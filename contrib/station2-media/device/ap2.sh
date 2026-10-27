#!/bin/sh
# AirPlay 2 на Станции 2: D-Bus, avahi, nqptp, shairport-sync и распорядитель звука.
#   ap2.sh start | stop | restart | status
#   ap2.sh ssh        — поднять dropbear на 2222 (вход только по ключу)
#   ap2.sh receiver   — поднять приёмник, если его нет (зовёт audio-owner.sh)
#   ap2.sh spotify    — поднять librespot, если его нет (зовёт audio-owner.sh)
#   ap2.sh run-sps | run-spotify — приёмник / librespot в переднем плане
#   ap2.sh run-avahi  — avahi с перезапуском при падении
. /data/local/opt/ap2/common.sh
SELF=$AP/ap2.sh
BUS=/run/dbus/ap2_bus
SPOTIFY_PORT=4371
# Кривая громкости Spotify в дБ: на полной шкале регулятора (36 дБ) половина ползунка
# звучит слишком тихо, ~25 дБ на слух совпадает с привычным шагом AirPlay (24 и меньше
# librespot считает «узким аппаратным» регулятором и переходит на линейную шкалу)
SPOTIFY_VOLUME_RANGE=25

# start-stop-daemon -x /bin/sh считает процесс запущенным, если жив любой /bin/sh,
# поэтому всегда свой pid-файл, а старый удаляем перед запуском.
spawn() { # pidfile программа аргументы...
  pf=$1; exe=$2; shift 2
  rm -f "$pf"
  start-stop-daemon -S -b -m -p "$pf" -x "$exe" -- "$@"
}

start_ssh() {
  [ -n "$(pids_matching "$B/dropbear")" ] && return 0
  [ -s "$E/dropbear_ed25519" ] || "$B/dropbearkey" -t ed25519 -f "$E/dropbear_ed25519" >/dev/null 2>&1
  # dropbear ищет ключи в домашнем каталоге root из /etc/passwd
  home=$(awk -F: '$1 == "root" { print $6 }' /etc/passwd)
  if [ -n "$home" ] && [ -s "$E/authorized_keys" ] &&
     ! cmp -s "$E/authorized_keys" "$home/.ssh/authorized_keys"; then
    # /root лежит на корне, а он смонтирован только для чтения
    mount -o remount,rw / 2>/dev/null
    mkdir -p "$home/.ssh" && cp "$E/authorized_keys" "$home/.ssh/authorized_keys"
    chmod 700 "$home/.ssh"
    chmod 600 "$home/.ssh/authorized_keys"
    sync
    mount -o remount,ro / 2>/dev/null
  fi
  "$B/dropbear" -r "$E/dropbear_ed25519" -p 2222 -s -P /run/ap2-dropbear.pid 2>>"$LOGD/dropbear.log"
}

start_bus() {
  [ -S "$BUS" ] && [ -n "$(pids_matching "$B/dbus-daemon")" ] && return 0
  mkdir -p /run/dbus
  rm -f "$BUS"
  "$B/dbus-daemon" --config-file="$E/dbus.conf" --fork >>"$LOGD/dbus.log" 2>&1
  sleep 1
}

# Имя хоста avahi должно совпадать с тем, что публикует maind
# (yandex-station-gen2-<id>), иначе mDNS-записи конфликтуют.
run_avahi() {
  # avahi собран с /var/run; на колонке это ссылка на /run
  mkdir -p /run/avahi-daemon /var/run/avahi-daemon 2>/dev/null
  while :; do
    name=$(cat "$E/hostname" 2>/dev/null || hostname)
    sed "s/@HOSTNAME@/$name/" "$E/avahi-daemon.conf.in" > /run/ap2-avahi.conf
    echo "$(date): avahi старт, имя $name" >> "$LOGD/avahi.log"
    "$B/avahi-daemon" --no-drop-root --no-chroot -f /run/ap2-avahi.conf >>"$LOGD/avahi.log" 2>&1
    echo "$(date): avahi завершился, код $?" >> "$LOGD/avahi.log"
    sleep 3
  done
}

# Системный alsa.conf тянет 32-битные плагины, поэтому у приёмника свой конфиг.
run_sps() {
  export ALSA_CONFIG_PATH=$E/asound.conf
  # Временная отладка: в etc/sps-debug — доп. аргументы (например -vvv), лог отдельно
  if [ -s "$E/sps-debug" ]; then
    # shellcheck disable=SC2046
    exec "$B/shairport-sync" -c "$E/shairport-sync.conf" $(cat "$E/sps-debug") \
      >>"$LOGD/sps-debug.log" 2>&1
  fi
  trim_log "$LOGD/sps.log"
  # shellcheck disable=SC2046
  exec $(audio_prio) "$B/shairport-sync" -c "$E/shairport-sync.conf" >>"$LOGD/sps.log" 2>&1
}

start_receiver() {
  [ -n "$(pids_matching "$B/shairport-sync")" ] && return 0
  spawn /run/ap2-sps.pid /bin/sh "$SELF" run-sps
}

# Spotify Connect. Звук отдаёт spotify-sink.sh (его librespot запускает на play и убивает
# на паузе), объявление — через наш avahi по D-Bus, вход — с телефона в той же сети,
# дальше librespot помнит его в spotify-cache.
run_spotify() {
  mkdir -p "$AP/spotify-cache"
  trim_log "$LOGD/spotify.log"
  # Громкость из приложения Spotify двигает тот же Master, что и сенсорная панель.
  # Стартовать librespot надо с текущей громкости колонки, иначе каждый его перезапуск
  # переставлял бы громкость Алисы: сам он берёт 50% или сохранённое значение (его
  # удаляем). Пересчёт: raw 0..255 -> дБ регулятора (-36..0) -> проценты кривой Spotify.
  export ALSA_CONFIG_PATH=$E/asound.conf
  rm -f "$AP/spotify-cache/volume"
  raw=$("$B/amixer" -D default get Master | sed -n 's/.*Playback \([0-9]*\) \[.*/\1/p' | head -1)
  db100=$(( ${raw:-128} * 3600 / 255 - 3600 ))
  pct=$(( 100 + db100 / SPOTIFY_VOLUME_RANGE ))
  [ "$pct" -lt 1 ] && pct=1
  # shellcheck disable=SC2046
  exec $(audio_prio) "$B/librespot" --name "$SPOTIFY_NAME" --device-type speaker --bitrate 320 \
    --backend subprocess --device "$AP/spotify-sink.sh" --format S16 \
    --mixer alsa --alsa-mixer-device default --alsa-mixer-control Master \
    --volume-ctrl log --volume-range "$SPOTIFY_VOLUME_RANGE" --initial-volume "$pct" \
    --cache "$AP/spotify-cache" --disable-audio-cache \
    --zeroconf-backend avahi --zeroconf-port "$SPOTIFY_PORT" >>"$LOGD/spotify.log" 2>&1
}

start_spotify() {
  [ -x "$B/librespot" ] || return 0
  [ -n "$(pids_matching "$B/librespot")" ] && return 0
  prime_volume
  spawn /run/ap2-spotify.pid /bin/sh "$SELF" run-spotify
}

# Голосом в Spotify (voice-spotify.sh): только если есть ключи Web API
start_voice() {
  [ -s "$E/spotify-webapi.json" ] || return 0
  [ -n "$(pids_matching "$AP/voice-spotify.sh")" ] && return 0
  spawn /run/ap2-voice.pid /bin/sh "$AP/voice-spotify.sh"
}

# Дописать шкалу дБ регулятору Master (см. pcm.ap2prime в asound.conf)
prime_volume() {
  ALSA_CONFIG_PATH=$E/asound.conf "$B/aplay" -q -D ap2prime -f S16_LE -c 2 -r 48000 -d 1 /dev/zero \
    >/dev/null 2>&1
}

start_all() {
  prime_volume
  start_bus
  if [ -z "$(pids_matching "$SELF run-avahi")" ]; then
    spawn /run/ap2-avahi.pid /bin/sh "$SELF" run-avahi
    sleep 3
  fi
  # nqptp должен быть ровно один и стартовать раньше приёмника
  if [ -z "$(pids_matching "$B/nqptp")" ]; then
    spawn /run/ap2-nqptp.pid "$B/nqptp"
    sleep 1
  fi
  start_receiver
  start_spotify
  start_voice
  [ -n "$(pids_matching "$AP/audio-owner.sh")" ] ||
    spawn /run/ap2-owner.pid /bin/sh "$AP/audio-owner.sh"
}

stop_all() {
  for m in "$AP/audio-owner.sh" "$AP/voice-spotify.sh" "$B/alice-text" "$SELF run-avahi" \
           "$B/shairport-sync" "$B/librespot" "$B/aplay -q -D spotify" avahi-daemon "$B/nqptp" \
           "$B/dbus-daemon"; do
    for p in $(pids_matching "$m"); do kill "$p" 2>/dev/null; done
  done
  sleep 1
  rm -f "$BUS"
  # распорядитель мог оставить Алису без медиа-демона
  start_mediad
}

show_status() {
  for m in "$B/dropbear" "$B/dbus-daemon" avahi-daemon "$B/nqptp" "$B/shairport-sync" \
           "$B/librespot" "$B/aplay -q -D spotify" "$AP/audio-owner.sh" "$AP/voice-spotify.sh" \
           "$MEDIAD_MATCH"; do
    printf '%-40s %s\n' "${m##*/}" "$(pids_matching "$m" | tr '\n' ' ')"
  done
  echo "--- порты:"
  netstat -ltn 2>/dev/null | grep -E ":(2222|7000|$SPOTIFY_PORT) "
  echo "--- sps.log:"
  tail -5 "$LOGD/sps.log" 2>/dev/null
  echo "--- spotify.log:"
  tail -5 "$LOGD/spotify.log" 2>/dev/null
}

case "$1" in
  start)     start_all ;;
  stop)      stop_all ;;
  restart)   stop_all; sleep 1; start_all ;;
  status)    show_status ;;
  ssh)       start_ssh ;;
  receiver)  start_receiver ;;
  spotify)   start_spotify ;;
  run-sps)   run_sps ;;
  run-spotify) run_spotify ;;
  run-avahi) run_avahi ;;
  *) echo "usage: $0 start|stop|restart|status|ssh|receiver|spotify" >&2; exit 1 ;;
esac
