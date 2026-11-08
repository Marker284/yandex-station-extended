#!/bin/sh
# spotify-voice: voice control of Soloist through Quasar Bridge (busybox sh).
# The bridge rule "spotify_control" sends phrases with "спотиф"/"spotify" to the
# LLM route (so Yandex does not handle them) and the model only confirms aloud.
# This watcher follows the bridge conversation journal ($BRIDGE_JOURNAL,
# "conversation_log" in the bridge config.json) and, when a request with such a
# phrase gets route=llm, runs the matching `soloist ctl` command.
# Journal (quasar-bridge internal/journal, Go json.Marshal), one object a line:
#   {"time":..,"request":"<id>","event":"transcript","text":"..",..}
#   {"time":..,"request":"<id>","event":"route","route":"llm",..}
# Only known commands run; anything else is logged as "ignored".
# Privacy: recognised text is never written to our log, only the action.
O=$(cd "$(dirname "$0")" && pwd)
. "$O/lib.sh"
VLOG="$RUN/voice.log"
mkdir -p "$RUN"

log() { log_to "$VLOG" "$@"; }

ctl() { ldr "$O/bin/soloist" ctl "$@" -D "$O/data" > /dev/null 2>&1; }

act() {
    case "$1" in
        play)
            ctl activate; r1=$?
            ctl play; r2=$?
            log "voice command -> play (activate rc=$r1, play rc=$r2)" ;;
        pause|next|prev)
            ctl "$1"; log "voice command -> $1 (rc=$?)" ;;
        *)
            log "voice: spotify phrase without a known command, ignored" ;;
    esac
}

# JSON-aware parser: string fields with escapes, any spacing, several requests
# in flight (matched by request id). Prints one action per routed request.
PARSER='
function jstr(s, key,    i, n, c, out) {
    if (!match(s, "\"" key "\"[ \t]*:[ \t]*\"")) return ""
    i = RSTART + RLENGTH; n = length(s); out = ""
    while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\\") {
            i++; c = substr(s, i, 1)
            if (c == "u") { c = " "; i += 4 }
            else if (c == "n" || c == "t" || c == "r" || c == "b" || c == "f") c = " "
        } else if (c == "\"") return out
        out = out c; i++
    }
    return ""
}
function classify(t) {
    # plain alternatives, not [Пп]: busybox awk matches bytes, not letters
    if (t ~ /пауз|Пауз|стоп|Стоп|останов|Останов|выключ|Выключ|хватит|Хватит/) return "pause"
    if (t ~ /следующ|Следующ|дальше|Дальше|переключ|Переключ|пропуст|Пропуст/) return "next"
    if (t ~ /предыдущ|Предыдущ|назад|Назад|прошл|Прошл/) return "prev"
    if (t ~ /включ|Включ|играй|Играй|продолж|Продолж|запуст|Запуст|воспроизв|Воспроизв|возобнов|Возобнов/) return "play"
    return "unknown"
}
{
    ev = jstr($0, "event"); id = jstr($0, "request")
    if (id == "") next
    if (ev == "transcript" || ev == "request") {
        t = jstr($0, "text")
        if (t == "") next
        if (!(id in txt)) { order[++last] = id; if (last - first >= 16) { delete txt[order[++first]] } }
        txt[id] = t
    } else if (ev == "route") {
        if (!(id in txt)) next
        t = txt[id]; delete txt[id]
        if (jstr($0, "route") != "llm") next
        if (t ~ /спотиф|Спотиф|СПОТИФ|[Ss]potify|SPOTIFY/) { print classify(t); fflush() }
    }
}'

TPID=""
# Killing tail ends the stream: awk sees EOF, the read loop ends with it.
stop() { end_nap; [ -n "$TPID" ] && kill -TERM "$TPID" 2>/dev/null; log "voice watcher stop"; exit 0; }
trap stop INT TERM

log "voice watcher start"
while [ ! -e "$BRIDGE_JOURNAL" ]; do nap 5; done
FIFO="$RUN/voice.fifo"
rm -f "$FIFO"; mkfifo "$FIFO" || exit 1
tail -n 0 -F "$BRIDGE_JOURNAL" > "$FIFO" 2>/dev/null &
TPID=$!
# In the background + wait: a trap does not run while sh waits for a
# foreground pipeline, so TERM would be ignored until the journal ends.
awk "$PARSER" < "$FIFO" | while IFS= read -r a; do act "$a"; done &
wait $!
log "voice watcher: journal stream ended"
kill -TERM "$TPID" 2>/dev/null
exit 1
