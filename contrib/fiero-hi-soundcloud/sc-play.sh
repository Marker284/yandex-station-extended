#!/bin/sh
# Проверено: Fiero Hi (Станция Лайт, blackthorn), прошивка 0.369.1.50.*. Откат — README.md рядом.
# SoundCloud на колонке без yt-dlp: поиск через api-v2, поток HLS -> ffmpeg -> aplay (dmix, рядом с Алисой).
#   sc-play.sh play <запрос>     найти и играть найденные треки подряд
#   sc-play.sh next | prev       следующий / предыдущий трек (prev в начале трека — предыдущий, иначе сначала)
#   sc-play.sh seek <±секунды>   перемотка относительно текущего места; seek 0 — с начала трека
#   sc-play.sh pause | resume    пауза (Алиса возвращается) и продолжение с того же места
#   sc-play.sh stop              остановить
#   sc-play.sh volume <+N|-N|N>  громкость в процентах (регулятор Master — общий с Алисой)
export PATH=/opt/bin:/opt/sbin:/usr/bin:/bin:/usr/sbin:/sbin
DIR=$(cd "$(dirname "$0")" && pwd)
VOLUME=1.0                       # ослабление в ffmpeg, 1.0 — без ослабления; громкость — Master
LIMIT=10                         # сколько треков брать из поиска
[ -f "$DIR/config" ] && . "$DIR/config"
API=https://api-v2.soundcloud.com
CID_FILE=$DIR/client_id
LIST=/tmp/sc.list                # id найденных треков, по строке
IDX=/tmp/sc.idx                  # номер текущего трека в LIST (с 0)
POS0=/tmp/sc.pos0                # с какой секунды запущен текущий трек
T0=/tmp/sc.t0                    # когда запущен (date +%s)
SEEK=/tmp/sc.seek                # просьба перезапустить текущий трек с этой секунды
JUMP=/tmp/sc.jump                # next/prev уже поменяли IDX
PAUSED=/tmp/sc.paused            # пауза: время постановки на паузу
PID=/tmp/sc-player.pid
UA="Mozilla/5.0"

# Провайдер режет колонке SoundCloud: если задана VLESS-ссылка (sc-vpn.sh set), curl и ffmpeg
# идут через локальный прокси xray, оба берут его из http_proxy/https_proxy
case "$1" in play|resume|next|prev|seek)
    if [ -f "$DIR/vless.url" ]; then
        "$DIR/sc-vpn.sh" start >/dev/null && export http_proxy=http://127.0.0.1:10809 https_proxy=http://127.0.0.1:10809
    fi ;;
esac

# client_id берём со страницы мобильного сайта: soundcloud.com с колонки не открывается,
# а m.soundcloud.com отдаёт его прямо в HTML ("clientId":"...")
refresh_cid() {
    id=$(curl -s -m 15 -A "$UA" https://m.soundcloud.com/ | grep -o 'clientId":"[A-Za-z0-9]\{32\}"' | head -1 | cut -d'"' -f3)
    [ -n "$id" ] && { echo "$id" > "$CID_FILE"; return 0; }
    return 1
}

cid() { [ -s "$CID_FILE" ] || refresh_cid; cat "$CID_FILE"; }

# GET к api-v2; при 401/403 обновляем client_id и пробуем ещё раз
api() {
    out=$(curl -s -m 15 -w '\n%{http_code}' "$1&client_id=$(cid)")
    code=${out##*
}
    case "$code" in
        401|403) refresh_cid; out=$(curl -s -m 15 -w '\n%{http_code}' "$1&client_id=$(cid)") ;;
    esac
    echo "${out%
*}"
}

search() {
    qe=$(jq -rn --arg q "$1" '$q|@uri')
    api "$API/search/tracks?q=$qe&limit=$LIMIT" |
        jq -r '.collection[] | select(.media.transcodings | length > 0) | .id' > "$LIST"
    [ -s "$LIST" ]
}

# ссылка на поток трека: HLS AAC или MP3, затем progressive
stream_url() {
    t=$(api "$API/tracks/$1?x=1")
    tu=$(echo "$t" | jq -r '
        [.media.transcodings[] | select(.snipped | not)] as $all
        | ([$all[] | select(.format.protocol == "hls")] + [$all[] | select(.format.protocol == "progressive")])
        | .[0].url // empty')
    auth=$(echo "$t" | jq -r '.track_authorization // empty')
    [ -n "$tu" ] || return 1
    api "$tu?track_authorization=$auth" | jq -r '.url // empty'
}

# Системный aplay: он читает /etc/asound.conf (default -> softvol Master -> dmix), так что
# громкость кнопками и голосом действует и на SoundCloud. aplay из Entware читает свой конфиг,
# где default — это сразу hw:0,0, мимо регулятора Master.
APLAY=/usr/bin/aplay

# Перемотка: ffmpeg не умеет -ss по HLS SoundCloud (сегменты fMP4 с EXT-X-MAP) — с -ss 42 не
# отдаёт ни байта. Поэтому собираем локальный плейлист с сегмента, где нужное место
# (по #EXTINF), а остаток внутри сегмента отрезаем после декодирования (-ss после -i).
M3U=/tmp/sc.m3u8

trim_playlist() { # url плейлиста, секунда; печатает, сколько отрезать внутри сегмента
    base=${1%%\?*}; base=${base%/*}
    curl -s -m 15 "$1" | awk -v pos="$2" -v base="$base" -v out="$M3U" '
        function abs(u) { return u ~ /^https?:/ ? u : base "/" u }
        # склейкой, не sub(): в подписанных ссылках есть «&», а в замене sub() это найденный текст
        /^#EXT-X-MAP:/ { l = $0
            if (match(l, /URI="[^"]*"/)) l = substr(l, 1, RSTART - 1) "URI=\"" abs(substr(l, RSTART + 5, RLENGTH - 6)) "\"" substr(l, RSTART + RLENGTH)
            hdr = hdr l "\n"; next }
        /^#EXTINF:/ { d = substr($0, 9) + 0; next }
        /^#EXT-X-ENDLIST/ { next }
        /^#/ { if (!started) hdr = hdr $0 "\n"; next }
        /./ { if (!started && t + d <= pos) { t += d; next }
              if (!started) { started = 1; printf "%s", hdr > out }
              printf "#EXTINF:%s,\n%s\n", d, abs($0) > out }
        END { if (!started) exit 1; print "#EXT-X-ENDLIST" > out; print pos - t }'
}

play_track() { # id, с какой секунды
    u=$(stream_url "$1") || return 1
    [ -n "$u" ] || return 1
    src=$u; cut=0
    if [ "${2:-0}" -gt 0 ]; then
        cut=$(trim_playlist "$u" "$2") || return 0   # дальше конца трека — следующий трек
        src=$M3U
    fi
    # httpproxy — так ffmpeg ходит в https через http_proxy (xray)
    ffmpeg -nostdin -hide_banner -loglevel error -protocol_whitelist file,http,https,tcp,tls,crypto,httpproxy \
        -i "$src" -ss "$cut" -af "volume=$VOLUME" -f s16le -ac 2 -ar 48000 - </dev/null 2>/tmp/sc-ffmpeg.log |
        "$APLAY" -q -D default -f S16_LE -c 2 -r 48000
}

# Текущее место в треке, секунды
position() {
    [ -f "$T0" ] || { echo 0; return; }
    echo $(( $(cat "$POS0") + $(date +%s) - $(cat "$T0") ))
}

player_loop() {
    while :; do
        idx=$(cat "$IDX" 2>/dev/null || echo 0)
        [ "$idx" -lt 0 ] && idx=0 && echo 0 > "$IDX"
        id=$(sed -n "$((idx + 1))p" "$LIST")
        [ -n "$id" ] || break
        i=0; while [ -f "$HOLD" ] && [ "$i" -lt 20 ]; do sleep 0.2; i=$((i + 1)); done
        pos=0; [ -f "$SEEK" ] && { pos=$(cat "$SEEK"); rm -f "$SEEK"; }
        echo "$pos" > "$POS0"; date +%s > "$T0"
        play_track "$id" "$pos"
        [ -f "$SEEK" ] && continue                    # перемотка: тот же трек с нового места
        [ -f "$JUMP" ] && { rm -f "$JUMP"; continue; } # next/prev уже выбрали трек
        echo $((idx + 1)) > "$IDX"
    done
}

# Медиа-демон Алисы (её голос, плеер и громкость). Пока играет SoundCloud, гасим его, как
# spotify-sink.sh в station2-media: иначе Алиса включает своё поверх, а после перезапуска
# mediad возвращает свою музыку. Голосовой канал 9875 и кнопки держит maind --platformd,
# поэтому голосовые команды доходят, а кнопки громкости platformd сам применяет к Master.
# Но голосовые «громче/тише» выполняет mediad, а после приглушения на «Алиса…» громкость
# возвращает тоже он. Поэтому, пока mediad погашен, громкость держим сами (LEVEL): изменения
# Master кнопками запоминаем, голосом меняем через sc-play.sh volume.
MEDIAD=/system/vendor/quasar/maind
GUARD=/tmp/sc-guard.pid
LEVEL=/tmp/sc.level              # громкость SoundCloud, % регулятора Master
DUCK=/tmp/sc.duck                # Алиса слушает команду — музыку тише (ставит voice-soundcloud.sh)
mediad_pids() { ps -o pid,args 2>/dev/null | awk -v b="$MEDIAD" '$2 == b && $3 == "--mediad" { print $1 }'; }

master() { amixer sget Master | grep -o '\[[0-9]*%\]' | head -n 1 | tr -d '[]%'; }

# Звук Алисы и SoundCloud смешивает dmix (общая память и семафор с ключом 0x400). Если
# убить его клиента в момент записи (mediad играет музыку Алисы), семафор остаётся занятым и
# весь dmix виснет: aplay стоит в PREPARED. Поэтому mediad гасим через SIGTERM (сам отпускает
# ALSA), а застрявший dmix, когда к нему никто не подключён, удаляем — следующий клиент
# создаст новый.
PCM=/proc/asound/card0/pcm0p/sub0/status
HOLD=/tmp/sc.hold                # идёт сброс dmix — player_loop ждёт

stop_mediad() {
    ps_=$(mediad_pids); [ -n "$ps_" ] || return 0
    kill -TERM $ps_ 2>/dev/null
    # mediad держит dmix открытым всегда; kill -9 до того, как он закроется сам, вешает dmix
    i=0
    while [ -n "$(mediad_pids)" ] && [ "$i" -lt 10 ]; do sleep 0.5; i=$((i + 1)); done
    for p in $(mediad_pids); do kill -9 "$p" 2>/dev/null; done
}

reset_dmix() {
    ipcs -m 2>/dev/null | awk '$1 == "0x00000400" || $1 == "0x00000401" { if ($6 > 0) busy = 1 } END { exit busy }' || return 1
    ipcrm -M 0x400 2>/dev/null; ipcrm -M 0x401 2>/dev/null; ipcrm -S 0x400 2>/dev/null
    return 0
}

# Кнопки громкости platformd применяет к Master сам: изменение Master не нами — новая
# громкость пользователя. Кроме времени, пока Алиса слушает (DUCK): тогда это её
# приглушение, его не запоминаем, а после возвращаем LEVEL.
guard_mediad() {
    last=$(master); stuck=0
    while [ -f "$PID" ]; do
        stop_mediad
        cur=$(master)
        [ "$cur" != "$last" ] && [ ! -f "$DUCK" ] && echo "$cur" > "$LEVEL"
        want=$(cat "$LEVEL" 2>/dev/null || echo 50)
        [ -f "$DUCK" ] && want=$((want / 3))
        [ "$cur" = "$want" ] || amixer -q set Master "$want%"
        last=$want
        # aplay есть, а звук не идёт ~6 с (дольше, чем грузится начало трека) — dmix завис:
        # перезапускаем трек с того же места
        if ps | grep -q '[/]usr/bin/aplay' && ! grep -q 'state: RUNNING' "$PCM"; then
            stuck=$((stuck + 1))
        else
            stuck=0
        fi
        if [ "$stuck" -ge 12 ]; then
            # HOLD держит player_loop, пока dmix не удалён: иначе новый aplay успевает
            # подключиться к старому семафору, и мы удаляем его у него же
            touch "$HOLD"
            position > "$SEEK"
            killall -q aplay ffmpeg 2>/dev/null
            i=0; until reset_dmix || [ "$i" -ge 10 ]; do sleep 0.3; i=$((i + 1)); done
            rm -f "$HOLD"
            stuck=0
        fi
        sleep 0.5
    done
}

# mediad после остановки поднимает лаунчер quasar, но с растущей паузой: 13 с, 57 с, больше
# 90 с подряд (station2-media: до 600 с). Поэтому, если за 10 с его нет, запускаем свой — с тем
# же окружением, что у maind от лаунчера (без LD_LIBRARY_PATH не найдёт libtflite.so). Два
# mediad дерутся за звук, и Алиса молчит: когда лаунчер поднимет свой, наш гасим — мягко
# (SIGTERM), иначе зависнет dmix.
launcher_pid() { ps -o pid,args 2>/dev/null | awk '$2 ~ /quasar_launcher/ { print $1; exit }'; }

dedupe_mediad() {
    lp=$(launcher_pid)
    extra=$(ps -o pid,ppid,args 2>/dev/null | awk -v b="$MEDIAD" -v lp="$lp" '
        $3 == b && $4 == "--mediad" { n++; if ($2 == lp) own = 1; else extra[$1] = 1 }
        END { if (n > 1) for (p in extra) if (own || --n > 0) print p }')
    [ -n "$extra" ] || return 0
    kill -TERM $extra 2>/dev/null
    i=0; while kill -0 $extra 2>/dev/null && [ "$i" -lt 10 ]; do sleep 0.5; i=$((i + 1)); done
    kill -9 $extra 2>/dev/null
}

# Вызывается в фоне, чтобы не задерживать «стоп» и голосовые команды
start_mediad() {
    [ -n "$(mediad_pids)" ] || reset_dmix    # не отдавать Алисе зависший dmix
    i=0
    while [ -z "$(mediad_pids)" ] && [ "$i" -lt 20 ]; do
        [ -f "$PID" ] && return 0              # снова играет SoundCloud — Алиса не нужна
        sleep 0.5; i=$((i + 1))
    done
    if [ -z "$(mediad_pids)" ]; then
        ( cd /data/quasar 2>/dev/null || cd /
          LD_LIBRARY_PATH=:/system/vendor/quasar/libs MALLOC_ARENA_MAX=2 \
              CA_CERTIFICATES=/system/vendor/quasar/ca-certificates.crt \
              setsid "$MEDIAD" --mediad >> /data/quasar/mediad.log 2>&1 </dev/null & )
    fi
    # лаунчер может поднять свой и позже — следим 10 минут, оставляем один
    i=0
    while [ "$i" -lt 300 ]; do
        [ -f "$PID" ] && return 0
        dedupe_mediad
        sleep 2; i=$((i + 1))
    done
}

running() { [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; }

start_player() {
    rm -f "$PAUSED" "$JUMP" "$DUCK"
    # громкость — с той, что была у Алисы; почти ноль (приглушили или убавили) — 30%, чтобы
    # не играть беззвучно
    l=$(master); [ "${l:-0}" -ge 10 ] || l=30; echo "$l" > "$LEVEL"
    # сначала отключаем Алису от dmix и, пока к нему никто не подключён, пересоздаём его:
    # SoundCloud стартует на чистом dmix, даже если прошлый клиент его повесил
    stop_mediad; reset_dmix
    ( player_loop
      # список доиграл сам: убираем сторожей и возвращаем Алису
      rm -f "$PID"; stop_helpers; start_mediad ) </dev/null >/dev/null 2>&1 &
    echo $! > "$PID"
    guard_mediad </dev/null >/dev/null 2>&1 &
    echo $! > "$GUARD"
}

stop_helpers() {
    [ -f "$GUARD" ] && kill "$(cat "$GUARD")" 2>/dev/null
    rm -f "$GUARD" "$DUCK"
    [ -s "$LEVEL" ] && amixer -q set Master "$(cat "$LEVEL")%"   # Алиса остаётся на этой громкости
}

halt_player() {
    [ -f "$PID" ] || return 0
    kill "$(cat "$PID")" 2>/dev/null
    rm -f "$PID"
    stop_helpers
    killall -q aplay ffmpeg 2>/dev/null
    sleep 1
    start_mediad </dev/null >/dev/null 2>&1 &
}

case "$1" in
    play)
        shift
        halt_player; rm -f "$PAUSED" "$SEEK"
        # распознавание часто искажает имена в конце фразы: не нашлось — убираем по слову с конца
        q="$*"
        until search "$q"; do
            case "$q" in *\ *) q=${q% *} ;; *) echo "ничего не найдено: $*"; exit 1 ;; esac
        done
        [ "$q" = "$*" ] || echo "по запросу «$*» ничего, ищу «$q»"
        echo 0 > "$IDX"
        start_player
        echo "играю: $* ($(wc -l < "$LIST") треков)"
        ;;
    next|prev)
        running || exit 1
        idx=$(cat "$IDX" 2>/dev/null || echo 0)
        if [ "$1" = next ]; then echo $((idx + 1)) > "$IDX"
        elif [ "$(position)" -gt 5 ]; then echo 0 > "$SEEK"   # как у плееров: сначала в начало трека
        else echo $((idx - 1)) > "$IDX"; fi
        [ -f "$SEEK" ] || touch "$JUMP"
        killall -q ffmpeg
        ;;
    seek)
        running || exit 1
        case "$2" in
            0) to=0 ;;
            *) to=$(( $(position) + $2 )); [ "$to" -lt 0 ] && to=0 ;;
        esac
        echo "$to" > "$SEEK"
        killall -q ffmpeg
        echo "перемотка на ${to} с"
        ;;
    pause)
        running || exit 1
        pos=$(position)
        halt_player
        echo "$pos" > "$SEEK"; date +%s > "$PAUSED"
        echo "пауза на ${pos} с"
        ;;
    resume)
        running && exit 0
        [ -f "$PAUSED" ] && [ -s "$LIST" ] || exit 1
        start_player
        echo "продолжаю с $(cat "$SEEK" 2>/dev/null || echo 0) с"
        ;;
    stop) halt_player; rm -f "$PAUSED" "$SEEK" ;;
    volume)
        l=$(cat "$LEVEL" 2>/dev/null || master)
        case "$2" in
            +*) l=$((l + ${2#+})) ;;
            -*) l=$((l - ${2#-})) ;;
            *) l=$2 ;;
        esac
        [ "$l" -gt 100 ] && l=100; [ "$l" -lt 0 ] && l=0
        echo "$l" > "$LEVEL"
        running || amixer -q set Master "$l%"   # пока играем, выставит guard_mediad
        echo "[$l%]"
        ;;
    *) echo "использование: $0 play <запрос> | next | prev | seek <±с> | pause | resume | stop | volume <+N|-N|N>"; exit 1 ;;
esac
