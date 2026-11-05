#!/bin/sh
# Block new downloads into the configured OTA directory, without recursion.
# Tested on JBL Link Portable with Alice, 1.80.0.228.3676569159.20251219.
# Pass disable to remove the attribute; only the script's own probe is deleted.
set -eu

DIR=/bkupgrade
fail() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || fail 'Root required'
[ -d "$DIR" ] && [ ! -L "$DIR" ] || fail 'Unexpected OTA directory'
grep -Eq '"updatesDir"[[:space:]]*:[[:space:]]*"/bkupgrade"' \
    /system/vendor/quasar/quasar.cfg || fail 'Different OTA download directory'

check_writer() {
    if pidof a01localupdate updater_switcher >/dev/null 2>&1; then
        fail 'OTA writer is running'
    fi
}

check_downloads() {
    # Only the known vendor runtime directory may be present at the top level.
    for entry in "$DIR"/* "$DIR"/.[!.]* "$DIR"/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        [ "$entry" = "$DIR/wiimu" ] && [ -d "$entry" ] && [ ! -L "$entry" ] ||
            fail 'Unexpected entry in OTA directory; inspect before enabling'
    done
    if find "$DIR" -maxdepth 3 -type f | grep -Ei '\.(img|zip|swu)$' >/dev/null; then
        fail 'Potential downloaded OTA image found'
    fi
}

probe_write() {
    probe="$DIR/.jbl-ota-write-probe-$$"
    [ ! -e "$probe" ] && [ ! -L "$probe" ] || fail 'Probe path already exists'
    # noclobber prevents replacing a file created between the check and open.
    if (set -C; : > "$probe") 2>/dev/null; then
        rm "$probe"
        return 0
    fi
    return 1
}

case "${1:-status}" in
    enable)
        check_writer
        check_downloads
        chattr +i "$DIR"
        sync
        if probe_write; then fail 'Directory is still writable'; fi
        echo JBL_OTA_DIRECTORY_BLOCKED
        ;;
    status)
        if probe_write; then
            echo JBL_OTA_DIRECTORY_WRITABLE
            exit 2
        fi
        echo JBL_OTA_DIRECTORY_BLOCKED
        ;;
    disable)
        check_writer
        chattr -i "$DIR"
        sync
        if ! probe_write; then fail 'Directory is still not writable'; fi
        echo JBL_OTA_DIRECTORY_WRITABLE
        ;;
    *) fail 'Usage: ota-guard.sh enable|status|disable' ;;
esac
