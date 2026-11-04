#!/bin/sh
# Run on JBL Link Portable with Alice through an explicitly selected root ADB.
# Tested firmware: 1.80.0.228.3676569159.20251219. See the access guide.
# This creates immutable network ADB markers; it never overwrites their contents.
set -eu

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

[ "$(id -u)" = 0 ] || fail 'Root shell required'
[ -f /system/vendor/quasar/activate_adb.sh ] || fail 'Missing quasar ADB script'
grep -Fq /tmp/lock_activated_adb /system/vendor/quasar/activate_adb.sh ||
    fail 'USB lock marker is not recognized by this firmware'
grep -aFq /data/network_adb /usr/bin/adbd ||
    fail 'Network ADB marker is not recognized by this binary'
command -v chattr >/dev/null 2>&1 || fail 'chattr is unavailable'

# Validate every target before making any changes.
for marker in /tmp/lock_activated_adb /data/network_adb /data/quasar_activate_adb; do
    [ ! -L "$marker" ] || fail "Refusing symlink: $marker"
    if [ -e "$marker" ]; then
        [ -f "$marker" ] || fail "Not a regular file: $marker"
        [ ! -s "$marker" ] || fail "Refusing nonempty marker: $marker"
    fi
done

# Skip existing files: immutable markers cannot be touched again.
for marker in /tmp/lock_activated_adb /data/network_adb /data/quasar_activate_adb; do
    if [ ! -e "$marker" ]; then
        touch "$marker"
    fi
done
chattr +i /data/network_adb /data/quasar_activate_adb
sync
id
echo JBL_ROOT_ENABLED
