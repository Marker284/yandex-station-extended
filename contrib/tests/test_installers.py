"""Installer failure paths, using fake adb and temporary files; no station required."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

CONTRIB = Path(__file__).resolve().parents[1]
SHELL = os.environ.get('SHELL_FOR_TESTS') or shutil.which('sh')

FAKE_ADB = '''import json, os, sys
args = sys.argv[1:]
with open(os.environ['ADB_LOG'], 'a', encoding='utf-8') as f:
    f.write(json.dumps(args) + '\\n')
cmd = args[2:] if args[:1] == ['-s'] else args
if cmd == ['get-state']:
    print('device\\r')
elif cmd == ['shell', 'id', '-u']:
    print(os.environ.get('FAKE_UID', '0'))
elif cmd == ['shell', 'cat /proc/device-tree/model']:
    print(os.environ.get('FAKE_MODEL', 'Yandex Station Micro v1.2'))
elif len(cmd) == 2 and cmd[0] == 'shell':
    script = cmd[1]
    if script.startswith('mktemp '):
        print(os.environ.get('FAKE_STAGE', '/data/local/tmp/librespot-check.ABC123'))
    elif script.endswith(' --check'):
        sys.exit(int(os.environ.get('FAKE_CHECK_EXIT', '0')))
    elif 'touch /data/quasar' in script:
        sys.exit(int(os.environ.get('FAKE_MARKERS_EXIT', '0')))
    elif '/proc/device-tree/compatible' in script:
        sys.exit(int(os.environ.get('FAKE_LAYOUT_EXIT', '0')))
    elif '/sys/class/ubi/' in script:
        sys.exit(int(os.environ.get('FAKE_ATTACHED', '0')))
'''


@unittest.skipUnless(SHELL, 'POSIX sh is required (SHELL_FOR_TESTS on Windows)')
class HostInstallers(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        bindir = self.root / 'bin'
        bindir.mkdir()
        fake = self.root / 'fake_adb.py'
        fake.write_text(FAKE_ADB, encoding='utf-8')
        launcher = '#!/bin/sh\nexec {} {} "$@"\n'.format(
            shlex.quote(Path(sys.executable).as_posix()), shlex.quote(fake.as_posix()))
        (bindir / 'adb').write_text(launcher, encoding='utf-8')
        (bindir / 'adb').chmod(0o755)
        (bindir / 'sleep').write_text('#!/bin/sh\nexit 0\n', encoding='utf-8')
        (bindir / 'sleep').chmod(0o755)
        self.log = self.root / 'adb.jsonl'
        self.env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ['PATH'],
                        ADB_LOG=str(self.log), MSYS_NO_PATHCONV='1')

    def run_script(self, name, *args, **env):
        return subprocess.run([SHELL, (CONTRIB / name).as_posix(), *map(str, args)],
                              env=dict(self.env, **env), capture_output=True,
                              text=True, encoding='utf-8', errors='replace', timeout=20)

    def calls(self):
        return [json.loads(s) for s in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_spotify_requires_explicit_target_and_valid_mode(self):
        for args in [(), ('--install',), ('station', '--unknown')]:
            with self.subTest(args=args):
                self.assertNotEqual(self.run_script('spotify.sh', *args).returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_spotify_rejects_mini2_before_upload(self):
        result = self.run_script('spotify.sh', 'station', '--install',
                                 FAKE_MODEL='Yandex Station Mini 2')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any('push' in c for c in self.calls()))

    def test_spotify_default_only_checks_and_cleans_own_stage(self):
        result = self.run_script('spotify.sh', 'station')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertTrue(any(c[-1].endswith(' --check') for c in calls))
        self.assertFalse(any(c[-1].endswith(' --install') for c in calls))
        self.assertTrue(any(c[-1] == "rm -rf '/data/local/tmp/librespot-check.ABC123'" for c in calls))
        self.assertTrue(all(c[:2] == ['-s', 'station'] for c in calls))

    def test_spotify_failed_check_never_installs(self):
        result = self.run_script('spotify.sh', 'station', '--install', FAKE_CHECK_EXIT='9')
        self.assertEqual(result.returncode, 9)
        self.assertFalse(any(c[-1].endswith(' --install') for c in self.calls()))

    def test_spotify_explicit_install_runs_only_after_successful_check(self):
        result = self.run_script('spotify.sh', 'station', '--install')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        check = next(i for i, c in enumerate(calls) if c[-1].endswith(' --check'))
        install = next(i for i, c in enumerate(calls) if c[-1].endswith(' --install'))
        self.assertLess(check, install)

    def test_spotify_rejects_unsafe_staging_path_without_cleanup(self):
        result = self.run_script('spotify.sh', 'station', FAKE_STAGE='/data')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any('rm -rf' in c[-1] or 'push' in c for c in self.calls()))

    def test_adb_requires_root_before_creating_markers(self):
        result = self.run_script('install-s97adb.sh', '192.0.2.1', FAKE_UID='2000')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any('touch /data/quasar' in c[-1] for c in self.calls()))

    def test_adb_marker_failure_does_not_report_success(self):
        result = self.run_script('install-s97adb.sh', '192.0.2.1', FAKE_MARKERS_EXIT='8')
        self.assertEqual(result.returncode, 8)
        self.assertNotIn('[+]', result.stdout)

    def test_adb_uses_native_markers_without_reboot_or_payload(self):
        result = self.run_script('install-s97adb.sh', '192.0.2.1')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertTrue(any('touch /data/quasar' in c[-1] for c in calls))
        self.assertFalse(any('push' in c or 'reboot' in c[-1] for c in calls))

    def image_dir(self, *names):
        images = self.root / 'images'
        images.mkdir()
        for name in names:
            (images / name).write_bytes(b'test image; never sent to a real device')
        return images

    def test_rollback_requires_explicit_write_before_adb(self):
        result = self.run_script('rollback.sh', 'station', self.image_dir('boot.img'))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_rollback_rejects_empty_image_set_before_adb(self):
        result = self.run_script('rollback.sh', 'station', self.image_dir(), '--write')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_rollback_rejects_wrong_layout_before_stopping_services(self):
        result = self.run_script('rollback.sh', 'station', self.image_dir('boot.img'),
                                 '--write', FAKE_LAYOUT_EXIT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any('killall' in c[-1] or 'push' in c for c in self.calls()))

    def test_rollback_never_erases_attached_ubi(self):
        result = self.run_script('rollback.sh', 'station', self.image_dir('system.ubi'),
                                 '--write', FAKE_ATTACHED='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any('killall' in c[-1] or 'push' in c for c in self.calls()))

    def test_rollback_preserves_userdata_and_hosts(self):
        result = self.run_script('rollback.sh', 'station', self.image_dir('boot.img'), '--write')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertTrue(any('nandwrite' in c[-1] for c in calls))
        self.assertFalse(any('/bkupgrade/' in c[-1] or '/etc/hosts' in c[-1] for c in calls))


@unittest.skipUnless(SHELL, 'POSIX sh is required')
class BackupGuards(unittest.TestCase):
    def exercise(self, script_name, action, setup=None, prelude=''):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            quasar, backup = root / 'quasar', root / 'backup'
            quasar.mkdir()
            backup.mkdir()
            for name in ('launch.json', 'ota_script.pub', 'device_ota_update.sh'):
                (quasar / name).write_text('original:' + name, encoding='utf-8')
            if setup:
                setup(quasar, backup)
            originals = {p.name: p.read_bytes() for p in quasar.iterdir()}
            source = (CONTRIB / script_name).read_text(encoding='utf-8')
            source = source.rsplit('\ncase "', 1)[0]
            source = source.replace('Q=/system/vendor/quasar', 'Q=' + shlex.quote(quasar.as_posix()))
            source = source.replace('BK=/data/opt/backup', 'BK=' + shlex.quote(backup.as_posix()))
            # Only temporary fixture paths may be written. Never remount the host root.
            mount_log = root / 'mount.log'
            source += '\nid() { echo 0; }\nmount() { echo called > ' + shlex.quote(mount_log.as_posix()) + '; }\n'
            source += prelude + '\n' + action + '\n'
            fixture = root / 'fixture.sh'
            fixture.write_text(source, encoding='utf-8', newline='\n')
            result = subprocess.run([SHELL, fixture.as_posix()], capture_output=True, text=True,
                                    encoding='utf-8', errors='replace', timeout=10)
            self.assertEqual({p.name: p.read_bytes() for p in quasar.iterdir()}, originals)
            self.assertFalse(mount_log.exists(), result.stdout + result.stderr)
            return result, {p.name: p.read_bytes() for p in backup.iterdir()}

    def test_failed_or_corrupt_copy_stops_before_system_writes(self):
        for script in ('yandex-noupdate.sh', 'yandex-micro-kit.sh'):
            for failure in ('return 1', 'return 0'):
                with self.subTest(script=script, failure=failure):
                    action = 'do_disable' if script == 'yandex-noupdate.sh' else 'ota_off'
                    result, files = self.exercise(script, action,
                        prelude='cp() { printf partial > "$3"; ' + failure + '; }')
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(files, {})

    def test_existing_backups_are_preserved(self):
        for script in ('yandex-noupdate.sh', 'yandex-micro-kit.sh'):
            def setup(q, b):
                (b / 'launch.json.orig').write_bytes(b'older-original')
            with self.subTest(script=script):
                result, files = self.exercise(script, 'backup', setup)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(files['launch.json.orig'], b'older-original')
                self.assertEqual(len(files), 3)

    def test_empty_backup_and_incomplete_restore_fail_closed(self):
        for script in ('yandex-noupdate.sh', 'yandex-micro-kit.sh'):
            for action in ('backup', 'do_restore'):
                with self.subTest(script=script, action=action):
                    result, _ = self.exercise(script, action,
                        setup=lambda q, b: (b / 'launch.json.orig').touch())
                    self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
