#!/usr/bin/env bash
# Вход Spotify на Станции 2 через OAuth — нужен один раз и после сброса колонки.
# librespot принимает ответ OAuth на 127.0.0.1:5588 колонки; этот порт пробрасывается
# на Mac по SSH, а страница входа открывается в браузере по умолчанию. После входа
# librespot сохраняет его в spotify-cache, и обычная служба дальше входит сама.
#
#   ./spotify-login.sh <IP колонки>
set -euo pipefail

IP=${1:?"использование: $0 <IP колонки>"}
HERE=$(cd "$(dirname "$0")" && pwd)
KEY=$HOME/.ssh/yandex_station2
PORT=5588
LOG=$(mktemp)
SSH_PID=
trap 'rm -f "$LOG"; [ -n "$SSH_PID" ] && kill "$SSH_PID" 2>/dev/null; true' EXIT

ssh_() {
  ssh -i "$KEY" -p 2222 -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
      -o UserKnownHostsFile="$HERE/known_hosts" "$@"
}

# Временный librespot с OAuth вместо службы, с тем же кэшем
ssh_ -o ExitOnForwardFailure=yes -L "$PORT:127.0.0.1:$PORT" "root@$IP" '. /data/local/opt/ap2/common.sh
  for p in $(pids_matching "$B/librespot"); do kill "$p"; done; sleep 1
  exec "$B/librespot" --enable-oauth --oauth-port '"$PORT"' --name "Станция 2" \
    --device-type speaker --backend subprocess --device "$AP/spotify-sink.sh" --format S16 \
    --cache "$AP/spotify-cache" --disable-audio-cache --zeroconf-backend avahi 2>&1' > "$LOG" 2>&1 &
SSH_PID=$!

for _ in $(seq 1 30); do grep -q 'accounts.spotify.com' "$LOG" && break; sleep 1; done
URL=$(grep -o 'https://accounts.spotify.com/authorize[^ ]*' "$LOG" | head -1)
[ -n "$URL" ] || { cat "$LOG"; echo "ОШИБКА: librespot не выдал ссылку входа" >&2; exit 1; }
open "$URL"
echo "Войдите в Spotify в открывшемся браузере и нажмите «Принимаю»…"

for _ in $(seq 1 300); do
  grep -q 'Authenticated as' "$LOG" && break
  grep -qE 'ERROR|Failed' "$LOG" && { cat "$LOG"; exit 1; }
  sleep 1
done
grep -q 'Authenticated as' "$LOG" || { echo "ОШИБКА: вход не завершился за 5 минут" >&2; exit 1; }
echo "Вход выполнен, возвращаю обычную службу"

ssh_ "root@$IP" '. /data/local/opt/ap2/common.sh
  for p in $(pids_matching "--enable-oauth"); do kill "$p"; done; sleep 2
  $AP/ap2.sh spotify; sleep 5; tail -3 $LOGD/spotify.log'
