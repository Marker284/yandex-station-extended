#!/bin/sh
# Foreground PulseAudio for Soloist (logs to stderr). The .pa file is a
# template: @RUN@ becomes the runtime directory from the settings.
O=$(cd "$(dirname "$0")" && pwd)
. "$O/lib.sh"
setup_env
sed "s#@RUN@#$RUN#g" "$O/etc/soloist.pa.in" > "$RUN/soloist.pa" || exit 1
exec "$O/lib/ld-linux-armhf.so.3" --library-path "$O/lib" "$O/bin/pulseaudio" \
    --daemonize=no -n -F "$RUN/soloist.pa" \
    --exit-idle-time=-1 --dl-search-path="$O/modules" --use-pid-file=no \
    --system=no --high-priority=no --realtime=no --log-target=stderr "$@"
