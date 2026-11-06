#!/bin/sh
# Установка пакетного менеджера yse на Яндекс Станцию — запускать на компьютере.
#
#   sh install-yse.sh <IP колонки>           # по ADB (порт 5555), если нет — по SSH (порт 2222)
#   sh install-yse.sh <IP> --ssh             # только по SSH
#   sh install-yse.sh <IP> --adb             # только по ADB
#
# Одной строкой, без клона репозитория:
#   curl -fsSL https://raw.githubusercontent.com/Marker284/yandex-station-extended/main/contrib/install-yse.sh | sh -s -- <IP>
#
# Скрипт берёт yse рядом с собой (contrib/bin/yse), а если его нет — скачивает с GitHub,
# кладёт в /data/opt/bin/yse и запускает `yse bootstrap` (Entware).
# SSH-клиент можно подменить: SSHPASS= YSE_SSH="sshpass -e ssh" sh install-yse.sh <IP> --ssh
set -eu

YSE_URL="https://raw.githubusercontent.com/Marker284/yandex-station-binaries/main/bin/yse"
IP="${1:?укажи IP колонки: sh install-yse.sh 192.168.1.120}"
MODE="${2:-auto}"
SSH="${YSE_SSH:-ssh}"

say(){ echo "[install-yse] $*"; }
die(){ echo "[install-yse] ошибка: $*" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
HERE=""
case "$0" in *install-yse.sh) HERE="$(cd "$(dirname "$0")" && pwd)" ;; esac   # при `curl | sh` $0 = sh
if [ -n "$HERE" ] && [ -f "$HERE/bin/yse" ]; then
    cp "$HERE/bin/yse" "$TMP/yse"
else
    say "скачиваю yse: $YSE_URL"
    if command -v curl >/dev/null; then curl -fsSL -o "$TMP/yse" "$YSE_URL"
    elif command -v wget >/dev/null; then wget -q -O "$TMP/yse" "$YSE_URL"
    else die "нужен curl или wget"; fi
fi
head -1 "$TMP/yse" | grep -q '^#!/bin/sh' || die "скачанный yse повреждён"

via_adb(){
    command -v adb >/dev/null || return 1
    adb connect "$IP:5555" >/dev/null 2>&1 || true
    adb -s "$IP:5555" shell true >/dev/null 2>&1 || return 1
    say "ставлю по ADB ($IP:5555)"
    adb -s "$IP:5555" shell mkdir -p /data/opt/bin
    adb -s "$IP:5555" push "$TMP/yse" /data/opt/bin/yse >/dev/null
    adb -s "$IP:5555" shell chmod +x /data/opt/bin/yse
    adb -s "$IP:5555" shell /data/opt/bin/yse bootstrap
}

via_ssh(){
    say "ставлю по SSH (root@$IP:2222; пароля у root нет — просто Enter)"
    # shellcheck disable=SC2086  # YSE_SSH может содержать аргументы (sshpass -e ssh)
    $SSH -p 2222 "root@$IP" 'mkdir -p /data/opt/bin && cat > /data/opt/bin/yse.new && chmod +x /data/opt/bin/yse.new && mv /data/opt/bin/yse.new /data/opt/bin/yse && /data/opt/bin/yse bootstrap' < "$TMP/yse"
}

case "$MODE" in
    --adb) via_adb || die "ADB недоступен ($IP:5555)" ;;
    --ssh) via_ssh ;;
    auto)  via_adb || via_ssh ;;
    *)     die "неизвестный режим: $MODE (--adb или --ssh)" ;;
esac

say "готово. Переподключитесь к колонке — команда yse будет в PATH:"
say "  yse install htop        # из Entware"
say "  yse install yap:btop    # из GitHub-реестра yapkg"
