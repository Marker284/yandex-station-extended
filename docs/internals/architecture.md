# Архитектура прошивки (quasar)

`quasar` — программа Яндекса на Amlogic-Станциях с Buildroot (Лайт, Мини, Мини 2,
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

На консоли UART вместо `getty` — `getty_rabbit_hole` (вход закрыт, см.
[UART](../start/recovery.md#serial)).

## Запуск quasar

`S99quasar` → `/system/vendor/quasar/onboot.sh start`:

1. `echo 1 > /proc/sys/vm/overcommit_memory`;
2. чистит остатки OTA в `/bkupgrade/`;
3. `LD_LIBRARY_PATH=/system/vendor/quasar:/system/vendor/quasar/libs`, `GST_PLUGIN_PATH=/system/vendor/quasar/libs`;
4. `activate_adb.sh check` — поднимает `adbd`, если есть маркеры ADB в `/data/quasar/`;
5. `run.sh`: `ulimit -n 10240`, `ulimit -s 1024` и
   `quasar_launcher2 /system/vendor/quasar/launch.json`.

## `maind`

Почти всё — один бинарник `/system/vendor/quasar/maind`. `quasar_launcher2` запускает его
несколько раз с разными ролями (см. `launch.json`):

| Роль | Что делает |
|---|---|
| `--platformd` | основной процесс; в том числе читает кнопки (`/dev/input/event1`) |
| `--mediad` | плеер: ответы Алисы и музыка, вывод в ALSA |
| `--telemetry` | телеметрия |
| `--fluent-bitd` | логи |
| `--updatesd` | обновления (OTA); убирается при [отключении обновлений](../start/ssh.md#kill-ota) |
| `--updater_gateway` | шлюз обновлятора через unix-сокет `/tmp/updater.sock` |

Симлинки на `maind` в том же каталоге: `led_util`, `tcp_alsa_writer`,
`keymaster_proxy_app`, `quasar_client`.

Кроме ролей, в `main` зашит диспетчер диагностических команд — их больше, чем оборачивает
[`q`](#q): помимо перечисленных есть ещё `--nettest`, `--build-timestamp` и
`--device-localization`.

!!! warning "`--getprop` синтезирует значения"
    Обработчик `--getprop` отдаёт Android-style свойства с **захардкоженным**
    `ro.product.cpu.abi=arm64-v8a`. Это не отражает реальную архитектуру: сам `maind` — **ARM32**
    (ELF32, armhf), userspace тоже 32-битный. Не ориентируйтесь на этот вывод при сборке бинарников.

## Звук

Все плееры пишут в ALSA `default` (`/etc/asound.conf`):

```text
default ─► softvol "Master" ─► plug ─► dmix_spk ─► hw:0,0  (TDM-B → усилитель)
```

`Master` — программный регулятор, его двигают кнопки и голосовые команды громкости
(`set_volume.sh N` = `amixer set Master N%`). Захват — `multi_capture`: 4 канала
микрофонов (`hw:0,1`, PDM) + 2 канала петли с выхода усилителя (`hw:0,0`, опорный сигнал
для эхоподавления).

### `maind --gst-launch` { #gst-launch }

Встроенный GStreamer, проигрывает любой пайплайн:

```sh
cd /system/vendor/quasar
LD_LIBRARY_PATH=/system/vendor/quasar:libs ./maind --gst-launch \
  "filesrc location=/path/file.mp3 ! decodebin ! audioconvert ! audioresample ! alsasink"
```

У команды есть ключи `--next` и `--clock` (назначение не изучали).

## Модели на борту

- `spotter_models/`: `activation`, `command`, `counteractivation`, `spotterRecognizer`, `vad`;
- `vqe_models/`: `noise_reducer`;
- `matter/`: `http`, `paa`.

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

`/system/vendor/quasar/q`: `start`, `stop`, `restart`, `version`, `device-id`, `wifi-info`,
`glagol-connections`, `full-info`, `backend-dev`, `backend-prod`, `cli`, `getprop`.
