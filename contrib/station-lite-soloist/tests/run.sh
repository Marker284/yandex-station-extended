#!/bin/sh
# Behaviour tests for the device scripts. Run on Linux with python3 (stubs):
#   BB=/path/to/busybox sh tests/run.sh [DEVICE_DIR] [TEST...]
# With BB set, every script runs under busybox applets only (like the station).
# Nothing here touches the real system: ip, mount, nslookup, aplay, the loader,
# pulseaudio and soloist are stubs, kernel files are plain files in a temp dir.
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "${1:-$HERE/../device}" && pwd); [ $# -gt 0 ] && shift
ONLY="$*"
PATH0=$PATH
PY=$(command -v python3) || { echo "python3 is needed for the stubs"; exit 2; }
PASS=0; FAIL=0; FAILED=""

say() { echo "  $*"; }

# --- fixture -------------------------------------------------------------------
# $T/opt dir/      install dir (with a space on purpose)
# $T/st/           stub state: addr.<if>, mounts, *.log, flags
# $T/bin/          stubs first, then busybox applets
setup() {
    T=$(mktemp -d /tmp/soloist-test.XXXXXX)
    O="$T/opt dir"; ST="$T/st"; B="$T/bin"
    mkdir -p "$ST" "$B" "$T/sb"
    : > "$ST/mounts"
    echo "/dev/root / squashfs ro,relatime 0 0" > "$ST/rootmounts"
    echo 1 > "$ST/cp15"
    printf '    inet 192.168.0.10/24 brd 192.168.0.255 scope global wlan0\n' > "$ST/addr.wlan0"
    printf '    inet 169.254.12.34/16 brd 169.254.255.255 scope link p2p0\n' > "$ST/addr.p2p0"
    write_stubs
    mk_kit "$O"
    cat > "$O/etc/soloist.conf" <<EOF
RUN="$T/run"
CACHE_DIR="$T/cache"
CP15_FILE="$ST/cp15"
MOUNTS="$ST/mounts"
APLAY="$B/aplay"
BRIDGE_JOURNAL="$T/journal.jsonl"
P2P_WAIT=4
ALICE_VOLUME_FILE="$ST/alice-volume"
ALICE_MUTE_FILE="$ST/alice-muted"
EOF
    if [ -n "$BB" ]; then
        "$BB" --install -s "$B" 2>/dev/null ||
            for a in $("$BB" --list); do ln -sf "$BB" "$B/$a"; done
    fi
    # the station's busybox has nohup; Debian's dynamic busybox does not
    [ -e "$B/nohup" ] || ln -s "$(command -v nohup)" "$B/nohup"
    export ST BB
    if [ -n "$BB" ]; then PATH="$B"; else PATH="$B:$PATH"; fi
    export PATH
}

teardown() {
    [ -n "${KEEP:-}" ] && { echo "  kept $T"; PATH=$PATH0; return; }
    for p in $(procs_in_test); do kill -9 "$p" 2>/dev/null; done
    sleep 0.3
    rm -rf "$T"
    PATH=$PATH0
}

write_stubs() {
    rm -f "$B/ip" "$B/mount" "$B/umount" "$B/nslookup" "$B/id"
    cat > "$B/ip" <<'EOF'
#!/bin/sh
# ip -4 addr show IF | ip addr del A dev IF | ip route
case "$1 $2 $3" in
"-4 addr show") cat "$ST/addr.$4" 2>/dev/null; exit 0 ;;
"addr del "*)
    echo "del $3 $5" >> "$ST/ip.log"
    [ -e "$ST/del-fail" ] && exit 2
    grep -vF "inet $3 " "$ST/addr.$5" > "$ST/addr.tmp"; mv "$ST/addr.tmp" "$ST/addr.$5"; exit 0 ;;
esac
[ "$1" = route ] && { echo "default via 192.168.0.1 dev wlan0"; exit 0; }
exit 1
EOF
    cat > "$B/mount" <<'EOF'
#!/bin/sh
echo "mount $*" >> "$ST/mount.log"
case "$*" in
"-o remount,rw /"|"-o remount,ro /")
    [ -e "$ST/remount-fail" ] && { echo "mount: permission denied" >&2; exit 1; }
    [ "$2" = remount,ro ] && [ -e "$ST/remount-ro-fail" ] && { echo "mount: / is busy" >&2; exit 1; }
    o=${2#remount,}
    echo "/dev/root / squashfs $o,relatime 0 0" > "$ST/rootmounts"; exit 0 ;;
esac
[ -e "$ST/mount-fail" ] && { echo "mount: mounting tmpfs failed: Out of memory" >&2; exit 32; }
for d; do :; done
echo "tmpfs $d tmpfs rw,relatime 0 0" >> "$ST/mounts"
EOF
    cat > "$B/umount" <<'EOF'
#!/bin/sh
grep -v " $1 tmpfs " "$ST/mounts" > "$ST/mounts.tmp"; mv "$ST/mounts.tmp" "$ST/mounts"
EOF
    printf '#!/bin/sh\nexit 0\n' > "$B/nslookup"
    if [ -n "$BB" ]; then realmv="\"$BB\" mv"; else realmv=$(command -v mv); fi
    rm -f "$B/mv"
    cat > "$B/mv" <<EOF
#!/bin/sh
if [ -e "\$ST/mv-fail" ] && [ "\$1" = "\$(cat "\$ST/mv-fail")" ]; then echo "mv: can't rename '\$1'" >&2; exit 1; fi
exec $realmv "\$@"
EOF
    printf '#!/bin/sh\necho 0\n' > "$B/id"
    # loader: ld-linux --library-path DIR PROG ARGS...
    printf '#!/bin/sh\nshift 2\nexec "$@"\n' > "$T/sb/ld-linux-armhf.so.3"
    cat > "$T/sb/pulseaudio" <<EOF
#!$PY
import os, re, signal, socket, sys, time
st = os.environ["ST"]
if "--version" in sys.argv:
    print("pulseaudio 17.0"); sys.exit(0)
if os.path.exists(st + "/pulse-die"):
    sys.exit(1)
pa = open(sys.argv[sys.argv.index("-F") + 1]).read()
fifo = re.search(r"file=(\S+)", pa).group(1)
sock = re.search(r"socket=(\S+)", pa).group(1)
if not os.path.exists(fifo):
    os.mkfifo(fifo)
fd = os.open(fifo, os.O_RDWR)          # like module-pipe-sink
s = socket.socket(socket.AF_UNIX); s.bind(sock); s.listen(1)
signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
while True:
    time.sleep(1)
EOF
    cat > "$T/sb/soloist" <<EOF
#!$PY
import os, signal, sys, time
st = os.environ["ST"]
if "--version" in sys.argv:
    if os.path.exists(st + "/version-fail"):
        print("error while loading shared libraries: libpulse.so.0", file=sys.stderr); sys.exit(127)
    print("1.3.10.51 build test"); sys.exit(0)
if sys.argv[1:2] == ["ctl"]:
    a = sys.argv[2:sys.argv.index("-D")] if "-D" in sys.argv else sys.argv[2:]
    open(st + "/ctl.log", "a").write(" ".join(a) + "\n"); sys.exit(0)
open(st + "/soloist.args", "a").write("\0".join(sys.argv[1:]) + "\n")
if os.path.exists(st + "/echo-key"):
    print("E [soloist] auth request failed for key " + sys.argv[sys.argv.index("-k") + 1], flush=True)
signal.signal(signal.SIGINT, lambda *a: sys.exit(0))   # real Soloist: INT, not TERM
signal.signal(signal.SIGTERM, signal.SIG_IGN)
print("I [soloist] logged in", flush=True)
while True:
    time.sleep(1)
EOF
    cat > "$B/aplay" <<EOF
#!$PY
import os, signal, sys, time
st = os.environ["ST"]
open(st + "/aplay.log", "a").write("start\n")
if os.path.exists(st + "/aplay-dies"):
    sys.exit(1)
signal.signal(signal.SIGINT, lambda *a: sys.exit(0))
while True:
    time.sleep(1)
EOF
    chmod +x "$B"/* "$T/sb"/*
}

mk_kit() {   # mk_kit DIR: device scripts + stub programs laid out like the real kit
    mkdir -p "$1/lib" "$1/bin" "$1/etc" "$1/modules"
    cp "$SRC"/*.sh "$SRC/S97soloist" "$1/"
    cp "$SRC/soloist.pa.in" "$SRC/soloist.conf.example" "$1/etc/"
    cp "$T/sb/ld-linux-armhf.so.3" "$1/lib/"
    cp "$T/sb/pulseaudio" "$T/sb/soloist" "$1/bin/"
    [ -e "$1/etc/api.key" ] || echo "test-key-not-real" > "$1/etc/api.key"
}

procs_in_test() {   # pids started by this test: the command line names the temp dir,
    # or the environment carries this test's ST (a leftover `sleep 30` names neither file)
    (
    export PROC_SCAN=1   # helpers of this scan (tr, grep) carry it and are skipped
    for f in /proc/[0-9]*/cmdline; do
        p=${f#/proc/}; p=${p%/cmdline}
        [ "$p" = $$ ] && continue
        case "$(tr '\0' ' ' 2>/dev/null < "$f")" in *"$T"*) echo "$p"; continue ;; esac
        e=$(tr '\0' '\n' 2>/dev/null < "/proc/$p/environ")
        case "$e" in *PROC_SCAN=1*) continue ;; esac
        printf '%s\n' "$e" | grep -qxF "ST=$ST" && echo "$p"
    done
    )
}

wait_for() {   # wait_for SECONDS CONDITION...
    n=$(( $1 * 5 )); shift
    while [ $n -gt 0 ]; do "$@" && return 0; sleep 0.2; n=$((n-1)); done
    return 1
}

alive() { [ -n "$1" ] && [ -d "/proc/$1" ] && [ "$(awk '{print $3}' /proc/$1/stat 2>/dev/null)" != Z ]; }

start_svc() {
    sh "$O/soloist-svc.sh" > "$ST/svc.out" 2>&1 &
    SVC=$!
}

stop_svc() {
    kill -TERM "$SVC" 2>/dev/null
    wait_for 30 eval '! alive $SVC'
}

soloist_started() { [ -s "$ST/soloist.args" ]; }
has() { grep -q "$2" "$1" 2>/dev/null; }

check() {   # check DESCRIPTION CONDITION...
    d=$1; shift
    if "$@"; then say "ok   $d"; else say "FAIL $d"; BAD=1; fi
}

run_test() {
    name=$1
    if [ -n "$ONLY" ]; then case " $ONLY " in *" $name "*) ;; *) return ;; esac; fi
    echo "$name"
    setup
    BAD=0
    "$name"
    if [ $BAD -eq 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED="$FAILED $name"
        echo "  --- svc.log:"; sed 's/^/  | /' "$T/run/svc.log" 2>/dev/null | tail -n 15; fi
    teardown
}

# --- tests: supervisor ---------------------------------------------------------

# Requirement: if the cache tmpfs cannot be mounted, Soloist must not start,
# otherwise its cache (min 100 MB) fills the shared /tmp, i.e. the RAM.
t_cache_mount_fails() {
    : > "$ST/mount-fail"
    start_svc
    wait_for 25 eval '! alive $SVC'
    check "supervisor exits by itself" eval '! alive $SVC'
    check "soloist was never started" eval '! soloist_started'
    check "log says why" has "$T/run/svc.log" "not starting Soloist"
    stop_svc
}

# Requirement: Soloist must not start without the PulseAudio socket
# (it would come up with no audio output).
t_pulse_never_up() {
    : > "$ST/pulse-die"
    start_svc
    wait_for 40 eval '! alive $SVC'
    check "supervisor gives up" eval '! alive $SVC'
    check "soloist was never started" eval '! soloist_started'
    check "log says PulseAudio did not come up" has "$T/run/svc.log" "PulseAudio did not come up"
    stop_svc
}

# Requirement: only the link-local IPv4 of p2p0 is removed. A Wi-Fi Direct
# group address (192.168.49.1/24 by default) belongs to Yandex and stays.
t_p2p0_keeps_non_ll() {
    printf '    inet 192.168.49.1/24 brd 192.168.49.255 scope global p2p0\n' > "$ST/addr.p2p0"
    start_svc
    wait_for 20 soloist_started
    check "soloist started" soloist_started
    check "192.168.49.1 still on p2p0" has "$ST/addr.p2p0" "192.168.49.1/24"
    check "no ip addr del issued" eval '! has "$ST/ip.log" "del"'
    stop_svc
}

t_p2p0_drops_ll_only() {
    printf '    inet 169.254.12.34/16 brd 169.254.255.255 scope link p2p0\n    inet 192.168.49.1/24 brd 192.168.49.255 scope global p2p0\n' > "$ST/addr.p2p0"
    start_svc
    wait_for 20 soloist_started
    check "169.254.12.34 removed" eval '! has "$ST/addr.p2p0" "169.254.12.34"'
    check "192.168.49.1 kept" has "$ST/addr.p2p0" "192.168.49.1/24"
    stop_svc
}

# Requirement: a failed removal is reported, not logged as success.
t_p2p0_del_failure_reported() {
    : > "$ST/del-fail"
    start_svc
    wait_for 20 soloist_started
    check "failure is logged" has "$T/run/svc.log" "could not remove 169.254.12.34"
    check "no false success" eval '! has "$T/run/svc.log" "removed 169.254.12.34"'
    stop_svc
}

# Requirement: name, interface and paths come from etc/soloist.conf; the
# install dir may contain a space.
t_config_is_used() {
    rm -f "$ST/addr.wlan0"
    printf '    inet 10.0.0.7/24 brd 10.0.0.255 scope global wlan1\n' > "$ST/addr.wlan1"
    cat >> "$O/etc/soloist.conf" <<'EOF'
DEVICE_NAME="Кухня 2"
WLAN_IF=wlan1
EOF
    start_svc
    wait_for 20 soloist_started
    check "soloist started (waited on wlan1, not wlan0)" soloist_started
    check "wlan1 used" has "$T/run/svc.log" "wlan1 IPv4 after 0s"
    args=$(tr '\0' '\n' < "$ST/soloist.args" 2>/dev/null)
    check "device name passed as one argument" eval 'echo "$args" | grep -qx "Кухня 2"'
    check "cache dir from settings" eval 'echo "$args" | grep -qx "$T/cache"'
    stop_svc
}

# Requirement: stopping the service restores cp15_barrier to the value it
# had before, not to a hard-coded 1.
t_cp15_restored() {
    echo 0 > "$ST/cp15"
    start_svc
    wait_for 20 soloist_started
    check "cp15 is 2 while running" eval '[ "$(cat "$ST/cp15")" = 2 ]'
    stop_svc
    check "cp15 back to 0 after stop" eval '[ "$(cat "$ST/cp15")" = 0 ]'
}

# Requirement: after stop nothing of ours keeps running (pulse, soloist,
# gate, voice watcher and its tail -F).
t_stop_leaves_nothing() {
    : > "$T/journal.jsonl"
    start_svc
    wait_for 20 soloist_started
    wait_for 5 eval '[ -n "$(procs_in_test | head -n 1)" ]'
    stop_svc
    sleep 1
    left=$(for p in $(procs_in_test); do tr '\0' ' ' < /proc/$p/cmdline; echo; done)
    check "no processes left${left:+: $left}" eval '[ -z "$left" ]'
    check "cache tmpfs unmounted" eval '! has "$ST/mounts" "$T/cache"'
}

# --- tests: voice watcher ------------------------------------------------------
start_voice() {
    : > "$T/journal.jsonl"
    mkdir -p "$T/run"
    sh "$O/spotify-voice.sh" > /dev/null 2>&1 &
    VP=$!
    sleep 1.5
}
stop_voice() { kill -TERM "$VP" 2>/dev/null; wait_for 5 eval '! alive $VP'; }
jl() { printf '%s\n' "$1" >> "$T/journal.jsonl"; }
ctl_has() { has "$ST/ctl.log" "^$1\$"; }

# Requirement: a phrase with an escaped quote is still recognised.
t_voice_json_escape() {
    start_voice
    jl '{"time":"2026-11-08T04:10:00Z","session":"s1","request":"r1","event":"transcript","text":"скажи \"привет\" и включи спотифай","delivered":false}'
    jl '{"time":"2026-11-08T04:10:01Z","session":"s1","request":"r1","event":"route","route":"llm","delivered":false}'
    wait_for 5 ctl_has play
    check "activate + play called" eval 'ctl_has activate && ctl_has play'
    stop_voice
}

# Requirement: a Spotify phrase without a known command does nothing.
t_voice_unknown_ignored() {
    start_voice
    jl '{"time":"2026-11-08T04:11:00Z","request":"r2","event":"transcript","text":"что сейчас играет в спотифай","delivered":false}'
    jl '{"time":"2026-11-08T04:11:01Z","request":"r2","event":"route","route":"llm","delivered":false}'
    sleep 2
    check "no soloist ctl call" eval '[ ! -s "$ST/ctl.log" ]'
    check "logged as ignored" has "$T/run/voice.log" "ignored"
    stop_voice
}

# Requirement: two requests in flight are matched by id.
t_voice_interleaved() {
    start_voice
    jl '{"time":"2026-11-08T04:12:00Z","request":"a1","event":"transcript","text":"пауза в спотифай","delivered":false}'
    jl '{"time":"2026-11-08T04:12:00Z","request":"b2","event":"transcript","text":"какая погода","delivered":false}'
    jl '{"time":"2026-11-08T04:12:01Z","request":"a1","event":"route","route":"llm","delivered":false}'
    jl '{"time":"2026-11-08T04:12:01Z","request":"b2","event":"route","route":"yandex","delivered":false}'
    wait_for 5 ctl_has pause
    check "pause for request a1" ctl_has pause
    stop_voice
}

# Requirement: Yandex-routed phrases never trigger Soloist.
t_voice_non_llm_route() {
    start_voice
    jl '{"time":"2026-11-08T04:13:00Z","request":"c3","event":"transcript","text":"включи спотифай","delivered":false}'
    jl '{"time":"2026-11-08T04:13:01Z","request":"c3","event":"route","route":"yandex","delivered":false}'
    sleep 2
    check "no soloist ctl call" eval '[ ! -s "$ST/ctl.log" ]'
    stop_voice
}

# Requirement: voice.log is bounded like the other logs.
t_voice_log_rotated() {
    echo "LOG_MAX=2000" >> "$O/etc/soloist.conf"
    mkdir -p "$T/run"
    head -c 5000 /dev/zero | tr '\0' 'x' > "$T/run/voice.log"
    start_voice
    jl '{"time":"2026-11-08T04:14:00Z","request":"d4","event":"transcript","text":"следующий трек в спотифай","delivered":false}'
    jl '{"time":"2026-11-08T04:14:01Z","request":"d4","event":"route","route":"llm","delivered":false}'
    wait_for 5 ctl_has next
    s=$(wc -c < "$T/run/voice.log")
    check "voice.log below LOG_MAX (is $s)" eval '[ "$s" -le 2000 ]'
    check "old content kept in voice.log.1" eval '[ -s "$T/run/voice.log.1" ]'
    stop_voice
}

# --- tests: audio gate ---------------------------------------------------------
# Requirement: an aplay that dies by itself is collected, the gate does not
# pile up zombies across play events.
t_gate_reaps_aplay() {
    mkdir -p "$T/run"
    mkfifo "$T/run/pcm.fifo" "$T/in"
    sleep 300 > "$T/run/pcm.fifo" &        # keeps the FIFO open, like pulse
    HOLD=$!
    : > "$ST/aplay-dies"
    sleep 300 &
    FAKE=$!
    sh "$O/audio-gate.sh" "$FAKE" < "$T/in" &
    GP=$!
    exec 7> "$T/in"
    for i in 1 2 3 4 5; do echo "I [x] : playing spotify:track:$i" >&7; sleep 0.6; done
    z=0
    for f in /proc/[0-9]*/stat; do
        set -- $(cat "$f" 2>/dev/null)
        [ "$4" = "$GP" ] && [ "$3" = Z ] && z=$((z+1))
    done
    check "at most one zombie child (found $z)" eval '[ "$z" -le 1 ]'
    check "aplay was started each time" eval '[ "$(grep -c start "$ST/aplay.log")" -ge 4 ]'
    exec 7>&-
    kill "$FAKE" "$HOLD" 2>/dev/null
    wait_for 5 eval '! alive $GP'
}

# --- tests: install.sh -----------------------------------------------------------
# Staging dir as deploy.py leaves it: kit + MANIFEST.sha256 (+ key if given).
STG_SUFFIX=.new
mk_stage() {   # mk_stage VERSION [DIR]
    STG=${2:-$O$STG_SUFFIX}
    rm -rf "$STG"; mk_kit "$STG"
    rm -f "$STG/etc/api.key"
    cp "$T/test.conf" "$STG/etc/soloist.conf"
    echo "$1" > "$STG/VERSION"
    ( cd "$STG" && find . -type f ! -name MANIFEST.sha256 | sort | xargs sha256sum > MANIFEST.sha256 )
}
old_install() {   # the current $O becomes an installed, running v1
    cp "$O/etc/soloist.conf" "$T/test.conf"
    echo v1 > "$O/VERSION"
    mkdir -p "$O/data" "$T/initd"
    echo "login-blob" > "$O/data/credentials.json"
    sed "s#@O@#$O#" "$O/S97soloist" > "$T/initd/S97soloist"; chmod 755 "$T/initd/S97soloist"
    sed -i "s#@O@#$O#" "$O/S97soloist"
    "$T/initd/S97soloist" start
    wait_for 20 soloist_started
}
do_install() {
    TARGET="$O" INIT_DIR="$T/initd" ROOT_MOUNTS="$ST/rootmounts" sh "$STG/install.sh" "$@" > "$T/install.out" 2>&1
    IRC=$?
}
svc_running() { "$T/initd/S97soloist" status 2>/dev/null | grep -q "running:"; }
root_ro() { grep -q " / squashfs ro," "$ST/rootmounts"; }
show_install() { sed 's/^/  > /' "$T/install.out"; }
stop_all() { "$T/initd/S97soloist" stop > /dev/null 2>&1; }

# Requirement: on a clean station the kit is installed, the init script gets
# the real path, rootfs is read-only again and the service runs.
t_install_fresh() {
    cp "$O/etc/soloist.conf" "$T/test.conf"
    rm -rf "$O"; mkdir -p "$T/initd"
    mk_stage v2
    echo "test-key-not-real" > "$STG/etc/api.key"
    do_install
    check "install exit 0" eval '[ $IRC -eq 0 ]'
    check "v2 in place" eval '[ "$(cat "$O/VERSION" 2>/dev/null)" = v2 ]'
    check "staging dir gone" eval '[ ! -e "$STG" ]'
    check "init script points to the install dir" eval 'grep -qxF "O=\"$O\"" "$T/initd/S97soloist"'
    check "rootfs remounted rw then ro" eval 'grep -q "remount,rw /" "$ST/mount.log" && grep -q "remount,ro /" "$ST/mount.log"'
    check "rootfs read-only again" root_ro
    check "api.key mode 600" eval '[ "$(stat -c %a "$O/etc/api.key")" = 600 ]'
    check "service running" svc_running
    [ $BAD -eq 0 ] || show_install
    stop_all
}

# Requirement: an upgrade keeps the key and the Spotify login (data/).
t_install_upgrade_keeps_login() {
    old_install
    mk_stage v2
    do_install
    check "install exit 0" eval '[ $IRC -eq 0 ]'
    check "v2 in place" eval '[ "$(cat "$O/VERSION")" = v2 ]'
    check "login data kept" has "$O/data/credentials.json" "login-blob"
    check "api.key kept" has "$O/etc/api.key" "test-key-not-real"
    check "old install removed" eval '[ ! -e "$O.old" ]'
    check "service running" svc_running
    [ $BAD -eq 0 ] || show_install
    stop_all
}

# Requirement: a kit that cannot start changes nothing on the station.
t_install_broken_kit_changes_nothing() {
    old_install
    mk_stage v2
    : > "$ST/version-fail"
    do_install
    rm -f "$ST/version-fail"
    check "install fails" eval '[ $IRC -ne 0 ]'
    check "v1 untouched" eval '[ "$(cat "$O/VERSION")" = v1 ]'
    check "old service still running" svc_running
    check "rootfs never remounted" eval '! has "$ST/mount.log" remount'
    stop_all
}

# Requirement: an incomplete copy is refused before anything changes.
t_install_manifest_mismatch() {
    old_install
    mk_stage v2
    echo "truncated" > "$STG/lib.sh"
    do_install
    check "install fails" eval '[ $IRC -ne 0 ]'
    check "message names the manifest" has "$T/install.out" "MANIFEST"
    check "v1 untouched" eval '[ "$(cat "$O/VERSION")" = v1 ]'
    stop_all
}

# Requirement: if the init script cannot be written, the old version comes back
# (directory, login, init script, running service) and rootfs stays read-only.
t_install_remount_fails_rolls_back() {
    old_install
    echo "# init of the previous version" >> "$T/initd/S97soloist"
    cp "$T/initd/S97soloist" "$T/init.before"
    mk_stage v2
    : > "$ST/remount-fail"
    do_install
    rm -f "$ST/remount-fail"
    check "install fails" eval '[ $IRC -ne 0 ]'
    check "v1 back in place" eval '[ "$(cat "$O/VERSION")" = v1 ]'
    check "login data back" has "$O/data/credentials.json" "login-blob"
    check "init script unchanged" cmp -s "$T/initd/S97soloist" "$T/init.before"
    check "rootfs read-only" root_ro
    check "old service running again" svc_running
    [ $BAD -eq 0 ] || show_install
    stop_all
}

# Requirement: if the new service does not come up, roll back and restart the
# old one; the previous init script is restored.
t_install_start_fails_rolls_back() {
    old_install
    echo "# init of the previous version" >> "$T/initd/S97soloist"
    cp "$T/initd/S97soloist" "$T/init.before"
    : > "$T/notadir"
    echo "CACHE_DIR=\"$T/notadir/cache\"" >> "$T/test.conf"   # v2 settings are broken
    mk_stage v2
    do_install
    check "install fails" eval '[ $IRC -ne 0 ]'
    check "v1 back in place" eval '[ "$(cat "$O/VERSION")" = v1 ]'
    check "previous init script restored" cmp -s "$T/initd/S97soloist" "$T/init.before"
    check "rootfs read-only" root_ro
    check "old service running again" svc_running
    [ $BAD -eq 0 ] || show_install
    stop_all
}


# Requirement: CP15 emulation knob missing or unreadable -> Soloist never starts
# (it would livelock), the service says why.
t_cp15_missing_refuses() {
    echo "CP15_FILE=\"$T/no-such-cp15\"" >> "$O/etc/soloist.conf"
    start_svc
    wait_for 25 eval '! alive $SVC'
    check "supervisor exits" eval '! alive $SVC'
    check "soloist was never started" eval '! soloist_started'
    check "log says why" has "$T/run/svc.log" "Soloist would livelock"
    stop_svc
}

# Requirement: if cp15_barrier cannot be written back, the original value is
# kept in cp15.orig and the log says so.
t_cp15_restore_failure_kept() {
    echo 0 > "$ST/cp15"
    start_svc
    wait_for 20 soloist_started
    chmod 444 "$ST/cp15"
    stop_svc
    check "saved value kept" eval '[ "$(cat "$T/run/cp15.orig" 2>/dev/null)" = 0 ]'
    check "failure logged" has "$T/run/svc.log" "could not restore cp15_barrier to 0"
    chmod 644 "$ST/cp15"
}

# Requirement: a Soloist output line with the API key never reaches soloist.log.
t_gate_redacts_key() {
    : > "$ST/echo-key"
    start_svc
    wait_for 20 soloist_started
    wait_for 5 has "$T/run/soloist.log" "API key removed"
    check "key in no log file" eval '! cat "$T/run"/*.log* 2>/dev/null | grep -qF "test-key-not-real"'
    check "line replaced, not dropped silently" has "$T/run/soloist.log" "API key removed"
    stop_svc
}

# Requirement: if the kit cannot be moved in place after the old service was
# stopped, the old version is restored and running again.
t_install_stage_move_fails_rolls_back() {
    old_install
    mk_stage v2
    echo "$STG" > "$ST/mv-fail"
    do_install
    rm -f "$ST/mv-fail"
    check "install fails" eval '[ $IRC -eq 1 ]'
    check "v1 back in place" eval '[ "$(cat "$O/VERSION")" = v1 ]'
    check "login data in place" has "$O/data/credentials.json" "login-blob"
    check "old service running again" svc_running
    [ $BAD -eq 0 ] || show_install
    stop_all
}

# Requirement: a second install.sh while one runs is refused.
t_install_parallel_refused() {
    old_install
    mk_stage v2
    TARGET="$O" INIT_DIR="$T/initd" ROOT_MOUNTS="$ST/rootmounts" sh "$STG/install.sh" > "$T/first.out" 2>&1 &
    FIRST=$!
    sleep 0.3
    cp -a "$STG" "$T/stage2"
    TARGET="$O" INIT_DIR="$T/initd" ROOT_MOUNTS="$ST/rootmounts" sh "$T/stage2/install.sh" > "$T/second.out" 2>&1
    rc2=$?
    wait $FIRST; rc1=$?
    check "second refused" eval '[ $rc2 -ne 0 ] && has "$T/second.out" "another install.sh is running"'
    check "first succeeded" eval '[ $rc1 -eq 0 ]'
    check "v2 in place" eval '[ "$(cat "$O/VERSION")" = v2 ]'
    [ $BAD -eq 0 ] || { sed 's/^/  1> /' "$T/first.out"; sed 's/^/  2> /' "$T/second.out"; }
    stop_all
}

# Requirement: if rootfs cannot be made read-only again, the install fails
# loudly instead of reporting success with rootfs writable.
t_install_ro_restore_fails_reported() {
    old_install
    echo "# init of the previous version" >> "$T/initd/S97soloist"
    mk_stage v2
    : > "$ST/remount-ro-fail"
    do_install
    rm -f "$ST/remount-ro-fail"
    check "install does not report success" eval '[ $IRC -ne 0 ]'
    check "says rootfs is read-write" has "$T/install.out" "still read-write"
    check "says rollback incomplete" has "$T/install.out" "INCOMPLETE"
    [ $BAD -eq 0 ] || show_install
    stop_all
}


# --- tests: volume follows Alice ----------------------------------------------------
# Requirement: Soloist starts at Alice's volume (15 of 20 -> 75), not at its own 40.
t_volume_initial_from_alice() {
    echo 15 > "$ST/alice-volume"; echo 0 > "$ST/alice-muted"
    start_svc
    wait_for 20 soloist_started
    args=$(tr '\0' '\n' < "$ST/soloist.args" 2>/dev/null)
    check "started with -i 75" eval 'echo "$args" | grep -A1 -x -- "-i" | grep -qx 75'
    stop_svc
}

# Requirement: when Alice's volume changes (buttons, "Алиса, громче"), Soloist
# gets the same share; muting Alice mutes the music.
t_volume_follows_alice() {
    echo 10 > "$ST/alice-volume"; echo 0 > "$ST/alice-muted"
    start_svc
    wait_for 20 soloist_started
    sleep 1.5
    echo 18 > "$ST/alice-volume"
    wait_for 6 has "$ST/ctl.log" "^volume 90$"
    check "volume 90 after Alice 18" has "$ST/ctl.log" "^volume 90$"
    echo 1 > "$ST/alice-muted"
    wait_for 6 has "$ST/ctl.log" "^volume 0$"
    check "volume 0 when Alice is muted" has "$ST/ctl.log" "^volume 0$"
    stop_svc
}

# Requirement: an unreadable or garbled level changes nothing.
t_volume_garbage_ignored() {
    printf 'x1\n' > "$ST/alice-volume"
    start_svc
    wait_for 20 soloist_started
    sleep 2.5
    args=$(tr '\0' '\n' < "$ST/soloist.args" 2>/dev/null)
    check "no -i passed" eval '! echo "$args" | grep -qx -- "-i"'
    check "no volume command" eval '! has "$ST/ctl.log" "^volume"'
    stop_svc
}

# --- tests: deploy.py (fake adb runs the station side locally) ----------------------
fake_adb() {
    cat > "$B/adb" <<'EOF'
#!/bin/sh
[ "$1" = -s ] && shift 2
case "$1" in
connect) exit 0 ;;
push) cp "$2" "$3" ;;
shell) shift
    # the station's adbd silently drops a shell command over ~4 KB (here 1 KB)
    c="$*"; [ -e "$ST/adb-maxlen" ] && [ ${#c} -gt 1024 ] && exit 0
    # Windows adb ends shell output lines with \r\r\n
    if [ -e "$ST/adb-crlf" ]; then sh -c "$*" | awk '{ printf "%s\r\r\n", $0 }'; exit 0; fi
    exec sh -c "$*" ;;
*) exit 1 ;;
esac
EOF
    chmod +x "$B/adb"
}
deploy() { "$PY" "$HERE/../deploy.py" --serial fake --target "$O" "$@" > "$T/deploy.out" 2>&1; DRC=$?; }
show_deploy() { sed 's/^/  > /' "$T/deploy.out"; }

# Requirement: an upgrade copies only what changed and installs it.
# (S97soloist is copied because the installed one carries the real path.)
t_deploy_upgrade_copies_only_changes() {
    old_install
    fake_adb
    : > "$ST/adb-maxlen"
    mk_stage v2 "$T/kit"
    INIT_DIR="$T/initd" ROOT_MOUNTS="$ST/rootmounts" deploy --kit "$T/kit"
    check "deploy exit 0" eval '[ $DRC -eq 0 ]'
    check "only VERSION and S97soloist copied" has "$T/deploy.out" "unchanged (hard links), 2 to copy"
    check "v2 in place" eval '[ "$(cat "$O/VERSION")" = v2 ]'
    check "login data kept" has "$O/data/credentials.json" "login-blob"
    check "service running" svc_running
    [ $BAD -eq 0 ] || show_deploy
    stop_all
}

# Requirement: a first install without a key stops before touching anything.
t_deploy_first_install_needs_key() {
    cp "$O/etc/soloist.conf" "$T/test.conf"
    rm -rf "$O"; mkdir -p "$T/initd"
    fake_adb
    mk_stage v2 "$T/kit"
    INIT_DIR="$T/initd" ROOT_MOUNTS="$ST/rootmounts" deploy --kit "$T/kit"
    check "deploy fails" eval '[ $DRC -ne 0 ]'
    check "asks for --key" has "$T/deploy.out" "pass --key"
    check "nothing created" eval '[ ! -e "$O" ] && [ ! -e "$O.new" ]'
}

# Requirement: dry run changes nothing; works with Windows adb line endings.
t_deploy_dry_run() {
    old_install
    fake_adb
    : > "$ST/adb-crlf"
    mk_stage v2 "$T/kit"
    deploy --kit "$T/kit" --dry-run
    check "dry run exit 0" eval '[ $DRC -eq 0 ]'
    check "free space parsed" has "$T/deploy.out" "KB free"
    check "no staging dir" eval '[ ! -e "$O.new" ]'
    check "v1 untouched" eval '[ "$(cat "$O/VERSION")" = v1 ]'
    stop_all
}

for t in t_cache_mount_fails t_pulse_never_up t_p2p0_keeps_non_ll t_p2p0_drops_ll_only \
         t_p2p0_del_failure_reported t_config_is_used t_cp15_restored t_stop_leaves_nothing \
         t_voice_json_escape t_voice_unknown_ignored t_voice_interleaved t_voice_non_llm_route \
         t_voice_log_rotated t_gate_reaps_aplay \
         t_install_fresh t_install_upgrade_keeps_login t_install_broken_kit_changes_nothing \
         t_install_manifest_mismatch t_install_remount_fails_rolls_back t_install_start_fails_rolls_back \
         t_deploy_upgrade_copies_only_changes t_deploy_first_install_needs_key t_deploy_dry_run \
         t_cp15_missing_refuses t_cp15_restore_failure_kept t_gate_redacts_key \
         t_install_stage_move_fails_rolls_back t_install_parallel_refused t_install_ro_restore_fails_reported \
         t_volume_initial_from_alice t_volume_follows_alice t_volume_garbage_ignored; do
    run_test "$t"
done
echo "passed $PASS, failed $FAIL${FAILED:+:$FAILED}"
[ $FAIL -eq 0 ]
