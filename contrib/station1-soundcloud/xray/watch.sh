#!/system/bin/sh
# Tested: Yandex Station 1, Android 6.0.1, quasar 2.369.5.46, AliceBridge, Xray-core 26.11.9, Nov 2026.
# Xray watchdog (started by run.sh). Every 60 s: restarts Xray if it died, checks the tunnel.
# Refreshes the subscription every 12 h, and right away when the tunnel failed 3 checks in a row
# (at most once per 20 min while it stays down).
BB=/system/bin/busybox-smp; DIR=/data/xray; CA=/system/vendor/quasar/ca-certificates.crt
export PATH=/sbin:/system/sbin:/system/bin:/system/xbin
PERIOD=43200; RETRY=1200; fails=0
echo $$ > $DIR/watch.pid
while :; do
    sleep 60
    [ -f $DIR/disabled ] && continue
    p=$(cat $DIR/xray.pid 2>/dev/null)
    [ -n "$p" ] && [ -d /proc/$p ] || { echo "$($BB date '+%F %T') xray not running, starting"; sh $DIR/run.sh start; }
    code=$(curl -s -o /dev/null -m 15 --cacert $CA --socks5-hostname 127.0.0.1:10808 -w '%{http_code}' https://api-v2.soundcloud.com/)
    # any HTTP answer from SoundCloud (401/404 without a key) means the tunnel works; 000 = no answer
    case "$code" in ''|000) fails=$((fails+1));; *) fails=0;; esac
    [ -s $DIR/sub.url ] || continue
    now=$($BB date +%s); last=$(cat $DIR/sub.last 2>/dev/null); last=${last:-0}
    reason=''
    [ $((now - last)) -ge $PERIOD ] && reason=periodic
    [ $fails -ge 3 ] && [ $((now - last)) -ge $RETRY ] && reason="tunnel down for $fails checks"
    if [ -n "$reason" ]; then
        echo $now > $DIR/sub.last
        sh $DIR/sub-update.sh "$reason" >/dev/null 2>&1
        fails=0
    fi
done
