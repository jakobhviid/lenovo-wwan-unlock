#! /bin/bash

### Insure the working directory is the same as the script
pushd "$(dirname "$0")" &> /dev/null || exit 1
trap "popd &> /dev/null" EXIT

echo "Setting up WWAN unlock for Fedora Silverblue / Kinoite / Bazzite..."

### Why this install dir?
#
# Lenovo's DPR_Fcc_unlock_service and configservice_lenovo dlopen() their
# plugin libraries and read their SAR configs from a HARDCODED absolute path
# baked into the ELF: "/opt/fcc_lenovo/...". On older Fedora atomic, /opt was a
# symlink to /var/opt, so that path resolved to a writable location and things
# worked. Newer atomic images (e.g. Bazzite) ship /opt as a REAL, read-only
# composefs directory (it now holds image-baked content such as browsers), so
# "/opt/fcc_lenovo" can neither be created nor resolved -> the unlock aborts
# with "Open libmbimtools.so failed" / "FCC unlock failed".
#
# Fix: install everything under a writable path and rewrite the hardcoded path
# inside the two binaries. We use "/var/fcc_lenovo" precisely because it is the
# SAME LENGTH as "/opt/fcc_lenovo" (15 bytes), which lets us patch the ELF
# strings in place without shifting any offsets.
INSTALL_DIR="/var/fcc_lenovo"
OLD_PREFIX="/opt/fcc_lenovo"

echo "Copying files and libraries to ${INSTALL_DIR}..."

sudo mkdir -p "${INSTALL_DIR}/lib"

### Copy main binaries and libraries
sudo cp -rvf DPR_Fcc_unlock_service "${INSTALL_DIR}/"
sudo cp -rvf configservice_lenovo "${INSTALL_DIR}/"
sudo cp -rvf libmodemauth.so "${INSTALL_DIR}/lib/"
sudo cp -rvf libmodemauth.so.1.1 "${INSTALL_DIR}/lib/"
sudo cp -rvf libconfigserviceR+.so "${INSTALL_DIR}/lib/"
sudo cp -rvf libconfigservice350.so "${INSTALL_DIR}/lib/"
sudo cp -rvf libconfigservice350.so.1.1 "${INSTALL_DIR}/lib/"
sudo cp -rvf libmbimtools.so "${INSTALL_DIR}/lib/"

### Copy SAR config files
sudo tar -zxf sar_config_files.tar.gz -C "${INSTALL_DIR}/"

### Grant permissions to all binaries and scripts
sudo chmod ugo+x "${INSTALL_DIR}"/*

### Rewrite the hardcoded "/opt/fcc_lenovo" prefix inside the binaries so they
### look for their libs/configs under ${INSTALL_DIR}. Equal-length replacement
### keeps the ELF byte-for-byte the same size (offsets preserved).
if [ "${INSTALL_DIR}" != "${OLD_PREFIX}" ]; then
    echo "Patching hardcoded '${OLD_PREFIX}' -> '${INSTALL_DIR}' in binaries..."
    if [ ${#INSTALL_DIR} -ne ${#OLD_PREFIX} ]; then
        echo "ERROR: INSTALL_DIR must be the same length as ${OLD_PREFIX} for the in-place patch." >&2
        exit 1
    fi
    for b in DPR_Fcc_unlock_service configservice_lenovo; do
        sudo perl -0777 -pi -e "s{\Q${OLD_PREFIX}\E}{${INSTALL_DIR}}g" "${INSTALL_DIR}/${b}"
        leftover=$(strings "${INSTALL_DIR}/${b}" 2>/dev/null | grep -c "${OLD_PREFIX}")
        echo "  ${b}: ${leftover} leftover '${OLD_PREFIX}' reference(s)"
    done
fi

### Part 2: Configure system integrations

### Create ModemManager fcc-unlock.d directory in /etc
echo "Configuring ModemManager..."
sudo mkdir -p /etc/ModemManager/fcc-unlock.d
# Tarball contains top-level fcc-unlock.d/, strip it to avoid nested dir
sudo tar -zxf fcc-unlock.d.tar.gz -C /etc/ModemManager/fcc-unlock.d/ --strip-components=1
# Remove macOS metadata files if present
sudo find /etc/ModemManager/fcc-unlock.d -name '._*' -delete

### The upstream hook scripts call the unlock binary via "/opt/fcc_lenovo/..."
### (sometimes as "./opt/..."). Repoint them at our install dir.
echo "Repointing FCC unlock hooks at ${INSTALL_DIR}..."
sudo sed -i -E "s#\.?(/var/opt/fcc_lenovo|/opt/fcc_lenovo)/DPR_Fcc_unlock_service#${INSTALL_DIR}/DPR_Fcc_unlock_service#g" \
    /etc/ModemManager/fcc-unlock.d/*

### ModemManager REFUSES to run an FCC-unlock hook unless it is owned by root
### (it logs: "File '...' not owned by root"). The shipped tarball preserves a
### foreign UID, so we must fix ownership and mode explicitly.
sudo chown root:root /etc/ModemManager/fcc-unlock.d/*
sudo chmod 755 /etc/ModemManager/fcc-unlock.d/*

echo "Validating FCC unlock hook installation..."
if [ -d /etc/ModemManager/fcc-unlock.d/fcc-unlock.d ]; then
    echo "Warning: Nested /etc/ModemManager/fcc-unlock.d/fcc-unlock.d detected."
    echo "This prevents ModemManager from finding hooks. Remove the nested directory and re-run setup."
fi
if ! find /etc/ModemManager/fcc-unlock.d -maxdepth 1 -type f | grep -q .; then
    echo "Warning: No FCC unlock hook files found in /etc/ModemManager/fcc-unlock.d."
    echo "FCC unlock will not trigger until hook files are present."
fi
echo "Verifying ModemManager FCC unlock search path..."
MM_BIN=$(command -v ModemManager || true)
if [ -z "$MM_BIN" ]; then
    echo "Warning: ModemManager binary not found. Unable to verify FCC unlock search path."
elif command -v strings >/dev/null 2>&1; then
    if strings "$MM_BIN" | grep -q "/etc/ModemManager/fcc-unlock.d"; then
        echo "ModemManager appears to include /etc/ModemManager/fcc-unlock.d in its search path."
    elif strings "$MM_BIN" | grep -q "/ModemManager/fcc-unlock.d"; then
        echo "Warning: ModemManager FCC unlock path detected, but /etc/ModemManager/fcc-unlock.d was not found in the binary."
        echo "If FCC unlock does not trigger, verify ModemManager search paths on this system."
    else
        echo "Warning: Unable to detect ModemManager FCC unlock search path in the binary."
        echo "If FCC unlock does not trigger, verify ModemManager search paths on this system."
    fi
else
    echo "Warning: 'strings' not available. Unable to verify ModemManager FCC unlock search path."
fi

### Configure dynamic linker to find our libraries.
### NOTE: the binaries dlopen() their libs by absolute path (patched above), so
### this is belt-and-suspenders, but we keep it consistent.
echo "Configuring dynamic linker..."
sudo bash -c "echo '${INSTALL_DIR}/lib' > /etc/ld.so.conf.d/fcc-lenovo.conf"
sudo ldconfig

### Install and enable the SAR config service and FCC unlock service
echo "Configuring systemd services..."
sudo cp -rvf lenovo-cfgservice.service /etc/systemd/system/
sudo cp -rvf lenovo-fcc-unlock.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable lenovo-cfgservice
sudo systemctl enable lenovo-fcc-unlock

### Install suspend/resume hook to re-run FCC unlock after wake
echo "Installing FCC unlock suspend/resume hook..."
sudo mkdir -p /etc/systemd/system-sleep
sudo cp -vf lenovo-fcc-unlock-resume.sh /etc/systemd/system-sleep/
sudo chmod 755 /etc/systemd/system-sleep/lenovo-fcc-unlock-resume.sh

### Part 3: Apply system-wide workarounds

### Apply ModemManager suspend fix via drop-in config
echo "Applying ModemManager suspend fix..."
SERVICE_FILE_PATH="/etc/systemd/system/ModemManager.service.d/10-wwan-unlock.conf"
STRING_LOW_POWER=" --test-low-power-suspend-resume"

restart_mm_service=false
function version_ge() { test "$(echo \"$@\" | tr \" \n\" | sort -rV | head -n 1)" == "$1"; }

function get_mm_execstart() {
    local exec_start_raw exec_start_cmd
    exec_start_raw=$(systemctl show -p ExecStart --value ModemManager 2>/dev/null || true)
    exec_start_cmd=$(printf '%s' "$exec_start_raw" | sed -n 's/.*argv\\[]=/ /p')
    exec_start_cmd=$(printf '%s' "$exec_start_cmd" | sed 's/;.*//' | sed 's/^[[:space:]]*//')
    if [ -z "$exec_start_cmd" ]; then
        exec_start_cmd=$(printf '%s' "$exec_start_raw" | sed 's/;.*//' | sed 's/^[[:space:]]*//')
    fi
    if [ -z "$exec_start_cmd" ]; then
        exec_start_cmd="/usr/sbin/ModemManager"
    fi
    printf '%s' "$exec_start_cmd"
}

LSPCI_BIN=$(command -v lspci || true)
if [ -z "$LSPCI_BIN" ]; then
    echo "Warning: lspci not found. Skipping suspend fix device check."
else
    Rplus_check=$("$LSPCI_BIN" -d :7560)
    FM350_check=$("$LSPCI_BIN" -d :4d75)
    RM520_check=$("$LSPCI_BIN" -d :1007)
    EM160R_check=$("$LSPCI_BIN" -d :100d)

    if [ -n "$Rplus_check" ] || [ -n "$FM350_check" ] || [ -n "$RM520_check" ] || [ -n "$EM160R_check" ]; then
        if ! command -v mmcli >/dev/null 2>&1; then
            echo "Warning: mmcli not found. Skipping suspend fix."
        else
            curmmver=$(mmcli -V)
            first_line=${curmmver%%
*}
            curmmvernum=$(echo $first_line | cut -d " " -f2)
            stand_ver="1.23.2"
            if version_ge $curmmvernum $stand_ver; then
                exec_start_cmd=$(get_mm_execstart)
                if printf '%s' "$exec_start_cmd" | grep -q -- '--test-low-power-suspend-resume'; then
                    echo "test-low-power-suspend-resume parameter already exists"
                else
                    sudo mkdir -p /etc/systemd/system/ModemManager.service.d
                    printf '[Service]\nExecStart=\nExecStart=%s%s\n' "$exec_start_cmd" "$STRING_LOW_POWER" | sudo tee "$SERVICE_FILE_PATH" >/dev/null
                    restart_mm_service=true
                fi
            else
                echo "ModemManager version is older than 1.23.2. Suspend fix not applied."
            fi
        fi
    fi
fi

### Part 4: Apply SELinux policies
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
    echo "Applying SELinux policies..."
    sudo cp -rvf mm_FccUnlock.cil "${INSTALL_DIR}"
    sudo cp -rvf mm_dmidecode.cil "${INSTALL_DIR}"
    sudo cp -rvf mm_sh.cil "${INSTALL_DIR}"
    sudo semodule -i "${INSTALL_DIR}"/*.cil

    ### ModemManager runs as modemmanager_t. It may only execute helpers labeled
    ### bin_t and map libraries labeled lib_t. Files freshly created under /var
    ### default to var_t, which modemmanager_t is NOT allowed to execute:
    ###   avc: denied { execute } ... comm="<vid:pid>" ... tcontext=...:var_t
    ### Register durable file-context rules and relabel so the labels survive a
    ### policy relabel / reboot.
    if command -v semanage >/dev/null 2>&1; then
        echo "Registering SELinux file contexts for ${INSTALL_DIR}..."
        sudo semanage fcontext -a -t bin_t "${INSTALL_DIR}/DPR_Fcc_unlock_service" 2>/dev/null \
            || sudo semanage fcontext -m -t bin_t "${INSTALL_DIR}/DPR_Fcc_unlock_service"
        sudo semanage fcontext -a -t bin_t "${INSTALL_DIR}/configservice_lenovo" 2>/dev/null \
            || sudo semanage fcontext -m -t bin_t "${INSTALL_DIR}/configservice_lenovo"
        sudo semanage fcontext -a -t lib_t "${INSTALL_DIR}/lib(/.*)?" 2>/dev/null \
            || sudo semanage fcontext -m -t lib_t "${INSTALL_DIR}/lib(/.*)?"
        sudo restorecon -R "${INSTALL_DIR}"
    else
        echo "Warning: semanage not found. Applying labels with chcon (not relabel-durable)."
        sudo chcon -t bin_t "${INSTALL_DIR}/DPR_Fcc_unlock_service" "${INSTALL_DIR}/configservice_lenovo"
        sudo chcon -t lib_t "${INSTALL_DIR}"/lib/*.so* 2>/dev/null || true
    fi
else
    echo "SELinux disabled; skipping SELinux policy + labeling."
fi

### Part 5: Finalizing
if [ "$restart_mm_service" == "true" ]
then
    echo "Reloading systemd and restarting ModemManager..."
    sudo systemctl daemon-reload
    sudo systemctl restart ModemManager
fi

### Part 6: Check persisted WWAN rfkill state (ThinkPad)
### A persisted value of 0 makes systemd-rfkill re-block WWAN at every boot,
### which ModemManager reports as "software radio switch is OFF".
RFKILL_STORE="/var/lib/systemd/rfkill/platform-thinkpad_acpi:wwan"
if [ -f "$RFKILL_STORE" ]; then
    RFKILL_VAL=$(cat "$RFKILL_STORE" 2>/dev/null || echo "")
    if [ "$RFKILL_VAL" = "0" ]; then
        echo "Warning: persisted WWAN rfkill is blocked (0)."
        echo "This can cause 'software radio switch is OFF' even if rfkill shows unblocked."
        echo "Applying fix..."
        sudo sh -c 'echo 1 > /var/lib/systemd/rfkill/platform-thinkpad_acpi:wwan'
        sudo systemctl restart systemd-rfkill
        echo "Fix applied."
    fi
fi

echo "Setup complete. A reboot is recommended."

### Exit script
exit 0
