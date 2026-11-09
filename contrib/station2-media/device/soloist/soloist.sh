#!/bin/sh
# Spotify Soloist на Станции 2: официальный клиент Spotify Connect вместо librespot
# (librespot на аккаунтах, созданных примерно с 2024–2025 года, получает «error audio key 0 1»).
# Цепочка: soloist -> PulseAudio (module-pipe-sink) -> /run/soloist/pcm.fifo -> sink.sh,
# который на время игры забирает звук у медиа-демона Алисы, как spotify-sink.sh у librespot.
#   soloist.sh start | stop | restart | status | update | ctl <команда soloist ctl>
# Запускает и гасит его ap2.sh. Ключ Soloist — etc/api-key (права 600).
# Бинарник Spotify не патчится: запуск через свой загрузчик glibc из lib/.
. /data/local/opt/ap2/common.sh
D=$AP/soloist
R=/run/soloist
WS=127.0.0.1:7071
SINK="$B/aplay -q -D spotify_solo"
RUNLOG=$LOGD/soloist-run.log
export HOME=$R XDG_RUNTIME_DIR=$R PULSE_RUNTIME_PATH=$R PULSE_SERVER=unix:$R/pulse.sock
export PULSE_CONFIG_PATH=$D PULSE_STATE_PATH=$R

solo() { "$D/lib/ld-linux-aarch64.so.1" --library-path "$D/lib" "$D/soloist" "$@"; }
log() { echo "$(date): $*" >> "$RUNLOG"; }
# start-stop-daemon -x /bin/sh считает процесс живым, если жив любой /bin/sh — свой pid-файл
spawn() { rm -f "$R/$1.pid"; start-stop-daemon -S -b -m -p "$R/$1.pid" -x /bin/sh -- "$D/soloist.sh" "$1"; }
alive() { [ -s "$R/$1.pid" ] && kill -0 "$(cat "$R/$1.pid")" 2>/dev/null; }
sink_pids() { pids_matching "$SINK"; pids_matching "/bin/sh $D/sink.sh"; }
# системный amixer колонки: amixer набора без ALSA_CONFIG_PATH не видит карту
master() { amixer -c 0 get Master | sed -n 's/.*\[\([0-9]*\)%\].*/\1/p' | head -1; }
differ() { d=$(( $1 - $2 )); [ "$d" -gt 1 ] || [ "$d" -lt -1 ]; }

# Громкость Алиса делает усилителем: Master двигает «SY6045S Master» (50% = -25,5 дБ,
# 20% = -41 дБ), через него идёт любой звук. Soloist же сам ослабляет свой поток
# (60*lg(v/100) дБ, 50% = -18 дБ) — вдвоём выходило слишком тихо. Выход fifo это
# ослабление снимает: поток Spotify всегда 0 дБ, громкость — только усилителем.
apply_gain() { # v 0-100
  [ "${1:-0}" -gt 0 ] || return 0
  # в busybox awk колонки нет математики — считаем в jq
  g=$("$B/jq" -n --argjson v "$1" '(-60 * (($v / 100) | log10)) * 100 | round / 100')
  "$D/bin/pactl" set-sink-volume fifo "${g}dB" 2>/dev/null
}

# Сборки Soloist живут 90 дней (код выхода 10) — свежая берётся с CDN Spotify
update() {
  T=/data/local/tmp/soloist-update
  rm -rf "$T"; mkdir -p "$T"
  "$B/curl" -fsSL --cacert "$AP/lib/ca-certificates.crt" -o "$T/s.tgz" \
    https://soloist-builds.spotifycdn.com/soloist_release_arm64.tar.gz &&
    gzip -dc "$T/s.tgz" | tar -xf - -C "$T" && [ -s "$T/soloist" ] ||
    { log "обновление: не скачалось"; rm -rf "$T"; return 1; }
  if cmp -s "$T/soloist" "$D/soloist"; then
    log "обновление: новой сборки нет"; rm -rf "$T"; return 1
  fi
  chmod 755 "$T/soloist" && mv "$T/soloist" "$D/soloist"
  rm -rf "$T"
  log "обновление: $(solo --version 2>&1 | head -1)"
}

run_pulse() {
  while :; do
    trim_log "$LOGD/soloist-pulse.log"
    "$D/bin/pulseaudio" -n -F "$D/pulse.pa" --daemonize=no --use-pid-file=no --system=no \
      --disallow-exit --exit-idle-time=-1 --dl-search-path="$D/modules" --log-target=stderr \
      >> "$LOGD/soloist-pulse.log" 2>&1
    log "pulseaudio вышел ($?)"; sleep 3
  done
}

run_soloist() {
  key=$(cat "$D/etc/api-key")
  while :; do
    trim_log "$LOGD/soloist.log"
    solo -n "$SPOTIFY_NAME" -k "$key" -D "$D/data" -C "$D/cache" -z 100 -w "$WS" \
      -i "$(master)" >> "$LOGD/soloist.log" 2>&1
    rc=$?; log "soloist вышел ($rc)"
    [ "$rc" = 10 ] && { log "сборка Soloist устарела (90 дней)"; update || sleep 3600; }
    sleep 5
  done
}

# События Soloist: состояние игры -> $R/state (его читает audio-owner.sh), ползунок -> Master
run_events() {
  while :; do
    apply_gain "$(solo ctl -w "$WS" now --json 2>/dev/null | "$B/jq" -r '.volume // 0')"
    solo ctl -w "$WS" trace 2>/dev/null | while read -r _ js; do
      case "$js" in
        *'"type":"playback_state"'*)
          echo "$js" | "$B/jq" -r '.status // empty' > "$R/state" ;;
        *'"type":"volume_changed"'*)
          v=$(echo "$js" | "$B/jq" -r '.volume // empty')
          apply_gain "$v"
          last=$(cat "$R/vol" 2>/dev/null)
          if [ -n "$v" ] && { [ -z "$last" ] || differ "$v" "$last"; }; then
            amixer -c 0 -q set Master "$v%"; master > "$R/vol"
          fi ;;
      esac
    done
    echo stopped > "$R/state"; sleep 3
  done
}

# Раз в секунду: приёмник по состоянию; громкость Алисы (Master) -> ползунок Spotify
run_watch() {
  idle=0
  while :; do
    st=$(cat "$R/state" 2>/dev/null)
    # buffering — переход между треками, звук Алисе не отдаём
    if [ "$st" = playing ] || [ "$st" = buffering ]; then
      idle=0
      if [ "$st" = playing ] && [ -z "$(sink_pids)" ]; then
        log "играет — приёмник"
        "$D/sink.sh" 2>>"$LOGD/soloist-sink.log" &
      fi
    else
      idle=$((idle+1))
      p=$(sink_pids)
      if [ "$idle" -ge 3 ] && [ -n "$p" ]; then log "пауза — звук Алисе"; kill $p 2>/dev/null; fi
    fi
    vm=$(master); last=$(cat "$R/vol" 2>/dev/null)
    if [ -n "$vm" ] && { [ -z "$last" ] || differ "$vm" "$last"; }; then
      echo "$vm" > "$R/vol"
      solo ctl -w "$WS" volume "$vm" >/dev/null 2>&1
    fi
    sleep 1
  done
}

start() {
  [ -x "$D/soloist" ] || { echo "нет $D/soloist — soloist.sh update"; return 1; }
  [ -s "$D/etc/api-key" ] || { echo "нет $D/etc/api-key"; return 1; }
  mkdir -p "$R" "$D/data" "$D/cache"; chmod 700 "$R"
  [ -p "$R/pcm.fifo" ] || mkfifo "$R/pcm.fifo"
  trim_log "$RUNLOG"
  alive run-pulse || spawn run-pulse
  sleep 2
  alive run-soloist || spawn run-soloist
  sleep 3
  alive run-events || spawn run-events
  alive run-watch || spawn run-watch
}

stop() {
  for n in run-watch run-events run-soloist run-pulse; do
    alive "$n" && kill "$(cat "$R/$n.pid")"; rm -f "$R/$n.pid"
  done
  sleep 1
  for m in "$D/soloist -n" "$D/soloist ctl" "$D/bin/pulseaudio -n" "$SINK" "/bin/sh $D/sink.sh"; do
    for p in $(pids_matching "$m"); do kill "$p" 2>/dev/null; done
  done
  rm -f "$R/state" "$R/vol"
}

case "$1" in
  start) start ;;
  stop) stop ;;
  restart) stop; sleep 2; start ;;
  update) update && { stop; sleep 2; start; } ;;
  run-pulse) run_pulse ;;
  run-soloist) run_soloist ;;
  run-events) run_events ;;
  run-watch) run_watch ;;
  ctl) shift; solo ctl -w "$WS" "$@" ;;
  status)
    for n in run-pulse run-soloist run-events run-watch; do
      printf '%-40s %s\n' "soloist $n" "$(alive "$n" && cat "$R/$n.pid")"
    done
    printf '%-40s %s\n' "aplay -q -D spotify_solo" "$(sink_pids | tr '\n' ' ')"
    printf '%-40s %s / Master %s%%\n' "состояние" "$(cat "$R/state" 2>/dev/null)" "$(master)"
    solo ctl -w "$WS" status 2>&1 | sed -n '2,4p'
    ;;
  *) echo "usage: $0 start|stop|restart|status|update|ctl ..." >&2; exit 1 ;;
esac
