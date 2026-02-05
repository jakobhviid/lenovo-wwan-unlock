#! /bin/bash

### Insure the working directory is the same as the script
pushd "$(dirname "$0")" &> /dev/null || exit 1
trap "popd &> /dev/null" EXIT

### Detect Fedora Silverblue/Kinoite/Bazzite (and other atomic variants) and defer
if [ -f /etc/os-release ]; then
    . /etc/os-release
    VARIANT_ID_LOWER=$(printf "%s" "${VARIANT_ID:-}" | tr '[:upper:]' '[:lower:]')
    ID_LOWER=$(printf "%s" "${ID:-}" | tr '[:upper:]' '[:lower:]')
    if { [ "$ID_LOWER" = "fedora" ] || [ "$ID_LOWER" = "bazzite" ]; } && \
       { [ "$VARIANT_ID_LOWER" = "silverblue" ] || [ "$VARIANT_ID_LOWER" = "kinoite" ] || [ "$VARIANT_ID_LOWER" = "bazzite" ]; }; then
        echo "Detected Fedora atomic variant (${ID:-unknown}/${VARIANT_ID:-unknown}). Deferring to Silverblue setup script..."
        exec "$(dirname "$0")/fcc_unlock_setup_silverblue.sh"
    fi
fi

echo "Copying files and libraries..."

if [ ! -d "/opt/fcc_lenovo" ]
then
        sudo mkdir /opt/fcc_lenovo
fi

if [ ! -d "/opt/fcc_lenovo/lib" ]
then
        sudo mkdir /opt/fcc_lenovo/lib
fi

### Identify current OS
OS_UBUNTU="Ubuntu"
OS_FEDORA="Fedora"

source /etc/os-release
echo $NAME

if [[ "$NAME" == *"$OS_UBUNTU"* ]]
then
	### Copy fcc unlock script for MM
	sudo mkdir -p /usr/lib/x86_64-linux-gnu/ModemManager/fcc-unlock.d
	sudo tar -zxf fcc-unlock.d.tar.gz -C /usr/lib/x86_64-linux-gnu/ModemManager/fcc-unlock.d --strip-components=1
	sudo find /usr/lib/x86_64-linux-gnu/ModemManager/fcc-unlock.d -name '._*' -delete
	sudo chmod ugo+x /usr/lib/x86_64-linux-gnu/ModemManager/fcc-unlock.d/*
	echo "Validating FCC unlock hook installation..."
	if [ -d /usr/lib/x86_64-linux-gnu/ModemManager/fcc-unlock.d/fcc-unlock.d ]; then
		echo "Warning: Nested fcc-unlock.d directory detected."
	fi
	if ! find /usr/lib/x86_64-linux-gnu/ModemManager/fcc-unlock.d -maxdepth 1 -type f | grep -q .; then
		echo "Warning: No FCC unlock hook files found in /usr/lib/x86_64-linux-gnu/ModemManager/fcc-unlock.d."
	fi

	### Copy SAR config files
	sudo tar -zxf sar_config_files.tar.gz -C /opt/fcc_lenovo/

	### Copy libraries
	sudo cp -rvf libmodemauth.so /opt/fcc_lenovo/lib/
	sudo cp -rvf libmodemauth.so.1.1 /opt/fcc_lenovo/lib/
	sudo cp -rvf libconfigserviceR+.so /opt/fcc_lenovo/lib/
	sudo cp -rvf libconfigservice350.so /opt/fcc_lenovo/lib/
	sudo cp -rvf libconfigservice350.so.1.1 /opt/fcc_lenovo/lib/
	sudo cp -rvf libmbimtools.so /opt/fcc_lenovo/lib/

elif [[ "$NAME" == *"$OS_FEDORA"* ]]
then
	### Copy fcc unlock script for MM
	sudo mkdir -p /usr/lib64/ModemManager/fcc-unlock.d
	sudo tar -zxf fcc-unlock.d.tar.gz -C /usr/lib64/ModemManager/fcc-unlock.d --strip-components=1
	sudo find /usr/lib64/ModemManager/fcc-unlock.d -name '._*' -delete
	sudo chmod ugo+x /usr/lib64/ModemManager/fcc-unlock.d/*
	echo "Validating FCC unlock hook installation..."
	if [ -d /usr/lib64/ModemManager/fcc-unlock.d/fcc-unlock.d ]; then
		echo "Warning: Nested fcc-unlock.d directory detected."
	fi
	if ! find /usr/lib64/ModemManager/fcc-unlock.d -maxdepth 1 -type f | grep -q .; then
		echo "Warning: No FCC unlock hook files found in /usr/lib64/ModemManager/fcc-unlock.d."
	fi

	### Copy SAR config files
	sudo tar -zxf sar_config_files.tar.gz -C /opt/fcc_lenovo/

	ln -s /usr/sbin/lspci /usr/bin/lspci

	### Copy libraries
	sudo cp -rvf libmodemauth.so /opt/fcc_lenovo/lib/
	sudo cp -rvf libmodemauth.so.1.1 /opt/fcc_lenovo/lib/
	sudo cp -rvf libconfigserviceR+.so /opt/fcc_lenovo/lib/
	sudo cp -rvf libconfigservice350.so /opt/fcc_lenovo/lib/
	sudo cp -rvf libconfigservice350.so.1.1 /opt/fcc_lenovo/lib/
	sudo cp -rvf libmbimtools.so /opt/fcc_lenovo/lib/

	### Copy files for selinux for fedora
	sudo cp -rvf mm_FccUnlock.cil /opt/fcc_lenovo
	sudo cp -rvf mm_dmidecode.cil /opt/fcc_lenovo
	sudo cp -rvf mm_sh.cil /opt/fcc_lenovo
	sudo semodule -i /opt/fcc_lenovo/*.cil

else
    echo "No need to copy files"
    exit 0
fi

### Copy binary
sudo cp -rvf DPR_Fcc_unlock_service /opt/fcc_lenovo/
sudo cp -rvf configservice_lenovo /opt/fcc_lenovo/

## copy and enable service
sudo cp -rvf lenovo-cfgservice.service /etc/systemd/system/.
sudo systemctl daemon-reload
systemctl enable lenovo-cfgservice

### Grant permissions to all binaries and script
sudo chmod ugo+x /opt/fcc_lenovo/*

### Below mentioned script is executed to fix issues related to WWAN.
### Issue List:
### 1) System sometimes wake up during suspend mode, while using Fibocom
###    L860-GL-16/FM350 and Quectel EM160R-GL/RM520N-GL WWAN module.
sudo chmod ugo+x suspend-fix/wwan_issue_fix.sh
suspend-fix/wwan_issue_fix.sh

### Check persisted WWAN rfkill state (ThinkPad)
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


## Please reboot machine (this will be needed only one for time)##

### Exit script
exit 0
