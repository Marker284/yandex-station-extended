#!/bin/sh
# hackalice.me/install.sh — short address for the YAM installer (https://github.com/nyakokitsu/yam).
# GitHub Pages cannot do HTTP redirects, so this script fetches the current install.sh from the
# YAM repository (branch main) and runs it with the same arguments and environment:
#   curl -fsSL https://hackalice.me/install.sh | sh
#   curl -fsSL https://hackalice.me/install.sh | sh -s -- --remove-old
#   curl -fsSL https://hackalice.me/install.sh | YAM_PLATFORM=yandexmini_2 sh
set -eu
URL=https://raw.githubusercontent.com/nyakokitsu/yam/refs/heads/main/install.sh
tmp=$(mktemp "${TMPDIR:-/tmp}/yam-install.XXXXXX")
trap 'rm -f "$tmp"' EXIT HUP INT TERM
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$URL" -o "$tmp"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$tmp" "$URL"
else
  echo 'curl or wget is required.' >&2; exit 4
fi
sh "$tmp" "$@"
