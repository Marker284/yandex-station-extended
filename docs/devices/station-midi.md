# Станция Миди

Розничное имя — **Яндекс Станция Миди**; кодовое имя — **Cucumber** (device-tree
`Yandex Cucumber DVT2`, `yandex,cucumber-dvt2` / `yandex,cucumber`, **`amlogic, a5`**).
Это **новейшее поколение** Amlogic-платформы: SoC **A5** (а не AXG, как у
[Лайта](station-lite.md)/[Мини 2](station-mini2.md)), ядро **5.4**, более быстрые
ядра **Cortex-A55 @ ~2 ГГц**, хранилище eMMC, USB-C PD, **Zigbee-хаб** и фирменные
**LED-часы**.

Прошивка — всё та же **Buildroot + quasar/maind**, так что приёмы из раздела
[Как это устроено](../internals/architecture.md) применимы (с поправкой на ядро 5.4 и новые
пути).

## Получение root

Поддержка Миди добавлена в **[AliceBridge — root с Android](../start/root-android.md)**.
Получение root этим способом проверено и работает; совместимость с другими версиями
прошивки требует отдельной проверки.

## Платформа в двух словах

| | |
|---|---|
| SoC | **Amlogic A5** (`amlogic, a5`) |
| CPU | 4× **Cortex-A55** (`0xd05`), до **2.016 ГГц** (100 МГц … 2016 МГц) |
| ISA | ARMv8.2 (atomics, fphp, asimdhp, asimddp, lrcpc, dcpop) |
| ОЗУ | **~980 МБ** (MemTotal 997788 kB) |
| Ядро | Linux **5.4.180** aarch64 (сборка 20261013) |
| Userspace | Buildroot **2023.11.1** (заметно новее, чем у AXG-моделей) |
| Хранилище | **eMMC** (MTD пуст, UBI не используется) |
| GPU | Vivante (`galcore`) |
| Усилитель | **2× FS2105** (Fourier Semi, стерео smart-PA) |
| Индикация | **LED-часы**: logo (6 RGB) + ring (24 RGB) + белые сегменты циферблата |
| Питание | **USB-C Power Delivery** (`husb238_pd` + `ya_pd_controllers`) |
| Умный дом | **Zigbee** (`zigbee_control`) + предположительно Matter/Zenoh (quasar) |
| Радио | **Unisoc** (`vlsicomm` + `aml_sdio` + `sdio_bt`), BT-пульт (`input_btrcu`) |
| quasar | 3.21 (`0.369.1.46.4778262955.20261013`) |

## Чем принципиально отличается

- **Новый SoC — Amlogic A5** с ядрами **Cortex-A55** (`0xd05`) до **2 ГГц** и ядром
  **5.4** (у AXG-моделей — A53 `0xd03` @1.2 ГГц, ядро 4.9).
- **Хранилище eMMC**, а не NAND+UBI: `/proc/mtd` пуст, UBI-томов нет.
- **USB-C Power Delivery**: контроллер **HUSB238** (`0-0x08`) + модуль
  `ya_pd_controllers` — питание/согласование по USB-C PD.
- **Zigbee-хаб**: модуль `zigbee_control` — встроенный радиомодуль Zigbee для
  умного дома.
- **LED-часы**: помимо кольца и логотипа есть белые **сегменты циферблата** —
  отдельная подсистема индикации (см. ниже).
- **GPU Vivante** (`galcore`) присутствует.
- Усилители **FS2105** (стерео), микрофоны PDM, аппаратный `LOOPBACK-A` (AEC).

## Шина I2C и периферия (4 шины)

| Шина:адрес | Чип | Назначение |
|---|---|---|
| `0-0x08` | **HUSB238** (husb238_pd) | USB-C Power Delivery контроллер |
| `1-0x12` | **AW96105** | ёмкостный SAR-сенсор (касание/приближение) |
| `1-0x20` | **AW21018** | LED-драйвер (матрица) |
| `1-0x34`, `1-0x35` | **AW21036** | LED-драйверы (матрица) |
| `1-0x51` | **PT7C4563** | RTC |
| `1-0x55`, `2-0x50`, `3-0x51` | 24C02A | EEPROM |
| `2-0x68`, `2-0x6a` | **FS2105** | Class-D усилители (стерео) |
| `3-0x21` | **AW21012** | LED-драйвер (матрица) |
| `3-0x37` | **AW21036** | LED-драйвер (матрица) |
| `3-0x53` | **LTR-308** (ltr308als01) | датчик освещённости |

## Индикация (LED-часы) { #led-clock }

У Миди самая сложная индикация в семействе — целый **циферблат** плюс кольцо и
логотип. Все узлы в `/sys/class/leds/`:

- **Логотип:** `cucumber:{red,green,blue}:logo0..5` — 6 RGB-зон.
- **Кольцо:** `cucumber:{red,green,blue}:ring0..23` — **24 RGB-зоны**.
- **Циферблат (белые сегменты):** `cucumber:white:clock-*` — цифры/сегменты
  (`clock-a1..4`, `clock-b1..4`, … `clock-q1..5`, `clock-deg`, `clock-h/l/m/p/q…`) —
  семисегментная раскладка часов.
- **Синхро-узлы:** `cucumber:logo:sync`, `cucumber:ringA:sync`, `cucumber:ringB:sync`,
  `cucumber:sync:clock-0/1`.

Драйверы: `leds_yandex_aw21036`, `leds_aw2101x`, подсистема `quasar_led_ring`
(Awinic AW210xx — это LED-matrix контроллеры с индивидуальной адресацией каналов).

!!! note "Нужно задокументировать"
    Протокол/формат анимаций для 24-зонного кольца и сегментов циферблата. Базовый
    доступ — запись яркости в соответствующие `/sys/class/leds/cucumber:*`.

## Звук

- ALSA card0 `AML-AUGESOUND`: `TDM-A-fs2105-speakers` (playback+capture),
  `PDM-dummy-mics` (микрофоны), `LOOPBACK-A` (AEC-reference).
- Усилители — **2× FS2105** (стерео).

## Вход

- `awinic_sar` — касание/приближение (AW96105).
- `vad_keypad` — кнопки (VAD-клавиатура).
- `mute` — аппаратное отключение микрофона.
- `input_btrcu` — Bluetooth-пульт.

## Ядро и модули (отличия от AXG)

Загружены: `aml_sdio`, `awinic_sar`, `dtbocfg` (DTB-оверлеи), `galcore` (GPU Vivante),
`leds_aw2101x`, `leds_yandex_aw21036`, `ltr308als01`, `optee`/`optee_armtz` (TEE),
`quasar_led_ring`, `quasar_pcba_ids`, `sdio_bt`, `snd_soc_fs2105`, `vlsicomm`,
`ya_pd_controllers` (USB-C PD), `zigbee_control` (Zigbee).

quasar-роли на снимке: `--platformd`, `--mediad`, `--loggerd` (на AXG-моделях
логирование было `--telemetry` / `--fluent-bitd`).

## Что ещё проверить

- Карта разделов eMMC (`/proc/partitions`, `lsblk`, `/dev/mmcblk*`) — на снимке
  `/proc/mtd` пуст.
- Формат анимаций LED-часов (кольцо 24 + сегменты циферблата).
- Zigbee: как устроен `zigbee_control`, какой радиочип, можно ли использовать как
  полноценный Zigbee-координатор.
- USB-C PD: что отдаёт `husb238`, профили питания.
- Отключение OTA и durable-доступ на ядре 5.4 / eMMC-rootfs.

---

*Данные для этой страницы собрал **@egorsexy** — спасибо за вклад! 🙌*
