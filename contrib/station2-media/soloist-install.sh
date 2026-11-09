#!/usr/bin/env bash
# Spotify Soloist на Станцию 2 поверх набора AirPlay (install.sh), по SSH:
#   - окружение из build/soloist-build.sh (glibc, PulseAudio) в ap2/soloist;
#   - soloist.sh, sink.sh и настройки PulseAudio, ключ Soloist в soloist/etc/api-key;
#   - обновлённые ap2.sh, audio-owner.sh, voice-spotify.sh, spotify-api.sh, etc/asound.conf;
#   - сам soloist — с CDN Spotify прямо на колонку (soloist.sh update).
# librespot при этом не запускается (ap2.sh пропускает его, если есть soloist/).
# Повторный запуск обновляет файлы; ключ можно не передавать, если он уже на колонке.
#
#   ./soloist-install.sh <IP колонки> [<ключ Soloist>]
#   ./soloist-install.sh <IP колонки> --remove   # убрать Soloist; librespot вернётся, если он есть
set -euo pipefail

IP=${1:?"использование: $0 <IP колонки> [<ключ Soloist> | --remove]"}
ARG=${2:-}
HERE=$(cd "$(dirname "$0")" && pwd)
BUNDLE=$HERE/build/out/soloist
KEY=$HOME/.ssh/yandex_station2
AP=/data/local/opt/ap2

die() { echo "ОШИБКА: $*" >&2; exit 1; }
ssh_() {
  ssh -i "$KEY" -p 2222 -o IdentitiesOnly=yes -o ConnectTimeout=5 -o BatchMode=yes \
      -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$HERE/known_hosts" \
      "root@$IP" "$@"
}
# Владелец root в архиве: --uid/--gid у bsdtar (macOS), --owner/--group у GNU tar (Linux)
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  tar_() { tar --format ustar --owner=0 --group=0 "$@"; }
else
  tar_() { COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 "$@"; }
fi

ssh_ 'echo ok' | grep -q ok || die "нет SSH по ключу на $IP:2222 — сначала install.sh"

if [ "$ARG" = "--remove" ]; then
  echo "==> убираю Soloist"
  ssh_ "[ -x $AP/soloist/soloist.sh ] && $AP/soloist/soloist.sh stop; rm -rf $AP/soloist /run/soloist &&
    $AP/ap2.sh restart >/dev/null 2>&1; echo ok" | grep -q ok || die "не удалилось"
  echo "Готово. Устройство Soloist останется в списке Spotify, пока его не забудет аккаунт."
  exit 0
fi

[ -x "$BUNDLE/bin/pulseaudio" ] ||
  die "нет $BUNDLE — сначала build/soloist-build.sh (см. docs/recipes/spotify.md)"
ssh_ "[ -x $AP/ap2.sh ] && [ -x $AP/bin/curl ] && [ -x $AP/bin/jq ] && echo ok" | grep -q ok ||
  die "на колонке нет набора с curl и jq — сначала install.sh и build/voice-build.sh"
if [ -z "$ARG" ]; then
  ssh_ "[ -s $AP/soloist/etc/api-key ] && echo ok" | grep -q ok ||
    die "передайте ключ Soloist вторым аргументом (developer.spotify.com/dashboard/soloist)"
fi

echo "==> файлы"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/ap2/soloist/etc" "$TMP/ap2/etc"
cp -R "$BUNDLE/lib" "$BUNDLE/bin" "$BUNDLE/modules" "$TMP/ap2/soloist/"
cp "$HERE/device/soloist/"* "$TMP/ap2/soloist/"
cp "$HERE/device/ap2.sh" "$HERE/device/common.sh" "$HERE/device/audio-owner.sh" \
   "$HERE/device/voice-spotify.sh" "$HERE/device/spotify-api.sh" "$TMP/ap2/"
cp "$HERE/device/etc/asound.conf" "$TMP/ap2/etc/"
chmod 755 "$TMP/ap2/"*.sh "$TMP/ap2/soloist/"*.sh "$TMP/ap2/soloist/bin/"*
tar_ -C "$TMP" -czf - ap2 | ssh_ "gzip -dc | tar -xf - -C /data/local/opt && echo ok" | grep -q ok ||
  die "не распаковалось на колонке"

if [ -n "$ARG" ]; then
  echo "==> ключ Soloist"
  # ключ идёт через stdin, в командную строку колонки не попадает
  printf '%s\n' "$ARG" | ssh_ "umask 077; cat > $AP/soloist/etc/api-key && echo ok" | grep -q ok ||
    die "ключ не записался"
fi

echo "==> soloist с CDN Spotify"
ssh_ "[ -x $AP/soloist/soloist ] || $AP/soloist/soloist.sh update; [ -x $AP/soloist/soloist ] && echo ok" |
  grep -q ok || die "soloist не скачался (нужен доступ к soloist-builds.spotifycdn.com)"

echo "==> перезапуск набора"
# librespot гасим: с Soloist он не нужен; новые скрипты подхватятся после перезапуска
ssh_ "$AP/ap2.sh restart >/dev/null 2>&1"
sleep 10
ssh_ "$AP/soloist/soloist.sh status; tail -3 /data/local/tmp/ap2/soloist.log"

echo
echo "Готово. В Spotify на телефоне в той же сети выберите устройство «Станция 2» и включите"
echo "трек — первый раз Soloist входит только так, дальше помнит вход в soloist/data."
