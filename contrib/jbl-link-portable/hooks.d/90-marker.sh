#!/bin/sh
# A harmless runtime marker verifies execution of ordinary startup scripts.
set -eu
umask 077
cat /proc/sys/kernel/random/boot_id > /run/jbl-autostart-hooks.boot-id
