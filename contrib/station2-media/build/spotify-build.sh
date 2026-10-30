#!/bin/sh
# Сборка librespot (Spotify Connect) для Станции 2 внутри alpine:3.24, aarch64-musl.
# Кладёт bin/librespot в /out/ap2 рядом с AirPlay 2: тот же загрузчик musl и RUNPATH,
# недостающие библиотеки докладываются в /out/ap2/lib. Сначала нужен ap2-build.sh.
#
# Запуск с Mac:
#   docker run --rm --platform linux/arm64 -v "$PWD:/work" -v "$PWD/out:/out" \
#     alpine:3.24 sh /work/spotify-build.sh
set -eu

LIBRESPOT_TAG=v0.8.0
FEATURES="alsa-backend with-avahi rustls-tls-webpki-roots"
PREFIX=/data/local/opt/ap2
OUT=/out/ap2
SRC=/work/src/librespot
export CARGO_HOME=/work/cargo-home
export CARGO_TARGET_DIR=/work/cargo-target

[ -x "$OUT/bin/shairport-sync" ] || { echo "нет $OUT — сначала ap2-build.sh"; exit 1; }

echo "=== deps ==="
apk add --no-cache build-base cargo rust pkgconf cmake perl linux-headers patchelf alsa-lib-dev \
  git >/dev/null
rustc --version

[ -d "$SRC" ] || git clone -q --depth=1 -b "$LIBRESPOT_TAG" https://github.com/librespot-org/librespot.git "$SRC"

echo "=== librespot $LIBRESPOT_TAG ($FEATURES) ==="
cd "$SRC"
cargo build --release --locked --no-default-features --features "$FEATURES" \
  >/tmp/cargo.log 2>&1 || { tail -40 /tmp/cargo.log; exit 1; }
BIN=$CARGO_TARGET_DIR/release/librespot
"$BIN" --version

cp "$BIN" "$OUT/bin/librespot"
strip "$OUT/bin/librespot"
for l in $(ldd "$OUT/bin/librespot" | awk '/=>/ { print $3 }'); do
  [ -f "$OUT/lib/${l##*/}" ] || cp -L "$l" "$OUT/lib/"
done
patchelf --set-interpreter "$PREFIX/lib/ld-musl-aarch64.so.1" \
         --set-rpath '$ORIGIN/../lib' "$OUT/bin/librespot"
readelf -d "$OUT/bin/librespot" | grep NEEDED
ls -l "$OUT/bin/librespot"
echo "=== DONE $(date) ==="
