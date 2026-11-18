# glagol и локальные IPC Алисы

Два локальных канала управления: `glagol` (API интеграций, `YandexIOReceiver`) и protobuf-IPC
внутри `aliced` (порт `9875`), по которому Алиса отдаёт распознанную фразу и состояние.
Страница собрана по данным с устройства и из документации проекта; непроверенное помечено.

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
| `9899` | внутренний | `glagold`, API внутри устройства | `quasar.cfg` (`glagold.port`); из локальной сети — `Connection refused` |
| `1961` | внешний (`externalPort`) | `glagol` поверх TLS | `quasar.cfg` (`glagold.externalPort`); `openssl s_client` — TLSv1.2 |
| `9875` | локальный IPC | `aliced` | `quasar.cfg` (`aliced.port`) |
| `7447` | TCP/UDP | Zenoh | вики |
| `5353` | UDP | mDNS (`maind --platformd`) | вики |

## TLS на `1961` { #tls }

- `TLSv1.2`, шифр `ECDHE-RSA-AES128-GCM-SHA256`.
- Сертификат самоподписанный: `issuer=C=RU, CN=localhost, O=Yandex`, `subject` тот же,
  `serial=01`, сроки `2026-11-18 → 2029-11-17`. Генерируется при загрузке, к известному
  удостоверяющему центру не приколочен.
- Нужна ли клиентская аутентификация — не проверялось.

## mDNS: как колонку видят в сети { #mdns }

`glagold` объявляет тип сервиса `_yandexio._tcp` (`glagold.serviceType`), с префиксом
`YandexIOReceiver-` и именем хоста `yandex-station-gen2-XXXXXXXX` (`hostnamePrefix`).
Проверено с мака: `dns-sd -B _yandexio._tcp` показывает
`YandexIOReceiver-<DEVICE_ID> _yandexio._tcp.` в локальной сети.

## Локальный IPC `9875` { #ipc }

Формат кадра: 4 байта длины (little-endian), затем protobuf.

| Поле | Что |
|---|---|
| `253 = 3` | состояние Алисы |
| `252` | вложенное сообщение: `1` — статус, `2` — текст |
| статус | `0` — свободна, `1` — слушает, `3` — фраза распознана |

Тот же формат разобран в `devices/station-2.md` и используется в клиенте `alice-text`
(см. `recipes/spotify.md`): он печатает распознанную фразу и `@state N`.

## Команда `START_VOCALIZE` { #vocalize }

Метод `AliceCapability` с номером `18`: произнести текст колонкой штатным синтезом.
Сообщение — `TVocalizeDirective`, поле `Append=1`. Подписка через `AliceCapabilityListener`,
события `TTS_STARTED` (6) и `TTS_COMPLETED` (1).

Скрипт `contrib/alice-say.py` отправляет текст через этот метод; проверен отправитель,
полный цикл на этой сборке не проверялся.

## Что не разобрано { #unknown }

- Остальные методы glagol и подписки.
- Нужна ли аутентификация на `1961` и как она работает.
  В конфиге — `tokensStorage: ${DATA}/gsdkTokens.json`.
- Чем внутренний `9899` отличается от внешнего `1961` (обещают одно и то же API?).
- Точная семантика событий `TTS_STARTED` / `TTS_COMPLETED`.
- Срок жизни и способ ротации сертификата.
- Что включает `enableEndpointProtocol: true` (гипотеза: Endpoint-протокол `YandexIOReceiver`).

## Воспроизведение { #reproduce }

```sh
openssl s_client -connect <IP_КОЛОНКИ>:1961 -servername yandex-station-gen2 -showcerts
dns-sd -B _yandexio._tcp
python3 tools/cfg_ports.py quasar.cfg   # порты glagold и aliced
strings -a rootfs/system/vendor/quasar/maind | grep -i TVocalizeDirective
```

## Что это даёт { #practice }

- [Свои звуки](../recipes/sounds.md#native-tts) и [Управление голосом алисы](../recipes/upravlenie-golosom-alisy.md) — отправка произвольного текста на озвучку.
- [Spotify Connect](../recipes/spotify.md) — распознанная фраза из `9875` для голосовых команд.
- [Своя LLM вместо Алисы](../recipes/llm.md) — подмена `uniProxyUrl` вместо локального API.
