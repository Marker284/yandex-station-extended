# Отключение телеметрии на Станции 3 { #station3-disable-telemetry }

Рецепт полностью останавливает отправку диагностической телеметрии (AppMetrica,
clickdaemon, логи через fluent-bit) — без влияния на голосовой пайплайн Алисы
(`backendUrl`/`uniProxyUrl` не трогаются, это отдельная тема —
[Бэкенд (Self-hosted)](bekend-self-hosted.md)). Общее устройство телеметрии
разобрано в [Телеметрии](../internals/telemetry.md).

**Проверено на:** Станция 3 (orion), прошивка `factory-13`
(`0.13.1.36.3322101745.20250823`), **два физических устройства**, root
([DNS-метод](../start/root.md)), обновления отключены
([`yandex-noupdate.sh`](../start/ssh.md#kill-ota)). Проверены применение,
перезагрузка (оба устройства переживают её без побочных эффектов) и откат.

!!! note "Другой подход, не проверенный на Станции 3"
    В репозитории уже есть
    [`yandex-station-privacy.sh`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/yandex-station-privacy.sh) —
    он блокирует только clickdaemon-эндпоинты через `quasar.cfg` + постоянный
    шаблон DNS-резолвера `/bkupgrade/data/unbound.conf.head`. На Станции 3
    `/bkupgrade` — симлинк на раздел `ota` ([карта разделов](../devices/station-3.md#partitions)),
    но именно файла `data/unbound.conf.head` там нет (раздел почти пустой),
    так что DNS-часть того скрипта здесь не сработает «из коробки», а
    AppMetrica/fluent-bit он не трогает в любом случае — не тот слой. Рецепт
    ниже — для Orion (Станция 3), действует иначе: убирает сами роли `maind`
    целиком, не их DNS-адреса.

## Шаги { #steps }

1. Скопируйте скрипт на колонку и запустите:

    ```sh
    adb push contrib/yandex-disable-telemetry.sh /data/opt/yandex-disable-telemetry.sh
    adb shell sh /data/opt/yandex-disable-telemetry.sh
    adb shell reboot
    ```

2. После перезагрузки проверьте:

    ```sh
    adb shell sh /data/opt/yandex-disable-telemetry.sh status
    ```

    ```text
    == статус телеметрии ==
    launch.json : telemetry убран
    launch.json : fluent-bitd убран
    -- процессы:
       maind --telemetry не запущен
       maind --fluent-bitd не запущен
    ```

## Откат { #rollback }

```sh
adb shell sh /data/opt/yandex-disable-telemetry.sh restore
adb shell reboot
```

!!! warning "Бэкап лежит на колонке и пропадёт при сбросе"
    Оригинал `launch.json` сохраняется в `/data/opt/backup/launch.json.orig` —
    как и для `yandex-noupdate.sh`, забирайте его к себе сразу после применения
    (`adb pull /data/opt/backup ./backup-колонки`), если важно иметь копию
    отдельно от самой колонки.

## Доп. слой (опционально): обнулить списки событий в `quasar.cfg` { #event-lists }

Не обязателен при выполненных шагах выше (роли уже не запускаются — отправлять
физически нечему), но дёшево подстраховывает на случай, если `telemetry`
когда-нибудь снова окажется живым (например, для другого теста): даже
запущенный агрегатор будет посылать пустой payload.

```sh
adb pull /system/vendor/quasar/quasar.cfg
jq '.metrica2d.consumers.clickdaemon.eventWhitelist = {}' quasar.cfg > quasar.cfg.1
jq '.metricad.eventBlacklist = [
  "AudioError","NetInterfaceUp","audioClientBufferStalled","audioClientError",
  "connectionStats","cpu_info","device_power_on","directiveCompleted",
  "directiveHandled","directiveStarted","glagold_heartbeat","http_request",
  "hybrid_request","local_analytics_info","local_request","mediadPlaybackError",
  "minidump","multiroomAround","multiroomClockDiff","musicPlayerBufferStalled",
  "notifyOnAudioPlaybackError","notifyOnPlaybackError","phraseSpottedWithoutInternet",
  "pings","processStart","setupConfigurationError","systemMetrics","wifiConnect",
  "wifiDisconnect","wifiReconnectConfigReload","wifiReset","wifiStats",
  "yandexRadio2RecoveryFail","ysk_error_network","ysk_error_timeout"
]' quasar.cfg.1 > quasar.cfg.new

adb push quasar.cfg.new /data/quasar.cfg.new
adb shell "mount -o remount,rw / && cp /system/vendor/quasar/quasar.cfg /data/quasar.cfg.backup && cp /data/quasar.cfg.new /system/vendor/quasar/quasar.cfg && sync && mount -o remount,ro /"
adb shell reboot
```

`jq` нужен на компьютере (на Linux/macOS обычно есть из коробки или ставится
пакетным менеджером; на самой колонке можно воспользоваться `yse install
ent:jq`, если ставить прямо на ней).

!!! warning "Список AppMetrica-событий собран вручную, не гарантированно полный"
    В `quasar.cfg` нет готового каталога **всех** возможных событий AppMetrica
    (в отличие от clickdaemon, у которого есть явный whitelist) — список выше
    собран из текущего `eventBlacklist`, служебного
    `metricad.teleme3d.priorities` и строк, подтверждённых в самом бинаре
    `maind` (`strings`), на прошивке `factory-13`. На других сборках
    могут быть другие/дополнительные имена событий. Это не критично:
    основная защита — удаление ролей (шаги выше) и сетевая изоляция,
    этот список — только дополнительный, не единственный слой.

## Как это работает { #how-it-works }

- Роли `maind` запускает `quasar_launcher2` по списку задач из
  `/system/vendor/quasar/launch.json` (как и `updatesd`, см.
  [отключение OTA](../start/ssh.md#kill-ota)). `telemetry` — это агрегатор
  (AppMetrica + clickdaemon очереди), `fluent-bitd` — отдельная роль,
  отгружающая текстовые логи. Убрав task-блоки из `launch.json`, лаунчер
  просто не запускает эти роли — в отличие от `kill`/`SIGSTOP`, это переживает
  перезагрузку.
- Остальные роли (`platformd`, `mediad`, `begemot`, `bulbik`) штатно
  переживают отсутствие телеметрии: при обращении к её внутреннему сервису
  (`metricad`) они получают таймаут и просто логируют предупреждение
  (`metrica_connector.cpp:519`, `"... service has expired"`), без падений —
  проверено часами наблюдения на живой колонке. Это ожидаемо: сама роль
  `telemetry` в `launch.json` имеет `allowedRestartIntervalSeconds: 600` —
  то есть прошивка штатно рассчитана переживать её временное отсутствие
  (падения/перезапуски) и в обычной работе, иначе она не работала бы
  надёжно ни на одной колонке.
- Своего локального выключателя телеметрии в `quasar.cfg` нет — только
  параметры самого процесса (логирование, лимит памяти) и списки событий
  (whitelist/blacklist), см. [доп. слой](#event-lists) выше.

## Ограничения { #limits }

- После правки `mount -o remount,ro /` может разово отдать `Device or
  resource busy` без зависания (похоже на нормальную флуктуацию, не
  связанную именно с этой правкой) — перезагрузка решает и одновременно
  подтверждает, что изменение переживает её.
- На одном из двух проверенных устройств после такой перезагрузки
  наблюдался цикл из нескольких Wi-Fi/DHCP-переподключений подряд с
  последующим зависанием, потребовавший физического отключения питания.
  Повторная проверка на **втором** устройстве (точно тот же файл,
  побайтово) прошла без единого сбоя, а после включения питания первое
  устройство тоже заработало штатно на тех же файлах без повреждений —
  похоже на случайную флаковость конкретного экземпляра (на этом же
  устройстве ранее уже наблюдалось похожее поведение после аппаратного
  сброса, не связанное с данной правкой), а не на следствие самой правки.
  Имейте план восстановления (физический доступ к питанию) на всякий
  случай перед применением на любой колонке впервые.
- Не проверялось на других моделях — архитектура ролей `maind`/`launch.json`
  общая для Buildroot-колонок (см. [Как это устроено](../internals/architecture.md)),
  но конкретные названия ролей и поведение при их отсутствии стоит
  перепроверить перед применением на другой модели.
