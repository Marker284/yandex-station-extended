#!/bin/sh
# Spotify Soloist supervisor for Yandex Station Lite 1 (busybox sh).
# Started by /etc/init.d/S97soloist. Kill switch for the next start:
# touch $O/disabled (a running service still has to be stopped).
# Order: home network IPv4 -> drop IPv4LL from p2p0 -> cp15_barrier=2 ->
# cache tmpfs -> PulseAudio -> (network, clock, DNS) -> Soloist | audio-gate.
# Refuses to start Soloist without the tmpfs cache, without the PulseAudio
# socket or with CP15 emulation on. Restarts Soloist on crash (max 5 in a
# row), never after exit code 10 (build expired). On TERM/INT stops
# everything and puts cp15_barrier back to the value it had before.
O=$(cd "$(dirname "$0")" && pwd)
. "$O/lib.sh"
setup_env
SVLOG="$RUN/svc.log"
PIPE="$RUN/solo.pipe"
P2P_WAIT=${P2P_WAIT:-30}      # seconds to wait for dhcpcd to put IPv4LL on p2p0
PPID_=""; SPID=""; GPID=""; VPID=""; YPID=""; MOUNTED=""

log() { log_to "$SVLOG" "$@"; }

# --- p2p0: only link-local (169.254/16) addresses are ours to remove --------
ipv4ll() {
    ip -4 addr show "$1" 2>/dev/null |
        sed -n 's/.*inet \(169\.254\.[0-9]*\.[0-9]*\/[0-9]*\).*/\1/p'
}

drop_ipv4ll() {   # 0 = an IPv4LL address was removed from $P2P_IF
    [ -n "$P2P_IF" ] || return 1
    rc=1
    for a in $(ipv4ll "$P2P_IF"); do
        ip addr del "$a" dev "$P2P_IF" 2>/dev/null
        if ipv4ll "$P2P_IF" | grep -qxF "$a"; then
            log "$P2P_IF: could not remove $a"
        else
            log "$P2P_IF: removed $a (mDNS fix)"
            rc=0
        fi
    done
    return $rc
}

# --- CP15 barrier emulation livelocks Soloist's arm32 code -------------------
cp15_is_2() { [ "$(cat "$CP15_FILE" 2>/dev/null)" = 2 ]; }

set_cp15() {   # fail closed: no knob, no saved value or no 2 -> do not start
    [ -r "$CP15_FILE" ] || { log "no $CP15_FILE"; return 1; }
    if [ ! -s "$RUN/cp15.orig" ]; then
        v=$(cat "$CP15_FILE" 2>/dev/null)
        case "$v" in 0|1|2) echo "$v" > "$RUN/cp15.orig" || return 1 ;; *) log "unexpected cp15_barrier '$v'"; return 1 ;; esac
    fi
    { echo 2 > "$CP15_FILE"; } 2>/dev/null
    cp15_is_2
}

restore_cp15() {   # keep the saved value if writing it back fails
    [ -s "$RUN/cp15.orig" ] || return 0
    v=$(cat "$RUN/cp15.orig")
    { echo "$v" > "$CP15_FILE"; } 2>/dev/null
    if [ "$(cat "$CP15_FILE" 2>/dev/null)" = "$v" ]; then
        log "cp15_barrier back to $v"
        rm -f "$RUN/cp15.orig"
    else
        log "could not restore cp15_barrier to $v (saved in $RUN/cp15.orig)"
    fi
}

# --- cache: a dedicated tmpfs or nothing (plain /tmp has no cap) ------------
cache_mounted() {
    awk -v d="$CACHE_DIR" '$2 == d && $3 == "tmpfs" { f = 1 } END { exit !f }' "$MOUNTS" 2>/dev/null
}

setup_cache() {
    mkdir -p "$CACHE_DIR" || return 1
    cache_mounted && return 0
    if ! mount -t tmpfs -o "size=$CACHE_SIZE,mode=700" tmpfs "$CACHE_DIR"; then
        log "cache: mount tmpfs on $CACHE_DIR failed"
        return 1
    fi
    MOUNTED=1
    cache_mounted || { log "cache: $CACHE_DIR is still not a tmpfs"; return 1; }
    log "cache: tmpfs $CACHE_SIZE on $CACHE_DIR"
}

# --- PulseAudio ---------------------------------------------------------------
stop_pulse() {
    [ -n "$PPID_" ] || return 0
    kill -TERM "$PPID_" 2>/dev/null
    wait_gone "$PPID_" 5 || kill -9 "$PPID_" 2>/dev/null
    wait "$PPID_" 2>/dev/null
    PPID_=""
}

start_pulse() {   # 0 = socket is there and pulse runs
    rm -f "$RUN/pulse/native"
    setsid sh "$O/run-pulse.sh" >> "$RUN/pulse.log" 2>&1 < /dev/null &
    PPID_=$!
    i=0
    while [ $i -lt 30 ]; do
        if [ -S "$RUN/pulse/native" ]; then log "pulse up pid=$PPID_"; return 0; fi
        running "$PPID_" || break
        sleep 0.5; i=$((i+1))
    done
    log "pulse socket did not appear (pid=$PPID_), see $RUN/pulse.log"
    stop_pulse
    return 1
}

ensure_pulse() {   # up to 3 attempts
    [ -S "$RUN/pulse/native" ] && running "$PPID_" && return 0
    n=1
    while [ $n -le 3 ]; do
        start_pulse && return 0
        n=$((n+1)); sleep 5
    done
    return 1
}

# --- Soloist, gate, voice ------------------------------------------------------
kill_soloist() {   # INT (it ignores TERM), -9 after 10 s; does not reap
    [ -n "$SPID" ] || return 0
    kill -INT "$SPID" 2>/dev/null
    wait_gone "$SPID" 10 || { log "soloist pid=$SPID ignored INT for 10 s, kill -9"; kill -9 "$SPID" 2>/dev/null; }
}

reap_gate() {   # the gate sees EOF, closes aplay with SIGINT and exits itself
    [ -n "$GPID" ] || return 0
    wait_gone "$GPID" 6 || { log "gate pid=$GPID still alive, TERM"; kill -TERM "$GPID" 2>/dev/null; }
    wait "$GPID" 2>/dev/null
    GPID=""
}

stop_soloist() {
    kill_soloist
    [ -n "$SPID" ] && wait "$SPID" 2>/dev/null
    SPID=""
    reap_gate
}

start_voice() {   # voice control watcher, own process group (setsid)
    [ -f "$O/spotify-voice.sh" ] || return 0
    setsid sh "$O/spotify-voice.sh" > /dev/null 2>&1 < /dev/null &
    VPID=$!
    log "voice watcher pid=$VPID"
}

start_vsync() {   # Soloist follows Alice's volume
    [ "$VOLUME_SYNC" = 1 ] && [ -f "$O/volume-sync.sh" ] || return 0
    setsid sh "$O/volume-sync.sh" > /dev/null 2>&1 < /dev/null &
    YPID=$!
    log "volume sync pid=$YPID"
}

stop_vsync() {
    [ -n "$YPID" ] || return 0
    kill -TERM "$YPID" 2>/dev/null
    wait_gone "$YPID" 3 || kill -9 "$YPID" 2>/dev/null
    wait "$YPID" 2>/dev/null
    YPID=""
}

stop_voice() {
    [ -n "$VPID" ] || return 0
    kill -TERM "$VPID" 2>/dev/null
    wait_gone "$VPID" 3 || kill -9 "$VPID" 2>/dev/null
    wait "$VPID" 2>/dev/null
    VPID=""
}

# Soloist does not exit when its first login fails (spotify/soloist#18), so it
# must start only when the network is really usable: default route, real clock
# (it is 1970 right after boot) and DNS for Spotify.
net_ready() {
    ip route 2>/dev/null | grep -q '^default' || return 1
    [ "$(date +%Y)" -ge 2026 ] || return 1
    nslookup "$NET_HOST" > /dev/null 2>&1
}

wait_net() {
    i=0
    until net_ready; do
        [ $((i % 60)) -eq 0 ] && log "waiting for network/clock/DNS (${i}s)"
        sleep 5 & wait $!
        i=$((i+5))
    done
    log "network ready after ${i}s"
}

cleanup() {   # cleanup EXIT_CODE
    trap '' INT TERM
    log "stopping"
    stop_voice
    stop_vsync
    stop_soloist
    stop_pulse
    restore_cp15
    [ -n "$MOUNTED" ] && umount "$CACHE_DIR" 2>/dev/null
    log "stopped"
    exit "${1:-0}"
}
trap 'cleanup 0' INT TERM

[ -e "$O/disabled" ] && { log "disabled by $O/disabled"; exit 0; }
log "svc start"

i=0
until ip -4 addr show "$WLAN_IF" 2>/dev/null | grep -q "inet "; do
    sleep 2; i=$((i+2)); [ $i -ge 180 ] && break
done
log "$WLAN_IF IPv4 after ${i}s"

# dhcpcd puts an IPv4LL address on p2p0 at boot; Soloist then answers mDNS
# there instead of the LAN. Give it time to appear, then drop it.
if [ -n "$P2P_IF" ]; then
    i=0
    while [ $i -lt "$P2P_WAIT" ]; do drop_ipv4ll && break; sleep 2; i=$((i+2)); done
fi

set_cp15 || { log "cannot set $CP15_FILE to 2: Soloist would livelock, not starting"; cleanup 1; }
setup_cache || { log "no tmpfs cache: not starting Soloist"; cleanup 1; }
ensure_pulse || { log "PulseAudio did not come up: not starting Soloist"; cleanup 1; }
start_voice
start_vsync

fails=0
while :; do
    wait_net
    # re-checked right before every start: wait_net can take long
    cache_mounted || { log "cache tmpfs is gone: not starting Soloist"; break; }
    ensure_pulse || { log "PulseAudio did not come up: not starting Soloist"; break; }
    cp15_is_2 || set_cp15 || { log "cp15_barrier is not 2: not starting Soloist"; break; }
    rm -f "$RUN/login-failed"
    rm -f "$PIPE"; mkfifo "$PIPE"
    t0=$(date +%s)
    restart=""
    sh "$O/run-soloist.sh" -w 127.0.0.1:0 > "$PIPE" 2>&1 < /dev/null &
    SPID=$!
    sh "$O/audio-gate.sh" "$SPID" < "$PIPE" &
    GPID=$!
    log "soloist pid=$SPID gate pid=$GPID"
    while running "$SPID"; do
        sleep 30 & wait $!
        running "$SPID" || break
        if [ -e "$RUN/login-failed" ]; then
            # observed: after a failed login Soloist took ~100 s to honour INT.
            # It holds no ALSA device (aplay does), so -9 is safe here.
            log "soloist still up after login failure, kill -9"
            kill -9 "$SPID" 2>/dev/null
            break
        fi
        if drop_ipv4ll; then
            log "$P2P_IF got an IPv4LL address again; restarting soloist"
            restart=1
            kill_soloist
            break
        fi
        running "$PPID_" || { log "pulse died while soloist runs, restarting pulse"; ensure_pulse; }
        [ -z "$VPID" ] || running "$VPID" || { log "voice watcher died, restarting"; start_voice; }
        [ -z "$YPID" ] || running "$YPID" || { log "volume sync died, restarting"; start_vsync; }
        rotate "$RUN/pulse.log"
    done
    wait "$SPID"; rc=$?
    SPID=""
    reap_gate
    log "soloist exited rc=$rc"
    if [ -e "$RUN/login-failed" ]; then
        log "login failed (stopped by gate); retry in 20s, not counted as a crash"
        sleep 20 & wait $!
        continue
    fi
    [ -n "$restart" ] && continue
    if [ "$rc" -eq 10 ]; then
        log "soloist build expired (exit 10): replace $O/bin/soloist; not restarting"
        break
    fi
    [ $(( $(date +%s) - t0 )) -gt 600 ] && fails=0
    fails=$((fails+1))
    if [ $fails -ge 5 ]; then log "5 restarts in a row, giving up"; break; fi
    sleep 30 & wait $!
done
cleanup 1
