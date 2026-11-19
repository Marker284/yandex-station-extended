#!/usr/bin/env python3
"""Offline fixture checks only; never executes a device binary or reads keys."""
import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
CANDIDATE = HERE.parent / "pickle-factory12" / "S98picklessh"
EXPECTED = shlex.split(
    "/data/opt/bin/dropbear -r /data/opt/etc/dropbear/hk_ed25519 "
    "-D /data/opt/etc/dropbear -s -B -j -k -T 3 -p 2222 "
    "-P /run/alice-pickle-dropbear.pid"
)


def main():
    assert CANDIDATE.is_file(), "candidate must exist before acceptance"
    source = CANDIDATE.read_text()
    assert source.startswith("#!/bin/sh\nset -eu\n")
    subprocess.run(["sh", "-n", str(CANDIDATE)], check=True)
    command = " ".join(EXPECTED) + " </dev/null >/dev/null 2>&1"
    assert command in source, "exact secure command and redirections required"
    with tempfile.TemporaryDirectory(prefix="selfcheck-", dir=HERE) as directory:
        root = Path(directory)
        binary = root / "data/opt/bin/dropbear"
        keys = root / "data/opt/etc/dropbear"
        pidfile = root / "run/alice-pickle-dropbear.pid"
        proc = root / "proc"
        tools = root / "tools"
        for folder in (binary.parent, keys, pidfile.parent, proc, tools):
            folder.mkdir(parents=True, exist_ok=True)
        hostkey = keys / "hk_ed25519"
        authorized = keys / "authorized_keys"
        hostkey.touch()  # Empty synthetic fixtures, never private key material.
        authorized.touch()
        keys.chmod(0o700)
        hostkey.chmod(0o600)
        authorized.chmod(0o600)
        binary.write_text(
            '#!/bin/sh\nset -eu\n'
            'root=${0%/data/opt/bin/dropbear}\n'
            'printf "%s\\n" "$@" > "$root/args"\n'
            'if read -r input; then exit 90; fi\n'
            'printf "must be suppressed\\n"\n'
            'printf "must also be suppressed\\n" >&2\n'
            'mode=$(cat "$root/mode")\n'
            'case "$mode" in\n'
            '  fail) exit 23 ;;\n'
            '  no_pid) exit 0 ;;\n'
            '  bad_pid) printf "bad\\n" > "$root/run/alice-pickle-dropbear.pid"; exit 0 ;;\n'
            'esac\n'
            'mkdir -p "$root/proc/4242"\n'
            'target=$0\n'
            '[ "$mode" != wrong_exe ] || target=/bin/sh\n'
            'ln -s "$target" "$root/proc/4242/exe"\n'
            'printf "%s\\000" "$0" "$@" > "$root/proc/4242/cmdline"\n'
            'if [ "$mode" = wrong_args ]; then\n'
            '  printf "%s\\000" "$0" unsafe > "$root/proc/4242/cmdline"\n'
            'fi\n'
            'printf "4242\\n" > "$root/run/alice-pickle-dropbear.pid"\n'
        )
        binary.chmod(0o755)
        identity = tools / "id"
        identity.write_text(
            '#!/bin/sh\n[ "$#" = 1 ] && [ "$1" = -u ] || exit 91\n'
            'root=${0%/tools/id}\ncat "$root/uid"\n'
        )
        identity.chmod(0o755)
        (root / "uid").write_text("0\n")
        # Substitute exact absolute literals only in a disposable local copy.
        local_source = source
        for literal in (
            "/data/opt/bin/dropbear",
            "/data/opt/etc/dropbear",
            "/run/alice-pickle-dropbear.pid",
            "/proc/",
        ):
            local_source = local_source.replace(literal, str(root) + literal)
        script = root / "candidate"
        script.write_text(local_source)
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"])

        def reset(mode="ok"):
            for path in (pidfile, root / "args", proc / "4242/exe", proc / "4242/cmdline"):
                path.unlink(missing_ok=True)
            (root / "mode").write_text(mode)

        def run(action=None, expected=0):
            args = ["sh", str(script)]
            if action is not None:
                args.append(action)
            result = subprocess.run(args, check=False, env=env, capture_output=True, timeout=5)
            assert result.returncode == expected, (action, result.returncode, expected)
            assert result.stdout == b"", result.stdout
            return result

        reset()
        result = run()
        assert result.stderr == b"", result.stderr
        expected_args = [arg.replace("/data/", str(root) + "/data/")
                         .replace("/run/", str(root) + "/run/") for arg in EXPECTED[1:]]
        assert (root / "args").read_text().splitlines() == expected_args
        assert pidfile.read_text() == "4242\n"
        (root / "args").unlink()
        run("start")  # Existing owned executable is idempotent.
        assert not (root / "args").exists()
        assert pidfile.read_text() == "4242\n"

        secure_argv = [str(binary), *expected_args]
        missing_s = [arg for arg in secure_argv if arg != "-s"]
        wrong_port = ["2223" if arg == "2222" else arg for arg in secure_argv]
        other_pidfile = [str(root / "run/other.pid") if arg == str(pidfile) else arg
                         for arg in secure_argv]
        # These two argv vectors have identical newline-converted representations.
        newline_arg = secure_argv.copy()
        newline_arg[1] += "\nextra"
        split_arg = [secure_argv[0], secure_argv[1], "extra", *secure_argv[2:]]
        assert "\n".join(newline_arg) == "\n".join(split_arg)
        for argv in (missing_s, wrong_port, other_pidfile, newline_arg, split_arg):
            reset()
            (proc / "4242/exe").symlink_to(binary)
            pidfile.write_text("4242\n")
            cmdline = b"\0".join(arg.encode() for arg in argv) + b"\0"
            (proc / "4242/cmdline").write_bytes(cmdline)
            run(expected=1)
            assert pidfile.read_text() == "4242\n"
            assert (proc / "4242/cmdline").read_bytes() == cmdline
            assert not (root / "args").exists()
        for missing_cmdline in (None, b"", b"\0".join(arg.encode() for arg in secure_argv)):
            reset()
            (proc / "4242/exe").symlink_to(binary)
            pidfile.write_text("4242\n")
            if missing_cmdline is not None:
                (proc / "4242/cmdline").write_bytes(missing_cmdline)
            run(expected=1)
            assert pidfile.read_text() == "4242\n"
            assert not (root / "args").exists()

        for pid in ("", "abc\n", "42 42\n", "4242\n99\n", "-1\n", "999999\n"):
            reset()
            pidfile.write_text(pid)
            run("start", expected=1)
            assert pidfile.read_text() == pid
            assert not (root / "args").exists()
        reset()
        (proc / "4242/exe").symlink_to("/bin/sh")
        pidfile.write_text("4242\n")
        run(expected=1)
        assert pidfile.read_text() == "4242\n"
        assert not (root / "args").exists()
        reset()
        pidfile.symlink_to(root / "absent")
        run(expected=1)
        assert pidfile.is_symlink() and not (root / "absent").exists()
        assert not (root / "args").exists()

        for mode, status in (("fail", 23), ("no_pid", 1), ("bad_pid", 1),
                             ("wrong_exe", 1), ("wrong_args", 1)):
            reset(mode)
            run(expected=status)
            assert (root / "args").exists()

        reset()
        (root / "uid").write_text("1000\n")
        run(expected=1)
        assert not (root / "args").exists()
        (root / "uid").unlink()  # id command failure also fails closed.
        run(expected=1)
        assert not (root / "args").exists()
        (root / "uid").write_text("0\n")
        binary.chmod(0o644)
        run(expected=1)
        assert not (root / "args").exists()
        binary.chmod(0o755)
        for key in (hostkey, authorized):
            key.unlink()
            run(expected=1)
            assert not (root / "args").exists()
            key.touch(mode=0o600)
        run("stop")
        assert not (root / "args").exists() and not pidfile.exists()
        run("restart", expected=2)
        assert not (root / "args").exists() and not pidfile.exists()
    assert CANDIDATE.read_text() == source
    print("PASS: syntax, exact argv, start, owned PID, refusal, failures, actions (offline only)")


class PickleSSHTest(unittest.TestCase):
    def test_secure_startup(self):
        main()


if __name__ == "__main__":
    unittest.main()
