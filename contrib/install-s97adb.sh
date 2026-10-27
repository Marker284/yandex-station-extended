#!/bin/sh
# Host-side helper for the native /data/quasar ADB markers (Buildroot stations).
# Uses the mechanism documented in start/ssh.md, not a missing S97adb payload.
# Requires existing root ADB. Does not reboot or change /etc/init.d.
# Hardware verification of this wrapper is pending; see model-specific limitations.
# Undo: chattr -i both markers, then remove them; keep another working entry point.
set -eu
# Git Bash must not rewrite absolute paths passed to the Android device.
export MSYS_NO_PATHCONV=1

[ "$#" = 1 ] || { echo "Usage: sh install-s97adb.sh <station-ip>" >&2; exit 2; }
IP=$1
case "$IP" in ''|*[!0-9.]*) echo 'Expected an IPv4 address.' >&2; exit 2 ;; esac
SER=$IP:5555
command -v adb >/dev/null 2>&1 || { echo 'adb not found' >&2; exit 1; }
adb connect "$SER"
[ "$(adb -s "$SER" shell id -u | tr -d '\r\n')" = 0 ] || {
    echo 'Root ADB is required.' >&2; exit 1
}
adb -s "$SER" shell 'set -eu
    [ -f /system/vendor/quasar/activate_adb.sh ] || {
        echo "Native Buildroot ADB activation script is missing." >&2; exit 1
    }
    command -v chattr >/dev/null 2>&1
    mkdir -p /data/quasar
    touch /data/quasar/activate_adb_quasmodrom /data/quasar/activate_network_adb
    chattr +i /data/quasar/activate_adb_quasmodrom /data/quasar/activate_network_adb
    sync'
echo '[+] Native ADB markers created and protected; no reboot was performed.'
echo "After a manual reboot, verify: adb connect $SER; adb -s $SER shell id"
echo 'Cloud deactivation/model-specific boot logic may still disable ADB; see start/ssh.md.'
