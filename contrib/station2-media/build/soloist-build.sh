#!/bin/sh
# Окружение для Spotify Soloist на Станции 2, внутри debian:trixie (arm64, glibc).
# Soloist — официальный клиент Spotify Connect, собран под glibc 2.38+ и выводит звук только
# в PulseAudio/PipeWire. На колонке 32-битный userland с glibc 2.30 и без PulseAudio, поэтому
# рядом кладём свой загрузчик glibc и PulseAudio с выходом в FIFO. Сам soloist здесь не
# качается: его берёт с CDN Spotify колонка (soloist.sh update), распространять его нельзя.
# Результат — /out/soloist/{lib,bin,modules}, около 18 МБ.
#
# Запуск с Mac:
#   docker run --rm --platform linux/arm64 -v "$PWD:/work" -v "$PWD/out:/out" \
#     debian:trixie sh /work/soloist-build.sh
set -eu

PREFIX=/data/local/opt/ap2/soloist
OUT=/out/soloist
L=/lib/aarch64-linux-gnu

echo "=== deps ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends pulseaudio pulseaudio-utils libatomic1 patchelf \
  >/dev/null 2>&1
ldd --version | head -1
pulseaudio --version

rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/bin" "$OUT/modules"

echo "=== glibc для soloist ==="
for f in ld-linux-aarch64.so.1 libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 \
         libatomic.so.1 libgcc_s.so.1; do
  cp -L "$L/$f" "$OUT/lib/"
done

echo "=== PulseAudio: выход в FIFO и сокет для клиента ==="
M=$(dirname "$(find /usr/lib -name module-pipe-sink.so | head -1)")
cp /usr/bin/pulseaudio /usr/bin/pactl "$OUT/bin/"
for m in module-native-protocol-unix module-pipe-sink libprotocol-native; do
  cp "$M/$m.so" "$OUT/modules/"
done
# soloist открывает libpulse через dlopen — кладём и её
LIBPULSE=$(find /usr/lib -name libpulse.so.0 | head -1)
for f in "$OUT"/bin/* "$OUT"/modules/*.so "$LIBPULSE"; do ldd "$f"; done |
  awk '/=>/ { print $3 }' | sort -u | while read -r l; do
    [ -f "$OUT/lib/${l##*/}" ] || cp -L "$l" "$OUT/lib/"
  done
cp -L "$LIBPULSE" "$OUT/lib/"

for f in "$OUT"/bin/*; do
  patchelf --set-interpreter "$PREFIX/lib/ld-linux-aarch64.so.1" --set-rpath "$PREFIX/lib" "$f"
done
for f in "$OUT"/modules/*.so "$OUT"/lib/*.so*; do
  case "$f" in */ld-linux-*|*/libc.so.6) continue ;; esac
  patchelf --set-rpath "$PREFIX/lib" "$f" 2>/dev/null || true
done

echo "библиотек: $(ls "$OUT/lib" | wc -l), размер: $(du -sh "$OUT" | cut -f1)"
echo "=== DONE $(date) ==="
