#!/system/bin/sh
# Tested: Yandex Station 1, Android 6.0.1, quasar 2.369.5.46, AliceBridge, Xray-core 26.11.9, Nov 2026.
# Rollback: sh /data/xray/run.sh stop, delete the autostart line from start.sh, rm -r /data/xray.
# Xray for NewPipe only: transparent redirect of NewPipe's TCP into a local Xray.
# Usage: run.sh [start|stop|restart|status|update]. start also launches watch.sh (auto subscription refresh). Safe to call repeatedly. Alice/other apps are not affected.
BB=/system/bin/busybox-smp
DIR=/data/xray
PORT=12345
export PATH=/sbin:/system/sbin:/system/bin:/system/xbin
uid_of() { $BB awk -v p="$1" '$1==p {print $2; exit}' /data/system/packages.list 2>/dev/null; }
running() { p=$(cat $DIR/xray.pid 2>/dev/null); [ -n "$p" ] && [ -r /proc/$p/cmdline ] && $BB tr '\000' ' ' < /proc/$p/cmdline | $BB grep -q "^$DIR/xray run"; }
watch_running() { p=$(cat $DIR/watch.pid 2>/dev/null); [ -n "$p" ] && [ -r /proc/$p/cmdline ] && $BB tr '\000' ' ' < /proc/$p/cmdline | $BB grep -q "$DIR/watch.sh"; }
rules_off() {
    while iptables -t nat -D OUTPUT -p tcp -m owner --uid-owner "$1" -j XRAY_NP 2>/dev/null; do :; done
    iptables -t nat -F XRAY_NP 2>/dev/null; iptables -t nat -X XRAY_NP 2>/dev/null
}
case "${1:-start}" in
start)
    [ -s $DIR/config.json ] || { echo 'No config.json'; exit 1; }
    [ -f $DIR/disabled ] && { echo 'Disabled (remove /data/xray/disabled)'; exit 0; }
    if ! running; then
        $BB setsid $DIR/xray run -c $DIR/config.json </dev/null >>$DIR/xray.log 2>&1 &
        echo $! > $DIR/xray.pid; sleep 2
        running || { echo 'Xray failed to start, see /data/xray/xray.log'; exit 1; }
    fi
    uid=$(uid_of org.schabi.newpipe); case "$uid" in ''|*[!0-9]*) echo 'NewPipe UID not found'; exit 1;; esac
    rules_off "$uid"
    iptables -t nat -N XRAY_NP
    for net in 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 224.0.0.0/4; do iptables -t nat -A XRAY_NP -d $net -j RETURN; done
    iptables -t nat -A XRAY_NP -p tcp -j REDIRECT --to-ports $PORT
    iptables -t nat -A OUTPUT -p tcp -m owner --uid-owner "$uid" -j XRAY_NP
    watch_running || { $BB setsid sh $DIR/watch.sh </dev/null >>$DIR/watch.log 2>&1 & }
    echo "Xray running (pid $(cat $DIR/xray.pid)); NewPipe uid $uid redirected";;
restart)
    running && kill "$(cat $DIR/xray.pid)"; rm -f $DIR/xray.pid; sleep 1; exec sh $DIR/run.sh start;;
update)
    exec sh $DIR/sub-update.sh manual;;
selftest)
    C=/system/vendor/quasar/ca-certificates.crt
    for u in https://soundcloud.com/ https://api-v2.soundcloud.com/; do
        echo "test $u $(curl --cacert $C -s -o /dev/null -m 20 --socks5-hostname 127.0.0.1:10808 -w '%{http_code}' $u)"
    done
    echo "exit-country $(curl --cacert $C -s -m 20 --socks5-hostname 127.0.0.1:10808 https://ifconfig.co/country)"
    echo "last server used: $($BB grep -oE 'socks-test (->|>>) g?proxy-[0-9]+' $DIR/xray.log | $BB tail -1)";;
setup)
    sh $DIR/sub-update.sh first-setup; echo 'waiting 40 s for server health checks...'; sleep 40
    sh $DIR/run.sh status; exec sh $DIR/run.sh selftest;;
stop)
    uid=$(uid_of org.schabi.newpipe); [ -n "$uid" ] && rules_off "$uid"
    watch_running && kill "$(cat $DIR/watch.pid)"; rm -f $DIR/watch.pid
    running && kill "$(cat $DIR/xray.pid)"; rm -f $DIR/xray.pid; echo 'Xray and watchdog stopped, rules removed';;
status)
    running && echo "xray: running pid $(cat $DIR/xray.pid)" || echo 'xray: stopped'
    watch_running && echo "watchdog: running pid $(cat $DIR/watch.pid)" || echo 'watchdog: stopped'
    echo "servers: $($BB grep -o '"tag":"g*proxy-[0-9]*"' $DIR/config.json | $BB wc -l), for Google: $($BB grep -o '"tag":"gproxy-[0-9]*"' $DIR/config.json | $BB wc -l); subscription URL saved: $([ -s $DIR/sub.url ] && echo yes || echo no)"
    $BB tail -3 $DIR/sub.log 2>/dev/null
    iptables -t nat -S OUTPUT 2>/dev/null | $BB grep XRAY_NP || iptables -t nat -L OUTPUT -n | $BB grep XRAY_NP || echo 'rules: none';;
boot)
    n=0; while [ "$(getprop sys.boot_completed)" != 1 ] && [ $n -lt 90 ]; do sleep 2; n=$((n+1)); done
    sleep 5; exec sh $DIR/run.sh start;;
*) echo 'Usage: run.sh [start|stop|restart|status|update|selftest|setup]'; exit 2;;
esac
