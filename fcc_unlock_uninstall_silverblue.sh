#! /bin/bash

echo "Uninstalling WWAN unlock package from Fedora Silverblue..."

### Part 1: Remove system integrations

### Remove ModemManager suspend fix
echo "Removing ModemManager suspend fix..."
sudo rm -f /etc/systemd/system/ModemManager.service.d/10-wwan-unlock.conf

### Remove dynamic linker configuration
echo "Removing dynamic linker configuration..."
sudo rm -f /etc/ld.so.conf.d/fcc-lenovo.conf
sudo ldconfig

### Disable and remove the SAR config service
echo "Disabling and removing systemd service..."
sudo systemctl disable --now lenovo-cfgservice
sudo rm -f /etc/systemd/system/lenovo-cfgservice.service

### Reload systemd to apply changes
echo "Reloading systemd..."
sudo systemctl daemon-reload

### Part 2: Remove files and policies

### Remove SELinux policies
# The .cil files are in /opt/fcc_lenovo, so we do this before removing that directory
if [ -d "/opt/fcc_lenovo" ] && [ -f "/opt/fcc_lenovo/mm_FccUnlock.cil" ]; then
    echo "Removing SELinux policies..."
    # The module name is the same as the cil file name without the extension
    sudo semodule -r mm_FccUnlock
    sudo semodule -r mm_dmidecode
    sudo semodule -r mm_sh
fi

### Remove ModemManager scripts
echo "Removing ModemManager scripts..."
sudo rm -rf /etc/ModemManager/fcc-unlock.d

### Remove all installed files
echo "Removing files from /opt/fcc_lenovo..."
sudo rm -rf /opt/fcc_lenovo

echo "Uninstallation complete."
echo "If you need to verify state, run: ./verify_install.sh"

### Exit script
exit 0
