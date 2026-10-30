#!/system/bin/sh
# AirPlay 2 for Station 1 / Android 6 / AliceBridge Entware. Run as root.
set -eu
export PATH=/opt/bin:/opt/sbin:/system/bin:/sbin:/bin
BB=/sbin/busybox
DIR=/data/station1-airplay
START=/data/dropbear/start.sh
MODE=${1:-install}
[ "$(id -u)" = 0 ] || { echo 'Run in the root AliceBridge terminal'; exit 1; }
[ -x "$BB" ] || exit 1
case "$MODE" in
    status)
        for name in dbus-daemon avahi-daemon nqptp shairport-sync; do
            if "$BB" pidof "$name" >/dev/null; then echo "$name: running"; else echo "$name: stopped"; fi
        done
        [ ! -x /opt/bin/shairport-sync ] || /opt/bin/shairport-sync -V
        [ ! -f "$DIR/disabled" ] || echo 'Autostart disabled'
        exit 0;;
    disable)
        mkdir -p "$DIR"; chmod 700 "$DIR"; : > "$DIR/disabled"
        for name in shairport-sync nqptp; do
            pids=$("$BB" pidof "$name" 2>/dev/null || true)
            [ -z "$pids" ] || kill $pids
        done
        echo 'AirPlay stopped and disabled; shared dbus/avahi left running'
        exit 0;;
    enable)
        rm -f "$DIR/disabled"
        sh /data/dropbear/airplay.sh
        exit 0;;
    install) ;;
    *) echo 'Usage: sh station1-airplay.sh [install|status|disable|enable]'; exit 1;;
esac
case "$(getprop ro.product.device)" in tulip*) ;; *) echo 'Only Station 1 / tulip is supported'; exit 1;; esac
[ "$(getprop ro.build.version.sdk)" = 23 ] || { echo 'Expected Android SDK 23'; exit 1; }
[ -x /opt/bin/opkg ] || { echo 'Install Entware with AliceBridge first'; exit 1; }
[ -d /data/dropbear ] && [ -f "$START" ] || { echo 'AliceBridge startup hook missing'; exit 1; }
"$BB" grep -q 'tas5751' /proc/asound/pcm || { echo 'Expected Station 1 speaker card not found'; exit 1; }
mkdir -p "$DIR/backups"
chmod 700 "$DIR" "$DIR/backups"
backup=$DIR/backups/$(date +%Y%m%d-%H%M%S)-$$
mkdir -p "$backup"
for file in /opt/etc/shairport-sync.conf /opt/etc/avahi/avahi-daemon.conf /data/dropbear/airplay.sh "$START"; do
    [ ! -f "$file" ] || cp -p "$file" "$backup/$(echo "$file" | "$BB" tr / _)"
done
echo "Backup: $backup"
existing=0
if [ -x /opt/bin/shairport-sync ] && /opt/bin/shairport-sync -V 2>/dev/null | "$BB" grep -q AirPlay2; then existing=1; fi

# Android's BusyBox wget cannot resolve names here. Keep an existing working
# downloader; create a curl wrapper only when /opt/bin/wget is absent.
if [ ! -x /opt/bin/wget ]; then
    [ -x /system/bin/curl ] || { echo 'Android curl missing'; exit 1; }
    cat > /opt/bin/wget <<'WGET'
#!/system/bin/sh
set -eu
out=-; url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -O) shift; out=$1;; -O*) out=${1#-O};;
        -T|--timeout|-t|--tries|-U|--user-agent) shift;;
        -*) ;; *) url=$1;;
    esac
    shift
done
[ -n "$url" ] || exit 1
case "$url" in http://bin.entware.net/*) url=https://${url#http://};; esac
exec /system/bin/curl --fail --location --retry 2 --connect-timeout 15 --max-time 300 --cacert /system/vendor/quasar/ca-certificates.crt --output "$out" "$url"
WGET
    chmod 755 /opt/bin/wget
fi
missing=0
for package in shairport-sync-openssl nqptp avahi-dbus-daemon dbus; do
    /opt/bin/opkg status "$package" | "$BB" grep -q '^Status:.* installed' || missing=1
done
if [ "$missing" = 1 ]; then
    /opt/bin/opkg update
    if /opt/bin/opkg status shairport-sync-mini | "$BB" grep -q '^Status:.* installed'; then
        /opt/bin/opkg remove shairport-sync-mini
    fi
    /opt/bin/opkg install shairport-sync-openssl nqptp avahi-dbus-daemon dbus
fi
/opt/bin/shairport-sync -V | "$BB" grep -q AirPlay2 || { echo 'AirPlay 2 build not installed'; exit 1; }

# Make Entware's account files independent if they point at read-only Android
# files. Never write through /etc/passwd or change the existing root account.
for name in passwd group; do
    file=/opt/etc/$name
    if [ -L "$file" ]; then
        cp -p "$file" "$backup/$name"
        cp "$file" "$DIR/$name.new"
        mv "$DIR/$name.new" "$file"
    fi
    [ -f "$file" ] || : > "$file"
done
"$BB" grep -q '^nobody:' /opt/etc/passwd || echo 'nobody:x:65534:65534:nobody:/nonexistent:/bin/false' >> /opt/etc/passwd
"$BB" grep -q '^nobody:' /opt/etc/group || echo 'nobody:x:65534:' >> /opt/etc/group

if [ "$existing" = 0 ]; then
    cat > /opt/etc/shairport-sync.conf <<'CONFIG'
general = {
    name = "Яндекс Станция";
    output_backend = "alsa";
    mdns_backend = "avahi";
    audio_backend_buffer_desired_length_in_seconds = 0.5;
};
alsa = {
    output_device = "plughw:1,0";
    use_precision_timing = "no";
};
CONFIG
fi
# Preserve existing custom Avahi settings; fix only the resource limit that
# prevents it from starting alongside Android's many root processes.
avahi=/opt/etc/avahi/avahi-daemon.conf
"$BB" sed '/^[[:space:]]*rlimit-nproc[[:space:]]*=/s/^/# Station 1: /' "$avahi" > "$DIR/avahi.new"
if [ "$existing" = 0 ]; then
    "$BB" sed -e '/^\[server\]/a\allow-interfaces=wlan0' -e 's/^[#[:space:]]*use-ipv6=.*/use-ipv6=no/' "$DIR/avahi.new" > "$avahi"
else
    cat "$DIR/avahi.new" > "$avahi"
fi
rm -f "$DIR/avahi.new"
cat > /data/dropbear/airplay.sh <<'BOOT'
#!/system/bin/sh
export PATH=/opt/bin:/opt/sbin:/system/bin:/sbin:/bin
BB=/sbin/busybox
DIR=/data/station1-airplay
[ ! -f "$DIR/disabled" ] || exit 0
mkdir -p "$DIR"
if ! mkdir "$DIR/start.lock" 2>/dev/null; then
    old=$(cat "$DIR/start.lock/pid" 2>/dev/null)
    case "$old" in ''|*[!0-9]*) ;; *) kill -0 "$old" 2>/dev/null && exit 0;; esac
    rm -f "$DIR/start.lock/pid"
    rmdir "$DIR/start.lock" 2>/dev/null || exit 1
    mkdir "$DIR/start.lock" || exit 1
fi
echo $$ > "$DIR/start.lock/pid"
trap 'rm -f "$DIR/start.lock/pid"; rmdir "$DIR/start.lock"' EXIT
mkdir -p /opt/var/run/dbus /opt/var/run/shairport-sync /opt/var/lib/dbus /opt/var/run/avahi-daemon
if ! "$BB" pidof dbus-daemon >/dev/null; then
    rm -f /opt/var/run/dbus/dbus.pid
    dbus-uuidgen --ensure && dbus-daemon --system || exit 1
fi
if ! "$BB" pidof avahi-daemon >/dev/null; then
    rm -f /opt/var/run/avahi-daemon/pid
    avahi-daemon -D --no-drop-root || exit 1
fi
if ! "$BB" pidof nqptp >/dev/null; then
    "$BB" setsid nqptp </dev/null >/dev/null 2>&1 &
fi
sleep 2
if ! "$BB" pidof shairport-sync >/dev/null; then
    rm -f /opt/var/run/shairport-sync/shairport-sync.pid
    shairport-sync -d -c /opt/etc/shairport-sync.conf || exit 1
fi
BOOT
chmod 700 /data/dropbear/airplay.sh
if ! "$BB" grep -q '/data/dropbear/airplay.sh' "$START"; then
    cat >> "$START" <<'HOOK'

# station1-airplay begin
/sbin/busybox setsid /system/bin/sh /data/dropbear/airplay.sh </dev/null >>/data/dropbear/airplay.log 2>&1 &
# station1-airplay end
HOOK
fi
if ! "$BB" test "$0" -ef "$DIR/install.sh"; then cp "$0" "$DIR/install.sh"; fi
chmod 700 "$DIR/install.sh"
if [ -f "$DIR/disabled" ]; then
    echo 'AirPlay remains disabled; enable: sh /data/station1-airplay/install.sh enable'
else
    sh /data/dropbear/airplay.sh
fi
echo 'AirPlay 2 installed. Select Яндекс Станция on an iPhone/iPad/Mac in the same network.'
echo 'No audio played, volume changed, Alice restart or metrics block applied.'
