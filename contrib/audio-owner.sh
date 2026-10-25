#!/bin/sh
# Распорядитель звука для AirPlay 2: приёмник виден всегда, Алиса возвращается после сессии.
#   - идёт AirPlay (есть ESTABLISHED-соединение с приёмником) -> демон колонки гасим
#   - сессия кончилась -> приёмник перезапускается (отпускает звук), демон колонки поднимается
#   - приёмник пропал -> поднимаем заново (не чаще раза в минуту)
#
# Откуда: https://github.com/derangedabbot/yandex-station-2-airplay — docs/03-airplay.md.
# Проверено на Станции 2 (yandex,station-midi): Amlogic AXG, ядро 4.9.68, приёмник собран из
# исходников. На других моделях НЕ проверялось — пути и имена демонов у каждой свои.
#
# Что поправить под свою модель (ниже — значения Станции 2):
#   MEDIAD_BIN / MEDIAD_MATCH — чем и как запускается демон колонки (здесь maind --mediad);
#   AP_PORT_7000 / AP_PORT_CONF — порты приёмника в hex: 1B58 = 7000 (AirPlay 2 до 5.6),
#                  1388 = 5000 (5.6+, берётся из port в shairport-sync.conf);
#   T2           — каталог, куда установлен приёмник;
#   LED/LED_PATTERN — подсветка кольца (уберите вызовы, если её нет);
#   sp_pid()     — как найти процесс приёмника.
#
# Поиск процессов — через /proc, а не ps|grep: шаблон легко совпадает с командной строкой
# того, кто его запустил, и вы убиваете собственную сессию.
pids_matching() {
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    [ "$pid" = "$$" ] && continue
    [ "$pid" = "$PPID" ] && continue
    cmd=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)
    case "$cmd" in *"$1"*) echo "$pid";; esac
  done
}

LOG=/data/local/tmp/audio-owner.log
L=/data/local/opt/tools/lib/ld-musl-aarch64.so.1
T2=/data/local/opt/airplay2
MEDIAD_BIN=/system/vendor/quasar/maind
MEDIAD_MATCH="$MEDIAD_BIN --mediad"
AP_PORT_7000=1B58
AP_PORT_CONF=1388
: >> "$LOG"
AIRPLAY_WAS_ON=0
IDLE_COUNT=0
LAST_REVIVE=0
LED=/data/local/bin/led-lamp.sh
LED_PATTERN=tricolor

sp_pid() { ps w | awk '/[s]hairport-sync -c \/data\/local\/opt\/airplay2/ {print $1}' | head -1; }

# Живая ли AirPlay-сессия: ESTABLISHED на порт приёмника. До 5.6 AirPlay 2 слушал
# фиксированный 7000 (0x1B58) и не смотрел на port из конфига; в 5.6+ берётся порт из
# shairport-sync.conf (у нас 5000, 0x1388). Проверяем оба — иначе после обновления
# распорядитель перестаёт видеть сессию, звук держит mediad и ALSA отвечает Resource busy.
# Именно это, а не «приёмник уже держит ALSA», потому что устройство держит mediad
# и приёмник его никогда не получит — получался замкнутый круг и тишина.
airplay_session() {
  for t in /proc/net/tcp /proc/net/tcp6; do
    [ -r "$t" ] || continue
    awk -v p1="$AP_PORT_7000" -v p2="$AP_PORT_CONF" \
      'FNR>1 { split($2,a,":"); if ((a[length(a)]==p1 || a[length(a)]==p2) && $4=="01") f=1 } END { exit(f?0:1) }' "$t" && return 0
  done
  return 1
}

# Держит ли приёмник устройство воспроизведения прямо сейчас
sp_holds_pcm() {
  P=$(sp_pid)
  [ -z "$P" ] && return 1
  for f in /proc/$P/fd/*; do
    t=$(readlink "$f" 2>/dev/null)
    case "$t" in *pcmC0D0p*) return 0;; esac
  done
  return 1
}

# Настойчиво освобождаем устройство под AirPlay: супервизор поднимает mediad обратно,
# поэтому одного kill мало — долбим, пока приёмник реально не займёт ALSA.
release_for_airplay() {
  i=0
  while [ "$i" -lt 40 ]; do
    sp_holds_pcm && return 0
    airplay_session || return 0
    P=$(pids_matching "$MEDIAD_MATCH" | head -1)
    [ -n "$P" ] && kill -9 "$P" 2>/dev/null
    sleep 0.3
    i=$((i+1))
  done
  return 1
}

playing() {
  # Играет, если сессия есть ИЛИ приёмник уже занял устройство.
  airplay_session && return 0
  P=$(sp_pid)
  [ -z "$P" ] && return 1
  for f in /proc/$P/fd/*; do
    t=$(readlink "$f" 2>/dev/null)
    case "$t" in *pcmC0D0p*) return 0;; esac
  done
  return 1
}


# Держит ли кто-нибудь устройство воспроизведения
pcm_busy() {
  for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    for f in /proc/$p/fd/*; do
      t=$(readlink "$f" 2>/dev/null)
      case "$t" in *pcmC0D0p*) return 0;; esac
    done
  done
  return 1
}

# Ждём, пока устройство освободится (приёмник отпускает его не сразу)
wait_pcm_free() {
  i=0
  while pcm_busy && [ "$i" -lt 15 ]; do
    sleep 1; i=$((i+1))
  done
  [ "$i" -gt 0 ] && echo "$(date): ждал освобождения звука ${i}с" >> "$LOG"
}

start_mediad() {
  # Если экземпляров больше одного (лаунчер успевает поднять свой), они дерутся за звук
  # и Алиса молчит. Оставляем ровно один.
  PIDS=$(pids_matching "$MEDIAD_MATCH")
  N=$(printf '%s\n' "$PIDS" | grep -c .)
  if [ "$N" -gt 1 ]; then
    for p in $PIDS; do kill -9 "$p" 2>/dev/null; done
    sleep 2
    echo "$(date): убрал дубли mediad (было $N)" >> "$LOG"
    N=0
  fi
  if [ "$N" -eq 0 ]; then
    cd /data/quasar 2>/dev/null || cd /
    MALLOC_ARENA_MAX=2 CA_CERTIFICATES=/system/vendor/quasar/ca-certificates.crt \
      nohup "$MEDIAD_BIN" --mediad >> /data/quasar/mediad.log 2>&1 < /dev/null &
    echo "$(date): mediad поднят" >> "$LOG"
  fi
}

revive_receiver() {
  now=$(date +%s)
  if [ $((now - LAST_REVIVE)) -ge 60 ]; then
    LAST_REVIVE=$now
    echo "$(date): приёмник пропал — поднимаю заново" >> "$LOG"
    /data/local/bin/airplay2-daemon.sh
  fi
}

# Наш плеер «Звука» держит звук так же, как AirPlay: пока он играет,
# кольцо должно дышать зелёным, иначе распорядитель его гасит каждые 4 секунды.
zvuk_playing() {
  for p in /proc/[0-9]*; do
    c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null || true)
    case "$c" in
      *"/usr/bin/aplay"*) ls -l "$p/fd" 2>/dev/null | grep -q pcmC0D0p && return 0 ;;
    esac
  done
  return 1
}

while :; do
  if playing; then
    if [ "$AIRPLAY_WAS_ON" = "0" ]; then
      echo "$(date): AirPlay пошёл — освобождаю звук" >> "$LOG"
      [ -x "$LED" ] && "$LED" start "$LED_PATTERN" >/dev/null 2>&1
      AIRPLAY_WAS_ON=1
    fi
    IDLE_COUNT=0
    # подсветка должна дышать всё время, пока идёт AirPlay
    if [ -x "$LED" ] && [ ! -f /run/led-lamp.pid ]; then
      "$LED" start "$LED_PATTERN" >/dev/null 2>&1
    fi
    release_for_airplay
  else
    # AirPlay не играет: если звук держит наш плеер «Звука» — дышим зелёным,
    # иначе гасим (даже если распорядитель перезапускался и не помнит про свет)
    if zvuk_playing; then
      [ -x "$LED" ] && [ ! -f /run/led-lamp.pid ] && "$LED" start green >/dev/null 2>&1
    else
      [ -x "$LED" ] && [ -f /run/led-lamp.pid ] && "$LED" stop >/dev/null 2>&1
    fi

    ps w | grep -q '[s]hairport-sync -c /data/local/opt/airplay2' || revive_receiver

    if [ "$AIRPLAY_WAS_ON" = "1" ]; then
      IDLE_COUNT=$((IDLE_COUNT+1))
      if [ "$IDLE_COUNT" -ge 1 ]; then
        echo "$(date): AirPlay закончился — возвращаю Алису" >> "$LOG"
        [ -x "$LED" ] && "$LED" stop >/dev/null 2>&1
        # приёмник отпускает устройство, а Алису поднимаем сразу: она нужнее,
        # приёмник всё равно вернётся в сеть за пару секунд
        for p in $(ps w | awk '/[s]hairport-sync -c \/data\/local\/opt\/airplay2/ {print $1}'); do kill "$p" 2>/dev/null; done
        wait_pcm_free
        start_mediad
        nohup /data/local/bin/airplay2-daemon.sh >/dev/null 2>&1 &
        echo "$(date): Алиса поднята, приёмник возвращается" >> "$LOG"
        AIRPLAY_WAS_ON=0
        IDLE_COUNT=0
      fi
    else
      start_mediad
    fi
  fi
  sleep 2
done
