#!/bin/sh
# volume-sync: Soloist follows Alice's volume (busybox sh).
# The station keeps one volume for Alice (0-20, buttons, "Алиса, громче",
# the Yandex app) in $ALICE_VOLUME_FILE and applies it only to its own
# player; Soloist has a separate one. Once a second this watcher reads
# Alice's level and, when it changed, sets Soloist to the same share
# (15 of 20 -> 75 of 100; muted -> 0). The start value is passed by
# run-soloist.sh as -i. The Spotify app's own slider still works until
# Alice's volume changes next time.
O=$(cd "$(dirname "$0")" && pwd)
. "$O/lib.sh"
VSLOG="$RUN/volume.log"
mkdir -p "$RUN"

log() { log_to "$VSLOG" "$@"; }

trap 'end_nap; log "volume sync stop"; exit 0' INT TERM

log "volume sync start"
last=$(alice_volume)
while :; do
    nap 1
    v=$(alice_volume) || continue
    [ "$v" = "$last" ] && continue
    # Soloist answers ctl only once it is up; keep "last" so we retry
    if ldr "$O/bin/soloist" ctl volume "$v" -D "$O/data" > /dev/null 2>&1; then
        log "alice volume -> soloist $v"
        last=$v
    fi
done
