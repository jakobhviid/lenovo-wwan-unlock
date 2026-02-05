#! /bin/bash

### Insure the working directory is the same as the script
pushd "$(dirname "$0")" &> /dev/null || exit 1
trap "popd &> /dev/null" EXIT

echo "Setting up WWAN unlock for Fedora Silverblue..."

### Part 1: Copy files to writable locations

echo "Copying files and libraries to /opt/fcc_lenovo..."

sudo mkdir -p /opt/fcc_lenovo/lib

### Copy main binaries and libraries
sudo cp -rvf DPR_Fcc_unlock_service /opt/fcc_lenovo/
sudo cp -rvf configservice_lenovo /opt/fcc_lenovo/
sudo cp -rvf libmodemauth.so /opt/fcc_lenovo/lib/
sudo cp -rvf libmodemauth.so.1.1 /opt/fcc_lenovo/lib/
sudo cp -rvf libconfigserviceR+.so /opt/fcc_lenovo/lib/
sudo cp -rvf libconfigservice350.so /opt/fcc_lenovo/lib/
sudo cp -rvf libconfigservice350.so.1.1 /opt/fcc_lenovo/lib/
sudo cp -rvf libmbimtools.so /opt/fcc_lenovo/lib/

### Copy SAR config files
sudo tar -zxf sar_config_files.tar.gz -C /opt/fcc_lenovo/

### Grant permissions to all binaries and scripts
sudo chmod ugo+x /opt/fcc_lenovo/*

### Part 2: Configure system integrations

### Create ModemManager fcc-unlock.d directory in /etc
echo "Configuring ModemManager..."
sudo mkdir -p /etc/ModemManager/fcc-unlock.d
sudo tar -zxf fcc-unlock.d.tar.gz -C /etc/ModemManager/fcc-unlock.d/
sudo chmod ugo+x /etc/ModemManager/fcc-unlock.d/*
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

### Configure dynamic linker to find our libraries
echo "Configuring dynamic linker..."
sudo bash -c 'echo "/opt/fcc_lenovo/lib" > /etc/ld.so.conf.d/fcc-lenovo.conf'
sudo ldconfig

### Install and enable the SAR config service
echo "Configuring systemd services..."
sudo cp -rvf lenovo-cfgservice.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable lenovo-cfgservice

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
echo "Applying SELinux policies..."
sudo cp -rvf mm_FccUnlock.cil /opt/fcc_lenovo
sudo cp -rvf mm_dmidecode.cil /opt/fcc_lenovo
sudo cp -rvf mm_sh.cil /opt/fcc_lenovo
sudo semodule -i /opt/fcc_lenovo/*.cil

### Part 5: Finalizing
if [ "$restart_mm_service" == "true" ]
then
    echo "Reloading systemd and restarting ModemManager..."
    sudo systemctl daemon-reload
    sudo systemctl restart ModemManager
fi

echo "Setup complete. A reboot is recommended."

### Exit script
exit 0
