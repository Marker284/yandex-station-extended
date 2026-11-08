#!/bin/sh
# install.sh - put a staged Soloist kit in place on Yandex Station Lite 1 (busybox sh).
# Normally run by deploy.py from the PC; by hand:
#   sh /bkupgrade/data/local/opt/soloist.new/install.sh [--no-start] [--keep-old]
# The kit must already be in the staging dir (this script's dir).
# Before anything changes: MANIFEST.sha256 check, trial run of soloist and
# pulseaudio --version from the staging dir, key and settings carried over.
# Then: stop the running service -> copy data/ (Spotify login) -> swap the
# directories -> back up and replace /etc/init.d/S97soloist (rootfs rw only for
# the copy, read-only again is checked) -> start. Any failure after the stop
# rolls back: old directory, old init script, rootfs read-only, old service
# started again. Exit 1 = failed and rolled back, 2 = rollback incomplete.
set -u
STAGE=$(cd "$(dirname "$0")" && pwd)
TARGET=${TARGET:-/bkupgrade/data/local/opt/soloist}
INIT_DIR=${INIT_DIR:-/etc/init.d}
ROOT_MOUNTS=${ROOT_MOUNTS:-/proc/mounts}
START=1; KEEP_OLD=""
for a; do
    case "$a" in
        --no-start) START="" ;;
        --keep-old) KEEP_OLD=1 ;;
        *) echo "usage: install.sh [--no-start] [--keep-old]" >&2; exit 2 ;;
    esac
done
INIT="$INIT_DIR/S97soloist"
OLD="$TARGET.old"
INIT_BAK="$TARGET.S97soloist.prev"
LOCK="$TARGET.lock"
WAS_RUNNING=""; OLD_MOVED=""; NEW_IN=""; INIT_TOUCHED=""; INIT_EXISTED=""; ROOT_WAS_RO=""

say() { echo "install: $*"; }
die() { say "ERROR: $*"; exit 1; }

root_opts() { awk '$2 == "/" { o = $4 } END { print o }' "$ROOT_MOUNTS"; }
root_is_ro() { case "$(root_opts)" in ro|ro,*) return 0 ;; esac; return 1; }

root_rw() {   # make rootfs writable if it is read-only
    root_is_ro || return 0
    mount -o remount,rw / && ! root_is_ro || { say "remount rw failed"; return 1; }
}

root_back() {   # read-only again if it was read-only before; 1 = still writable
    [ -n "$ROOT_WAS_RO" ] || return 0
    root_is_ro && return 0
    sync
    mount -o remount,ro / 2>/dev/null || { sleep 1; sync; mount -o remount,ro /; }
    root_is_ro && return 0
    say "rootfs is still read-write"
    return 1
}

put_init() {   # put_init FILE: copy FILE to $INIT, compare, rootfs back to ro
    root_rw || return 1
    INIT_TOUCHED=1
    ok=""
    cp "$1" "$INIT.new" && chmod 755 "$INIT.new" && mv -f "$INIT.new" "$INIT" && sync &&
        cmp -s "$1" "$INIT" && ok=1
    [ -n "$ok" ] || { rm -f "$INIT.new"; say "copy to $INIT failed"; }
    root_back || ok=""
    [ -n "$ok" ]
}

rm_init() {
    root_rw || return 1
    INIT_TOUCHED=1
    rm -f "$INIT"; sync
    root_back || return 1
    [ ! -e "$INIT" ]
}

carry() {   # carry FILE: from the old install unless the kit brings one
    [ -e "$STAGE/$1" ] || [ ! -e "$TARGET/$1" ] || cp -p "$TARGET/$1" "$STAGE/$1"
}

rollback() {
    say "rolling back"
    bad=""
    [ -n "$NEW_IN" ] && [ -x "$INIT" ] && "$INIT" stop > /dev/null 2>&1
    if [ -n "$NEW_IN" ]; then
        rm -rf "$TARGET.failed"
        mv "$TARGET" "$TARGET.failed" || { say "could not move the new kit away"; bad=1; }
    fi
    if [ -n "$OLD_MOVED" ]; then
        mv "$OLD" "$TARGET" || { say "could not put $OLD back to $TARGET"; bad=1; }
    fi
    if [ -n "$INIT_TOUCHED" ]; then
        if [ -n "$INIT_EXISTED" ]; then
            cmp -s "$INIT_BAK" "$INIT" 2>/dev/null || put_init "$INIT_BAK" ||
                { say "could not restore $INIT from $INIT_BAK"; bad=1; }
        elif [ -e "$INIT" ]; then
            rm_init || { say "could not remove $INIT"; bad=1; }
        fi
    fi
    root_back || { say "run by hand: mount -o remount,ro /"; bad=1; }
    if [ -n "$WAS_RUNNING" ] && [ -x "$INIT" ]; then
        "$INIT" start && say "old version started again" || { say "could not start the old version"; bad=1; }
    fi
    if [ -n "$bad" ]; then say "ERROR: rollback INCOMPLETE, see the lines above"; exit 2; fi
    [ -n "$NEW_IN" ] && say "the new kit is left in $TARGET.failed for a look"
    say "rollback done"
    exit 1
}

# --- 1. checks that change nothing on the running system ------------------------
[ "$(id -u)" = 0 ] || die "run as root"
[ "$STAGE" != "$TARGET" ] || die "run install.sh from the staging dir, not from $TARGET"
mkdir "$LOCK" 2>/dev/null || die "another install.sh is running (or remove a stale $LOCK)"
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
[ -s "$STAGE/MANIFEST.sha256" ] || die "no MANIFEST.sha256 in $STAGE"
( cd "$STAGE" && sha256sum -c MANIFEST.sha256 > /dev/null 2>&1 ) || die "kit does not match MANIFEST.sha256 (incomplete copy?)"
say "kit verified ($(wc -l < "$STAGE/MANIFEST.sha256") files)"
carry etc/api.key || die "could not copy etc/api.key from $TARGET"
carry etc/soloist.conf || die "could not copy etc/soloist.conf from $TARGET"
[ -s "$STAGE/etc/api.key" ] || die "no Soloist API key: give one to deploy.py (--key) or put it in $STAGE/etc/api.key"
chmod 600 "$STAGE/etc/api.key" || die "chmod api.key failed"
APLAY=$(O="$STAGE"; . "$STAGE/lib.sh"; echo "$APLAY")
[ -x "$APLAY" ] || die "$APLAY not found (the station's own player)"
chmod 755 "$STAGE"/*.sh "$STAGE/S97soloist" "$STAGE/bin/soloist" "$STAGE/bin/pulseaudio" \
    "$STAGE/lib/ld-linux-armhf.so.3" || die "chmod failed"
LD="$STAGE/lib/ld-linux-armhf.so.3"
v=$("$LD" --library-path "$STAGE/lib" "$STAGE/bin/soloist" --version 2>&1) ||
    die "soloist does not start from the kit: $v"
say "soloist --version: $v"
p=$("$LD" --library-path "$STAGE/lib" "$STAGE/bin/pulseaudio" --version 2>&1) ||
    die "pulseaudio does not start from the kit: $p"
say "pulseaudio --version: $p"
sed "s#@O@#$TARGET#" "$STAGE/S97soloist" > "$STAGE/S97soloist.tmp" &&
    mv -f "$STAGE/S97soloist.tmp" "$STAGE/S97soloist" && chmod 755 "$STAGE/S97soloist" ||
    die "could not prepare the init script"
root_is_ro && ROOT_WAS_RO=1

# --- 2. stop the old service (nothing changed yet if this fails) --------------------
if [ -x "$INIT" ] && "$INIT" status 2>/dev/null | grep -q "running:"; then
    WAS_RUNNING=1
    if ! "$INIT" stop; then
        "$INIT" start; die "could not stop the running service; nothing was changed"
    fi
    say "old service stopped"
fi

# --- 3. swap; from here on every failure rolls back ------------------------------------
if [ -d "$TARGET/data" ] && [ ! -e "$STAGE/data" ]; then
    cp -a "$TARGET/data" "$STAGE/data" || { say "could not copy data/"; rollback; }
fi
if [ -d "$TARGET" ]; then
    rm -rf "$OLD"
    mv "$TARGET" "$OLD" || { say "could not move the old install aside"; rollback; }
    OLD_MOVED=1
fi
mv "$STAGE" "$TARGET" || { say "could not move the kit in place"; rollback; }
NEW_IN=1
say "kit in place: $TARGET"

# --- 4. init script ----------------------------------------------------------------------
GEN="$TARGET/S97soloist"
if [ -e "$INIT" ] && cmp -s "$GEN" "$INIT"; then
    say "$INIT unchanged"
else
    if [ -e "$INIT" ]; then
        INIT_EXISTED=1
        cp -p "$INIT" "$INIT_BAK" && cmp -s "$INIT" "$INIT_BAK" ||
            { say "could not back up $INIT"; rollback; }
    fi
    put_init "$GEN" || rollback
    say "$INIT installed"
fi

# --- 5. start: the process must come up; login is only reported ------------------------
if [ -n "$START" ]; then
    RUN=$(O="$TARGET"; . "$TARGET/lib.sh"; echo "$RUN")
    N0=$(wc -l < "$RUN/svc.log" 2>/dev/null || echo 0)
    newlog() { tail -n +$((N0 + 1)) "$RUN/svc.log" 2>/dev/null; }
    "$INIT" start || { say "$INIT start failed"; rollback; }
    i=0
    while [ $i -lt 240 ]; do
        newlog | grep -q "soloist pid=" && break
        if ! "$INIT" status | grep -q "running:"; then
            say "service stopped by itself:"; newlog | tail -n 5; rollback
        fi
        sleep 1; i=$((i+1))
    done
    [ $i -lt 240 ] || { say "Soloist was not started within 240 s:"; newlog | tail -n 5; rollback; }
    sleep 5
    "$INIT" status | grep -q "running:" || { say "service died after start"; newlog | tail -n 5; rollback; }
    say "service up: $(newlog | grep "soloist pid=" | tail -n 1)"
    say "this checks the processes only; check the device in the Spotify app"
fi

rm -f "$INIT_BAK"
if [ -n "$OLD_MOVED" ] && [ -z "$KEEP_OLD" ]; then rm -rf "$OLD"; say "old install removed"; fi
say "done"
