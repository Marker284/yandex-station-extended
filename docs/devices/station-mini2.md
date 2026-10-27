# Станция Мини 2

Розничное имя — **Яндекс Станция Мини 2**; device-tree — `Yandex Station Mini 2`
(`yandex,station-mini2`, `amlogic, axg`). Та же платформа, что и у
[Станции Лайт](station-lite.md) (Amlogic AXG + Buildroot + quasar), но богаче по
периферии: отдельный ЦАП, кольцо из 6 RGB-зон, LED-часы, датчик освещённости, RTC и выход на наушники.

Общие механизмы (доступ, прошивка, сеть) — в разделе
[Как это устроено](../internals/architecture.md).

## Платформа в двух словах

| | |
|---|---|
| SoC | **Amlogic AXG (A113)**, `amlogic, axg` |
| CPU | 4× Cortex-A53 (`0xd03`), до **1.2 ГГц** (100/250/500/667/1000/1200 МГц) |
| ОЗУ | **~244 МБ** (MemTotal 243996 kB) |
| Флеш | **NAND 256 МБ SLC**, UBI поверх MTD. Встречаются Toshiba `TC58NVG1S3HBAI4` и Micron `MT29F2G08-A` |
| Ядро | Linux **4.9.68** aarch64, PREEMPT (сборки 28.09.2026 и 13.10.2026) |
| Userspace | Buildroot **2020.02.1** (armhf) |
| ЦАП / усилитель | **ES8156** (ЦАП) + **SY6045S** (Class-D усилитель) |
| Микрофоны | PDM-матрица |
| Индикация | кольцо **6 RGB-зон** + **LED-часы**, оба на **IS31FL3236** |
| Радио | **Unisoc UWE5621** (модули `uwe5621_bsp_sdio`, `sprdwl_ng`, `sprdbt_tty`) |
| Выход на наушники | есть (`AML-AUGESOUND Headphones`) |
| quasar | 3.21 (`0.369.1.25…20260928`, `0.369.1.46…20261013`) |
| Температура | `soc_thermal` ~42 °C в простое |

## Отличия от Станции Лайт

- **Звук:** отдельный ЦАП **ES8156** + усилитель **SY6045S** (на Лайте —
  усилитель NTP8910A напрямую). ALSA: `TDM-B-sy6045s-hifi`.
- **Индикация:** кольцо **6 RGB-зон** `mini2:{red,green,blue}:ring{1..6}` (на Лайте — 3) и
  **LED-часы**; обе — на **IS31FL3236** (модуль `leds_is31fl32xx`): кольцо `0-0x3f`, часы `1-0x3c`.
- **Доп. сенсоры:** датчик освещённости **LTR-308** (`1-0x53`), **RTC DS1307**
  (`0-0x68`), SAR-сенсор **AW96103** (`1-0x12`, на Лайте он на шине 0).
- **`/tee`** смонтирован как **vfat** (на Лайте — jffs2).
- **Разъём наушников** (3.5 мм) — на Лайте отсутствует.
- **Радио:** тот же UWE5621, но другие модули ядра: `uwe5621_bsp_sdio`, `sprdwl_ng`, `sprdbt_tty`
  (на Лайте — `vlsicomm`, `aml_sdio`, `sdio_bt`).

## Карта флеша (MTD / UBI)

```text
mtd0 "bootloader" 2 MB   mtd1 "tpl" 2 MB   mtd2 "boot" 10 MB
mtd3 "system" ~80 MB -> ubi0:rootfs (ubifs, RO)
mtd4 "nv" 1 MB -> /tee (vfat, RO)
mtd5 "bkupgrade" 105 MB -> ubi1 (RW) = /bkupgrade (+ /data)
mtd6 "recovery" ~50 MB
```

NAND 256 МБ SLC, page 2048, erase 128 КБ. Две ревизии: Toshiba `TC58NVG1S3HBAI4` (OOB 128)
и Micron `MT29F2G08-A` (OOB 64). rootfs — ubifs **RO** (dm-verity не применён → durable-правки
возможны, см. [Доступ](../start/ssh.md)).

## Шина I2C и периферия

| Шина:адрес | Чип | Назначение |
|---|---|---|
| `0-0x3f` | **IS31FL3236** | LED-драйвер кольца |
| `0-0x68` | **DS1307** | RTC по I2C |
| `1-0x08` | **ES8156** | аудио-ЦАП (Everest) |
| `1-0x12` | **AW96103** (aw9610x_sar) | ёмкостный SAR-сенсор (касание/приближение) |
| `1-0x2a` | **SY6045S** | Class-D усилитель (активный, `TDM-B`) |
| `1-0x3c` | **IS31FL3236** | LED-драйвер часов |
| `1-0x50` | 24C01 | EEPROM (заводские данные) |
| `1-0x53` | **LTR-308** (ltr308als01) | датчик освещённости |

## Индикация

- **Кольцо, 6 RGB-зон**: `/sys/class/leds/mini2:{red,green,blue}:ring{1..6}` (18 каналов).
- **LED-часы**: `/sys/class/leds/mini2:white:clock*` — сегменты `clockA1`…`clockG4`, `clockDEGREE`,
  `clockMINUS`, `clockPLUS1`…`clockPLUS4`.
- Всё пишется из userspace напрямую (sysfs, root). Готовый скрипт для кольца —
  [`contrib/install-rgb-alice-mini2.sh`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/install-rgb-alice-mini2.sh).
- Формат анимаций прошивки — `.led` (как на Лайте, но 6 зон вместо 3): см.
  [формат `.led`](station-lite.md#led-format). Количество hex-колонок в кадре
  соответствует числу зон — **нужно проверить** на этой модели.

## Звук

- ALSA card0 `AML-AUGESOUND`: `TDM-B-sy6045s-hifi` (playback+capture),
  `PDM-dummy` (микрофоны).
- Тракт: `TDM-B` → ЦАП **ES8156** → усилитель **SY6045S**.
- Есть выход на наушники (отдельный input `AML-AUGESOUND Headphones`).

## Вход

- `sar0_pad0` — касание через SAR-сенсор AW96103.
- `AML-AUGESOUND Headphones` — детектор подключения наушников.
- Отдельного `gpio-keys` нет (на Лайте — `gpio-keys-filter`).

## Что ещё проверить на этой модели

- Точный формат `.led` для 6 зон.
- Отключение OTA — по общей схеме: [шаг 2](../start/ssh.md#kill-ota).
- Карту регистров ES8156 / SY6045S через `i2cdump` (аккуратно).
