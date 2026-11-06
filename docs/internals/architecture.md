# Архитектура прошивки Quasar

Quasar — программный стек Яндекса на Amlogic-Станциях с Buildroot (Лайт, Мини, Мини 2,
Мини 3, Миди, Станция 2, Стрит, Умный хаб). Всё ниже снято со Станции Лайт, прошивка 3.21.

## Загрузка

Buildroot, BusyBox init. `/etc/inittab` монтирует `/proc`, `/dev/pts`, `/dev/shm`, задаёт
hostname и запускает `/etc/init.d/rcS`. Он выполняет `/etc/init.d/S??*` по алфавиту:

```text
S00hostname  S01rw-dirs  S01syslogd  S01watchdog  S02klogd  S02sysctl  S10mdev
S20urandom  S30dbus  S39w1_wifi_ant_config  S40dhcpcd-db  S40net.lo  S40wifi  S41dhcpcd
S45tas58xx  S49chrony  S49teeinit  S50hci0  S51bluetoothd  S52bluealsa  S53bluealsa-aplay
S54default-bluez-agent  S60touch_buttons_settings  S70unbound  S98pstore-clear  S99quasar
```

На консоли UART вместо стандартного `getty` запущен `getty_rabbit_hole` (вход закрыт, см.
[UART](../start/recovery.md#serial)).

### Read-only rootfs { #rootfs }

`/` монтируется ядром `ro` (у Станций на eMMC — из `PARTLABEL=system`, cmdline
`root=PARTLABEL=system ro rootwait skip_initramfs`). Это не случайность и не защита от
правок, а осознанный appliance-дизайн — в `/etc/inittab` штатно присутствует (и
закомментирована) строка:

```text
#::sysinit:/bin/mount -o remount,rw /
```

То есть сам вендор предусмотрел `remount rw` корня при разработке образа; ничего не
откатывает и не карает такую правку сама по себе (но см.
[«Подводные камни»](gotchas.md) про `sync` и зависания). Отдельные подкаталоги `/`,
которым штатно нужна запись, не хранятся на самом `system` — их пробрасывает бинд-маунтами
скрипт `S01rw-dirs` (виден в списке выше) по списку из `/etc/rw-dirs.d/*.conf`, указывая на
реально-записываемые разделы (`/data`, `/ota`). Целостность `system` в такой модели держится
соглашением (ro-монтирование), а не принуждением (verity/подпись) — на Станции 3 (orion)
подтверждено статическим анализом дампа: `dm-verity` в ядре скомпилирован
(`CONFIG_DM_VERITY=y`), но не активен (`avb2=0` в U-Boot env, нет `dm=` в cmdline), и
boot-скрипт U-Boot читает только раздел `boot` (`imgread kernel boot`), к `system` вообще
не обращаясь — подробности и полный разбор `env`/secure-boot цепочки на
[странице модели](../devices/station-3.md#remount-rw). На других моделях семейства не
перепроверялось — возможны отличия.

## Запуск quasar

`S99quasar` → `/system/vendor/quasar/onboot.sh start`:

1. включает overcommit памяти (`echo 1 > /proc/sys/vm/overcommit_memory`);
2. очищает остатки OTA в `/bkupgrade/`;
3. задаёт пути библиотек: `LD_LIBRARY_PATH=/system/vendor/quasar:/system/vendor/quasar/libs`
   и `GST_PLUGIN_PATH=/system/vendor/quasar/libs`;
4. скриптом `activate_adb.sh check` поднимает `adbd`, если найдены маркеры в `/data/quasar/`;
5. скриптом `run.sh` задаёт лимиты `ulimit -n 10240`, `ulimit -s 1024` и запускает
   `quasar_launcher2 /system/vendor/quasar/launch.json`.

## `maind`

Почти всё — один бинарник `/system/vendor/quasar/maind`. `quasar_launcher2` запускает его
несколько раз с разными ролями (см. `launch.json`):

| Роль | Что делает |
|---|---|
| `--platformd` | основной процесс; в том числе читает кнопки (`/dev/input/event1`) |
| `--mediad` | плеер: ответы Алисы и музыка, вывод в ALSA |
| `--telemetry` | [телеметрия](telemetry.md): что собирает и куда отправляет |
| `--fluent-bitd` | логи |
| `--updatesd` | обновления (OTA); убирается при [отключении обновлений](../start/ssh.md#kill-ota) |
| `--updater_gateway` | шлюз обновлятора через unix-сокет `/tmp/updater.sock` |

Симлинки на `maind` в том же каталоге: `led_util`, `tcp_alsa_writer`,
`keymaster_proxy_app`, `quasar_client`.

Кроме ролей, в `maind` зашит диспетчер диагностических команд. Их больше, чем оборачивает
скрипт [`q`](#q): помимо перечисленных поддерживаются `--nettest`, `--build-timestamp` и
`--device-localization`.

!!! warning "Команда `--getprop` отдаёт неверную архитектуру"
    Обработчик `--getprop` отдаёт Android-свойства с фиксированным значением
    `ro.product.cpu.abi=arm64-v8a`. Это не отражает реальную архитектуру: сам процесс `maind` —
    32-битный (`ELF32`, `armhf`), userspace тоже 32-битный. Не ориентируйтесь на этот вывод
    при сборке бинарников.

## `launch.json`: как устроены задачи { #launch-json }

`quasar_launcher2` — универсальный супервизор процессов, не привязанный к `maind`: у каждой
задачи в `launch.json` свой путь `path` к исполняемому файлу, и это не обязательно `maind` с
другим `arg`. На Станции 3 (orion) часть задач запускает отдельные бинарники — `begemot`
(поисковый wizard) и `bulbik` (сценарии умного дома) — со своими путями, не
симлинками на `maind` (см. [страницу модели](../devices/station-3.md#differences)).
Обе роли — чисто облачные (без интернета бесполезны) и
[отключаемы](../recipes/station3-disable-wizard.md) тем же способом, что и
`telemetry`/`fluent-bitd`. Снято со Станции 3, `factory-13`:

```json
{
  "name": "telemetry",
  "delay": 5,
  "allowedRestartIntervalSeconds": 600,
  "root": ".",
  "path": "/system/vendor/quasar/maind",
  "arg": ["--telemetry"],
  "order": 0,
  "log": false
}
```

Поля:

- `path`/`arg`/`root` — что и с какими аргументами запускать (рабочий каталог — `root`).
- `envs` — переменные окружения только для этой задачи (например, `mediad` получает
  `MALLOC_ARENA_MAX=2`).
- `order` — порядок **старта** (меньше — раньше), не приоритет важности: на Станции 3
  `telemetry`/`fluent-bitd` стартуют первыми (`order: 0`), `platformd` — следом (`1`), и это
  не случайность — другие роли ожидают, что агрегатор телеметрии к их собственному старту уже
  поднят (хотя и переживают, если его всё-таки нет, см. ниже).
- `allowedRestartIntervalSeconds` — *(вывод)* похоже на допустимый интервал между
  автоматическими перезапусками самого `quasar_launcher2`: у `mediad` он короткий (`10`,
  плеер должен восстанавливаться быстро), у большинства ролей — `600` (10 минут). Проверено
  только относительными значениями между ролями, не точная семантика при превышении интервала.
- `loggerPath`/`loggerArgs` — отдельный процесс-логгер для задачи (например, `bulbik`
  запускает собственный `maind --loggerd bulbik` только для сбора своих логов).

!!! note "Секции `quasar.cfg` не всегда = отдельная задача в `launch.json`"
    Не каждый ключ верхнего уровня в `quasar.cfg` (`monitord`, `metricad`, `metrica2d`,
    `syncd`, `backend` и т.п.) соответствует своему процессу в `launch.json` — часть из них
    это внутренние компоненты уже существующих ролей (например, сборщик метрик `monitord` не
    значится отдельной задачей, хотя у него свой порт). Респавн процессов — исключительно
    зона ответственности `quasar_launcher2` по `launch.json` (`allowedRestartIntervalSeconds`
    выше); `monitord.servicesList` — это просто список для отчёта о здоровье (мониторинг),
    не список на перезапуск. Проверено на Станции 3: сама роль `telemetry` присутствует в
    `monitord.servicesList`, но её остановка не вызвала никаких действий со стороны
    `monitord` — только таймауты у клиентов, которые к ней обращались.

## Звук

Все плееры пишут в ALSA `default` (`/etc/asound.conf`):

```mermaid
flowchart LR
    default --> softvol["softvol Master"] --> plug --> dmix_spk --> hw["hw:0,0<br>(TDM-B → усилитель)"]
```

Регулятор `Master` — программный, его изменяют кнопки и голосовые команды громкости
(`set_volume.sh N` эквивалентно `amixer set Master N%`).
Захват звука выполняется через `multi_capture`: 4 канала микрофонов (`hw:0,1`, PDM) и 2 канала
петли с выхода усилителя (`hw:0,0`, опорный сигнал для эхоподавления).

### `maind --gst-launch` { #gst-launch }

Встроенный GStreamer: тем же бинарником проигрывается любой пайплайн, от файла до
интернет-потока. Команды и примеры — в рецепте [Свои звуки](../recipes/sounds.md).

## Модели на борту

| Каталог | Назначение моделей |
|---|---|
| `spotter_models/` | activation, command, counteractivation, spotterRecognizer, vad |
| `vqe_models/` | noise_reducer |
| `matter/` | http, paa |

## Где что лежит

| Путь | Что это |
|---|---|
| `/system/vendor/quasar/launch.json` | какие роли `maind` запускать |
| `/system/vendor/quasar/quasar.cfg` | конфиг всех демонов (адреса, звук, VQE, громкость) |
| `/system/vendor/quasar/ota_script.pub` | ключ проверки подписи OTA |
| `/data/quasar/devices.json` | ключи и токены устройства — **никогда не публикуйте** |
| `/data/quasar/activate_adb_quasmodrom`, `activate_network_adb` | маркеры автозапуска ADB; на старых сборках — `/data/quasar_activate_*`, см. [шаг 1](../start/ssh.md#perm-adb) |
| `/data/quasar/daemons_logs/` | логи: `maind.log`, `mediad.log`, `yiod.log`, `wifid.log`, `updatesd.log` … |
| `/etc/asound.conf` | маршрутизация звука ALSA |

На Лайт 1 с прошивкой `0.369.1.46.4778262442.20261013.297`
в `quasar.cfg` присутствует параметр `configuration_patch.patch_dir`
со значением `${DATA}/quasar_patches` (на проверенном устройстве каталог был пуст).
Это только находка в конфиге: формат патчей и возможность безопасно
менять настройки таким способом **не проверены**.

## Хелпер `q`

Скрипт `/system/vendor/quasar/q` оборачивает вызовы `maind` и системные утилиты:

```text
q <команда>
команды: start, stop, restart, version, device-id, wifi-info,
         glagol-connections, full-info, backend-dev, backend-prod, cli, getprop
```
