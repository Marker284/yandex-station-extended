#!/bin/sh
# Called by the native Fluent Bit input plugin; never wait for user hooks here.
set -eu
[ "$(id -u)" = 0 ] || exit 0
STATE=/data/jbl-autostart
UNIT=/run/systemd/system/jbl-autostart.service
[ ! -e "$STATE/disabled" ] || exit 0
[ -f "$STATE/managed-by-jbl-link-portable" ] || exit 1
if systemctl is-active --quiet jbl-autostart.service; then
    exit 0
fi
umask 077
if [ -e "$UNIT" ]; then
    cmp -s "$STATE/jbl-autostart.service" "$UNIT" || exit 1
else
    (set -C; cat "$STATE/jbl-autostart.service" > "$UNIT")
fi
systemctl daemon-reload
systemctl --no-block start jbl-autostart.service
