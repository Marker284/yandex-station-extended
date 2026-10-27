#!/system/bin/sh
# Установка ТВ-набора на Яндекс Станцию 1 (Android 6, root, dropbear в /data/dropbear, Entware в /opt):
# веб-пульт (lighttpd, порт 8080), Couchy Launcher, SmartTube, v2rayNG.
# Запускается install.ps1 после распаковки архива в /data/local/tmp/tvpack. Повторный запуск безопасен.
# Удаление: убрать строку remote.sh из /data/dropbear/start.sh, rm -rf /opt/share/remote,
#           pm uninstall com.conreo.couchytv org.smarttube.stable com.v2ray.ang,
#           opkg remove lighttpd-mod-cgi lighttpd.
set -e
export ANDROID_DATA=/data ANDROID_ROOT=/system PATH=/opt/bin:/opt/sbin:/system/bin:/sbin:/bin
BB=/sbin/busybox
P=/data/local/tmp/tvpack
say() { echo "[*] $*"; }

[ "$(id -u)" = 0 ] || { echo "[!] нужен root"; exit 1; }
[ -x /opt/bin/opkg ] || { echo "[!] нет Entware (/opt/bin/opkg): поставьте его через AliceBridge"; exit 1; }
[ -f /data/dropbear/start.sh ] || { echo "[!] нет /data/dropbear/start.sh: нужен SSH от AliceBridge"; exit 1; }

# opkg качает через wget, а busybox wget на Android не резолвит DNS: обёртка над curl
if ! [ -f /opt/bin/wget ] || ! grep -q curl /opt/bin/wget; then
    rm -f /opt/bin/wget
    cat > /opt/bin/wget <<'EOF'
#!/system/bin/sh
# Обёртка wget -> curl для opkg: busybox wget на Android не резолвит DNS (нет /etc/resolv.conf).
out=-; url=
while [ $# -gt 0 ]; do
    case "$1" in
        -O) out=$2; shift;;
        -O*) out=${1#-O};;
        -T|--timeout|-t|--tries|-U|--user-agent) shift;;
        -*) ;;
        *) url=$1;;
    esac
    shift
done
[ -n "$url" ] || exit 1
if [ "$out" = - ]; then exec /bin/curl -fsSL --cacert /system/vendor/quasar/ca-certificates.crt "$url"
else exec /bin/curl -fsSL --cacert /system/vendor/quasar/ca-certificates.crt -o "$out" "$url"; fi
EOF
    chmod 755 /opt/bin/wget
    say "wget для opkg настроен"
fi

say "ставлю lighttpd"
opkg update >/dev/null
opkg install lighttpd lighttpd-mod-cgi >/dev/null

say "копирую файлы пульта"
mkdir -p /opt/share/remote/cgi-bin /opt/var/log /opt/var/run /opt/tmp
cp $P/index.html /opt/share/remote/index.html
cp $P/k /opt/share/remote/cgi-bin/k
cp $P/remote.conf /opt/etc/lighttpd/remote.conf
cp $P/remote.sh /data/dropbear/remote.sh
chmod 755 /opt/share/remote/cgi-bin/k /data/dropbear/remote.sh
[ -f /data/dropbear/tv.conf ] || echo BOOT_LAUNCHER=alice > /data/dropbear/tv.conf

for apk in $P/*.apk; do
    chmod 644 "$apk"
    say "ставлю $(basename "$apk")"
    pm install -r "$apk" | tail -1
done

F=/data/dropbear/start.sh
grep -q remote.sh $F || $BB sed -i '1a /sbin/busybox setsid /system/bin/sh /data/dropbear/remote.sh </dev/null >>/data/dropbear/remote.log 2>\&1 \&' $F
/system/bin/sh /data/dropbear/remote.sh now

rm -rf $P
ip=$(ip -4 addr show wlan0 2>/dev/null | $BB sed -n 's/.*inet \([0-9.]*\).*/\1/p')
say "готово. Пульт: http://${ip:-<IP колонки>}:8080"
