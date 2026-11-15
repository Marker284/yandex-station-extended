# Станция Мини 3 Про (pickle)

Розничное имя — **Яндекс Станция Мини 3 Про**; кодовое имя — **Pickle** (device-tree
`Yandex Pickle EVT`, `yandex,pickle-evt` / `yandex,pickle`, **`amlogic, a4`**). Не путать с
[Мини 3 (bergamot)](station-mini3.md): там рутованная колонка сохраняет правки во всех
разделах, а у Мини 3 Про на прошивке `.50` — **только в `/data`**. На заводской
factory-12 правки корня, наоборот, [сохраняются](#factory-12).

Новый для вики SoC — **Amlogic A4**; программная основа та же, что у
[Миди](station-midi.md): ядро 5.4, Buildroot 2023.11.1, quasar/`maind`. Хранилище при этом
не eMMC, а NAND с UBI, как у AXG-моделей.

## Платформа в двух словах { #platform }

| Что | Значение |
|---|---|
| SoC | **Amlogic A4** (`amlogic, a4`) |
| CPU | 4× **Cortex-A53** (`0xd03`), до **2.016 ГГц** (100 МГц … 2016 МГц) |
| ОЗУ | **~473 МБ** (MemTotal 484784 kB) |
| Ядро | Linux **5.4.242** aarch64 (сборка 30.05.2025) |
| Userspace | Buildroot **2023.11.1** |
| Флеш | **NAND Toshiba 512 МБ SLC** (TC58NVG2S0HTA00), страница 4096, блок 256 КБ, UBI поверх MTD |
| Усилитель | **ACM8625** (`snd_soc_acm8625`, `3-0x2c`) |
| Индикация | кольцо 16 RGB + логотип 6 RGB + **LED-часы** (сегменты циферблата) |
| Питание | **USB-C Power Delivery** (`husb238_pd` + `ya_pd_controllers`) |
| Умный дом | **Zigbee** (`zigbee_control`) |
| Радио | **Unisoc** (`vlsicomm` + `aml_sdio` + `sdio_bt`), BT-пульт (`input_btrcu`) |
| Безопасность | SELinux `enforcing`, JTAG выключен (`jtag=disable`), `rh_unlock=0` |

## Что работает { #features }

| Что | Состояние | Где описано |
|---|---|---|
| Root и SSH | частично (автозапуск на factory `.8` и `.22`; не на `.50`) | [SSH только по ключу на `.8`](../start/pickle-factory12.md) |
| USB Host (OTG) | не проверялось | — |
| AirPlay | работает на factory-12 | [AirPlay](#airplay) |
| Spotify Connect | не проверялось | — |
| Плеер как Bluetooth-источник | не проверялось | — |
| Свои звуки | не проверялось | — |
| Обработанный микрофон | не проверялось | — |
| Подсветка | работает | [Индикация](#led) |
| YAM | работает на factory-12 (профиль midi) | [автозапуск](../recipes/packagemanagers.md#autostart) |
| Своя LLM | не проверялось | — |

## Получение root { #root }

На заводской сборке `factory-12` (2025 год) root берётся обычной
[подменой DNS](../start/root.md), и правки корня там переживают перезагрузку — что ещё
отличается от текущих прошивок, описано [ниже](#factory-12).

Для проверенной factory `.8` есть отдельный порядок:
[SSH только по ключу, блокировка OTA и отключение сетевого ADB](../start/pickle-factory12.md).
Это не универсальный способ отката retail на factory.

Для сборок `.50` способа пока нет. Ниже разобрано железо и то, что известно о закреплении
доступа; если у вас есть проверенные данные — [дополните страницу](../contributing.md).

## Разделы флеша { #partitions }

| MTD | Раздел | Размер | Что внутри |
|---|---|---|---|
| `mtd0` | `bootloader` | 4 МБ | |
| `mtd1`–`mtd3` | `bl2e`, `bl2x`, `ddrfip` | по 2 МБ | ступени загрузчика |
| `mtd4` | `tpl` | 12 МБ | |
| `mtd5` | `tee` | 2 МБ | jffs2, `/tee` (ro) |
| `mtd6` | `aml_sysrecovery` | 128 МБ | |
| `mtd7` | `recovery` | 16 МБ | |
| `mtd8` | `boot` | 16 МБ | ядро |
| `mtd9` | `system` | 128,5 МБ | UBI `ubi0:rootfs` → `/`, **ro** |
| `mtd10` | `data` | 187 МБ | UBI `ubi1:data` → `/data`, rw |

`/` и `/data` — **разные UBI-устройства на разных разделах** (`ubi.mtd=system`,
`ubi.mtd=data` в cmdline). Поэтому `/data` и переживает OTA, которое переписывает `system`.

## Шина I2C и периферия { #i2c }

| Шина:адрес | Чип | Назначение |
|---|---|---|
| `1-0x20` | **AW21018** | LED-драйвер (матрица) |
| `1-0x21` | **AW21012** | LED-драйвер (матрица) |
| `1-0x34`, `2-0x34` | **AW21036** | LED-драйверы (матрица) |
| `2-0x50`, `3-0x52`, `3-0x55` | 24C02A | EEPROM |
| `3-0x08` | **HUSB238** (husb238_pd) | USB-C Power Delivery |
| `3-0x12` | **AW93303** (`aw933xx`) | ёмкостные сенсорные кнопки |
| `3-0x13` | **QMA6100P** | акселерометр |
| `3-0x2c` | **ACM8625** | усилитель |
| `3-0x51` | **PCF8563** | RTC |
| `3-0x53` | **LTR-308** (ltr308als01) | датчик освещённости |

## Индикация { #led }

Светодиоды — в `/sys/class/leds/pickle:*`:

- кольцо — 16 RGB-зон: `pickle:{red,green,blue}:ring0` … `ring15`;
- логотип — 6 RGB-зон: `pickle:{red,green,blue}:logo0` … `logo5`;
- циферблат — белые сегменты `pickle:white:clockA0` … `clockH3` (8 групп по 4) и
  `clockDEGREE`, `clockDH`, `clockDL`, `clockDM`;
- служебные `pickle:ring:sync0/1`, `pickle:logo:sync`, `pickle:sync:clock`.

Драйверы: `leds_aw2101x`, `leds_yandex_aw21036`, `quasar_led_ring`.

### Подсветка { #led-pickle }

Кольцо — 48 файлов `/sys/class/leds/pickle:{red,green,blue}:ring0…ring15`, яркость 0–255,
по умолчанию триггер `ledfb-ring` (анимации Quasar). Запись в `brightness` отцепляет триггер;
чтобы вернуть кольцо Алисе, запишите `ledfb-ring` в `trigger` каждой зоны.

**YAM.** Профиля Pickle в YAM нет, а `custom` нумерует светодиоды с 1. Подходит профиль `midi`:
он считает с 0 и при остановке плагина возвращает триггер `ledfb-ring`. Ему нужны имена
`cucumber:*`, поэтому в `/data` делаются ссылки на каталоги светодиодов:

```sh
D=/data/quazar/yam/leds-pickle; mkdir -p $D
for c in red green blue; do for i in $(seq 0 15); do
    ln -sfn /sys/class/leds/pickle:$c:ring$i $D/cucumber:$c:ring$i
done; done
```

и в `settings.toml` YAM, раздел `[led]`: `profile = "midi"`, `count = 16`,
`sysfs_root = "/data/quazar/yam/leds-pickle"`. После перезапуска `yamd` появляются
`led.ring.rgb` и `led.ring.16`, Lua-плагины рисуют через `alice.set(...)` с 16 цветами.

**Что сейчас показывает Алиса.** В `/data/quasar/daemons_logs/maind.log` каждая смена анимации:

```text
device_state_handler_base.cpp:709 Play animations: oknix [idle.led], ring [/system/vendor/quasar/ledpatterns/ring/alice_listening.led], clock [clock] ...
```

Значения кольца: `idle.led` (ничего), `alice_listening.led`, `alice_thinking.led`,
`alice_speaking.led`, `ring_spectrogram` (Алиса играет музыку), `…_out.led idle.led`
(затухание и возврат). По этим строкам можно уступать кольцо Алисе: свой эффект ставится на
паузу при любом значении, кроме `idle.led`.

### LED-часы { #clock }

36 белых сегментов на AW21036 (`2-0034`), `/sys/class/leds/pickle:white:clock*`, яркость
0–255 (Алиса ставит 90), триггер `none`:

| Сегменты | Что |
|---|---|
| `A0`…`G3` | 4 семисегментные цифры слева направо: A верх, B правый верхний, C правый нижний, D низ, E левый нижний, F левый верхний, G середина |
| `H0`…`H3` | восьмой сегмент позиции |
| `DH`, `DL` | верхняя и нижняя точки двоеточия |
| `DM` | средний элемент разделителя |
| `DEGREE` | значок градуса |
| `pickle:sync:clock` | служебный |

Раскладка совпадает с Лайт 2 (plum): YAM определяет часы как `Plum` и выводит время
(`PUT /api/clock {"time":"12:34"}`) и сегменты без доработок. Но время Quasar пишет прямо в
sysfs и **перерисовывает его на каждой смене минуты**, так что своё изображение держится до
конца текущей минуты. Анимации часов — `/system/vendor/quasar/ledpatterns/clock/*.scled`:
строка — кадр из 4×7 яркостей цифр, 4 служебных значений и длительности в мс.

## Звук { #audio }

- ALSA card0 `AML-AUGESOUND`: `TDM-A-acm8625-speaker` (воспроизведение), `PDM-dummy-mics`
  (микрофоны), `LOOPBACK-A` (опорный сигнал для эхоподавления), `VAD-dummy-vad`.
- ALSA `pcm.speakers` — общий `dmix` (`ipc_key 1024`) поверх `hw:0,0`, им пользуются и Алиса,
  и сторонние приёмники.
- Громкость Алисы — это `amixer set Master N%` (так делает `set_volume.sh`). Чужая запись в
  `Master` меняет громкость, но Quasar о ней не знает: следующая кнопка считает от его уровня.
- `native-volume` из пакета
  [station-volume](https://github.com/Yandex-Station-Universal-Repo/station-volume)
  на factory-12 **читает** громкость (`stereo_pair`, порт 9921), но `volume_set` через
  `iohub_clients` (9910) Quasar не принимает: уровень не меняется.
- **Петлевой канал** `LOOPBACK-A` (`hw:0,2`, 4 канала S16 48 кГц; 0 и 1 — левый и правый того,
  что играет колонка) Алиса держит для эхоподавления, **пока микрофоны включены**, и отпускает,
  когда они выключены.

!!! danger "Занятый петлевой канал приводит к падению процесса Алисы"
    Если включить микрофоны, пока `hw:0,2` занят чужим процессом, `maind --platformd` падает
    («Skipping boot sequence after maind crash» в журнале) и перезапускается через ~2 с.
    Порядок: выключить микрофоны → открыть канал; закрыть канал (дождаться `closed` в
    `/proc/asound/card0/pcm2c/sub0/status`) → включить микрофоны.

**Системные звуки** — `/system/vendor/quasar/sounds/`. Форматы на factory-12:

| Файл | Формат |
|---|---|
| `boot.wav` | WAV PCM 44,1 кГц стерео |
| `timer.wav` | **MP3** моно 44,1 кГц (расширение `.wav`) |
| `notification_sound.mp3` | MP3 стерео 48 кГц |
| `volume_sound.mp3` | MP3 моно 44,1 кГц, 0,1 с |
| `bluetooth_turning_{on,off}_jingle.opus` | Ogg Opus 48 кГц стерео |

Замена в том же формате подхватывается **сразу, без перезагрузки** (проверено на
`volume_sound.mp3`).
Звук загрузки не играет, пока есть `/data/quasar/data/no_boot_sound`; Алиса создаёт этот файл
заново после синхронизации, если в облачном конфиге `"jingle": false`.

## Вход { #input }

- Устройства ввода: `aw933xx` (сенсорные кнопки), `vad_keypad`, `mute` (отключение микрофона),
  `input_btrcu` (BT-пульт).

**Микрофон программно.** Кнопка микрофона — устройство ввода `mute` (gpio-keys,
на проверенной колонке `/dev/input/event2`), переключатель `SW_MUTE_DEVICE`.
Записанное в это устройство событие Quasar обрабатывает как нажатие
(`Mute microphones` / `Unmute microphones` в журнале):

```sh
dev=$(awk '/^N: Name="mute"/ { f = 1 } f && /^H:/ { if (match($0, /event[0-9]+/)) print substr($0, RSTART, RLENGTH); exit }' /proc/bus/input/devices)
z='\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000'
printf "$z\005\000\016\000\001\000\000\000$z\000\000\000\000\000\000\000\000" > /dev/input/$dev   # 1 = выключить, \000 = включить
```

Модули ядра: `aml_sdio`, `dtbocfg`, `key_aw933xx`, `leds_aw2101x`, `leds_yandex_aw21036`,
`ltr308als01`, `optee`/`optee_armtz`, `qma6100p`, `quasar_led_ring`, `quasar_pcba_ids`,
`sdio_bt`, `snd_soc_acm8625`, `vlsicomm`, `ya_pd_controllers`, `zigbee_control`.

## Что переживает перезагрузку и OTA { #persistence }

- На `.50` после перезагрузки сохраняются изменения **только в `/data`**: правки корневой ФС
  (`/etc/init.d`, `/system/vendor/quasar` и т. п.) пропадают. Корень смонтирован `ro`
  (`ubi0:rootfs` на `mtd9`).
- OTA полностью переписывает разделы **mtd0–mtd4 и mtd9**, но не трогает **mtd10** — это
  `/data`. В `/data` обновление удаляет только `/data/overlay` и `/data/quasar_activate_*`.
- `chattr +i` защищает файл от правки и удаления, но **не** от перезаписи всего раздела: файлы,
  которые должны пережить обновление, держите в `/data`.

Для `.50` правило: всё своё — в `/data`, а то, что требует автозапуска из корневой ФС (например,
SSH из `init.d`), придётся запускать заново после каждого включения.

## Постоянный ADB { #adb }

Root ADB, настроенный так, пережил обновление на `.50` и поднимается сам на каждой загрузке.
Всё делается заранее, с root-доступом (например, на factory-прошивке).

1. Добавьте в `/data/quasar/data/user_config.dat` (это JSON) блок `system_config.adbd`.
   Если файла нет, создайте его с таким содержимым; если есть — сохраните копию и
   впишите блок в существующий JSON, не затирая остальное:

    ```json
    {
      "system_config": {
        "adbd": {
          "remoteActivation": true,
          "network": true
        }
      }
    }
    ```

2. Создайте пустые маркеры и защитите их от удаления:

    ```sh
    mkdir -p /data/quasar
    touch /data/quasar/activate_adb_quasmodrom /data/quasar/activate_network_adb
    chattr +i /data/quasar/activate_adb_quasmodrom /data/quasar/activate_network_adb
    ```

Как это срабатывает на загрузке:

- `onboot.sh` вызывает `activate_adb.sh check`, тот видит маркеры в `/data/quasar/` и
  запускает ADB;
- `syncd` читает локальный `user_config.dat`, передаёт `system_config.adbd` в `AdbService`, и
  тот подтверждает активацию сетевого ADB.

!!! warning "Маркеры с подчёркиванием удаляются при загрузке и OTA"
    Используйте только путь `/data/quasar/activate_*` (через слэш). Файлы
    `/data/quasar_activate_*` (через подчёркивание) относятся к старой схеме: их удаляют
    и `onboot.sh`, и процесс OTA.

## SSH { #ssh }

На `.50` автозапуск из корневой ФС не сохраняется, поэтому Dropbear, ключ и скрипт запуска
лежат в `/data` (например, `/data/alice-ssh`), а запускать его нужно после каждого включения —
вручную по ADB:

```sh
adb connect <IP_колонки>:5555
adb shell sh /data/alice-ssh/start-ssh.sh
```

??? example "Скрипт start-ssh.sh для запуска Dropbear из data"
    ```sh
    #!/bin/sh
    # Dropbear on :2222 from /data (rootfs changes do not survive a reboot here).
    D=/data/alice-ssh
    pidof dropbear >/dev/null 2>&1 && exit 0
    [ -s "$D/hk_ed25519" ] || "$D/dropbearkey" -t ed25519 -f "$D/hk_ed25519" >> "$D/dropbear.log" 2>&1
    # -B: root has an empty password
    "$D/dropbear" -r "$D/hk_ed25519" -p 2222 -B 2>>"$D/dropbear.log"
    ```

Чтобы не делать это руками, SSH может поднимать компьютер в домашней сети, который включён
постоянно (мини-ПК, NAS, роутер с `adb`): периодически проверять Dropbear по ADB и запускать
его, если он не работает. Пример цикла — оберните его в службу systemd или cron:

```sh
#!/bin/sh
# Keep SSH up on the speaker: check every minute over ADB, start dropbear if it is not running.
IP=<IP_колонки>
while :; do
  adb connect "$IP:5555" >/dev/null 2>&1
  adb -s "$IP:5555" shell 'pidof dropbear >/dev/null || sh /data/alice-ssh/start-ssh.sh' >/dev/null 2>&1
  sleep 60
done
```

Пакеты (`yse`, Entware) ставятся в `/data` и переживают и перезагрузку, и OTA.

## Прошивка factory-12: что отличается от `.50` { #factory-12 }

На Yandex Pickle EVT со сборкой `0.12.1.8.2901568369.20250228.factory-12`
15 ноября 2026 года отдельно проверены постоянный UID0 SSH только по ключу,
блокировка OTA и отсутствие сетевого adbd после обычной перезагрузки. Корень UBIFS
вернулся в RO, Quasar остался включён. [Порядок и ограничения](../start/pickle-factory12.md).
Сброс или перепрошивка могут убрать эти изменения.

Ниже — независимый результат сообщества для `.22`, не утверждение об одинаковом Quasar
или политике ADB на `.8`:

На сборке `0.12.1.22.3114898626.20250530.factory-12` колонка получила root через DNS-метод
и осталась на ней (обновления закрыты скриптом `yandex-noupdate.sh`). Ниже приведены отличия
от прошивки `.50`:

| | `.50` (выше на странице) | factory-12 |
|---|---|---|
| Правки корня (`/etc/init.d`, `/system/vendor/quasar`) после перезагрузки | пропадают | **сохраняются**: после `mount -o remount,rw /` и `sync` файлы на месте, `S99zdropbear` поднимает SSH на 13-й секунде загрузки |
| Маркеры ADB | `/data/quasar/activate_*` | **старая схема** `/data/quasar_activate_*` (через подчёркивание): её читает `adb_options.inc` этой сборки |
| `maind --gst-launch` ([Свои звуки](../recipes/sounds.md)) | — | **нет такого режима**: `maind` печатает справку. Для проигрывания есть системные `mpg123` и `aplay` |
| `yandex-noupdate.sh` | — | работает, правки держатся после перезагрузки |

Значит, автозапуск из `/etc/init.d` на factory-12 работает как на других моделях, а
обходной путь с запуском SSH по ADB после каждого включения не нужен.

## ADB после возврата DNS { #adb-after-dns }

После того как DNS `179.254.167.126` убран с роутера, колонка синхронизируется с настоящим
бэкендом. Его конфиг без раздела `adbd`, и через ~40 с после загрузки Quasar выключает ADB:

```text
adb_service.cpp:61 Read quasmodrom config section "adbd": forceDisable=undefined, remoteActivation=undefined, network=undefined
adb_service.cpp:80 Deactivate adb service. Running command: /system/vendor/quasar/activate_adb.sh --quasmodrom deactivate
```

`deactivate` удаляет маркеры `/data/quasar_activate_*`, `chattr +i` на `/data/quasar/activate_*`
на factory-12 не помогает (эти файлы сборка не читает). `user_config.dat` бэкенд перезаписывает
при каждой синхронизации, так что вписывать туда `adbd` бесполезно.

Рабочий вариант — не давать облачному конфигу выключать ADB. В начало
`/system/vendor/quasar/activate_adb.sh` (сохранив оригинал в `/data`):

```sh
# Keep ADB on: ignore the deactivation that the cloud config sends when it has
# no "adbd" section.
q=; d=
for a in "$@"; do [ "$a" = --quasmodrom ] && q=1; [ "$a" = deactivate ] && d=1; done
if [ -n "$q" ] && [ -n "$d" ]; then
    echo "`date`: quasmodrom deactivate ignored (patched)" >> /data/quasar/quasar_adb.log
    exit 0
fi
```

и включить ADB штатно: `activate_adb.sh --quasmodrom --network activate`. Проверено
перезагрузкой с настоящим DNS: ADB поднимается, `adb connect` даёт root. SSH от DNS не
зависит в любом случае.

CA-бандл factory-12 (`/system/vendor/quasar/ca-certificates.crt`) доверяет настоящему
серверу `quasar.yandex.net`: утилита `curl --cacert` с этим бандлом проходит проверку
сертификата. После возврата DNS Алиса работает в штатном режиме.

## AirPlay { #airplay }

[station-airplay](https://github.com/Yandex-Station-Universal-Repo/Station-airplay) 1.4.0 из
yapkg работает на factory-12 (профиль `yandexmini_3_pro`, AArch64 Shairport Sync 5.6.2,
`pcm.speakers`, Алиса сохраняется). Условия:

- `allow_plugin_binaries = true` в настройках YAM;
- модель для YAM — `data/device.toml` с `model = "yandexmini_3_pro"` (сам YAM Pickle не узнаёт).

!!! warning "YAM определяет Pickle как первое поколение Мини"
    `recognized_model()` ищет подстроку, и `yandexmini_3_pro` превращается в `yandexmini`
    (Мини 1) — даже из `device.toml`. AirPlay помечается несовместимым и останавливается. Обход
    в своей сборке плагина: при `yandexmini` проверять `/proc/device-tree/model` на `Pickle`
    и добавить `yandexmini` в `models` манифеста. Автообновление YAM (`[updates]` в
    `settings.toml`) лучше выключить.

Что можно добавить в профиль Mini 3 Pro патчем к исходникам плагина (`shairport-sync` этой
сборки поддерживает соответствующие ключи):

- `ignore_volume_control = "yes"` и `run_this_when_volume_is_set` → `amixer set Master`:
  ползунок источника меняет громкость колонки (диапазон −30…0 дБ → 0…100 %).
- `run_this_before_entering_active_state` / `run_this_after_exiting_active_state` →
  выключение микрофона Алисы на время сеанса (см. выше) и свои действия, например светомузыка
  по петлевому каналу.
- Паузы и переключения треков с колонки нет: в сборке нет D-Bus/MPRIS-интерфейса.

## `yse` и Entware { #yse }

На factory-12 `yse install` не ставит пакеты Entware (`Unknown package`), а `.yap` не качаются
(«для загрузки с GitHub нужен curl»). Причина — `LD_LIBRARY_PATH=/opt/lib`, который `yse`
ставит для `opkg` и `curl`: в Entware glibc старее системной (2.36), и системные `/bin/sh` и
`wget` падают с `GLIBC_2.34 not found`, а `opkg` под этой переменной видит 18 пакетов вместо
~2960. Программам Entware переменная не нужна (интерпретатор и rpath у них свои). Убрать
`LD_LIBRARY_PATH="$OPT/lib"` в функции `opkg()` и в `fetch_https()` — и Entware, и `.yap`
ставятся.

Статический `curl` для `fetch_https` — из пакета `curl` в yapkg (aarch64, OpenSSL, свой
`cacert.pem`): системного CA-бандла `/etc/ssl/certs/ca-certificates.crt` на колонке нет,
путь к сертификатам — через `~/.curlrc` (`HOME=/data/opt/home`).

## Резервная копия флеш-памяти { #nand-dump }

`nanddump -q /dev/mtdN` по SSH читает все разделы; суммы `mtd0`–`mtd9` совпадают при
повторном чтении, `mtd10` (`data`, живой) — нет, его удобнее сохранять архивом файлов
(`tar` без `z` + `gzip`: busybox `tar` здесь не умеет сжимать). На `mtd0` (`bootloader`)
`nanddump` пишет `uncorrectable bitflip` в конце каждого блока — загрузчик Amlogic записан в
своей разметке ECC, для его восстановления такая копия может не подойти.

## Quasar на factory `.8` { #quasar }

**Проверено на:** Yandex Pickle EVT, `0.12.1.8.2901568369.20250228.factory-12`,
15 ноября 2026 года. Файл `/system/vendor/quasar/VERSION` содержит `3.21`.

Это роли одного исполняемого файла maind, различаемые аргументами запуска.
В сохранённом исходном launch.json массив `nodes[0].tasks` содержит шесть задач:

| Задача | Аргумент | order | Роль по флагу |
|---|---|---|---|
| updatesd | `--updatesd` | 3 | Обновления |
| mediad | `--mediad` | 3 | Медиа |
| telemetry | `--telemetry` | 0 | Телеметрия |
| maind | `--platformd` | 1 | Платформа Quasar |
| fluent-bitd | `--fluent-bitd` | 0 | Сбор и доставка журналов |
| calld | `--calld` | 3 | Звонки |

Снимок работающей системы **уже изменён блокировкой OTA**: задачи и процесса updatesd
нет, остальные пять ролей работают.

## Zigbee на factory `.8` { #zigbee }

**Проверено на:** Yandex Pickle EVT, `0.12.1.8.2901568369.20250228.factory-12`,
15 ноября 2026 года, один датчик вибрации. Команда включения на реальной розетке или лампе
не проверялась.

Колонка сама работает координатором: штатный Quasar ведёт сеть через радиочип Telink,
а встроенная в maind локальная панель принимает команды без облака.

### Радиочип { #zigbee-radio }

| Источник | Наблюдение |
|---|---|
| quasar.cfg | порт `/dev/ttyS2`, прошивка `${QUASAR}/zigbee/gateway.ybl` |
| gateway.ybl | 215196 байт, сырой образ Telink: байты 32–35 `4b 4e 4c 54` (KNLT) |
| Стартовый код образа | совпадает с `cstartup_b91.S` из Telink Zigbee SDK, адрес сборки `0x20008000` |
| Строки образа | `OPENTHREAD/1.3.0`: в одной прошивке Zigbee и Thread |
| maind | классы Telink NCP и строка Gecko Bootloader (общий файл для разных моделей) |
| sysfs platform zigbee | модуль `zigbee_control`, линии `zb-reset` и `zb-boot` |

Семейство чипа — Telink B91 (TLSR921x/951x, RISC-V). У других чипов из того же SDK
стартовый код другой. Точная маркировка на плате не снималась. Первые 32 КБ флеша чипа
занимает загрузчик, его протокол не разбирался.

Хост говорит с чипом по Telink ZBHCI: 115200 8N1, кадр из байта `55`, типа и длины
(по два байта, старший первым), контрольной суммы XOR, данных и байта `aa`.
Чип ответил на три запроса чтения:

| Запрос | Что вернул |
|---|---|
| `0x0045`, стандартный | роль координатора, PAN ID, адреса, канал |
| `0x0900`, расширение Яндекса | версию `0x16013001`, код производителя `0x140A`, размер образа |
| `0x0905`, расширение Яндекса | номер канала |

Версия и размер из ответа совпали с файлом gateway.ybl. Остальные запросы группы `0x09xx`
не разобраны.

Порт радио занят: роль `--platformd` держит `/dev/ttyS2` открытым. Второй читатель забирает
часть байтов — после такого опроса Quasar писал `No ACK` на каждый свой запрос, пока его
не перезапустили.

ZHA и Zigbee2MQTT протокол ZBHCI не поддерживают, поэтому внешним адаптером для них чип
в таком виде не станет.

### Локальная панель { #zigbee-panel }

В quasar.cfg есть выключенный раздел `zigbee.httpControl`: порт 9233, страница из
`/system/vendor/quasar/zigbee/http`. Временное включение, до перезагрузки колонки:

```sh
cp /system/vendor/quasar/quasar.cfg /tmp/quasar.cfg
n=$(grep -n '"httpControl" : {' /tmp/quasar.cfg | cut -d: -f1)
sed -i "$((n+1))s/false/true/" /tmp/quasar.cfg
mount --bind /tmp/quasar.cfg /system/vendor/quasar/quasar.cfg
/etc/init.d/S99quasar stop
sleep 5
/etc/init.d/S99quasar start
```

Алиса молчит около 20 секунд, пока роли запускаются. `S99quasar restart` здесь ничего
не делает, а `kill` роль `--platformd` не завершает, поэтому нужны именно `stop` и `start`.

Проверка и подключение устройства:

```sh
wget -qO- http://127.0.0.1:9233/status
wget -qO- --post-data 'duration=120' http://127.0.0.1:9233/permit_join
grep -a '\[zigbee\]' /data/quasar/daemons_logs/maind.log | tail
```

Адреса панели взяты из её страницы и строк maind; вызывались только первые три.

| Адрес | Параметры | Действие |
|---|---|---|
| `GET /status` | — | сеть сформирована или нет, EUI-64, PAN ID |
| `POST /permit_join` | `duration`, секунды, 0–255 | открыть сеть для новых устройств, 0 закрывает |
| `POST /on_off/on`, `off`, `toggle` | `address` (4 hex-цифры), `endpoint` | команда On/Off одному устройству |
| `POST /set_channel` | `channel`, 11–25 | канал, пока сеть не сформирована |
| `POST /form_network` | — | сформировать сеть |
| `POST /set_install_code` | `eui64`, `install_code` | код установки устройства |
| `POST /factory_reset` | — | сброс Zigbee-сети |

!!! danger "Панель открыта всей локальной сети"
    Порт 9233 слушает на всех интерфейсах без пароля, а `iptables` в образе нет. Любое
    устройство в сети может сбросить Zigbee-сеть колонки, пока панель включена.

Что показала проверка с датчиком вибрации (IAS Zone, `deviceId=0x0402`):

- После `permit_join` датчик вошёл в сеть без облачного поиска устройств: в журнале
  появились `onDeviceAnnounce` с сетевым адресом, `onNodeJoined` и `saveNetwork nodeCount=1`.
- Срабатывания приходят и после закрытия сети — строками `onIncomingMessage` с кластером
  `0x0500`. Другого локального выхода у событий нет.
- Алиса такое устройство не видит: в журнале `Dumped 0 devices`.
- `on_off` на неизвестный адрес панель принимает с ответом 200, в журнале при этом
  `can't get node`. Успешный ответ не означает, что устройство переключилось.

Работа Zigbee через штатный Quasar с подменой бэкенда описана
[в исследовании quasard на Миди](../internals/zigbee.md) — там другая модель и другой путь.

## Климатический модуль { #climate }

**Проверено на:** Yandex Pickle EVT, `0.12.1.8.2901568369.20250228.factory-12`,
15 ноября 2026 года, один модуль с датчиками температуры, влажности и CO₂. Версии прошивки
модуля считаны [одним своим запросом](#climate-sync); после него процесс Quasar завершился.

Модуль — подставка под колонку. С колонкой он связан по USB через контакты на дне,
Zigbee здесь не участвует. В прошивке он называется cradle.

| Что | Значение |
|---|---|
| USB | `28e9:018a`, производитель Yandex, продукт Blanc, Full Speed, до 100 мА |
| Класс | CDC ACM, порт `/dev/ttyACM0` |
| Кто держит порт | роль `--platformd`, очередь `CradleCapability` |
| Модель в событиях умного дома | `YNDX-00652` |
| Опрос | раз в 60 секунд: температура, CO₂, влажность |

При снятии колонки с модуля и при возврате на него она перезагружалась — по одному
наблюдению на каждый случай. Без модуля в журнале остаётся `No cradle was connected`.

### Показания из журнала { #climate-log }

Quasar пишет каждый ответ модуля в `/data/quasar/daemons_logs/maind.log`:

```text
[cradle] [info] [temperature_sensor_capability.cpp:81] Got temperature data response, temperature_celsius=24.1019
[cradle] [info] [co2_sensor_capability.cpp:81] Got CO2 data response, co2_ppm=1293
[cradle] [info] [humidity_sensor_capability.cpp:81] Got humidity data response, humidity_percent=41.7423
```

Последние значения одной командой:

```sh
grep -a '\[cradle\]' /data/quasar/daemons_logs/maind.log | grep -a 'Got ' | tail -3
```

Это единственный способ чтения, не мешающий Quasar. Единственная своя запись в порт при
работающем Quasar [закончилась завершением platformd](#climate-sync).

### Протокол { #climate-protocol }

Кадр — HDLC: флаг `7e`, адрес `01`, байт управления со счётчиками, полезные данные,
контрольная сумма CRC-16/X-25 младшим байтом вперёд, флаг `7e`. Сумма считается по
адресу, байту управления и данным; она сошлась на четырёх записанных кадрах.
Экранирование байта `7e` внутри данных в записи не встретилось.

Данные — protobuf, пакет `cradle`. Схема встроена в maind, имена файлов начинаются
с `smart_devices/libs/cradle/protos/`.

| Сообщение | Поля |
|---|---|
| RequestMessage | одно из: `endpoint` = 1, `capability` = 2, `debug_info` = 3, `factory` = 4 |
| CapabilityRequest | `message` = 1, тип `google.protobuf.Any` |
| ResponseMessage | те же четыре поля и `log_message` = 6 |
| CapabilityResponse | `message` = 1 (Any), `capability_name` = 2 |
| SyncEndpointResponse | `endpoint_id`, версии приложения и загрузчика, список возможностей, `device_id`, `pcba_id` |

Внутри Any лежит запрос или ответ одной возможности с адресом типа вида
`type.googleapis.com/cradle.Co2SensorCapabilityRequest`.

| Возможность | Номер | Запрос | Ответ |
|---|---|---|---|
| BATTERY | 0 | заряд, принудительный уровень и температура | уровень, напряжение, ток, температура, статистика |
| UPDATER | 1 | подготовка, запись частями, применение прошивки | код ошибки, состояние |
| BUTTON | 2 | — | номер кнопки и тип нажатия |
| ANIMATION | 3 | показать уровень заряда | — |
| PARTICULATES | 4 | данные | `pm_1_0_ug_m3`, `pm_2_5_ug_m3`, `pm_10_0_ug_m3` |
| CO2_SENSOR | 5 | данные; калибровка с `target_co2_ppm` | `co2_ppm`, `stale_data`; поправка калибровки |
| TEMPERATURE_SENSOR | 6 | данные | `temperature_celsius` (float), `stale_data` |
| HUMIDITY_SENSOR | 7 | данные | `humidity_percent` (float), `stale_data` |
| VOC_SENSOR | 8 | данные | `voc`, `stale_data` |
| NOX_SENSOR | 9 | данные | `nox`, `stale_data` |
| CRYPTOGRAPHY | 10 | схема не извлечена | — |
| POWER_SUPPLY | 11 | схема не извлечена | — |

В обмене этого модуля видны только номера 5, 6 и 7. Остальные взяты из схемы и,
судя по набору, относятся к другим подставкам, в том числе с аккумулятором.

Записанный запрос CO₂ и ответ на него, 69 и 75 байт:

```text
7e 01 02 | 12 3d 0a 3b 0a 35 "type.googleapis.com/cradle.Co2SensorCapabilityRequest" 12 02 0a 00 | 04 d8 | 7e
7e 01 4e | 12 43 0a 3f 0a 36 "type.googleapis.com/cradle.Co2SensorCapabilityResponse" 12 05 0a 03 08 9e 0a 10 05 | 5c ae | 7e
```

В ответе `08 9e 0a` — поле `co2_ppm` со значением 1310, `10 05` — `capability_name`
со значением CO2_SENSOR. Ответ приходит через 3–4 мс после запроса.

### Запрос синхронизации { #climate-sync }

При старте platformd шлёт модулю `RequestMessage` с пустым полем `endpoint` — кадр
`7e 01 02 0a 00 ad a8 7e`. Модуль отвечает `SyncEndpointResponse` длиной 235 байт.

| Поле | Значение |
|---|---|
| `endpoint_id` | `Blanc` |
| `fw_version.app_version` | `6.19.1450367f.4117975802.20260507` |
| `fw_version.bldr_version` | `6.12.5a0d6956.3424653207.20250929` |
| `supported_capabilites` | 2, 12, 5, 7, 6, 11, 1 |
| `device_id` | 14 знаков, серийный номер модуля |
| `pcba_id` | 128 байт: строка производственных данных платы, добитая точками |

Возможности по номерам: BUTTON, CO2_SENSOR, HUMIDITY_SENSOR, TEMPERATURE_SENSOR,
POWER_SUPPLY, UPDATER. Номера 12 в схеме этой прошивки колонки нет: прошивка модуля
новее. Колонка при этом опрашивает только три датчика.

По байту управления: колонка нумерует свои кадры в битах 1–3, а счётчик приёма в битах
5–7 всегда держит нулём. Модуль ставит в свой счётчик приёма номер запроса плюс один.
Два запроса подряд с одним номером модуль принял и ответил на оба.

Как получен ответ. Пассивная запись старта Quasar дала только первые 15 байт. Целиком
ответ получен так: при работающем Quasar в `/dev/ttyACM0` один раз записан тот же кадр
синхронизации, порт на чтение не открывался, ответ сняла [запись kprobe](#climate-trace).
Модуль ответил через 3 мс. Quasar получил ответ, которого не ждал, сбросил свои номера
кадров, сразу заново запросил три датчика, и через 0,4 секунды процесс platformd
завершился. Супервизор его не поднял, опрос модуля вернулся после
`/etc/init.d/S99quasar stop` и `start`.

Это одно наблюдение, причина завершения не установлена: лог к тому моменту был
перезаписан, а сам platformd перед этим пережил несколько остановок супервизора
(`stop` завершает только `quasar_launcher2`). Писать в порт при работающем Quasar не стоит.

### Запись обмена без захвата порта { #climate-trace }

В ядре нет usbmon и на колонке нет strace, но есть kprobe-события. Точки ставятся на
запись в CDC ACM и на приём в tty; порт при этом не открывается, Quasar ничего не замечает.

```sh
T=/sys/kernel/debug/tracing
W='n=%x2:s32'; R='n=%x3:s64'
for i in $(seq 0 19); do
    W="$W d$i=+$((i*8))(%x1):x64"; R="$R d$i=+$((i*8))(%x1):x64"
done
echo "p:cradle/tx acm_tty_write $W" >> $T/kprobe_events
echo "p:cradle/rx tty_insert_flip_string_fixed_flag $R" >> $T/kprobe_events
mkdir $T/instances/cradle
echo 1 > $T/instances/cradle/events/cradle/enable
sleep 65
echo 0 > $T/instances/cradle/events/cradle/enable
cat $T/instances/cradle/trace > /tmp/cradle.trace
rmdir $T/instances/cradle
echo '-:cradle/tx' >> $T/kprobe_events
echo '-:cradle/rx' >> $T/kprobe_events
```

В каждой строке записи `n` — длина блока, `d0`…`d19` — его первые 160 байт словами по
8 байт, младший байт первым. Точка `rx` общая для всех последовательных портов, поэтому
в запись попадает и обмен с Bluetooth-чипом; кадры модуля отличаются первым байтом `7e`.
Один ответ модуля может прийти двумя-тремя блоками подряд.

## Что ещё проверить { #todo }

- Способ получить root на текущих прошивках.
- Почему на `.50` не сохраняются правки корневой ФС (SELinux в режиме `enforcing`, overlay или
  что-то ещё), если на factory-12 они [сохраняются](#factory-12).
- Климатический модуль: возможность с номером 12, причина завершения platformd после
  [своего запроса синхронизации](#climate-sync), прямой обмен по
  [протоколу](#climate-protocol) при остановленном Quasar, события кнопки.
- Zigbee: маркировка радиочипа на плате, `on_off` на реальной розетке или лампе, сохранение
  сети после перезагрузки и постоянное включение [локальной панели](#zigbee-panel).
