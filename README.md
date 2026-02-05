# lenovo-wwan-unlock-silverblue

This repository contains scripts and configurations for enabling FCC and DPR unlock, and SAR configuration, for WWAN modules in specific Lenovo PCs, specifically adapted for **Fedora Silverblue**.

The original scripts in this repository were designed for traditional Linux distributions and are incompatible with Fedora Silverblue's immutable root filesystem. This "-silverblue" version includes new setup and uninstall scripts (`fcc_unlock_setup_silverblue.sh` and `fcc_unlock_uninstall_silverblue.sh`) that leverage Silverblue's architectural principles (e.g., using writable `/etc` and `/var` directories, systemd drop-ins) to achieve the same functionality while preserving system integrity.

These Silverblue-compatible scripts were developed by Gemini AI. Additional adaptations and hardening were made by Codex (OpenAI).

Quick Start (Silverblue / Kinoite / Bazzite):
1) Run the Silverblue setup script:
   ```
   chmod ugo+x fcc_unlock_setup_silverblue.sh
   ./fcc_unlock_setup_silverblue.sh
   ```
2) Reboot once.

Quick Verify:
```
./verify_install.sh
```
Quick Fix (ThinkPad WWAN persisted rfkill):
```
./verify_install.sh --fix-rfkill
```

Bazzite Notes:
- If ModemManager shows "software radio switch is OFF" even though `rfkill` and `nmcli radio` report enabled, check your ThinkPad WWAN hardware toggle and BIOS/UEFI WWAN settings.
- Also check the persisted rfkill state. If `/var/lib/systemd/rfkill/platform-thinkpad_acpi:wwan` contains `0`, systemd restores WWAN as blocked at boot.
- Fix: `./verify_install.sh --fix-rfkill`
- If ModemManager stops seeing the modem after restart, re-trigger udev:
  `sudo udevadm trigger -c add -s mhi -s wwan && sudo udevadm settle`
- Avoid repeated ModemManager stop/start loops while MBIM is active; it can temporarily hide the modem.

Uninstall (Silverblue / Kinoite / Bazzite):
1) Run the Silverblue uninstall script:
   ```
   chmod ugo+x fcc_unlock_uninstall_silverblue.sh
   ./fcc_unlock_uninstall_silverblue.sh
   ```

Notes / Deviations From Upstream:
- The upstream Lenovo repo does not include the Silverblue scripts. This fork adds them and uses writable `/etc` and `/opt` paths instead of immutable `/usr` and `/lib`.
- The legacy Lenovo scripts (`fcc_unlock_setup.sh`, `fcc_unlock_uninstall.sh`) are retained for reference, but they now detect Fedora Silverblue/Kinoite (case-insensitive) and defer to the Silverblue scripts.
- The FCC unlock scripts inside `fcc-unlock.d.tar.gz` now call `/opt/fcc_lenovo/DPR_Fcc_unlock_service` using an absolute path to avoid reliance on ModemManager’s working directory.
- `fcc_unlock_setup_silverblue.sh` includes a best-effort check that warns if ModemManager’s FCC unlock search path does not appear to include `/etc/ModemManager/fcc-unlock.d`.

Rationale / Known Issues (for maintainers):
- Silverblue/Kinoite have immutable `/usr` and `/lib`, so upstream install logic that writes into those locations will fail. All integration must be done via writable `/etc` and `/opt`.
- The original `fcc-unlock.d` scripts used `./opt/fcc_lenovo/...` (relative path). This can break if ModemManager’s working directory is not `/`. Absolute `/opt/...` avoids this fragility.
- ModemManager’s FCC unlock search paths may vary by build. The Silverblue setup script does a best-effort binary check for `/etc/ModemManager/fcc-unlock.d` and warns if it cannot find it.
- The scripts assume `mmcli`, `lspci`, `semodule`, `ldconfig`, and `systemctl` are present. On a minimal Silverblue image, you may need to install missing packages via `rpm-ostree`.

----
Everything below this line is from the original upstream repository.

FCC and DPR unlock for Lenovo PCs

Instructions to perform FCC unlock and SAR config:

-----------------------------------------------------------------
List of Supported WWAN Modules and Systems:

1) WWAN module : Fibocom L860R+  
   Supported systems:
   - ThinkPad X1 Yoga Gen 7
   - ThinkPad X1 Yoga Gen 8
   - ThinkPad X1 Carbon Gen 10
   - ThinkPad X1 Carbon Gen 11
   - ThinkPad T14 Gen 3
   - ThinkPad T14 Gen 4
   - ThinkPad T14s Gen 3
   - ThinkPad T14s Gen 4
   - ThinkPad T16 Gen 1
   - ThinkPad T16 Gen 2
   - ThinkPad L14 Gen 4
   - ThinkPad L15 Gen 4
   - ThinkPad P14s Gen 4

2) WWAN module : Fibocom FM350 5G  
   Supported systems:
   - ThinkPad X1 Yoga Gen 7
   - ThinkPad X1 Yoga Gen 8
   - ThinkPad X1 Carbon Gen 10
   - ThinkPad X1 Carbon Gen 11
   - ThinkPad X13 Gen 5

3) WWAN module : Quectel RM520N-GL (*Please refer below required Environment)
   Supported systems:
   - ThinkPad X1 Carbon Gen 12
   - ThinkPad X1 2-in-1 Gen 9
   - ThinkPad T14 Gen 5 (Intel/AMD)
   - ThinkPad T16 Gen 3
   - ThinkPad T14s Gen 5 (Intel)
   - ThinkPad T14s Gen 6 (AMD)
     
     -- **Below are list of 2025 products** --
   - ThinkPad X1 Carbon Gen 13
   - ThinkPad X1 2-in-1 Gen 10
   - ThinkPad T14 Gen 6 (Intel/AMD)
   - ThinkPad T14s Gen 6 (Intel/AMD)
   - ThinkPad T16 Gen 4 (Intel/AMD)
   - ThinkPad P16s Gen 4 AMD
   - ThinkPad P14s Gen 6 AMD
     
   **Environment**:(Enabled only for non-USA SIM)
   - Kernel version: 6.6 or later
   - ModemManager version: 1.22 or later

4) WWAN module : Quectel EM160R-GL (*Please refer below required Environment)
   Supported systems:
   - ThinkPad X1 Carbon Gen 12
   - ThinkPad X1 2-in-1 Gen 9
   - ThinkPad L14 Gen 5
   - ThinkPad L16 Gen 1
   - ThinkPad X13 2-in-1 Gen 5
   - ThinkPad T14 Gen 5 (Intel/AMD)
  
     -- **Below are list of 2025 products** --
   - ThinkPad X1 Carbon Gen 13 (ARL only)
   - ThinkPad X1 2-in-1 Gen 10 (ARL only)
   - ThinkPad P16s Gen 4
   - ThinkPad L14 Gen 6 (Intel/AMD)
   - ThinkPad T14 Gen 6 (Intel/AMD)
   - ThinkPad P14s Gen 6 AMD
     
   **Environment**:(Enabled only for non-USA SIM)
   - Kernel version: 6.5 or later
   - ModemManager version: 1.22 or later

5) WWAN module : Quectel EM061K (*Please refer below required Environment)
   Supported systems:
   - ThinkPad L13 Gen 5
   - ThinkPad L13 2-in-1 Gen 5
   - ThinkPad L14 Gen 5
   - ThinkPad L16 Gen 1
   - ThinkPad X13 Gen 5
   - ThinkPad X13 2-in-1 Gen 5
   - ThinkPad T14 Gen 5 (Intel/AMD)
   - ThinkPad T16 Gen 3
   - ThinkPad T14s Gen 5 (Intel)
     
     -- **Below are list of 2025 products** --
   - ThinkPad L13 Gen 6 (Intel/AMD)
   - ThinkPad L13 2-in-1 Gen 6 (Intel/AMD)
   - ThinkPad L14 Gen 6 (Intel/AMD)
   - ThinkPad L16 Gen 2 (Intel/AMD)
   - ThinkPad T14 Gen 6 (Intel/AMD)
   - ThinkPad T14s Gen 6 (Intel/AMD)
   - ThinkPad T16 Gen 4 (Intel/AMD)
   - ThinkPad X13 Gen 6 (Intel/AMD)
   - ThinkPad T14s 2-in-1 Gen 1 (Intel)
     
   **Environment**:(Enabled only for non-USA SIM)
   - Kernel version: 6.5 or later
   - ModemManager version: 1.22 or later

6) WWAN module : Quectel EM05-CN (*Please refer below required Environment) 
   Supported systems:
   - ThinkPad X1 Carbon Gen 12
   - ThinkPad X13 Gen 5
   - ThinkPad X13 2-in-1 Gen 5
   - ThinkPad T14 Gen 5 (Intel)
     
   **Environment**:
   - Kernel version: 6.6 or later
   - ModemManager version: 1.21.2 or later

7) WWAN module : Rolling Wireless RW350 
   Supported systems:
   - ThinkPad T14s 2-in-1 Gen 1 (Intel)
   - ThinkPad X13 Gen 6
   - ThinkPad P16 Gen 3
   - ThinkPad P16v Gen 3
     
Enablement is done on a Module + System basis. **Systems not listed 
are currently not supported.**

------------------------------------------------------------------------
Tested Operating Systems:
- Ubuntu 22.04 : OK
- Fedora: OK

------------------------------------------------------------------------
**Please follow the procedure below step by step to enable WWAN**

1) Run the `fcc_unlock_setup.sh` script to
   install SAR config package and FCC unlock:
   ```
   chmod ugo+x fcc_unlock_setup.sh
   ./fcc_unlock_setup.sh
   ```
2) Reboot machine (Only needed once)

------------------------------------------------------------------------
**Please follow the procedure for uninstalling this package**

1) Run the `fcc_unlock_uninstall.sh` script to
   uninstall SAR config package and FCC unlock:
   ```
   chmod ugo+x fcc_unlock_uninstall.sh
   ./fcc_unlock_uninstall.sh
   ```
------------------------------------------------------------------------
Logs can be checked using **one** of the commands below:
- For FCC Unlock: `cat /var/log/syslog | grep -i DPR_Fcc_unlock_service`
- For SAR Config: `cat /var/log/syslog | grep -i configservice_lenovo`
- `journalctl`
- Please follow below steps to enable **Verbose** logging:
  1) **For FCC Unlock**:
  Add "-v" in FCC unlock scripts updated in "fcc-unlock.d.tar.gz", for example:

      FileName - fcc-unlock.d/8086:7560
  
      Modification- "./opt/fcc_lenovo/DPR_Fcc_unlock_service **-v**"

  2) **For SAR Config**:
      Add "-v" in systemd service file, for example:

      FileName - lenovo-cfgservice.service
  
  Modification- "ExecStart=/opt/fcc_lenovo/configservice_lenovo **-v**"    

------------------------------------------------------------------------
Additional Notes:
- If the Modem disappears after the machine reboots, please
restart it with the `systemctl restart ModemManager` command.
- WWAN enablement is not done for USA SIM, used in below modules:
   - Fibocom FM350
   - Quectel RM520N-GL
   - Quectel EM160R-GL
   - Quectel EM061K
- WWAN enablement is done for USA SIM except for Verizon SIM, used in below module:
   - Fibocom L860R+

  Reason: Carrier certification for USA operator is not completed and it
          will take few months to enable WWAN for USA SIM.
------------------------------------------------------------------------
