# FCC Unlock on Fedora Atomic (Silverblue / Kinoite / Bazzite) — Deep Dive

This document records *why* WWAN FCC unlock breaks on atomic desktops and exactly
how this fork fixes it. Read this first if the modem stops unlocking after a base
image update. It exists because the failure mode is non-obvious and recurred once
already (see the git history around the `/var/fcc_lenovo` migration).

---

## TL;DR

Lenovo's `DPR_Fcc_unlock_service` (and `configservice_lenovo`) **`dlopen()` their
libraries from an absolute path hardcoded into the binary: `/opt/fcc_lenovo/lib/…`**.
They do **not** honor `ld.so.conf`, `LD_LIBRARY_PATH`, or the current working
directory for those plugin libs.

- On **older Fedora atomic**, `/opt` was a **symlink to `/var/opt`**, so installing
  to `/opt/fcc_lenovo` actually landed in writable `/var/opt/fcc_lenovo`, and the
  hardcoded path resolved. Everything worked.
- On **newer atomic (e.g. Bazzite)**, `/opt` is a **real, read-only directory baked
  into the composefs image** (the "new model" — it now holds image-shipped content
  like browsers). `/opt/fcc_lenovo` can neither be created nor resolved, so the
  `dlopen()` fails and unlock aborts.

**Fix:** install everything under the writable path **`/var/fcc_lenovo`** and rewrite
the hardcoded prefix inside the two binaries. `/var/fcc_lenovo` is deliberately the
**same length (15 bytes)** as `/opt/fcc_lenovo`, so the ELF strings can be patched
in place without shifting any offsets.

---

## Symptoms

- `mmcli -m 0` shows `state: disabled`, `power state: low`.
- ModemManager journal:
  ```
  [modem0] Cannot power-up: software radio switch is OFF
  [modem0] failed enabling modem: Invalid transition
  ```
  …even though `rfkill list` and `nmcli radio` report WWAN enabled.
- With verbose logging on (see below), the DPR service logs:
  ```
  WWAN device Quectel RM520N-GL found
  Device "/dev/wwan0mbim0" exists
  Open libmbimtools.so failed! error:/opt/fcc_lenovo/lib/libmbimtools.so: cannot open shared object file: No such file or directory
  FCC unlock failed
  ```

## Root cause: the `/opt` model change

Confirm which model your system uses:

```bash
# Read-only, real dir baked into the image? (new model → hardcoded /opt path breaks)
findmnt /                       # type overlay, "composefs ... ro"
ls -ldZ /opt                    # real dir, not a symlink
touch /opt/_t 2>&1              # "Read-only file system" on the new model
readlink -f /opt                # prints /opt (not /var/opt) on the new model
```

The tmpfiles drop-in `rpm-ostree-0-integration-opt-usrlocal.conf` documents both
models. When the base image started shipping content in `/opt`, `/opt` had to become
a real image directory instead of a `→ /var/opt` symlink — and that silently broke
the binaries' hardcoded lookup path.

Nothing about the modem, the LVFS modem firmware, or Lenovo's unlock package changed.
(Modem firmware for the RM520N-GL is delivered via `fwupd`/LVFS, independently of this
repo.)

## The full failure chain (three separate bugs)

Fixing the path alone is not enough. ModemManager's **supported** mechanism is to
dispatch `/etc/ModemManager/fcc-unlock.d/<vid:pid>` during modem enable. For that to
succeed, all three of these must hold:

1. **Hardcoded lib path resolves.** → Install to `/var/fcc_lenovo` and patch the
   binaries (`s{/opt/fcc_lenovo}{/var/fcc_lenovo}g`, equal length).

2. **Hook files are owned by root.** ModemManager refuses any FCC-unlock hook that is
   not root-owned:
   ```
   couldn't run FCC unlock: Cannot run fcc unlock operation from
   /etc/ModemManager/fcc-unlock.d/1eac:1007: File '…1eac:1007' not owned by root
   ```
   The shipped `fcc-unlock.d.tar.gz` preserves a foreign UID (e.g. `1177719483`), so
   setup must `chown root:root` + `chmod 755` the hooks.
   > NOTE: this also debunks the earlier "MM 1.24.2 doesn't dispatch hooks" theory —
   > MM 1.24.2 **does** dispatch; it was rejecting the hook purely on ownership.

3. **SELinux lets `modemmanager_t` execute the binary.** Files freshly created under
   `/var` get the generic `var_t` label, which `modemmanager_t` may not execute:
   ```
   avc: denied { execute } comm="1eac:1007" name="DPR_Fcc_unlock_service"
        scontext=…:modemmanager_t tcontext=…:var_t
   ```
   Fix with **durable** contexts (survive relabel/reboot):
   ```bash
   semanage fcontext -a -t bin_t '/var/fcc_lenovo/DPR_Fcc_unlock_service'
   semanage fcontext -a -t bin_t '/var/fcc_lenovo/configservice_lenovo'
   semanage fcontext -a -t lib_t '/var/fcc_lenovo/lib(/.*)?'
   restorecon -R /var/fcc_lenovo
   ```
   `modemmanager_t` is allowed to execute `bin_t` helpers and map `lib_t` libraries.

Plus a common secondary issue on ThinkPads:

4. **Persisted rfkill.** If `/var/lib/systemd/rfkill/platform-thinkpad_acpi:wwan`
   contains `0`, systemd re-blocks WWAN at every boot ("software radio switch is OFF"
   even when live `rfkill` looks fine). Set it to `1` and restart `systemd-rfkill`.
   (`./verify_install.sh --fix-rfkill` does this.)

## Diagnostics

Enable verbose logging by appending `-v` to the hook, then read syslog:

```bash
# add -v (temporarily) to the hook for your modem, e.g. 1eac:1007 for RM520N-GL
sudo sed -i 's#\(DPR_Fcc_unlock_service\)$#\1 -v#' /etc/ModemManager/fcc-unlock.d/1eac:1007

# turn on MM debug and re-trigger enable
sudo mmcli -G DEBUG
sudo mmcli -m 0 -e

# read the results
journalctl -t DPR_Fcc_unlock_service -n 20           # DPR's own messages
journalctl -u ModemManager -b | grep -iE 'fcc|unlock|not owned|radio switch'
ausearch -m avc -ts recent | grep -iE 'fcc_lenovo|modemmanager'   # SELinux denials
```

The unlock itself uses an AT command (`AT+GTFCCLOCKMODEUNLOCK`) after an MBIM
`FccModemChallenge`; the DPR service also talks to ModemManager over D-Bus, so **MM
must be running** — running the binary standalone with MM stopped fails to connect.

## How the fix is applied

`fcc_unlock_setup_silverblue.sh` does all of the above automatically:
`INSTALL_DIR=/var/fcc_lenovo` → copy files → in-place ELF patch of both binaries →
extract + repoint + `chown root` the hooks → `ld.so.conf` → install/enable the
systemd units → SELinux `.cil` + `semanage fcontext` (`bin_t`/`lib_t`) + `restorecon`
→ rfkill check. Reboot once and the modem unlocks via MM's normal enable path.

## Verify

```bash
mmcli -m 0 | grep -E 'state:|power state|signal|packet'
# expect: state: registered, power state: on, packet service state: attached
```

---

## Alternative: bake it into a custom image (bootc / ublue)

On a system you build yourself, this is cleaner than the runtime scripts:

- **`COPY` the files to the real `/opt/fcc_lenovo`** in your Containerfile. Read-only
  is fine — the service only *reads* its libs/configs — so the binaries' hardcoded
  `/opt/fcc_lenovo/lib` path resolves natively with **no binary patching**.
- **Root ownership is automatic** for image content → bug #2 disappears for free.
- You still ship, at build time: the `fcc-unlock.d` hooks, the systemd units, and an
  **SELinux** policy piece — set `bin_t`/`lib_t` contexts for the installed files
  (ship the `.cil` + a `semanage fcontext` rule, or set contexts during the build).
- Because no patching is needed, you can use **upstream Lenovo files unmodified** at
  `/opt/fcc_lenovo`. For the RM520N-GL specifically, upstream's `libmodemauth`,
  `libmbimtools`, and `libconfigservice350` are byte-identical to this fork anyway;
  upstream's newer work is RW101R-GL / SDX61-only.
- Trade-off: updates require an image rebuild (fine for a component that rarely
  changes), and you can't hot-edit files at runtime.

The persisted-rfkill fix (#4) is `/var` runtime state and can't be baked in; keep the
one-time check or accept fixing it once.
