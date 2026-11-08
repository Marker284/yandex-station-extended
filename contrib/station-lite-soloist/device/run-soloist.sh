#!/bin/sh
# Foreground Spotify Soloist. The API key is read from etc/api.key (mode 600)
# and never echoed; Soloist only takes it as -k, so it is visible in ps.
# Extra args (e.g. -w 127.0.0.1:0, -v) are passed through.
O=$(cd "$(dirname "$0")" && pwd)
. "$O/lib.sh"
setup_env
KEYFILE="$O/etc/api.key"
[ -s "$KEYFILE" ] || { echo "soloist: no API key in $KEYFILE" >&2; exit 1; }
KEY=$(tr -d '\r\n\t ' < "$KEYFILE")
mkdir -p "$O/data"
# start at Alice's volume (else Soloist's own default, 40); SOLOIST_ARGS can override
INITIAL=""
if [ "$VOLUME_SYNC" = 1 ] && v=$(alice_volume); then INITIAL="-i $v"; fi
# shellcheck disable=SC2086  # SOLOIST_ARGS is a list of options on purpose
exec "$O/lib/ld-linux-armhf.so.3" --library-path "$O/lib" "$O/bin/soloist" \
    -n "$DEVICE_NAME" -k "$KEY" -D "$O/data" -C "$CACHE_DIR" -z "$CACHE_LIMIT_MB" \
    $INITIAL $SOLOIST_ARGS "$@"
