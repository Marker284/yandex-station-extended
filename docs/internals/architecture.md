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

## Загрузочная цепочка Лайт 2 (Plum) { #bootchain-plum }

**Источник:** сообщение в группе Telegram Yandex Station Extended от 8 ноября
2026 года. Ни извлечение ключа, ни его работу на другом экземпляре Лайт 2
для этой статьи независимо не проверяли.

### Что запускается до Linux

При включении процессора сначала выполняется BootROM — встроенный код
микросхемы. Он загружает BL2, который настраивает частоты, память DRAM
и передаёт управление следующим стадиям. Они упакованы в FIP
(Firmware Image Package). В зависимости от образа контейнер содержит:

- BL30 — код системного сопроцессора;
- BL31 — защищённый монитор, работающий в режиме EL3;
- BL32 — доверенную среду, если она предусмотрена;
- BL33 (U-Boot) — загрузчик ядра Linux.

После запуска Linux стартуют службы Quasar. Общее устройство цепочки
описано в [документации Trusted Firmware-A](https://tf-a.docs.trustedfirmware.org/en/latest/getting_started/image-terminology.html).

### Как исследовали ключ

По сообщению в группе Telegram, использовали уязвимость Blasty в обработке
запросов защищённого хранилища Amlogic. Через неё получили дамп памяти
защищённого монитора EL3. В дампе искали 32-байтные фрагменты, способные
расшифровать характерные заголовки BL2 и FIP. Найденный ключ, по сообщению
исследователей, дал при обратном шифровании исходные данные побайтно.

Сходный принцип доступа к защищённому режиму Amlogic A113X описан
в [исследовании BootROM](https://haxx.in/posts/dumping-the-amlogic-a113x-bootrom/).
Точное исходное место хранения ключа в Лайт 2 не установлено:
в публикации подтверждается его обнаружение в рабочей памяти EL3,
но не чтение напрямую из eFuse. Описанный способ требует совместимого
с ядром кода; ошибка может привести к перезагрузке или bootloop.

По сообщениям в группе, ключ может быть общим для семейства Plum,
но у Мини 3 (Bergamot) другой. Проверки всех ревизий Plum нет.

### Что даёт расшифровка

| Образ | Шифрование | Контроль после расшифровки |
|---|---|---|
| BL2 (mtd0) | AES-256-CBC, IV из нулей | `@AML` по смещению `0x10` |
| TPL/FIP (mtd1) | Тот же ключ и режим | FIP magic `0xAA640001` по смещению `0x10` |

Для офлайн-анализа в репозитории есть
[`contrib/decrypt_ota.py`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/decrypt_ota.py)
с параметром `--bootchain-key`. Сам ключ в Wiki не приводится.

Например, если после обновления изменилось поведение загрузки ядра,
можно расшифровать и сравнить старый и новый BL2/FIP. Это помогает
проверить, изменились ли механизмы загрузки и безопасности,
в том числе при исследовании альтернативной ОС.

### Отличие от root через подмену DNS

Подмена DNS и [патч CA из сервисного режима](../start/retail-ca.md)
дают доступ к ADB через настройки уже существующих Linux и Quasar.
Они не требуют AES-ключа и не расшифровывают BL2/FIP.

Официальное подписанное OTA может само обновить эти разделы, если они
входят в пакет. Поэтому утверждать, что их содержимое после OTA
не изменилось, без проверки образов нельзя.

Ключ AES позволяет прочитать зашифрованные загрузчики, но не создать
подпись производителя для изменённого образа. Это не готовый способ
установить другую ОС или прошивку с сохранением root. Запись
изменённого загрузчика может сделать колонку неработоспособной.

