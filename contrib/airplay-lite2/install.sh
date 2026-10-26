#!/bin/sh
# AirPlay 2 на Станции Лайт 2 вместе с Алисой (bt-proxy) — запускать на компьютере.
#
#   sh install.sh <IP колонки>               # установка
#   sh install.sh <IP колонки> --reboot      # установка и перезагрузка колонки
#   sh install.sh <IP колонки> --uninstall   # откат (добавьте --reboot, чтобы сразу применить)
#
# Одной строкой, без клона репозитория:
#   curl -fsSL https://raw.githubusercontent.com/Marker284/yandex-station-extended/main/contrib/airplay-lite2/install.sh | sh -s -- <IP>
#
# Нужны root по SSH (порт 2222) и yse (contrib/install-yse.sh). Ставит avahi из Entware,
# shairport-sync + nqptp (contrib/packages/airplay-lite2-armhf.tar.gz), bt-proxy, конфиги и
# автозапуск S55zbtproxy + S99zairplay-lite2, отключает D-Bus-активацию org.bluez.
# airplay_device_id и имя хоста для avahi вычисляются на колонке; имя можно задать: AP_HOSTNAME=...
# Проверено на Станции Лайт 2 (plum), прошивка 0.369.1.50.
# SSH-клиент можно подменить: SSHPASS= AP_SSH="sshpass -e ssh" sh install.sh <IP>
set -eu

RAW="https://raw.githubusercontent.com/Marker284/yandex-station-extended/main/contrib"
IP="${1:?укажи IP колонки: sh install.sh 192.168.1.50}"
shift
ACTION=install REBOOT=0
for a in "$@"; do
    case "$a" in
        --uninstall) ACTION=uninstall ;;
        --reboot) REBOOT=1 ;;
        *) echo "[airplay-lite2] неизвестный аргумент: $a" >&2; exit 1 ;;
    esac
done
SSH="${AP_SSH:-ssh}"
# macOS tar иначе кладёт в поток служебные ._*
export COPYFILE_DISABLE=1

say(){ echo "[airplay-lite2] $*"; }
die(){ echo "[airplay-lite2] ошибка: $*" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
P="$TMP/payload"; mkdir -p "$P/airplay" "$P/btproxy" "$P/init"
HERE=""
case "$0" in *install.sh) HERE="$(cd "$(dirname "$0")" && pwd)" ;; esac   # при `curl | sh` $0 = sh

# файл из клона репозитория (contrib/<путь>) или с GitHub
fetch(){
    if [ -n "$HERE" ] && [ -f "$HERE/../$1" ]; then
        cp "$HERE/../$1" "$2"
    elif command -v curl >/dev/null; then
        curl -fsSL -o "$2" "$RAW/$1" || die "не скачался $1"
    else
        wget -q -O "$2" "$RAW/$1" || die "не скачался $1 (нужен curl или wget)"
    fi
}

if [ "$ACTION" = install ]; then
    fetch packages/airplay-lite2-armhf.tar.gz "$TMP/pkg.tar.gz"
    # busybox tar на колонке не умеет -z — распаковываем здесь
    tar -xzf "$TMP/pkg.tar.gz" -C "$P/airplay"
    [ -x "$P/airplay/bin/shairport-sync" ] || die "архив сборки повреждён"
    fetch airplay-lite2/shairport-sync.conf "$P/airplay/shairport-sync.conf"
    fetch airplay-lite2/asoundrc "$P/airplay/.asoundrc"
    fetch airplay-lite2/S99zairplay-lite2 "$P/init/S99zairplay-lite2"
    fetch bin/bt-proxy "$P/btproxy/bt-proxy"
    fetch bt-proxy/bus.conf "$P/btproxy/bus.conf"
    fetch bt-proxy/S55zbtproxy "$P/init/S55zbtproxy"
    chmod 755 "$P/btproxy/bt-proxy" "$P/init/"*
fi

cat > "$P/remote.sh" <<'REMOTE'
#!/bin/sh
# Часть установщика, которая выполняется на колонке.
set -u
ACTION="$1" REBOOT="$2" HOSTNAME_OVERRIDE="${3:-}"
S=/tmp/apinst
SVC=/usr/share/dbus-1/system-services/org.bluez.service
say(){ echo "[airplay-lite2] $*"; }
die(){ echo "[airplay-lite2] ошибка: $*" >&2; mount -o remount,ro / 2>/dev/null; exit 1; }

if [ "$ACTION" = uninstall ]; then
    /etc/init.d/S99zairplay-lite2 stop 2>/dev/null
    /etc/init.d/S55zbtproxy stop 2>/dev/null
    mount -o remount,rw / || die "rootfs не перемонтируется на запись"
    rm -f /etc/init.d/S55zbtproxy /etc/init.d/S99zairplay-lite2
    [ -f "$SVC.disabled" ] && mv "$SVC.disabled" "$SVC"
    sync; mount -o remount,ro /
    # Bluetooth-демоны — обратно на системную шину, приватную погасить
    for s in S54default-bluez-agent S53bluealsa-aplay S52bluealsa S51bluetoothd; do /etc/init.d/$s stop; done
    i=0
    while [ $i -lt 50 ] && pidof bluetoothd bluealsa bluealsa-aplay just-works-bluez-agent >/dev/null; do
        usleep 100000; i=$((i+1))
    done
    for p in $(pidof dbus-daemon); do
        grep -q btproxy /proc/$p/cmdline 2>/dev/null && kill $p
    done
    rm -rf /tmp/btbus
    for s in S51bluetoothd S52bluealsa S53bluealsa-aplay S54default-bluez-agent; do /etc/init.d/$s start; done
    rm -rf /data/opt/airplay /data/opt/btproxy
    A=/opt/etc/avahi/avahi-daemon.conf
    [ -f "$A.orig" ] && mv "$A.orig" "$A"
    say "удалено, Bluetooth снова на системной шине"
    say "(avahi из Entware оставлен: yse remove avahi-dbus-daemon, если не нужен)"
else
    grep -q '"accessPointName" : "Plum"' /system/vendor/quasar/quasar.cfg ||
        die "это не Станция Лайт 2 (plum): на других моделях не проверялось"
    [ -x /data/opt/bin/yse ] || die "нет yse — сначала contrib/install-yse.sh"
    for s in S51bluetoothd S52bluealsa S53bluealsa-aplay S54default-bluez-agent; do
        [ -x /etc/init.d/$s ] || die "нет /etc/init.d/$s — другой Bluetooth-стек"
    done
    grep -q BluezBluetoothImpl /system/vendor/quasar/maind || die "maind без BlueZ — не поддерживается"

    if [ ! -x /opt/sbin/avahi-daemon ]; then
        say "ставлю avahi из Entware"
        /data/opt/bin/yse install avahi-dbus-daemon || die "avahi не поставился"
    fi

    say "копирую в /data/opt/airplay и /data/opt/btproxy"
    /etc/init.d/S99zairplay-lite2 stop 2>/dev/null
    mkdir -p /data/opt/airplay /data/opt/btproxy
    rm -rf /data/opt/airplay/bin /data/opt/airplay/lib
    cp -a $S/airplay/bin $S/airplay/lib $S/airplay/.asoundrc /data/opt/airplay/
    # bt-proxy может работать — заменить файл, а не писать поверх
    cp $S/btproxy/bt-proxy /data/opt/btproxy/bt-proxy.new
    mv /data/opt/btproxy/bt-proxy.new /data/opt/btproxy/bt-proxy
    cp $S/btproxy/bus.conf /data/opt/btproxy/
    chown -R root:root /data/opt/airplay /data/opt/btproxy

    MAC=$(tr -d ':\n' < /sys/class/net/wlan0/address | tr a-f A-F)
    [ ${#MAC} = 12 ] || die "не прочитался MAC wlan0"
    sed "s/0xXXXXXXXXXXXXL/0x${MAC}L/" $S/airplay/shairport-sync.conf > /data/opt/airplay/shairport-sync.conf

    # avahi берёт имя хоста, которое объявляет maind, иначе конфликт обратной PTR-записи
    DEVID=$(sed -n 's/.*androidboot.deviceid=\([^ ]*\).*/\1/p' /proc/cmdline)
    HOST="${HOSTNAME_OVERRIDE:-YandexLite-gen2-$DEVID}"
    [ -n "$DEVID" ] || [ -n "$HOSTNAME_OVERRIDE" ] || die "не прочитался deviceid — задайте AP_HOSTNAME"
    A=/opt/etc/avahi/avahi-daemon.conf
    [ -f "$A" ] && [ ! -f "$A.orig" ] && cp "$A" "$A.orig"
    cat > "$A" <<EOF
# airplay-lite2: имя хоста — то, что объявляет maind; свои адреса не публикуем
[server]
host-name=$HOST
allow-interfaces=wlan0
use-ipv4=yes
use-ipv6=no
[publish]
publish-addresses=no
publish-hinfo=no
publish-workstation=no
EOF

    say "автозапуск в /etc/init.d, отключаю D-Bus-активацию org.bluez"
    mount -o remount,rw / || die "rootfs не перемонтируется на запись"
    cp $S/init/S55zbtproxy $S/init/S99zairplay-lite2 /etc/init.d/
    chmod 755 /etc/init.d/S55zbtproxy /etc/init.d/S99zairplay-lite2
    [ -f "$SVC" ] && mv "$SVC" "$SVC.disabled"
    sync; mount -o remount,ro /
    say "готово: имя хоста avahi $HOST, airplay_device_id 0x$MAC"
fi
rm -rf $S
if [ "$REBOOT" = 1 ]; then
    say "перезагружаю колонку"
    sync; reboot
else
    say "перезагрузите колонку, чтобы применить"
fi
REMOTE

say "ставлю по SSH (root@$IP:2222; пароля у root нет — просто Enter)"
# shellcheck disable=SC2086  # AP_SSH может содержать аргументы (sshpass -e ssh)
tar -C "$P" -cf - . | $SSH -p 2222 "root@$IP" \
    "rm -rf /tmp/apinst && mkdir -p /tmp/apinst && tar -C /tmp/apinst -xf - && sh /tmp/apinst/remote.sh $ACTION $REBOOT '${AP_HOSTNAME:-}'"
