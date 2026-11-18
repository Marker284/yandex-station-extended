#!/bin/sh
# midi-factory-to-0369.sh — перевод Станции Миди (cucumber) с заводской прошивки на 0.369.
#
# Зачем: после сброса Миди стоит на factory-образе, а Quasar Bridge работает на 0.369.
# Подробности — docs/devices/station-midi.md, разделы factory-7 и «Переход с factory на 0.369».
#
# Проверено на: Станция Миди, factory-7 (0.7.1.24.2409336217.20240626) ->
#               0.369.1.46.4778262955.20261013.160, ноябрь 2026.
#
# Запуск на колонке под root (adb shell), BusyBox sh:
#   sh midi-factory-to-0369.sh prepare          # сразу после root: ADB + блок скачивания OTA
#   sh midi-factory-to-0369.sh install <образ>  # образ 0.369 уже лежит в /ota
#   sh midi-factory-to-0369.sh status
#
# prepare:
#   - закрепляет маркеры ADB обеих схем (/data/quasar_activate_* и /data/quasar/activate_*);
#   - для каждой версии из «Has update» в updatesd.log кладёт в /ota пустой неизменяемый
#     update_<версия>.img — updatesd не может скачать туда образ;
#   - останавливает текущий maind --updatesd (quasar_launcher2 может запустить его снова,
#     поэтому prepare можно повторять).
#   Системные файлы не меняет.
# install: проверяет модель и MD5 образа, затем делает то же, что штатный yandex-apply-ota
#   из 0.369: mv в /ota/yandex_io_ota.swu, sync, umount /ota, yandex-reboot recovery.
#   Установку выполняет recovery колонки и сам проверяет подпись образа.
#
# Откат:
#   - маркеры и заглушки: chattr -i <файл>; rm <файл>;
#   - установку отменить нельзя; сброс кнопкой вернёт колонку на factory-образ.
# НЕ используйте yandex-reboot update: на Миди это usb_burning.

set -u

OTA=/ota
LOG=/data/quasar/daemons_logs
MD5_0369=b31b3b09242531e89a3877ece83519d1   # 0.369.1.46.4778262955.20261013.160

say() { echo "[midi] $*"; }
die() { echo "[midi] ОШИБКА: $*" >&2; exit 1; }

check_model() {
  grep -q cucumber /proc/device-tree/compatible 2>/dev/null ||
    die "это не Станция Миди (в /proc/device-tree/compatible нет cucumber)"
}

pin_adb() {
  mkdir -p /data/quasar
  for f in /data/quasar_activate_adb_quasmodrom /data/quasar_activate_network_adb \
           /data/quasar/activate_adb_quasmodrom /data/quasar/activate_network_adb; do
    [ -e "$f" ] || touch "$f"
    chattr +i "$f" 2>/dev/null || say "не удалось chattr +i $f"
  done
  say "маркеры ADB:"
  lsattr /data/quasar_activate_* /data/quasar/activate_* 2>/dev/null
}

block_ota_downloads() {
  vers=$(cat "$LOG"/updatesd.log* 2>/dev/null |
         sed -n 's/.*Has update: version: \([0-9.]*\).*/\1/p' | sort -u)
  if [ -z "$vers" ]; then
    say "в updatesd.log нет «Has update» — пока нечего блокировать, повторите prepare позже"
    return 0
  fi
  for v in $vers; do
    f="$OTA/update_$v.img"
    if lsattr "$f" 2>/dev/null | grep -q '^....i'; then
      say "уже заблокировано: $f"; continue
    fi
    rm -f "$f"; touch "$f" && chattr +i "$f" && say "заблокировано скачивание $v"
  done
}

stop_updatesd() {
  for p in $(ps | grep 'maind --updatesd' | grep -v grep | awk '{print $1}'); do
    kill -9 "$p" && say "остановлен maind --updatesd (PID $p)"
  done
}

cmd_prepare() {
  check_model
  pin_adb
  block_ota_downloads
  stop_updatesd
}

cmd_install() {
  img=${1:-}
  [ -n "$img" ] || die "укажите образ: install /ota/<файл>"
  [ -f "$img" ] || die "нет файла $img"
  check_model
  case "$img" in "$OTA"/*) ;; *) die "образ должен лежать в $OTA (тот же раздел, что yandex_io_ota.swu)";; esac
  [ -x /usr/bin/yandex-reboot ] || die "нет /usr/bin/yandex-reboot"
  say "MD5 образа..."
  sum=$(md5sum "$img" | cut -d' ' -f1)
  [ "$sum" = "$MD5_0369" ] ||
    die "MD5 $sum не совпадает с 0.369.1.46…160 ($MD5_0369); для другой сборки поправьте MD5_0369"
  say "ок. Через ~7 с Алиса остановится, колонка уйдёт в recovery; питание не трогать ~2 мин"
  cat > /data/midi-apply-0369.sh <<EOF
#!/bin/sh
exec > /data/midi-apply-0369.log 2>&1
date
killall quasar_launcher2; sleep 5; killall -9 maind
mv "$img" $OTA/yandex_io_ota.swu && ls -la $OTA
sync
umount $OTA && echo UMOUNT_OK || echo UMOUNT_FAIL
sync
/usr/bin/yandex-reboot recovery
echo "yandex-reboot вернул \$?"
EOF
  chmod +x /data/midi-apply-0369.sh
  # setsid: иначе выход из adb shell остановит скрипт
  setsid /data/midi-apply-0369.sh </dev/null >/dev/null 2>&1 &
  say "запущено; журнал — /data/midi-apply-0369.log"
}

cmd_status() {
  busybox 2>&1 | head -1
  cat /system/vendor/quasar/VERSION 2>/dev/null; echo
  [ -f "$OTA/swupdate.status" ] && say "swupdate.status: $(cat $OTA/swupdate.status)"
  lsattr /data/quasar_activate_* /data/quasar/activate_* 2>/dev/null
  ls -la "$OTA"
  ps | grep 'maind --updatesd' | grep -v grep || say "maind --updatesd не запущен"
}

case "${1:-}" in
  prepare) cmd_prepare ;;
  install) shift; cmd_install "${1:-}" ;;
  status)  cmd_status ;;
  *) echo "Использование: $0 prepare | install /ota/<образ 0.369> | status"; exit 1 ;;
esac
