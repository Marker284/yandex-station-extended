#!/bin/sh
# audio-gate: keeps the station's shared ALSA output (dmix, also used by Alice)
# open only while Soloist is actually playing (busybox sh).
# Usage: audio-gate.sh <soloist_pid>   (stdin = Soloist's stdout+stderr)
# Copies Soloist's output into soloist.log (rotated), starts the SYSTEM
# /usr/bin/aplay (system libasound, same as Alice) reading PulseAudio's
# pipe-sink FIFO on "playing", and stops it with SIGINT after a short pause,
# so aplay closes the PCM itself. Never kill -9 aplay automatically: an abrupt
# death mid-recovery is the suspected cause of the 08.11.2026 dmix stall.
O=$(cd "$(dirname "$0")" && pwd)
. "$O/lib.sh"
SPID="$1"
FIFO="$RUN/pcm.fifo"
SLOG="$RUN/soloist.log"
GLOG="$RUN/gate.log"

IDLE_STOP=5          # seconds of pause before closing the output
APID=""
STOP_AT=0
N=0

log() { log_to "$GLOG" "$@"; }

reap_aplay() {   # collect an aplay that exited by itself (no zombies)
    [ -n "$APID" ] || return 0
    running "$APID" && return 1
    wait "$APID" 2>/dev/null; rc=$?
    log "aplay pid=$APID exited by itself rc=$rc"
    APID=""
}

start_aplay() {
    STOP_AT=0
    reap_aplay || return 0
    [ -p "$FIFO" ] || { log "no fifo, not starting aplay"; return; }
    setsid "$APLAY" -q -D default -f S16_LE -c 2 -r 48000 -t raw < "$FIFO" &
    APID=$!
    log "aplay start pid=$APID"
}

stop_aplay() {
    STOP_AT=0
    reap_aplay && return 0
    kill -INT "$APID"
    i=0
    while [ $i -lt 30 ] && running "$APID"; do sleep 0.1; i=$((i+1)); done
    if running "$APID"; then
        log "aplay pid=$APID did NOT exit after SIGINT: it may still hold the PCM; check by hand"
    else
        wait "$APID" 2>/dev/null
        log "aplay stopped pid=$APID"
        APID=""
    fi
}

trap 'stop_aplay; log "gate exit (signal)"; exit 0' INT TERM

# Soloist gets the key on its command line; never let a line with it reach the log.
KEY=$(tr -d '\r\n\t ' < "$O/etc/api.key" 2>/dev/null)

log "gate start, soloist pid=$SPID"
while :; do
    if read -t 1 line; then
        case "$line" in *"$KEY"*) [ -n "$KEY" ] && line="[line with the API key removed]" ;; esac
        echo "$line" >> "$SLOG"
        N=$((N+1)); [ $((N % 200)) -eq 0 ] && rotate "$SLOG"
        case "$line" in
            *": playing "*) start_aplay ;;
            *"login failed"*)
                # Soloist stays up but unusable after a failed login (soloist#18):
                # stop it so the supervisor retries once the network is fine.
                log "soloist login failed; asking it to exit"
                : > "$RUN/login-failed"
                kill -INT "$SPID" 2>/dev/null ;;
            *": paused "*|*"no longer active device"*|*": stopped"*)
                running "$APID" && [ "$STOP_AT" -eq 0 ] && STOP_AT=$(( $(date +%s) + IDLE_STOP )) ;;
        esac
    else
        # busybox read returns 1 both on timeout and on EOF
        running "$SPID" || break
        sleep 0.2
    fi
    if [ "$STOP_AT" -ne 0 ] && [ "$(date +%s)" -ge "$STOP_AT" ]; then
        stop_aplay
    fi
done
stop_aplay
log "gate exit (soloist gone)"
