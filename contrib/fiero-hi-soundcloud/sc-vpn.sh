#!/bin/sh
# Проверено: Fiero Hi (Станция Лайт, blackthorn), прошивка 0.369.1.50.*. Откат — README.md рядом.
# VLESS-прокси для SoundCloud: провайдер режет колонке CDN SoundCloud, поэтому curl и ffmpeg
# из sc-play.sh ходят через xray. Остальной трафик колонки (Алиса и прочее) идёт напрямую.
#   sc-vpn.sh set 'vless://...'   записать или заменить ссылку и перезапустить
#   sc-vpn.sh start | stop | restart | status
#   sc-vpn.sh test                скорость скачивания через прокси
# На /data мало места, поэтому xray лежит сжатым (xray.gz) и распаковывается в /tmp (RAM).
export PATH=/opt/bin:/opt/sbin:/usr/bin:/bin:/usr/sbin:/sbin
DIR=$(cd "$(dirname "$0")" && pwd)
URL_FILE=$DIR/vless.url
CONF=$DIR/xray.json
BIN=/tmp/xray
PID=/tmp/xray.pid
LOG=/tmp/xray.log
PORT=10809                       # HTTP-прокси для curl и ffmpeg, только 127.0.0.1

# Значение параметра из query-строки ссылки, %XX раскодируем
param() {
    v=$(echo "$QUERY" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1)
    printf '%b' "$(echo "$v" | sed 's/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')"
}

# vless://uuid@host:port?type=tcp&security=reality&...#имя -> xray.json
make_conf() {
    link=${1#vless://}
    [ "$link" != "$1" ] || { echo "это не vless:// ссылка"; return 1; }
    link=${link%%#*}
    QUERY=; case "$link" in *\?*) QUERY=${link#*\?} ;; esac
    main=${link%%\?*}; main=${main%/}
    uuid=${main%%@*}; hp=${main#*@}
    case "$hp" in
        \[*) host=${hp%%]*}; host=${host#[}; port=${hp##*]:} ;;   # IPv6 в скобках
        *) host=${hp%:*}; port=${hp##*:} ;;
    esac
    [ -n "$uuid" ] && [ -n "$host" ] && [ "$port" -gt 0 ] 2>/dev/null || { echo "не разобрал uuid/host/port"; return 1; }
    jq -n --arg uuid "$uuid" --arg host "$host" --argjson port "$port" --argjson lport "$PORT" \
        --arg type "$(param type)" --arg security "$(param security)" --arg flow "$(param flow)" \
        --arg sni "$(param sni)" --arg fp "$(param fp)" --arg pbk "$(param pbk)" --arg sid "$(param sid)" \
        --arg spx "$(param spx)" --arg alpn "$(param alpn)" --arg path "$(param path)" \
        --arg hhost "$(param host)" --arg svc "$(param serviceName)" '
        ($type | if . == "" then "tcp" else . end) as $net
        | {
            log: { loglevel: "warning" },
            inbounds: [{ listen: "127.0.0.1", port: $lport, protocol: "http" }],
            outbounds: [{
                protocol: "vless",
                settings: { vnext: [{ address: $host, port: $port,
                    users: [{ id: $uuid, encryption: "none" } + (if $flow != "" then { flow: $flow } else {} end)] }] },
                streamSettings: ({ network: $net, security: (if $security == "" then "none" else $security end) }
                    + (if $security == "reality" then { realitySettings: {
                            serverName: $sni, fingerprint: (if $fp == "" then "chrome" else $fp end),
                            publicKey: $pbk, shortId: $sid, spiderX: $spx } }
                       elif $security == "tls" then { tlsSettings: ({ serverName: $sni }
                            + (if $fp != "" then { fingerprint: $fp } else {} end)
                            + (if $alpn != "" then { alpn: ($alpn | split(",")) } else {} end)) }
                       else {} end)
                    + (if $net == "ws" then { wsSettings: { path: (if $path == "" then "/" else $path end), headers: { Host: $hhost } } }
                       elif $net == "grpc" then { grpcSettings: { serviceName: $svc } }
                       else {} end))
            }]
        }' > "$CONF.new" || return 1
    mv "$CONF.new" "$CONF"
}

running() { [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; }

start() {
    running && return 0
    [ -f "$CONF" ] || { echo "нет ссылки: $0 set 'vless://...'"; return 1; }
    [ -x "$BIN" ] || { gzip -dc "$DIR/xray.gz" > "$BIN.tmp" && chmod 755 "$BIN.tmp" && mv "$BIN.tmp" "$BIN"; } || return 1
    "$BIN" run -c "$CONF" >> "$LOG" 2>&1 </dev/null &
    echo $! > "$PID"
    sleep 2
    running && echo "xray запущен, прокси 127.0.0.1:$PORT" || { echo "xray не запустился:"; tail -n 5 "$LOG"; return 1; }
}

stop() {
    running && kill "$(cat "$PID")"
    rm -f "$PID"
}

case "$1" in
    set)
        [ -n "$2" ] || { echo "использование: $0 set 'vless://...'"; exit 1; }
        make_conf "$2" || exit 1
        echo "$2" > "$URL_FILE"; chmod 600 "$URL_FILE" "$CONF"
        stop; start
        ;;
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    status)
        running && echo "работает (pid $(cat "$PID")), прокси 127.0.0.1:$PORT" || echo "не запущен"
        [ -f "$CONF" ] && jq -r '.outbounds[0] | "сервер: \(.settings.vnext[0].address):\(.settings.vnext[0].port) \(.streamSettings.network)/\(.streamSettings.security)"' "$CONF"
        ;;
    test)
        running || { echo "не запущен"; exit 1; }
        curl -s -m 20 -x "http://127.0.0.1:$PORT" -o /dev/null \
            -w 'через прокси: %{http_code}, %{size_download} байт за %{time_total} с\n' https://m.soundcloud.com/
        ;;
    *) echo "использование: $0 set 'vless://...' | start | stop | restart | status | test"; exit 1 ;;
esac
