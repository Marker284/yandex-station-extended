#!/bin/sh
# Short oneshot hooks only. Persistent daemons belong in their own systemd units.
set -eu
[ "$(id -u)" = 0 ] || exit 1
STATE=/data/jbl-autostart
[ ! -e "$STATE/disabled" ] || exit 0
[ "$(stat -c '%u:%g:%a' "$STATE/hooks.d")" = 0:0:700 ] || exit 1
for hook in "$STATE"/hooks.d/*.sh; do
    [ -f "$hook" ] || continue
    [ ! -L "$hook" ] || exit 1
    case "$(stat -c '%u:%g:%a' "$hook")" in
        0:0:700|0:0:755) ;;
        *) echo "Unsafe hook permissions: $hook" >&2; exit 1 ;;
    esac
    echo "START $hook"
    /bin/sh "$hook"
    echo "DONE $hook"
done
