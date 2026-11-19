#!/usr/bin/env python3
"""Build the Spotify Soloist kit for Yandex Station Lite 1 (yandexmicro) on a PC.

Python 3.8+, standard library only; works on Windows, Linux and macOS (no dpkg,
no Docker). Steps:
  1. Debian index: dists/<dist>/InRelease -> SHA256 of main/binary-armhf/Packages.xz
     (signature checked only with --keyring; otherwise trust = HTTPS + hash chain).
  2. Dependency closure of libc6, libpulse0 and pulseaudio with Debian version
     constraints, alternatives and Provides; unsatisfiable -> error.
  3. Download the .deb files, each checked against the SHA256 from Packages.
  4. Extract only library and program files of data.tar.* into a fresh directory.
  5. ELF DT_NEEDED closure (RUNPATH/RPATH honoured) of soloist, pulseaudio,
     module-pipe-sink and module-native-protocol-unix; anything unresolved -> error.
  6. Lay out the kit exactly as /bkupgrade/data/local/opt/soloist with MANIFEST.sha256.
Soloist itself is downloaded from Spotify's CDN (or given with --soloist) and is
never stored in the repository.

usage: build-kit.py [--out kit] [--cache .cache] [--dist trixie]
                    [--mirror URL | --snapshot 20261108T000000Z]
                    [--soloist FILE_OR_URL] [--keyring debian-archive-keyring.gpg]
"""
import argparse
import hashlib
import io
import lzma
import os
import posixpath
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import time
import urllib.request

SOLOIST_URL = "https://soloist-builds.spotifycdn.com/soloist_release_arm32.tar.gz"
ROOTS = ["libc6", "libpulse0", "pulseaudio"]
# Packages that carry no shared library or program we run (maintainer scripts,
# tools, data, daemons). They are not downloaded; the ELF closure below fails
# loudly if one of them was needed after all.
SKIP = {
    "adduser", "debconf", "debconf-2.0", "init-system-helpers", "pulseaudio-utils",
    "lsb-base", "sysvinit-utils", "libc-bin", "dbus", "dbus-bin", "dbus-daemon",
    "dbus-session-bus", "default-dbus-session-bus", "dbus-user-session",
    "dbus-system-bus", "default-dbus-system-bus", "systemd", "systemd-sysv",
    "procps", "libpam-systemd", "rtkit", "libspa-0.2-modules",
}
ELF_ENTRIES = ["/usr/bin/pulseaudio", "@MODULES@/module-pipe-sink.so",
               "@MODULES@/module-native-protocol-unix.so"]
# glibc itself dlopen()s libgcc_s for pthread_cancel/pthread_exit and backtraces;
# no ELF lists it in DT_NEEDED, so it is added explicitly (error if absent).
DLOPEN_LIBS = ["libgcc_s.so.1"]
LIB_DIRS = ["/usr/lib/arm-linux-gnueabihf", "/lib/arm-linux-gnueabihf", "/usr/lib", "/lib"]
DEVICE_FILES = ["lib.sh", "soloist-svc.sh", "audio-gate.sh", "spotify-voice.sh", "volume-sync.sh",
                "run-pulse.sh", "run-soloist.sh", "install.sh", "S97soloist"]
DEVICE_ETC = ["soloist.pa.in", "soloist.conf.example"]
UA = {"User-Agent": "station-lite-soloist-build/1"}


class BuildError(Exception):
    pass


def say(*a):
    print(*a, flush=True)


# --- Debian version comparison (dpkg algorithm) --------------------------------
def _order(c):
    if c == "~":
        return -1
    if c.isdigit():
        return 0
    if c.isalpha():
        return ord(c)
    return ord(c) + 256


def _cmp_part(a, b):
    while a or b:
        na = re.match(r"\D*", a).group(0)
        nb = re.match(r"\D*", b).group(0)
        a, b = a[len(na):], b[len(nb):]
        for i in range(max(len(na), len(nb))):
            ca = _order(na[i]) if i < len(na) else 0
            cb = _order(nb[i]) if i < len(nb) else 0
            if ca != cb:
                return -1 if ca < cb else 1
        da = re.match(r"\d*", a).group(0)
        db = re.match(r"\d*", b).group(0)
        a, b = a[len(da):], b[len(db):]
        ia, ib = int(da or 0), int(db or 0)
        if ia != ib:
            return -1 if ia < ib else 1
    return 0


def vercmp(a, b):
    def split(v):
        e, _, rest = v.partition(":") if ":" in v else ("0", "", v)
        u, _, r = rest.rpartition("-") if "-" in rest else (rest, "", "0")
        return int(e or 0), u, r
    ea, ua, ra = split(a)
    eb, ub, rb = split(b)
    if ea != eb:
        return -1 if ea < eb else 1
    return _cmp_part(ua, ub) or _cmp_part(ra, rb)


def satisfies(ver, op, want):
    if op is None:
        return True
    c = vercmp(ver, want)
    return {"<<": c < 0, "<=": c <= 0, "=": c == 0, ">=": c >= 0, ">>": c > 0,
            "<": c <= 0, ">": c >= 0}[op]


# --- index parsing ----------------------------------------------------------------
def parse_stanzas(text):
    out, cur, key = [], {}, None
    for line in text.splitlines() + [""]:
        if not line.strip():
            if cur:
                out.append(cur)
            cur, key = {}, None
        elif line[0] in " \t":
            if key:
                cur[key] += "\n" + line.strip()
        else:
            key, _, v = line.partition(":")
            cur[key] = v.strip()
    return out


DEP_RE = re.compile(r"^\s*([a-z0-9][a-z0-9+.-]*)(?::[a-z0-9-]+)?\s*(?:\(\s*(<<|<=|=|>=|>>|<|>)\s*([^)\s]+)\s*\))?")


def parse_deps(field):
    groups = []
    for grp in field.split(","):
        alts = []
        for alt in grp.split("|"):
            alt = alt.strip()
            if not alt:
                continue
            m = DEP_RE.match(alt)
            if not m:
                raise BuildError(f"cannot parse dependency '{alt}'")
            alts.append((m.group(1), m.group(2), m.group(3)))
        if alts:
            groups.append(alts)
    return groups


class Index:
    def __init__(self, text):
        self.pkgs, self.provides = {}, {}
        for st in parse_stanzas(text):
            if "Package" not in st or "Version" not in st:
                continue
            self.pkgs.setdefault(st["Package"], []).append(st)
            for name, _op, ver in (a for g in parse_deps(st.get("Provides", "")) for a in g):
                self.provides.setdefault(name, []).append((st, ver))

    def candidates(self, name, op, ver):
        """Stanzas that satisfy name (op ver), highest version first."""
        c = [st for st in self.pkgs.get(name, []) if satisfies(st["Version"], op, ver)]
        for st, pver in self.provides.get(name, []):
            # dpkg: a versioned dependency is satisfied only by a versioned Provides
            if op is None or (pver is not None and satisfies(pver, op, ver)):
                c.append(st)
        return sorted(c, key=_VerKey, reverse=True)


class _VerKey:
    def __init__(self, st):
        self.v = st["Version"]

    def __lt__(self, o):
        return vercmp(self.v, o.v) < 0


def resolve(index, roots, skip=frozenset()):
    """Return {package: stanza}. Raises BuildError on anything unsatisfiable."""
    chosen = {}
    todo = [[(r, None, None)] for r in roots]
    while todo:
        alts = todo.pop()
        if any(a[0] in skip for a in alts):
            continue
        # already satisfied by something we picked?
        done = False
        for name, op, ver in alts:
            for st in index.candidates(name, op, ver):
                if chosen.get(st["Package"]) is st:
                    done = True
        if done:
            continue
        pick = None
        for name, op, ver in alts:
            for st in index.candidates(name, op, ver):
                prev = chosen.get(st["Package"])
                if prev is None:
                    pick = st
                    break
            if pick:
                break
        if pick is None:
            want = " | ".join(n + (f" ({o} {v})" if o else "") for n, o, v in alts)
            have = {n: [s["Version"] for s in index.pkgs.get(n, [])] for n, _, _ in alts}
            raise BuildError(f"unsatisfiable dependency: {want} (index has {have})")
        chosen[pick["Package"]] = pick
        for field in ("Pre-Depends", "Depends"):
            todo.extend(parse_deps(pick.get(field, "")))
    return chosen


# --- downloads ----------------------------------------------------------------------
def fetch(url, timeout=120):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def readb(path):
    with open(path, "rb") as f:
        return f.read()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def inrelease_content(raw):
    text = raw.decode("utf-8").replace("\r\n", "\n")
    if not text.startswith("-----BEGIN PGP SIGNED MESSAGE-----"):
        return text
    body = text.split("\n\n", 1)[1].split("\n-----BEGIN PGP SIGNATURE-----", 1)[0]
    return "\n".join(l[2:] if l.startswith("- ") else l for l in body.splitlines())


def verify_signature(path, keyring):
    for cmd in (["gpgv", "--keyring", keyring, path],
                ["gpg", "--no-default-keyring", "--keyring", keyring, "--verify", path]):
        try:
            r = subprocess.run(cmd, capture_output=True, text=True)
        except FileNotFoundError:
            continue
        if r.returncode == 0:
            return
        raise BuildError(f"InRelease signature check failed:\n{r.stderr.strip()}")
    raise BuildError("--keyring given but neither gpgv nor gpg is installed")


def load_index(mirror, dist, cache, keyring=None):
    raw = fetch(f"{mirror}/dists/{dist}/InRelease")
    path = os.path.join(cache, f"{dist}-InRelease")
    with open(path, "wb") as f:
        f.write(raw)
    if keyring:
        verify_signature(path, keyring)
        say("InRelease: signature OK")
    else:
        say("InRelease: signature NOT checked (no --keyring); trusting HTTPS + SHA256 chain")
    rel = parse_stanzas(inrelease_content(raw))[0]
    want = None
    for line in rel.get("SHA256", "").splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[2] == "main/binary-armhf/Packages.xz":
            want = parts[0]
    if not want:
        raise BuildError("InRelease has no SHA256 for main/binary-armhf/Packages.xz")
    xz = fetch(f"{mirror}/dists/{dist}/main/binary-armhf/Packages.xz")
    if sha256(xz) != want:
        raise BuildError("Packages.xz SHA256 does not match InRelease")
    say(f"Packages.xz: {len(xz)} bytes, SHA256 OK; release {rel.get('Version', '?')} of {rel.get('Date', '?')}")
    return Index(lzma.decompress(xz).decode("utf-8")), rel


def download_debs(mirror, chosen, cache):
    os.makedirs(cache, exist_ok=True)
    paths = {}
    for name in sorted(chosen):
        st = chosen[name]
        fn = os.path.join(cache, os.path.basename(st["Filename"]))
        data = readb(fn) if os.path.exists(fn) else None
        if data is None or sha256(data) != st["SHA256"]:
            data = fetch(f"{mirror}/{st['Filename']}")
            if sha256(data) != st["SHA256"]:
                raise BuildError(f"{name}: SHA256 mismatch for {st['Filename']}")
            with open(fn, "wb") as f:
                f.write(data)
        paths[name] = fn
    return paths


# --- .deb extraction ---------------------------------------------------------------
def ar_members(data):
    if data[:8] != b"!<arch>\n":
        raise BuildError("not an ar archive")
    pos = 8
    while pos + 60 <= len(data):
        hdr = data[pos:pos + 60]
        name = hdr[:16].decode().strip().rstrip("/")
        size = int(hdr[48:58].decode().strip())
        yield name, data[pos + 60:pos + 60 + size]
        pos += 60 + size + (size & 1)


def open_data_tar(name, body, deb):
    if name.endswith(".zst"):
        try:
            from compression import zstd  # Python 3.14+
            body = zstd.decompress(body)
        except ImportError:
            raise BuildError(f"{os.path.basename(deb)}: data.tar.zst needs Python 3.14+")
        return tarfile.open(fileobj=io.BytesIO(body), mode="r:")
    if not re.fullmatch(r"data\.tar(\.(xz|gz|bz2))?", name):
        raise BuildError(f"{os.path.basename(deb)}: unsupported member {name}")
    return tarfile.open(fileobj=io.BytesIO(body), mode="r:*")


def wanted_file(rel):
    return rel.startswith(("usr/lib/", "lib/")) or rel == "usr/bin/pulseaudio"


def extract(debs, root):
    """Extract libraries/programs of all debs into a FRESH root. Returns symlink map."""
    if os.path.exists(root):
        shutil.rmtree(root)
    os.makedirs(root)
    links = {}
    for deb in debs:
        found = False
        for name, body in ar_members(readb(deb)):
            if not name.startswith("data.tar"):
                continue
            found = True
            with open_data_tar(name, body, deb) as tf:
                for m in tf.getmembers():
                    rel = posixpath.normpath(m.name.lstrip("./"))
                    if rel.startswith("..") or rel.startswith("/") or rel == ".":
                        continue
                    if m.issym():
                        links["/" + rel] = m.linkname
                    elif m.islnk():
                        links["/" + rel] = "/" + m.linkname.lstrip("./")
                    elif m.isfile() and wanted_file(rel):
                        dst = os.path.join(root, *rel.split("/"))
                        os.makedirs(os.path.dirname(dst), exist_ok=True)
                        with open(dst, "wb") as out:
                            out.write(tf.extractfile(m).read())
        if not found:
            raise BuildError(f"{os.path.basename(deb)}: no data.tar member")
    return links


class Root:
    def __init__(self, root, links):
        self.root, self.links = root, links

    def resolve(self, p, depth=0):
        """Root path through recorded symlinks -> (root path, host path) or None."""
        if depth > 40:
            return None
        parts = p.strip("/").split("/")
        cur = "/"
        for i, part in enumerate(parts):
            nxt = posixpath.join(cur, part)
            if nxt in self.links:
                t = self.links[nxt]
                t = t if t.startswith("/") else posixpath.normpath(posixpath.join(cur, t))
                rest = "/".join(parts[i + 1:])
                return self.resolve(posixpath.join(t, rest) if rest else t, depth + 1)
            cur = nxt
        host = os.path.join(self.root, *cur.strip("/").split("/"))
        return (cur, host) if os.path.isfile(host) else None

    def glob_dir(self, pattern):
        """Directories matching a root path pattern with * in any component."""
        def host(p):
            return os.path.join(self.root, *p.strip("/").split("/"))
        cur = ["/"]
        for part in pattern.strip("/").split("/"):
            nxt = []
            for c in cur:
                if "*" not in part:
                    nxt.append(posixpath.join(c, part))
                    continue
                rx = re.escape(part).replace(r"\*", ".*")
                names = sorted(os.listdir(host(c))) if os.path.isdir(host(c)) else []
                nxt += [posixpath.join(c, n) for n in names if re.fullmatch(rx, n)]
            cur = nxt
        return [c for c in cur if os.path.isdir(host(c))]


# --- ELF -------------------------------------------------------------------------------
def elf_info(path):
    d = readb(path)
    if d[:4] != b"\x7fELF":
        raise BuildError(f"{path}: not an ELF file")
    if d[4] != 1 or d[5] != 1:
        raise BuildError(f"{path}: not a 32-bit little-endian ELF")
    machine, = struct.unpack_from("<H", d, 0x12)
    flags, = struct.unpack_from("<I", d, 0x24)
    shoff, = struct.unpack_from("<I", d, 0x20)
    shentsize, shnum = struct.unpack_from("<HH", d, 0x2E)
    secs = [struct.unpack_from("<IIIIIIIIII", d, shoff + i * shentsize) for i in range(shnum)]
    needed, soname, runpath = [], None, []
    dyn = next((s for s in secs if s[1] == 6), None)  # SHT_DYNAMIC
    if dyn is not None:
        so = secs[dyn[6]][4]
        for off in range(dyn[4], dyn[4] + dyn[5], 8):
            tag, val = struct.unpack_from("<iI", d, off)
            if tag == 0:
                break
            if tag in (1, 14, 15, 29):
                s = d[so + val:d.index(b"\0", so + val)].decode()
                if tag == 1:
                    needed.append(s)
                elif tag == 14:
                    soname = s
                else:
                    runpath.extend(x for x in s.split(":") if x)
    return {"machine": machine, "hardfloat": bool(flags & 0x400), "needed": needed,
            "soname": soname, "runpath": runpath}


def check_armhf(path, what):
    i = elf_info(path)
    if i["machine"] != 40 or not i["hardfloat"]:
        raise BuildError(f"{what}: not an ARM hard-float (armhf) ELF")
    return i


def elf_closure(rootfs, entries):
    """entries: [(label, root_path_or_None, host_path)] -> {soname: host_path}.
    Raises BuildError listing every unresolved soname."""
    libs, unresolved, queue = {}, {}, list(entries)
    while queue:
        label, rpath, host = queue.pop()
        info = check_armhf(host, label)
        dirs = []
        for rp in info["runpath"]:
            if "$ORIGIN" in rp or "${ORIGIN}" in rp:
                if rpath is None:
                    continue
                rp = rp.replace("${ORIGIN}", posixpath.dirname(rpath)).replace("$ORIGIN", posixpath.dirname(rpath))
            dirs.append(rp)
        for dep in info["needed"]:
            if dep in libs:
                continue
            hit = None
            for d in dirs + LIB_DIRS:
                hit = rootfs.resolve(posixpath.join(d, dep))
                if hit:
                    break
            if not hit:
                unresolved.setdefault(dep, []).append(label)
                continue
            libs[dep] = hit[1]
            queue.append((dep, hit[0], hit[1]))
    if unresolved:
        raise BuildError("unresolved libraries: " +
                         "; ".join(f"{k} (needed by {', '.join(sorted(set(v)))})" for k, v in sorted(unresolved.items())))
    return libs


def dlopen_hints(path, shipped):
    """Library names mentioned as strings but not in NEEDED: possible dlopen()."""
    names = set(m.decode() for m in re.findall(rb"lib[A-Za-z0-9_+.-]*\.so(?:\.[0-9]+)*", readb(path)))
    return sorted(n for n in names if n not in shipped and not n.endswith(".so"))


def verify_kit(out):
    """The kit as shipped: every ELF under bin/, lib/, modules/ finds each
    DT_NEEDED in lib/ (that is the loader's --library-path on the station)."""
    have = set(os.listdir(os.path.join(out, "lib")))
    missing = []
    for d in ("bin", "lib", "modules"):
        for f in sorted(os.listdir(os.path.join(out, d))):
            for n in elf_info(os.path.join(out, d, f))["needed"]:
                if n not in have:
                    missing.append(f"{d}/{f} -> {n}")
    if missing:
        raise BuildError("kit check: not in lib/: " + "; ".join(missing))


def check_armhf_bytes(data, cache):
    p = os.path.join(cache, "soloist.check")
    with open(p, "wb") as f:
        f.write(data)
    check_armhf(p, "soloist")


# --- Soloist ------------------------------------------------------------------------------
def get_soloist(src, cache):
    if src and os.path.isfile(src):
        data = readb(src)
        origin = os.path.abspath(src)
    else:
        url = src or SOLOIST_URL
        data = fetch(url, timeout=300)
        origin = url
        with open(os.path.join(cache, "soloist_release_arm32.tar.gz"), "wb") as f:
            f.write(data)
    if data[:4] == b"\x7fELF":
        return data, origin
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as tf:
        m = [x for x in tf.getmembers() if x.isfile() and posixpath.basename(x.name) == "soloist"]
        if len(m) != 1:
            raise BuildError(f"{origin}: expected exactly one 'soloist' file in the archive")
        return tf.extractfile(m[0]).read(), origin


# --- kit layout ---------------------------------------------------------------------------
def lf(data):
    return data.replace(b"\r\n", b"\n")


def layout(out, soloist, rootfs, libs, modules, device_dir, info):
    if os.path.exists(out):
        shutil.rmtree(out)
    for d in ("bin", "lib", "modules", "etc"):
        os.makedirs(os.path.join(out, d))

    def put(rel, data):
        with open(os.path.join(out, *rel.split("/")), "wb") as f:
            f.write(data)

    put("bin/soloist", soloist)
    put("bin/pulseaudio", readb(rootfs.resolve("/usr/bin/pulseaudio")[1]))
    for so, host in libs.items():
        put(f"lib/{so}", readb(host))
    for name, host in modules.items():
        put(f"modules/{name}", readb(host))
    for f in DEVICE_FILES:
        put(f, lf(readb(os.path.join(device_dir, f))))
    for f in DEVICE_ETC:
        put(f"etc/{f}", lf(readb(os.path.join(device_dir, f))))
    put("BUILD-INFO", info.encode("utf-8"))
    lines = []
    for dp, _dn, fns in os.walk(out):
        for fn in fns:
            p = os.path.join(dp, fn)
            rel = os.path.relpath(p, out).replace(os.sep, "/")
            lines.append(f"{sha256(open(p, 'rb').read())}  ./{rel}")
    put("MANIFEST.sha256", ("\n".join(sorted(lines, key=lambda l: l[66:])) + "\n").encode())
    return sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(out) for f in fs)


def build(a):
    os.makedirs(a.cache, exist_ok=True)
    mirror = f"https://snapshot.debian.org/archive/debian/{a.snapshot}" if a.snapshot else a.mirror.rstrip("/")
    index, rel = load_index(mirror, a.dist, a.cache, a.keyring)
    chosen = resolve(index, ROOTS, SKIP)
    say(f"dependency closure: {len(chosen)} packages, "
        f"{sum(int(s.get('Size', 0)) for s in chosen.values()) // 1048576} MB to download")
    debs = download_debs(mirror, chosen, a.cache)
    say(f"downloaded and checked {len(debs)} .deb (SHA256 from Packages)")
    rootdir = os.path.join(a.cache, "root")
    rootfs = Root(rootdir, extract(debs.values(), rootdir))
    mdirs = rootfs.glob_dir("/usr/lib/pulse-*/modules")
    if len(mdirs) != 1:
        raise BuildError(f"expected one PulseAudio modules dir, found {mdirs}")
    soloist, origin = get_soloist(a.soloist, a.cache)
    check_armhf_bytes(soloist, a.cache)
    if a.soloist_sha256 and sha256(soloist) != a.soloist_sha256.lower():
        raise BuildError(f"soloist SHA256 {sha256(soloist)} != expected {a.soloist_sha256}")
    spath = os.path.join(a.cache, "soloist.bin")
    with open(spath, "wb") as f:
        f.write(soloist)
    entries = [("soloist", None, spath)]
    modules = {}
    for e in ELF_ENTRIES:
        p = e.replace("@MODULES@", mdirs[0])
        hit = rootfs.resolve(p)
        if not hit:
            raise BuildError(f"{p} not found in the extracted packages")
        entries.append((posixpath.basename(p), hit[0], hit[1]))
        if "/modules/" in p:
            modules[posixpath.basename(p)] = hit[1]
    libs = elf_closure(rootfs, entries)
    for so in DLOPEN_LIBS:
        hit = next((h for h in (rootfs.resolve(posixpath.join(d, so)) for d in LIB_DIRS) if h), None)
        if not hit:
            raise BuildError(f"{so} (loaded by glibc at run time) not found in the packages")
        libs.update(elf_closure(rootfs, [(so, hit[0], hit[1])]))
        libs[so] = hit[1]
    hints = dlopen_hints(spath, set(libs))
    info = [f"built {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())}",
            f"debian {a.dist} armhf from {mirror}, release {rel.get('Version', '?')} {rel.get('Date', '?')}",
            f"soloist sha256 {sha256(soloist)} from {origin}",
            f"pulseaudio modules from {mdirs[0]}", "packages:"]
    info += [f"  {n} {chosen[n]['Version']} {chosen[n]['SHA256']}" for n in sorted(chosen)]
    size = layout(a.out, soloist, rootfs, libs, modules, a.device_dir, "\n".join(info) + "\n")
    verify_kit(a.out)
    say(f"libraries: {len(libs)}; modules: {', '.join(sorted(modules))}")
    if hints:
        say("note: soloist mentions these libraries but does not link them (possible dlopen, "
            "not shipped): " + ", ".join(hints))
    say(f"kit: {a.out} ({size / 1048576:.1f} MB), soloist sha256 {sha256(soloist)[:16]}...")
    return 0


def main(argv=None):
    here = os.path.dirname(os.path.abspath(__file__))
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--out", default="kit")
    p.add_argument("--cache", default=".cache")
    p.add_argument("--dist", default="trixie")
    p.add_argument("--mirror", default="https://deb.debian.org/debian")
    p.add_argument("--snapshot", help="snapshot.debian.org timestamp, e.g. 20261108T000000Z")
    p.add_argument("--soloist", help="local soloist binary/tarball or URL (default: Spotify CDN)")
    p.add_argument("--soloist-sha256", help="expected SHA256 of the soloist binary (pin a build)")
    p.add_argument("--keyring", help="Debian archive keyring to verify InRelease")
    p.add_argument("--device-dir", default=os.path.join(here, "..", "device"))
    a = p.parse_args(argv)
    try:
        return build(a)
    except BuildError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
