#!/bin/sh
# Распорядитель звука: AirPlay и Spotify видны всегда, Алиса возвращается после сессии.
#   - идёт AirPlay (ESTABLISHED на порт приёмника) -> медиа-демон колонки гасим;
#   - играет Spotify или YouTube Music -> устройство уже забрал spotify-sink.sh или
#     ytm-sink.sh, ждём конца;
#   - всё стихло -> медиа-демон поднимаем; после AirPlay ещё перезапускаем приёмник,
#     чтобы он отпустил ALSA;
#   - приёмник, librespot или ytmd пропали -> поднимаем заново (не чаще раза в минуту).
# Основа — contrib/audio-owner.sh из Marker284/yandex-station-extended (оттуда же —
# derangedabbot/yandex-station-2-airplay), без подсветки и плеера «Звука».
. /data/local/opt/ap2/common.sh
LOG=$LOGD/owner.log
# Порт приёмника в hex: 7000 = 1B58 (port в shairport-sync.conf, 5.6+ берёт его оттуда)
AP_PORT=1B58
SP_MATCH="$B/shairport-sync"
SPOTIFY_SINK="$B/aplay -q -D spotify"
YTM_SINK="$B/aplay -q -D youtube"
STATE=idle
# Первый подъём пропавших — не раньше чем через минуту: при старте ap2.sh приёмник и
# librespot ещё запускаются, и без этой паузы распорядитель поднимал их дубли
LAST_REVIVE=$(date +%s)

sp_pid() { pids_matching "$SP_MATCH" | head -1; }

# Признак AirPlay — TCP-сессия, а не владение ALSA: устройство держит mediad,
# приёмник его не получит, и признак «приёмник держит ALSA» всегда ложный.
airplay_session() {
  for t in /proc/net/tcp /proc/net/tcp6; do
    [ -r "$t" ] || continue
    awk -v p="$AP_PORT" \
      'FNR>1 { split($2,a,":"); if (a[length(a)]==p && $4=="01") f=1 } END { exit(f?0:1) }' "$t" &&
      return 0
  done
  return 1
}

sp_holds_pcm() { holds_pcm "$(sp_pid)"; }

# librespot держит spotify-sink.sh только пока играет: на паузе он его убивает.
# Ищем по «/bin/sh …»: голый путь к скрипту есть и в командной строке самого librespot.
spotify_playing() { [ -n "$(pids_matching "$SPOTIFY_SINK")$(pids_matching "/bin/sh $AP/spotify-sink.sh")" ]; }

# ytmd.py держит ytm-sink.sh, пока трек играет; между треками его на миг нет, поэтому
# смотрим и на метку /tmp/ytm.playing — ytmd пишет в неё время каждые 3 с и стирает на паузе
# (stat в busybox колонки нет)
youtube_playing() {
  [ -n "$(pids_matching "$YTM_SINK")$(pids_matching "/bin/sh $AP/ytm-sink.sh")" ] && return 0
  m=$(cat /tmp/ytm.playing 2>/dev/null)
  [ -n "$m" ] && [ $(( $(date +%s) - m )) -lt 10 ]
}

# Супервизор quasar поднимает mediad обратно, поэтому одного kill мало:
# добиваем, пока приёмник реально не займёт устройство.
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

# Приёмник отпускает устройство не сразу
wait_pcm_free() {
  i=0
  while pcm_busy && [ "$i" -lt 15 ]; do
    sleep 1; i=$((i+1))
  done
  [ "$i" -gt 0 ] && echo "$(date): ждал освобождения звука ${i}с" >> "$LOG"
}

revive_missing() {
  now=$(date +%s)
  [ $((now - LAST_REVIVE)) -ge 60 ] || return 0
  if [ -z "$(sp_pid)" ]; then
    LAST_REVIVE=$now
    echo "$(date): приёмник AirPlay пропал — поднимаю заново" >> "$LOG"
    "$AP/ap2.sh" receiver
  fi
  if [ -x "$B/librespot" ] && [ -z "$(pids_matching "$B/librespot")" ]; then
    LAST_REVIVE=$now
    echo "$(date): librespot пропал — поднимаю заново" >> "$LOG"
    "$AP/ap2.sh" spotify
  fi
  if [ -f "$AP/ytm/ytmd.py" ] && [ -z "$(pids_matching "$AP/ytm/ytmd.py")" ]; then
    LAST_REVIVE=$now
    echo "$(date): ytmd пропал — поднимаю заново" >> "$LOG"
    "$AP/ap2.sh" ytm
  fi
}

trim_log "$LOG"
while :; do
  if airplay_session || sp_holds_pcm; then
    if [ "$STATE" != airplay ]; then
      echo "$(date): AirPlay пошёл — освобождаю звук" >> "$LOG"
      STATE=airplay
    fi
    release_for_airplay
  elif spotify_playing; then
    if [ "$STATE" != spotify ]; then
      echo "$(date): играет Spotify" >> "$LOG"
      STATE=spotify
    fi
  elif youtube_playing; then
    if [ "$STATE" != youtube ]; then
      echo "$(date): играет YouTube Music" >> "$LOG"
      STATE=youtube
    fi
  else
    revive_missing
    case "$STATE" in
      airplay)
        echo "$(date): AirPlay закончился — возвращаю Алису" >> "$LOG"
        for p in $(pids_matching "$SP_MATCH"); do kill "$p" 2>/dev/null; done
        wait_pcm_free
        start_mediad
        "$AP/ap2.sh" receiver
        ;;
      spotify|youtube)
        echo "$(date): $STATE на паузе или остановлен — возвращаю Алису" >> "$LOG"
        wait_pcm_free
        start_mediad
        ;;
      *)
        start_mediad
        ;;
    esac
    STATE=idle
  fi
  sleep 2
done
