# Baking Lenovo WWAN FCC Unlock into a Fedora Atomic Image (Silverblue / Kinoite / Bazzite / any bootc image)

This guide explains how to build the FCC unlock **into a custom OS image** (a
bootc / `ublue`-style Containerfile) instead of installing it at runtime with
the scripts in this repo. On an image-based/atomic system this is the cleaner
option: it uses **Lenovo's upstream files unmodified**, makes the fix
reproducible and update-safe, and — done as described here — is **safe to ship
to every machine in a fleet**, activating only on the ones that actually have a
supported modem.

It is self-contained: read this together with `SILVERBLUE_NOTES.md` (which
explains the runtime install and the root-cause analysis) and you have
everything needed to implement it.

---

## 0. Background: why a plain install breaks on atomic

Lenovo's `DPR_Fcc_unlock_service` and `configservice_lenovo` **`dlopen()` their
plugin libraries and read their SAR configs from an absolute path hardcoded in
the ELF**: `/opt/fcc_lenovo/lib/…` and `/opt/fcc_lenovo/sar_config_files/…`.
They do *not* consult `ld.so.conf`, `LD_LIBRARY_PATH`, or the working directory
for those libs. Verify on any copy of the binary:

```bash
strings DPR_Fcc_unlock_service | grep /opt/fcc_lenovo
# /opt/fcc_lenovo/lib/libmbimtools.so
# /opt/fcc_lenovo/lib/libmodemauth.so
# … etc
```

On a traditional distro `/opt` is a normal writable directory, so installing to
`/opt/fcc_lenovo` satisfies that path and everything works. On Fedora atomic:

- **Older atomic:** `/opt` is a **symlink to `/var/opt`**. Installing to
  `/opt/fcc_lenovo` lands in writable `/var/opt/fcc_lenovo`, the hardcoded path
  resolves, and the runtime scripts in this repo work.
- **Image with baked `/opt` content:** many custom images convert `/opt` into a
  **real directory** in the (read-only) image layer — typically with
  `RUN rm /opt && mkdir /opt` — so that RPMs which install into `/opt` (several
  browsers and desktop apps do) can be baked in. Once `/opt` is a real,
  read-only image directory, `/opt/fcc_lenovo` can neither be created at runtime
  nor resolve through the old symlink, and unlock fails with:

  ```
  Open libmbimtools.so failed! error:/opt/fcc_lenovo/lib/libmbimtools.so: cannot open shared object file: No such file or directory
  FCC unlock failed
  ```
  reported by ModemManager as `Cannot power-up: software radio switch is OFF`.

**The image approach turns this liability into the fix:** if `/opt` is a real
image directory, you simply *bake the Lenovo files at the real `/opt/fcc_lenovo`*
and the hardcoded path resolves natively (read-only is fine — the service only
*reads* its libs/configs). No binary patching, no `/var`, no `ld.so.conf`.

### The three failure modes, and what the image fixes for free

ModemManager's supported unlock mechanism is to run a hook at
`…/ModemManager/fcc-unlock.d/<vendorID:productID>` during modem enable. For that
to succeed, three conditions must hold. In an image build, two of them are
satisfied automatically:

| Requirement | Runtime install | **Image build** |
|---|---|---|
| The binary's hardcoded `/opt/fcc_lenovo/lib` resolves | needs a writable path + patch, OR `/opt` symlink | **free** — bake at the real `/opt/fcc_lenovo` |
| The hook file is **owned by root** (MM refuses non-root hooks: `File '…' not owned by root`) | must `chown root:root` | **free** — image files are root-owned |
| `modemmanager_t` may **execute** the binary + map the libs under SELinux | must relabel | **still required** — set `bin_t`/`lib_t` (see §4) |

There is also a fourth, non-blocking item (ThinkPad persisted rfkill) covered in
§6.

---

## 1. Which files you need, and where to get them

Take them from **upstream** `github.com/lenovo/lenovo-wwan-unlock` (they work
unmodified in an image — no fork needed). **Vendor them at a pinned commit**
into your image repo rather than fetching at build time: a live fetch couples
your entire image build to Lenovo's repo layout, and they *do* restructure it.
A pinned vendored copy makes the build hermetic and reproducible.

From the upstream repo you need:

- **Binaries:** `DPR_Fcc_unlock_service`, `configservice_lenovo`
- **Libraries** (contents of `lib/`, dlopen'd by the binaries):
  - Always: `libmbimtools.so`, `libmodemauth.so`, `libmodemauth.so.1.1`
  - For SAR config: `libconfigservice350.so`, `libconfigservice350.so.1.1`,
    `libconfigserviceR+.so` (and, in newer upstream, `libconfigservice350.so.1.2`,
    `libconfigservice101.so.1.2`)
  - For newer modems only (Rolling Wireless RW101, etc.): `libmodemauthRW101.so.1.1`,
    `libfiisdk.so.2.2.x`. Include if you want to support those modems; harmless
    otherwise.
- **Hook scripts:** `fcc-unlock.d.tar.gz` — one script per supported
  `<vendorID:productID>`, each just calls `DPR_Fcc_unlock_service`.
- **SAR profiles:** `sar_config_files.tar.gz` (large; contains per-machine
  `.bin` profiles, including a `cs25/` subtree for recent ThinkPads).
- **SELinux policy modules:** `mm_FccUnlock.cil`, `mm_dmidecode.cil`, `mm_sh.cil`.

Find your modem's `vendorID:productID` on the target machine with
`lspci -nn | grep -i -E 'modem|wwan|cellular'` or `mmcli -m 0`. Common IDs:
Quectel `1eac:1007` (RM520N-GL) / `1eac:100d` (EM160R-GL), Fibocom `14c3:4d75`
(FM350), Intel `8086:7560` (L860-R+), Foxconn `105b:e0*` / `2cb7:01a*`. Ship the
hook(s) for the modem(s) you care about.

> **Do NOT run upstream's `fcc_unlock_setup.sh` inside the build.** It targets a
> live, mutable system (writes into `/usr/lib*/ModemManager`, runs `ldconfig`,
> `systemctl`, `mmcli`, rfkill pokes). In an image you place files declaratively
> and handle enablement the image way (§3–§5). Cherry-pick, don't execute it.

---

## 2. Target layout inside the image

Mirror the layout upstream uses on ordinary Fedora, frozen into the image:

```
/opt/fcc_lenovo/
├── DPR_Fcc_unlock_service          # bin_t  (see §4)
├── configservice_lenovo            # bin_t
├── lib/                            # lib_t
│   ├── libmbimtools.so
│   ├── libmodemauth.so  libmodemauth.so.1.1
│   └── libconfigservice*.so*  libconfigserviceR+.so  …
├── sar_config_files/…              # SAR .bin profiles
└── mm_FccUnlock.cil  mm_dmidecode.cil  mm_sh.cil

/usr/lib64/ModemManager/fcc-unlock.d/
└── 1eac:1007                       # (+ any other <vid:pid> hooks), root:root 0755

/usr/lib/systemd/system/lenovo-cfgservice.service                    # SAR (guarded, §5)
/usr/lib/systemd/system/ModemManager.service.d/10-wwan-unlock.conf   # suspend flag (§5)
/usr/lib/systemd/system-sleep/lenovo-fcc-unlock-resume.sh            # resume re-unlock (guarded, §5)
```

Notes:

- **Hook directory:** ModemManager searches both `/etc/ModemManager/fcc-unlock.d`
  and its compiled-in libdir directory. On Fedora that libdir dir is
  `/usr/lib64/ModemManager/fcc-unlock.d`. Confirm on your base image:
  ```bash
  strings "$(command -v ModemManager)" | grep -o '/[^"]*fcc-unlock.d'
  ```
  Put hooks in the `/usr/lib64/...` path (image layer, root-owned). `/etc/...`
  also works but `/etc` is a per-deployment merge; `/usr` is the cleaner image
  home. Check the base image doesn't already ship a conflicting hook for your
  `<vid:pid>`.
- **Everything lives in `/opt` and `/usr`** — both are part of the image layer.
  Deliberately **avoid `/var`**: content baked into `/var` requires a matching
  `tmpfiles.d` entry or `bootc container lint` fails ("content in /var missing
  tmpfiles.d entries"), and `/var` is per-deployment state, not image content.

---

## 3. Containerfile: make `/opt` a real directory, then COPY

The Lenovo files can only live at a real `/opt/fcc_lenovo` if `/opt` is a real
directory in the image. Base images (Bazzite etc.) ship `/opt` as a symlink to
`/var/opt`; convert it once, early, before any COPY into `/opt`:

```dockerfile
FROM <your-base-image>

# Base images ship /opt as a symlink to /var/opt (writable at runtime). To bake
# content into /opt it must be a real directory in the image layer. Two options:
#
#   (a) real directory:
RUN rm /opt && mkdir /opt
#
#   (b) bootc-idiomatic — keep /opt a symlink, but into the read-only image:
# RUN rm /opt && ln -s usr/lib/opt /opt
#     (then place files at /usr/lib/opt/fcc_lenovo; the hardcoded
#      /opt/fcc_lenovo path resolves through the symlink to the image layer)
#
# Either way /opt becomes read-only on the running system — which is exactly
# what makes the hardcoded /opt/fcc_lenovo path work: the service only reads it.

# Overlay the vendored files verbatim (see §2 for the tree). A COPY makes every
# file root-owned automatically — which satisfies ModemManager's
# "hook must be owned by root" requirement for free.
COPY system_files/ /

# Package install / SELinux / enablement (see build.sh in §4–§5)
COPY build_files/ /ctx/
RUN /ctx/build.sh

# Always lint last.
RUN bootc container lint
```

`system_files/` is a tree whose paths mirror the image root (i.e.
`system_files/opt/fcc_lenovo/…`, `system_files/usr/lib64/ModemManager/…`, …).
This is the standard `ublue`/`bootc` overlay pattern.

If you chose option (b), put the files under `system_files/usr/lib/opt/fcc_lenovo`
instead of `system_files/opt/fcc_lenovo`.

---

## 4. build.sh: SELinux (the one part the image can't do implicitly)

`modemmanager_t` (the domain ModemManager runs in) may only **execute** files
labeled `bin_t` and **map** libraries labeled `lib_t`. Files placed under `/opt`
via COPY get a generic label that `modemmanager_t` is *not* permitted to
execute; without a fix you get:

```
avc: denied { execute } comm="1eac:1007" name="DPR_Fcc_unlock_service" tcontext=…:var_t
```

Register durable file contexts and load the policy modules during the build:

```bash
#!/bin/bash
set -euo pipefail

FCC=/opt/fcc_lenovo            # or /usr/lib/opt/fcc_lenovo for Containerfile option (b)

# 1) Load Lenovo's SELinux modules (let MM write its log, exec dmidecode, etc.)
semodule -i "$FCC"/mm_FccUnlock.cil "$FCC"/mm_dmidecode.cil "$FCC"/mm_sh.cil

# 2) Label the binaries bin_t and the libs lib_t so modemmanager_t can run them.
#    semanage writes durable rules into the policy store (survives relabels);
#    restorecon then applies them to the on-disk files (committed into the image).
semanage fcontext -a -t bin_t "$FCC/DPR_Fcc_unlock_service"
semanage fcontext -a -t bin_t "$FCC/configservice_lenovo"
semanage fcontext -a -t lib_t "$FCC/lib(/.*)?"
restorecon -Rv "$FCC"

# 3) Make sure the binaries + hooks are executable (COPY preserves mode, but be safe)
chmod 0755 "$FCC/DPR_Fcc_unlock_service" "$FCC/configservice_lenovo"
chmod 0755 /usr/lib64/ModemManager/fcc-unlock.d/*
```

Notes / gotchas:

- `semanage`, `semodule`, `restorecon` are provided by `policycoreutils` /
  `policycoreutils-python-utils`. They are present in the Fedora bootc and
  `ublue` bases; on a minimal base, `dnf install` them in the build.
- `semodule`/`semanage` operate on the policy **store** and file **xattrs** — no
  running kernel SELinux is required in the build container. `bootc`/`ostree`
  commits the resulting labels into the (composefs) image.
- The `bin_t`/`lib_t` labeling is exactly what was verified working on a live
  machine (ModemManager successfully executed the binary and unlocked the modem
  once these labels were in place).
- Alternative to `semanage`+`restorecon`: ship a small custom `.cil` that assigns
  the type via a `filecon` rule. `semanage`+`restorecon` is simpler and proven.

---

## 5. build.sh: systemd units — self-gating so they're safe fleet-wide

The FCC-unlock **hooks are inherently self-gating**: ModemManager only invokes
`fcc-unlock.d/<vid:pid>` when a modem with that exact ID appears. On a machine
with no such modem the hook is never called — zero cost. Ship it freely.

The **SAR service** and the **resume hook**, however, would misbehave on a
machine with no modem unless guarded — this is the key to shipping the image to a
mixed fleet:

- `lenovo-cfgservice.service` has `Restart=on-failure`; with no modem it would
  **restart-loop every 20 s forever**.
- The resume hook waits for `/dev/wwan0mbim0`; with no modem it would **hang the
  resume for ~30 s on every wake**.

Guard both so they become inert (skipped, not failed) where there is no modem:

**`system_files/usr/lib/systemd/system/lenovo-cfgservice.service`**
```ini
[Unit]
Description=Lenovo WWAN SAR config
After=ModemManager.service
# Inert on machines with no WWAN modem: systemd skips the unit (logged as
# "Condition check ... skipped"), so no failure and no restart loop.
ConditionPathExistsGlob=/dev/wwan*mbim*

[Service]
Type=simple
User=root
ExecStart=/opt/fcc_lenovo/configservice_lenovo
Restart=on-failure
RestartSec=20

[Install]
WantedBy=multi-user.target
```

**`system_files/usr/lib/systemd/system-sleep/lenovo-fcc-unlock-resume.sh`** (mode 0755)
```bash
#!/bin/bash
# Re-run FCC unlock after resume. Guard first: on a machine with no WWAN modem,
# exit immediately so we don't stall every resume waiting for a device that
# will never appear.
[ "$1" = "post" ] || exit 0
[ -e /dev/wwan0mbim0 ] || exit 0
/opt/fcc_lenovo/DPR_Fcc_unlock_service
```

**`system_files/usr/lib/systemd/system/ModemManager.service.d/10-wwan-unlock.conf`**
— keeps the modem in low power across suspend so the FCC unlock persists (needed
by MM ≥ 1.23.2 for several of these modems). Harmless on modem-less machines.
```ini
[Service]
ExecStart=
ExecStart=/usr/sbin/ModemManager --test-low-power-suspend-resume
```
> Verify the base image's ModemManager `ExecStart` path with
> `systemctl cat ModemManager | grep ExecStart` and match it (Fedora:
> `/usr/sbin/ModemManager`).

**Enable the SAR service at build time** (systemd presets are not applied inside
a build container, so enable explicitly to bake the symlink):
```bash
systemctl enable lenovo-cfgservice.service
```
The drop-in and the system-sleep script need no enabling (a drop-in is applied
automatically; a `system-sleep` script runs by virtue of being in the directory).

### Do NOT ship a boot-time unlock service

Some setups add a oneshot service that runs `DPR_Fcc_unlock_service` at boot,
under the belief that "ModemManager doesn't dispatch the hooks." That is a
misdiagnosis: ModemManager **does** dispatch the hook — it was only *refusing*
hooks that weren't root-owned. In an image the hooks are root-owned, so MM runs
them during normal modem enable at every boot. A boot service is redundant (and
`DPR_Fcc_unlock_service` also needs ModemManager running — it talks to MM over
D-Bus — so running it standalone/early is fragile). Omit it.

---

## 6. ThinkPad persisted rfkill (not bakeable)

On some ThinkPads, `/var/lib/systemd/rfkill/platform-thinkpad_acpi:wwan` holds
`0`, so systemd re-blocks WWAN at every boot and ModemManager reports "software
radio switch is OFF" even when live `rfkill` looks fine. This is **`/var`
runtime state and cannot be baked into the image.** Options:

- Leave it — many machines never hit this; if unlock works after rebase you're
  done.
- If a target machine does hit it, fix it once:
  ```bash
  echo 1 | sudo tee /var/lib/systemd/rfkill/platform-thinkpad_acpi:wwan
  sudo systemctl restart systemd-rfkill
  ```
- Or ship a tiny guarded first-boot oneshot that writes `1` when the file
  contains `0` and a WWAN device is present.

---

## 7. Verify (on a machine that actually has the modem, after rebasing)

The build machine typically has no modem, so verification happens on the target
after it rebases onto the new image:

```bash
mmcli -L                                   # modem present?
mmcli -m 0 | grep -E 'state:|power state|signal|packet'
# want: state: registered, power state: on, packet service state: attached

journalctl -u ModemManager -b | grep -iE 'fcc|unlock|not owned|radio switch'
# want: an "attempting FCC unlock..." with NO "not owned by root" and NO failure

ausearch -m avc -ts recent 2>/dev/null | grep -i fcc_lenovo   # want: nothing
```

Verbose DPR logging (temporary): append `-v` to the hook and read syslog:
```bash
sudo sed -i 's#\(DPR_Fcc_unlock_service\)$#\1 -v#' /usr/lib64/ModemManager/fcc-unlock.d/1eac:1007
sudo mmcli -G DEBUG && sudo mmcli -m 0 -e
journalctl -t DPR_Fcc_unlock_service -n 20
```
A healthy verbose run prints `WWAN device … found` / `Device "/dev/wwan0mbim0"
exists` and then succeeds silently (it only logs `FCC unlock failed` on error).

### Migration tip (zero-downtime)

If a machine currently has the **runtime** fix from this repo, its hooks live in
`/etc/ModemManager/fcc-unlock.d/`, which **overrides** the image's
`/usr/lib64/...` hooks. So rebasing onto the baked image changes nothing until
you deliberately hand over: remove the `/etc` hooks (and any `/var/fcc_lenovo`
tree the runtime fix created), reboot, and let the image's version take effect.
If it works, done; if not, the runtime fix is one script away. Fully reversible.

---

## 8. Troubleshooting matrix

| Symptom (verbose log / journal / audit) | Cause | Fix |
|---|---|---|
| `Open lib….so failed! …/opt/fcc_lenovo/lib/…: No such file or directory` | Files not at the path the binary hardcodes | Ensure `/opt` is a real dir and files are at `/opt/fcc_lenovo` (§3); if using symlink option (b), files at `/usr/lib/opt/fcc_lenovo` |
| `couldn't run FCC unlock: … not owned by root` | Hook not root-owned | In an image this shouldn't happen; if extracting a tarball in build.sh, `chown root:root` the hooks |
| `avc: denied { execute } … tcontext=…:var_t` (or other non-bin_t) | SELinux label wrong | `semanage fcontext` `bin_t`/`lib_t` + `restorecon` (§4) |
| `FCC unlock failed` with no lib error | Path resolved but exec/label or modem-state issue | Check `ausearch -m avc`; ensure ModemManager is running (DPR needs its D-Bus) |
| `Cannot power-up: software radio switch is OFF` and unlock never attempted | Hook not found / wrong dir | Confirm MM's search dir (§2) and the `<vid:pid>` filename matches your modem |
| Same, but unlock *did* run | Persisted rfkill = 0 | §6 |
| `lenovo-cfgservice` restart-looping on a modem-less machine | Missing `Condition` guard | Add `ConditionPathExistsGlob=/dev/wwan*mbim*` (§5) |
| 30 s hang on resume on a modem-less machine | Resume hook not guarded | Add the `[ -e /dev/wwan0mbim0 ] || exit 0` early-exit (§5) |
| `bootc container lint` fails: "content in /var …" | Something baked into `/var` | Keep everything in `/opt` + `/usr`, or add a `tmpfiles.d` entry |

---

## 9. Summary

- Convert `/opt` to a real image directory; bake **upstream Lenovo files
  unmodified** at `/opt/fcc_lenovo`.
- Put hooks in `/usr/lib64/ModemManager/fcc-unlock.d/` — root-owned for free.
- The only active build step is **SELinux**: load the `.cil` modules and label
  the binaries `bin_t` / libs `lib_t`, then `restorecon`.
- Make the **SAR service** and **resume hook** self-gating (`Condition` /
  early-exit) so the image is safe on machines with no modem; the fcc-unlock
  hooks are already self-gating.
- Skip the boot-time unlock service (redundant); handle rfkill out-of-band.
- Vendor the files at a **pinned** upstream commit — never fetch live, or a
  Lenovo repo reshuffle can break your whole image build.

This reproduces the known-good traditional-Fedora install, frozen into the
image, with no patched binaries and no per-machine manual steps.
