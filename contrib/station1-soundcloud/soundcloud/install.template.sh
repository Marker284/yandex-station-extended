#!/system/bin/sh
# Station 1 / Android 6: NewPipe SoundCloud, Alice voice bridge and v2rayNG.
# One file, run in AliceBridge's rooted Station terminal. No public proxies.
set -e
set +x
export ANDROID_DATA=/data ANDROID_ROOT=/system PATH=/system/bin:/sbin:/bin
umask 077
BB=/sbin/busybox
DIR=/data/station1-soundcloud
COMPONENT=me.hackalice.station.soundcloud/me.hackalice.station.soundcloud.SoundCloudVoiceService
case "${1:-}" in ''|vpn|repair|vpn-autostart|uninstall|restore-newpipe) ;; *) echo 'Usage: sh install-soundcloud.sh [vpn|repair|vpn-autostart on|off|uninstall|restore-newpipe]'; exit 2;; esac
[ "$(id -u)" = 0 ] || { echo 'Run in AliceBridge Station terminal with root'; exit 1; }
[ "$(getprop ro.board.platform)" = tulip ] && [ "$(getprop ro.build.version.sdk)" = 23 ] || { echo 'Only Station 1 / Android 6 is supported'; exit 1; }
[ -x "$BB" ] && [ -x /system/bin/curl ] || { echo 'AliceBridge busybox and system curl are required'; exit 1; }
stop_voice() {
    pid=$(cat "$DIR/voice.pid" 2>/dev/null || true)
    case "$pid" in ''|*[!0-9]*) ;; *)
        if [ -r "/proc/$pid/cmdline" ] && "$BB" tr '\000' ' ' < "/proc/$pid/cmdline" | "$BB" grep -q "NativeVoice $DIR"; then kill "$pid" 2>/dev/null || true; fi;;
    esac
    rm -f "$DIR/voice.pid"
}
restore_data() {
    saved=$1
    owner=$(dumpsys package org.schabi.newpipe | $BB awk '/userId=/ {sub(/.*userId=/, ""); sub(/[^0-9].*/, ""); print; exit}')
    case "$owner" in ''|*[!0-9]*) echo 'Cannot determine NewPipe UID'; return 1;; esac
    $BB tar -xf "$saved/data.tar" -C /data/data
    chown -R "$owner:$owner" /data/data/org.schabi.newpipe
    restorecon -R /data/data/org.schabi.newpipe 2>/dev/null || true
}
restore_newpipe() {
    saved=$1
    [ -s "$saved/NewPipe.apk" ] && [ -s "$saved/data.tar" ] || { echo 'NewPipe backup is incomplete'; return 1; }
    cp "$saved/NewPipe.apk" /data/local/tmp/NewPipe-soundcloud-restore.apk
    chmod 644 /data/local/tmp/NewPipe-soundcloud-restore.apk
    am force-stop org.schabi.newpipe
    case "$(pm path org.schabi.newpipe 2>/dev/null)" in package:*) pm uninstall org.schabi.newpipe;; esac
    result=$(pm install /data/local/tmp/NewPipe-soundcloud-restore.apk 2>&1) || true
    echo "$result" | $BB grep -q Success || { echo 'Cannot restore the saved APK; backup preserved'; return 1; }
    restore_data "$saved"
    rm -f /data/local/tmp/NewPipe-soundcloud-restore.apk
    echo 'Previous NewPipe APK and saved data restored.'
}
if [ "${1:-}" = restore-newpipe ]; then
    [ -f "$DIR/last-newpipe-backup" ] || { echo 'No NewPipe migration backup'; exit 1; }
    saved=$(cat "$DIR/last-newpipe-backup")
    case "$saved" in "$DIR"/backups/NewPipe-*) ;; *) echo 'Invalid backup path'; exit 1;; esac
    : > "$DIR/voice-disabled"
    stop_voice
    restore_newpipe "$saved"
    exit 0
fi
if [ "${1:-}" = vpn ]; then
    [ -f "$DIR/vless.sh" ] || { echo 'Run the installer first'; exit 1; }
    exec sh "$DIR/vless.sh"
fi
if [ "${1:-}" = repair ]; then
    exec sh "$DIR/boot.sh" now
fi
if [ "${1:-}" = vpn-autostart ]; then
    [ -d "$DIR" ] || { echo 'Run the installer first'; exit 1; }
    case "${2:-}" in
        off) : > "$DIR/no-vpn-autostart"; echo 'VPN autostart disabled; current connection preserved';;
        on) rm -f "$DIR/no-vpn-autostart"; echo 'VPN autostart enabled';;
        *) echo 'Usage: sh install-soundcloud.sh vpn-autostart on|off'; exit 2;;
    esac
    exit 0
fi
if [ "${1:-}" = uninstall ]; then
    stop_voice
    if [ -f /data/dropbear/start.sh ]; then
        "$BB" sed '/^# station1-soundcloud begin$/,/^# station1-soundcloud end$/d' /data/dropbear/start.sh > "$DIR/start.without-soundcloud"
        cat "$DIR/start.without-soundcloud" > /data/dropbear/start.sh
        rm -f "$DIR/start.without-soundcloud"
    fi
    if [ -f "$DIR/route-uid" ]; then
        uid=$(cat "$DIR/route-uid")
        table=$(cat "$DIR/route-table" 2>/dev/null || true)
        case "$uid:$table" in *[!0-9:]*|:|*:) ;; *) ip rule del pref 10850 uidrange "$uid-$uid" lookup "$table" 2>/dev/null || true;; esac
    fi
    current=$(settings get secure enabled_accessibility_services)
    new=$(printf '%s' "$current" | $BB awk -v RS=: -v ORS=: -v own="$COMPONENT" '$0!=own && $0!="null" && $0!="" {print}' | $BB sed 's/:$//')
    if [ -n "$new" ]; then settings put secure enabled_accessibility_services "$new";
    else settings delete secure enabled_accessibility_services; settings put secure accessibility_enabled 0; fi
    if pm path me.hackalice.station.soundcloud >/dev/null 2>&1; then pm uninstall me.hackalice.station.soundcloud; fi
    rm -f "$DIR/vless.sh" "$DIR/vless-import.jar" "$DIR/boot.sh" "$DIR/route-uid" "$DIR/route-table"
    echo 'Voice bridge removed. NewPipe, v2rayNG and their data are preserved.'
    exit 0
fi
mkdir -p "$DIR"
chmod 700 "$DIR"
stop_voice
rm -f "$DIR/voice-disabled"
STAGE=/data/local/tmp/station-soundcloud-$(date +%s)-$$
mkdir -p "$STAGE"
chmod 755 "$STAGE"
cleanup() { rm -f "$STAGE/voice.apk" "$STAGE/NewPipe.apk" "$STAGE/v2rayNG.apk" "$STAGE/vless-import.jar"; rmdir "$STAGE" 2>/dev/null || true; }
trap cleanup EXIT

"$BB" uudecode -o "$STAGE/voice.apk" <<'SOUNDCLOUD_VOICE_APK'
begin-base64 644 voice.apk
__VOICE_APK_BASE64_WRAPPED__
====
SOUNDCLOUD_VOICE_APK
"$BB" uudecode -o "$STAGE/vless-import.jar" <<'SOUNDCLOUD_VLESS_JAR'
begin-base64 600 vless-import.jar
__VLESS_JAR_BASE64_WRAPPED__
====
SOUNDCLOUD_VLESS_JAR
"$BB" uudecode -o "$STAGE/NewPipe.apk" <<'SOUNDCLOUD_NEWPIPE_APK'
begin-base64 644 NewPipe.apk
__NEWPIPE_APK_BASE64_WRAPPED__
====
SOUNDCLOUD_NEWPIPE_APK
[ "$($BB sha256sum "$STAGE/voice.apk" | $BB awk '{print $1}')" = '__VOICE_APK_SHA256__' ] || { echo 'Embedded APK checksum failed'; exit 1; }
[ "$($BB sha256sum "$STAGE/vless-import.jar" | $BB awk '{print $1}')" = '__VLESS_JAR_SHA256__' ] || { echo 'Embedded VLESS helper checksum failed'; exit 1; }
[ "$($BB sha256sum "$STAGE/NewPipe.apk" | $BB awk '{print $1}')" = '__NEWPIPE_APK_SHA256__' ] || { echo 'Embedded NewPipe checksum failed'; exit 1; }

install_missing() {
    package=$1; name=$2; url=$3; hash=$4
    case "$(pm path "$package" 2>/dev/null || true)" in package:*) echo "Already installed: $package"; return;; esac
    echo "Downloading $name"
    if [ -f /system/vendor/quasar/ca-certificates.crt ]; then
        /system/bin/curl --fail --location --retry 2 --connect-timeout 15 --max-time 300 --cacert /system/vendor/quasar/ca-certificates.crt "$url" -o "$STAGE/$name"
    else
        /system/bin/curl --fail --location --retry 2 --connect-timeout 15 --max-time 300 "$url" -o "$STAGE/$name"
    fi
    [ "$($BB sha256sum "$STAGE/$name" | $BB awk '{print $1}')" = "$hash" ] || { echo "APK checksum failed: $name"; exit 1; }
    chmod 644 "$STAGE/$name"
    result=$(pm install -r "$STAGE/$name" 2>&1); echo "$result"
    echo "$result" | $BB grep -q Success || exit 1
}
fresh=0
case "$(pm path org.schabi.newpipe 2>/dev/null || true)" in package:*) ;; *) fresh=1;; esac
chmod 644 "$STAGE/NewPipe.apk"
old_apk=$(pm path org.schabi.newpipe 2>/dev/null | $BB sed -n 's/^package://p' | $BB head -n 1)
if [ -n "$old_apk" ]; then
    old_hash=$($BB sha256sum "$old_apk" | $BB awk '{print $1}')
    if [ "$old_hash" != '__NEWPIPE_APK_SHA256__' ]; then
        result=$(pm install -r -d "$STAGE/NewPipe.apk" 2>&1) || true
        if ! echo "$result" | $BB grep -q Success; then
            [ "$old_hash" = '18447bfb1e06d113edc88df93f471827280de06f6f3d4dc42f56f28b9c1bab79' ] || { echo 'Existing NewPipe has a different signature/version; it was preserved. Review its migration separately.'; exit 1; }
            saved=$DIR/backups/NewPipe-$(date +%Y%m%d-%H%M%S)-$$
            mkdir -p "$saved"
            cp "$old_apk" "$saved/NewPipe.apk"
            am force-stop org.schabi.newpipe
            $BB tar -cf "$saved/data.tar" -C /data/data org.schabi.newpipe
            echo "$saved" > "$DIR/last-newpipe-backup"
            echo 'Installing the Station 1 rendering fix; original APK and data were backed up.'
            result=$(pm uninstall org.schabi.newpipe 2>&1) || true
            echo "$result" | $BB grep -q Success || { echo 'Cannot replace NewPipe; backup preserved'; exit 1; }
            result=$(pm install "$STAGE/NewPipe.apk" 2>&1) || true
            if ! echo "$result" | $BB grep -q Success; then restore_newpipe "$saved"; exit 1; fi
            restore_data "$saved"
        fi
    fi
else
    result=$(pm install "$STAGE/NewPipe.apk" 2>&1) || true
    echo "$result" | $BB grep -q Success || { echo 'Cannot install NewPipe'; exit 1; }
fi
install_missing com.v2ray.ang v2rayNG.apk \
    https://github.com/2dust/v2rayNG/releases/download/1.9.45/v2rayNG_1.9.45_arm64-v8a.apk \
    72fb0b4ee3f4ab37608d17ff658ba2bdec2e65248ee9f07c3d375992a12ec148

if [ "$fresh" = 1 ]; then
    pref=/data/data/org.schabi.newpipe/shared_prefs
    mkdir -p "$pref"
    cat > "$pref/org.schabi.newpipe_preferences.xml" <<'NEWPIPE_PREFERENCES'
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <string name="theme">light_theme</string>
    <string name="list_view_mode">list</string>
    <string name="service">SoundCloud</string>
</map>
NEWPIPE_PREFERENCES
    owner=$(dumpsys package org.schabi.newpipe | $BB awk '/userId=/ {sub(/.*userId=/, ""); sub(/[^0-9].*/, ""); print; exit}')
    case "$owner" in ''|*[!0-9]*) echo 'Cannot determine NewPipe UID'; exit 1;; esac
    chown -R "$owner:$owner" /data/data/org.schabi.newpipe
    chmod 771 "$pref"
    chmod 660 "$pref/org.schabi.newpipe_preferences.xml"
    restorecon -R "$pref" 2>/dev/null || true
fi

# Keep the previous helper/bridge APK for local rollback when updating.
if [ -f "$DIR/vless.sh" ] || pm path me.hackalice.station.soundcloud >/dev/null 2>&1; then
    backup=$DIR/backups/$(date +%Y%m%d-%H%M%S)-$$
    mkdir -p "$backup"
    for name in vless.sh vless-import.jar; do [ ! -f "$DIR/$name" ] || cp "$DIR/$name" "$backup/$name"; done
    old_apk=$(pm path me.hackalice.station.soundcloud 2>/dev/null | $BB sed -n 's/^package://p' | $BB head -n 1)
    [ ! -f "$old_apk" ] || cp "$old_apk" "$backup/voice.apk"
fi
chmod 644 "$STAGE/voice.apk"
result=$(pm install -r "$STAGE/voice.apk" 2>&1); echo "$result"
echo "$result" | $BB grep -q Success || exit 1
cp "$STAGE/vless-import.jar" "$DIR/vless-import.jar"
chmod 600 "$DIR/vless-import.jar"
cat > "$DIR/vless.sh" <<'SOUNDCLOUD_VLESS_SCRIPT'
__VLESS_SH__
SOUNDCLOUD_VLESS_SCRIPT
chmod 700 "$DIR/vless.sh"
if ! "$BB" test "$0" -ef "$DIR/install-soundcloud.sh"; then
    cp "$0" "$DIR/install-soundcloud.sh"
fi
chmod 700 "$DIR/install-soundcloud.sh"
if [ ! -f "$DIR/accessibility-before" ]; then
    settings get secure enabled_accessibility_services > "$DIR/accessibility-before"
    settings get secure accessibility_enabled > "$DIR/enabled-before"
fi
cat > "$DIR/boot.sh" <<'SOUNDCLOUD_BOOT_SCRIPT'
__BOOT_SH__
SOUNDCLOUD_BOOT_SCRIPT
chmod 700 "$DIR/boot.sh"
if [ -f /data/dropbear/start.sh ]; then
    cp /data/dropbear/start.sh "$DIR/start.before-soundcloud.sh"
    if ! "$BB" grep -q '^# station1-soundcloud begin$' /data/dropbear/start.sh; then
        cat >> /data/dropbear/start.sh <<'SOUNDCLOUD_BOOT_HOOK'

# station1-soundcloud begin
/sbin/busybox setsid /system/bin/sh /data/station1-soundcloud/boot.sh </dev/null >>/data/station1-soundcloud/boot.log 2>&1 &
# station1-soundcloud end
SOUNDCLOUD_BOOT_HOOK
    fi
fi
sh "$DIR/boot.sh" now
echo 'Installed: NewPipe SoundCloud, Alice voice bridge and v2rayNG.'
echo 'Change/import VLESS: sh /data/station1-soundcloud/vless.sh'
echo 'After importing, select the new profile in v2rayNG and connect. Confirm the Android VPN dialog on first use.'
echo 'Then say: Алиса, включи в Саундклауде название трека'
echo 'The first track starts in the background. Commands: стоп; продолжи; перемотай на 30 секунд.'
echo 'The selected VPN profile starts after reboot. Disable: sh /data/station1-soundcloud/install-soundcloud.sh vpn-autostart off'
echo 'No public proxies, reboot or Alice restart. Existing VPN settings are preserved.'
if [ -t 0 ]; then
    printf 'Import a VLESS key now? [y/N]: '
    IFS= read -r answer || answer=n
    case "$answer" in y|Y|yes|YES|д|Д|да|Да) sh "$DIR/vless.sh";; esac
fi
