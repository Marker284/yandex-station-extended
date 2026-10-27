#!/bin/sh
# Сборка AirPlay 2 для Яндекс Станции 2 (yandexmidi, aarch64) внутри alpine:3.24.
#
# Результат — самодостаточный набор /out/ap2/{bin,lib}, рассчитанный на путь
# /data/local/opt/ap2 на колонке: у каждого бинарника интерпретатор
# /data/local/opt/ap2/lib/ld-musl-aarch64.so.1 и RUNPATH $ORIGIN/../lib,
# поэтому ни обёртки с загрузчиком, ни LD_LIBRARY_PATH не нужны.
#
# Запуск с Mac:
#   docker run --rm --platform linux/arm64 -v "$PWD:/work" -v "$PWD/out:/out" \
#     alpine:3.24 sh /work/ap2-build.sh
set -eu

SPS_TAG=5.6.2
NQPTP_TAG=1.2.9
FFMPEG_TAG=n8.1.3
PREFIX=/data/local/opt/ap2
OUT=/out/ap2
SRC=/work/src
FFOUT=/work/ffout

echo "=== deps ==="
apk add --no-cache build-base autoconf automake libtool git pkgconf patchelf xxd \
  alsa-lib-dev popt-dev libconfig-dev soxr-dev openssl-dev avahi-dev \
  libplist-dev libplist-util libsodium-dev libgcrypt-dev util-linux-dev linux-headers \
  avahi dbus dropbear alsa-utils >/dev/null

mkdir -p "$SRC"
clone() { # url tag dir
  [ -d "$SRC/$3" ] || git clone -q --depth=1 -b "$2" "$1" "$SRC/$3"
}
clone https://github.com/FFmpeg/FFmpeg.git "$FFMPEG_TAG" ffmpeg
clone https://github.com/mikebrady/nqptp.git "$NQPTP_TAG" nqptp
clone https://github.com/mikebrady/shairport-sync.git "$SPS_TAG" shairport-sync

if [ ! -f "$FFOUT/lib/libavcodec.a" ]; then
  echo "=== ffmpeg $FFMPEG_TAG (только aac/alac, статически) ==="
  cd "$SRC/ffmpeg"
  [ -f config.h ] && make distclean >/dev/null 2>&1 || true
  ./configure --prefix="$FFOUT" \
    --disable-everything --disable-programs --disable-doc --disable-network \
    --disable-avdevice --disable-avfilter --disable-swscale \
    --disable-autodetect --disable-shared --enable-static --enable-pic \
    --enable-decoder=aac,alac --enable-parser=aac \
    --enable-demuxer=mov --enable-protocol=file \
    >/tmp/ffcfg.log 2>&1 || { tail -30 /tmp/ffcfg.log; exit 1; }
  make -j"$(nproc)" >/tmp/ffmake.log 2>&1 || { tail -30 /tmp/ffmake.log; exit 1; }
  make install >/dev/null
fi

if [ ! -x "$SRC/nqptp/nqptp" ]; then
  echo "=== nqptp $NQPTP_TAG ==="
  cd "$SRC/nqptp"
  autoreconf -fi >/dev/null 2>&1
  ./configure >/dev/null
  make -j"$(nproc)" >/tmp/nqmake.log 2>&1 || { tail -30 /tmp/nqmake.log; exit 1; }
fi

echo "=== shairport-sync $SPS_TAG (AirPlay 2) ==="
cd "$SRC/shairport-sync"
make distclean >/dev/null 2>&1 || true
autoreconf -fi >/dev/null 2>&1
PKG_CONFIG_PATH="$FFOUT/lib/pkgconfig" ./configure --sysconfdir=/etc \
  --with-alsa --with-soxr --with-avahi --with-ssl=openssl \
  --with-airplay-2 --with-metadata --with-piddir=/run \
  >/tmp/spscfg.log 2>&1 || { tail -40 /tmp/spscfg.log; exit 1; }
make -j"$(nproc)" >/tmp/spsmake.log 2>&1 || { tail -40 /tmp/spsmake.log; exit 1; }

echo "=== сборка набора ==="
rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/lib"
cp "$SRC/shairport-sync/shairport-sync" "$SRC/nqptp/nqptp" "$OUT/bin/"
for b in /usr/sbin/avahi-daemon /usr/bin/dbus-daemon /usr/bin/dbus-send \
         /usr/sbin/dropbear /usr/bin/dropbearkey /usr/bin/aplay /usr/bin/amixer \
         /usr/bin/speaker-test; do
  cp "$b" "$OUT/bin/"
done
strip "$OUT/bin/"* 2>/dev/null || true

# Замыкание зависимостей: ldd всех бинарников, пока список не перестанет расти.
: > /tmp/libs
while :; do
  before=$(wc -l < /tmp/libs)
  for f in "$OUT/bin/"* $(cat /tmp/libs); do
    ldd "$f" 2>/dev/null | awk '/=>/ { print $3 }'
  done | grep -v '^$' | sort -u > /tmp/libs.new
  cat /tmp/libs /tmp/libs.new | sort -u > /tmp/libs.all
  mv /tmp/libs.all /tmp/libs
  [ "$(wc -l < /tmp/libs)" -eq "$before" ] && break
done
while read -r l; do cp -L "$l" "$OUT/lib/"; done < /tmp/libs
cp -L /lib/ld-musl-aarch64.so.1 "$OUT/lib/"
ln -sf ld-musl-aarch64.so.1 "$OUT/lib/libc.musl-aarch64.so.1"

for f in "$OUT/bin/"*; do
  patchelf --set-interpreter "$PREFIX/lib/ld-musl-aarch64.so.1" \
           --set-rpath '$ORIGIN/../lib' "$f"
done

echo "=== версии ==="
"$SRC/shairport-sync/shairport-sync" -V
"$SRC/nqptp/nqptp" -V
echo "библиотек: $(ls "$OUT/lib" | wc -l), размер: $(du -sh "$OUT" | cut -f1)"
echo "=== DONE $(date) ==="
