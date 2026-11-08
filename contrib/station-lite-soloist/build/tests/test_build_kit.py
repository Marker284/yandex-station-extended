"""Tests for build-kit.py: python -m unittest discover -s build/tests
Fixtures are synthetic but in the real formats: ar .deb with data.tar.xz,
clearsigned-style InRelease, xz Packages index, ELF32 ARM objects with
DT_NEEDED / DT_SONAME / DT_RUNPATH, symlink chains as Debian ships them.
"""
import hashlib
import importlib.util
import io
import lzma
import os
import pathlib
import shutil
import struct
import tarfile
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("buildkit", os.path.join(HERE, "..", "build-kit.py"))
bk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bk)
DEVICE = os.path.join(HERE, "..", "..", "device")


def make_elf(needed=(), soname=None, runpath=None, machine=40, flags=0x05000400):
    strtab = bytearray(b"\0")
    off = {}
    for s in list(needed) + [x for x in (soname, runpath) if x]:
        off[s] = len(strtab)
        strtab += s.encode() + b"\0"
    while len(strtab) % 4:
        strtab += b"\0"
    dyn = b"".join(struct.pack("<iI", 1, off[n]) for n in needed)
    if soname:
        dyn += struct.pack("<iI", 14, off[soname])
    if runpath:
        dyn += struct.pack("<iI", 29, off[runpath])
    dyn += struct.pack("<iI", 0, 0)
    str_off, dyn_off = 52, 52 + len(strtab)
    shoff = dyn_off + len(dyn)
    hdr = b"\x7fELF\x01\x01\x01" + b"\0" * 9 + struct.pack(
        "<HHIIIIIHHHHHH", 3, machine, 1, 0, 0, shoff, flags, 52, 32, 0, 40, 3, 0)
    sh = struct.pack("<10I", *[0] * 10)
    sh += struct.pack("<10I", 0, 3, 0, 0, str_off, len(strtab), 0, 0, 1, 0)
    sh += struct.pack("<10I", 0, 6, 0, 0, dyn_off, len(dyn), 1, 0, 4, 8)
    return hdr + bytes(strtab) + dyn + sh


def make_deb(files=None, links=None, comp="xz"):
    """files {path: bytes}, links {path: target} -> .deb bytes"""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:" + comp) as tf:
        for p, data in (files or {}).items():
            ti = tarfile.TarInfo("./" + p)
            ti.size = len(data)
            tf.addfile(ti, io.BytesIO(data))
        for p, t in (links or {}).items():
            ti = tarfile.TarInfo("./" + p)
            ti.type = tarfile.SYMTYPE
            ti.linkname = t
            tf.addfile(ti)
    members = [("debian-binary", b"2.0\n"), ("control.tar.xz", lzma.compress(b"")),
               (f"data.tar.{comp}", buf.getvalue())]
    out = b"!<arch>\n"
    for name, body in members:
        out += f"{name + '/':<16}{0:<12}{0:<6}{0:<6}{100644:<8}{len(body):<10}`\n".encode() + body
        if len(body) % 2:
            out += b"\n"
    return out


def stanza(pkg, ver, depends="", provides="", filename=None, data=b""):
    s = f"Package: {pkg}\nVersion: {ver}\nArchitecture: armhf\n"
    if depends:
        s += f"Depends: {depends}\n"
    if provides:
        s += f"Provides: {provides}\n"
    s += f"Filename: {filename or 'pool/' + pkg + '.deb'}\nSize: {len(data)}\n"
    s += f"SHA256: {hashlib.sha256(data).hexdigest()}\n"
    return s


class Tmp(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="bk-test-")

    def tearDown(self):
        shutil.rmtree(self.d, ignore_errors=True)


class VersionTests(unittest.TestCase):
    # Requirement: Debian ordering, or the wrong package version gets picked.
    def test_dpkg_ordering(self):
        cases = [("1.0~rc1", "1.0", -1), ("1:0.1", "2.0", 1), ("2.41-12", "2.41-6+b1", 1),
                 ("17.0+dfsg1-2+b1", "17.0+dfsg1-2", 1), ("1.0", "1.0-0", 0), ("1.2a", "1.2", 1),
                 ("2.41-12+deb13u1", "2.41-12", 1)]
        for a, b, want in cases:
            with self.subTest(a=a, b=b):
                self.assertEqual(bk.vercmp(a, b), want)


class ResolveTests(unittest.TestCase):
    def idx(self, *stanzas):
        return bk.Index("\n".join(stanzas))

    # Requirement: a version constraint the index cannot meet stops the build
    # (the old resolve.py ignored versions and went on).
    def test_unsatisfiable_version_is_an_error(self):
        i = self.idx(stanza("a", "1", "b (>= 2.0)"), stanza("b", "1.5"))
        with self.assertRaises(bk.BuildError) as e:
            bk.resolve(i, ["a"])
        self.assertIn("b (>= 2.0)", str(e.exception))

    # Requirement: with alternatives, the first one that is satisfiable wins
    # (the old resolver took the first one that merely existed).
    def test_alternative_skips_unsatisfiable_first(self):
        i = self.idx(stanza("a", "1", "x (>= 3) | y"), stanza("x", "2"), stanza("y", "1"))
        self.assertEqual(sorted(bk.resolve(i, ["a"])), ["a", "y"])

    def test_versioned_dep_needs_versioned_provides(self):
        i = self.idx(stanza("a", "1", "virt (>= 1)"), stanza("p", "1", provides="virt"),
                     stanza("q", "1", provides="virt (= 1.5)"))
        self.assertEqual(sorted(bk.resolve(i, ["a"])), ["a", "q"])

    def test_highest_version_when_index_has_two(self):
        i = self.idx(stanza("a", "1", "b"), stanza("b", "1.0"), stanza("b", "1.2"))
        self.assertEqual(bk.resolve(i, ["a"])["b"]["Version"], "1.2")

    def test_missing_package_is_an_error(self):
        i = self.idx(stanza("a", "1", "nothere"))
        with self.assertRaises(bk.BuildError):
            bk.resolve(i, ["a"])

    def test_skip_list(self):
        i = self.idx(stanza("a", "1", "adduser, b"), stanza("b", "1"))
        self.assertEqual(sorted(bk.resolve(i, ["a"], {"adduser"})), ["a", "b"])


class ExtractTests(Tmp):
    # Requirement: a second build starts from a clean tree; links and files of
    # packages that are no longer in the set must not survive (the old debx.py
    # appended to _symlinks.tsv on every run).
    def test_rebuild_starts_clean(self):
        d1 = os.path.join(self.d, "one.deb")
        d2 = os.path.join(self.d, "two.deb")
        open(d1, "wb").write(make_deb({"usr/lib/arm-linux-gnueabihf/libold.so.1.0": b"x"},
                                      {"usr/lib/arm-linux-gnueabihf/libold.so.1": "libold.so.1.0"}))
        open(d2, "wb").write(make_deb({"usr/lib/arm-linux-gnueabihf/libnew.so.2": b"y"}))
        root = os.path.join(self.d, "root")
        bk.extract([d1], root)
        links = bk.extract([d2], root)
        self.assertNotIn("/usr/lib/arm-linux-gnueabihf/libold.so.1", links)
        self.assertFalse(os.path.exists(os.path.join(root, "usr/lib/arm-linux-gnueabihf/libold.so.1.0")))

    def test_only_libraries_and_pulseaudio_extracted(self):
        deb = os.path.join(self.d, "p.deb")
        open(deb, "wb").write(make_deb({"usr/share/doc/p/copyright": b"c", "usr/bin/pulseaudio": b"p",
                                        "usr/bin/pactl": b"t", "usr/lib/arm-linux-gnueabihf/libp.so.0": b"l"}))
        root = os.path.join(self.d, "root")
        bk.extract([deb], root)
        got = sorted(str(p.relative_to(root)).replace(os.sep, "/") for p in pathlib.Path(root).rglob("*") if p.is_file())
        self.assertEqual(got, ["usr/bin/pulseaudio", "usr/lib/arm-linux-gnueabihf/libp.so.0"])

    def test_gz_data_member(self):
        deb = os.path.join(self.d, "g.deb")
        open(deb, "wb").write(make_deb({"usr/lib/libg.so.1": b"g"}, comp="gz"))
        bk.extract([deb], os.path.join(self.d, "root"))
        self.assertTrue(os.path.isfile(os.path.join(self.d, "root/usr/lib/libg.so.1")))


class ElfTests(Tmp):
    def root(self, files, links=None):
        r = os.path.join(self.d, "root")
        for p, data in files.items():
            h = os.path.join(r, *p.strip("/").split("/"))
            os.makedirs(os.path.dirname(h), exist_ok=True)
            open(h, "wb").write(data)
        return bk.Root(r, links or {})

    def entry(self, data):
        p = os.path.join(self.d, "entry.bin")
        open(p, "wb").write(data)
        return [("soloist", None, p)]

    # Requirement: an unresolved library stops the build and is named (the old
    # elfclosure.py printed it and exited 0, leaving a kit that cannot start).
    def test_unresolved_is_an_error(self):
        r = self.root({"/usr/lib/arm-linux-gnueabihf/libc.so.6": make_elf(soname="libc.so.6")})
        with self.assertRaises(bk.BuildError) as e:
            bk.elf_closure(r, self.entry(make_elf(["libc.so.6", "libpulse.so.0"])))
        self.assertIn("libpulse.so.0 (needed by soloist)", str(e.exception))

    # Requirement: libraries are found through Debian's symlink chains and
    # through RUNPATH (pulse modules live in a versioned directory).
    def test_symlink_chain_and_runpath(self):
        mod = "/usr/lib/pulse-17.0+dfsg1/modules"
        r = self.root({
            "/usr/lib/arm-linux-gnueabihf/libpulse.so.0.24.3": make_elf(["libc.so.6"], soname="libpulse.so.0"),
            "/usr/lib/arm-linux-gnueabihf/libc.so.6": make_elf(soname="libc.so.6"),
            mod + "/libprotocol-native.so": make_elf(["libc.so.6"]),
            mod + "/module-native-protocol-unix.so": make_elf(["libprotocol-native.so"], runpath=mod),
        }, {"/usr/lib/arm-linux-gnueabihf/libpulse.so.0": "libpulse.so.0.24.3"})
        libs = bk.elf_closure(r, self.entry(make_elf(["libpulse.so.0"])) +
                              [("m", mod + "/module-native-protocol-unix.so",
                                os.path.join(r.root, *(mod + "/module-native-protocol-unix.so").strip("/").split("/")))])
        self.assertEqual(sorted(libs), ["libc.so.6", "libprotocol-native.so", "libpulse.so.0"])
        self.assertTrue(libs["libpulse.so.0"].endswith("libpulse.so.0.24.3"))

    def test_wrong_architecture_rejected(self):
        with self.assertRaises(bk.BuildError):
            bk.elf_closure(self.root({}), self.entry(make_elf(machine=183)))  # aarch64
        with self.assertRaises(bk.BuildError):
            bk.elf_closure(self.root({}), self.entry(make_elf(flags=0x05000200)))  # soft-float

    def test_modules_dir_found_by_glob(self):
        r = self.root({"/usr/lib/pulse-18.1/modules/module-pipe-sink.so": make_elf()})
        self.assertEqual(r.glob_dir("/usr/lib/pulse-*/modules"), ["/usr/lib/pulse-18.1/modules"])


class EndToEndTests(Tmp):
    """Fake Debian mirror on file://, full build into a kit."""

    def test_full_build(self):
        m = os.path.join(self.d, "mirror")
        mod = "usr/lib/pulse-17.0+dfsg1/modules"
        L = "usr/lib/arm-linux-gnueabihf"
        debs = {
            "libc6": make_deb({f"{L}/libc.so.6": make_elf(["ld-linux-armhf.so.3"], soname="libc.so.6"),
                               f"{L}/ld-linux-armhf.so.3": make_elf(soname="ld-linux-armhf.so.3")},
                              {"usr/lib/ld-linux-armhf.so.3": "arm-linux-gnueabihf/ld-linux-armhf.so.3"}),
            "libgcc-s1": make_deb({f"{L}/libgcc_s.so.1": make_elf(["libc.so.6"], soname="libgcc_s.so.1")}),
            "libpulse0": make_deb({f"{L}/libpulse.so.0.24.3": make_elf(["libc.so.6"], soname="libpulse.so.0")},
                                  {f"{L}/libpulse.so.0": "libpulse.so.0.24.3"}),
            "pulseaudio": make_deb({"usr/bin/pulseaudio": make_elf(["libpulse.so.0", "libc.so.6"]),
                                    f"{mod}/module-pipe-sink.so": make_elf(["libc.so.6"]),
                                    f"{mod}/module-native-protocol-unix.so": make_elf(["libc.so.6"]),
                                    "usr/share/doc/pulseaudio/README": b"doc"}),
        }
        deps = {"libc6": "libgcc-s1", "libgcc-s1": "libc6 (>= 2.35)", "libpulse0": "libc6 (>= 2.38)", "pulseaudio": "libpulse0 (= 17.0+dfsg1-2), adduser"}
        vers = {"libc6": "2.41-12", "libgcc-s1": "14.2.0-19", "libpulse0": "17.0+dfsg1-2", "pulseaudio": "17.0+dfsg1-2"}
        os.makedirs(os.path.join(m, "pool"))
        text = ""
        for n, data in debs.items():
            open(os.path.join(m, "pool", n + ".deb"), "wb").write(data)
            text += stanza(n, vers[n], deps[n], data=data) + "\n"
        xz = lzma.compress(text.encode())
        ddir = os.path.join(m, "dists", "trixie", "main", "binary-armhf")
        os.makedirs(ddir)
        open(os.path.join(ddir, "Packages.xz"), "wb").write(xz)
        rel = ("Origin: Debian\nVersion: 13.7\nDate: Sat, 12 Sep 2026 07:55:41 UTC\nSHA256:\n"
               f" {hashlib.sha256(xz).hexdigest()} {len(xz)} main/binary-armhf/Packages.xz\n")
        open(os.path.join(m, "dists", "trixie", "InRelease"), "w", newline="\n").write(
            "-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA512\n\n" + rel +
            "-----BEGIN PGP SIGNATURE-----\nfake\n-----END PGP SIGNATURE-----\n")
        sol = os.path.join(self.d, "soloist")
        open(sol, "wb").write(make_elf(["libpulse.so.0", "libc.so.6"]) + b"\0libasound.so.2\0")
        out = os.path.join(self.d, "kit")
        rc = bk.main(["--out", out, "--cache", os.path.join(self.d, "cache"),
                      "--mirror", pathlib.Path(m).as_uri(), "--soloist", sol, "--device-dir", DEVICE])
        self.assertEqual(rc, 0)
        files = sorted(str(p.relative_to(out)).replace(os.sep, "/") for p in pathlib.Path(out).rglob("*") if p.is_file())
        for f in ["bin/soloist", "bin/pulseaudio", "lib/libc.so.6", "lib/ld-linux-armhf.so.3",
                  "lib/libpulse.so.0", "lib/libgcc_s.so.1", "modules/module-pipe-sink.so", "modules/module-native-protocol-unix.so",
                  "etc/soloist.pa.in", "soloist-svc.sh", "install.sh", "S97soloist", "MANIFEST.sha256"]:
            self.assertIn(f, files)
        self.assertNotIn("etc/api.key", files)
        manifest = open(os.path.join(out, "MANIFEST.sha256")).read().splitlines()
        for line in manifest:
            h, p = line.split("  ", 1)
            self.assertEqual(hashlib.sha256(open(os.path.join(out, p), "rb").read()).hexdigest(), h)
        self.assertEqual(len(manifest), len(files) - 1)
        for f in files:
            if f.endswith(".sh") or f == "S97soloist":
                self.assertNotIn(b"\r\n", open(os.path.join(out, f), "rb").read(), f)
        # Requirement: a pinned Soloist SHA256 that does not match stops the build.
        rc = bk.main(["--out", out + "2", "--cache", os.path.join(self.d, "cache"),
                      "--mirror", pathlib.Path(m).as_uri(), "--soloist", sol, "--device-dir", DEVICE,
                      "--soloist-sha256", "0" * 64])
        self.assertEqual(rc, 1)
        self.assertFalse(os.path.exists(out + "2"))

    # Requirement: the shipped kit is checked as laid out: an ELF whose
    # DT_NEEDED is not in lib/ fails the build.
    def test_verify_kit_finds_missing_lib(self):
        out = os.path.join(self.d, "kit")
        for d in ("bin", "lib", "modules"):
            os.makedirs(os.path.join(out, d))
        open(os.path.join(out, "bin", "soloist"), "wb").write(make_elf(["libc.so.6", "libgone.so.1"]))
        open(os.path.join(out, "lib", "libc.so.6"), "wb").write(make_elf(soname="libc.so.6"))
        with self.assertRaises(bk.BuildError) as e:
            bk.verify_kit(out)
        self.assertIn("bin/soloist -> libgone.so.1", str(e.exception))

    def test_tampered_deb_rejected(self):
        m = os.path.join(self.d, "mirror")
        good = make_deb({"usr/lib/libc.so.6": make_elf()})
        os.makedirs(os.path.join(m, "pool"))
        open(os.path.join(m, "pool", "libc6.deb"), "wb").write(good + b"tampered")
        st = bk.parse_stanzas(stanza("libc6", "2.41-12", data=good))[0]
        with self.assertRaises(bk.BuildError) as e:
            bk.download_debs(pathlib.Path(m).as_uri(), {"libc6": st}, os.path.join(self.d, "c"))
        self.assertIn("SHA256 mismatch", str(e.exception))


if __name__ == "__main__":
    unittest.main()
