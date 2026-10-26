"""Exercise the standalone TTS client without SSH, accounts or audio devices."""
import asyncio
import contextlib
import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import AsyncMock, patch

SOURCE = Path(__file__).resolve().parents[1] / 'alice-say.py'
SPEC = importlib.util.spec_from_file_location('alice_say', SOURCE)
say = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(say)

# Golden frame from the original helper verified against the Plum IPC backend.
HELLO_FRAME = bytes.fromhex(
    '31000000e20f2a3a0f416c6963654361706162696c6974794217081218016a110a0d'
    'd09fd180d0b8d0b2d0b5d182211001e80fd201')


def event(kind):
    remote = say.byte_field(18, say.integer(1, kind))
    payload = say.byte_field(252, remote) + say.integer(253, 210)
    return len(payload).to_bytes(4, 'little') + payload


class Input:
    def __init__(self):
        self.data = bytearray()
        self.closed = False

    def write(self, data):
        self.data.extend(data)

    async def drain(self):
        pass

    def close(self):
        self.closed = True

    async def wait_closed(self):
        pass


class Process:
    def __init__(self, replies=b'', eof=True, stuck=False):
        self.stdin = Input()
        self.stdout = asyncio.StreamReader()
        self.stdout.feed_data(replies)
        if eof:
            self.stdout.feed_eof()
        self.returncode = None
        self.stuck = stuck
        self.terminated = False

    async def wait(self):
        if self.stuck and not self.terminated:
            await asyncio.Future()
        self.returncode = 0
        return 0

    def terminate(self):
        self.terminated = True


class WireFormat(unittest.TestCase):
    def test_request_matches_the_frame_verified_on_plum(self):
        self.assertEqual(say.vocalize_frame('Привет!'), HELLO_FRAME)

    def test_dry_run_does_not_start_ssh_or_echo_the_text(self):
        output = io.StringIO()
        with patch.object(say.asyncio, 'create_subprocess_exec') as spawn:
            with contextlib.redirect_stdout(output):
                self.assertEqual(say.main(['private example', '--dry-run']), 0)
        spawn.assert_not_called()
        self.assertNotIn('private example', output.getvalue())

    def test_bad_frames_and_invalid_host_arguments_are_rejected(self):
        for data in [b'\x00', b'\x80', b'\x0a\x02x', b'\x0b', b'\x08'+b'\xff'*10]:
            with self.subTest(data=data), self.assertRaises(ValueError):
                say.fields(data)
        for host in ['', '-oProxyCommand=anything', 'host name', 'host\nname']:
            with self.subTest(host=host), self.assertRaises(ValueError):
                say.ssh_command(host)


class Client(unittest.IsolatedAsyncioTestCase):
    async def test_waits_for_start_then_completion_and_keeps_text_out_of_shell(self):
        process = Process(event(1) + event(6) + event(1))
        spawn = AsyncMock(return_value=process)
        text = 'Привет! "$HOME" $(example) '+chr(96)+'example'+chr(96)
        with patch.object(say.asyncio, 'create_subprocess_exec', spawn):
            with contextlib.redirect_stdout(io.StringIO()) as output:
                await say.speak('alice', text, 1)
        args = spawn.call_args.args
        self.assertNotIn(text, ' '.join(args))
        self.assertIn('StrictHostKeyChecking=yes', args)
        self.assertEqual(args[-1], 'exec socat STDIO TCP:127.0.0.1:9875,connect-timeout=2')
        self.assertIn(text.encode(), process.stdin.data)
        self.assertIn('подтвердила завершение', output.getvalue())
        self.assertTrue(process.stdin.closed)
        self.assertEqual(process.returncode, 0)

    async def test_native_error_does_not_dump_the_private_payload(self):
        process = Process(event(4))
        spawn = AsyncMock(return_value=process)
        with patch.object(say.asyncio, 'create_subprocess_exec', spawn):
            with self.assertRaisesRegex(RuntimeError, 'Штатный речевой сервис'):
                await say.speak('alice', 'test', 1)
        self.assertTrue(process.stdin.closed)

    async def test_eof_or_invalid_size_is_not_success(self):
        for replies, error in [(event(6), asyncio.IncompleteReadError),
                               ((512 * 1024 + 1).to_bytes(4, 'little'), ValueError),
                               (bytes(4), ValueError)]:
            process = Process(replies)
            spawn = AsyncMock(return_value=process)
            with self.subTest(error=error):
                with patch.object(say.asyncio, 'create_subprocess_exec', spawn):
                    with contextlib.redirect_stdout(io.StringIO()):
                        with self.assertRaises(error):
                            await say.speak('alice', 'test', 1)
                self.assertTrue(process.stdin.closed)

    async def test_silent_connection_times_out_and_closes_stdin(self):
        process = Process(eof=False)
        with patch.object(say.asyncio, 'create_subprocess_exec',
                          AsyncMock(return_value=process)):
            with self.assertRaises(TimeoutError):
                await say.speak('alice', 'test', .01)
        self.assertTrue(process.stdin.closed)
        self.assertEqual(process.returncode, 0)

    async def test_stuck_ssh_is_terminated_after_the_grace_period(self):
        process = Process(event(6) + event(1), stuck=True)
        with patch.object(say.asyncio, 'create_subprocess_exec',
                          AsyncMock(return_value=process)):
            with contextlib.redirect_stdout(io.StringIO()):
                await say.speak('alice', 'test', 1)
        self.assertTrue(process.terminated)
        self.assertTrue(process.stdin.closed)
        self.assertEqual(process.returncode, 0)


if __name__ == '__main__':
    unittest.main()
