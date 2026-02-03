#! /bin/bash

## Silverblue-compatible suspend fix for ModemManager
## Applies a systemd drop-in instead of modifying /usr/lib.

set -euo pipefail

STRING_LOW_POWER=" --test-low-power-suspend-resume"
SERVICE_DROPIN_DIR="/etc/systemd/system/ModemManager.service.d"
SERVICE_DROPIN_PATH="${SERVICE_DROPIN_DIR}/10-wwan-unlock.conf"

Rplus_check=$(/usr/sbin/lspci -d :7560)
FM350_check=$(/usr/sbin/lspci -d :4d75)
RM520_check=$(/usr/sbin/lspci -d :1007)
EM160R_check=$(/usr/sbin/lspci -d :100d)

restart_mm_service=false

function version_ge() { test "$(echo "$@" | tr " " "\n" | sort -rV | head -n 1)" == "$1"; }

if [ -n "$Rplus_check" ] || [ -n "$FM350_check" ] || [ -n "$RM520_check" ] || [ -n "$EM160R_check" ]; then
    curmmver=$(mmcli -V)
    first_line=${curmmver%%$'\n'*}
    curmmvernum=$(echo "$first_line" | cut -d " " -f2)
    stand_ver="1.23.2"

    if version_ge "$curmmvernum" "$stand_ver"; then
        sudo mkdir -p "$SERVICE_DROPIN_DIR"
        sudo bash -c "printf '[Service]\nExecStart=\nExecStart=/usr/sbin/ModemManager%s\n' '${STRING_LOW_POWER}' > '${SERVICE_DROPIN_PATH}'"
        restart_mm_service=true
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
