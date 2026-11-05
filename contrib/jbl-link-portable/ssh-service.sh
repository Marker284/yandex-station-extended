#!/bin/sh
# Manage an installed Dropbear using a transient systemd unit on Yocto.
# Tested on JBL Link Portable with Alice, 1.80.0.228.3676569159.20251219.
# Pass stop to stop only the managed SSH service, retaining installed keys/files.
set -eu
umask 077

STATE=/data/jbl-ssh
UNIT=/run/systemd/system/jbl-ssh.service
PERSISTENT_UNIT=/etc/systemd/system/jbl-ssh.service
ACTION=${1:-status}

fail() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || fail 'Root required'

secure_path() {
    path=$1
    mode=$2
    [ ! -L "$path" ] || fail "Refusing symlink: $path"
    [ "$(stat -c '%u:%g:%a' "$path")" = "0:0:$mode" ] ||
        fail "Unexpected owner or mode: $path (expected root:root $mode)"
}

case "$ACTION" in
    start|prepare)
        secure_path "$STATE" 700
        secure_path "$STATE/auth" 700
        secure_path "$STATE/auth/authorized_keys" 600
        secure_path "$STATE/host_ed25519" 600
        secure_path "$STATE/bin" 700
        secure_path "$STATE/bin/dropbear" 755
        [ -s "$STATE/auth/authorized_keys" ] || fail 'No authorized key'
        [ -s "$STATE/host_ed25519" ] || fail 'No host key'
        [ -x "$STATE/bin/dropbear" ] || fail 'Dropbear is not executable'
        # Dropbear rejects /data's stock system:users 775 parent permissions.
        # Keep /data unchanged and copy only the public key to a root-owned path.
        [ ! -L /run/jbl-ssh-auth ] || fail 'Runtime auth directory is a symlink'
        mkdir -p /run/jbl-ssh-auth
        secure_path /run/jbl-ssh-auth 700
        [ ! -L /run/jbl-ssh-auth/authorized_keys ] || fail 'Runtime authorized_keys is a symlink'
        cp "$STATE/auth/authorized_keys" /run/jbl-ssh-auth/authorized_keys
        chmod 600 /run/jbl-ssh-auth/authorized_keys
        if [ "$ACTION" = prepare ]; then
            echo JBL_SSH_PREPARED
            exit 0
        fi
        if [ -f "$PERSISTENT_UNIT" ]; then
            grep -Fxq '# Managed by jbl-link-portable ssh-service.sh' "$PERSISTENT_UNIT" ||
                fail 'Persistent unit belongs to another installation'
            systemctl start jbl-ssh.service
            systemctl is-active --quiet jbl-ssh.service
            echo JBL_SSH_STARTED
            exit 0
        fi
        if [ -e "$UNIT" ] || [ -L "$UNIT" ]; then
            [ ! -L "$UNIT" ] && grep -Fxq '# Managed by jbl-link-portable ssh-service.sh' "$UNIT" ||
                fail 'Existing runtime unit is not owned by this script'
        fi
        mkdir -p /run/systemd/system
        cat > "$UNIT" <<'UNIT'
# Managed by jbl-link-portable ssh-service.sh
[Unit]
Description=JBL Link Portable key-only SSH
After=network.target droproot_setup.service

[Service]
Type=simple
ExecStart=/bin/sh -c 'exec /data/jbl-ssh/bin/dropbear -F -s -D /run/jbl-ssh-auth -r /data/jbl-ssh/host_ed25519 -p 2222 -P /run/jbl-ssh.pid -K 60 2>>/run/jbl-ssh.log'
WorkingDirectory=/data/jbl-ssh
UMask=0077
Restart=on-failure
RestartSec=2
StandardOutput=journal
StandardError=journal
UNIT
        systemctl daemon-reload
        systemctl start jbl-ssh.service
        systemctl is-active --quiet jbl-ssh.service
        echo JBL_SSH_STARTED
        ;;
    status)
        systemctl is-active jbl-ssh.service || exit 1
        echo JBL_SSH_ACTIVE
        ;;
    stop)
        if { [ -f "$PERSISTENT_UNIT" ] && grep -Fxq '# Managed by jbl-link-portable ssh-service.sh' "$PERSISTENT_UNIT"; } ||
           { [ -f "$UNIT" ] && grep -Fxq '# Managed by jbl-link-portable ssh-service.sh' "$UNIT"; }; then
            systemctl stop jbl-ssh.service
        else
            fail 'Managed runtime unit not found'
        fi
        echo JBL_SSH_STOPPED
        ;;
    *) fail 'Usage: ssh-service.sh start|prepare|status|stop' ;;
esac
