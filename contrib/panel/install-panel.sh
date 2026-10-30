# Установщик веб-панели колонки: вставьте весь этот код в консоль колонки (SSH или терминал
# AliceBridge). Нужен Entware. HTTPS на порту 8443. Пароль задаётся при первом входе в браузере
# по коду установки, который установщик напечатает в конце. Повторная установка обновляет панель,
# а пароль и сертификат сохраняет (сбросить пароль: rm /data/opt/panel/config и установить снова).
(
export PATH=/opt/bin:/opt/sbin:/usr/bin:/bin:/usr/sbin:/sbin
D=/data/opt/panel

command -v socat >/dev/null || opkg install socat >/dev/null || { echo "❌ Не поставился socat (нужен Entware)"; exit 1; }
command -v openssl >/dev/null || opkg install openssl-util >/dev/null || { echo "❌ Не поставился openssl"; exit 1; }

mkdir -p "$D/www"
cat > "$D/http.sh" <<'EOF_PANEL'
#!/bin/sh
# Веб-панель колонки: обработчик одного HTTPS-запроса (socat OPENSSL-LISTEN … fork EXEC).
# Защита: пароль (sha256 с солью), сессия в cookie HttpOnly/Secure/SameSite=Strict,
# блокировка после 5 неверных паролей за 5 минут, для API — обязательный заголовок X-Panel.
# Первый вход: пароля ещё нет (HASH пустой) — его задают в браузере с одноразовым кодом
# установки (setup-code, его печатает установщик), иначе пароль задал бы любой в сети.
export PATH=/opt/bin:/opt/sbin:/usr/bin:/bin:/usr/sbin:/sbin
DIR=$(cd "$(dirname "$0")" && pwd)
SALT=; HASH=
[ -f "$DIR/config" ] && . "$DIR/config"   # SALT=, HASH=
TZ=MSK-3                                  # часы колонки идут в UTC; пояс для журналов и расписания
[ -f "$DIR/settings" ] && . "$DIR/settings"
export TZ
SETUP_FILE=$DIR/setup-code
ST=/tmp/panel
LOG=$DIR/panel.log
AUTO=$DIR/autostart.d
CRON=$DIR/cron
SESSION_SECONDS=43200
CMD_SECONDS=30
BODY_MAX=1048576                  # для всего, кроме загрузки файлов
mkdir -p "$ST/sess"
[ -f "$ST/cwd" ] || echo /data > "$ST/cwd"
CR=$(printf '\r')
PEER=${SOCAT_PEERADDR:-?}
T=$ST/resp.$$
trap 'rm -f "$T" "$ST/body.$$" "$ST/up.$$" "$ST/say.$$"*' EXIT

log() { echo "$(date '+%m-%d %H:%M:%S') $PEER $*" >> "$LOG"; }

# ---- HTTP --------------------------------------------------------------------

reply() { # статус тип [доп. заголовки]; тело — в $T
    n=$(wc -c < "$T")
    printf 'HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %s\r\nCache-Control: no-store\r\n' "$1" "$2" "$n"
    printf 'X-Frame-Options: DENY\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n'
    printf "Content-Security-Policy: default-src 'self'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'\r\n"
    printf 'Strict-Transport-Security: max-age=31536000\r\nConnection: close\r\n'
    [ -n "${3:-}" ] && printf '%s\r\n' "$3"
    printf '\r\n'
    cat "$T"
    exit 0
}

text() { printf '%s' "$2" > "$T"; reply "$1" 'text/plain; charset=utf-8' "$3"; }
out() { "$@" > "$T" 2>&1; reply '200 OK' 'text/plain; charset=utf-8'; }   # ответ — вывод функции

read -r method target _ || exit 0
method=${method%$CR}; target=${target%$CR}
len=0; cookie=; xpanel=; xname=; xpath=
while IFS= read -r h; do
    h=${h%$CR}; [ -n "$h" ] || break
    case "$h" in
        [Cc]ontent-[Ll]ength:*) len=${h#*:}; len=${len# } ;;
        [Cc]ookie:*) cookie=${h#*:} ;;
        [Xx]-[Pp]anel:*) xpanel=1 ;;
        [Xx]-[Ff]ile-[Nn]ame:*) xname=${h#*:}; xname=${xname# } ;;
        [Xx]-[Ff]ile-[Pp]ath:*) xpath=${h#*:}; xpath=${xpath# } ;;
    esac
done
case "$len" in ''|*[!0-9]*) len=0 ;; esac
path=${target%%\?*}

body() { # тело запроса (до BODY_MAX) — в файл
    [ "$len" -le "$BODY_MAX" ] || text '413 Payload Too Large' 'слишком большой запрос'
    head -c "$len" > "$ST/body.$$"
    cat "$ST/body.$$"
}

# ---- Сессии ------------------------------------------------------------------

now=$(date +%s)
sid=$(echo "$cookie" | sed -n 's/.*sid=\([0-9a-f]\{32\}\).*/\1/p')

authed() {
    [ -n "$sid" ] && [ -f "$ST/sess/$sid" ] && [ "$now" -lt "$(cat "$ST/sess/$sid")" ] || return 1
    echo $((now + SESSION_SECONDS)) > "$ST/sess/$sid"
}

check_password() { [ -n "$HASH" ] && [ "$(printf '%s%s' "$SALT" "$1" | sha256sum | cut -d' ' -f1)" = "$HASH" ]; }

# 5 неверных паролей или кодов за 5 минут — вход закрыт на 5 минут
check_lock() {
    fails=$(awk -v t=$((now - 300)) '$1 > t' "$ST/fails" 2>/dev/null | wc -l)
    [ "$fails" -lt 5 ] || { log "login locked"; text '429 Too Many Requests' 'слишком много попыток, подождите 5 минут'; }
}

failed() { echo "$now" >> "$ST/fails"; log "$1 FAILED"; sleep 1; text '401 Unauthorized' "$2"; }

new_session() { # выдать cookie и ответить
    sid=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    echo $((now + SESSION_SECONDS)) > "$ST/sess/$sid"
    find "$ST/sess" -type f -mmin +720 -exec rm -f {} \; 2>/dev/null
    text '200 OK' ok "Set-Cookie: sid=$sid; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=$SESSION_SECONDS"
}

save_password() { # новый пароль -> config (соль новая)
    s=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    h=$(printf '%s%s' "$s" "$1" | sha256sum | cut -d' ' -f1)
    printf 'SALT=%s\nHASH=%s\n' "$s" "$h" > "$DIR/config.new" && chmod 600 "$DIR/config.new" && mv "$DIR/config.new" "$DIR/config"
}

login() {
    check_lock
    pw=$(body)
    check_password "$pw" || failed login 'неверный пароль'
    log "login ok"
    new_session
}

setup() { # первый вход: тело — код установки, перевод строки, новый пароль
    [ -z "$HASH" ] || text '409 Conflict' 'пароль уже задан'
    check_lock
    b=$(body); code=$(echo "$b" | head -n 1 | tr -cd '0-9a-f'); new=$(echo "$b" | sed -n 2p)
    [ -s "$SETUP_FILE" ] && [ "$code" = "$(cat "$SETUP_FILE")" ] || failed setup 'неверный код установки'
    [ "${#new}" -ge 8 ] || text '400 Bad Request' 'пароль короче 8 символов'
    save_password "$new"
    rm -f "$SETUP_FILE" "$ST/fails"
    log "setup: password set"
    new_session
}

# ---- Система -----------------------------------------------------------------

master() { amixer sget Master | grep -o '\[[0-9]*%\]' | head -n 1 | tr -d '[]%'; }
cwd() { cat "$ST/cwd"; }
abspath() { case "$1" in /*) echo "$1" ;; *) echo "$(cwd)/$1" ;; esac; }
temp() { echo $(( $(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0) / 1000 )); }
wlan_ip() {
    ip=$(ip -4 addr show wlan0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
    [ -n "$ip" ] || ip=$(ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p')
    echo "$ip"
}

system_info() {
    up=$(awk '{printf "%dд %dч %dм", int($1/86400), int($1%86400/3600), int($1%3600/60)}' /proc/uptime)
    echo "Модель:       $(tr -d '\0' < /proc/device-tree/model 2>/dev/null)"
    echo "Прошивка:     $(head -n 1 /system/vendor/quasar/version_full 2>/dev/null)"
    echo "Ядро:         $(uname -r), $(uname -m)"
    echo "Работает:     $up"
    echo "Время:        $(date '+%d.%m.%Y %H:%M') ($TZ)"
    echo "Температура:  $(temp) °C"
    echo "Wi-Fi:        $(wpa_cli -i wlan0 status 2>/dev/null | sed -n 's/^ssid=//p')"
    echo "IP / MAC:     $(wlan_ip) / $(cat /sys/class/net/wlan0/address 2>/dev/null)"
    echo "Громкость:    $(master) %"
}

resources() {
    read -r _ a1 b1 c1 d1 e1 f1 g1 _ < /proc/stat
    sleep 1
    read -r _ a2 b2 c2 d2 e2 f2 g2 _ < /proc/stat
    busy=$(( (a2 + b2 + c2 + f2 + g2) - (a1 + b1 + c1 + f1 + g1) ))
    total=$(( busy + (d2 + e2) - (d1 + e1) ))
    echo "CPU:          $(( total > 0 ? busy * 100 / total : 0 )) %, нагрузка $(cut -d' ' -f1-3 /proc/loadavg)"
    free | awk '/^Mem:/ {printf "Память:       %d из %d МБ занято, доступно %d МБ\n", $3/1024, $2/1024, $7/1024}'
    echo "Температура:  $(temp) °C"
    awk -F'[: ]+' '/wlan0/ {printf "Сеть wlan0:   приём %d МБ, отправка %d МБ\n", $3/1048576, $11/1048576}' /proc/net/dev
    df -h /data /tmp 2>/dev/null | awk 'NR > 1 {printf "Диск %-8s %s из %s свободно\n", $6 ":", $4, $2}'
}

# ---- Консоль и файлы ---------------------------------------------------------

run_cmd() { # команда — в текущей папке, не дольше CMD_SECONDS
    c=$1
    case "$c" in
        cd|"cd "*)
            d=${c#cd}; d=${d# }; [ -n "$d" ] || d=/data
            # eval — чтобы работали кавычки и ~ как в обычной оболочке (доступ и так только после входа)
            if n=$(cd "$(cwd)" 2>/dev/null && eval "cd $d" 2>/dev/null && pwd); then echo "$n" > "$ST/cwd"; else echo "нет такой папки: $d"; fi
            return ;;
    esac
    log "cmd: $c"
    ( cd "$(cwd)" 2>/dev/null; exec sh -c "$c" ) > "$ST/out.$$" 2>&1 </dev/null &
    p=$!
    i=0
    while kill -0 "$p" 2>/dev/null && [ "$i" -lt $((CMD_SECONDS * 2)) ]; do sleep 0.5; i=$((i + 1)); done
    if kill -0 "$p" 2>/dev/null; then
        kill "$p" 2>/dev/null
        echo "[прервано: дольше $CMD_SECONDS с — долгое запускайте с & в конце]" >> "$ST/out.$$"
    fi
    head -c 200000 "$ST/out.$$"
    rm -f "$ST/out.$$"
}

# Первая строка — папка, дальше «тип|размер|имя» (d — папка, f — файл). Имена берём из оболочки:
# ls из busybox заменяет кириллицу на «?», и такой файл было бы не скачать.
list_dir() {
    d=$(cwd); echo "$d"
    for f in "$d"/* "$d"/.[!.]* "$d"/..?*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        n=${f##*/}
        if [ -d "$f" ]; then echo "d||$n"
        else echo "f|$(ls -ld "$f" 2>/dev/null | awk '{print $5}')|$n"; fi
    done
}

upload() { # тело — содержимое, X-File-Name — имя в base64
    name=$(echo "$xname" | base64 -d 2>/dev/null | tr -d '/\000-\037')
    case "$name" in ''|.|..) text '400 Bad Request' 'нет имени файла' ;; esac
    free=$(df -k "$(cwd)" | awk 'NR == 2 {print $4 * 1024}')
    [ "$len" -lt "${free:-0}" ] || text '507 Insufficient Storage' "не хватает места в $(cwd)"
    dst="$(cwd)/$name"
    head -c "$len" > "$ST/up.$$" && mv "$ST/up.$$" "$dst" || text '500 Internal Server Error' 'не удалось сохранить'
    case "$name" in *.sh) chmod 755 "$dst" ;; esac
    log "upload: $dst ($len)"
    text '200 OK' "сохранено: $dst ($len байт)"
}

download() {
    f=$(abspath "$(body)")
    [ -f "$f" ] && [ -r "$f" ] || text '404 Not Found' "нет такого файла: $f"
    log "download: $f"
    n=$(wc -c < "$f")
    printf 'HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: %s\r\n' "$n"
    printf 'Content-Disposition: attachment; filename="%s"\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n' \
        "$(basename "$f" | tr -d '"\r\n')"
    cat "$f"
    exit 0
}

file_read() { # редактор: тело — путь; ответ — содержимое (до 1 МБ), X-File-Path — полный путь
    f=$(abspath "$(body | head -n 1)")
    [ -f "$f" ] || text '404 Not Found' "нет такого файла: $f"
    [ "$(wc -c < "$f")" -le "$BODY_MAX" ] || text '413 Payload Too Large' 'файл больше 1 МБ — скачайте его'
    cp "$f" "$T"
    reply '200 OK' 'text/plain; charset=utf-8' "X-File-Path: $(printf '%s' "$f" | base64 | tr -d '\n')"
}

file_write() { # редактор: X-File-Path — путь в base64, тело — новое содержимое
    f=$(abspath "$(echo "$xpath" | base64 -d 2>/dev/null)")
    [ -d "$(dirname "$f")" ] || text '400 Bad Request' "нет папки: $(dirname "$f")"
    [ "$len" -le "$BODY_MAX" ] || text '413 Payload Too Large' 'больше 1 МБ'
    head -c "$len" > "$ST/up.$$" && cat "$ST/up.$$" > "$f" || text '500 Internal Server Error' "не удалось записать $f"
    log "edit: $f ($len)"
    text '200 OK' "сохранено: $f ($len байт)"
}

# ---- Процессы ----------------------------------------------------------------

procs() { # «pid|ppid|пользователь|состояние|VSZ|CPU|команда»
    top -b -n 1 2>/dev/null | awk 'NR > 4 && $1 ~ /^[0-9]+$/ {
        c = $8; for (i = 9; i <= NF; i++) c = c " " $i
        print $1 "|" $2 "|" $3 "|" $4 "|" $5 "|" $7 "|" c }'
}

signal() { # тело: «pid сигнал»
    set -- $(body | head -n 1 | tr -cd 'A-Z0-9 ')
    case "$1" in ''|*[!0-9]*|1) echo "неверный pid"; return ;; esac
    case "${2:-TERM}" in TERM|KILL|STOP|CONT|HUP|INT) s=${2:-TERM} ;; *) echo "неверный сигнал"; return ;; esac
    if kill -"$s" "$1" 2>/dev/null; then log "kill -$s $1"; echo "SIG$s отправлен процессу $1"; else echo "не получилось: процесса $1 нет?"; fi
}

# ---- Свой автозапуск (autostart.d/*.sh; включён — если исполняемый) ----------

# имя без точек в начале: иначе «../x» стало бы скрытым «....x.sh», которого не видно в списке
auto_name() { n=$(echo "$1" | head -n 1 | tr -cd 'A-Za-z0-9_.-' | sed 's/^\.*//'); n=${n%.sh}; [ -n "$n" ] || return 1; echo "$n"; }

# pid процессов, в командной строке которых есть строка $1 (без самого awk — иначе нашёл бы себя)
pids_with() { ps -o pid,args 2>/dev/null | awk -v s="$1" 'index($0, s) && !/ awk /' | awk '{print $1}'; }

auto() {
    mkdir -p "$AUTO"
    case "$1" in
        list) for f in "$AUTO"/*.sh; do
                  [ -e "$f" ] || continue
                  b=$(basename "$f" .sh); [ -x "$f" ] && on=1 || on=0
                  run=0; [ -n "$(pids_with "$f")" ] && run=1
                  echo "$b|$on|$run"
              done ;;
        save) n=$(auto_name "$(echo "$xname" | base64 -d 2>/dev/null)") || { echo "неверное имя"; return; }
              [ "$len" -le "$BODY_MAX" ] || { echo "больше 1 МБ"; return; }
              new=0; [ -e "$AUTO/$n.sh" ] || new=1
              head -c "$len" > "$AUTO/$n.sh"
              [ "$new" = 1 ] && chmod 755 "$AUTO/$n.sh"
              log "autostart save: $n"; echo "сохранено: $n" ;;
        *)    n=$(auto_name "$(body)") || { echo "неверное имя"; return; }
              f=$AUTO/$n.sh
              [ -f "$f" ] || { echo "нет скрипта $n"; return; }
              case "$1" in
                  get)    cat "$f" ;;
                  toggle) if [ -x "$f" ]; then chmod 644 "$f"; echo "$n: выключен"; else chmod 755 "$f"; echo "$n: включён"; fi
                          log "autostart toggle: $n" ;;
                  run)    (cd "$AUTO" && setsid sh "$f" >> "$AUTO/$n.log" 2>&1 </dev/null &)
                          log "autostart run: $n"; echo "$n запущен" ;;
                  stop)   for p in $(pids_with "$f"); do kill "$p" 2>/dev/null; done
                          echo "$n остановлен" ;;
                  log)    tail -n 80 "$AUTO/$n.log" 2>/dev/null || echo "журнала пока нет" ;;
                  delete) rm -f "$f" "$AUTO/$n.log"; log "autostart delete: $n"; echo "$n удалён" ;;
              esac ;;
    esac
}

# ---- Планировщик (busybox crond, свой каталог crontab) -----------------------

crond_up() { ps -o args 2>/dev/null | grep -q "[c]rond .*-c $CRON"; }
crond_start() {
    crond_up && return 0
    mkdir -p "$CRON"; touch "$CRON/root"
    TZ=$TZ crond -b -c "$CRON" -L "$DIR/cron.log"
}

cron_get() {
    echo "Время на колонке: $(date '+%d.%m.%Y %H:%M') ($TZ), crond: $(crond_up && echo работает || echo остановлен)"
    echo "---"
    cat "$CRON/root" 2>/dev/null
}

cron_set() {
    mkdir -p "$CRON"
    body | tr -d '\r' > "$CRON/root.new"
    bad=$(awk 'NF && $0 !~ /^[[:space:]]*#/ && $0 !~ /^[A-Za-z_]+=/ && NF < 6 {print NR}' "$CRON/root.new" | head -n 1)
    [ -z "$bad" ] || { rm -f "$CRON/root.new"; echo "строка $bad: нужно «мин час день месяц день_недели команда»"; return; }
    mv "$CRON/root.new" "$CRON/root"; chmod 600 "$CRON/root"
    touch "$CRON/cron.update"
    crond_start
    log "cron saved"; echo "расписание сохранено"
}

# ---- Звук --------------------------------------------------------------------

SND=$ST/sound.pid
sound_running() { [ -f "$SND" ] && kill -0 "$(cat "$SND")" 2>/dev/null; }

sound_stop() {
    if [ -f "$SND" ]; then
        pp=$(cat "$SND")
        for c in $(ps -o pid,ppid 2>/dev/null | awk -v pp="$pp" '$2 == pp {print $1}'); do kill "$c" 2>/dev/null; done
        kill "$pp" 2>/dev/null; rm -f "$SND"
    fi
    echo "остановлено"
}

sound_play() { # тело: путь к файлу (от текущей папки) или ссылка http(s)
    src=$(body | head -n 1)
    command -v ffmpeg >/dev/null || { echo "нужен ffmpeg: opkg install ffmpeg"; return; }
    case "$src" in
        http://*|https://*) ;;
        '') echo "нет файла или ссылки"; return ;;
        *) src=$(abspath "$src"); [ -f "$src" ] || { echo "нет такого файла: $src"; return; } ;;
    esac
    sound_stop >/dev/null
    # системный aplay: default -> softvol Master -> dmix, рядом с Алисой
    ( ffmpeg -nostdin -hide_banner -loglevel error -i "$src" -f s16le -ac 2 -ar 48000 - 2>"$ST/sound.err" |
        /usr/bin/aplay -q -D default -f S16_LE -c 2 -r 48000 ) </dev/null >/dev/null 2>&1 &
    echo $! > "$SND"; echo "$src" > "$ST/sound.src"
    log "sound: $src"; echo "играет: $src"
}

sound_status() {
    if sound_running; then echo "играет: $(cat "$ST/sound.src")"; else echo "тишина"; fi
    [ -s "$ST/sound.err" ] && { echo; tail -n 3 "$ST/sound.err"; }
}

# ---- Подсветка (3 RGB-зоны кольца, яркость 0–255) ----------------------------

LEDS=/sys/class/leds
led_state() {
    [ -e "$LEDS/micro:red:ring1/brightness" ] || { echo "нет подсветки micro:*:ring*"; return; }
    for z in 1 2 3; do
        echo "$z $(cat "$LEDS/micro:red:ring$z/brightness") $(cat "$LEDS/micro:green:ring$z/brightness") $(cat "$LEDS/micro:blue:ring$z/brightness")"
    done
}

led_set() { # тело: «зона r g b» (зона all|1|2|3) или «off»
    set -- $(body | head -n 1 | tr -cd 'a-z0-9 ')
    [ "$1" = off ] && set -- all 0 0 0
    case "$1" in all) zs="1 2 3" ;; 1|2|3) zs=$1 ;; *) echo "неверная зона"; return ;; esac
    for v in "$2" "$3" "$4"; do
        case "$v" in ''|*[!0-9]*) echo "неверный цвет"; return ;; esac
        [ "$v" -le 255 ] || { echo "яркость 0–255"; return; }
    done
    for z in $zs; do
        echo "$2" > "$LEDS/micro:red:ring$z/brightness"
        echo "$3" > "$LEDS/micro:green:ring$z/brightness"
        echo "$4" > "$LEDS/micro:blue:ring$z/brightness"
    done
    led_state
}

# ---- Алиса -------------------------------------------------------------------

# «Алиса, скажи»: кадр как в contrib/alice-say.py (проверен на Лайт 2): подписка на события
# AliceCapability и START_VOCALIZE с текстом — в канал aliced 127.0.0.1:9875.
alice_say() {
    t=$(body | tr '\r\n' '  ' | head -c 600)
    [ -n "$t" ] || { echo "пустой текст"; return; }
    printf '%s' "$t" | od -An -v -tu1 | tr -s ' \n' ' ' > "$ST/say.$$.hex"
    awk -v t="$(cat "$ST/say.$$.hex")" '
        function v(x,   o) { o = ""; while (x >= 128) { o = o sprintf("\\0%03o", x % 128 + 128); x = int(x / 128) } return o sprintf("\\0%03o", x) }
        function s(str,   i, o) { o = ""; for (i = 1; i <= length(str); i++) o = o sprintf("\\0%03o", ord[substr(str, i, 1)]); return o }
        function blen(b) { return gsub(/\\0[0-7][0-7][0-7]/, "&", b) }
        function bf(f, b) { return v(f * 8 + 2) v(blen(b)) b }
        function iv(f, x) { return v(f * 8) v(x) }
        function frame(f, p,   e, n) { e = bf(252, bf(7, s("AliceCapability")) bf(f, p)) iv(253, 210); n = blen(e)
            return sprintf("\\0%03o\\0%03o\\0%03o\\0%03o", n % 256, int(n / 256) % 256, int(n / 65536) % 256, 0) e }
        BEGIN {
            for (i = 32; i < 127; i++) ord[sprintf("%c", i)] = i
            n = split(t, a, " "); txt = ""; for (i = 1; i <= n; i++) if (a[i] != "") txt = txt sprintf("\\0%03o", a[i])
            printf "%s%s", frame(20, bf(1, s("AliceCapability"))), frame(8, iv(1, 18) iv(3, 1) bf(13, bf(1, txt) iv(2, 1)))
        }' > "$ST/say.$$.esc"
    printf '%b' "$(cat "$ST/say.$$.esc")" > "$ST/say.$$.bin"
    (cat "$ST/say.$$.bin"; sleep 3) | socat -T 5 - TCP:127.0.0.1:9875 >/dev/null 2>&1
    log "say: $t"; echo "отправлено Алисе"
}

MEDIAD=/system/vendor/quasar/maind
mediad_pids() { ps -o pid,args 2>/dev/null | awk -v b="$MEDIAD" '$2 == b && $3 == "--mediad" { print $1 }'; }
launcher_pid() { ps -o pid,args 2>/dev/null | awk '$2 ~ /quasar_launcher/ { print $1; exit }'; }

# Перезапуск медиа-демона Алисы (её голос и плеер). Лаунчер quasar поднимает его с растущей
# паузой (бывает больше 90 с), поэтому через 10 с запускаем свой, а когда лаунчер поднимет
# свой — наш гасим через SIGTERM: два mediad дерутся за звук. kill -9 вешает dmix, его — в последнюю очередь.
alice_restart() {
    p=$(mediad_pids)
    [ -n "$p" ] && kill -TERM $p 2>/dev/null
    i=0; while [ -n "$(mediad_pids)" ] && [ "$i" -lt 10 ]; do sleep 0.5; i=$((i + 1)); done
    for x in $(mediad_pids); do kill -9 "$x" 2>/dev/null; done
    (
        i=0; while [ -z "$(mediad_pids)" ] && [ "$i" -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
        if [ -z "$(mediad_pids)" ]; then
            cd /data/quasar 2>/dev/null || cd /
            LD_LIBRARY_PATH=:/system/vendor/quasar/libs MALLOC_ARENA_MAX=2 \
                CA_CERTIFICATES=/system/vendor/quasar/ca-certificates.crt \
                setsid "$MEDIAD" --mediad >> /data/quasar/mediad.log 2>&1 </dev/null &
        fi
        i=0
        while [ "$i" -lt 300 ]; do
            lp=$(launcher_pid)
            extra=$(ps -o pid,ppid,args 2>/dev/null | awk -v b="$MEDIAD" -v lp="$lp" '
                $3 == b && $4 == "--mediad" { n++; if ($2 == lp) own = 1; else x[$1] = 1 }
                END { if (n > 1) for (p in x) if (own || --n > 0) print p }')
            [ -n "$extra" ] && kill -TERM $extra 2>/dev/null
            sleep 2; i=$((i + 1))
        done
    ) </dev/null >/dev/null 2>&1 &
    log "alice restart"
    echo "медиа-демон Алисы перезапускается — 10–15 с"
}

# ---- Журналы -----------------------------------------------------------------

log_files() { # «путь|размер» — только эти файлы можно читать
    for f in "$LOG" "$DIR/cron.log" "$AUTO"/*.log /data/quasar/daemons_logs/*.log /data/quasar/*.log; do
        [ -f "$f" ] && echo "$f|$(ls -ld "$f" | awk '{print $5}')"
    done
}

log_tail() { # тело: путь, сколько строк, фильтр
    b=$(body); f=$(echo "$b" | sed -n 1p); n=$(echo "$b" | sed -n 2p | tr -cd '0-9'); q=$(echo "$b" | sed -n 3p)
    log_files | cut -d'|' -f1 | grep -qxF -- "$f" || { echo "этот файл не журнал"; return; }
    [ -n "$n" ] && [ "$n" -le 2000 ] || n=200
    if [ -n "$q" ]; then grep -iF -- "$q" "$f" | tail -n "$n"; else tail -n "$n" "$f"; fi
}

# ---- Сеть --------------------------------------------------------------------

net_info() {
    wpa_cli -i wlan0 status 2>/dev/null > "$ST/wpa.$$"
    echo "Сеть:         $(sed -n 's/^ssid=//p' "$ST/wpa.$$")"
    echo "Частота:      $(sed -n 's/^freq=//p' "$ST/wpa.$$") МГц"
    echo "Сигнал:       $(awk '/wlan0:/ {print int($4)}' /proc/net/wireless) дБм"
    echo "IP:           $(wlan_ip)"
    echo "Шлюз:         $(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')"
    echo "DNS:          $(awk '/^nameserver/ {print $2}' /etc/resolv.conf | tr '\n' ' ')"
    awk -F'[: ]+' '/wlan0/ {printf "Трафик:       приём %d МБ, отправка %d МБ\n", $3/1048576, $11/1048576}' /proc/net/dev
    rm -f "$ST/wpa.$$"
}

net_ping() {
    h=$(body | head -n 1 | tr -cd 'A-Za-z0-9.:-')
    [ -n "$h" ] || { echo "нет адреса"; return; }
    ping -c 4 -W 2 "$h" 2>&1 | tail -n 6
}

net_sites() {
    for s in ya.ru google.com github.com cloudflare.com telegram.org; do
        r=$(curl -s -o /dev/null -m 6 -w '%{http_code} %{time_total}' "https://$s/" 2>/dev/null)
        case "$r" in 000*|'') echo "❌ $s — нет ответа" ;; *) echo "✅ $s — ${r#* } с (HTTP ${r%% *})" ;; esac
    done
}

# ---- Бэкап (всё в /data/opt, кроме пакетов Entware) --------------------------

backup_make() {
    rm -f "$ST"/backup-*.tar.gz
    f=$ST/backup-$(date '+%Y%m%d-%H%M').tar.gz
    (cd / && tar -c --exclude=data/opt/entware data/opt 2>/dev/null) | gzip > "$f"
    log "backup: $f"
    echo "$f|$(wc -c < "$f")"
}

backup_restore() { # тело: путь к загруженному архиву
    a=$(abspath "$(body | head -n 1)")
    [ -f "$a" ] || { echo "нет файла: $a"; return; }
    gzip -t "$a" 2>/dev/null || { echo "это не .tar.gz"; return; }
    gzip -dc "$a" | tar -t 2>/dev/null | grep -qv '^data/opt/' && { echo "в архиве есть файлы не из data/opt — не восстанавливаю"; return; }
    gzip -dc "$a" | tar -x -C / && { log "restore: $a"; echo "восстановлено из $a"; } || echo "ошибка распаковки"
}

# ---- Настройки ---------------------------------------------------------------

tz_set() {
    z=$(body | head -n 1 | tr -cd 'A-Za-z0-9+:,./<>-')
    [ -n "$z" ] || { echo "пустой пояс"; return; }
    echo "TZ=$z" > "$DIR/settings"
    for p in $(pids_with "crond -b -c $CRON"); do kill "$p" 2>/dev/null; done
    TZ=$z; crond_start
    log "tz: $z"; echo "часовой пояс: $z, сейчас $(TZ=$z date '+%H:%M')"
}

passwd() { # тело: старый пароль, перевод строки, новый
    b=$(body); old=$(echo "$b" | head -n 1); new=$(echo "$b" | sed -n 2p)
    check_password "$old" || { log "passwd FAILED"; text '403 Forbidden' 'старый пароль неверный'; }
    [ "${#new}" -ge 8 ] || text '400 Bad Request' 'новый пароль короче 8 символов'
    save_password "$new"
    find "$ST/sess" -type f ! -name "$sid" -exec rm -f {} \;     # остальные сессии — выйти
    log "passwd changed"
    text '200 OK' 'пароль изменён, остальные сессии закрыты'
}

# ---- Маршруты ----------------------------------------------------------------

case "$method $path" in
    "GET /"|"GET /index.html") cp "$DIR/www/index.html" "$T"; reply '200 OK' 'text/html; charset=utf-8' ;;
    "GET /app.js") cp "$DIR/www/app.js" "$T"; reply '200 OK' 'application/javascript; charset=utf-8' ;;
    "GET /favicon.ico") : > "$T"; reply '204 No Content' 'text/plain' ;;
    *" /api/"*) ;;
    *) text '404 Not Found' 'нет такой страницы' ;;
esac

# API: только POST и только с X-Panel — так его не вызвать с чужого сайта
[ "$method" = POST ] && [ -n "$xpanel" ] || text '403 Forbidden' 'запрещено'
api=${path#/api/}
if [ -z "$HASH" ]; then                    # пароль ещё не задан — только первая настройка
    [ "$api" = setup ] && setup
    text '409 Conflict' 'нужна первая настройка'
fi
[ "$api" = login ] && login
authed || text '401 Unauthorized' 'нужен вход'

case "$api" in
    me)            text '200 OK' ok ;;
    logout)        rm -f "$ST/sess/$sid"; log logout
                   text '200 OK' ok 'Set-Cookie: sid=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0' ;;
    system)        out system_info ;;
    resources)     out resources ;;
    hist)          cat "$ST/hist" > "$T" 2>/dev/null; reply '200 OK' 'text/plain; charset=utf-8' ;;
    volume)        v=$(body | tr -cd 'a-z0-9+-')
                   case "$v" in
                       mute) cur=$(master)
                             if [ "${cur:-0}" -gt 0 ]; then echo "$cur" > "$ST/unmute"; v=0; else v=$(cat "$ST/unmute" 2>/dev/null || echo 50); fi ;;
                       +[0-9]*|-[0-9]*|[0-9]*) ;;
                       *) text '400 Bad Request' 'неверное значение' ;;
                   esac
                   case "$v" in +*|-*) amixer -q set Master "${v#[+-]}%${v%%[0-9]*}" ;; *) amixer -q set Master "$v%" ;; esac
                   text '200 OK' "[$(master)%]" ;;
    cmd)           run_cmd "$(body)" > "$T"; reply '200 OK' 'text/plain; charset=utf-8' "X-Cwd: $(cwd | tr -d '\r\n' | base64 | tr -d '\n')" ;;
    ls)            out list_dir ;;
    upload)        upload ;;
    download)      download ;;
    fread)         file_read ;;
    fwrite)        file_write ;;
    ps)            out procs ;;
    kill)          out signal ;;
    auto-list)     out auto list ;;
    auto-save)     out auto save ;;
    auto-get)      out auto get ;;
    auto-toggle)   out auto toggle ;;
    auto-run)      out auto run ;;
    auto-stop)     out auto stop ;;
    auto-log)      out auto log ;;
    auto-delete)   out auto delete ;;
    cron-get)      out cron_get ;;
    cron-set)      out cron_set ;;
    sound-play)    out sound_play ;;
    sound-stop)    out sound_stop ;;
    sound-status)  out sound_status ;;
    led-get)       out led_state ;;
    led-set)       out led_set ;;
    say)           out alice_say ;;
    alice-restart) out alice_restart ;;
    log-list)      out log_files ;;
    log-tail)      out log_tail ;;
    net-info)      out net_info ;;
    net-ping)      out net_ping ;;
    net-sites)     out net_sites ;;
    backup)        out backup_make ;;
    restore)       out backup_restore ;;
    tz)            out tz_set ;;
    passwd)        passwd ;;
    reboot)        [ "$(body)" = yes ] || text '400 Bad Request' 'нужно подтверждение'
                   log reboot; sync; (sleep 2; reboot) </dev/null >/dev/null 2>&1 &
                   text '200 OK' 'перезагружаюсь, вернусь через минуту' ;;
    *)             text '404 Not Found' 'нет такого действия' ;;
esac
EOF_PANEL
cat > "$D/panel-mon.sh" <<'EOF_PANEL'
#!/bin/sh
# История для графиков панели: раз в минуту «время cpu% память% температура» в /tmp/panel/hist,
# хранятся последние 24 часа (1440 строк). Запускается из panel-boot.sh.
ST=/tmp/panel
H=$ST/hist
mkdir -p "$ST"
read -r _ a1 b1 c1 d1 e1 f1 g1 _ < /proc/stat
i=0
while :; do
    sleep 60
    read -r _ a2 b2 c2 d2 e2 f2 g2 _ < /proc/stat
    busy=$(( (a2 + b2 + c2 + f2 + g2) - (a1 + b1 + c1 + f1 + g1) ))
    total=$(( busy + (d2 + e2) - (d1 + e1) ))
    cpu=$(( total > 0 ? busy * 100 / total : 0 ))
    mem=$(free | awk '/^Mem:/ {printf "%d", ($2 - $7) * 100 / $2}')
    t=$(( $(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0) / 1000 ))
    echo "$(date +%s) $cpu $mem $t" >> "$H"
    a1=$a2; b1=$b2; c1=$c2; d1=$d2; e1=$e2; f1=$f2; g1=$g2
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then tail -n 1440 "$H" > "$H.new" && mv "$H.new" "$H"; i=0; fi
done
EOF_PANEL
cat > "$D/panel-boot.sh" <<'EOF_PANEL'
#!/bin/sh
# Запуск веб-панели: вызывается из /etc/init.d/S99zpanel при загрузке.
# Поднимает HTTPS на 8443, сбор истории для графиков, crond расписания и включённые скрипты
# своего автозапуска. Повторный запуск безопасен — запускается только то, чего ещё нет.
export PATH=/opt/bin:/opt/sbin:/usr/bin:/bin:/usr/sbin:/sbin
DIR=$(cd "$(dirname "$0")" && pwd)
PORT=8443
TZ=MSK-3
[ -f "$DIR/settings" ] && . "$DIR/settings"
export TZ
mkdir -p /tmp/panel "$DIR/autostart.d" "$DIR/cron"
touch "$DIR/cron/root"

ps -o args 2>/dev/null | grep -q "[O]PENSSL-LISTEN:$PORT" ||
    (setsid socat -T 120 \
        "OPENSSL-LISTEN:$PORT,reuseaddr,fork,max-children=10,cert=$DIR/cert.pem,key=$DIR/key.pem,verify=0" \
        "EXEC:$DIR/http.sh" </dev/null >/dev/null 2>&1 &)

ps -o args 2>/dev/null | grep -q '[p]anel-mon.sh' || (setsid sh "$DIR/panel-mon.sh" </dev/null >/dev/null 2>&1 &)

ps -o args 2>/dev/null | grep -q "[c]rond .*-c $DIR/cron" || crond -b -c "$DIR/cron" -L "$DIR/cron.log"

# свой автозапуск — один раз за загрузку, только включённые (исполняемые) скрипты
if [ ! -f /tmp/panel/autostart.done ]; then
    touch /tmp/panel/autostart.done
    for f in "$DIR"/autostart.d/*.sh; do
        [ -x "$f" ] || continue
        (cd "$DIR/autostart.d" && setsid sh "$f" >> "${f%.sh}.log" 2>&1 </dev/null &)
    done
fi

sleep 1
echo "$(date '+%m-%d %H:%M:%S') panel-boot: https=$(netstat -tln 2>/dev/null | grep -q ":$PORT " && echo up || echo DOWN)" \
    "mon=$(ps -o args | grep -q '[p]anel-mon.sh' && echo up || echo DOWN)" \
    "crond=$(ps -o args | grep -q "[c]rond .*-c $DIR/cron" && echo up || echo DOWN)"
EOF_PANEL
cat > "$D/www/index.html" <<'EOF_PANEL'
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Колонка</title>
<style>
  :root {
    --bg:#f2f3f5; --card:#fff; --line:#e7e8ec; --text:#1a1a1a; --dim:#7b7f87; --soft:#f4f5f7;
    --y:#ffdb4d; --yh:#ffd21f; --acc:#6c4bf5; --bad:#e5322d; --ok:#1db954; --shadow:0 2px 12px rgba(0,0,0,.06);
    --mono:ui-monospace, "SF Mono", Menlo, Consolas, monospace;
  }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#121214; --card:#1c1c1f; --line:#2c2c31; --text:#f2f2f3; --dim:#9a9ca3; --soft:#26262b; --shadow:0 2px 12px rgba(0,0,0,.4); }
  }
  * { box-sizing:border-box; }
  html, body { margin:0; background:var(--bg); color:var(--text); font:15px/1.45 -apple-system, "Segoe UI", Roboto, Arial, sans-serif; }
  .hidden { display:none !important; }
  button, input, textarea, select { font:inherit; color:inherit; }
  button { cursor:pointer; border:0; border-radius:12px; padding:10px 16px; background:var(--soft); transition:background .15s, transform .05s; }
  button:hover { background:var(--line); } button:active { transform:scale(.98); }
  button.y { background:var(--y); color:#1a1a1a; font-weight:600; } button.y:hover { background:var(--yh); }
  button.bad { color:var(--bad); } button.sm { padding:6px 10px; border-radius:10px; font-size:14px; }
  input[type=text], input[type=password], input[type=number], textarea, select {
    width:100%; background:var(--soft); border:1px solid transparent; border-radius:12px; padding:10px 12px; outline:none; }
  input:focus, textarea:focus, select:focus { border-color:var(--y); background:var(--card); }
  textarea { font:13px/1.5 var(--mono); resize:vertical; }
  pre { margin:0; white-space:pre-wrap; word-break:break-word; font:13px/1.5 var(--mono); }
  h1 { font-size:26px; margin:0 0 16px; font-weight:700; } h2 { font-size:17px; margin:0 0 12px; font-weight:600; }
  .dim { color:var(--dim); font-size:13px; }

  /* вход */
  .auth { max-width:380px; margin:12vh auto; padding:0 16px; }
  .auth .card { padding:28px; }
  .logo { width:48px; height:48px; border-radius:50%; background:conic-gradient(from 200deg, #8a5cff, #ff5ca8, #ffb84d, #8a5cff); margin-bottom:16px; }

  /* каркас */
  .layout { display:flex; min-height:100vh; }
  aside { width:240px; flex:none; padding:20px 12px; position:sticky; top:0; height:100vh; overflow-y:auto; }
  aside .brand { display:flex; align-items:center; gap:10px; padding:4px 10px 18px; font-weight:700; font-size:17px; }
  aside .brand .logo { width:28px; height:28px; margin:0; }
  nav button { display:flex; align-items:center; gap:10px; width:100%; text-align:left; background:none; padding:10px 12px; margin:2px 0; border-radius:12px; }
  nav button:hover { background:var(--card); }
  nav button.on { background:var(--card); box-shadow:var(--shadow); font-weight:600; }
  nav .ico { width:22px; text-align:center; }
  main { flex:1; min-width:0; padding:24px 28px 60px; max-width:1100px; }
  .top { display:flex; align-items:center; gap:12px; margin-bottom:18px; }
  .top .st { flex:1; color:var(--dim); font-size:14px; }
  .dot { display:inline-block; width:8px; height:8px; border-radius:50%; background:var(--ok); margin-right:6px; }
  section { display:none; } section.on { display:block; }
  .card { background:var(--card); border-radius:16px; box-shadow:var(--shadow); padding:18px; margin-bottom:14px; }
  .grid { display:grid; gap:14px; grid-template-columns:repeat(auto-fill, minmax(220px, 1fr)); }
  .tile .v { font-size:28px; font-weight:700; margin-top:4px; } .tile .l { color:var(--dim); font-size:13px; }
  .row { display:flex; flex-wrap:wrap; gap:8px; align-items:center; margin:10px 0; }
  .row > input[type=text], .row > select { flex:1; min-width:160px; width:auto; }
  .chart { width:100%; height:120px; display:block; }
  .chart path.l { fill:none; stroke-width:2; } .chart path.a { opacity:.12; }
  input[type=range] { flex:1; min-width:160px; accent-color:#1a1a1a; }
  @media (prefers-color-scheme: dark) { input[type=range] { accent-color:var(--y); } }
  .big { font-size:40px; font-weight:700; min-width:90px; }

  /* таблицы и списки */
  table { width:100%; border-collapse:collapse; font-size:14px; }
  th { text-align:left; color:var(--dim); font-weight:500; padding:8px 6px; border-bottom:1px solid var(--line); }
  td { padding:8px 6px; border-bottom:1px solid var(--line); vertical-align:middle; }
  td.num { text-align:right; white-space:nowrap; color:var(--dim); font-variant-numeric:tabular-nums; }
  td.name { word-break:break-all; } tr:hover td { background:var(--soft); }
  a.link { color:inherit; cursor:pointer; text-decoration:none; } a.link:hover { color:var(--acc); }
  .scroll { max-height:60vh; overflow:auto; }
  .out { background:var(--soft); border-radius:12px; padding:12px; max-height:60vh; overflow:auto; }
  .term { background:#111214; color:#e8e8e8; border-radius:14px; padding:14px; height:55vh; overflow:auto; }
  .term pre { color:#e8e8e8; }
  .pill { display:inline-block; padding:2px 8px; border-radius:999px; background:var(--soft); font-size:12px; color:var(--dim); }
  .pill.ok { background:rgba(29,185,84,.15); color:var(--ok); }

  /* переключатель */
  .sw { position:relative; width:44px; height:26px; flex:none; display:inline-block; }
  .sw input { opacity:0; width:0; height:0; }
  .sw span { position:absolute; inset:0; background:var(--line); border-radius:999px; transition:.2s; cursor:pointer; }
  .sw span:before { content:""; position:absolute; width:20px; height:20px; left:3px; top:3px; background:#fff; border-radius:50%; transition:.2s; box-shadow:0 1px 3px rgba(0,0,0,.2); }
  .sw input:checked + span { background:var(--y); } .sw input:checked + span:before { transform:translateX(18px); }

  /* подсветка */
  .zones { display:flex; gap:16px; flex-wrap:wrap; }
  .zone { text-align:center; } .zone .sw-c { width:72px; height:72px; border-radius:50%; border:4px solid var(--soft); margin:0 auto 8px; }
  .zone input[type=color] { width:72px; height:36px; border:0; background:none; cursor:pointer; }
  .presets button { width:38px; height:38px; border-radius:50%; padding:0; border:2px solid var(--line); }

  /* модальное окно и уведомления */
  .modal { position:fixed; inset:0; background:rgba(0,0,0,.45); display:flex; align-items:center; justify-content:center; padding:16px; z-index:10; }
  .modal .card { width:min(960px, 100%); max-height:92vh; display:flex; flex-direction:column; margin:0; }
  .modal textarea { flex:1; min-height:55vh; }
  #toast { position:fixed; left:50%; bottom:24px; transform:translateX(-50%); background:#1a1a1a; color:#fff; padding:12px 18px;
    border-radius:14px; box-shadow:0 8px 24px rgba(0,0,0,.25); font-size:14px; z-index:20; max-width:90vw; transition:opacity .2s; }

  @media (max-width: 820px) {
    .layout { display:block; }
    aside { width:auto; height:auto; position:sticky; top:0; z-index:5; background:var(--bg); padding:8px; }
    aside .brand { display:none; }
    nav { display:flex; overflow-x:auto; gap:4px; }
    nav button { width:auto; white-space:nowrap; margin:0; }
    main { padding:14px 12px 60px; }
  }
</style>
</head>
<body>

<div id="setup" class="auth hidden"><div class="card">
  <div class="logo"></div>
  <h1>Первый вход</h1>
  <p class="dim">Задайте пароль панели. Код установки напечатал установщик в консоли колонки,
    он же лежит в /data/opt/panel/setup-code.</p>
  <form id="setupForm">
    <div class="row"><input id="setupCode" type="text" placeholder="Код установки" autocomplete="off" spellcheck="false"></div>
    <div class="row"><input id="setupPw" type="password" placeholder="Новый пароль, от 8 символов" autocomplete="new-password"></div>
    <div class="row"><input id="setupPw2" type="password" placeholder="Пароль ещё раз" autocomplete="new-password"></div>
    <div class="row"><button type="submit" class="y">Задать пароль и войти</button></div>
    <div id="setupMsg" class="dim"></div>
  </form>
</div></div>

<div id="login" class="auth hidden"><div class="card">
  <div class="logo"></div>
  <h1>Колонка</h1>
  <form id="loginForm">
    <div class="row"><input id="pw" type="password" placeholder="Пароль" autocomplete="current-password"></div>
    <div class="row"><button type="submit" class="y">Войти</button></div>
    <div id="loginMsg" class="dim"></div>
  </form>
</div></div>

<div id="app" class="layout hidden">
  <aside>
    <div class="brand"><div class="logo"></div>Колонка</div>
    <nav id="tabs">
      <button data-tab="home"><span class="ico">🏠</span>Главная</button>
      <button data-tab="sound"><span class="ico">🔊</span>Звук и Алиса</button>
      <button data-tab="led"><span class="ico">💡</span>Подсветка</button>
      <button data-tab="console"><span class="ico">💻</span>Консоль</button>
      <button data-tab="files"><span class="ico">📁</span>Файлы</button>
      <button data-tab="procs"><span class="ico">⚙️</span>Процессы</button>
      <button data-tab="auto"><span class="ico">🚀</span>Автозапуск</button>
      <button data-tab="cron"><span class="ico">⏰</span>Расписание</button>
      <button data-tab="logs"><span class="ico">📜</span>Журналы</button>
      <button data-tab="net"><span class="ico">🌐</span>Сеть</button>
      <button data-tab="service"><span class="ico">🛠</span>Сервис</button>
    </nav>
  </aside>
  <main>
    <div class="top"><div class="st" id="status"><span class="dot"></span>на связи</div><button id="logout" class="sm">Выйти</button></div>

    <section id="home">
      <h1>Главная</h1>
      <div class="grid" id="tiles"></div>
      <div class="grid" style="margin-top:14px">
        <div class="card"><h2>CPU, %</h2><svg class="chart" id="chCpu" viewBox="0 0 300 120" preserveAspectRatio="none"></svg><div class="dim" id="chCpuL"></div></div>
        <div class="card"><h2>Память, %</h2><svg class="chart" id="chMem" viewBox="0 0 300 120" preserveAspectRatio="none"></svg><div class="dim" id="chMemL"></div></div>
        <div class="card"><h2>Температура, °C</h2><svg class="chart" id="chTemp" viewBox="0 0 300 120" preserveAspectRatio="none"></svg><div class="dim" id="chTempL"></div></div>
      </div>
      <div class="card"><h2>О колонке</h2><pre id="systemOut">…</pre></div>
    </section>

    <section id="sound">
      <h1>Звук и Алиса</h1>
      <div class="card"><h2>Громкость</h2>
        <div class="row"><span class="big" id="volVal">—</span><input id="volRange" type="range" min="0" max="100" step="5"></div>
        <div class="row">
          <button data-vol="-10">−10</button><button data-vol="+10">+10</button>
          <button data-vol="20">20 %</button><button data-vol="50">50 %</button><button data-vol="80">80 %</button>
          <button data-vol="mute">🔇 Без звука</button>
        </div></div>
      <div class="card"><h2>Алиса, скажи</h2>
        <form id="sayForm" class="row"><input id="sayText" type="text" placeholder="Текст, который произнесёт Алиса"><button class="y" type="submit">Сказать</button></form>
        <div class="row"><button id="aliceRestart">🔁 Перезапустить голос Алисы</button><span class="dim">если она зависла или молчит</span></div>
      </div>
      <div class="card"><h2>Проиграть звук</h2>
        <form id="playForm" class="row"><input id="playSrc" type="text" placeholder="Ссылка на поток или путь к файлу (mp3, wav, …)"><button class="y" type="submit">▶ Играть</button><button type="button" id="playStop">⏹ Стоп</button></form>
        <div class="row"><input id="playFile" type="file" accept="audio/*"><button id="playUpload">Загрузить в /tmp и играть</button></div>
        <pre id="soundOut" class="dim"></pre>
      </div>
    </section>

    <section id="led">
      <h1>Подсветка</h1>
      <div class="card">
        <div class="zones" id="zones"></div>
        <div class="row presets" id="presets"></div>
        <div class="row"><button class="y" id="ledAll">Всё кольцо — цвет зоны 1</button><button id="ledOff">Погасить</button></div>
        <div class="dim">Алиса сама управляет кольцом: когда она слушает или отвечает, ваш цвет сменится её анимацией.</div>
      </div>
    </section>

    <section id="console">
      <h1>Консоль</h1>
      <div class="card">
        <div class="dim">Папка: <b id="cwd">/data</b> · Enter — выполнить, Shift+Enter — новая строка, ↑/↓ — история; дольше 30 с — прерывается (запускайте с &amp;)</div>
        <div class="term" style="margin-top:10px" id="term"><pre id="consoleOut"></pre></div>
        <div class="row"><textarea id="cmd" rows="2" placeholder="команда" spellcheck="false"></textarea></div>
        <div class="row"><button class="y" id="cmdRun">Выполнить</button><button id="cmdClear">Очистить</button></div>
      </div>
    </section>

    <section id="files">
      <h1>Файлы</h1>
      <div class="card">
        <div class="row"><b id="filesCwd" style="flex:1;word-break:break-all">…</b>
          <button id="filesUp" class="sm">⬆ Вверх</button><button id="filesHome" class="sm">/data</button><button id="filesTmp" class="sm">/tmp</button><button id="filesRefresh" class="sm">↻</button></div>
        <div class="row"><input id="upFiles" type="file" multiple><button class="y" id="upBtn">Загрузить сюда</button><button id="newFile">Новый файл</button></div>
        <div class="scroll"><table><tbody id="filesList"></tbody></table></div>
      </div>
    </section>

    <section id="procs">
      <h1>Процессы</h1>
      <div class="card">
        <div class="row"><input id="procFilter" type="text" placeholder="Фильтр по имени"><button id="procRefresh">↻ Обновить</button></div>
        <div class="scroll"><table><thead><tr><th>PID</th><th>Процесс</th><th>VSZ</th><th>CPU</th><th></th></tr></thead><tbody id="procList"></tbody></table></div>
      </div>
    </section>

    <section id="auto">
      <h1>Автозапуск</h1>
      <div class="card">
        <div class="dim">Свои скрипты, которые запускаются при загрузке колонки (один раз). Включён — значит запустится.</div>
        <div class="row"><input id="autoName" type="text" placeholder="имя нового скрипта, например my-bot"><button class="y" id="autoNew">Создать</button></div>
        <table><tbody id="autoList"></tbody></table>
        <pre id="autoOut" class="out hidden" style="margin-top:12px"></pre>
      </div>
    </section>

    <section id="cron">
      <h1>Расписание</h1>
      <div class="card">
        <div class="dim" id="cronTime"></div>
        <div class="row" id="cronPresets"></div>
        <textarea id="cronText" rows="12" spellcheck="false"></textarea>
        <div class="row"><button class="y" id="cronSave">Сохранить</button><button id="cronReload">↻</button></div>
        <div class="dim">Строка: <code>минута час день месяц день_недели команда</code>. «*» — любое значение, «*/15» — каждые 15. Пример: <code>0 4 * * * reboot</code> — перезагрузка в 4:00.</div>
      </div>
    </section>

    <section id="logs">
      <h1>Журналы</h1>
      <div class="card">
        <div class="row"><select id="logFile"></select><input id="logLines" type="number" value="200" min="10" max="2000" style="width:100px;flex:none"><input id="logFilter" type="text" placeholder="фильтр"></div>
        <div class="row"><button class="y" id="logShow">Показать</button><label class="row" style="margin:0"><span class="sw"><input type="checkbox" id="logAuto"><span></span></span>&nbsp;обновлять каждые 3 с</label></div>
        <div class="out"><pre id="logOut"></pre></div>
      </div>
    </section>

    <section id="net">
      <h1>Сеть</h1>
      <div class="card"><h2>Подключение</h2><pre id="netOut">…</pre></div>
      <div class="card"><h2>Проверка</h2>
        <form id="pingForm" class="row"><input id="pingHost" type="text" placeholder="адрес для ping, например ya.ru"><button class="y" type="submit">Ping</button><button type="button" id="sitesBtn">Доступность сайтов</button></form>
        <pre id="pingOut" class="out"></pre>
      </div>
    </section>

    <section id="service">
      <h1>Сервис</h1>
      <div class="card"><h2>Бэкап</h2>
        <div class="dim">Всё в /data/opt, кроме пакетов Entware: настройки, скрипты, панель.</div>
        <div class="row"><button class="y" id="backupBtn">Скачать бэкап</button></div>
        <div class="row"><input id="restoreFile" type="file" accept=".gz"><button id="restoreBtn" class="bad">Восстановить из архива</button></div>
        <div id="backupMsg" class="dim"></div>
      </div>
      <div class="card"><h2>Часовой пояс</h2>
        <div class="row"><input id="tzVal" type="text" placeholder="MSK-3"><button id="tzBtn">Сохранить</button></div>
        <div class="dim">Формат POSIX: MSK-3 — Москва (UTC+3), EET-2 — UTC+2, UTC0. Нужен для журналов и расписания.</div>
      </div>
      <div class="card"><h2>Пароль</h2>
        <form id="pwForm">
          <div class="row"><input id="pwOld" type="password" placeholder="Текущий пароль" autocomplete="current-password"></div>
          <div class="row"><input id="pwNew" type="password" placeholder="Новый пароль, от 8 символов" autocomplete="new-password"></div>
          <div class="row"><button type="submit">Сменить</button></div>
          <div id="pwMsg" class="dim"></div>
        </form></div>
      <div class="card"><h2>Журнал панели</h2><div class="row"><button id="panelLog">Показать</button></div><pre id="panelLogOut" class="out hidden"></pre></div>
      <div class="card"><button id="rebootBtn" class="bad">🔄 Перезагрузить колонку</button></div>
    </section>
  </main>
</div>

<div id="editor" class="modal hidden"><div class="card">
  <div class="row" style="margin-top:0"><b id="edPath" style="flex:1;word-break:break-all"></b><button class="y" id="edSave">Сохранить</button><button id="edClose">Закрыть</button></div>
  <textarea id="edText" spellcheck="false"></textarea>
  <div class="dim" id="edMsg" style="margin-top:8px">Ctrl+S — сохранить</div>
</div></div>

<div id="toast" class="hidden"></div>
<script src="/app.js"></script>
</body>
</html>
EOF_PANEL
cat > "$D/www/app.js" <<'EOF_PANEL'
'use strict';
// Веб-панель колонки. Все запросы — POST /api/<действие> с заголовком X-Panel (без него сервер
// отвечает 403: так API не вызвать с чужого сайта). Данные с колонки — только через textContent.

const $ = (id) => document.getElementById(id);
const timers = {};
const hist = [];
let histPos = 0;

// ---- общее ----
async function api(name, body, extra = {}) {
  const r = await fetch('/api/' + name, {
    method: 'POST', credentials: 'same-origin',
    headers: Object.assign({ 'X-Panel': '1' }, extra.headers || {}),
    body: body === undefined ? '' : body,
  });
  if (r.status === 409 && name !== 'setup') { showOnly('setup'); throw new Error('нужна первая настройка'); }
  if (r.status === 401 && name !== 'login' && name !== 'setup') { showOnly('login'); throw new Error('нужен вход'); }
  return r;
}
const apiText = async (name, body) => (await api(name, body)).text();

function el(tag, props = {}, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (k === 'on') for (const [ev, fn] of Object.entries(v)) e.addEventListener(ev, fn);
    else if (k === 'text') e.textContent = v;
    else if (k in e && k !== 'style') e[k] = v;
    else e.setAttribute(k, v);
  }
  for (const c of kids) if (c != null) e.append(c);
  return e;
}
function toast(msg) {
  const t = $('toast'); t.textContent = msg; t.classList.remove('hidden');
  clearTimeout(timers.toast); timers.toast = setTimeout(() => t.classList.add('hidden'), 3500);
}
function b64(s) { return btoa(String.fromCharCode(...new TextEncoder().encode(s))); }
function unb64(s) { try { return new TextDecoder().decode(Uint8Array.from(atob(s), (c) => c.charCodeAt(0))); } catch (e) { return ''; } }
const shq = (s) => "'" + s.replace(/'/g, "'\\''") + "'";
function stopTimers() { for (const k of ['res', 'log']) { clearInterval(timers[k]); timers[k] = null; } }

function showOnly(id) {
  ['login', 'setup', 'app'].forEach((x) => $(x).classList.toggle('hidden', x !== id));
  if (id !== 'app') stopTimers();
  if (id === 'login') $('pw').focus();
  if (id === 'setup') $('setupCode').focus();
  if (id === 'app') openTab(location.hash.slice(1) || 'home');
}

// ---- вход ----
$('loginForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  const r = await api('login', $('pw').value);
  $('pw').value = '';
  if (r.ok) { $('loginMsg').textContent = ''; showOnly('app'); } else { $('loginMsg').textContent = await r.text(); }
});
$('setupForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  if ($('setupPw').value !== $('setupPw2').value) { $('setupMsg').textContent = 'пароли не совпадают'; return; }
  const r = await api('setup', $('setupCode').value.trim() + '\n' + $('setupPw').value);
  if (r.ok) { $('setupPw').value = ''; $('setupPw2').value = ''; showOnly('app'); } else { $('setupMsg').textContent = await r.text(); }
});
$('logout').addEventListener('click', async () => { await api('logout'); showOnly('login'); });

// ---- вкладки ----
const loaders = {
  home: loadHome, sound: loadSound, led: loadLed, console: loadCwd, files: loadFiles, procs: loadProcs,
  auto: loadAuto, cron: loadCron, logs: loadLogList, net: loadNet, service: () => {},
};
function openTab(t) {
  if (!loaders[t]) t = 'home';
  history.replaceState(null, '', '#' + t);
  document.querySelectorAll('#tabs button').forEach((b) => b.classList.toggle('on', b.dataset.tab === t));
  document.querySelectorAll('main section').forEach((s) => s.classList.toggle('on', s.id === t));
  stopTimers();
  loaders[t]();
  if (t === 'home') timers.res = setInterval(loadHome, 10000);
  if (t === 'console') $('cmd').focus();
}
$('tabs').addEventListener('click', (e) => { const b = e.target.closest('button'); if (b) openTab(b.dataset.tab); });

// ---- главная ----
function parseKV(txt) {
  const m = {};
  for (const l of txt.split('\n')) { const i = l.indexOf(':'); if (i > 0) m[l.slice(0, i).trim()] = l.slice(i + 1).trim(); }
  return m;
}
function tile(label, value, sub) {
  return el('div', { className: 'card tile' }, el('div', { className: 'l', text: label }), el('div', { className: 'v', text: value }),
    sub ? el('div', { className: 'dim', text: sub }) : null);
}
function chart(svg, label, pts, color, unit) {
  svg.textContent = '';
  if (pts.length < 2) { label.textContent = 'данные копятся: точка раз в минуту'; return; }
  const max = Math.max(...pts.map((p) => p[1]), unit === '°C' ? 60 : 100);
  const min = 0;
  const t0 = pts[0][0], t1 = pts[pts.length - 1][0] || t0 + 1;
  const xy = pts.map(([t, v]) => [((t - t0) / (t1 - t0 || 1)) * 300, 115 - ((v - min) / (max - min || 1)) * 108]);
  const d = 'M' + xy.map((p) => p[0].toFixed(1) + ' ' + p[1].toFixed(1)).join(' L');
  const ns = 'http://www.w3.org/2000/svg';
  const area = document.createElementNS(ns, 'path'); area.setAttribute('d', d + ` L300 120 L0 120 Z`); area.setAttribute('class', 'a'); area.setAttribute('fill', color);
  const line = document.createElementNS(ns, 'path'); line.setAttribute('d', d); line.setAttribute('class', 'l'); line.setAttribute('stroke', color);
  svg.append(area, line);
  const vals = pts.map((p) => p[1]);
  const hrs = ((t1 - t0) / 3600).toFixed(1);
  label.textContent = `сейчас ${vals[vals.length - 1]} ${unit} · макс. ${Math.max(...vals)} · за ${hrs} ч`;
}
async function loadHome() {
  const [sys, res, h] = await Promise.all([apiText('system'), apiText('resources'), apiText('hist')]);
  const s = parseKV(sys), r = parseKV(res);
  $('systemOut').textContent = sys;
  const tiles = $('tiles'); tiles.textContent = '';
  const cpu = (r['CPU'] || '').split(',')[0];
  const mem = /(\d+) из (\d+) МБ/.exec(r['Память'] || '');
  tiles.append(
    tile('CPU', cpu || '—', 'нагрузка ' + ((r['CPU'] || '').split('нагрузка ')[1] || '')),
    tile('Память', mem ? Math.round(mem[1] / mem[2] * 100) + ' %' : '—', mem ? `${mem[1]} из ${mem[2]} МБ` : ''),
    tile('Температура', s['Температура'] || '—', ''),
    tile('Громкость', s['Громкость'] || '—', ''),
    tile('Работает', s['Работает'] || '—', s['Время'] || ''),
    tile('Wi-Fi', s['Wi-Fi'] || '—', (s['IP / MAC'] || '').split(' / ')[0]),
  );
  const rows = h.trim().split('\n').filter(Boolean).map((l) => l.split(' ').map(Number));
  chart($('chCpu'), $('chCpuL'), rows.map((x) => [x[0], x[1]]), '#ffb800', '%');
  chart($('chMem'), $('chMemL'), rows.map((x) => [x[0], x[2]]), '#6c4bf5', '%');
  chart($('chTemp'), $('chTempL'), rows.map((x) => [x[0], x[3]]), '#e5322d', '°C');
}

// ---- звук и Алиса ----
function showVol(t) { const m = /(\d+)%/.exec(t); if (m) { $('volVal').textContent = m[1] + ' %'; $('volRange').value = m[1]; } }
async function loadSound() { showVol(parseKV(await apiText('system'))['Громкость'] || ''); $('soundOut').textContent = await apiText('sound-status'); }
async function setVol(v) { showVol(await apiText('volume', String(v))); }
document.querySelectorAll('[data-vol]').forEach((b) => b.addEventListener('click', () => setVol(b.dataset.vol)));
$('volRange').addEventListener('change', (e) => setVol(e.target.value));
$('sayForm').addEventListener('submit', async (e) => {
  e.preventDefault(); const t = $('sayText').value.trim(); if (!t) return;
  toast(await apiText('say', t)); $('sayText').value = '';
});
$('aliceRestart').addEventListener('click', async () => {
  if (confirm('Перезапустить медиа-демон Алисы? Она замолчит секунд на 10–15.')) toast(await apiText('alice-restart'));
});
$('playForm').addEventListener('submit', async (e) => {
  e.preventDefault(); const s = $('playSrc').value.trim(); if (!s) return;
  $('soundOut').textContent = await apiText('sound-play', s);
});
$('playStop').addEventListener('click', async () => { $('soundOut').textContent = await apiText('sound-stop'); });
$('playUpload').addEventListener('click', async () => {
  const f = $('playFile').files[0]; if (!f) return;
  const prev = $('cwd').textContent;
  await api('cmd', 'cd /tmp');
  const r = await api('upload', f, { headers: { 'X-File-Name': b64(f.name) } });
  toast(await r.text());
  await api('cmd', 'cd ' + shq(prev || '/data'));
  $('soundOut').textContent = await apiText('sound-play', '/tmp/' + f.name);
});

// ---- подсветка ----
const hex = (r, g, b) => '#' + [r, g, b].map((x) => Number(x).toString(16).padStart(2, '0')).join('');
const rgb = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
async function setLed(zone, color) {
  const t = await apiText('led-set', zone + ' ' + rgb(color).join(' '));
  drawLed(t);
}
function drawLed(t) {
  const z = $('zones'); z.textContent = '';
  if (!/^\d/.test(t)) { z.append(el('div', { className: 'dim', text: t })); return; }
  for (const l of t.trim().split('\n')) {
    const [n, r, g, b] = l.split(' ');
    const c = hex(r, g, b);
    const sw = el('div', { className: 'sw-c' }); sw.style.background = c;
    const inp = el('input', { type: 'color', value: c, on: { change: (e) => setLed(n, e.target.value) } });
    z.append(el('div', { className: 'zone' }, sw, inp, el('div', { className: 'dim', text: 'Зона ' + n })));
  }
}
async function loadLed() { drawLed(await apiText('led-get')); }
const presetColors = ['#ffffff', '#ff0000', '#ff8800', '#ffdb00', '#00ff44', '#00d5ff', '#0044ff', '#8a2bff', '#ff2bd6'];
for (const c of presetColors) {
  const b = el('button', { title: c, on: { click: () => setLed('all', c) } }); b.style.background = c;
  $('presets').append(b);
}
$('ledAll').addEventListener('click', () => { const c = document.querySelector('#zones input[type=color]'); if (c) setLed('all', c.value); });
$('ledOff').addEventListener('click', async () => drawLed(await apiText('led-set', 'off')));

// ---- консоль ----
function print(t) { $('consoleOut').textContent += t; $('term').scrollTop = $('term').scrollHeight; }
async function runCmd(c) {
  hist.push(c); histPos = hist.length;
  print('\n' + $('cwd').textContent + ' $ ' + c + '\n');
  const r = await api('cmd', c);
  const cwd = unb64(r.headers.get('X-Cwd') || ''); if (cwd) $('cwd').textContent = cwd;
  print(await r.text());
}
async function loadCwd() { $('cwd').textContent = (await apiText('cmd', 'pwd')).trim() || '/data'; }
$('cmd').addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); const c = $('cmd').value.trim(); $('cmd').value = ''; if (c) runCmd(c); }
  if (e.key === 'ArrowUp' && histPos > 0 && !$('cmd').value.includes('\n')) { histPos--; $('cmd').value = hist[histPos]; e.preventDefault(); }
  if (e.key === 'ArrowDown' && histPos < hist.length) { histPos++; $('cmd').value = hist[histPos] || ''; e.preventDefault(); }
});
$('cmdRun').addEventListener('click', () => { const c = $('cmd').value.trim(); $('cmd').value = ''; if (c) runCmd(c); });
$('cmdClear').addEventListener('click', () => { $('consoleOut').textContent = ''; });

// ---- файлы и редактор ----
function fmtSize(n) { n = Number(n); if (n < 1024) return n + ' Б'; if (n < 1048576) return (n / 1024).toFixed(1) + ' КБ'; return (n / 1048576).toFixed(1) + ' МБ'; }
async function loadFiles() {
  const lines = (await apiText('ls')).split('\n');
  $('filesCwd').textContent = lines[0]; $('cwd').textContent = lines[0];
  const rows = lines.slice(1).filter((l) => /^[df]\|/.test(l)).map((l) => {
    const i = l.indexOf('|', 2); return { dir: l[0] === 'd', size: l.slice(2, i), name: l.slice(i + 1) };
  }).sort((a, b) => (b.dir - a.dir) || a.name.localeCompare(b.name));
  const tb = $('filesList'); tb.textContent = '';
  for (const f of rows) {
    const open = () => (f.dir ? cd(f.name) : openEditor(f.name));
    tb.append(el('tr', {},
      el('td', { className: 'name' }, el('a', { className: 'link', text: (f.dir ? '📁 ' : '📄 ') + f.name, on: { click: open } })),
      el('td', { className: 'num', text: f.dir ? '' : fmtSize(f.size) }),
      el('td', { className: 'num' }, f.dir ? null : el('button', { className: 'sm', title: 'Изменить', text: '✏️', on: { click: () => openEditor(f.name) } }), ' ',
        f.dir ? null : el('button', { className: 'sm', title: 'Скачать', text: '⬇', on: { click: () => download(f.name) } }), ' ',
        el('button', { className: 'sm bad', title: 'Удалить', text: '✕', on: { click: () => remove(f.name, f.dir) } }))));
  }
}
async function cd(d) { await api('cmd', 'cd ' + shq(d)); loadFiles(); }
async function remove(name, dir) {
  if (!confirm('Удалить ' + name + (dir ? ' вместе со всем содержимым' : '') + '?')) return;
  toast((await apiText('cmd', 'rm -' + (dir ? 'r' : '') + 'f -- ' + shq(name))) || 'удалено'); loadFiles();
}
$('filesUp').addEventListener('click', () => cd('..'));
$('filesHome').addEventListener('click', () => cd('/data'));
$('filesTmp').addEventListener('click', () => cd('/tmp'));
$('filesRefresh').addEventListener('click', loadFiles);
async function download(name) {
  const r = await api('download', name);
  if (!r.ok) { toast(await r.text()); return; }
  const url = URL.createObjectURL(await r.blob());
  el('a', { href: url, download: name.split('/').pop() }).click();
  setTimeout(() => URL.revokeObjectURL(url), 10000);
}
$('upBtn').addEventListener('click', async () => {
  for (const f of $('upFiles').files) {
    toast('загружаю ' + f.name + '…');
    toast(await (await api('upload', f, { headers: { 'X-File-Name': b64(f.name) } })).text());
  }
  $('upFiles').value = ''; loadFiles();
});
$('newFile').addEventListener('click', () => { const n = prompt('Имя нового файла'); if (n) openEditor(n, true); });

let edSaver = null;
async function openEditor(name, isNew = false) {
  let path = name, text = '';
  if (!isNew) {
    const r = await api('fread', name);
    if (!r.ok) { toast(await r.text()); return; }
    path = unb64(r.headers.get('X-File-Path') || '') || name; text = await r.text();
  } else path = $('filesCwd').textContent.replace(/\/$/, '') + '/' + name;
  edSaver = async (content) => (await api('fwrite', content, { headers: { 'X-File-Path': b64(path) } })).text();
  showEditor(path, text);
}
function showEditor(title, text) {
  $('edPath').textContent = title; $('edText').value = text; $('edMsg').textContent = 'Ctrl+S — сохранить';
  $('editor').classList.remove('hidden'); $('edText').focus();
}
async function edSave() { $('edMsg').textContent = await edSaver($('edText').value); if ($('files').classList.contains('on')) loadFiles(); if ($('auto').classList.contains('on')) loadAuto(); }
$('edSave').addEventListener('click', edSave);
$('edClose').addEventListener('click', () => $('editor').classList.add('hidden'));
$('edText').addEventListener('keydown', (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key === 's') { e.preventDefault(); edSave(); }
  if (e.key === 'Tab') { e.preventDefault(); const t = e.target, p = t.selectionStart; t.setRangeText('  ', p, t.selectionEnd, 'end'); }
});

// ---- процессы ----
let procRows = [];
async function loadProcs() {
  procRows = (await apiText('ps')).trim().split('\n').filter(Boolean).map((l) => l.split('|'));
  drawProcs();
}
function drawProcs() {
  const q = $('procFilter').value.toLowerCase();
  const tb = $('procList'); tb.textContent = '';
  for (const [pid, , , st, vsz, cpu, ...cmd] of procRows) {
    const c = cmd.join('|');
    if (q && !c.toLowerCase().includes(q) && pid !== q) continue;
    const sig = async (s) => { if (s === 'TERM' || confirm(`Отправить SIG${s} процессу ${pid}?`)) { toast(await apiText('kill', pid + ' ' + s)); setTimeout(loadProcs, 800); } };
    tb.append(el('tr', {},
      el('td', { className: 'num', text: pid }),
      el('td', { className: 'name', text: c + (st.startsWith('T') ? '  (остановлен)' : '') }),
      el('td', { className: 'num', text: vsz }), el('td', { className: 'num', text: cpu }),
      el('td', { className: 'num' },
        el('button', { className: 'sm', title: 'Завершить (TERM)', text: '⏹', on: { click: () => sig('TERM') } }), ' ',
        el('button', { className: 'sm bad', title: 'Убить (KILL)', text: '✕', on: { click: () => sig('KILL') } }))));
  }
}
$('procFilter').addEventListener('input', drawProcs);
$('procRefresh').addEventListener('click', loadProcs);

// ---- автозапуск ----
async function loadAuto() {
  const rows = (await apiText('auto-list')).trim().split('\n').filter(Boolean).map((l) => l.split('|'));
  const tb = $('autoList'); tb.textContent = '';
  if (!rows.length) tb.append(el('tr', {}, el('td', { className: 'dim', text: 'Скриптов пока нет — создайте первый.' })));
  for (const [name, on, run] of rows) {
    const act = async (a) => { const t = await apiText('auto-' + a, name); if (a === 'log') { $('autoOut').textContent = t; $('autoOut').classList.remove('hidden'); } else toast(t); loadAuto(); };
    const swi = el('input', { type: 'checkbox', checked: on === '1', on: { change: () => act('toggle') } });
    tb.append(el('tr', {},
      el('td', {}, el('label', { className: 'sw' }, swi, el('span'))),
      el('td', { className: 'name' }, el('b', { text: name }), ' ', el('span', { className: 'pill' + (run === '1' ? ' ok' : ''), text: run === '1' ? 'работает' : 'не запущен' })),
      el('td', { className: 'num' },
        el('button', { className: 'sm', text: '✏️', title: 'Изменить', on: { click: () => editAuto(name) } }), ' ',
        el('button', { className: 'sm', text: run === '1' ? '⏹' : '▶', title: run === '1' ? 'Остановить' : 'Запустить', on: { click: () => act(run === '1' ? 'stop' : 'run') } }), ' ',
        el('button', { className: 'sm', text: '📜', title: 'Журнал', on: { click: () => act('log') } }), ' ',
        el('button', { className: 'sm bad', text: '✕', title: 'Удалить', on: { click: () => confirm('Удалить ' + name + '?') && act('delete') } }))));
  }
}
async function editAuto(name, isNew) {
  const text = isNew ? '#!/bin/sh\n# ' + name + ' — запускается при загрузке колонки\n\n' : await apiText('auto-get', name);
  edSaver = async (content) => (await api('auto-save', content, { headers: { 'X-File-Name': b64(name) } })).text();
  showEditor('Автозапуск: ' + name, text);
}
$('autoNew').addEventListener('click', () => {
  const n = $('autoName').value.trim().replace(/\.sh$/, '');
  if (!/^[A-Za-z0-9_.-]+$/.test(n)) { toast('имя — латиница, цифры, _ . -'); return; }
  $('autoName').value = ''; editAuto(n, true);
});

// ---- расписание ----
const cronPresets = [
  ['Перезагрузка в 4:00', '0 4 * * * reboot'],
  ['Тише в 23:00', '0 23 * * * amixer -q set Master 20%'],
  ['Громче в 8:00', '0 8 * * * amixer -q set Master 50%'],
  ['Каждые 15 минут', '*/15 * * * * echo "$(date)" >> /tmp/tick.log'],
];
for (const [t, line] of cronPresets) {
  $('cronPresets').append(el('button', { className: 'sm', text: '+ ' + t, on: { click: () => { const a = $('cronText'); a.value = a.value.replace(/\s*$/, '\n') + line + '\n'; } } }));
}
async function loadCron() {
  const t = await apiText('cron-get'); const i = t.indexOf('\n---\n');
  $('cronTime').textContent = t.slice(0, i); $('cronText').value = t.slice(i + 5);
}
$('cronSave').addEventListener('click', async () => { toast(await apiText('cron-set', $('cronText').value)); loadCron(); });
$('cronReload').addEventListener('click', loadCron);

// ---- журналы ----
async function loadLogList() {
  const rows = (await apiText('log-list')).trim().split('\n').filter(Boolean).map((l) => l.split('|'));
  const s = $('logFile'), cur = s.value; s.textContent = '';
  for (const [p, size] of rows) s.append(el('option', { value: p, text: p.replace('/data/quasar/daemons_logs/', 'quasar: ') + '  (' + fmtSize(size) + ')' }));
  if (cur) s.value = cur;
  if ($('logAuto').checked) timers.log = setInterval(showLog, 3000);
}
async function showLog() {
  const t = await apiText('log-tail', $('logFile').value + '\n' + $('logLines').value + '\n' + $('logFilter').value);
  const o = $('logOut'); const atEnd = o.parentNode.scrollTop + o.parentNode.clientHeight >= o.parentNode.scrollHeight - 30;
  o.textContent = t; if (atEnd) o.parentNode.scrollTop = o.parentNode.scrollHeight;
}
$('logShow').addEventListener('click', showLog);
$('logAuto').addEventListener('change', (e) => { clearInterval(timers.log); timers.log = e.target.checked ? setInterval(showLog, 3000) : null; if (e.target.checked) showLog(); });

// ---- сеть ----
async function loadNet() { $('netOut').textContent = await apiText('net-info'); }
$('pingForm').addEventListener('submit', async (e) => {
  e.preventDefault(); const h = $('pingHost').value.trim(); if (!h) return;
  $('pingOut').textContent = 'ping ' + h + '…'; $('pingOut').textContent = await apiText('net-ping', h);
});
$('sitesBtn').addEventListener('click', async () => { $('pingOut').textContent = 'проверяю…'; $('pingOut').textContent = await apiText('net-sites'); });

// ---- сервис ----
$('backupBtn').addEventListener('click', async () => {
  $('backupMsg').textContent = 'собираю архив…';
  const [p, size] = (await apiText('backup')).trim().split('|');
  $('backupMsg').textContent = 'архив ' + fmtSize(size) + ', скачиваю…';
  await download(p); $('backupMsg').textContent = 'готово: ' + p.split('/').pop();
});
$('restoreBtn').addEventListener('click', async () => {
  const f = $('restoreFile').files[0]; if (!f) { toast('выберите архив'); return; }
  if (!confirm('Восстановить /data/opt из ' + f.name + '? Текущие файлы с теми же именами будут заменены.')) return;
  await api('cmd', 'cd /tmp');
  toast(await (await api('upload', f, { headers: { 'X-File-Name': b64('restore.tar.gz') } })).text());
  $('backupMsg').textContent = await apiText('restore', '/tmp/restore.tar.gz');
  await api('cmd', 'rm -f /tmp/restore.tar.gz');
});
$('tzBtn').addEventListener('click', async () => toast(await apiText('tz', $('tzVal').value.trim())));
$('pwForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  const r = await api('passwd', $('pwOld').value + '\n' + $('pwNew').value);
  $('pwMsg').textContent = await r.text(); if (r.ok) { $('pwOld').value = ''; $('pwNew').value = ''; }
});
$('panelLog').addEventListener('click', async () => {
  const o = $('panelLogOut'); o.classList.remove('hidden');
  o.textContent = await apiText('log-tail', '/data/opt/panel/panel.log\n100\n');
});
$('rebootBtn').addEventListener('click', async () => { if (confirm('Перезагрузить колонку?')) toast(await apiText('reboot', 'yes')); });

// ---- старт ----
api('me').then((r) => (r.ok ? showOnly('app') : showOnly('login'))).catch(() => {});
EOF_PANEL
chmod 755 "$D/http.sh" "$D/panel-boot.sh" "$D/panel-mon.sh"

# пароль задают при первом входе в браузере; до этого нужен одноразовый код установки
CODE=
if ! grep -q '^HASH=[0-9a-f]' "$D/config" 2>/dev/null; then
    printf 'SALT=\nHASH=\n' > "$D/config"
    CODE=$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')
    echo "$CODE" > "$D/setup-code"
    chmod 600 "$D/setup-code"
    rm -rf /tmp/panel/sess /tmp/panel/fails
fi
chmod 600 "$D/config"

# самоподписанный сертификат на 10 лет (браузер один раз предупредит)
if [ ! -s "$D/cert.pem" ]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
        -subj /CN=station-panel -keyout "$D/key.pem" -out "$D/cert.pem" 2>/dev/null ||
        { echo "❌ Не создался сертификат"; exit 1; }
fi
chmod 600 "$D/key.pem"

# автозапуск — /etc/init.d/S99zpanel; корень на время записи монтируется на запись
mount -o remount,rw / || { echo "❌ Не удалось смонтировать корень на запись"; exit 1; }
cat > /etc/init.d/S99zpanel <<'EOF_INIT'
#!/bin/sh
# Автозапуск веб-панели из /data/opt/panel. Убрать автозапуск — удалить этот файл.
[ "${1:-start}" = start ] || exit 0
(
    # ждём Entware и адрес в Wi-Fi, не дольше двух минут
    i=0
    while [ "$i" -lt 60 ]; do
        [ -x /opt/bin/socat ] && ip -4 addr show wlan0 2>/dev/null | grep -q inet && break
        i=$((i + 1)); sleep 2
    done
    sh /data/opt/panel/panel-boot.sh >> /data/opt/panel/boot.log 2>&1
) </dev/null >/dev/null 2>&1 &
EOF_INIT
chmod 755 /etc/init.d/S99zpanel
sync
mount -o remount,ro /

# прежние версии запускались из ap-start.sh рецепта AirPlay — эту строку убираем
A=/data/opt/media/bin/ap-start.sh
[ -f "$A" ] && grep -q panel-boot.sh "$A" && sed -i '/panel-boot.sh/d' "$A"

for p in $(ps -o pid,args | awk '/[O]PENSSL-LISTEN:8443/ {print $1}'); do kill "$p"; done
sleep 1
sh "$D/panel-boot.sh"
IP=$(ip -4 addr show wlan0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
echo
echo "✅ Панель установлена: https://${IP:-<IP колонки>}:8443"
echo "   Браузер предупредит о самоподписанном сертификате — это нормально, примите его один раз."
if [ -n "$CODE" ]; then
    echo
    echo "   Код установки для первого входа:  $CODE"
    echo "   Введите его в браузере и задайте пароль."
else
    echo "   Пароль сохранён прежний."
fi
)
