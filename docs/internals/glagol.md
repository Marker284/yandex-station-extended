# glagol и локальные IPC Алисы

Два локальных канала управления: `glagol` (API интеграций, `YandexIOReceiver`) и
protobuf-IPC внутри `aliced` (порт `9875`), по которому Алиса отдаёт распознанную фразу и
состояние. Страница собрана по данным с устройства и из документации проекта;
непроверенное помечено.

**Проверено на:** Станция 2 (`yandexmidi`), прошивка `0.369.1.46.4793639783.20261020.295`,
ноябрь 2026.

## Что это { #what }

- `glagol` (`glagold` в `quasar.cfg`) — локальный API, по которому колонкой управляют
  приложения и интеграции, например [YandexStation для Home Assistant](https://github.com/AlexxIT/YandexStation).
- Локальный IPC `9875` (`aliced`) — поток кадров Алисы: состояние, распознанная фраза и
  отправка ей команд.

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
авторизацией Яндекса (тот же OAuth, что и у аккаунта владельца). `platform` — как в TXT-записи
(`yandexmidi` для Станции 2). Проверено с чужим токеном — колонка отвечает
WebSocket `Close code=4000, reason="Invalid token"` и закрывает соединение.

На самой колонке токен хранится в `gsdkTokens.json` (`glagold.tokensStorage`); файла нет
в снимке `/data` этого устройства — не проверялось.

## Как устроен обмен по glagol { #protocol }

Соединение — WebSocket (WSS). Клиент шлёт JSON:

```json
{"conversationToken": "<token>", "id": "<uuid>",
 "payload": {"command": "…"}, "sentTime": 1763450000000}
```

- `conversationToken` — glagol-токен (см. выше).
- `id` — uuid запроса; колонка отвечает сообщениями с тем же `id`.
- `sentTime` — миллисекунды Unix epoch.
- Команды: `softwareVersion`, `ping` (ping предназначен для поддержания сессии),
  `serverAction` с `serverActionEventPayload.type = "server_action"` и
  `name = "on_reset_session"`.

Колонка сама шлёт периодические сообщения со `state` (громкость, плеер, таймеры,
`timeSinceLastVoiceActivity`) и `vinsResponse` (ответ Алисы, карты, `is_streaming`,
`output_speech`) — так работает наблюдение громкости, плеера и ответа Алисы через интеграции.

Набор команд зависит от модели и прошивки: на Orion (Станция 3) команды
`softwareVersion`, `ping`, `getVersion`, `status`, `allStates`, `getState`, `get_status` не
отвечают (см. [Станция 3](../devices/station-3.md#glagol)).

## Команда `START_VOCALIZE` { #vocalize }

Метод `AliceCapability` с номером `18`: произнести текст колонкой штатным синтезом.
Сообщение — `TVocalizeDirective`, поле `Append=1`. Подписка через `AliceCapabilityListener`,
события `TTS_STARTED` (6) и `TTS_COMPLETED` (1).

Скрипт `contrib/alice-say.py` отправляет текст через этот метод; проверен отправитель,
полный цикл на этой сборке не проверялся.

## Что не разобрано { #unknown }

- Остальные методы glagol и подписки.
- Точная семантика событий `TTS_STARTED` / `TTS_COMPLETED`.
- Срок жизни и способ ротации сертификата.
- Что включает `enableEndpointProtocol: true` (гипотеза: Endpoint-протокол `YandexIOReceiver`).
- Чем отличается `9899` (`glagold.port`) от `1961` (`glagold.externalPort`): набор команд и
  проверки одинаковые или нет.

## Воспроизведение { #reproduce }

```sh
openssl s_client -connect <IP_КОЛОНКИ>:1961 -servername yandex-station-gen2 -showcerts
dns-sd -B _yandexio._tcp
dns-sd -L YandexIOReceiver-<DEVICE_ID> _yandexio._tcp
strings -a rootfs/system/vendor/quasar/maind | grep -i TVocalizeDirective
```

## Что это даёт { #practice }

- [Свои звуки](../recipes/sounds.md#native-tts) и [Управление голосом алисы](../recipes/upravlenie-golosom-alisy.md) — отправка произвольного текста на озвучку.
- [Spotify Connect](../recipes/spotify.md) — распознанная фраза из `9875` для голосовых команд.
- [Своя LLM вместо Алисы](../recipes/llm.md) — подмена `uniProxyUrl` вместо локального API.
