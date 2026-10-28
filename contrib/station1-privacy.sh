#!/system/bin/sh
# Station 1 / Android 6: limit analytics uploads with a reversible hosts bind mount.
# Does NOT stop Alice, edit quasar.cfg/launch.json, remount system RW or change DNS servers.
# Default: apply. Inspection: sh script.sh check. Undo: sh script.sh restore.
# Only exact analytics hostnames are blocked; this is not a complete privacy guarantee.
set -e
export ANDROID_DATA=/data ANDROID_ROOT=/system PATH=/system/bin:/sbin:/bin
umask 077
BB=/sbin/busybox
DIR=/data/station1-privacy
DEST=/system/etc/hosts
START=/data/dropbear/start.sh
MARK='station1-privacy-managed-v1'
MODE=${1:-apply}

check_device() {
    [ "$(id -u)" = 0 ] || { echo 'Root is required'; exit 1; }
    [ "$(getprop ro.board.platform)" = tulip ] && [ "$(getprop ro.build.version.sdk)" = 23 ] || { echo 'Only Station 1 / Android 6 is supported'; exit 1; }
}
status() {
    if $BB grep -q "$MARK" "$DEST"; then echo 'Analytics hosts block: active'; else echo 'Analytics hosts block: inactive'; fi
    echo 'Exact hosts: clck.yandex.net, clck.yasmina.yango.com,'
    echo 'report.appmetrica.yandex.net, startup.appmetrica.yandex.net,'
    echo 'startup.mobile.yandex.net,'
    echo 'report.appmetrica.yango.com, startup.appmetrica.yango.com'
    echo 'Voice/auth/update endpoints and telemetry processes are unchanged.'
}
case "$MODE" in
    check|status) check_device; status; exit 0;;
    apply|boot|restore) check_device;;
    *) echo 'Usage: sh station1-privacy.sh [apply|check|restore]'; exit 1;;
esac
if [ "$MODE" = restore ]; then
    if $BB grep -q "$MARK" "$DEST"; then
        $BB test "$DEST" -ef "$DIR/hosts" || { echo 'Hosts were replaced by another tool; inspect them before restoring'; exit 1; }
        umount "$DEST" || { echo 'Cannot unmount managed hosts file; nothing else changed'; exit 1; }
    fi
    if [ -f "$START" ]; then
        $BB awk '!/station1-privacy-hook/' "$START" > "$START.privacy-new"
        chmod 700 "$START.privacy-new"
        mv "$START.privacy-new" "$START"
    fi
    echo 'Managed block and startup hook removed. Existing connections may need to reconnect.'
    exit 0
fi
[ -f "$START" ] || { echo 'AliceBridge startup hook is required'; exit 1; }
mkdir -p "$DIR"
chmod 700 "$DIR"
if [ "$MODE" != boot ]; then
    case "$0" in "$DIR/privacy.sh") ;; *) cp "$0" "$DIR/privacy.sh"; chmod 700 "$DIR/privacy.sh";; esac
fi
if ! $BB grep -q "$MARK" "$DEST"; then
    [ -s "$DIR/original-hosts" ] || cp -p "$DEST" "$DIR/original-hosts"
    {
        $BB awk '
            BEGIN { n=split("clck.yandex.net clck.yasmina.yango.com report.appmetrica.yandex.net startup.appmetrica.yandex.net startup.mobile.yandex.net report.appmetrica.yango.com startup.appmetrica.yango.com", a, " "); for(i=1;i<=n;i++) blocked[a[i]]=1 }
            /^[[:space:]]*#/ || NF<2 {print; next}
            { line=$1; keep=0; comment=""; for(i=2;i<=NF;i++) { if(substr($i,1,1)=="#") { for(j=i;j<=NF;j++) comment=comment " " $j; break } if(!blocked[tolower($i)]) {line=line " " $i; keep++} } if(keep) print line comment; else if(comment!="") print comment }
        ' "$DEST"
        printf '\n# %s\n' "$MARK"
        for host in clck.yandex.net clck.yasmina.yango.com report.appmetrica.yandex.net startup.appmetrica.yandex.net startup.mobile.yandex.net report.appmetrica.yango.com startup.appmetrica.yango.com; do
            printf '0.0.0.0 %s\n::1 %s\n' "$host" "$host"
        done
    } > "$DIR/hosts.new"
    chmod 644 "$DIR/hosts.new"
    mv "$DIR/hosts.new" "$DIR/hosts"
    mount -o bind "$DIR/hosts" "$DEST"
    if ! $BB grep -q "$MARK" "$DEST"; then umount "$DEST"; echo 'Mount verification failed'; exit 1; fi
fi
if [ "$MODE" != boot ] && ! $BB grep -q station1-privacy-hook "$START"; then
    cp -p "$START" "$DIR/start.before-privacy.sh"
    $BB awk 'NR==1 { print; print "/sbin/busybox setsid /system/bin/sh /data/station1-privacy/privacy.sh boot </dev/null >>/data/station1-privacy/start.log 2>&1 & # station1-privacy-hook"; next } { print }' "$START" > "$START.privacy-new"
    chmod 700 "$START.privacy-new"
    mv "$START.privacy-new" "$START"
fi
status
echo 'No reboot or Alice restart was performed.'
