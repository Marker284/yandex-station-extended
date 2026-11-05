#!/usr/bin/env python3
"""Install the tested Fluent Bit /data hook; never changes rootfs or geometry.

Default is offline validation. --install edits the existing device.cfg in place,
preserves its original bytes, and protects it from regeneration with +i.
It does not delete vendor files or restart any process. Rollback is installed
before the config is changed. The local backup contains device-specific values.
"""
import argparse
import hashlib
from pathlib import Path
import re
import shlex
import struct
import subprocess

ROOT = Path(__file__).resolve().parent
STATE = "/data/jbl-autostart"
CFG = "/data/quasar/fluent-bit/device.cfg"
PLUGIN = ROOT / "build/flb-in_jbl_bootstrap.so"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install", action="store_true")
    parser.add_argument("--ssh-config", type=Path, help="Local OpenSSH config with a jbl alias")
    args = parser.parse_args()
    if args.install and (args.ssh_config is None or not args.ssh_config.is_file()):
        parser.error("--install requires --ssh-config pointing to an existing trusted SSH config")
    plugin = PLUGIN.read_bytes()
    if plugin[:7] != b"\x7fELF\x01\x01\x01" or struct.unpack_from("<H", plugin, 18)[0] != 40:
        raise ValueError("Expected ARM32 ELF plugin")
    if b"/data/jbl-autostart/bootstrap.sh" not in plugin or b"/run/jbl-fluent-probe/initialized" in plugin:
        raise ValueError("Wrong plugin variant")
    print(f"PLUGIN sha256={digest(plugin)} bytes={len(plugin)}", flush=True)
    if not args.install:
        print("PLAN: new files under /data/jbl-autostart; preserved in-place device.cfg edit; no device access")
        return
    ssh = ["ssh", "-F", str(args.ssh_config), "-o", "BatchMode=yes",
           "-o", "ConnectTimeout=5", "jbl"]

    def remote(command, data=None):
        try:
            result = subprocess.run(ssh + [command], input=data, capture_output=True, timeout=20)
        except subprocess.TimeoutExpired:
            raise RuntimeError("SSH step timed out; inspect before retry") from None
        if result.returncode:
            raise RuntimeError("SSH step failed; endpoint and config values omitted")
        return result.stdout

    guard = (f'test "$(id -u)" = 0 && test ! -e {STATE} && '
             f'test -f {CFG} && test ! -L {CFG} && '
             f'test "$(stat -c \'%u:%g:%a\' {CFG})" = 0:0:644 && '
             'test "$(cat /sys/class/ubi/ubi0_0/reserved_ebs)" = 237 && '
             'test "$(cat /sys/class/mtd/mtd8/name)" = ROOTFS1 && '
             'echo INSTALL_TARGET_OK')
    if remote(guard).strip() != b"INSTALL_TARGET_OK":
        raise RuntimeError("Unexpected target state")
    version = remote("cat /system/vendor/quasar/version_full").strip()
    if version != b"1.80.0.228.3676569159.20251219.":
        raise RuntimeError("Unreviewed firmware version")
    original = remote(f"cat {CFG}")
    if not original or any(not re.match(rb"^@SET device_(id|platform|crtFile)=", line)
                           for line in original.splitlines() if line.strip()):
        raise ValueError("Unexpected device.cfg structure")
    vendor = remote("cat /system/vendor/quasar/fluent-bit/logs.cfg")
    match = re.search(rb"(?m)^\[SERVICE\]\n(.*?)(?=^\[)", vendor, re.S)
    if not match or b"Plugins_File" in vendor:
        raise ValueError("Unexpected vendor logging configuration")
    service = (b"[SERVICE]\n" + match[1].rstrip() + b"\n    Plugins_File " +
               STATE.encode() + b"/plugins.conf\n\n[INPUT]\n    Name jbl_bootstrap\n")
    modified = original.rstrip() + b"\n@INCLUDE " + STATE.encode() + b"/fluent-service.cfg\n"
    # A zero-byte append open verifies the existing config is writable without
    # changing its contents; the file is required to exist by the guard above.
    remote(f"test -f {CFG} && : >> {CFG}")
    backup = ROOT / "private/device.cfg.original"
    backup.parent.mkdir(parents=True, exist_ok=True)
    with backup.open("xb") as stream:
        backup.chmod(0o600)
        stream.write(original)
    rollback = f'''#!/bin/sh
set -eu
[ "$(id -u)" = 0 ] || exit 1
CFG={CFG}
STATE={STATE}
[ "$(sha256sum "$CFG" | cut -d' ' -f1)" = {digest(modified)} ] || exit 1
[ "$(sha256sum "$STATE/device.cfg.original" | cut -d' ' -f1)" = {digest(original)} ] || exit 1
chattr -i "$STATE"
(set -C; : > "$STATE/disabled")
chattr +i "$STATE/disabled" "$STATE"
chattr -i "$CFG"
cat "$STATE/device.cfg.original" > "$CFG"
chmod 644 "$CFG"
chown 0:0 "$CFG"
sync
echo AUTOSTART_CONFIG_RESTORED_NO_VENDOR_FILES_DELETED
'''.encode()
    files = {
        "managed-by-jbl-link-portable": b"JBL /data autostart; rootfs untouched\n",
        "device.cfg.original": original,
        "rollback.sh": rollback,
        "flb-in_jbl_bootstrap.so": plugin,
        "plugins.conf": f"[PLUGINS]\n    Path {STATE}/flb-in_jbl_bootstrap.so\n".encode(),
        "fluent-service.cfg": service,
        "bootstrap.sh": (ROOT / "bootstrap.sh").read_bytes(),
        "run.sh": (ROOT / "run.sh").read_bytes(),
        "jbl-autostart.service": (ROOT / "jbl-autostart.service").read_bytes(),
        "hooks.d/10-ssh.sh": (ROOT / "hooks.d/10-ssh.sh").read_bytes(),
        "hooks.d/90-marker.sh": (ROOT / "hooks.d/90-marker.sh").read_bytes(),
    }
    remote(f"umask 077; mkdir {STATE} && mkdir {STATE}/hooks.d")
    for name, data in files.items():
        path = shlex.quote(f"{STATE}/{name}")
        remote(f"set -C; cat > {path}", data)
        mode = "700" if name.endswith(".sh") else "600"
        remote(f"chmod {mode} {path}")
    remote(f"chattr -R +i {STATE}")
    # Guard against a concurrent vendor rewrite between backup and installation.
    remote(f'test "$(sha256sum {CFG} | cut -d\' \' -f1)" = {digest(original)}')
    remote(f"cat > {CFG}", modified)
    remote(f"chattr +i {CFG}; sync")
    if remote(f"cat {CFG}") != modified:
        raise RuntimeError("Config readback mismatch; rollback is preserved on device")
    print("INSTALLED: config readback matches; vendor files preserved; no reboot/restart", flush=True)
    print(f"ROLLBACK: sh {STATE}/rollback.sh", flush=True)


if __name__ == "__main__":
    main()
