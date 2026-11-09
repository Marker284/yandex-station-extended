#!/system/bin/sh
# Spotify TV + local Alice voice bridge for Station 1, Android 6 / SDK 23.
# Run one file in AliceBridge. No VPN, metrics blocking, rootfs or audio settings changed.
# Rollback: sh /data/station1-spotify/install.sh uninstall (Spotify/login are preserved).
set -eu
export ANDROID_DATA=/data ANDROID_ROOT=/system EXTERNAL_STORAGE=/sdcard ANDROID_STORAGE=/storage
export PATH=/opt/bin:/opt/sbin:/system/bin:/sbin:/bin
DIR=/data/station1-spotify
BB=/sbin/busybox
START=/data/dropbear/start.sh
MODE=${1:-install}
[ "$(id -u)" = 0 ] || { echo 'Run in the root AliceBridge terminal'; exit 1; }
[ -x "$BB" ] || exit 1
stop_voice() {
    if [ -f "$DIR/voice.pid" ]; then
        pid=$(cat "$DIR/voice.pid")
        case "$pid" in ''|*[!0-9]*) ;; *)
            if [ -r "/proc/$pid/cmdline" ] && "$BB" tr '\000' ' ' < "/proc/$pid/cmdline" | "$BB" grep -q 'SpotifyVoice /data/station1-spotify'; then kill "$pid"; fi;;
        esac
        rm -f "$DIR/voice.pid"
    fi
}
case "$MODE" in
    status|account|login|pair|logout|reconnect|open)
        shift || true; exec sh "$DIR/control.sh" "$MODE" "$@";;
    disable)
        mkdir -p "$DIR"; : > "$DIR/disabled"; stop_voice
        sh "$DIR/control.sh" pause >/dev/null 2>&1 || true
        echo 'Spotify voice bridge disabled'; exit 0;;
    enable|repair)
        rm -f "$DIR/disabled"; sh "$DIR/boot.sh"; echo 'Spotify bridge started'; exit 0;;
    uninstall)
        mkdir -p "$DIR"; : > "$DIR/disabled"; stop_voice
        sh "$DIR/control.sh" pause >/dev/null 2>&1 || true
        if [ -f "$START" ]; then
            "$BB" grep -v '# station1-spotify$' "$START" > "$DIR/start.new" || true
            cat "$DIR/start.new" > "$START"; rm -f "$DIR/start.new"
        fi
        echo 'Spotify bridge stopped and removed from autostart.'
        echo 'Spotify app, account, helpers and backups are preserved. Use logout to remove the account.'
        exit 0;;
    install|repair-app) ;;
    *) echo 'Usage: install.sh install|status|login|logout|reconnect|disable|enable|repair|repair-app|uninstall'; exit 1;;
esac
case "$(getprop ro.product.device)" in tulip*) ;; *) echo 'Only Station 1 / tulip is supported'; exit 1;; esac
[ "$(getprop ro.build.version.sdk)" = 23 ] || { echo 'Expected Android SDK 23'; exit 1; }
[ -f "$START" ] || { echo 'AliceBridge startup hook missing'; exit 1; }
work=/data/local/tmp/station1-spotify-install.$$
mkdir -p "$work" "$DIR/backups"
chmod 755 "$work"; chmod 700 "$DIR" "$DIR/backups"
cleanup() {
    if [ -n "${session:-}" ]; then pm install-abandon "$session" >/dev/null 2>&1 || true; fi
    rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM
"$BB" sed -n '/^begin-base64 644 payload.tar.gz$/,/^====$/p' "$0" | "$BB" uudecode -o "$work/payload.tar.gz"
echo '05040a201ffbda52ba89119e70e267f855c838ddb78c9b190066761154f3b28a  payload.tar.gz' > "$work/payload.sha256"
(cd "$work"; "$BB" sha256sum -c payload.sha256)
"$BB" gzip -dc "$work/payload.tar.gz" | "$BB" tar -xf - -C "$work"
(cd "$work"; "$BB" sha256sum -c files.sha256)
chmod 644 "$work/control.jar"
export CLASSPATH=$work/control.jar
if pm path com.spotify.tv.android 2>/dev/null | "$BB" grep -q '^package:'; then
    base=$(pm path com.spotify.tv.android | "$BB" sed -n 's/^package:\(.*\/base.apk\)$/\1/p' | "$BB" head -n 1)
    [ -n "$base" ] || { echo 'Cannot inspect the existing Spotify app'; exit 1; }
    app_process /system/bin SpotifyControl verify "$base" || {
        echo 'Existing Spotify app/version is preserved. This installer expects official Spotify TV 1.134.2.'; exit 1;
    }
    fresh=0
else
    fresh=1
fi
if [ "$fresh" = 1 ] || [ "$MODE" = repair-app ]; then
    echo 'Downloading original Spotify TV 1.134.2 (split APKs)...'
    /system/bin/curl -fL --user-agent 'Mozilla/5.0' --retry 2 --connect-timeout 15 --max-time 180 \
        --cacert /system/vendor/quasar/ca-certificates.crt \
        'https://d.apkpure.net/b/XAPK/com.spotify.tv.android?versionCode=2340200' -o "$work/spotify.xapk"
    echo 'cce2572683217186c4b96286e990851e47d236b2593d9b1004a54f9ef02cd24a  spotify.xapk' > "$work/spotify.sha256"
    (cd "$work"; "$BB" sha256sum -c spotify.sha256)
    app_process /system/bin SpotifyControl extract "$work/spotify.xapk" "$work"
    cat > "$work/apks.sha256" <<'HASHES'
509106d1df7638cf43ff0d76e11b8d4c2a24ca128fcb84f3c3b674ab255a8562  com.spotify.tv.android.apk
7a790ce7e20b4905b6617b2850de778af5d494440869acd93c61ecf6c8217721  config.armeabi_v7a.apk
b9916898804e4d8e38b104f4ad6b1e82064c42215ddd581c8efa68286ea660fa  config.en.apk
491bbd8a318bce5af2ef1dc04adba0c1eded3db6b5c85c68fcd13f52b4da89f0  config.ru.apk
1c26b246dd77b99394a66ba882b57619d2f49a3dc7de35a7cae80959e9f84b05  config.xhdpi.apk
HASHES
    (cd "$work"; "$BB" sha256sum -c apks.sha256)
    chmod 644 "$work"/*.apk
    app_process /system/bin SpotifyControl verify "$work/com.spotify.tv.android.apk"
    result=$(pm install-create -r)
    session=$(printf '%s' "$result" | "$BB" sed -n 's/.*\[\([0-9]*\)\].*/\1/p')
    [ -n "$session" ] || { printf '%s\n' "$result"; exit 1; }
    for file in com.spotify.tv.android.apk config.armeabi_v7a.apk config.en.apk config.ru.apk config.xhdpi.apk; do
        pm install-write "$session" "$file" "$work/$file"
    done
    pm install-commit "$session"; session=
fi
backup=$DIR/backups/$(date +%Y%m%d-%H%M%S)-$$
mkdir -p "$backup"
cp -p "$START" "$backup/start.sh"
for file in control.jar boot.sh control.sh install.sh; do
    [ ! -f "$DIR/$file" ] || cp -p "$DIR/$file" "$backup/$file"
done
stop_voice
for file in control.jar boot.sh control.sh; do cp "$work/$file" "$DIR/$file.new"; mv "$DIR/$file.new" "$DIR/$file"; done
chmod 600 "$DIR/control.jar"; chmod 700 "$DIR/boot.sh" "$DIR/control.sh"
cp "$0" "$DIR/install.sh.new"; chmod 700 "$DIR/install.sh.new"; mv "$DIR/install.sh.new" "$DIR/install.sh"
"$BB" grep -q '# station1-spotify$' "$START" || printf '\nsh /data/station1-spotify/boot.sh >/dev/null 2>&1 & # station1-spotify\n' >> "$START"
rm -f "$DIR/disabled"
sh "$DIR/boot.sh"
echo "Installed. Backup: $backup"
echo "Pairing code: sh $DIR/control.sh login"
echo "Account/status: sh $DIR/control.sh account"
echo "Sign out: sh $DIR/control.sh logout"
[ "$fresh" != 1 ] || sh "$DIR/control.sh" login || true
exit 0
begin-base64 644 payload.tar.gz
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
====
