#!/bin/sh
# Install key-only Dropbear on JBL Link Portable with Alice, firmware
# 1.80.0.228.3676569159.20251219. The underlying setup is device-tested;
# this packaging wrapper refuses an existing installation. It never edits /.
# Stop: sh /data/jbl-ssh/service.sh stop. Files and keys remain intact.
set -eu
STAGE=${1:?Usage: sh install-ssh.sh /tmp/jbl-ssh-install}
STATE=/data/jbl-ssh
fail() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || fail 'Root required'
[ "$(uname -m)" = armv7l ] || fail 'ARMv7 required'
[ "$(cat /system/vendor/quasar/version_full)" = 1.80.0.228.3676569159.20251219. ] ||
    fail 'Unreviewed firmware'
[ ! -e "$STATE" ] && [ ! -L "$STATE" ] || fail 'Installation already exists; no files replaced'
for name in dropbear dropbearkey authorized_keys ssh-service.sh; do
    [ -f "$STAGE/$name" ] && [ ! -L "$STAGE/$name" ] || fail "Missing regular file: $name"
done
[ "$(sha256sum "$STAGE/dropbear" | cut -d' ' -f1)" = \
    374be9f85dabfab4d1f649d553f45e6238973e272b447fd2d81c2ab24a654db2 ] || fail 'Wrong Dropbear'
[ "$(sha256sum "$STAGE/dropbearkey" | cut -d' ' -f1)" = \
    86dee7ca66376f9ff463dd3d455e8f248239becdeb46ea8f71886ef1eaa4d3e7 ] || fail 'Wrong dropbearkey'
grep -q '^ssh-ed25519 ' "$STAGE/authorized_keys" || fail 'Ed25519 public key required'
sh -n "$STAGE/ssh-service.sh"
umask 077
mkdir "$STATE"
mkdir "$STATE/bin" "$STATE/auth"
cp "$STAGE/dropbear" "$STATE/bin/dropbear"
cp "$STAGE/authorized_keys" "$STATE/auth/authorized_keys"
cp "$STAGE/ssh-service.sh" "$STATE/service.sh"
chmod 755 "$STATE/bin/dropbear" "$STATE/service.sh" "$STAGE/dropbearkey"
"$STAGE/dropbearkey" -t ed25519 -f "$STATE/host_ed25519" >/dev/null
chmod 600 "$STATE/host_ed25519" "$STATE/auth/authorized_keys"
chown -R 0:0 "$STATE"
chattr -R +i "$STATE"
sync
sh "$STATE/service.sh" start
