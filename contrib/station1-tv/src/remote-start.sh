#!/system/bin/sh
# Station 1 only. Keep one input VM alive and bind only the current wlan0 address.
export ANDROID_DATA=/data ANDROID_ROOT=/system PATH=/system/bin:/sbin:/bin:/opt/bin:/opt/sbin
umask 077
DIR=/data/station-remote
BB=/sbin/busybox
GUARD=$DIR/guard.pid
DAEMON=$DIR/daemon.pid

ours() {
    case "$1" in ''|*[!0-9]*|0|1) return 1;; esac
    [ -r "/proc/$1/cmdline" ] || return 1
    $BB tr '\000' ' ' < "/proc/$1/cmdline" | $BB grep -q "$2"
}
stop_daemon() {
    pid=$(cat "$DAEMON" 2>/dev/null)
    if ours "$pid" 'StationRemote /data/station-remote'; then kill "$pid" 2>/dev/null; fi
    rm -f "$DAEMON"
}
if [ "$1" = stop ]; then
    pid=$(cat "$GUARD" 2>/dev/null)
    if ours "$pid" '/data/station-remote/remote-start.sh watch'; then
        kill "$pid" 2>/dev/null
        i=0
        while ours "$pid" '/data/station-remote/remote-start.sh watch' && [ "$i" -lt 6 ]; do sleep 1; i=$((i + 1)); done
        if ours "$pid" '/data/station-remote/remote-start.sh watch'; then kill -KILL "$pid" 2>/dev/null; fi
    fi
    stop_daemon
    rm -f "$GUARD"
    exit 0
fi

if [ "$1" != watch ]; then
    pid=$(cat "$GUARD" 2>/dev/null)
    if ! ours "$pid" '/data/station-remote/remote-start.sh watch'; then
        $BB setsid /system/bin/sh "$DIR/remote-start.sh" watch </dev/null >>"$DIR/guard.log" 2>&1 &
    fi
    # Preserve the existing explicit choice. The default keeps Alice running.
    if [ "$1" != now ] && $BB grep -q '^BOOT_LAUNCHER=couchy$' /data/dropbear/tv.conf 2>/dev/null; then
        i=0
        while [ "$(getprop sys.boot_completed)" != 1 ] && [ "$i" -lt 90 ]; do sleep 2; i=$((i + 1)); done
        sleep 15
        am start -n com.conreo.couchytv/.MainActivity >/dev/null 2>&1
        am force-stop ru.yandex.quasar.app
    fi
    exit 0
fi

echo $$ > "$GUARD"
trap 'stop_daemon; rm -f "$GUARD"; exit 0' TERM INT
last_ip=
while :; do
    lan_ip=$(ip -4 addr show dev wlan0 2>/dev/null | $BB awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}')
    pid=$(cat "$DAEMON" 2>/dev/null)
    if [ -n "$lan_ip" ]; then
        if [ "$lan_ip" != "$last_ip" ] || ! ours "$pid" 'StationRemote /data/station-remote'; then
            stop_daemon
            # Bound log growth; never print commands, text, passwords or VPN links.
            [ ! -f "$DIR/server.log" ] || [ "$($BB wc -c < "$DIR/server.log")" -lt 131072 ] || mv "$DIR/server.log" "$DIR/server.log.1"
            CLASSPATH="$DIR/station-remote.jar" /system/bin/app_process /system/bin StationRemote "$DIR" "$lan_ip" 8080 </dev/null >>"$DIR/server.log" 2>&1 &
            echo $! > "$DAEMON"
            last_ip=$lan_ip
        fi
    else
        stop_daemon
        last_ip=
    fi
    sleep 3
done
