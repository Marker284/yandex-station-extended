"""Test OAuth forwarding without a speaker, accounts or network services."""
from contextlib import redirect_stdout
from email.message import Message
import importlib.util
import io
import json
from pathlib import Path
import ssl
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

SOURCE = Path(__file__).resolve().parents[1] / 'lite-kit-oauth.py'
SPEC = importlib.util.spec_from_file_location('lite_kit_oauth', SOURCE)
relay = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(relay)


class BaseHandler:
    def handle_request(self):
        self.delegated = True

    def do_HEAD(self):
        self.head_delegated = True

    def log_message(self, *args):
        print('base log', self.path, self.headers)

    def _send_json(self, payload, code=200):
        self.response_status = code
        self.wfile.write(payload)

    def _read_body(self):
        return b'grant_type=PRIVATE_BODY'

    def send_response(self, status):
        self.response_status = status
        self.log_message('response', status)

    def send_header(self, key, value):
        self.response_headers[key.lower()] = value

    def end_headers(self):
        pass


def setup_handler(client='127.0.0.1', tls=True):
    module = SimpleNamespace(EquasarHandler=BaseHandler,
                             DNS_NAMES={b'quasar.yandex.net'},
                             real_ip=lambda host: '192.0.2.1')
    target = {'station_ip': '127.0.0.1', 'device_id': '<DEVICE_ID>',
              'platform': 'yandexmini_2'}
    relay.install_oauth_proxy(module, target)
    handler = object.__new__(module.EquasarHandler)
    handler.client_address = (client, 1234)
    handler.headers = Message()
    handler.headers['Host'] = 'oauth.yandex.ru'
    handler.headers['Authorization'] = 'PRIVATE_HEADER'
    handler.headers['Proxy-Authorization'] = 'PRIVATE_PROXY_HEADER'
    handler.connection = Mock(spec=ssl.SSLSocket) if tls else object()
    handler.path = '/token?secret=PRIVATE_QUERY'
    handler.command = 'POST'
    handler.wfile = io.BytesIO()
    handler.response_headers = {}
    module.PinnedHTTPS = Mock()
    return module, handler


class OAuthForwarding(unittest.TestCase):
    def exercise(self, status, fail=False, method='POST'):
        module, handler = setup_handler()
        handler.command = method
        connection = module.PinnedHTTPS.return_value
        response = connection.getresponse.return_value
        response.status = status
        response.read.return_value = b'{"token":"PRIVATE_RESPONSE"}'
        response.getheaders.return_value = [('Content-Type', 'application/json'),
                                             ('Transfer-Encoding', 'chunked')]
        if fail:
            connection.request.side_effect = OSError('PRIVATE_EXCEPTION')
        output = io.StringIO()
        with redirect_stdout(output):
            handler.handle_request()
        self.assertNotIn('PRIVATE_', output.getvalue())
        context = module.PinnedHTTPS.call_args.kwargs['context']
        self.assertTrue(context.check_hostname)
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
        return module, handler, connection

    def test_preserves_real_status_body_credentials_and_error_responses(self):
        for status in (200, 400, 503):
            with self.subTest(status=status):
                module, handler, connection = self.exercise(status)
                self.assertEqual(handler.response_status, status)
                self.assertEqual(handler.wfile.getvalue(), b'{"token":"PRIVATE_RESPONSE"}')
                self.assertEqual(module.PinnedHTTPS.call_args.args,
                                 ('oauth.yandex.ru', '192.0.2.1'))
                method, path = connection.request.call_args.args
                body = connection.request.call_args.kwargs['body']
                headers = connection.request.call_args.kwargs['headers']
                self.assertEqual((method, path, body),
                                 ('POST', '/token?secret=PRIVATE_QUERY',
                                  b'grant_type=PRIVATE_BODY'))
                self.assertEqual(headers['Authorization'], 'PRIVATE_HEADER')
                self.assertNotIn('Proxy-Authorization', headers)
                self.assertNotIn('transfer-encoding', handler.response_headers)
                connection.close.assert_called_once()

    def test_failure_is_502_without_fake_success(self):
        _, handler, connection = self.exercise(200, fail=True)
        self.assertEqual(handler.response_status, 502)
        connection.close.assert_called_once()

    def test_head_forwards_status_without_sending_body(self):
        _, handler, connection = self.exercise(200, method='HEAD')
        self.assertEqual(handler.response_status, 200)
        self.assertEqual(handler.wfile.getvalue(), b'')
        self.assertIsNone(connection.request.call_args.kwargs['body'])

    def test_rejects_other_clients_and_plain_http_before_upstream(self):
        for client, tls, status in [('127.0.0.2', True, 403),
                                    ('127.0.0.1', False, 426)]:
            with self.subTest(client=client, tls=tls):
                module, handler = setup_handler(client, tls)
                handler.handle_request()
                self.assertEqual(handler.response_status, status)
                module.PinnedHTTPS.assert_not_called()

    def test_follows_only_same_device_and_platform_after_dhcp(self):
        for device, platform, status in [('<DEVICE_ID>', 'yandexmini_2', 426),
                                         ('other', 'yandexmini_2', 403),
                                         ('<DEVICE_ID>', 'other', 403)]:
            with self.subTest(device=device, platform=platform):
                module, handler = setup_handler('127.0.0.2', tls=False)
                handler.headers.replace_header('Host', 'quasar.yandex.net')
                handler.path = '/check_updates?device_id={}&platform={}'.format(device, platform)
                handler.handle_request()
                self.assertTrue(handler.delegated)
                handler.headers.replace_header('Host', 'oauth.yandex.ru')
                handler.path = '/token'
                handler.handle_request()
                self.assertEqual(handler.response_status, status)
                module.PinnedHTTPS.assert_not_called()

    def test_keeps_quasar_handler_and_head_behavior(self):
        module, handler = setup_handler()
        handler.headers.replace_header('Host', 'quasar.yandex.net')
        handler.handle_request()
        handler.do_HEAD()
        self.assertTrue(handler.delegated)
        self.assertTrue(handler.head_delegated)
        module.PinnedHTTPS.assert_not_called()


class Configuration(unittest.TestCase):
    def test_requires_complete_private_target(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'target.json'
            target = {'station_ip': '192.168.1.120', 'device_id': '<DEVICE_ID>',
                      'platform': 'yandexmini_2'}
            for invalid in ({}, {**target, 'station_ip': '8.8.8.8'},
                            {**target, 'device_id': ''}, []):
                path.write_text(json.dumps(invalid), encoding='utf-8')
                with self.assertRaises(ValueError):
                    relay.load_target(path)
            path.write_text(json.dumps(target), encoding='utf-8')
            self.assertEqual(relay.load_target(path), target)

    def test_load_kit_checks_layout_and_interface(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(ValueError):
                relay.load_kit(folder)
            source = Path(folder) / 'scripts/equasar_server.py'
            source.parent.mkdir()
            source.write_text('DNS_NAMES=set()\n', encoding='utf-8')
            with self.assertRaises(ValueError):
                relay.load_kit(folder)
            source.write_text('class EquasarHandler: pass\nDNS_NAMES=set()\n'
                              'PinnedHTTPS=object\ndef real_ip(): pass\n'
                              'def main(): pass\n', encoding='utf-8')
            module, loaded = relay.load_kit(folder)
            self.assertEqual(loaded, source.resolve())
            self.assertNotIn(b'oauth.yandex.ru', module.DNS_NAMES)

    def test_entry_point_forwards_kit_arguments(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / 'target.json'
            target.write_text(json.dumps({'station_ip': '192.168.1.120',
                                          'device_id': '<DEVICE_ID>',
                                          'platform': 'yandexmini_2'}), encoding='utf-8')
            module = SimpleNamespace(EquasarHandler=BaseHandler, DNS_NAMES=set())
            observed = []
            module.main = lambda: observed.append(list(sys.argv))
            source = Path(folder) / 'scripts/equasar_server.py'
            with patch.object(sys, 'argv', ['relay', '--kit', folder, '--target-file',
                                           str(target), '--dns', '--downgrade']), \
                    patch.object(relay, 'load_kit', return_value=(module, source)):
                relay.main()
            self.assertEqual(observed, [[str(source), '--dns', '--downgrade']])
            self.assertIn(b'oauth.yandex.ru', module.DNS_NAMES)


if __name__ == '__main__':
    unittest.main()
