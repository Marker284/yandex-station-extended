#!/usr/bin/env python3
"""Run a local lite-kit clone with OAuth forwarding for one speaker.

Flow verified on Mini 2 YNDX-00020, factory-3 -> .369.1.46, November 2026.
The portable entry point is covered by host tests; it does not edit the kit,
router or speaker. To undo, stop it and start lite-kit normally.
"""
import argparse
import importlib.util
import http.client
import ipaddress
import json
from pathlib import Path
import ssl
import sys
from urllib.parse import parse_qs, urlsplit


def private_ipv4(value):
    ip = ipaddress.IPv4Address(value)
    return ip.is_loopback or any(ip in ipaddress.IPv4Network(net) for net in
                                ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'))


def load_target(path):
    target = json.loads(Path(path).read_text(encoding='utf-8'))
    if not isinstance(target, dict) or not all(
            isinstance(target.get(key), str) and target[key].strip()
            for key in ('station_ip', 'device_id', 'platform')):
        raise ValueError('OAuth target needs station_ip, device_id and platform')
    if not private_ipv4(target['station_ip']):
        raise ValueError('OAuth target station_ip must be private IPv4 or loopback')
    return target


def install_oauth_proxy(module, target):
    selected_ips = {target['station_ip']}

    class OAuthHandler(module.EquasarHandler):
        def oauth_request(self):
            headers = getattr(self, 'headers', None)
            return bool(headers and (headers.get('Host') or '').lower().split(':')[0]
                        == 'oauth.yandex.ru')

        def log_message(self, *args):
            if getattr(self, 'headers', None) is not None and not self.oauth_request():
                super().log_message(*args)

        def do_HEAD(self):
            if self.oauth_request():
                self.handle_request()
            else:
                super().do_HEAD()

        def handle_request(self):
            if urlsplit(self.path).path in ('/get_sync_info', '/check_updates'):
                query = parse_qs(urlsplit(self.path).query)
                if (query.get('device_id') == [target['device_id']]
                        and query.get('platform') == [target['platform']]
                        and private_ipv4(self.client_address[0])):
                    selected_ips.add(self.client_address[0])
            if not self.oauth_request():
                return super().handle_request()
            # OAuth must never reach Quasar cache or synthetic-success handlers.
            if self.client_address[0] not in selected_ips:
                self._send_json(b'{"error":"not_selected"}', code=403)
                return
            if not isinstance(self.connection, ssl.SSLSocket):
                self._send_json(b'{"error":"https_required"}', code=426)
                return
            connection = None
            try:
                host = 'oauth.yandex.ru'
                connection = module.PinnedHTTPS(host, module.real_ip(host), timeout=8,
                                                context=ssl.create_default_context())
                excluded = {'host', 'connection', 'content-length', 'transfer-encoding',
                            'proxy-authorization', 'proxy-connection'}
                headers = {k: v for k, v in self.headers.items() if k.lower() not in excluded}
                body = self._read_body() if self.command == 'POST' else None
                connection.request(self.command, self.path, body=body, headers=headers)
                response = connection.getresponse()
                data = response.read()
                self.send_response(response.status)
                for key, value in response.getheaders():
                    if key.lower() not in {'connection', 'content-length', 'transfer-encoding'}:
                        self.send_header(key, value)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                if self.command != 'HEAD':
                    self.wfile.write(data)
                print('[OAUTH] upstream status={}'.format(response.status), flush=True)
            except (OSError, http.client.HTTPException) as error:
                print('[OAUTH] upstream failed {}'.format(type(error).__name__), flush=True)
                self._send_json(b'{"error":"upstream_failed"}', code=502)
            finally:
                if connection:
                    connection.close()

    module.EquasarHandler = OAuthHandler
    module.DNS_NAMES.add(b'oauth.yandex.ru')


def load_kit(kit):
    source = (Path(kit) / 'scripts/equasar_server.py').resolve()
    if not source.is_file():
        raise ValueError('Kit must contain scripts/equasar_server.py')
    spec = importlib.util.spec_from_file_location('lite_kit_oauth_server', source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    required = ('EquasarHandler', 'DNS_NAMES', 'PinnedHTTPS', 'real_ip', 'main')
    if not all(hasattr(module, name) for name in required):
        raise ValueError('Unsupported lite-kit server interface')
    return module, source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kit', required=True, type=Path, help='Local lite-kit clone')
    parser.add_argument('--target-file', required=True, type=Path,
                        help='Private JSON with station_ip, device_id and platform')
    args, remaining = parser.parse_known_args()
    try:
        target = load_target(args.target_file)
        module, source = load_kit(args.kit)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    install_oauth_proxy(module, target)
    sys.argv = [str(source), *remaining]
    module.main()


if __name__ == '__main__':
    main()
