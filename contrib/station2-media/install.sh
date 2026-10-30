#!/usr/bin/env bash
# Установка на Станцию 2. Окно root ADB после DNS-метода короткое, поэтому в два этапа:
#   1) по ADB — только SSH (dropbear на 2222, вход по ключу ~/.ssh/yandex_station2), <1 МБ;
#   2) по SSH — AirPlay 2 в /data/local/opt/ap2, отключение обновлений (yandex-noupdate.sh
#      из вики, бэкап оригиналов — на Mac), автозапуск /etc/init.d/S97ap2.
# Повторный запуск безопасен: ключ хоста и бэкапы не перезаписываются.
#
#   ./install.sh <IP колонки>             # оба этапа
#   ./install.sh <IP колонки> --ssh-only  # SSH уже есть — только этап 2
set -euo pipefail

IP=${1:?"использование: $0 <IP колонки> [--ssh-only]"}
MODE=${2:-}
HERE=$(cd "$(dirname "$0")" && pwd)
BUNDLE=$HERE/build/out/ap2
KEY=$HOME/.ssh/yandex_station2
BACKUP=$HERE/backup
AP=/data/local/opt/ap2
SERIAL=$IP:5555
SSH_FILES="ap2/bin/dropbear ap2/bin/dropbearkey ap2/lib/ld-musl-aarch64.so.1
  ap2/lib/libc.musl-aarch64.so.1 ap2/lib/libz.so.1 ap2/lib/libutmps.so.0.1
  ap2/lib/libskarnet.so.2.15 ap2/common.sh ap2/ap2.sh ap2/etc/authorized_keys"

die() { echo "ОШИБКА: $*" >&2; exit 1; }
adb_() { adb -s "$SERIAL" "$@"; }
# adbd колонки не всегда пробрасывает код возврата — смотрим на вывод
sh_() { adb_ shell "$1" | tr -d '\r'; }
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

[ -x "$BUNDLE/bin/shairport-sync" ] || die "нет сборки $BUNDLE — сначала build/ap2-build.sh (см. docs/recipes/airplay.md)"
mkdir -p "$BACKUP"

echo "==> пакет"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/ap2/etc"
cp -R "$BUNDLE/bin" "$BUNDLE/lib" "$TMP/ap2/"
cp "$HERE/device/"*.sh "$TMP/ap2/"
cp "$HERE/device/etc/"* "$TMP/ap2/etc/"
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C yandex-station2 -f "$KEY"
cp "$KEY.pub" "$TMP/ap2/etc/authorized_keys"
# Имя хоста для avahi — то, что колонка уже публикует по mDNS (hostname у неё другой)
# dig есть в macOS; в Linux его часто нет (dnsutils), там пробуем avahi-resolve-address
MDNS=
if command -v dig >/dev/null; then
  MDNS=$(dig +short +time=2 +tries=1 -x "$IP" @224.0.0.251 -p 5353 2>/dev/null | head -1 | sed 's/\.local\.$//' || true)
elif command -v avahi-resolve-address >/dev/null; then
  MDNS=$(avahi-resolve-address "$IP" 2>/dev/null | awk '{ print $2 }' | sed 's/\.local$//' || true)
fi
[ -n "$MDNS" ] && echo "$MDNS" > "$TMP/ap2/etc/hostname"
echo "    mDNS-имя: ${MDNS:-не найдено, возьмём hostname колонки}"

if [ "$MODE" != "--ssh-only" ]; then
  echo "==> этап 1: SSH по ADB $SERIAL"
  adb connect "$SERIAL" >/dev/null || true
  [ "$(sh_ 'id -u')" = 0 ] || die "нет root ADB на $SERIAL"
  # shellcheck disable=SC2086
  tar_ -C "$TMP" -czf "$TMP/ap2-ssh.tgz" $SSH_FILES
  adb_ push "$TMP/ap2-ssh.tgz" /data/local/tmp/ap2-ssh.tgz >/dev/null
  [ "$(sh_ "mkdir -p /data/local/opt && gzip -dc /data/local/tmp/ap2-ssh.tgz | tar -xf - -C /data/local/opt && rm /data/local/tmp/ap2-ssh.tgz && $AP/ap2.sh ssh && echo ok")" = ok ] ||
    die "не поднялся SSH"
fi
ssh_ 'echo ok' | grep -q ok || die "SSH по ключу не пускает (лог: /data/local/tmp/ap2/dropbear.log)"
echo "    ok: ssh -i $KEY -p 2222 root@$IP"

echo "==> снимок состояния колонки"
ssh_ 'cat /proc/asound/cards; ls /dev/snd; echo "hostname: $(hostname)"; grep "^root:" /etc/passwd; df -h /data; ps w | grep "[m]aind"' \
  > "$BACKUP/probe-$(date +%Y%m%d-%H%M%S).txt"

echo "==> этап 2: AirPlay 2 по SSH"
# с --ssh-only этапа 1 не было, и каталога может не быть
tar_ -C "$TMP" -czf - ap2 | ssh_ "mkdir -p /data/local/opt && gzip -dc | tar -xf - -C /data/local/opt && echo ok" | grep -q ok ||
  die "не распаковался пакет"

echo "==> отключение обновлений"
ssh_ 'mkdir -p /data/opt && cat > /data/opt/yandex-noupdate.sh' < "$HERE/../yandex-noupdate.sh"
ssh_ 'sh /data/opt/yandex-noupdate.sh'
mkdir -p "$BACKUP/ota"
ssh_ 'cd /data/opt/backup && tar -cf - .' | tar -xf - -C "$BACKUP/ota"
ls "$BACKUP/ota"

echo "==> сторож обновлений /etc/init.d/S96otaguard"
# оригинал apply_packed_ota — на Mac, пока его не сменила заглушка
if ! ssh_ 'head -2 /usr/bin/apply_packed_ota' | grep -q 'OTA заблокирован'; then
  ssh_ 'cat /usr/bin/apply_packed_ota' > "$BACKUP/ota/apply_packed_ota.orig"
fi
ssh_ 'set -e; export PATH=/sbin:/usr/sbin:/bin:/usr/bin; Q=/system/vendor/quasar; G=/etc/otaguard
  [ "$(grep -c updatesd $Q/launch.json)" = 0 ]
  head -2 $Q/device_ota_update.sh | grep -q "disabled by yandex-noupdate"
  mount -o remount,rw /
  mkdir -p $G
  [ -f $G/apply_packed_ota.orig ] || cp /usr/bin/apply_packed_ota $G/apply_packed_ota.orig
  cp $Q/launch.json $Q/device_ota_update.sh $Q/ota_script.pub $G/
  printf "%s\n" "#!/bin/sh" \
    "# OTA заблокирован (/etc/init.d/S96otaguard). Оригинал: /etc/otaguard/apply_packed_ota.orig" \
    "logger -t otaguard \"apply_packed_ota blocked: \$*\" 2>/dev/null" \
    "echo \"\$(date): apply_packed_ota отклонён: \$*\" >> /tmp/otaguard.log" \
    "rm -f \"\$1\"" "exit 1" > $G/apply_packed_ota
  chmod 755 $G/apply_packed_ota
  cp $G/apply_packed_ota /usr/bin/apply_packed_ota
  cat > /etc/init.d/S96otaguard
  chmod 755 /etc/init.d/S96otaguard
  sync; mount -o remount,ro /
  /etc/init.d/S96otaguard start
  echo ok' < "$HERE/device/S96otaguard" | grep -q ok || die "сторож обновлений не встал"

echo "==> автозапуск и пользователь avahi"
ssh_ "mount -o remount,rw / &&
  { grep -q '^avahi:' /etc/passwd || echo 'avahi:x:86:86::/:/bin/false' >> /etc/passwd; } &&
  { grep -q '^avahi:' /etc/group || echo 'avahi:x:86:' >> /etc/group; } &&
  cat > /etc/init.d/S97ap2 && chmod 755 /etc/init.d/S97ap2 && sync && mount -o remount,ro / && echo ok" \
  < "$HERE/device/S97ap2" | grep -q ok || die "не записался /etc/init.d/S97ap2"

echo "==> запуск AirPlay 2"
ssh_ "$AP/ap2.sh restart"
sleep 6
ssh_ "$AP/ap2.sh status"

echo
echo "Готово. Проверьте с Mac: dns-sd -B _airplay._tcp — в списке должна быть «Станция 2»."
echo "Дальше: перезагрузка (ssh … reboot) и проверка, что SSH и AirPlay поднялись сами."
