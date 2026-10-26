#!/bin/sh
# Голосовые команды в Spotify: собирает alice-text и докладывает jq, curl и сертификаты для
# Spotify Web API в /out/ap2 (aarch64-musl, тот же загрузчик и RUNPATH, что у AirPlay 2).
# Сначала нужен ap2-build.sh.
#
# Запуск с Mac:
#   docker run --rm --platform linux/arm64 -v "$PWD:/work" -v "$PWD/out:/out" \
#     alpine:3.24 sh /work/voice-build.sh
set -eu

PREFIX=/data/local/opt/ap2
OUT=/out/ap2

[ -x "$OUT/bin/shairport-sync" ] || { echo "нет $OUT — сначала ap2-build.sh"; exit 1; }

apk add --no-cache build-base jq curl ca-certificates patchelf >/dev/null

gcc -O2 -Wall -Wextra -o "$OUT/bin/alice-text" /work/voice/alice-text.c
cp /usr/bin/jq /usr/bin/curl "$OUT/bin/"
cp /etc/ssl/certs/ca-certificates.crt "$OUT/lib/ca-certificates.crt"
strip "$OUT/bin/alice-text" "$OUT/bin/jq" "$OUT/bin/curl"

# ldd по каждому бинарнику и по уже скопированным библиотекам, пока список растёт
for b in alice-text jq curl; do
  for l in $(ldd "$OUT/bin/$b" | awk '/=>/ { print $3 }'); do
    [ -f "$OUT/lib/${l##*/}" ] || cp -L "$l" "$OUT/lib/"
  done
  patchelf --set-interpreter "$PREFIX/lib/ld-musl-aarch64.so.1" \
           --set-rpath '$ORIGIN/../lib' "$OUT/bin/$b"
done
for i in 1 2 3; do
  for f in "$OUT"/lib/*.so*; do
    for l in $(ldd "$f" 2>/dev/null | awk '/=>/ { print $3 }'); do
      [ -f "$OUT/lib/${l##*/}" ] || cp -L "$l" "$OUT/lib/"
    done
  done
done
ls -l "$OUT/bin/alice-text" "$OUT/bin/jq" "$OUT/bin/curl"
echo "=== DONE $(date) ==="
