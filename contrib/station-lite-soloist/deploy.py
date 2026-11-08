#!/usr/bin/env python3
"""Install a kit built by build/build-kit.py on Yandex Station Lite 1 over ADB.

Python 3.8+, standard library; needs `adb` in PATH and root ADB on the station.
  python deploy.py --kit kit --serial SPEAKER_IP:5555 --key soloist.key
  python deploy.py --kit kit --serial SPEAKER_IP:5555 --dry-run   # only look
Files that are already installed with the same SHA256 are hard-linked into the
staging dir instead of being copied (the kit is ~40 MB, /bkupgrade is small).
install.sh then runs detached on the station (an ADB drop must not kill it
halfway); this script follows its log. The API key is copied, never printed.
"""
import argparse
import os
import shlex
import subprocess
import sys
import time

TARGET = "/bkupgrade/data/local/opt/soloist"
APPLETS = ["sh", "sha256sum", "cmp", "setsid", "nohup", "mkfifo", "awk", "sed", "tail",
           "ln", "df", "mount", "ip", "nslookup", "tr", "wc"]
MAX_CMD = 900          # bytes per batched shell command (adbd limit is ~4 KB)
LOG = "/tmp/soloist-install.log"
RC = "/tmp/soloist-install.rc"


class Fail(Exception):
    pass


class Adb:
    def __init__(self, serial):
        self.serial = serial

    def _run(self, args, check=True, retry=True):
        cmd = ["adb"] + (["-s", self.serial] if self.serial else []) + args
        last = ""
        for attempt in range(6 if retry else 1):
            p = subprocess.run(cmd, capture_output=True)
            # adb shell on Windows ends lines with \r\r\n; drop every \r
            stdout = p.stdout.decode("utf-8", "replace").replace("\r", "")
            stderr = p.stderr.decode("utf-8", "replace").replace("\r", "")
            r = subprocess.CompletedProcess(cmd, p.returncode, stdout, stderr)
            out = r.stdout + r.stderr
            # adb's own connection errors, not errors of the command on the station
            err = r.stderr.strip().lower()
            transient = r.returncode != 0 and not r.stdout and (
                err.startswith(("error:", "adb: error")) and any(
                    s in err for s in ("offline", "not found", "closed", "no devices", "protocol fault",
                                       "connection reset", "unauthorized")))
            if r.returncode == 0 or not transient:
                if check and r.returncode != 0:
                    raise Fail(f"adb {' '.join(args[:2])} failed: {out.strip()[:300]}")
                return r.returncode, r.stdout
            last = out.strip()
            if self.serial and ":" in self.serial:
                subprocess.run(["adb", "connect", self.serial], capture_output=True)
            time.sleep(2 + attempt)
        raise Fail(f"ADB keeps failing: {last[:300]}")

    def sh_rc(self, script, retry=True):
        """Run a shell snippet -> (exit code, stdout). The code is echoed back
        because old adb versions do not pass it through; None = no marker
        (connection lost or output cut)."""
        _rc, out = self._run(["shell", f"{script}\necho __rc=$?"], check=False, retry=retry)
        lines = out.rstrip("\n").split("\n")
        if lines and lines[-1].startswith("__rc=") and lines[-1][5:].strip().isdigit():
            return int(lines[-1][5:]), "\n".join(lines[:-1])
        return None, out

    def sh(self, script, check=True, retry=True):
        code, body = self.sh_rc(script, retry=retry)
        if check and code != 0:
            raise Fail(f"on the station: {script.splitlines()[0][:80]}... -> rc={code}\n{body[-500:]}")
        return body

    def sh_batch(self, commands, limit=MAX_CMD):
        """Run many commands in chunks: the station's adbd (old protocol) drops
        a shell command longer than ~4 KB. Each chunk stops at the first error."""
        chunk = []
        for c in commands + [None]:
            if chunk and (c is None or len(" &&\n".join(chunk + [c])) > limit):
                self.sh(" &&\n".join(chunk))
                chunk = []
            if c is not None:
                chunk.append(c)

    def push(self, local, remote):
        self._run(["push", local, remote])


def read_manifest(kit):
    files = {}
    with open(os.path.join(kit, "MANIFEST.sha256"), encoding="utf-8") as f:
        for line in f:
            h, p = line.rstrip("\n").split("  ", 1)
            files[p[2:] if p.startswith("./") else p] = h
    return files


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--kit", required=True)
    ap.add_argument("--serial", help="adb serial, e.g. SPEAKER_IP:5555")
    ap.add_argument("--key", help="file with the Soloist API key (needed on a first install)")
    ap.add_argument("--target", default=TARGET)
    ap.add_argument("--no-start", action="store_true")
    ap.add_argument("--keep-old", action="store_true")
    ap.add_argument("--dry-run", action="store_true", help="check and plan only, change nothing")
    a = ap.parse_args(argv)
    try:
        return deploy(a)
    except Fail as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


def deploy(a):
    kit, target = a.kit, a.target.rstrip("/")
    stage = target + ".new"
    files = read_manifest(kit)
    for p in files:
        if not os.path.isfile(os.path.join(kit, *p.split("/"))):
            raise Fail(f"kit is incomplete: {p} missing (rebuild it)")
    if a.serial and ":" in a.serial:
        subprocess.run(["adb", "connect", a.serial], capture_output=True)
    adb = Adb(a.serial)

    # --- checks --------------------------------------------------------------------
    parent = target.rsplit("/", 1)[0] or "/"
    info = adb.sh(f"id -u; uname -m; df -k {shlex.quote(parent)} | tail -n 1")
    lines = info.splitlines()
    if lines[0].strip() != "0":
        raise Fail("ADB shell is not root")
    print(f"station: {lines[1].strip()}, {parent}: {lines[2].split()[3]} KB free")
    free_kb = int(lines[2].split()[3])
    missing = adb.sh("for c in " + " ".join(APPLETS) + "; do command -v $c >/dev/null || echo $c; done").split()
    if missing:
        raise Fail(f"busybox on the station lacks: {', '.join(missing)}")
    has_key = adb.sh(f"[ -s {shlex.quote(target)}/etc/api.key ] && echo yes || echo no").strip() == "yes"
    if not a.key and not has_key:
        raise Fail("no API key on the station yet: pass --key FILE")
    if a.key and not os.path.isfile(a.key):
        raise Fail(f"--key {a.key}: no such file")

    # --- what is already there -------------------------------------------------------
    q = shlex.quote(target)
    listing = adb.sh(f"[ -d {q} ] && cd {q} && for f in " + " ".join(shlex.quote(p) for p in sorted(files)) +
                     "; do [ -f \"$f\" ] && sha256sum \"$f\"; done; true")
    have = {}
    for line in listing.splitlines():
        parts = line.split()
        if len(parts) == 2:
            have[parts[1][2:] if parts[1].startswith("./") else parts[1]] = parts[0]
    link = sorted(p for p, h in files.items() if have.get(p) == h)
    push = sorted(p for p in files if p not in link)
    # allocated size (4 KB blocks) + copy of data/ (login) + margin
    push_kb = sum((os.path.getsize(os.path.join(kit, *p.split("/"))) + 4095) // 4096 * 4 for p in push) + 8
    data_kb = adb.sh(f"du -sk {q}/data 2>/dev/null | cut -f1; true").strip()
    need_kb = push_kb + (int(data_kb) if data_kb.isdigit() else 0) + 4096
    print(f"plan: {len(link)} files unchanged (hard links), {len(push)} to copy ({push_kb} KB)")
    if need_kb > free_kb:
        raise Fail(f"not enough space in {parent}: need ~{need_kb} KB, free {free_kb} KB")
    if a.dry_run:
        for p in push:
            print("  copy", p)
        print("dry run: nothing changed")
        return 0

    # --- stage ----------------------------------------------------------------------------
    s = shlex.quote(stage)
    dirs = sorted({posixpath_dir(p) for p in files if "/" in p})
    adb.sh(f"rm -rf {s} && mkdir -p " + " ".join(f"{s}/{d}" for d in dirs) + f" && chmod 700 {s}/etc")
    if link:
        adb.sh_batch([f"ln -f {q}/{p} {s}/{p}" for p in link])
    for i, p in enumerate(push, 1):
        adb.push(os.path.join(kit, *p.split("/")), f"{stage}/{p}")
        print(f"\r  copied {i}/{len(push)}", end="", flush=True)
    if push:
        print()
    adb.push(os.path.join(kit, "MANIFEST.sha256"), f"{stage}/MANIFEST.sha256")
    if a.key:
        adb.push(a.key, f"{stage}/etc/api.key")
        adb.sh(f"chmod 600 {s}/etc/api.key")
        print("  API key copied (not shown)")

    # --- install, detached ----------------------------------------------------------------
    opts = (" --no-start" if a.no_start else "") + (" --keep-old" if a.keep_old else "")
    # launched once, never retried: a retry after a dropped connection could
    # start a second installer (install.sh also refuses that with a lock)
    adb.sh(f"rm -f {LOG} {RC}; TARGET={q} setsid nohup sh -c "
           + shlex.quote(f"sh {shlex.quote(stage + '/install.sh')}{opts} > {LOG} 2>&1; echo $? > {RC}")
           # adbd hangs up the session as soon as the command ends; without the
           # pause the child dies before setsid detaches it (seen on the station)
           + " > /dev/null 2>&1 < /dev/null &\nsleep 2", retry=False)
    shown, deadline = 0, time.time() + 420
    while time.time() < deadline:
        time.sleep(3)
        try:
            code, out = adb.sh_rc(f"cat {LOG} 2>/dev/null; echo __end; cat {RC} 2>/dev/null")
        except Fail as e:
            print(f"  (ADB: {e}; still waiting)")
            continue
        if code is None or "__end" not in out:
            print("  (ADB output cut; still waiting)")
            continue
        log, _, rc = out.partition("__end")
        new = log.splitlines()[shown:]
        for line in new:
            print(line)
        shown += len(new)
        if rc.strip():
            return 0 if rc.strip() == "0" else 1
    raise Fail(f"install.sh did not finish in 7 min; see {LOG} on the station")


def posixpath_dir(p):
    return p.rsplit("/", 1)[0]


if __name__ == "__main__":
    sys.exit(main())
