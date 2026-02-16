#!/bin/bash
# systemd system-sleep hook to re-run FCC unlock after resume
if [ "$1" = "post" ]; then
    for i in $(seq 1 30); do
        [ -c /dev/wwan0mbim0 ] && break
        sleep 1
    done
    /opt/fcc_lenovo/DPR_Fcc_unlock_service
fi
