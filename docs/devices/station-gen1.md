# Станция (1-е поколение)

Розничное имя — **Яндекс Станция** (большая, первое поколение, 2018, модель **YNDX-0001**).
Это **другая аппаратная платформа**, не как у младших Станций: **Allwinner R18** + **Android 6.0.1**
(а не Amlogic + Buildroot). Полноценный медиацентр с **HDMI-выходом**.

!!! info "Две платформы в семействе"
    Станции делятся как минимум на два мира:

    - **Amlogic AXG + Buildroot + quasar/maind** — [Лайт](station-lite.md),
      [Мини 2](station-mini2.md), [Мини](station-mini.md);
    - **Allwinner + Android + quasar как APK** — эта модель (и другие ТВ-ориентированные).

    Многие приёмы из раздела [«Как это устроено»](../internals/architecture.md) (maind-демоны,
    `gst-launch`, init.d) к Android-платформе **не применимы** напрямую — там Android
    и APK. Общее — протокол **glagol** (`:1961`).

## Платформа в двух словах

| | |
|---|---|
| SoC | **Allwinner R18** (`sun50iw1p1`) — тот же кристалл, что **A64**; плата `tulip-d1` |
| ОС | **Android 6.0.1** (SDK 23), ABI `arm64-v8a`, вендорское ядро **3.10.65** |
| CPU | 4× Cortex-A53 (`0xd03`), **480…1152 МГц**; Android держит 1152 МГц постоянно (governor `performance`) |
| ОЗУ | **~980 МБ** (1002756 kB) |
| Хранилище | eMMC ~7.3 ГБ (`mmcblk0`) |
| Видео | **HDMI 1920×1080** (DE2 + DesignWare HDMI) |
| GPU | **Mali-400 MP2** (вендорский `libGLES_mali` r6p0-01rel0) |
| Усилители | **2× TAS5751M**: сабвуфер (моно, PBTL) и пищалки (стерео, BTL) |
| Микрофоны | **7 микрофонов** на **5× TLV320ADC3101** (TDM), ещё 3 канала — опорный сигнал с усилителей для эхоподавления |
| Wi-Fi / BT | **AMPAK AP6356S** (BCM4356, Wi-Fi по SDIO, Bluetooth по UART) |
| Подсветка | кольцо из **24 RGB-светодиодов** на двух **SN3236 / IS31FL3236** (I2C) |
| PMIC | **AXP803** (в вендорском ядре драйвер `axp81x`) |
| Прошивка quasar | 3.21, как Android-APK `ru.yandex.quasar.app` |
| Безопасность | **dm-verity** (`verity_block`), SELinux `permissive` |
| Кодовое имя | `tulip-d1` (`ro.board.platform=tulip`), в конфиге quasar — `yandexstation` |

## Чем принципиально отличается

- **SoC Allwinner R18** (ARM+Android), а не Amlogic+Buildroot. Соответственно — всё
  дерево `sunxi_*` драйверов (`sunxi_daudio`, `sunxi_sndhdmi`, `sunxi-ths` и т.д.).
- **Полный Android 6** со своим init, SELinux, `/system/priv-app`, и **quasar — это
  APK** (`ru.yandex.quasar.app`, `/system/priv-app/Quasar-Webmusic`), а не нативный
  `maind`-стек (хотя нативные роли `--platformd/--mediad` тоже присутствуют).
- **HDMI-выход** и звук по HDMI (`sndhdmi`) — модель задумана как ТВ-приставка-колонка.
- **Звук 2.1** на двух усилителях **TAS5751M**: `1-0x2a` — сабвуфер, `1-0x2b` — пищалки.
- **dm-verity включён** (`verity_block`) — раздел `system` подписан; durable-правки системного
  раздела сложнее, чем на Buildroot-моделях без verity.

## Загрузка и прошивка платформы

- Цепочка: **boot0 → U-Boot (Allwinner, `boota`) → boot.img** (Android boot image v0).
  Слот `recovery` грузится тем же `boota`.
- В фоне работают **ATF (BL31)** и прошивка **SCP на ядре AR100** («arisc»). PMIC сидит на
  шине R_RSB, которой владеет SCP, поэтому ОС обращается к AXP803 **только через вызовы BL31**
  (SMC). Частоту и напряжение CPU тоже меняет SCP по запросу от ядра. В таблице напряжений
  (`dvfs_table`) максимум 1152 МГц при 1,30 В; 1200 и 1344 МГц есть только в `cpufreq_tbl`, и запрос
  такой частоты означает разгон без повышения напряжения.
- Серийный номер (`androidboot.serialno`) U-Boot вычисляет из eFuse SID:
  `%04x%08x%08x` от `SID[1] >> 16`, `SID[2]`, `SID[3]` (SID по адресу `0x01c14200`).
- MAC-адрес Wi-Fi у каждой Станции свой (префикс `cc:4b:73` — AMPAK). В `nvram.txt` у всех Станций
  один и тот же образцовый адрес `00:90:4c:1a:10:01`, а в файлах на eMMC собственного адреса нет.
  По-видимому, вендорский драйвер `bcmdhd` берёт его из **OTP модуля** (в ядре есть
  `dhd_conf_get_otp`). Служба Android `engsetmacaddr` закомментирована.

!!! warning "Чего не делать"
    - **Выключение** (`poweroff`, PSCI `SYSTEM_OFF`), судя по разбору прошивки SCP, полностью
      снимает питание (запись `0x80` в регистр `0x32` AXP803): батареи нет, и Станция включится
      только после переподключения в розетку.
    - Перезагрузка через **PSCI `SYSTEM_RESET`** может подвесить плату до отключения питания.
      Надёжно перезагружает только **сторожевой таймер SoC**.
    - Не трогайте boot0, U-Boot, `env` и раздел `boot`: без них Станция не загрузится.

## Разметка (Android-партиции)

U-Boot передаёт ядру имена разделов строкой `partitions=` в командной строке.
Номера в `mmcblk0` (таблица MBR с расширенным разделом):

| Раздел | Устройство | Размер |
|---|---|---|
| `UDISK` (`/data`) | `mmcblk0p1` | 1.3 ГБ |
| `bootloader` | `mmcblk0p2` | 32 МБ |
| `env` | `mmcblk0p5` | 16 МБ |
| `boot` | `mmcblk0p6` | 16 МБ |
| `system` | `mmcblk0p7` | 2 ГБ |
| `verity_block` | `mmcblk0p8` | 32 МБ |
| `misc` | `mmcblk0p9` | 16 МБ |
| `recovery` | `mmcblk0p10` | 32 МБ |
| `cache` | `mmcblk0p11` | 1.5 ГБ |
| `metadata` | `mmcblk0p12` | 16 МБ |
| `private` | `mmcblk0p13` | 16 МБ |
| `frp` | `mmcblk0p14` | 512 КБ |
| `rescue` | `mmcblk0p15` | 2 ГБ |
| `tinaos` | `mmcblk0p16` | 64 МБ |
| `rback` | `mmcblk0p17` | 32 МБ |
| `secret` | `mmcblk0p18` | 16 МБ |
| `alog` | `mmcblk0p19` | 80 МБ |

В строке U-Boot есть ещё `lback`, `rboot` и `media_data` (`p20`–`p22`), но в таблице MBR/EBR
проверенной Станции разделы заканчиваются на `p19`.

`verity_block` — dm-verity для `system`; `tinaos` — Allwinner Tina (recovery-мир);
`frp` — factory reset protection; `alog` — логи Android.

## I2C / звук

| Шина:адрес | Чип | Назначение |
|---|---|---|
| `1-0x2a` | **TAS5751M** | усилитель сабвуфера (моно, PBTL) |
| `1-0x2b` | **TAS5751M** | усилитель пищалок (стерео, BTL) |
| `1-0x18`…`1-0x1b` | **TLV320ADC3101** ×4 | 7 микрофонов и 1 опорный канал |
| `0-0x18` | **TLV320ADC3101** | 2 опорных канала (выходы усилителей) |

ALSA-карты: `audiocodec`, `snddaudio1` (карта 1, усилители, I2S1), `snddaudio0` (карта 2,
микрофоны, I2S0, TDM), `sndhdmi`, `Loopback` (карта 4: через неё quasar получает опорный
сигнал для эхоподавления). Входы: `axp81x-supplyer` (PMIC), `audiocodec sunxi Audio Jack`,
`sunxi-ths` (термодатчик).

- Данные к усилителям идут по I2S1 (PG10–PG13, оба чипа на одной линии), а MCLK 12,288 МГц —
  с вывода MCLK контроллера I2S0 (**PB3**). Вся настройка звука (эквалайзер, DRC,
  микширование) зашита в вендорский модуль `snd-soc-tas5751m.ko` в виде скриптов регистров.
- Громкость в вендорском драйвере идёт по шкале 0…1023 с шагом 0.125 дБ (0 — без звука,
  1023 — +24 дБ). Громкость Android 100 % — это около +8 дБ (`hardvol_ti.xml`); уже −20 дБ на этой
  колонке очень громко.
- Микрофонные АЦП тактуются только от BCLK (без MCLK) и делят одну линию RESET.

## Доступ

- **ADB** — обычный Android adb (`:5555`); root — по-андроидному (зависит от сборки,
  SELinux `permissive` помогает).
- **glagol** — тот же локальный API на `:1961` (WebSocket/TLS), как на всех Станциях.
- Энтузиасты ставят свои бинарники в `/data/local/bin` (Android-путь) — например,
  `zsh`, `fastfetch`; можно поднять свой dropbear-SSH.

## Что ещё проверить

- Способ получить root и влияние SELinux-политики.
- Обход/отключение OTA на Android-платформе (механизм иной, чем `maind --updatesd`).
- Формат прошивки Allwinner (Tina/`tinaos`) и разделы `lback`/`rboot`/`media_data`.
