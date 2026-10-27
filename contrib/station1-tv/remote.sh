#!/system/bin/sh
# Веб-пульт: lighttpd (страница и CGI, порт 8080) + лаунчер при загрузке из /data/dropbear/tv.conf.
# BOOT_LAUNCHER=couchy — после загрузки открыть Couchy и выгрузить лаунчер Яндекса
# (голос Алисы при этом работать не будет). По умолчанию — alice, ничего не меняется.
# monkey не используется: пока он запущен, процесс Алисы (maind --platformd) перезапускается
# каждые 30–80 секунд. Повторный запуск безопасен.
# Отключить: убрать вызов из /data/dropbear/start.sh и перезагрузить.
export ANDROID_DATA=/data ANDROID_ROOT=/system PATH=/opt/bin:/opt/sbin:/system/bin:/sbin:/bin
BB=/sbin/busybox
/sbin/busybox pidof lighttpd >/dev/null || lighttpd -f /opt/etc/lighttpd/remote.conf

[ "$1" = now ] && exit 0
if [ "$($BB sed -n 's/^BOOT_LAUNCHER=//p' /data/dropbear/tv.conf 2>/dev/null)" = couchy ]; then
    i=0; while [ "$(getprop sys.boot_completed)" != 1 ] && [ $i -lt 120 ]; do sleep 2; i=$((i + 1)); done
    sleep 15  # дать лаунчеру Яндекса открыться, иначе он перекроет Couchy
    am start -n com.conreo.couchytv/.MainActivity >/dev/null 2>&1
    am force-stop ru.yandex.quasar.app
fi
