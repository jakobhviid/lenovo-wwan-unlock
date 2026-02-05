#!/usr/bin/env bash

set -euo pipefail

FIX_RFKILL=false
if [ "${1:-}" = "--fix-rfkill" ]; then
    FIX_RFKILL=true
fi

printf '%s\n' "WWAN unlock verification"

hook_dir_etc="/etc/ModemManager/fcc-unlock.d"
if [ -d "$hook_dir_etc" ]; then
    printf '%s\n' "- Hooks dir: $hook_dir_etc"
    hook_files=$(find "$hook_dir_etc" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "$hook_files" -eq 0 ]; then
        printf '%s\n' "  Warning: no hook files found in $hook_dir_etc"
    fi
    if [ -d "$hook_dir_etc/fcc-unlock.d" ]; then
        printf '%s\n' "  Warning: nested fcc-unlock.d directory detected ($hook_dir_etc/fcc-unlock.d)"
    fi
else
    printf '%s\n' "- Hooks dir: $hook_dir_etc (missing)"
fi

printf '%s' "- ModemManager present: "
if command -v ModemManager >/dev/null 2>&1; then
    printf '%s\n' "yes"
else
    printf '%s\n' "no"
fi

printf '%s' "- Modems: "
if command -v mmcli >/dev/null 2>&1; then
    mmcli -L || true
else
    printf '%s\n' "mmcli not found"
fi

printf '%s' "- Device nodes: "
ls -l /dev/wwan* 2>/dev/null || printf '%s\n' "none"

printf '%s' "- rfkill: "
if command -v rfkill >/dev/null 2>&1; then
    rfkill list || true
else
    printf '%s\n' "rfkill not found"
fi

printf '%s' "- systemd-rfkill (persisted state): "
rfkill_store="/var/lib/systemd/rfkill/platform-thinkpad_acpi:wwan"
if [ -f "$rfkill_store" ]; then
    cat "$rfkill_store" || true
    if [ "$(cat "$rfkill_store" 2>/dev/null)" = "0" ]; then
        printf '%s\n' "  Warning: persisted WWAN rfkill is blocked (0). This can cause 'software radio switch is OFF'."
        if $FIX_RFKILL; then
            printf '%s\n' "  Applying fix..."
            if command -v sudo >/dev/null 2>&1; then
                sudo sh -c 'echo 1 > /var/lib/systemd/rfkill/platform-thinkpad_acpi:wwan'
                sudo systemctl restart systemd-rfkill
            else
                sh -c 'echo 1 > /var/lib/systemd/rfkill/platform-thinkpad_acpi:wwan'
                systemctl restart systemd-rfkill
            fi
            printf '%s\n' "  Fix applied."
        else
            printf '%s\n' "  Fix: ./verify_install.sh --fix-rfkill"
            printf '%s\n' "  Or:  sudo sh -c 'echo 1 > /var/lib/systemd/rfkill/platform-thinkpad_acpi:wwan' && sudo systemctl restart systemd-rfkill"
        fi
    fi
else
    printf '%s\n' "not found"
fi

printf '%s' "- NetworkManager radio: "
if command -v nmcli >/dev/null 2>&1; then
    nmcli radio || true
else
    printf '%s\n' "nmcli not found"
fi

printf '%s\n' "- ModemManager recent logs (last 50 lines):"
if command -v journalctl >/dev/null 2>&1; then
    journalctl -u ModemManager -b | tail -n 50 || true
else
    printf '%s\n' "journalctl not found"
fi

printf '%s\n' ""
printf '%s\n' "If ModemManager shows no modems but /dev/wwan* exists, try:"
printf '%s\n' "  sudo udevadm trigger -c add -s mhi -s wwan && sudo udevadm settle"

if [ -e /dev/wwan0mbim0 ] && command -v mmcli >/dev/null 2>&1; then
    if ! mmcli -L 2>/dev/null | grep -q '/org/freedesktop/ModemManager1/Modem'; then
        printf '%s' ""
        printf '%s' "Modems not detected but /dev/wwan* exists. Re-trigger udev now? [y/N]: "
        read -r reply
        if [ "$reply" = "y" ] || [ "$reply" = "Y" ]; then
            if command -v sudo >/dev/null 2>&1; then
                sudo udevadm trigger -c add -s mhi -s wwan
                sudo udevadm settle
            else
                udevadm trigger -c add -s mhi -s wwan
                udevadm settle
            fi
            mmcli -L || true
        fi
    fi
fi
