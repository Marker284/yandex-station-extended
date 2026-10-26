# shairport-sync (AirPlay 2 + D-Bus) и nqptp для Станции Лайт 2 (userspace armhf, glibc 2.30).
# Кросс-сборка в Debian buster: glibc 2.28 не новее системной, бинарники идут на штатной libc
# и штатной libasound (общий dmix с Алисой). glib/gio/OpenSSL/zlib/dbus — системные колонки;
# ffmpeg (только AAC/ALAC) и libplist — статически; прочее — в lib/ рядом, RUNPATH=$ORIGIN/../lib.
FROM debian:buster
ARG SPS=5.6.2
ARG NQPTP=1.2.9
ARG FFMPEG=6.1.2
ARG PLIST=2.8.0
RUN printf 'deb http://archive.debian.org/debian buster main\ndeb http://archive.debian.org/debian-security buster/updates main\n' > /etc/apt/sources.list \
 && dpkg --add-architecture armhf && apt-get update && apt-get install -y --no-install-recommends \
    crossbuild-essential-armhf pkg-config autoconf automake libtool git ca-certificates curl xz-utils \
    xxd libglib2.0-dev-bin libplist-utils patchelf \
    libpopt-dev:armhf libconfig-dev:armhf libasound2-dev:armhf libavahi-client-dev:armhf \
    libssl-dev:armhf libsoxr-dev:armhf libsodium-dev:armhf libgcrypt20-dev:armhf uuid-dev:armhf \
    libglib2.0-dev:armhf
# autoconf под --host не проверяет malloc(0) и подставляет несуществующий rpl_malloc
ENV HOST=arm-linux-gnueabihf PREFIX=/opt/deps \
    ac_cv_func_malloc_0_nonnull=yes ac_cv_func_realloc_0_nonnull=yes
ENV PKG_CONFIG_LIBDIR=/opt/deps/lib/pkgconfig:/usr/lib/arm-linux-gnueabihf/pkgconfig:/usr/share/pkgconfig
WORKDIR /src
RUN curl -fsSL https://ffmpeg.org/releases/ffmpeg-$FFMPEG.tar.xz | tar xJ && cd ffmpeg-$FFMPEG \
 && ./configure --prefix=$PREFIX --enable-cross-compile --arch=arm --cpu=cortex-a53 --target-os=linux \
    --cross-prefix=$HOST- --pkg-config=pkg-config --disable-everything --disable-programs --disable-doc \
    --disable-autodetect --disable-shared --enable-static --enable-pic \
    --enable-decoder=aac,alac --enable-parser=aac --enable-demuxer=mov --enable-protocol=file \
    --enable-swresample \
 && make -j"$(nproc)" && make install
RUN git clone -q --depth 1 -b $PLIST https://github.com/libimobiledevice/libplist && cd libplist \
 && ./autogen.sh --host=$HOST --prefix=$PREFIX --without-cython --disable-shared --enable-static \
    --with-pic >/dev/null && make -j"$(nproc)" && make install
RUN git clone -q --depth 1 -b $NQPTP https://github.com/mikebrady/nqptp && cd nqptp \
 && autoreconf -fi && ./configure --host=$HOST && make -j"$(nproc)"
RUN git clone -q --depth 1 -b $SPS https://github.com/mikebrady/shairport-sync && cd shairport-sync \
 && autoreconf -fi && ./configure --host=$HOST --sysconfdir=/etc \
    --with-alsa --with-soxr --with-avahi --with-ssl=openssl --with-airplay-2 \
    --with-dbus-interface --with-mpris-interface --with-metadata \
    LIBS="-lm -lpthread" \
 && make -j"$(nproc)"
# Раскладка: bin/ + lib/ (только то, чего нет в системе колонки); RUNPATH и у библиотек —
# он действует только на прямые зависимости (libgcrypt -> libgpg-error)
RUN mkdir -p /out/bin /out/lib && cp shairport-sync/shairport-sync nqptp/nqptp /out/bin/ \
 && $HOST-strip /out/bin/* && patchelf --set-rpath '$ORIGIN/../lib' /out/bin/shairport-sync \
 && for l in libconfig.so.9 libpopt.so.0 libsoxr.so.0 libavahi-client.so.3 libavahi-common.so.3 \
      libsodium.so.23 libgcrypt.so.20 libgpg-error.so.0 libuuid.so.1; do \
      cp -L /usr/lib/$HOST/$l /out/lib/ 2>/dev/null || cp -L /lib/$HOST/$l /out/lib/; done \
 && $HOST-strip /out/lib/* \
 && for l in /out/lib/*; do patchelf --set-rpath '$ORIGIN' $l; done \
 && cp shairport-sync/scripts/shairport-sync-dbus-policy.conf /out/ 2>/dev/null || true
