# lib.sh - shared settings and helpers for the Soloist scripts (busybox sh).
# Sourced after the caller has set O (install directory).
# Settings below are defaults; override them in $O/etc/soloist.conf.
[ -n "$O" ] || { echo "lib.sh: O is not set" >&2; exit 1; }

DEVICE_NAME="Станция Лайт"        # name shown in Spotify Connect
WLAN_IF=wlan0                     # interface that carries the home network
P2P_IF=p2p0                       # Wi-Fi Direct interface whose IPv4LL is removed; empty = leave alone
RUN=/tmp/soloist-run              # runtime dir in RAM: sockets, FIFOs, logs
CACHE_DIR=/tmp/soloist-cache      # Soloist cache, always a dedicated tmpfs
CACHE_SIZE=12m                    # hard cap of that tmpfs
CACHE_LIMIT_MB=100                # Soloist -z (its minimum is 100, the tmpfs is the real cap)
SOLOIST_ARGS=""                   # extra Soloist options, e.g. "-i 30" (initial volume)
NET_HOST=apresolve.spotify.com    # must resolve before Soloist starts
BRIDGE_JOURNAL=/tmp/quasar-conv.jsonl  # Quasar Bridge conversation_log (voice control)
LOG_MAX=262144                    # rotate each log above this many bytes (one .1 copy kept)
VOLUME_SYNC=1                     # 1 = Soloist follows Alice's volume (volume-sync.sh)
ALICE_VOLUME_FILE=/data/quasar/data/last_vendor_volume   # Alice's level, written by maind
ALICE_MUTE_FILE=/data/quasar/data/is_speaker_muted      # 1 = muted
ALICE_VOLUME_MAX=20               # top of Alice's scale on Station Lite
CP15_FILE=/proc/sys/abi/cp15_barrier
MOUNTS=/proc/mounts
APLAY=/usr/bin/aplay              # the station's own aplay: system libasound, dmix shared with Alice

[ -r "$O/etc/soloist.conf" ] && . "$O/etc/soloist.conf"

# Rotate by copy + truncate, so writers that keep the file open (pulse) follow.
rotate() {
    s=$(wc -c < "$1" 2>/dev/null) || return 0
    [ "${s:-0}" -gt "$LOG_MAX" ] || return 0
    cp -f "$1" "$1.1" && : > "$1"
    return 0
}

log_to() {   # log_to FILE MESSAGE...
    f=$1; shift
    rotate "$f"
    echo "$(date -u '+%F %T') $*" >> "$f"
}

# kill -0 succeeds on a zombie, so look at the process state instead.
running() {
    [ -n "$1" ] && [ -r "/proc/$1/stat" ] || return 1
    st=$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null)
    [ -n "$st" ] && [ "$st" != Z ]
}

# Interruptible sleep: a trap runs during `wait`, not during a foreground sleep.
# The sleep's pid is kept in NAP so a stopping script can kill it (end_nap):
# otherwise the sleep outlives the script by up to its full length.
NAP=""
nap() { sleep "$1" & NAP=$!; wait "$NAP"; NAP=""; }
end_nap() { [ -n "$NAP" ] && kill "$NAP" 2>/dev/null; NAP=""; }

wait_gone() {   # wait_gone PID SECONDS
    i=0
    while [ $i -lt $(( $2 * 5 )) ] && running "$1"; do sleep 0.2; i=$((i+1)); done
    ! running "$1"
}

# Alice's volume as Soloist's 0-100; nothing (status 1) if unreadable.
alice_volume() {
    v=$(tr -d ' \r\n' < "$ALICE_VOLUME_FILE" 2>/dev/null)
    case "$v" in ''|*[!0-9]*) return 1 ;; esac
    m=$(tr -d ' \r\n' < "$ALICE_MUTE_FILE" 2>/dev/null)
    [ "$m" = 1 ] && { echo 0; return 0; }
    [ "$v" -gt "$ALICE_VOLUME_MAX" ] && v=$ALICE_VOLUME_MAX
    echo $(( v * 100 / ALICE_VOLUME_MAX ))
}

# Debian trixie runtime (glibc 2.41) through its own loader. Never a global
# LD_LIBRARY_PATH: that would break Yandex's 32-bit programs.
ldr() {
    "$O/lib/ld-linux-armhf.so.3" --library-path "$O/lib" "$@"
}

setup_env() {
    export HOME="$O/home"
    export XDG_RUNTIME_DIR="$RUN"
    export PULSE_RUNTIME_PATH="$RUN/pulse"
    export PULSE_STATE_PATH="$O/home/pulse-state"
    export PULSE_SERVER="unix:$RUN/pulse/native"
    mkdir -p "$HOME" "$PULSE_STATE_PATH" "$RUN/pulse"
    chmod 700 "$RUN" "$RUN/pulse"
}
