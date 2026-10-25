# Станция Миди

Розничное имя — **Яндекс Станция Миди**; кодовое имя — **Cucumber** (device-tree
`Yandex Cucumber DVT2`, `yandex,cucumber-dvt2` / `yandex,cucumber`, **`amlogic, a5`**,
`amlogic-dt-id = "a5_cucumber_dvt2"`).
Это **новейшее поколение** Amlogic-платформы: SoC **A5** (а не AXG, как у
[Лайта](station-lite.md)/[Мини 2](station-mini2.md)), ядро **5.4**, более быстрые
ядра **Cortex-A55 @ ~2 ГГц**, хранилище eMMC, USB-C PD, **Zigbee-хаб** и фирменные
**LED-часы**.

Прошивка — всё та же **Buildroot + quasar/maind**, так что приёмы из раздела
[Как это устроено](../internals/architecture.md) применимы (с поправкой на ядро 5.4 и новые
пути).

## Получение root { #root }

- **[DNS-метод](../start/root.md)** — как на большинстве моделей, на Миди проверен.
- **[AliceBridge](../start/root-android.md)** — с Android-телефона, без компьютера: поддержка
  Миди добавлена, получение root проверено. Совместимость с другими версиями прошивки пока
  не проверялась.

Дальше — [SSH и отключение обновлений](../start/ssh.md).

## Платформа в двух словах

| | |
|---|---|
| SoC | **Amlogic A5** (`amlogic, a5`) |
| CPU | 4× **Cortex-A55** (`0xd05`), до **2.016 ГГц** (100 МГц … 2016 МГц), см. [DVFS](#dvfs) |
| ISA | ARMv8.2 (atomics, fphp, asimdhp, asimddp, lrcpc, dcpop) |
| ОЗУ | **~980 МБ** (MemTotal 997788 kB; в DT `memory` = `0x3F800000`) |
| Ядро | Linux **5.4.180** aarch64, Linaro GCC 6.3.1 |
| Userspace | Buildroot **2023.11.1** (заметно новее, чем у AXG-моделей) |
| Хранилище | **eMMC** HS400, 8 бит (MTD пуст, UBI не используется), см. [разделы](#partitions) |
| NPU | **Vivante VIPNano-Q** (`galcore`) — нейроускоритель; GPU нет |
| DSP | **Cadence HiFi4** (`hifi4dsp`) @ 800 МГц + аппаратный VAD |
| Усилитель | **2× FS2105** (Fourier Semi, smart-PA): **вуфер + твитеры** |
| Микрофоны | **4× PDM** на крышке, прямоугольником вокруг центра, см. [Микрофоны](#mics) |
| Индикация | **LED-часы**: logo (6 RGB) + ring (24 RGB) + белые сегменты циферблата |
| Питание | **USB-C Power Delivery** (`husb238_pd` + `ya_pd_controllers`) |
| Умный дом | **Zigbee** на чипе **Telink** (`zigbee_control`) + предположительно Matter/Zenoh (quasar) |
| Радио | **Unisoc** (`vlsicomm` + `aml_sdio` + `sdio_bt`), BT-пульт (`input_btrcu`) |

Версии на снимках:

| | quasar | ядро (сборка) | U-Boot |
|---|---|---|---|
| снимок 1 | 3.21 (`0.369.1.46.4778262955.20261013`) | 20261013 | — |
| снимок 2 | `0.369.1.50.4794663100.20261021.160` | 21.10.2026 | `01.01.261021.115421` |

## Чем принципиально отличается

- **Новый SoC — Amlogic A5** с ядрами **Cortex-A55** (`0xd05`) до **2 ГГц** и ядром
  **5.4** (у AXG-моделей — A53 `0xd03` @1.2 ГГц, ядро 4.9).
- **Хранилище eMMC**, а не NAND+UBI: `/proc/mtd` пуст, UBI-томов нет.
- **USB-C Power Delivery**: контроллер **HUSB238** (`0-0x08`) + модуль
  `ya_pd_controllers` — питание/согласование по USB-C PD.
- **Zigbee-хаб**: отдельный радиочип **Telink** под управлением модуля `zigbee_control`
  (см. [Zigbee](#zigbee)).
- **LED-часы**: помимо кольца и логотипа есть белые **сегменты циферблата** —
  отдельная подсистема индикации (см. ниже).
- **NPU Vivante VIPNano-Q** (`galcore`) и **DSP HiFi4** — в SoC есть ускорители для
  нейросетей и обработки звука.
- Усилители **FS2105** (вуфер + твитеры), микрофоны PDM, аппаратный `LOOPBACK-A` (AEC).

## Шина I2C и периферия (4 шины)

| Шина:адрес | Чип | Назначение |
|---|---|---|
| `0-0x08` | **HUSB238** (husb238_pd) | USB-C Power Delivery контроллер |
| `1-0x12` | **AW96105** | ёмкостный SAR-сенсор (сенсорные кнопки) |
| `1-0x20` | **AW21018** | LED-драйвер (матрица) |
| `1-0x34`, `1-0x35` | **AW21036** | LED-драйверы (матрица) |
| `1-0x51` | **PT7C4563** | RTC (внешний; в SoC есть ещё свой `meson-rtc`) |
| `1-0x55` | 24C02A | EEPROM платы **top** |
| `2-0x50` | 24C02A | EEPROM платы **main** |
| `3-0x51` | 24C02A | EEPROM платы **clock** |
| `2-0x68` | **FS2105** | Class-D усилитель — **вуфер** |
| `2-0x6a` | **FS2105** | Class-D усилитель — **твитеры** |
| `3-0x21` | **AW21012** | LED-драйвер (матрица) |
| `3-0x37` | **AW21036** | LED-драйвер (матрица) |
| `3-0x53` | **LTR-308** (ltr308als01) | датчик освещённости |

Привязка EEPROM к платам — из узла `pcba_ids` (`eeprom-names = "main", "top", "clock"`,
плюс unifykey `assembly`); его читает модуль `quasar_pcba_ids`.

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

Кроме sysfs, кольцо и логотип выставлены как **framebuffer** (драйвер `yandex,ledfb`):

| Устройство | Имя | Размер | bpp | Примечание |
|---|---|---|---|---|
| `/dev/fb0` | `ring` | 24×1 | 24 | `yandex,hw-brightness` |
| `/dev/fb1` | `logo` | 6×1 | 24 | |

Сегменты циферблата во framebuffer не входят — только `/sys/class/leds/cucumber:white:clock-*`.

!!! note "Нужно задокументировать"
    Формат кадра для `/dev/fb0`/`/dev/fb1` (порядок байт RGB, как quasar рисует анимации
    и не перетирает ли он кадр) и протокол анимаций сегментов циферблата. Базовый доступ —
    запись яркости в `/sys/class/leds/cucumber:*`.

## Звук

- ALSA card0 `AML-AUGESOUND`: `TDM-A-fs2105-speakers` (playback+capture),
  `PDM-dummy-mics` (микрофоны), `LOOPBACK-A` (AEC-reference).
- Усилители — **2× FS2105**, полосы разделены: `prefix-names = "woofer", "tweeters"`
  (`0x68` → вуфер, `0x6a` → твитеры). TDM-A: формат i2s, 2 слота × 32 бит, MCLK 12.288 МГц.
- Микрофоны — PDM; у `LOOPBACK-A` `datain_chnum = 4`, `datain_chmask = 0xf`. Микрофонов
  действительно **4**, раскладка и доступ — в разделе [Микрофоны](#mics).
- **DSP HiFi4** (`hifi4dsp`): один DSP (`dspa`) @ 800 МГц, прошивка в SRAM `0xF7030000`
  (3.6 МБ), CMA-пул `linux,dsp_fw` 8 МБ.
- **VAD** (`snd-vad-top`) с прерыванием `irq_wakeup` — аппаратное детектирование голоса
  для пробуждения из сна.
- В DT есть узел `dolby_fw` (1 МБ под прошивку Dolby).

## Микрофоны { #mics }

На крышке четыре отверстия микрофонов. Они стоят прямоугольником вокруг центра, между
кнопками «−» и «+»: по ширине (слева направо) расстояние примерно в 1,5 раза больше, чем
по глубине. Каналы `hw:0,1` (`PDM-dummy-mics`), вид сверху, лицевая сторона (циферблат) снизу:

```
          зад (разъём питания)
   ┌───────────────────────────┐
   │      мик 2      мик 3     │
 − │                           │ +
   │      мик 1      мик 0     │
   └───────────────────────────┘
          лицевая (циферблат)
```

| Канал | Где |
|---|---|
| 0 | спереди справа (сторона «+») |
| 1 | спереди слева (сторона «−») |
| 2 | сзади слева (сторона «−») |
| 3 | сзади справа (сторона «+») |

Как проверяли: тыкали ручкой у каждого отверстия и смотрели, в какой канал звук приходит
первым (задержки по всем шести парам через GCC-PHAT). Между дальними микрофонами звук
идёт до ~14 сэмплов при 96 кГц. По этим задержкам направление на источник определяется
уверенно, на этом работает подсветка «откуда звук».

Захват:

```sh
arecord -D hw:0,1 -f S32_LE -c 4 -r 96000 -t raw > /tmp/mics.raw   # S16_LE тоже работает
```

!!! warning "Не меняйте частоту PDM"
    PDM общий с захватом прошивки: `maind --platformd` держит `hw:0,2` (`LOOPBACK-A`,
    8 каналов, S16, 96000 Гц), в который приходят те же микрофоны. Если открыть `hw:0,1`
    на другой частоте, PDM перенастраивается под вас, и Алиса глохнет: на 16000 Гц её поток
    встаёт полностью, на 48000 Гц идёт вдвое медленнее. Так остаётся и после закрытия
    `arecord`, пока PDM снова не откроют на 96000 Гц. На **96000 Гц** (4 канала, S16 или
    S32) запись параллельно с Алисой безопасна. Проверить, что прошивка получает звук:
    `hw_ptr` в `/proc/asound/card0/pcm2c/sub0/status` должен расти на ~96000 в секунду.
    Частота захвата прошивки видна в `/proc/asound/card0/pcm2c/sub0/hw_params`.

## Вход

- `awinic_sar` — сенсорные кнопки (AW96105): `linux,keycodes` = `KEY_VOICECOMMAND`,
  `KEY_VOLUMEUP`, `KEY_VOLUMEDOWN`.
- `vad_keypad` — кнопки (VAD-клавиатура).
- `mute` (`gpio-keys`) — аппаратное отключение микрофона, два узла:
    - `mute-key` — кнопка, `KEY_MUTE`;
    - `mute-switch` — переключатель с состоянием, `EV_SW` / `SW_MUTE_DEVICE`.
- `input_btrcu` — Bluetooth-пульт.

## Zigbee { #zigbee }

- Радио — отдельный чип **Telink**: прошивка `/system/vendor/quasar/zigbee/gateway.ybl`
  несёт сигнатуру Telink `KNLT` (смещение `0x20`), код — RISC-V (вероятно, семейство
  TLSR9 / TL321x).
- Узел DT `zigbee` (`yandex,zigbee-control`): `zb-reset-gpios` и `zb-boot-gpios` —
  Linux может сбросить радиочип и перевести его в бутлоадер, т.е. прошивка радио
  обновляется со стороны Станции.
- Связь с SoC — по UART с RTS/CTS (см. [UART](#uart)).
- Рядом лежит каталог `/system/vendor/quasar/zigbee/http/` (`index.html` + bootstrap).

## UART { #uart }

| tty | Адрес | Назначение |
|---|---|---|
| `ttyS0` | `FE07A000` | отладочная консоль; в env U-Boot `console=ttyS0,921600`, но ядро стартует с пустым `console=`, а U-Boot — с `silent=1` |
| `ttyS1` | `FE078000` | RTS/CTS, есть трафик — BT / Zigbee |
| `ttyS2` | `FE07C000` | RTS/CTS, есть трафик — BT / Zigbee |

## Разделы eMMC { #partitions }

Драйвер разделов Amlogic создаёт устройства прямо в `/dev/<имя>`
(`/dev/block/by-name` нет); `/dev/root → system`, `root=PARTLABEL=system`.

| Раздел | Устройство | Размер | Что внутри |
|---|---|---|---|
| bootloader | `mmcblk0p1` | 4M | U-Boot; копии — `mmcblk0boot0/1` (`/dev/bootloader0/1`) |
| reserved | `mmcblk0p2` | 64M | таблица разделов MPT, unifykeys, DTB |
| cache | `mmcblk0p3` | — | узел `/dev/cache` есть, в `/proc/partitions` отсутствует |
| env | `mmcblk0p4` | 8M | U-Boot env (64 КБ, CRC32) |
| misc | `mmcblk0p5` | 4M | |
| tee | `mmcblk0p6` | 48M | ext4, `/tee` (ro) — OP-TEE secure storage |
| aml_sysrecovery | `mmcblk0p7` | 1.5G | |
| boot | `mmcblk0p8` | 64M | ядро + DTB |
| recovery | `mmcblk0p9` | 192M | |
| system | `mmcblk0p10` | 1G | rootfs (ext4) |
| ota | `mmcblk0p11` | 1.5G | ext4, `/ota` — `swupdate.*`, `data/wpa_supplicant.conf`, `data/quasar` |
| data | `mmcblk0p12` | 2.8G | ext4, `/data` |

!!! warning "Личные данные"
    Кроме `data`, личное лежит в **`ota`** (пароли Wi-Fi, состояние quasar — в том числе
    в удалённых блоках), **`env`** (серийник, `cpu_id`), **`reserved`** (unifykeys:
    `deviceid`, `key_blob`) и **`tee`**. Не публикуйте их дампы как есть.

## Питание и температура { #dvfs }

CPU-регулятор `vddcpu0` — PWM, 0.689…1.049 В; governor `schedutil`.

| МГц | 100…1404 | 1500 | 1608 | 1704 | 1800 | 1920 | 2016 |
|---|---|---|---|---|---|---|---|
| В | 0.769 | 0.799 | 0.829 | 0.869 | 0.909 | 0.969 | 1.009 |

Точки ниже 1404 МГц: 100, 250, 500, 667, 1000, 1200, 1404.

Термозона `soc_thermal`: троттлинг с **85 °C**, второй порог **95 °C**,
критическая **105 °C**; `sustainable-power` 1160 мВт.

## Прочее железо по DT

- **Wi-Fi** (`aml_wifi`): SDIO 4 бит до 200 МГц, `power_on`/IRQ на GPIO, 32 кГц от PWM.
- **BT** (`aml_bt`): GPIO `reset`, `btwakeup`, `hostwake`.
- **USB**: контроллер CRG DRD (PHY USB2 + USB3), OTG.
- **pstore/ramoops**: `0x06000000`, 1 МБ — логи паники ядра переживают перезагрузку
  (`/sys/fs/pstore`).
- **Безопасность**: JTAG выключен (`select = "disable"`), `secmon`/`securitykey` (ключи
  через SMC), `unifykey`, `efuse`, аппаратные AES/SHA/TDES и TRNG; verified boot
  (`androidboot.verifiedbootstate=green`).
- **Есть в SoC, но выключено**: Ethernet (dwmac, внутренний PHY), ИК-приёмник
  (`meson-ir`), `ramdump_bl33z`.

## Ядро и модули (отличия от AXG)

Загружены: `aml_sdio`, `awinic_sar`, `dtbocfg` (DTB-оверлеи), `galcore` (NPU Vivante),
`leds_aw2101x`, `leds_yandex_aw21036`, `ltr308als01`, `optee`/`optee_armtz` (TEE),
`quasar_led_ring`, `quasar_pcba_ids`, `sdio_bt`, `snd_soc_fs2105`, `vlsicomm`,
`ya_pd_controllers` (USB-C PD), `zigbee_control` (Zigbee).

Конфиг ядра доступен в `/proc/config.gz` (`CONFIG_IKCONFIG=y`). DTB-оверлей из
`/boot`: `yandex-cucumber-i2ctop-overlay.dtb` (включает `i2c@68000`).

quasar-роли на снимке: `--platformd`, `--mediad`, `--loggerd` (на AXG-моделях
логирование было `--telemetry` / `--fluent-bitd`).

## Что ещё проверить

- Формат кадра LED-framebuffer'ов и анимаций сегментов циферблата.
- Zigbee: точная модель Telink и можно ли использовать его как полноценный
  Zigbee-координатор.
- USB-C PD: что отдаёт `husb238`, профили питания.
- Отключение OTA и durable-доступ на ядре 5.4 / eMMC-rootfs.

---

*Данные для этой страницы собрали **@egorsexy** и **[@chelik0002](https://github.com/chelik0002)** — спасибо за вклад! 🙌*
