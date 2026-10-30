#!/bin/sh
# YouTube Music для Станции 2: собирает ytm-dec из build/ytm/ytm-dec.c на статических ffmpeg
# из ap2-build.sh (build/ffout) и кладёт его в /out/ap2/bin. Сам yt-dlp и Python ставятся на
# колонке (ytm-install.sh): Python — из Entware, yt-dlp — свежий релиз с GitHub.
#
# Запуск с Mac:
#   docker run --rm --platform linux/arm64 -v "$PWD:/work" -v "$PWD/out:/out" \
#     alpine:3.24 sh /work/ytm-build.sh
set -eu

PREFIX=/data/local/opt/ap2
OUT=/out/ap2
FFOUT=/work/ffout

[ -x "$OUT/bin/shairport-sync" ] || { echo "нет $OUT — сначала ap2-build.sh"; exit 1; }
[ -f "$FFOUT/lib/libavcodec.a" ] || { echo "нет $FFOUT — сначала ap2-build.sh"; exit 1; }

apk add --no-cache build-base patchelf >/dev/null

gcc -O2 -Wall -Wextra -I"$FFOUT/include" -o "$OUT/bin/ytm-dec" /work/ytm/ytm-dec.c \
  -L"$FFOUT/lib" -lavformat -lavcodec -lswresample -lavutil -lm
strip "$OUT/bin/ytm-dec"
patchelf --set-interpreter "$PREFIX/lib/ld-musl-aarch64.so.1" \
         --set-rpath '$ORIGIN/../lib' "$OUT/bin/ytm-dec"
readelf -d "$OUT/bin/ytm-dec" | grep NEEDED
ls -l "$OUT/bin/ytm-dec"
echo "=== DONE $(date) ==="
