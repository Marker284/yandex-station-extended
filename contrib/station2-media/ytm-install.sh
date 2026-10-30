#!/usr/bin/env bash
# YouTube Music на Станцию 2 поверх набора AirPlay (install.sh), по SSH:
#   - Python 3 из Entware (нужен yse bootstrap), свежий yt-dlp с GitHub в ytm/lib;
#   - ytm-dec из build/ytm-build.sh, плеер ytm/ytmd.py, ytm.sh, ytm-sink.sh;
#   - обновлённые ap2.sh, audio-owner.sh, voice-spotify.sh и etc/asound.conf.
# Повторный запуск обновляет файлы и yt-dlp.
#
#   ./ytm-install.sh <IP колонки>
#   ./ytm-install.sh <IP колонки> --remove   # убрать плеер; Python и Entware остаются
set -euo pipefail

IP=${1:?"использование: $0 <IP колонки> [--remove]"}
MODE=${2:-}
HERE=$(cd "$(dirname "$0")" && pwd)
BUNDLE=$HERE/build/out/ap2
KEY=$HOME/.ssh/yandex_station2
AP=/data/local/opt/ap2
# То же, от чего зависит пакет yt-dlp в Entware; сам пакет не берём — он отстаёт от YouTube
PKGS="python3-light python3-asyncio python3-codecs python3-ctypes python3-email python3-logging
  python3-openssl python3-sqlite3 python3-urllib python3-uuid python3-xml ca-certificates curl"

die() { echo "ОШИБКА: $*" >&2; exit 1; }
ssh_() {
  ssh -i "$KEY" -p 2222 -o IdentitiesOnly=yes -o ConnectTimeout=5 -o BatchMode=yes \
      -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$HERE/known_hosts" \
      "root@$IP" "$@"
}
tar_() { COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 "$@"; }

ssh_ 'echo ok' | grep -q ok || die "нет SSH по ключу на $IP:2222 — сначала install.sh"

if [ "$MODE" = "--remove" ]; then
  echo "==> убираю YouTube Music"
  ssh_ ". $AP/common.sh; for m in \"\$AP/ytm/ytmd.py\" \"\$B/ytm-dec\" \"\$B/aplay -q -D youtube\"; do
      for p in \$(pids_matching \"\$m\"); do kill \$p 2>/dev/null; done; done
    rm -rf $AP/ytm $AP/ytm.sh $AP/ytm-sink.sh $AP/bin/ytm-dec /run/ytm.sock /tmp/ytm.playing && echo ok" |
    grep -q ok || die "не удалилось"
  echo "Готово. ap2.sh и audio-owner.sh без ytm/ просто пропускают YouTube Music."
  echo "Python из Entware остался; убрать: ssh … 'opkg remove --autoremove python3-light'."
  exit 0
fi

[ -x "$BUNDLE/bin/ytm-dec" ] || die "нет $BUNDLE/bin/ytm-dec — сначала build/ytm-build.sh (см. docs/recipes/youtube-music.md)"
ssh_ '[ -x /opt/bin/opkg ] && echo ok' | grep -q ok ||
  die "на колонке нет Entware — сначала yse (docs/start/packages.md): yse bootstrap"

echo "==> Python из Entware"
# shellcheck disable=SC2086
ssh_ "export PATH=/opt/bin:/opt/sbin:\$PATH; opkg update >/dev/null 2>&1; opkg install $(echo $PKGS) >/tmp/ytm-opkg.log 2>&1 &&
  python3 -c 'import ssl, urllib.request, http.client' && echo ok" | grep -q ok ||
  die "не поставился Python (лог на колонке: /tmp/ytm-opkg.log)"

echo "==> файлы"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/ap2/ytm" "$TMP/ap2/bin" "$TMP/ap2/etc"
cp "$HERE/device/ytm/"*.py "$TMP/ap2/ytm/"
cp "$HERE/device/ytm.sh" "$HERE/device/ytm-sink.sh" "$HERE/device/ap2.sh" "$HERE/device/common.sh" \
   "$HERE/device/audio-owner.sh" "$HERE/device/voice-spotify.sh" "$TMP/ap2/"
cp "$HERE/device/etc/asound.conf" "$TMP/ap2/etc/"
cp "$BUNDLE/bin/ytm-dec" "$TMP/ap2/bin/"
chmod 755 "$TMP/ap2/"*.sh "$TMP/ap2/bin/ytm-dec"
tar_ -C "$TMP" -czf - ap2 | ssh_ "gzip -dc | tar -xf - -C /data/local/opt && echo ok" | grep -q ok ||
  die "не распаковалось на колонке"

echo "==> yt-dlp"
ssh_ "$AP/ytm.sh update" || die "yt-dlp не скачался (нужен доступ к github.com)"

echo "==> перезапуск распорядителя звука"
# Новые audio-owner.sh и voice-spotify.sh подхватятся только после перезапуска
ssh_ ". $AP/common.sh; for m in $AP/audio-owner.sh $AP/voice-spotify.sh; do
    for p in \$(pids_matching \$m); do kill \$p 2>/dev/null; done; done; $AP/ap2.sh start"
sleep 8
ssh_ "$AP/ap2.sh status | grep -E 'ytmd|youtube|owner'; tail -3 /data/local/tmp/ap2/ytm.log"

echo
echo "Готово. Проверка с консоли колонки: $AP/ytm.sh play маркул"
echo "Голосом: «Алиса, поставь Маркула» (или «… в ютубе», если голос Spotify тоже настроен)."
