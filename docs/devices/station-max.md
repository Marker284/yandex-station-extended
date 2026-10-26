# Станция Макс

Розничное имя — **Яндекс Станция Макс** (YNDX-0008); внутренний идентификатор —
**`yandexstation_2`** (`ro.product.device` / `ro.yndx.quasar.platform`,
build-профиль `yandexstation_2_tv/127`). Это флагман-медиацентр на **Amlogic + Android 9**
(не Buildroot/quasar), с видеодекодом, GPU, ТВ-демодулятором и LED-экраном. По сравнению
с Buildroot-колонками — **заметно более закрытая** платформа.

Существует ревизия **`YNDX-00052` — Макс со встроенным Zigbee-координатором** на той же
платформе; её особенности вынесены на отдельную страницу
[«Станция Макс с Zigbee»](station-max-zigbee.md).

!!! warning "Путаница кодовых имён (важно)"
    `yandexstation_2` — это **Станция Макс**, а не розничная [«Станция 2»](station-2.md)!
    Розничная «Станция 2» имеет device-tree-имя `yandex,station-midi` и работает на
    Buildroot/AXG. То есть: `yandexstation_2` ↔ **Макс** (Android), `station-midi` ↔
    **Станция 2** (Buildroot). Ориентируйтесь на ОС и SoC, а не на цифру «2».

## Платформа в двух словах

| | |
|---|---|
| Внутр. имя | `yandexstation_2` (`yandexstation_2_tv/127`) |
| ОС | **YaOS_X** (Яндекс ТВ, поколение 3) на базе **Android 9** (SDK 28), AVB 1.1 |
| Fingerprint | `Yandex/yandexstation_2/yandexstation_2:9/PPR1.180610.011/5000000896:user/release-keys` |
| SoC | **Amlogic** (TV-класс), 4× Cortex-A53 (`0xd03`), до **1.8 ГГц** |
| GPU | **Mali** (`mali_kbase`) + VPU, полный видеодекод |
| ОЗУ | **~2 ГБ** (MemTotal 2038 МБ) |
| Хранилище | **eMMC** (`mmcblk0` + boot0/1 + rpmb), разделы Android |
| Ядро | Linux **4.9.113** aarch64 (Linaro GCC 6.3) |
| Безопасность | **AVB (verified boot) + dm-verity enforcing + SELinux enforcing**, verifiedbootstate=green |
| Усилители | **2× SY6045S** + **TAS5825M** (стерео, Class-D) |
| ЦАП/АЦП | ES8156, PCM1774 (ЦАП); **ES7210** (4-кан. АЦП микрофонов), TLV320ADC3101 |
| Индикация | **LED-экран** (`quasar_led_screen` + `gowin_led_device` + IS31FL32xx) + кольцо |
| ТВ/видео | **ATBM8881** демодулятор (`atbm8881_fe`) + `aml_hardware_dmx` (демукс) |
| Управление | **рукоятка громкости** (`rotary_volume`) |
| Умный дом | **Zigbee** (`zigbee_control`) |
| Радио | Realtek RTL8822 (`88x2es`) + Intel (`iwlwifi`/`iwlmvm`); BT Intel (`btusb`/`btintel`) |

## Чем принципиально отличается

- **Это YaOS (Android TV), а не Buildroot.** Нет `/system/vendor/quasar/` (и нет
  `/vendor|/odm|/product/quasar`), в `/vendor/etc/init/` нет `maind/aliced/setupd`-rc —
  только стандартные Android-HAL и Amlogic-скрипты. Стек quasar распространён **как
  Android-приложения** (`com.yandex.io.sdk`, `com.yandex.tv.alice` и др.). Поэтому
  приёмы из раздела [«Как это устроено»](../internals/architecture.md) (maind-демоны, `gst-launch`,
  init.d, `activate_adb.sh`/`launch.json`) и quasar-root-kit здесь **неприменимы**.
- **Закрытая загрузка.** AVB 1.1 (Android Verified Boot) + **dm-verity (enforcing)** на
  `/vendor` и `/` + **SELinux enforcing**. Правки системных разделов ломают verity.
- **Root по ADB не выдаётся:** `adb root` → *"adbd cannot run as root in production
  builds"*. Shell работает как `uid=2000(shell)`, `u:r:shell:s0`; `dmesg` закрыт
  (`kernel.dmesg_restrict`), многие `/proc` и `/sys` — `Permission denied`.
- **Полноценный медиацентр:** аппаратный видеодекод (H.264/H.265/VP9/AVS/VC1/MPEG),
  Mali GPU, HDMI, демукс и **ТВ-демодулятор ATBM8881** — устройство умеет видео/ТВ.
- **LED-экран** (точечная матрица) через `quasar_led_screen` + Gowin FPGA.

## Разметка (Android, eMMC)

Разделы `/dev/block/`:
```
boot bootloader cache cri_data data dtbo env logo md0 metadata misc
odm param platform product recovery reserved rsv sysrecovery system
tee vbmeta vendor zram0 (+ dm-0, dm-1, loop0..7)
```
`vbmeta`/`dtbo`/AVB — современная Android-загрузка; `/vendor` смонтирован через
**dm-verity** (`dm-1`, ro); TEE на отдельном разделе `tee` (OP-TEE). UBI/NAND не
используется. Размеры: `/odm` 124 МБ, `/product` 122 МБ, **`/vendor` 488 МБ** (dm-verity,
72%), `/data` 1.9 ГБ (занято ~1.5 ГБ), `/cache` 1.0 ГБ, `/metadata` 11 МБ, + `zram0`.

## ПО: YaOS / Яндекс ТВ

Это платформа **Яндекс ТВ** (`ro.yndx.build.os=YaOS_X`, `generation=3`,
`build.number=5000000896`). Набор приложений — как у ТВ-приставки:

- **Медиа/ТВ:** `ru.kinopoisk.yandex.tv`, `com.yandex.tv.live`, `com.yandex.tv.input.efir`
  (эфир/ТВ), `com.yandex.tv.videoplayer`, `com.yandex.tv.webplayer`, `com.yandex.tv.music`,
  `com.yandex.browser.tv`, `ru.yandex.games`;
- **Голос/quasar:** `com.yandex.tv.alice`, `com.yandex.io.sdk`,
  `com.yandex.tv.services[.platform|.privileged]`;
- **Оболочка:** `com.yandex.tv.home`, `com.yandex.tv.settings`, `com.yandex.tv.setupwizard`,
  `com.yandex.tv.keyboard`, `ru.yandex.bleremotecontrol` (BLE-пульт).

## Шина I2C

Имена чипов (из привязки к драйверам; на части адресов — только адрес из-за SELinux):

| Шина:адрес | Чип | Назначение |
|---|---|---|
| `0-0x30` | **SCP** (scp_ctrl) | секурный ко-процессор Amlogic |
| `0-0x3c`, `0-0x3f` | **IS31FL32xx** | LED-драйверы (экран/кольцо) |
| `0-0x53` | **LTR-308** | датчик освещённости |
| `0-0x52/0x54/0x55/0x56/0x57` | AT24 | EEPROM |
| `2-0x08` | **ES8156** | ЦАП |
| `2-0x2a`, `2-0x2b` | **SY6045S** | усилители (стерео) |
| `2-0x40` | **ES7210** | 4-канальный АЦП (микрофоны) |
| `2-0x51` | **PCF8563** | RTC |
| `2-0x18/0x4c/0x4d` | ЦАП/АЦП | (PCM1774 / TLV320ADC3101 и т.п.) |

## Звук

Многоусилительный тракт: **2× SY6045S** + **TAS5825M** (Class-D), ЦАП **ES8156/PCM1774**,
АЦП микрофонов **ES7210** (4 канала) + TLV320ADC3101, плюс `snd_aloop`. (Детали ALSA
закрыты SELinux на не-root shell.)

## Доступ

- **ADB по сети** работает (`:5555`, после серверной активации конфига), но **без root**
  (`uid=2000(shell)`, SELinux enforcing). `/data/local/tmp` — для записи (`/tmp` закрыт).
- Полноценного рута «из коробки» нет: мешают AVB + dm-verity + SELinux + production adbd.
  Путь к руту здесь — не правка rootfs (как на Buildroot-моделях), а разблокировка
  загрузчика / эксплойт (**нужно исследование**).

## Что ещё проверить

- Возможность разблокировки загрузчика (fastboot `unlock`), состояние `ro.boot.flash.locked`.
- Как устроен quasar-APK на Android-платформе (пакет, сервисы).
- Протокол LED-экрана (`quasar_led_screen` / Gowin).
- Назначение ATBM8881 (эфирное ТВ / IPTV-демукс).
- Точная модель SoC (по железу из root-контекста).

---

*Данные собрали **@ilyaleet** и **@rnsdr** (два взаимодополняющих отчёта) — спасибо! 🙌*
