#!/bin/sh
# Ограничение отправки метрик на Fiero Hi (Linux-прошивка Станции Лайт): точные имена узлов
# аналитики направляются в 127.0.0.1 строками в /etc/hosts, между метками начала и конца.
# Алиса, quasar.cfg и DNS-серверы не меняются. Корень монтируется на запись только на время
# правки. Команды: apply — включить, check — состояние, restore — убрать свои строки.
set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
HOSTS=/etc/hosts
DIR=/data/opt/fiero-hi-privacy
BEGIN='# fiero-hi-privacy begin'
END='# fiero-hi-privacy end'
NAMES='startup.mobile.yandex.net startup.appmetrica.yandex.net report.appmetrica.yandex.net
clck.yandex.net startup.appmetrica.yango.com report.appmetrica.yango.com clck.yasmina.yango.com'

die() { echo "❌ $*"; exit 1; }
blocked() { grep -qxF "$BEGIN" "$HOSTS"; }
sha() { sha256sum < "$1" | cut -d' ' -f1; }
rw() { mount -o remount,rw / || die "не удалось смонтировать корень на запись"; }
ro() { sync; mount -o remount,ro / || echo "⚠️ корень остался смонтирован на запись"; }
# адрес, который получит программа: ping резолвит через /etc/hosts, как и libc в maind
addr() { ping -c 1 -W 1 "$1" 2>/dev/null | sed -n '1s/.*(\([0-9.]*\)).*/\1/p'; }

check() {
    if blocked; then echo "Блокировка: включена"; else echo "Блокировка: выключена"; fi
    for n in $NAMES; do
        a=$(addr "$n")
        printf '  %-32s %s\n' "$n" "${a:-не резолвится}"
    done
}

apply() {
    blocked && { echo "Уже включено."; check; return; }
    mount | grep -q ' on /etc/hosts ' && die "/etc/hosts подменён другим инструментом (mount), остановлено"
    mkdir -p "$DIR" || die "не создать $DIR"
    cp -p "$HOSTS" "$DIR/hosts.orig" && sha "$HOSTS" > "$DIR/hosts.orig.sha256" ||
        die "не сохранить копию hosts"
    rw
    {
        echo "$BEGIN"
        for n in $NAMES; do printf '127.0.0.1\t%s\n' "$n"; done
        echo "$END"
    } >> "$HOSTS" || { ro; die "не удалось дописать $HOSTS"; }
    ro
    echo "✅ Блокировка включена. Копия прежнего hosts: $DIR/hosts.orig"
    check
}

restore() {
    blocked || { echo "Блокировка не включена, менять нечего."; return; }
    rw
    sed -i "/^$BEGIN\$/,/^$END\$/d" "$HOSTS" || { ro; die "не удалось убрать строки из $HOSTS"; }
    ro
    if [ -s "$DIR/hosts.orig.sha256" ] && [ "$(sha "$HOSTS")" = "$(cat "$DIR/hosts.orig.sha256")" ]; then
        echo "✅ Блокировка снята, hosts совпадает с исходным (SHA-256)."
    else
        echo "⚠️ Блокировка снята, но hosts отличается от копии $DIR/hosts.orig — сравните вручную."
    fi
    check
}

case "${1:-}" in
    apply) apply ;;
    check) check ;;
    restore) restore ;;
    *) echo "Использование: sh $0 apply | check | restore"; exit 2 ;;
esac
