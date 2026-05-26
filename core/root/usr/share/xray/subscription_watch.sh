#!/bin/sh

UPDATER="/usr/share/xray/subscription_update.sh"

while true; do
    sleep 60

    output="$(${UPDATER} due 2>&1)"
    case "${output}" in
        *changed=1*)
            logger -st xray-subscription[$$] -p4 "subscription nodes changed; reloading xray_core"
            ( sleep 1; /etc/init.d/xray_core reload >/dev/null 2>&1 ) &
            exit 0
            ;;
    esac
done
