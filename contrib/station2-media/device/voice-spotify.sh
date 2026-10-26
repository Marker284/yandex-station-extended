#!/bin/sh
# Голосом в Spotify вместо Яндекс Музыки: «Алиса, поставь Маркула» — поиск и запуск в
# Spotify на этой колонке. Текст фразы берём у alice-text (локальный канал Алисы).
# Алиса отвечает как обычно и успевает на секунду-две включить своё — как только
# заиграет Spotify, spotify-sink.sh забирает у неё звук.
# В лог попадают только музыкальные команды, остальная речь никуда не пишется.
. /data/local/opt/ap2/common.sh
LOG=$LOGD/voice.log
API_SH=$AP/spotify-api.sh
ACTIVE=/tmp/spotify-voice.active   # время последнего запуска Spotify голосом
RECENT_SECONDS=3600
DUCK=/tmp/ap2-duck                 # метка текущего приглушения
DUCK_LEVEL=25%                     # AP2 Duck: 25% шкалы ~ -22 дБ
DUCK_MAX_SECONDS=15                # страховка, если «свободна» не придёт

note() { echo "$(date): $*" >> "$LOG"; }

duck_set() { ALSA_CONFIG_PATH=$E/asound.conf "$B/amixer" -q -D default set "AP2 Duck" "$1" 2>/dev/null; }

# Пока Алиса слушает, музыка AirPlay и Spotify тише — иначе команда тонет в ней
duck_on() {
  mark=$(date +%s)
  echo "$mark" > "$DUCK"
  duck_set "$DUCK_LEVEL"
  ( sleep "$DUCK_MAX_SECONDS"; [ "$(cat "$DUCK" 2>/dev/null)" = "$mark" ] && duck_off ) &
}

duck_off() {
  rm -f "$DUCK"
  duck_set 100%
}

# Умный дом, таймеры, громкость и прочее — не музыка, оставляем Алисе
not_music() {
  case "$1" in
    *свет*|*ламп*|*люстр*|*телевизор*|*кондиционер*|*обогрев*|*увлажн*|*розетк*|*пылесос*|\
    *чайник*|*будильник*|*таймер*|*напомин*|*блютуз*|*bluetooth*|*радио*|*сказк*|*новост*|\
    *погод*|*звук*|*громче*|*тише*|*громкост*) return 0 ;;
  esac
  return 1
}

# Spotify сейчас играет или включался голосом недавно — тогда «пауза», «дальше» для него
spotify_recent() {
  [ -n "$(pids_matching "$B/aplay -q -D spotify")" ] && return 0
  [ -f "$ACTIVE" ] && [ $(( $(date +%s) - $(cat "$ACTIVE") )) -lt "$RECENT_SECONDS" ]
}

run() { # команда spotify-api.sh в фоне: поиск идёт секунду-две, читать фразы не мешаем
  note "$*"
  ( if "$API_SH" "$@" >> "$LOG" 2>&1; then
      case "$1" in play|liked) date +%s > "$ACTIVE" ;; esac
    else
      note "не вышло: $*"
    fi ) &
}

play_phrase() { # «маркула», «песню X», «альбом X», «плейлист X», «музыку»
  q=$(echo "$1" | sed -E 's/ (в|на|из) (спотифай|спотифае|спотифая|spotify)$//; s/ пожалуйста$//')
  mode=auto
  case "$q" in
    песню\ *|трек\ *|композицию\ *) mode=track; q=${q#* } ;;
    альбом\ *) mode=album; q=${q#* } ;;
    плейлист\ *|подборку\ *) mode=playlist; q=${q#* } ;;
  esac
  case "$q" in
    ''|музыку|музыка|что-нибудь|мою\ музыку|любимое|любимую\ музыку|любимые\ песни) run liked ;;
    *) run play "$mode" "$q" ;;
  esac
}

handle() {
  t=$1
  # Состояние Алисы от alice-text: 1 — слушает, 3 — фраза распознана, 0 — свободна
  case "$t" in
    "@state 1") duck_on; return 0 ;;
    "@state 0") [ -f "$DUCK" ] && duck_off; return 0 ;;
    @state\ *) return 0 ;;
  esac
  case "$t" in
    *ыключи*|*стоп*|*хватит*|*ауза*|*аузу*) spotify_recent && run pause ;;
    *родолж*) spotify_recent && run resume ;;
    *ледующ*|*альше*) spotify_recent && run next ;;
    *редыдущ*|*азад*) spotify_recent && run prev ;;
    *оставь\ *|*ключи\ *|*грай\ *)
      q=$(echo "$t" | sed -E 's/^.*(Поставь|поставь|Включи|включи|Играй|играй) //')
      [ "$q" = "$t" ] && return 0
      not_music "$q" && return 0
      play_phrase "$q"
      ;;
  esac
}

trim_log "$LOG"
duck_off
note "слушатель запущен"
"$B/alice-text" | while IFS= read -r line; do
  handle "$line"
done
