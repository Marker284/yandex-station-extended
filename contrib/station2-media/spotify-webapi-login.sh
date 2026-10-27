#!/usr/bin/env bash
# Ключи Spotify Web API для голосовых команд на Станции 2 (voice-spotify.sh).
# Вход по PKCE без секрета приложения: страница Spotify открывается в браузере, ответ
# ловится на 127.0.0.1:5589, refresh_token сразу уходит на колонку (права 600) и в
# терминал не печатается.
#
# Нужно приложение на developer.spotify.com (Web API, Redirect URI
# http://127.0.0.1:5589/callback); его Client ID — первый аргумент.
#
#   ./spotify-webapi-login.sh <Client ID> <IP колонки>
set -euo pipefail

CID=${1:?"использование: $0 <Client ID> <IP колонки>"}
IP=${2:?"использование: $0 <Client ID> <IP колонки>"}
HERE=$(cd "$(dirname "$0")" && pwd)
KEY=$HOME/.ssh/yandex_station2

python3 -I - "$CID" <<'PY' |
import base64, hashlib, http.server, json, secrets, sys, urllib.parse, urllib.request, webbrowser

cid = sys.argv[1]
port = 5589
redirect = f"http://127.0.0.1:{port}/callback"
verifier = secrets.token_urlsafe(64)
challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
state = secrets.token_urlsafe(16)
scope = "user-read-playback-state user-modify-playback-state user-read-private user-library-read"
url = "https://accounts.spotify.com/authorize?" + urllib.parse.urlencode({
    "client_id": cid, "response_type": "code", "redirect_uri": redirect,
    "code_challenge_method": "S256", "code_challenge": challenge, "state": state, "scope": scope,
})
result = {}

class Callback(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        if q.get("state", [""])[0] != state:
            self.send_response(404)
            self.end_headers()
            return
        result["code"] = q.get("code", [None])[0]
        result["error"] = q.get("error", [None])[0]
        msg = "Готово, вкладку можно закрыть." if result["code"] else f"Ошибка: {result['error']}"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write(msg.encode())

    def log_message(self, *args):
        pass

server = http.server.HTTPServer(("127.0.0.1", port), Callback)
webbrowser.open(url)
print("Открыл страницу входа Spotify в браузере…", file=sys.stderr)
while not result:
    server.handle_request()
if not result.get("code"):
    sys.exit(f"Spotify отказал: {result.get('error')}")

body = urllib.parse.urlencode({
    "grant_type": "authorization_code", "code": result["code"], "redirect_uri": redirect,
    "client_id": cid, "code_verifier": verifier,
}).encode()
tokens = json.load(urllib.request.urlopen(
    urllib.request.Request("https://accounts.spotify.com/api/token", data=body)))
print(json.dumps({"client_id": cid, "refresh_token": tokens["refresh_token"]}))
PY
ssh -i "$KEY" -p 2222 -o IdentitiesOnly=yes -o BatchMode=yes \
    -o UserKnownHostsFile="$HERE/known_hosts" "root@$IP" \
    'umask 077; cat > /data/local/opt/ap2/etc/spotify-webapi.json && echo "ключи на колонке" &&
     /data/local/opt/ap2/spotify-api.sh devices'
