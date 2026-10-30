#!/system/bin/sh
# Station 1: one native IPC listener, no screen/microphone or metrics changes.
export ANDROID_DATA=/data ANDROID_ROOT=/system PATH=/system/bin:/sbin:/bin
umask 077
BB=/sbin/busybox
DIR=/data/station1-soundcloud
[ ! -f "$DIR/voice-disabled" ] || exit 0
if [ "${1:-}" != now ]; then
    count=0
    while [ "$(getprop sys.boot_completed)" != 1 ] && [ "$count" -lt 90 ]; do sleep 2; count=$((count+1)); done
fi
# Remove only the obsolete screen observer from earlier versions.
component=me.hackalice.station.soundcloud/me.hackalice.station.soundcloud.SoundCloudVoiceService
current=$(settings get secure enabled_accessibility_services)
case ":$current:" in *":$component:"*)
    others=$(printf '%s' "$current" | "$BB" awk -v RS=: -v ORS=: -v own="$component" '$0!=own && $0!="null" && $0!="" {print}' | "$BB" sed 's/:$//')
    settings put secure enabled_accessibility_services "$others";;
esac
running=0
pid=$(cat "$DIR/voice.pid" 2>/dev/null)
case "$pid" in ''|*[!0-9]*) ;; *)
    if [ -r "/proc/$pid/cmdline" ] && "$BB" tr '\000' ' ' < "/proc/$pid/cmdline" | "$BB" grep -q "NativeVoice $DIR"; then
        running=1
    fi;;
esac
if [ "$running" = 0 ]; then
    rm -f "$DIR/voice-native.json"
    CLASSPATH=$DIR/vless-import.jar "$BB" setsid app_process /system/bin NativeVoice "$DIR" </dev/null >"$DIR/voice.log" 2>&1 &
    echo $! > "$DIR/voice.pid"
fi
echo 'Native SoundCloud voice worker started; no Alice restart, mute or metrics block'
uid=$(dumpsys package com.v2ray.ang | "$BB" awk '/userId=/ {sub(/.*userId=/, ""); sub(/[^0-9].*/, ""); print; exit}')
case "$uid" in ''|*[!0-9]*) echo 'v2rayNG UID unavailable; native voice remains running'; exit 1;; esac
# Android's boot-time ip cannot resolve netd's dynamic table name. Read the
# numeric Wi-Fi table after netd creates it, independently of the voice worker.
count=0
table=
while [ "$count" -lt 30 ]; do
    table=$("$BB" awk '$2=="wlan0" {print $1; exit}' /data/misc/net/rt_tables 2>/dev/null)
    case "$table" in ''|*[!0-9]*) ;; *) if ip route show table "$table" | "$BB" grep -q '^default '; then break; fi;; esac
    count=$((count+1)); sleep 2
done
case "$table" in ''|*[!0-9]*) echo 'Wi-Fi table not ready; rerun installer repair after connecting'; exit 1;; esac
if ip rule | "$BB" grep -q '^10850:'; then
    ip rule | "$BB" grep -Eq "^10850:.*uidrange $uid-$uid lookup ($table|wlan0)([[:space:]]|$)" || { echo 'Route priority 10850 is already used; preserved'; exit 1; }
else
    ip rule add pref 10850 uidrange "$uid-$uid" lookup "$table" || exit 1
fi
echo "$uid" > "$DIR/route-uid"
echo "$table" > "$DIR/route-table"
echo 'v2rayNG physical Wi-Fi transport rule ready'
# This firmware blocks third-party BOOT_COMPLETED receivers. Use v2rayNG's
# supported explicit start action, never a toggle. The selected profile is kept.
if [ ! -f "$DIR/no-vpn-autostart" ]; then
    CLASSPATH=$DIR/vless-import.jar app_process /system/bin VpnStart
fi
