# Станция 3 (Orion)

Розничное имя — **Яндекс Станция 3**; кодовое имя — **Orion** (device-tree
`Yandex Orion PVT`, `yandex,orion-pvt` / `yandex,orion`, **`amlogic, a5`**,
`amlogic-dt-id = "a5_orion_pvt"`). В mDNS — `platform=orion`.

Это **тот же SoC, что у [Миди](station-midi.md)** (Amlogic A5, ядро 5.4,
Buildroot 2023.11.1), но **другая плата**: ~2 ГБ ОЗУ, кольцо на 36 RGB,
эмбиент-подсветка, монохромный LED-дисплей 21×12, ультразвук на отдельном TDM,
четыре усилителя ACM8625S. Не Android (Макс) и не AXG.

Прошивка — **Buildroot + quasar/`maind`**, приёмы из
[Как это устроено](../internals/architecture.md) применимы (ядро 5.4, eMMC).
Корень смонтирован **ro** (`root=PARTLABEL=system`).

Снимок: hostname `Yandex-Station3`, quasar **3.21**,
`BUILD_ID=3322101745`, ядро собрано **23.08.2025**,
U-Boot `01.01.250823.213609`. Совпадает с заводским User-Agent
`orion/0.13.1.36.3322101745.20250823.factory-13`.

## Получение root { #root }

Сетевой [DNS-метод](../start/root.md) на `orion` **не работает** — свой набор
корневых CA, Let's Encrypt колонка не принимает. Подробности — в разделе
[TLS](#tls) (разведка без root, issue #24).

Рабочая схема — как в публичных разборах **Mini 2 / eQuasar**, через подмену
ответа бэкенда (не UART и не взлом Android):

1. На роутере (OpenWrt, `dnsmasq`) `quasar.yandex.net` / `quasar.yandex.ru`
   заворачиваются на свой хост (Pi, `192.168.1.105`).
2. На Pi — Docker `nginx` + `sync_patch.py`: берётся **живой** ответ
   `/get_sync_info` и в него дописываются флаги `adbd.remoteActivation` и
   `network` (сетевой ADB).
3. Ключевой момент — именно `/get_sync_info`, а не `/check_updates`: сразу после
   настройки колонка стучится только в `/check_updates`, а `get_sync_info`
   запрашивает **после ребута по питанию** (обычно пару раз). После применения
   патча поднимается **сетевой ADB `:5555`, `uid=0`**.
4. Дальше на уже открытой колонке — кит: фиксация маркеров ADB (`chattr +i`),
   глушение OTA и **Dropbear на `:22`** (логин `root`). Своё лежит в `/data`;
   после `remount,rw` правки `/etc` возможны, но корень **ro** и OTA их сотрёт.

На Максе (`yandexstation_2`, Android TV) тот же трюк **не сработал**: конфиг
доезжал, но `:5555` колонка так и не слушала.

## Платформа в двух словах

| | |
|---|---|
| SoC | **Amlogic A5** (`amlogic, a5`, `Hardware: Amlogic`) |
| CPU | 4× **Cortex-A55** (`0xd05`, variant `0x2`), **100 МГц … 2.016 ГГц** |
| ISA | ARMv8.2 (atomics, fphp, asimdhp, asimddp, lrcpc, dcpop, aes/sha/crc32) |
| ОЗУ | **~1.93 ГБ** (MemTotal 2027672 kB) — заметно больше, чем у Миди (~980 МБ) |
| Ядро | Linux **5.4.180** aarch64, `#2 SMP PREEMPT`, сборка 23.08.2025 |
| Userspace | Buildroot **2023.11.1**, glibc **2.36** |
| Хранилище | **eMMC** (~7.1 ГБ, `mmcblk0` 7471104 блоков). `/proc/mtd` пуст |
| NPU | **Vivante VIPNano-Q** (GC9000, `model 0x9000` rev `0x9002`), ~800 МГц, `galcore` 6.4.8.7.7.1.1, класс `/sys/class/npu` ([детали](#gpu)) |
| DSP | **HiFi4** (`hifi4dsp0`), есть узел `dolby_fw` |
| Усилители | **4× ACM8625S**: 1× ультразвук (`2-0x2c`) + **3× колонки** (`3-0x2c/2d/2e`) |
| Микрофоны | PDM (`PDM-dummy-mics`); LOOPBACK **14 каналов** @ 96 кГц (раскладка не снималась) |
| Индикация | кольцо **36 RGB** + эмбиент **12 зон × a/b, RGBW** + дисплей **21×12** |
| Питание | **USB-C PD** (`husb238` + `ya_pd_controllers`), PDO 20/15/12/9/5 В |
| Умный дом | **Zigbee** + **Matter** + **WiFi** (`iot.providers`); Zigbee NCP на `/dev/ttyS2` |
| Радио | **Unisoc** (`vlsicomm` + `aml_sdio` + `sdio_bt`), BT-пульт (`input_btrcu`); в образе есть и драйвер Amlogic `w2l` |
| Безопасность | SELinux `enforcing`, JTAG `disable`, `rh_unlock=0`, verified boot `green`, OP-TEE + keymaster (`/dev/keymaster_svc`) |

## Чем принципиально отличается от Миди

- Тот же **A5 / 5.4 / Buildroot 2023.11.1 / eMMC**, другая DT: `a5_orion_pvt`, не `a5_cucumber_dvt2`.
- **Вдвое больше ОЗУ** (~2 ГБ vs ~1 ГБ).
- Кольцо **36** диодов (`orion:*:ring0..35`), не 24 `cucumber:*`.
- Нет sysfs-циферблата `*:white:clock-*`. Вместо него framebuffer
  **`/dev/fb1` (`YNDX LED screen`, 21×12, 24 bpp)** — 252 пикселя, как в розничных ТТХ.
- Эмбиент: `/dev/fb0` (`ambilight`, 12×1, **48 bpp**) и sysfs `orion:{red,green,blue,white}:ambilight{0..11}{a,b}`.
- Звук: колонки на **`hw:0,1`** (TDM-B), ультразвук на **`hw:0,0`** (TDM-A). На Миди динамики на TDM-A.
- Усилители **ACM8625S**, не FS2105. В микшере полосы `fr1` / `fr2` / `us`.
- LED-матрица дисплея — модуль **`gowin_led_device`** (не только AW21036).
- quasar: `quasar_launcher2` + `maind --platformd/--mediad/--loggerd/--telemetry/--fluent-bitd`,
  плюс `begemot` и `bulbik` (кольцо Алисы через `ledfb-ring`).

## Шина I2C и периферия (4 шины)

| Шина:адрес | Чип | Назначение |
|---|---|---|
| `0-0x12` | **AW93312** (`aw933xx` / `key_aw933xx`) | ёмкостные кнопки |
| `0-0x34`, `0-0x35`, `0-0x36` | **AW21036** | LED-матрица |
| `0-0x51` | **PCF8563** | RTC |
| `0-0x52` | 24C02 | EEPROM |
| `0-0x53` | **LTR-308** (`ltr308als01`) | датчик освещённости |
| `1-0x52` | 24C02 | EEPROM |
| `2-0x08` | **HUSB251** (DT-узел `husb251@08`, драйвер `ya_pd`) | USB-C Power Delivery |
| `2-0x2c` | **ACM8625S** | Class-D — **ультразвук** (`us`) |
| `2-0x34`, `2-0x35`, `2-0x36` | **AW21036** | LED-матрица |
| `2-0x51` | 24C02 | EEPROM |
| `3-0x2c`, `3-0x2d`, `3-0x2e` | **ACM8625S** | Class-D — **колонки** (`fr1`/`fr2`) |
| `3-0x50` | 24C02 | EEPROM |

Контроллеры всех четырёх шин — в блоке APB4, по device-tree aliases:

| Шина | Контроллер (DT) | Устройства из DT |
|---|---|---|
| `i2c-0` | `apb4/i2c@66000` (`0xfe066000`) | `touch-sensor@12`, `led-controller@34/35/36`, `rtc@51`, `eeprom@52`, `light-sensor@53` |
| `i2c-1` | `apb4/i2c@68000` (`0xfe068000`) | `eeprom@52` |
| `i2c-2` | `apb4/i2c@6a000` (`0xfe06a000`) | `husb251@08`, `acm8625s@2c`, `led-controller@34/35/36`, `eeprom@51` |
| `i2c-3` | `apb4/i2c@6c000` (`0xfe06c000`) | `acm8625s@2c/2d/2e`, `eeprom@50` |

Узлы DT совпадают с таблицей выше. Нюанс: `i2c-0` в дереве по умолчанию
`disabled` — `S30top-board` включает его рантайм-оверлеем
`/boot/yandex-orion-i2c_top-overlay.dtb` (после остановки AO-CPU через
`/dev/ree2aocpu`), поэтому `/dev/i2c-0` появляется не сразу на старте.

## Индикация { #leds }

Все узлы в `/sys/class/leds/` (на снимке **210** штук), префикс `orion:`:

- **Кольцо:** `orion:{red,green,blue}:ring0..35` — **36 RGB**.
  Синхро: `orion:ringA:sync`, `ringB:sync`, `ringC:sync`.
  Триггер Алисы — `ledfb-ring` / `ledfb-ring-sync` (как на Миди, другой префикс и счёт).
- **Эмбиент:** `orion:{red,green,blue,white}:ambilight{0..11}{a,b}` —
  12 зон, по два канала `a`/`b`, RGB + белый.
  Синхро: `orion:ambilightA/B/C:sync`.
- **Дисплей:** не через `*:clock-*`, а framebuffer (модуль `gowin_led_device`).

Framebuffers (`yandex,ledfb` / Gowin):

| Устройство | Имя | Размер | bpp | stride | Что это |
|---|---|---|---|---|---|
| `/dev/fb0` | `ambilight` | 12×1 | 48 | 72 | эмбиент (широкий пиксель) |
| `/dev/fb1` | `YNDX LED screen` | 21×12 | 24 | 63 | монохромный дисплей, 252 сегмента |
| `/dev/fb2` | `ring` | 36×1 | 24 | 108 | кольцо |

Кольцо — **отдельный узел верхнего уровня `/ring-framebuffer`** (а не потомок
шины); тот же оверлей переводит его в `status = "okay"`. Это согласуется с
`quasar_led_ring` (`yandex,ledfb`) как рутовым fb-узлом.

Запись brightness в sysfs кольца **срывает** триггер `ledfb-ring` у `bulbik` —
кольцо Алисы начинает мерцать, пока триггер не вернуть. Короткий оверлей
громкости: снять кадр `/dev/fb2` (108 байт), нарисовать шкалу, через ~1.6 с
вернуть `ledfb-ring` и старый кадр.

Драйверы: `leds_yandex_aw21036`, `quasar_led_ring`, `gowin_led_device`.

## Звук

ALSA card0 `AML-AUGESOUND`:

| PCM | Имя | Назначение |
|---|---|---|
| `hw:0,0` | `TDM-A-acm8625-ultrasonic` | ультразвук (playback+capture), усилитель `2-0x2c` |
| `hw:0,1` | `TDM-B-acm8625-speakers` | **динамики**, 48 кГц в пользовательском тракте |
| `hw:0,2` | `PDM-dummy-mics` | микрофоны |
| `hw:0,3` | `LOOPBACK-A-dummy-loopback` | AEC; на снимке capture **14 ch, S16, 96 кГц** |

Штатный PCM Алисы — `speakers` (dmix на `hw:0,1`). Ультразвук `hw:0,0` для
музыки не использовать.

Параметры тракта (`audiod` / `audiosender` в `quasar.cfg`): **6 каналов
микрофонов** (PDM), **7 каналов динамиков**, захват 96 кГц → выход 16 кГц,
период 512, VQE `type=yandex`, `preset=orion`, споттер — модель
`spotter_models/activation/alisa`. Это и раскладывает 14-канальный LOOPBACK:
**6× `raw_mic_0..5` + 7× `raw_spk_0..6` + `vqe_0`**; разбор музыки — по
`raw_spk_0` / `raw_spk_1`.

Усилители по ролям (из `S42acm8625-settings`, sysfs `settings_file`, конфиги
`orion-acm8625-*`):

| I2C | Роль | Конфиг |
|---|---|---|
| `2-0x2c` | ультразвук (`us`) | `orion-acm8625-us.cfg` |
| `3-0x2c` | центр (`center`) | `orion-acm8625-center.cfg` |
| `3-0x2d` | сабвуфер (`woofer`) | `orion-acm8625-woofer.cfg` |
| `3-0x2e` | левый/правый (`lr`) | `orion-acm8625-lr.cfg` |

Микшер: общий **`Master`** (его крутит и Алиса, и сторонний софт), плюс
`Ultrasound`, `fr1`/`fr2`/`us Acm8625 AMP *`, `VAD`, `PDM *`, `Loopback *`.

VAD: `vad_keypad`, устройство `/dev/vad`.

## Вход

- `aw933xx` (`AW93312`) — сенсорные кнопки: `KEY_VOICECOMMAND` (582),
  `KEY_VOLUMEUP` (115), `KEY_VOLUMEDOWN` (114).
- `vad_keypad` — VAD-клавиатура.
- `mute` (`gpio-keys`) — отключение микрофона (`KEY_MUTE` + `SW_MUTE_DEVICE`).
- `input_btrcu` — Bluetooth-пульт.

## Zigbee { #zigbee }

Модуль `zigbee_control`, прошивка `/system/vendor/quasar/zigbee/gateway.ybl`
(217 692 Б, сигнатура `25 a0 01 30`), рядом `http/`. **UART — `/dev/ttyS2`**
(секция `zigbee` в `quasar.cfg`); по DT-aliases это `/soc/serial@fe07c000`.
DT-узел `zigbee` (`compatible = yandex,zigbee-control`) держит только линии
`zb-reset-gpios` и `zb-boot-gpios` (сброс чипа и вход в его загрузчик), данные —
по UART. Встроенный веб-интерфейс `httpControl`
выключен (порт 9233). Свой OTA-склад для Zigbee-устройств —
`${DATA}/data/zigbee/` (`ota.lmdb`, лимит 6144 КБ, TTL 12 ч), БД сети
`network.dat`, устройств — `device.lmdb`. Модель чипа по дампу не определяется.

Умный дом в целом (`iot.providers` в `quasar.cfg`): включены **Zigbee**,
**Matter** (`matter/paa` CA-store, свой OTA-склад) и **WiFi**.

## Разделы eMMC { #partitions }

Как на Миди: узлы `/dev/<имя>`, MTD нет, `root=PARTLABEL=system`.
`mmcblk0` ≈ 7.1 ГБ; boot-копии `mmcblk0boot0/1`, есть `mmcblk0rpmb`.

| Раздел | Устройство | Размер | Что внутри |
|---|---|---|---|
| bootloader | `mmcblk0p1` `/dev/bootloader` | 4M | U-Boot; копии `bootloader0/1` |
| reserved | `mmcblk0p2` `/dev/reserved` | 64M | |
| cache | `mmcblk0p3` `/dev/cache` | — | узел есть |
| env | `mmcblk0p4` `/dev/env` | 8M | U-Boot env |
| misc | `mmcblk0p5` `/dev/misc` | 4M | |
| tee | `mmcblk0p6` `/dev/tee` | 48M | ext4, `/tee` (ro) |
| aml_sysrecovery | `mmcblk0p7` `/dev/aml_sysrecovery` | 1.5G | |
| boot | `mmcblk0p8` `/dev/boot` | 64M | ядро |
| recovery | `mmcblk0p9` `/dev/recovery` | 192M | |
| system | `mmcblk0p10` `/dev/system` | 1G | rootfs ext4, `/` **ro** |
| ota | `mmcblk0p11` `/dev/ota` | 1.5G | ext4, `/ota` (rw) |
| data | `mmcblk0p12` `/dev/data` | ~2.6G | ext4, `/data` (rw) |

Монтируется: `/` ro, `/tee` ro, `/ota` и `/data` rw.

Размеры подтверждает DT-узел `partitions` (`parts=8`): `boot` 64M, `recovery`
192M, `system` 1G, `tee` 48M, `misc` 4M, `ota` 1.5G, `aml_sysrecovery` 1.5G,
`data` — остаток диска. Поле `mask`: `1` — обычный раздел, `2` — сохраняется при
обновлении (`ota`), `4` — `data`. Фиксированные `bootloader`/`reserved`/`env`/
`cache` в этот узел не входят — их создаёт прошивальщик Amlogic до таблицы.

!!! warning "Личные данные"
    Не публикуйте дампы `data`, `ota`, `env`, `reserved`, `tee`.
    В cmdline есть `androidboot.serialno`; в `/proc/cpuinfo` — поле `Serial`.

## DVFS

Те же точки, что у Миди A5 (подтверждено `cpu_opp_table0` в DT): 100, 250, 500,
667, 1000, 1200, 1404, 1500, 1608, 1704, 1800, 1920, **2016** МГц. Напряжение
держится **0.769 В** до 1404 МГц, затем растёт до **1.009 В** на 2016 МГц. CPU —
`arm,cortex-a55`. Термозона `soc_thermal`.

## Ядро и модули

Загружены (снимок): `aml_sdio`, `sdio_bt`, `vlsicomm`, `optee`/`optee_armtz`,
`key_aw933xx`, `ltr308als01`, `dtbocfg`, `gowin_led_device`, `zigbee_control`,
`quasar_pcba_ids`, `leds_yandex_aw21036`, `ya_pd_controllers`, `galcore`,
`quasar_led_ring`, `snd_soc_acm8625`.

Есть `/dev/hifi4dsp0`, `/dev/dolby_fw`, `/dev/unifykeys`, `/dev/galcore`.

В `extra/` лежат ещё `w2l` / `w2l_comm` / `w2l_bt` (Amlogic «11nac», прошивки
`w2l/wifi_w2l_fw_{pcie,usb,sdio}.bin`, USB VID `0x1B8E`) и `leds-aw2101x`
(Awinic AW21012/AW21018) — на живом снимке не загружены.

Про радиомодуль: в DT узлы `aml_wifi` (`amlogic, aml-wifi`) и `aml_bt`
(`amlogic, aml-bt`) по шине **SDIO** (`soc/sdio@fe088000`, стек `aml_sdio`). То
есть дерево описывает **combo-чип Amlogic**, а не Unisoc; вывод про Unisoc
держится только на имени модуля `vlsicomm` — точную модель надо снимать по
SDIO-ID на живой колонке.

Из `.config` ядра (`/proc/config.gz`): **подпись модулей выключена** (нет
`CONFIG_MODULE_SIG`) — свои `.ko` грузятся свободно; `CONFIG_IKCONFIG_PROC=y`
(отсюда и сам конфиг), `KALLSYMS=y`, KASLR вкл, `DM_VERITY` в ядре есть.
Ядро — Amlogic BSP (`CONFIG_AMLOGIC_GKI`, `CONFIG_AMLOGIC_ANDROIDP`), тулчейн
Arm GNU 12.2. В DT есть и неиспользуемое ТВ-наследие BSP: видеодекодер
(`vdec`/`vcodec_dec`), DVB и ИК-блок (`ir@8000` + `meson-irblaster`) — все со
`status = disabled`.

`maind` — **мультибинарь** (как busybox): `quasar_client`,
`begemot_client_util`, `keymaster_proxy_app`, `led_util`, `metrics_collector`
в `/system/vendor/quasar/` — это симлинки на `maind`, а запускается он с
флагами `--platformd` / `--mediad` / `--telemetry` / `--fluent-bitd` /
`--loggerd` (см. `launch.json`).

## NPU — Vivante VIPNano-Q { #gpu }

Блок, который обслуживает `galcore`, — это **не 3D-GPU, а NPU: Vivante
VIPNano-Q (GC9000)**. Снято с живой колонки (на Orion путь к debugfs —
`/sys/kernel/debug/galcore/`, **не** `gc`):

| поле (`galcore/info`, параметры модуля) | значение |
|---|---|
| `model` | `0x9000` |
| `revision` | `0x9002` |
| `product` | `0x5090001` |
| `eco` | `0x4000000` |
| версия `galcore` | `6.4.8.7.7.1.1` |
| адрес / IRQ | `0xfdb00000` (узел `fdb00000.galcore`), `registerMemSize` 128K, IRQ 19 |
| clk (`mc`/`sh`) | ≈ **800 МГц**; `nanoqFreq` 838 860 800 Гц (≈ 839 МГц) |
| `enableNN` / `userClusterMasks` | `255` / `255` |
| `pdevCoreCount` | `21,0,0,0` |
| load (`galcore/load`) | core0 **22 %** (держит `maind`) |

Что это именно NN-ядро, а не графика, подтверждает DT-узел `galcore`
(`compatible = amlogic, galcore`): `clock-names = cts_vipnanoq_axi/core_*`,
`reg-names = NN_REG / NN_SRAM / NN_MEM0 / NN_MEM1 / NN_RESET / NN_CLK`,
`nn_power_version`; класс устройства — **`/sys/class/npu/galcore`**, а
`galcore/version` выдаёт build-путь `.../yandex_orion/build/amlogic-npu-manifest/`.
То есть 3D/2D/VG-пайплайны — это общие возможности Vivante GAL, а на этой
железке распаян только NN-движок под on-device-инференс (споттер, VQE,
биометрия).

`database` в debugfs — это **аллокации памяти процессов** (у `maind` ~17 МБ
virtual + контекст-буферы), а **не** feature-DB с полем `NNcore number`,
поэтому точное число NN-ядер из нод не вылезает; косвенно о мощности говорят
`enableNN=255`, `pdevCoreCount=21` и `nanoqFreq ≈ 839 МГц`.

## Идентификация (сеть)

mDNS (`_yandexio._tcp.local`):

```text
yandex-station-3-<deviceId>
    deviceId=<DEVICE_ID>
    platform=orion
    cluster=yes
```

Подтверждается `glagold` в `quasar.cfg`: `externalPort 1961`, `hostnamePrefix
yandex-station-3-`, `serviceType _yandexio._tcp`, `servicePrefix
YandexIOReceiver-`. Имя точки доступа при настройке — **`Yandex.Station-3`**,
BT-префикс `Yandex.Station-3 ` (`common`).

Порты (localhost, из `quasar.cfg`): glagol internal 9899 / external **1961**,
networkd 9917, net_clock 11125, multiroomd 11124, updatesd 9889, brickd 9898,
config 9882, audioinit 9883. После root — ещё SSH `:22` (и ADB `:5555`, если
включён).

## glagol (порт 1961)

Токен — стандартный публичный flow (`oauth.mobile.yandex.net` →
`quasar.yandex.net/glagol/token`, `platform=orion`). Колонка принимает TLS при
валидном токене; невалидный → `Invalid token` и разрыв. Команды старых платформ
(`softwareVersion`, `ping`, `getVersion`, `status`, `allStates`, `getState`,
`get_status`) на `orion` ответа не дают — набор другой, не описан.

## Сетевые обращения при активации

Сброс → BLE + «Дом с Алисой» → аккаунт (tcpdump по MAC колонки):

1. `scbh.yandex.net` — HTTP `HEAD /generate_204` (User-Agent прошивки).
2. `oauth.yandex.ru`
3. `startup.mobile.yandex.net`
4. `quasar.yandex.net`
5. `report.appmetrica.yandex.net`
6. `uniproxy.alice.yandex.net`, `rpc.alice.yandex.net`
7. CDN OTA (`ext-cloudcdn-ruekt01mts-02.cdn.yandex.net`)

Весь цикл от DHCP до старта загрузки OTA — ~13 с. На стоке порты adb (`5555`) и
ssh (`22`/`2222`) закрыты.

Бэкенды из `quasar.cfg`: `quasar.yandex.net` (основной), `quasar.yandex.ru/dev`
(dev), `uniproxy.alice.yandex.net/uni.ws` и `rpc.alice.yandex.net` (Алиса),
`ws.api.music.yandex.net` (музыка), `push.yandex.ru`, `clck.yandex.net`
(метрика), `startup.mobile.yandex.net`, `scbh.yandex.net/generate_204`
(проверка связи), `quasar.s3.yandex.net` + `*.svc.cdn.yandex.net` (OTA/звуки).
На случай отказа DNS прописан жёсткий **`DnsFallbackMap`:
`quasar.yandex.net → 213.180.193.230`** — это стоит учитывать при DNS-методе.
OTA-демон `updatesd` применяет пакет через `device_ota_update.sh`, проверяя
подпись `ota_script.pub`; каталог обновлений — `/bkupgrade`, имена `*.img`.

## DNS-метод не работает: свой набор корневых CA { #tls }

Классический DNS/MITM на `orion` закрыт: и самоподписанный, и Let's Encrypt
дают `tlsv1 alert unknown ca` (48) — колонка доверяет урезанному набору
корневых CA, а не конкретному сертификату. Подмена работает только для
`scbh.yandex.net` (отдаём настоящий 204). Нужен CA из бандла прошивки (или уже
имеющийся root). Обсуждение — [issue #24](https://github.com/Marker284/yandex-station-extended/issues/24).

На **Лайт 2 / Мини 3** (после 21.10.2026) root получают добавлением своего корня
в CA-бандл из factory mode — для `orion` такой путь не подтверждён (здесь root
взят сетевым методом, см. [Получение root](#root)).

## Что ещё проверить

- Физическая раскладка микрофонов (отверстия корпуса vs 6 каналов PDM
  `raw_mic_0..5`) и безопасная частота захвата параллельно с Алисой.
- Формат кадра `/dev/fb0` (48 bpp) и `/dev/fb1` (21×12).
- Модель Zigbee-чипа (UART известен — `/dev/ttyS2`, см. [Zigbee](#zigbee)).
- Сохраняются ли правки `/etc` после OTA (корень ro, своё — в `/data`).
- Профиль YAM для кольца Orion (36 LED, `orion:` + `ledfb-ring`); из коробки
  в YAM профиля нет.

---

*Железо снято с rooted Orion (SSH), корпус не вскрывали. 
От **[@chelik0002](https://github.com/chelik0002)**, не без помощи **[@shaderlaze](https://t.me/shaderlaze)**
