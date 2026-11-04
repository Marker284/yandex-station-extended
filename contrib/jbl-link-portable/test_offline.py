"""Installer guards only: no SSH, ADB, network or device changes."""
import contextlib
import importlib.util
import io
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("portable_installer", Path(__file__).with_name("install-autostart.py"))
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


class InstallerGuards(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.plugin = self.root / "plugin.so"
        header = bytearray(64)
        header[:7] = b"\x7fELF\x01\x01\x01"
        struct.pack_into("<H", header, 18, 40)
        self.plugin.write_bytes(header + b"/data/jbl-autostart/bootstrap.sh")
        self.config = self.root / "ssh-config"
        self.config.write_text("Host jbl\n    HostName example.invalid\n")

    def test_default_mode_never_connects(self):
        with mock.patch.object(installer, "PLUGIN", self.plugin), \
             mock.patch.object(sys, "argv", ["install-autostart.py"]), \
             mock.patch.object(installer.subprocess, "run") as remote, \
             contextlib.redirect_stdout(io.StringIO()):
            installer.main()
            remote.assert_not_called()

    def test_unrecognized_plugin_stops_before_ssh(self):
        self.plugin.write_bytes(b"not an ARM plugin")
        with mock.patch.object(installer, "PLUGIN", self.plugin), \
             mock.patch.object(sys, "argv", ["install-autostart.py", "--install", "--ssh-config", str(self.config)]), \
             mock.patch.object(installer.subprocess, "run") as remote:
            with self.assertRaises(ValueError):
                installer.main()
            remote.assert_not_called()

    def test_unreviewed_firmware_stops_before_writes(self):
        replies = [subprocess.CompletedProcess([], 0, b"INSTALL_TARGET_OK\n", b""),
                   subprocess.CompletedProcess([], 0, b"other-firmware\n", b"")]
        with mock.patch.object(installer, "PLUGIN", self.plugin), \
             mock.patch.object(sys, "argv", ["install-autostart.py", "--install", "--ssh-config", str(self.config)]), \
             mock.patch.object(installer.subprocess, "run", side_effect=replies) as remote, \
             contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, "Unreviewed firmware"):
                installer.main()
            self.assertEqual(remote.call_count, 2)
            for call in remote.call_args_list:
                command = call.args[0][-1]
                self.assertNotIn("mkdir", command)
                self.assertNotIn("cat >", command)
                self.assertNotIn("chattr", command)


if __name__ == "__main__":
    unittest.main()
