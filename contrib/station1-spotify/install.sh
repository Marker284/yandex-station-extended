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
echo 'b0c1f9232f88b3e9c799e4471f8b8385e90682b46e19688a31ef325977d2eb84  payload.tar.gz' > "$work/payload.sha256"
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
X4fWX/KX/CV/yV/yl/xZ/j/fvQN5AFAAAA==
====
