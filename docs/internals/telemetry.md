# Телеметрия

Что колонка собирает о себе и куда это отправляет. Роль `maind --telemetry` (см.
[Архитектура](architecture.md#maind)). Снято со Станции Миди (Cucumber, ПО `0.369.1.50…`): по
`quasar.cfg`, живым логам `telemetry.log` и реальному трафику с устройства (root по adb), плюс
строки и RTTI-имена в `strings maind`. Бинарь один на всех Amlogic-моделях, картина общая.
Помечено *(вывод)* то, что не подтверждено напрямую.

!!! abstract "Главное"
    `--telemetry` — это **агрегатор**: другие роли `maind` не ходят в облако сами, а шлют
    события по локальному IPC в этот процесс. Он копит их в локальных хранилищах на `/data` и
    двумя очередями отгружает в облако:

    - **AppMetrica** — `https://report.appmetrica.yandex.net/report` (SDK-аналитика Яндекса);
    - **clickdaemon** — `https://clck.yandex.net/quasar_metrics/write/batch` (продуктовые события).

    Плюс логи уходят через `--fluent-bitd` на тот же `clck.yandex.net`. Собираются идентичность
    устройства, Wi-Fi/сеть, геолокация *(вывод)*, системное здоровье (CPU/RAM/диск/крэши),
    события Алисы, плеера, умного дома, биометрии и обновлений — это **диагностическая**
    телеметрия, часть работы сервиса. **Запись голоса** (`SoundLogger` / spotter-логирование) —
    **отдельный** канал (uniproxy), который управляется согласием владельца (настройка
    «Помогать Алисе стать лучше» в Яндекс ID) — см. [Когда что включается](#when).

## Конвейер { #pipeline }

```text
  источники внутри maind              агрегатор (maind --telemetry)        отправка в облако
 ──────────────────────          ──────────────────────────────────     ──────────────────────
  platformd / mediad / …          teleme3d (SinksConfigurer)             appmetricaBatchSender ──► report.appmetrica.yandex.net
  ├─ IpcMetricsSender  ─IPC─►      ├─ очередь событий (persistentBatch)   clickdaemonBatchSender ─► clck.yandex.net/quasar_metrics
  ├─ metrics_collector            ├─ metrica UUID + session_id           (оба — из процесса pid --telemetry)
  ├─ net_devices_monitor          └─ throttled (rate-limit)
  └─ fluent-bitd (логи)  ─────────────────────────────────────────────► clck.yandex.net /quasar/write/json/batch (TLS :443)
  monitord (metrics_collector, период 10 c) ──────────────────────────► пинги quasar.yandex.ru + systemMetrics в телеметрию
```

Процессы на живом устройстве (`ps`): `maind --telemetry`, `maind --fluent-bitd`,
`maind --platformd`, `maind --mediad`, `maind --updatesd`, `maind --loggerd`.

Компоненты (имена исходников — дословно из бинаря, ключи — из `quasar.cfg`):

- **`teleme3d`** — конфиг роли `--telemetry`: `apiKey`, `appMetricaStartupHost`,
  `appmetricaFallbackHosts`, `clickdaemon.endpointUri`, белые списки событий. Код —
  `teleme3d_endpoint.cpp`, `SinksConfigurer`, `default_sinks_configurer.cpp`.
- **AppMetrica-отправитель** — `metrica_batch_sender_base.cpp`, `persistent_batch_sender.cpp`,
  `appmetricaBatchSender`; метаданные и UUID в `${DATA}/quasar_metricad.json` и
  `${DATA}/data/metrica/clickdaemon/metadata.json`, session-id в `session_id_part.txt`.
- **clickdaemon-отправитель** — `clickdaemonBatchSender`; та же очередь, другой endpoint.
- **`monitord`** (`metrics_collector.cpp`, порт 9895) — системные метрики каждые 10 c, дамп раз
  в 300 c; `pstorePath=/sys/fs/pstore`, пинги `quasar.yandex.ru`, список сервисов для watchdog.
- **`metrica2d`** (порт 9904) и **`metricad`** (порт 9887) — gRPC-эндпоинты метрики
  (см. [Сеть и порты](network.md)).
- **`--fluent-bitd`** — отгрузка текстовых логов на `clck.yandex.net:443`
  (`/quasar/write/json/batch`).

Защита от переполнения и rate-limit: `throttled_callable`, `isEventTooBig`, `maxStorageSizeMb`,
`maxEventsInBatch`. У самого процесса — `selfDestroyer` с лимитом RSS 64 МБ.

## Куда отправляется (с устройства, подтверждено) { #endpoints }

Хосты задаются в `quasar.cfg` (ключ `teleme3d`) и могут переопределяться startup-ответом раз в
сутки. Реальные значения на прошивке `0.369`:

| Назначение | Хост | Примечание |
|---|---|---|
| AppMetrica report | `https://report.appmetrica.yandex.net/report` | основной; в логе `sent successfully … batches` |
| AppMetrica startup | `https://startup.mobile.yandex.net` | выдача актуальных хостов, раунд раз в 86400 c |
| clickdaemon (продукт.) | `https://clck.yandex.net/quasar_metrics/write/batch` | очередь `clickdaemonBatchSender` |
| fluent-bit (логи) | `clck.yandex.net:443` `/quasar/write/json/batch` | роль `--fluent-bitd` |
| monitord ping | `quasar.yandex.ru` | ICMP раз в 10 c |

Реальный запрос в AppMetrica (из `telemetry.log`, идентификаторы заменены на `<…>`):

```text
https://report.appmetrica.yandex.net/report?protocol_version=2&locale=ru_RU
  &analytics_sdk_build_type=embedded_cpp&analytics_sdk_version_name=1.0.0
  &api_key_128=46b160aa-bba7-421a-9e3d-f366e76386ef&app_id=aliced&app_platform=linux
  &app_version_name=0.369.1.50.…&device_type=desktop&manufacturer=YANDEX&model=cucumber
  &os_version=<полный uname>&deviceid=<серийник R…NK6K>&uuid=<metrica-uuid>
```

То есть в каждом отчёте уходят: **серийник устройства**, **metrica-UUID**, модель (`cucumber`),
производитель, версия ПО и **полная строка `uname`** ядра.

!!! info "Что такое `api_key_128`"
    `api_key_128` (`46b160aa-bba7-421a-9e3d-f366e76386ef`) — это *application API key* AppMetrica,
    UUID-идентификатор **приложения** (здесь — `aliced`, стек Станции), зашитый в прошивку. Это
    **клиентский ключ, а не секрет**: он одинаков на всех колонках и извлекается из прошивки
    любого устройства. Знание ключа позволяет только *слать* события в поток приложения `aliced`
    (т.е. максимум — засорять статистику), но **не даёт доступа на чтение** чьей-либо телеметрии —
    для этого нужен отдельный секретный *Post API key* (OAuth-токен Reporting API), которого в
    прошивке нет. Поэтому ключ безопасно приводить открыто — в отличие от per-device `uuid` и
    серийника, которые здесь заменены на `<…>`.

### Что ещё видно на живом устройстве

- **UUID два разных**: AppMetrica-UUID лежит в `${DATA}/quasar_metricad.json` вместе со списком
  актуальных хостов (`"reports":[…report.appmetrica.yandex.net]`,
  `"startups":[…startup.mobile.yandex.net]`),
  а у clickdaemon свой UUID в `${DATA}/data/metrica/clickdaemon/metadata.json`.
- **startup раз в сутки**: `Go for startup` → `Next startup round delayed for 86400 seconds`;
  именно он обновляет список report-хостов (`onStartupResult <uuid> urls:[…]`).
- **очереди реально активны**: в `telemetry.log` видно `appmetricaBatchSender sent successfully
  2303 batches` и `clickdaemonBatchSender … 1015 batches` (несколько тысяч батчей за аптайм);
  при недоступности сети — `curl error: 28` и повтор с задержкой, без потери (`dropped 0`).
- **session-id** собирается из постоянной (`${DATA}/data/metrica/session_id_part.txt`) и
  временной (`${TMP}/metrica/session_id_part.txt`) частей.

!!! note "Международный вариант (Yasmina / Yango)"
    В `quasar.cfg` есть второй набор хостов для зарубежного рынка: `startup.appmetrica.yango.com`,
    `clck.yasmina.yango.com`, `scbh.yasmina.yango.com`. Выбирается по региону устройства.

## Что собирается { #collected }

Телеметрия идёт в двух protobuf-форматах; что именно слать — задано **белыми списками** в
`quasar.cfg`.

**AppMetrica — `ReportMessage`** (~32 события, `teleme3d.appmetrica.events`). В основном
сетевая и системная диагностика: `NetInterfaceUp`, `wifiConnect` / `wifiDisconnect` /
`wifiReport`, `emptyIp` / `wrongIp` / `internetRecovery*`, `pings`, `connectionStats`,
`systemMetrics`, `processStart`, `phraseSpottedWithoutInternet`,
`directiveStarted/Handled/Completed`,
`ysk_error_network` / `ysk_error_timeout`. Поля proto: `Session → {SessionDesc → Location,
CellularNetworkInfo; Event → Account, NetworkInfo → WifiAccessPoint}`, `Location`,
`NetworkInterface`, `EnvironmentVariable`, `SimInfo`. Режим env-ключей — `black` (чёрный список).

**clickdaemon — продуктовые события** (**185 включённых**, `teleme3d.clickdaemon.events`). Это
подробная продуктовая аналитика. Категории с примерами ключей:

- **Алиса / запросы** — `aliceRequest`, `getNextRequest(Failed)`, `local_request`,
  `hybrid_request`, `http_request`, `localRecognitionData`, `local_analytics_info`.
- **Аудио / музыка** — `audioClient*` (play/underrun/error/altUrl), `musicPlayer*`,
  `YandexMusicPlay/SwitchTrackTimeout`, `AudioError`, `dsp_info`, `equalizerStats`,
  `audioDeviceStats`.
- **Биометрия (голосовой отпечаток)** — большой блок `bio*`: `bioEnrollment*`, `bioAddAccount*`,
  `bioRemoveAccount*`, `bioShareEnrolledPerson*`, `bioLibraryDiagnosticData`, `bioLogStorage`.
- **Аккаунты / токены** — `addGuestUser*`, `clearGuestUser*`, `changeAccount*`, `deleteAccount*`,
  `authTokenRefresh*`, `backendStatusChanged`.
- **Умный дом** — `iotDiscovery*`, `iotDirectiveResult`, `iotDeviceStatusDuration`,
  `iotScenariosLaunch*`, `localIotScenario*`, `matter_diagnostics_event`, `glagolPlayMusic`.
- **Bluetooth** — `bluetooth_devices_list`, `bluetooth_source_connected/disconnected`,
  `bluetooth_transport_metrics`.
- **Будильники / сценарии** — `addAlarm`, `alarmDirectiveReceived`, `alarmSoundFallback*`,
  `dcpc*` (device control panel).
- **Система / обновления / крэши** — `device_power_on`, `minidump`, `minidump_on_update`,
  `log_error`, `setupConfigurationError`, `failedSetupNetwork`, `VqeOnDspRestarted`,
  `ledDisplayAnimationStart`, анимации.

**Системные метрики** (`monitord`, каждые 10 c): CPU/PSI, память и `ooms`, диск (`mmcblk0`,
`diskstats`), зависшие процессы, крэши из `/sys/fs/pstore`, факт включения (`device_power_on`).

**A/B и трассировка**: к событиям и дампам цепляются `quasmodrom_group=production`,
`quasmodrom_subgroup` и список `test_buckets` (идентификаторы экспериментов), а в
backend-метрики — `SetraceReqId` / `SetraceClientReqId`.

!!! note "Звук с микрофона — отдельно и по согласию"
    Фрагменты звука (spotter-логирование, `RandomSoundLogger` / `cachingSoundLogSender`) отгружаются
    для улучшения распознавания своим каналом (**uniproxy**, канал Алисы), не через clickdaemon, и
    управляются согласием владельца, а не ключом в `quasar.cfg`. Это не диагностическая телеметрия —
    см. [Когда что включается](#when).

## Когда что включается { #when }

Телеметрия делится на два слоя, и управляются они по-разному:

1. **Диагностический** (AppMetrica `ReportMessage`, clickdaemon-события, `monitord` systemMetrics,
   fluent-bit логи, minidump-крэши) — часть работы сервиса. Отдельного пользовательского тумблера
   под него на устройстве нет; состав задаётся белыми списками (`quasar.cfg` + онлайн-конфиг).
2. **Запись голоса** (spotter-логирование / `SoundLogger`) — управляется согласием владельца
   «Помогать Алисе стать лучше» (Яндекс ID → [Доступы к данным](https://id.yandex.ru/personal/data-access)
   → **Алиса**).

### Как настройки доезжают до колонки

Колонка периодически получает из облака конфиг (`sync_endpoint.cpp`, лог `Config updated`): три
блока — `account_config` (привязан к владельцу), `device_config` и `system_config`. Именно сюда
прилетает состояние согласий и параметры логирования. Диагностические белые списки при этом
**дополняются** онлайн (синтаксис `"+events":[…]` в `teleme3d.appmetrica`), а не только берутся из
`quasar.cfg`.

### Что меняет тумблер «Помогать Алисе стать лучше»

По [справке Яндекса][yq]: до активационного слова в облако **ничего не передаётся**; голосовой
запрос уходит **после активации** и **может** использоваться для обучения Алисы, но только **в
обезличенном виде**. Технически согласие проявляется в `account_config`, который приходит
на колонку:

- `doNotUseUserLogs` — флаг «не использовать логи пользователя». При включённом согласии он
  `false` (логи использовать можно); выключишь галочку — станет `true` *(вывод: обратное значение)*.
- **spotter-логирование** (`voiceDialogSettings`): колонка выгружает не весь звук, а **сэмпл**
  срабатываний активационного слова. Параметры задаются онлайн, напр.:
  `spotterLoggingVeryRareEventPercent` (доля «очень редких» срабатываний для выгрузки),
  `spotterLoggingRareEventPercent`, `*TailMillis` / `*StreamingLengthMillis` (сколько секунд звука
  вокруг срабатывания слать). При согласии проценты ненулевые → часть активаций уходит на сервер.
- `noise_detector.spotterLogging` — то же для детектора бытовых звуков (разбитие стекла, плач,
  лай, хлопок…): при включении логируются сэмплы этих событий.
- `onlineSpotterEnabled` — онлайн-валидация активаций (аудио активации уходит в облако на проверку).

То есть галочка влияет **на запись голоса/активаций**, а не на диагностическую телеметрию:
последняя (идентификаторы устройства, Wi-Fi, systemMetrics, крэши, продуктовые события) идёт
независимо от этого согласия.

### Почему на диске пусто, хотя согласие включено

`cachingSoundLogSender` (каталог `soundLogStorageDir`) — это **кэш на случай, если выгрузить
сейчас не вышло**. Сэмплы споттера стримятся сразу через uniproxy, поэтому при живой сети на диске
ничего не оседает, и каталога может не быть. Плюс выгружается малая доля срабатываний (проценты в
`spotterLogging*`), так что в произвольный момент очередь обычно пуста — само по себе это **не
значит**, что запись выключена.

Историю запросов можно скачать (в составе общего архива) или удалить: Яндекс ID →
[Управление данными](https://id.yandex.ru/profile/data) → сервис **Алиса**.

[yq]: https://alice.yandex.ru/support/ru/station/settings/query-history

## Где лежит на устройстве { #storage }

| Путь | Что это |
|---|---|
| `${DATA}/quasar_metricad.json` | metrica-UUID + список report/startup-хостов |
| `${DATA}/data/metrica/clickdaemon/metadata.json` | UUID clickdaemon |
| `${DATA}/data/metrica/session_id_part.txt` | постоянная часть session-id |
| `${DATA}/appmetrica/persistedBatch` | неотправленные батчи AppMetrica |
| `${DATA}/soundLogStorageDir` | кэш фрагментов звука на случай неудачной выгрузки (может отсутствовать) |
| `${LOGS}/telemetry.log` | лог роли `--telemetry` (отправки, startup) |
| `${DATA}/minidump/telemetry.dmp*` | крэш-дампы (поле `moveToMetrica: true` — уходят в метрику) |

`${DATA}` на колонке — `/data/quasar`, `${LOGS}` — `/data/quasar/daemons_logs`.

!!! tip "Как перехватить / проверить"
    - `SSLKEYLOGFILE` в бинаре (BoringSSL) — можно писать TLS-ключи и читать трафик в Wireshark.
    - Подмены DNS мало: есть `appmetricaFallbackHosts` и статические fallback-IP у части сервисов
      (см. [Подводные камни](gotchas.md)). Нужны правки hosts/маршрутов или keylog.
    - До отправки всё лежит локально (таблица выше) — можно читать, не трогая сеть.

## Как отключить { #disable }

**Штатно (без рута), запись голоса:** Яндекс ID → [Доступы к данным](https://id.yandex.ru/personal/data-access)
→ **Алиса** → выключить **«Помогать Алисе стать лучше»**. Это убирает использование записей для
обучения; диагностической телеметрии не касается.

**На устройстве (рут), ключи `quasar.cfg`** (факты, не рекомендация):

- `fluentBitDisabled` — выключить отгрузку логов fluent-bit;
- белые списки `teleme3d.appmetrica.events` / `clickdaemon.events` — сузить, что слать;
- `spotterLogging*` в `voiceDialogSettings` — параметры выгрузки сэмплов активаций;
- `maxStorageSizeMb` / `maxEventsInBatch` — лимиты; `monitord.metricsCollectorPeriodSec` — период.

Учти: эти ключи доезжают и из онлайн-конфига (`account_config`/`system_config`), так что правка
локального `quasar.cfg` может переопределяться при следующем `Config updated`.

Полностью изолировать от облака одной подменой DNS не выйдет — см. блок про fallback-хосты выше.
