#!/system/bin/sh
# Tested: Yandex Station 1, Android 6.0.1, quasar 2.369.5.46, AliceBridge, Xray-core 26.11.9, Nov 2026.
# Rollback: sh /data/xray/run.sh stop; restore config.prev.json if needed.
# NB: busybox 1.20 grep -x is broken on this station; use grep "^...$" instead.
# Downloads the Xray-JSON subscription, puts EVERY server ("proxy" outbound) behind a leastPing balancer
# with health checks, tests the config and restarts Xray only if the server set changed.
# Usage: sub-update.sh [reason] | sub-update.sh regoogle (re-test Gemini on the current list, no download). URL is read from /data/xray/sub.url (600) and passed to curl via stdin, never argv.
BB=/system/bin/busybox-smp; DIR=/data/xray; CA=/system/vendor/quasar/ca-certificates.crt
export PATH=/sbin:/system/sbin:/system/bin:/system/xbin
umask 077
log() { echo "$($BB date '+%F %T') $*" >> $DIR/sub.log; echo "$*"; }
[ -s $DIR/sub.log ] && [ $($BB wc -l < $DIR/sub.log) -gt 400 ] && { $BB tail -200 $DIR/sub.log > $DIR/sub.log.t; mv $DIR/sub.log.t $DIR/sub.log; }
[ -s $DIR/sub.url ] || { log "no subscription URL saved (/data/xray/sub.url)"; exit 1; }
L=$DIR/sub.lockd  # mkdir lock (mksh closes extra fds on exec, so flock on an fd does not work here)
if ! mkdir $L 2>/dev/null; then
    [ $(( $($BB date +%s) - $($BB stat -c %Y $L 2>/dev/null || echo 0) )) -gt 600 ] && rmdir $L 2>/dev/null && mkdir $L 2>/dev/null || { echo 'update already running'; exit 0; }
fi
trap 'rmdir $L 2>/dev/null' EXIT
log "update started (${1:-manual})"

if [ "$1" = regoogle ]; then
    [ -s $DIR/sub.outs ] || { log "no saved server list; run a normal update first"; exit 1; }
    via=local; new=$(cat $DIR/sub.md5 2>/dev/null)
else
serial=$(getprop ro.serialno)
hwid=$(printf 'station1:%s' "$serial" | $BB sha256sum | $BB cut -c1-16)
fetch() { # $1 = extra curl option (e.g. via the tunnel)
    rm -f $DIR/sub.raw
    { printf 'url = "%s"\n' "$($BB head -1 $DIR/sub.url | $BB tr -d '\r\n')"; } | curl -s -f -m 40 --cacert $CA $1 -K - \
        -A 'v2rayNG/1.9.45' -H "x-hwid: $hwid" -H 'x-device-os: Android' -H 'x-ver-os: 6.0.1' -H 'x-device-model: Yandex Station' \
        -o $DIR/sub.raw && [ "$($BB head -c 1 $DIR/sub.raw)" = "[" ]
}
if fetch ''; then via=direct
elif fetch '--socks5-hostname 127.0.0.1:10808'; then via=tunnel
else log "download failed (direct and via tunnel); config unchanged"; rm -f $DIR/sub.raw; exit 1; fi

# The subscription is one huge minified line; fold cuts it into 256-char pieces (linear time) and extract.awk,
# a small JSON scanner that keeps its state across pieces, prints every "proxy" outbound, one per line.
$BB fold -w 256 $DIR/sub.raw | $BB awk -f $DIR/extract.awk | $BB sort -u > $DIR/sub.outs.new
rm -f $DIR/sub.raw
cnt=$($BB wc -l < $DIR/sub.outs.new)
[ "$cnt" -gt 0 ] || { log "subscription has no usable servers (via $via); config unchanged"; rm -f $DIR/sub.outs.new; exit 1; }
new=$($BB md5sum < $DIR/sub.outs.new | $BB cut -c1-32)
if [ "$new" = "$(cat $DIR/sub.md5 2>/dev/null)" ] && [ -s $DIR/config.json ] && [ -s $DIR/sub.outs ]; then
    log "subscription unchanged ($cnt servers, via $via)"; rm -f $DIR/sub.outs.new; exit 0
fi
mv $DIR/sub.outs.new $DIR/sub.outs
fi

# Mark servers known to work with the Gemini API (google-ok.list = md5 of each outbound line, from gemini-test.sh).
mark_google() {
    : > $DIR/google.lines
    [ -s $DIR/google-ok.list ] || return 0
    i=1
    while IFS= read -r line; do
        m=$(printf '%s\n' "$line" | $BB md5sum | $BB cut -c1-32)
        $BB grep -q "^$m$" $DIR/google-ok.list && echo $i >> $DIR/google.lines
        i=$((i + 1))
    done < $DIR/sub.outs
}
tagof() { $BB grep -q "^$1$" $DIR/google.lines && echo "gproxy-$1" || echo "proxy-$1"; }
build() {
  first=$(tagof 1); g1=$($BB head -1 $DIR/google.lines)
{
  printf '{"log":{"loglevel":"warning"},"dns":{"servers":["1.1.1.1","8.8.8.8"]},'
  printf '"inbounds":[{"tag":"np-redirect","listen":"127.0.0.1","port":12345,"protocol":"dokodemo-door","settings":{"network":"tcp","followRedirect":true},"sniffing":{"enabled":true,"destOverride":["http","tls"],"routeOnly":true}},'
  printf '{"tag":"socks-test","listen":"127.0.0.1","port":10808,"protocol":"socks","settings":{"udp":false}}],"outbounds":['
  $BB awk -v gl=$DIR/google.lines 'BEGIN { while ((getline l < gl) > 0) g[l] = 1 } { t = (NR in g) ? "gproxy-" : "proxy-"; sub(/"tag":"proxy"/, "\"tag\":\"" t NR "\""); printf "%s%s", (NR > 1 ? "," : ""), $0 }' $DIR/sub.outs
  printf ',{"tag":"direct","protocol":"freedom"}],'
  printf '"burstObservatory":{"subjectSelector":["proxy-","gproxy-"],"pingConfig":{"destination":"https://api-v2.soundcloud.com/","interval":"5m","sampling":2,"timeout":"8s"}},'
  printf '"routing":{"balancers":[{"tag":"auto","selector":["proxy-","gproxy-"],"strategy":{"type":"leastPing"},"fallbackTag":"%s"}' "$first"
  [ -n "$g1" ] && printf ',{"tag":"google","selector":["gproxy-"],"strategy":{"type":"leastPing"},"fallbackTag":"gproxy-%s"}' "$g1"
  printf '],"rules":['
  [ -n "$g1" ] && printf '{"type":"field","inboundTag":["np-redirect","socks-test"],"domain":["domain:googleapis.com"],"balancerTag":"google"},'
  printf '{"type":"field","inboundTag":["np-redirect","socks-test"],"balancerTag":"auto"}]}}\n'
} > $DIR/config.new.json
}
# Drop servers that this Xray rejects (one per try) instead of failing the whole update.
validate() {
  tries=0
  while :; do
    mark_google; build
    $DIR/xray run -test -format json -c $DIR/config.new.json > $DIR/test.err 2>&1 && return 0
    bad=$($BB grep -o 'with tag g*proxy-[0-9]*' $DIR/test.err | $BB head -1 | $BB sed 's/.*-//')
    tries=$((tries+1))
    if [ -z "$bad" ] || [ $tries -gt 20 ] || [ "$($BB wc -l < $DIR/sub.outs)" -le 1 ]; then
        log "new config failed the Xray test; config unchanged"; rm -f $DIR/config.new.json; return 1
    fi
    $BB sed -i "${bad}d" $DIR/sub.outs; log "server #$bad rejected by Xray, skipped"
  done
}
validate || exit 1
if [ -s /data/llm/key ] && [ -x $DIR/gemini-test.sh ]; then
    sh $DIR/gemini-test.sh >/dev/null 2>&1 || log "gemini test failed"
    validate || exit 1
fi
cnt=$($BB wc -l < $DIR/sub.outs); gcnt=$($BB wc -l < $DIR/google.lines)
[ -s $DIR/config.json ] && cp -p $DIR/config.json $DIR/config.prev.json
mv $DIR/config.new.json $DIR/config.json
echo "$new" > $DIR/sub.md5
log "installed $cnt servers, $gcnt of them for Google/Gemini (via $via); restarting Xray"
sh $DIR/run.sh restart >/dev/null 2>&1 && log "Xray restarted" || log "Xray restart FAILED, see xray.log"
