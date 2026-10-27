#!/bin/sh
# Host-side wrapper for packages/librespot-micro-installer.zip (Lite/Micro only).
# Requires an already rooted station and adb; does not unlock or reboot it.
# Default: check hardware/package without installing. Playback is not verified here.
# Rollback: follow README.txt in the package; keep its ALSA backup outside the station.
set -eu
# Git Bash must not rewrite absolute paths passed to the Android device.
export MSYS_NO_PATHCONV=1

usage() {
    echo "Usage: sh spotify.sh <adb-serial> [--check|--install]" >&2
    echo "Only Yandex Station Micro v1.2; not Mini 2. Spotify Premium is required." >&2
}
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage; exit 2; }
SERIAL=$1
MODE=${2:---check}
case "$SERIAL" in ''|-*|*[!a-zA-Z0-9_.:-]*) usage; exit 2 ;; esac
case "$MODE" in --check|--install) ;; *) usage; exit 2 ;; esac
for cmd in adb unzip mktemp; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Missing command: $cmd" >&2; exit 1; }
done
BASE=$(CDPATH= cd "$(dirname "$0")" && pwd)
PACKAGE=$BASE/packages/librespot-micro-installer.zip
[ -s "$PACKAGE" ] || { echo "Package not found: $PACKAGE" >&2; exit 1; }

# Select a device explicitly: never fall back to another connected station.
[ "$(adb -s "$SERIAL" get-state | tr -d '\r\n')" = device ] || exit 1
MODEL=$(adb -s "$SERIAL" shell 'cat /proc/device-tree/model' | tr -d '\000\r\n')
[ "$MODEL" = 'Yandex Station Micro v1.2' ] || {
    echo "Unsupported model: $MODEL. The bundled audio configuration is Micro-only." >&2
    exit 1
}

STAGE=$(mktemp -d)
REMOTE=
cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    if [ -n "$REMOTE" ]; then
        adb -s "$SERIAL" shell "rm -rf '$REMOTE'" >/dev/null 2>&1 || true
    fi
    rm -rf "$STAGE"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
unzip -q "$PACKAGE" -d "$STAGE"
# mktemp prevents collisions with another installation/check on the station.
REMOTE=$(adb -s "$SERIAL" shell 'mktemp -d /data/local/tmp/librespot-check.XXXXXX' | tr -d '\r\n')
case "$REMOTE" in
    /data/local/tmp/librespot-check.*)
        suffix=${REMOTE#/data/local/tmp/librespot-check.}
        case "$suffix" in ''|*[!a-zA-Z0-9]*) REMOTE=; exit 1 ;; esac ;;
    *) REMOTE=; echo 'Cannot create remote staging directory.' >&2; exit 1 ;;
esac
adb -s "$SERIAL" push "$STAGE/." "$REMOTE/" >/dev/null
# The package checks root, SHA256SUMS, hardware, existing installs and free space.
adb -s "$SERIAL" shell "sh '$REMOTE/install.sh' --check"
if [ "$MODE" = --install ]; then
    adb -s "$SERIAL" shell "sh '$REMOTE/install.sh' --install"
fi
