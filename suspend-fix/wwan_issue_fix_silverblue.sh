#! /bin/bash

## Silverblue-compatible suspend fix for ModemManager
## Applies a systemd drop-in instead of modifying /usr/lib.

STRING_LOW_POWER=" --test-low-power-suspend-resume"
SERVICE_DROPIN_DIR="/etc/systemd/system/ModemManager.service.d"
SERVICE_DROPIN_PATH="${SERVICE_DROPIN_DIR}/10-wwan-unlock.conf"

restart_mm_service=false

function version_ge() { test "$(echo "$@" | tr " " "\n" | sort -rV | head -n 1)" == "$1"; }

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
    exit 0
fi

Rplus_check=$("$LSPCI_BIN" -d :7560)
FM350_check=$("$LSPCI_BIN" -d :4d75)
RM520_check=$("$LSPCI_BIN" -d :1007)
EM160R_check=$("$LSPCI_BIN" -d :100d)

if [ -n "$Rplus_check" ] || [ -n "$FM350_check" ] || [ -n "$RM520_check" ] || [ -n "$EM160R_check" ]; then
    if ! command -v mmcli >/dev/null 2>&1; then
        echo "Warning: mmcli not found. Skipping suspend fix."
        exit 0
    fi

    curmmver=$(mmcli -V)
    first_line=${curmmver%%$'\n'*}
    curmmvernum=$(echo "$first_line" | cut -d " " -f2)
    stand_ver="1.23.2"

    if version_ge "$curmmvernum" "$stand_ver"; then
        exec_start_cmd=$(get_mm_execstart)
        if printf '%s' "$exec_start_cmd" | grep -q -- '--test-low-power-suspend-resume'; then
            echo "test-low-power-suspend-resume parameter already exists"
        else
            sudo mkdir -p "$SERVICE_DROPIN_DIR"
            printf '[Service]\nExecStart=\nExecStart=%s%s\n' "$exec_start_cmd" "$STRING_LOW_POWER" | sudo tee "$SERVICE_DROPIN_PATH" >/dev/null
            restart_mm_service=true
        fi
    else
        echo "Fix supports ModemManager version 1.23.2 or later only."
    fi
else
    echo "Issue Fix is only applicable for Fibocom L860-GL-16/FM350 and Quectel EM160R-GL/RM520N-GL WWAN module."
fi

if [ "$restart_mm_service" == "true" ]; then
    sudo systemctl daemon-reload
    sudo systemctl restart ModemManager
fi
