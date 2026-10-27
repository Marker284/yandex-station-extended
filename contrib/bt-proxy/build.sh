#!/bin/sh
# Сборка bt-proxy: статический ARMv7 musl (работает и на 64-битных ядрах колонок).
# Нужны rustup-цель armv7-unknown-linux-musleabihf и cargo-zigbuild (zig как линкер).
set -e
cd "$(dirname "$0")"
rustup target add armv7-unknown-linux-musleabihf
cargo test
# пути исходников попадают в сообщения паник — не публиковать домашний каталог сборщика
RUSTFLAGS="--remap-path-prefix=$HOME=~ --remap-path-prefix=$PWD=bt-proxy" \
  cargo zigbuild --release --target armv7-unknown-linux-musleabihf
cp target/armv7-unknown-linux-musleabihf/release/bt-proxy ../bin/bt-proxy
