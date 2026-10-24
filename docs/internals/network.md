# Сеть и порты

Снято со Станции Лайт (прошивка 3.21, с включёнными ADB и SSH).

## Интерфейсы

| Интерфейс | Назначение |
|---|---|
| `wlan0` | Wi-Fi, адрес по DHCP от роутера |
| `p2p0` | Wi-Fi Direct, адрес `169.254.x.x` |

Радио — комбо-чип Unisoc UWE5621 (Wi-Fi + Bluetooth, SDIO). Ethernet на плате нет, но его
можно добавить USB-адаптером: [USB Host](../recipes/usb-host.md).

## Открытые порты

| Порт | Что это |
|---|---|
| `tcp 1961` | glagol (`glagold`) — локальный API управления |
| `tcp 5555` | ADB (после [получения root](../start/root.md)) |
| `tcp 2222` | SSH, Dropbear (после [шага 2](../start/ssh.md)) |
| `tcp 5081` | сервис прошивки (назначение не изучали) |
| `tcp/udp 7447` | Zenoh |
| `udp 5353` | mDNS |
| `udp 11125` | `net_clock` |
| `tcp 127.0.0.1:11124` | `multiroomd` |
| `127.0.0.1:53` | локальный DNS `unbound` |
| `127.0.0.1:98xx–99xx` | внутренние порты демонов quasar (номера — в `quasar.cfg`) |

## DNS: `unbound`

На колонке работает свой резолвер `unbound` на `127.0.0.1:53`. Запросы он пересылает DNS
роутера и DNS Яндекса (`77.88.8.1`, `77.88.8.2`, `77.88.8.8`, `77.88.8.88`). Кроме того, в
`quasar.cfg` есть таблица `DnsFallbackMap` — запасные адреса на случай, если DNS не
отвечает. Поэтому одной подмены DNS может не хватить, чтобы изолировать колонку от Яндекса.

## glagol (порт 1961) { #glagol }

Локальный API, через который колонкой управляют приложения и интеграции (например,
[YandexStation для Home Assistant](https://github.com/AlexxIT/YandexStation)). Это
WebSocket-сервер (`websocketpp`) поверх TLS на порту **1961**, путь `/`. Разобрано по строкам
в `maind` и живым пробам (прошивка quasar 3.21 на Amlogic-станции).

### Два сокета

| Сокет | Роль |
|---|---|
| `127.0.0.1:9899` (`"port"`) | внутренний WS/IPC внутри `maind --platformd` |
| `:::1961` (`"externalPort"`) | внешний WebSocket поверх TLS, виден в LAN (dual-stack IPv6) |

### Обнаружение (mDNS)

Колонка анонсирует себя как `_yandexio._tcp` (`avahi` встроен в glagold, отдельного
`avahi-daemon` в системе нет). Пример TXT: `deviceId=<DEVICE_ID> platform=<PLATFORM>
cluster=yes`. Найти с ПК: `avahi-browse -rt _yandexio._tcp` (или `dns-sd -B _yandexio._tcp`).

### TLS

Сертификат **самоподписанный и генерируется заново при каждом старте** glagold
(`CN=localhost, O=Yandex`, без SAN, срок +3 года). Идентичности он не несёт — проверку в
клиенте отключают; TLS здесь только шифрует канал, а не авторизует.

### Авторизация — `conversationToken` { #glagol-token }

Доступ определяется полем `conversationToken` **в каждом сообщении**. Это **JWT** (не UUID),
со сроком жизни ~24 ч (`exp` внутри). Сообщение без валидного токена сервер закрывает
WebSocket-кадром `CLOSE` с причиной `"Invalid token"` (проверка локальная, без обращения в облако).

Токен выписывается в облаке по OAuth аккаунта:

```http
GET https://quasar.yandex.net/glagol/token?device_id=<DEVICE_ID>&platform=<PLATFORM>
Authorization: OAuth <YANDEX_OAUTH_TOKEN>
→ 200 {"status":"ok","token":"<JWT>"}
```

!!! warning "Какой OAuth подходит и откуда звать"
    * В `/data/quasar/account_storage.dat` (protobuf) лежит **несколько** OAuth-токенов `y0_…`.
      Для `/glagol/token` годится **не любой** — часть отдаёт `403 Forbidden`. Перебирайте
      кандидатов до `status:ok`.
    * Запрос **с постороннего хоста** (ПК) часто ловит `403` (antirobot/скоуп/UA). Надёжнее
      выписывать токен **на самой колонке** (`wget` по SSH): там верный OAuth, CA-бандл
      (`CA_CERTIFICATES=/system/vendor/quasar/ca-certificates.crt`) и antirobot-контекст.

Смежные облачные эндпоинты: `/glagol/device_list` (список устройств аккаунта; **именно он
открывает порт 1961**, см. [Подводные камни](gotchas.md#glagol-1961)) и `/glagol/check_token`
(+ `/glagol/v2.0/check_token`) — серверная валидация токена; в штатном режиме glagold проверяет
JWT локально (подпись + `exp`).

### Конверт сообщения

```json
{
  "conversationToken": "<JWT>",
  "id": "<hex/uuid>",
  "sentTime": 1700000000000,
  "payload": { "command": "<verb>", ... }
}
```

В ответ на валидную команду колонка присылает свой `state` (`PlayerState`, `AudioPlayerState`,
`Volume`/`MaxVolume`, `aliceState`, `SoftwareVersion` …).

Команды `payload.command` (подтверждены по строкам в `maind`):

| `command` | payload | Действие |
|---|---|---|
| `ping` | — | проверка связи, в ответ — `state` |
| `play` / `stop` | — | воспроизведение / пауза |
| `next` / `prev` | — | следующий / предыдущий трек |
| `rewind` | `{"position": <сек>}` | перемотка |
| `setVolume` | `{"volume": 0.0..1.0}` | громкость (доля, **не** `set_volume`) |
| `sendText` | `{"text": "<фраза>"}` | текстовая **команда** Алисе (она её выполнит/ответит) |
| `serverAction` | `{"serverActionEventPayload": {...}}` | server-action semantic frame |

### Заставить Алису произнести текст дословно { #glagol-tts }

`sendText` — это команда (Алиса её *интерпретирует*). Чтобы она произнесла текст слово-в-слово,
шлют `serverAction` со сценарием `personal_assistant.scenarios.quasar.iot.repeat_phrase`
(шаблон зашит в `maind`):

```json
{ "command": "serverAction",
  "serverActionEventPayload": {
    "type": "server_action",
    "name": "update_form",
    "payload": {
      "form_update": {
        "name": "personal_assistant.scenarios.quasar.iot.repeat_phrase",
        "slots": [{ "name": "phrase_to_repeat", "optional": false, "type": "string", "value": "привет всем" }]
      },
      "resubmit": true
    } } }
```

!!! note "Синтез речи идёт через облако"
    И `sendText`, и `repeat_phrase` уходят в NLU/TTS Яндекса (`uniproxy.alice.yandex.net`). На
    изолированной без интернета сети они не произнесутся. Полностью локальная озвучка — только
    проиграть заранее отрендеренный WAV через `aplay`/Linkplay, уже не «голосом Алисы».

### Минимальный клиент (stdlib Python)

```python
import asyncio, json, os, ssl, time, websockets

DEVICE_IP, PORT, TOKEN = "192.168.1.x", 1961, "<JWT>"

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

def envelope(payload):
    return json.dumps({
        "conversationToken": TOKEN,
        "id": os.urandom(8).hex(),
        "sentTime": int(time.time() * 1000),
        "payload": payload,
    })

async def main():
    async with websockets.connect(f"wss://{DEVICE_IP}:{PORT}/", ssl=ctx) as ws:
        await ws.send(envelope({"command": "ping"}))
        print("state:", await ws.recv())
        await ws.send(envelope({"command": "sendText", "text": "какая погода"}))

asyncio.run(main())
```
