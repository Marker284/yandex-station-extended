# glagol и локальные IPC Алисы

Два локальных канала управления: `glagol` (API интеграций, `YandexIOReceiver`) и
protobuf-IPC внутри `aliced` (порт `9875`), по которому Алиса отдаёт распознанную фразу и
состояние. Страница собрана по данным с устройства и из документации проекта;
непроверенное помечено.

**Проверено на:** Станция 2 (`yandexmidi`), прошивка `0.369.1.46.4793639783.20261020.295`,
ноябрь 2026.

## Что это { #what }

- **glagol** (`glagold` в `quasar.cfg`) — локальный API, по которому колонкой управляют
  приложения и интеграции, например [YandexStation для Home Assistant](https://github.com/AlexxIT/YandexStation).
- Локальный IPC `9875` (`aliced`) — поток кадров Алисы: состояние, распознанная фраза и
  отправка ей команд.
- **GlagolCluster** — реализация glagol внутри `maind`: приём и отправка сообщений в
  распределённые «кластер»; новости/состояние — через Capability.

## Порты { #ports }

| Порт | Где | Что | Проверено |
|---|---|---|---|
| `9899` | внутренний (`glagold.port`) | glagol внутри устройства | из локальной сети — `Connection refused`; с самой колонки TCP-соединение принимает, на мусорный ввод ничего не отвечает |
| `1961` | внешний (`glagold.externalPort`) | glagol поверх WSS | `quasar.cfg`; `openssl s_client` — TLSv1.2 |
| `9875` | локальный IPC | `aliced` | `quasar.cfg` (`aliced.port`) |
| `7447` | TCP/UDP | Zenoh | вики |
| `5353` | UDP | mDNS (`maind --platformd`) | вики |

## mDNS: как колонку видят в сети { #mdns }

`glagold` объявляет тип сервиса `_yandexio._tcp` (`glagold.serviceType`), префикс
`YandexIOReceiver-` и имя хоста `yandex-station-2-XXXXXXXX` (`hostnamePrefix`).
Проверено с мака: `dns-sd -B _yandexio._tcp` показывает
`YandexIOReceiver-<DEVICE_ID> _yandexio._tcp.local.` в локальной сети.
TXT-записи: `deviceId=…`, `platform=…`, `cluster=yes`; `platform` для Станции 2 — `yandexmidi`.

```text
YandexIOReceiver-<DEVICE_ID>._yandexio._tcp.local. can be reached at yandex-station-gen2-<DEVICE_ID>.local.:1961
 deviceId=<DEVICE_ID> platform=yandexmidi cluster=yes
```

## TLS на `1961` { #tls }

- `TLSv1.2`, шифр `ECDHE-RSA-AES128-GCM-SHA256`.
- Сертификат самоподписанный: `issuer=C=RU, CN=localhost, O=Yandex`, `subject` тот же,
  `serial=01`, сроки `2026-11-18 → 2029-11-17`. Генерируется при загрузке, к известному
  удостоверяющему центру не приколочен.
- Клиентская аутентификация на уровне TLS не требуется: рукопожатие с чужим сертификатом
  проходит. Проверки идут на уровне сообщений WebSocket (см. токен).

## Токен glagol { #token }

По коду интеграции YandexStation: токен получается запросом
`https://quasar.yandex.net/glagol/token?device_id=<id>&platform=<platform>` с учётной
авторизацией Яндекса. `platform` — как в TXT-записи (`yandexmidi` для Станции 2).
Проверено с чужим токеном — колонка отвечает WebSocket `Close code=4000,
reason="Invalid token"` и закрывает соединение.

На самой колонке токен хранится в `gsdkTokens.json` (`glagold.tokensStorage`); файла нет
в снимке `/data` этого устройства — не проверялось.

## Как устроен обмен по glagol { #protocol }

Соединение — WebSocket (WSS). Клиент шлёт сообщения:

```json
{"conversationToken": "<token>", "id": "<uuid>",
 "payload": {"command": "…"}, "sentTime": 1763450000000}
```

- `conversationToken` — glagol-токен (см. выше).
- `id` — uuid запроса; колонка отвечает сообщениями с тем же `id`.
- `sentTime` — миллисекунды Unix epoch.

Колонка сама шлёт периодические сообщения со `state` (громкость, плеер, таймеры,
`timeSinceLastVoiceActivity`), `vinsResponse` (ответ Алисы, карты, `is_streaming`,
`output_speech`) и со списком `experiments` и `supported_features`.

### Команды воспроизведения и громкости { #hardware }

Проверены строки в `maind` (гугл-отчёты локальной интеграции):

| Команда | Параметры | Проверено |
|---|---|---|
| `play` | — | строка в maind |
| `stop` | — | строка в maind (работает как пауза) |
| `prev` | — | строка в maind |
| `next` | — | строка в maind |
| `setVolume` | `volume: 0…10` | строка в maind (23 вхождения) |
| `rewind` | `position: <сек>` | строка в maind |
| `repeat` | `mode: None` / `One` / `All` | строка в maind |
| `shuffle` | `enable: true/false` | строка в maind |
| `sendText` | `text: <строка>` | строка в maind |

### Команда `externalCommandBypass` { #bypass }

`externalCommandBypass` — generic-обёртка для команд уровня приложений; данные —
base64 от protobuf `{1: <имя-команды>, 2: <payload-json>}`.

Встречающиеся команды (строки в `maind` присутствуют, поведение не проверялось):

- `audio_play` — играет поток, формирует `payload` вида
  `{stream: {type: Track/FmRadio, url, id, …}, metadata: {}}`;
- `sound_louder` / `sound_quiter` — громче/тише;
- `draw_led_screen` — анимация LED-панели;
- `draw_scled_animations` — анимации центральных LED.

Из окружения интеграции известно использование `update_form` для сценариев вида
`personal_assistant.scenarios.quasar.go_home`, `player_continue`, `repeat_phrase`;
`form_update` и `resubmit` встретились в `maind`.

### `serverAction` { #server-action }

`serverAction` — команда-«маршрут» к сценарию: payload вида

```json
{"command": "serverAction", "serverActionEventPayload": {
  "type": "server_action", "name": "<name>",
  "payload": { "<key>": "<value>" }}}
```

Описаны две формы: `on_reset_session` (сброс) и `update_form` с
`resubmit: true` и списком `slots` (заполняются именованные слоты сценария).
`player_continue`, `go_home`, `repeat_phrase` встречаются в строках `maind`.

## Команда `START_VOCALIZE` { #vocalize }

Метод `AliceCapability` с номером `18`: произнести текст колонкой штатным синтезом.
Сообщение — `TVocalizeDirective`, поле `Append=1`. Подписка через `AliceCapabilityListener`,
события `TTS_STARTED` (6) и `TTS_COMPLETED` (1).

Скрипт `contrib/alice-say.py` отправляет текст через этот метод; проверен отправитель,
полный цикл на этой сборке не проверялся.

## Что не разобрано { #unknown }

- Остальные методы glagol и подписки (например, `on_reset_session` и
  `repeat_after_me` не найдены в строках `maind`, но были бы нужны для связывания).
- Точная семантика событий `TTS_STARTED` / `TTS_COMPLETED`.
- Срок жизни и способ ротации сертификата.
- Что включает `enableEndpointProtocol: true` (гипотеза: Endpoint-протокол `YandexIOReceiver`).
- Чем отличается `9899` (`glagold.port`) от `1961` (`glagold.externalPort`):
  набор команд и проверки одинаковые или нет.
- Назначение пути `/glagol/check_token` в `maind` (вероятно, проверка токена между
  колонкой и облаком — точно не установлено).

## Воспроизведение { #reproduce }

```sh
openssl s_client -connect <IP_КОЛОНКИ>:1961 -servername yandex-station-gen2 -showcerts
dns-sd -B _yandexio._tcp
dns-sd -L YandexIOReceiver-<DEVICE_ID> _yandexio._tcp
strings -a rootfs/system/vendor/quasar/maind | grep -i -E "glagol|externalCommandBypass|serverAction"
```

## Что это даёт { #practice }

- [Свои звуки](../recipes/sounds.md#native-tts) и [Управление голосом алисы](../recipes/upravlenie-golosom-alisy.md) — отправка произвольного текста на озвучку.
- [Spotify Connect](../recipes/spotify.md) — распознанная фраза из `9875` для голосовых команд.
- [Своя LLM вместо Алисы](../recipes/llm.md) — подмена `uniProxyUrl` вместо локального API.
