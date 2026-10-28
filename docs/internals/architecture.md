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
| `/data/quasar/activate_adb_quasmodrom`, `activate_network_adb` | маркеры автозапуска ADB |
| `/data/quasar/daemons_logs/` | логи: `maind.log`, `mediad.log`, `yiod.log`, `wifid.log`, `updatesd.log` … |
| `/etc/asound.conf` | маршрутизация звука ALSA |

## Хелпер `q`

Скрипт `/system/vendor/quasar/q` оборачивает вызовы `maind` и системные утилиты:

```text
q <команда>
команды: start, stop, restart, version, device-id, wifi-info,
         glagol-connections, full-info, backend-dev, backend-prod, cli, getprop
```
