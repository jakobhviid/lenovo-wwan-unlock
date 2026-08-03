#! /bin/bash

echo "Uninstalling WWAN unlock package from Fedora Silverblue / Kinoite / Bazzite..."

INSTALL_DIR="/var/fcc_lenovo"

### Part 1: Remove system integrations

### Remove ModemManager suspend fix
echo "Removing ModemManager suspend fix..."
sudo rm -f /etc/systemd/system/ModemManager.service.d/10-wwan-unlock.conf

### Remove dynamic linker configuration
echo "Removing dynamic linker configuration..."
sudo rm -f /etc/ld.so.conf.d/fcc-lenovo.conf
sudo ldconfig

### Disable and remove the SAR config service and FCC unlock service
echo "Disabling and removing systemd services..."
sudo systemctl disable --now lenovo-cfgservice
sudo rm -f /etc/systemd/system/lenovo-cfgservice.service
sudo systemctl disable --now lenovo-fcc-unlock
sudo rm -f /etc/systemd/system/lenovo-fcc-unlock.service

### Remove suspend/resume hook
echo "Removing FCC unlock suspend/resume hook..."
sudo rm -f /etc/systemd/system-sleep/lenovo-fcc-unlock-resume.sh

### Reload systemd to apply changes
echo "Reloading systemd..."
sudo systemctl daemon-reload

### Part 2: Remove files and policies

### Remove SELinux policies and file-context rules
# The .cil files live in ${INSTALL_DIR}, so remove the modules before the dir.
if [ -f "${INSTALL_DIR}/mm_FccUnlock.cil" ]; then
    echo "Removing SELinux policies..."
    # The module name is the cil file name without the extension
    sudo semodule -r mm_FccUnlock
    sudo semodule -r mm_dmidecode
    sudo semodule -r mm_sh
fi
if command -v semanage >/dev/null 2>&1; then
    echo "Removing SELinux file-context rules..."
    sudo semanage fcontext -d "${INSTALL_DIR}/DPR_Fcc_unlock_service" 2>/dev/null || true
    sudo semanage fcontext -d "${INSTALL_DIR}/configservice_lenovo" 2>/dev/null || true
    sudo semanage fcontext -d "${INSTALL_DIR}/lib(/.*)?" 2>/dev/null || true
fi

### Remove ModemManager scripts
echo "Removing ModemManager scripts..."
sudo rm -rf /etc/ModemManager/fcc-unlock.d

### Remove all installed files
echo "Removing files from ${INSTALL_DIR}..."
sudo rm -rf "${INSTALL_DIR}"

echo "Uninstallation complete."
echo "If you need to verify state, run: ./verify_install.sh"

### Exit script
exit 0
