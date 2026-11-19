#!/system/bin/sh
# Tested: Yandex Station 1, Android 6.0.1, quasar 2.369.5.46, AliceBridge, Xray-core 26.11.9, Nov 2026.
# Finds the subscription servers through which the Gemini API answers (Google refuses some exit locations).
# Runs a temporary Xray with one SOCKS port per server, asks the API's model list through each, and writes
# md5 sums of the working servers to /data/xray/google-ok.list (used by sub-update.sh for Google routing).
# The API key is read from /data/llm/key and passed to curl via stdin, never argv.
BB=/system/bin/busybox-smp; DIR=/data/xray; KEY=/data/llm/key; CA=/system/vendor/quasar/ca-certificates.crt
export PATH=/sbin:/system/sbin:/system/bin:/system/xbin
umask 077
[ -s $DIR/sub.outs ] || { echo 'no server list yet (run sub-update.sh first)'; exit 1; }
[ -s $KEY ] || { echo 'no Gemini key (/data/llm/key)'; exit 1; }
T=$DIR/gtest; rm -rf $T; mkdir $T
{
  printf '{"log":{"loglevel":"none"},"inbounds":['
  $BB awk '{ printf "%s{\"tag\":\"in-%d\",\"listen\":\"127.0.0.1\",\"port\":%d,\"protocol\":\"socks\",\"settings\":{\"udp\":false}}", (NR > 1 ? "," : ""), NR, 20000 + NR }' $DIR/sub.outs
  printf '],"outbounds":['
  $BB awk '{ sub(/"tag":"proxy"/, "\"tag\":\"t-" NR "\""); printf "%s%s", (NR > 1 ? "," : ""), $0 }' $DIR/sub.outs
  printf '],"routing":{"rules":['
  $BB awk '{ printf "%s{\"type\":\"field\",\"inboundTag\":[\"in-%d\"],\"outboundTag\":\"t-%d\"}", (NR > 1 ? "," : ""), NR, NR }' $DIR/sub.outs
  printf ']}}\n'
} > $T/c.json
$DIR/xray run -c $T/c.json > $T/x.log 2>&1 &
XP=$!
sleep 3
kill -0 $XP 2>/dev/null || { echo 'test xray failed to start'; tail -3 $T/x.log; rm -rf $T; exit 1; }
n=$($BB wc -l < $DIR/sub.outs); i=1; pids=''
# NB: a bare "wait" would also wait for the test Xray above, so only the curl jobs are awaited.
while [ $i -le $n ]; do
  (
    code=$({ echo 'url = "https://generativelanguage.googleapis.com/v1beta/openai/models"'; printf 'header = "Authorization: Bearer %s"\n' "$(cat $KEY)"; } |
      curl -s -o $T/r$i -m 20 --cacert $CA --proxy socks5h://127.0.0.1:$((20000 + i)) -K - -w '%{http_code}')
    echo "$i $code" > $T/c$i
  ) &
  pids="$pids $!"
  if [ $((i % 8)) -eq 0 ]; then wait $pids; pids=''; fi
  i=$((i + 1))
done
[ -n "$pids" ] && wait $pids
kill $XP 2>/dev/null
: > $DIR/google-ok.list.new; ok=0; loc=0; other=0
i=1
while [ $i -le $n ]; do
  code=$(cut -d' ' -f2 $T/c$i 2>/dev/null)
  if [ "$code" = 200 ]; then $BB sed -n "${i}p" $DIR/sub.outs | $BB md5sum | $BB cut -c1-32 >> $DIR/google-ok.list.new; ok=$((ok + 1))
  elif grep -q 'location is not supported' $T/r$i 2>/dev/null; then loc=$((loc + 1))
  else other=$((other + 1)); fi
  i=$((i + 1))
done
mv $DIR/google-ok.list.new $DIR/google-ok.list
rm -rf $T
echo "$($BB date '+%F %T') gemini test: $ok of $n servers work, $loc refused by location, $other no answer" | tee -a $DIR/sub.log
