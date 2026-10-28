# JBL Link Music (с Алисой)

Колонка **JBL Link Music** со встроенной Алисой. Внутри другой мир, чем у Станций: SoC
**MediaTek** (`mediatek,mt8167`, платформа aud8516), **32-битное** ядро 4.4 и **Yocto** с
systemd вместо Buildroot. Поверх — тот же quasar/`maind`.

Каталоги `/vendor/wiimu` и имя хоста `A118SmartAudio_XXXX` указывают на модуль **LinkPlay**
(WiiMu) — на нём построена колонка.

## Платформа в двух словах { #platform }

| Что | Значение |
|---|---|
| SoC | **MediaTek MT8516** (в device-tree — `MT8167`, `mediatek,mt8167`; `androidboot.hardware=aud8516p1_linux`) |
| CPU | 4× **Cortex-A35** (`0xd04`), 1040 / 1196 / **1300 МГц** |
| Разрядность | **armv7l (32-бит)** — ядро и userspace |
| ОЗУ | **~494 МБ** (MemTotal 505648 kB) |
| Ядро | Linux **4.4.22** armv7l, SMP PREEMPT (сборка 19.12.2025) |
| ОС | **Yocto** «aud Baseline» 11.0.1 (miranda), `poky-aud-systemd`, **systemd** |
| Флеш | **NAND Micron MT29F4G08ABAEAWP**, 512 МБ SLC, страница 4096, блок 256 КБ, UBI |
| Wi-Fi / Bluetooth | **MediaTek MT7668** по SDIO (`wlan_mt7668_sdio`, `btmtksdio`) |
| ЦАП | **TI PCM5121** (`1-004c`) |
| Усилитель | **TI TAS5782M** (`2-0048`) |
| Прошивка quasar | `1.80.0.228.3676124705.20251219` |
| UART | `ttyS0`, **921600** бод (`console=ttyS0,921600n1`) |

!!! warning "Сборки под aarch64 не запустятся"
    Как и на [Станции Стрит](station-street.md), здесь всё 32-битное — нужен ARMv7. Это касается пакетов [`.yap`](../start/packages.md#yap),
    YAM и утилиты `fastfetch` из вики.

## Что работает { #features }

| Что | Состояние | Где описано |
|---|---|---|
| Root и SSH | работает | [ADB по USB на старте](../start/root-jbl-link-music.md) |
| USB Host (OTG) | не проверялось | — |
| AirPlay | не проверялось | — |
| Spotify Connect | не проверялось | — |
| Плеер как Bluetooth-источник | не проверялось | — |
| Свои звуки | не проверялось | — |
| Обработанный микрофон | не проверялось | — |
| Подсветка | не проверялось | — |
| YAM | не проверялось | — |
| Своя LLM | не проверялось | — |

## Получение root { #root }

[ADB по USB на старте](../start/root-jbl-link-music.md): после включения ADB по USB
несколько секунд работает с root. В это окно ставятся маркеры, после которых ADB работает по
сети через порт 5555 и переживает перезагрузку. Нужен только кабель Micro-USB — сервисный разъём
под резиновой подложкой на дне.

В [AliceBridge](../start/root-android.md) есть профиль `jbl_link_music`, но полный проход на
этой модели не проверен.

## Разделы флеша { #partitions }

Разметка A/B: загрузочный образ, TEE и корень — в двух копиях.

| MTD | Раздел | Размер | Что внутри |
|---|---|---|---|
| `mtd0` | `UBOOT` | 512 КБ | загрузчик |
| `mtd1` | `NVRAM` | 1 МБ | |
| `mtd2`, `mtd3` | `BOOTIMG1`, `BOOTIMG2` | по 7 МБ | ядро, слоты A/B |
| `mtd4` | `SEC_RO` | 512 КБ | |
| `mtd5` | `MISC` | 512 КБ | |
| `mtd6`, `mtd7` | `TEE1`, `TEE2` | по 1,5 МБ | TEE, слоты A/B |
| `mtd8`, `mtd9` | `ROOTFS1`, `ROOTFS2` | по 150 МБ | корень, слоты A/B |
| `mtd10` | `FACTORY` | 16 МБ | UBI `factory` → `/factory`, `/vendor/wiimu_factory` |
| `mtd11` | `USRDATA` | 24 МБ | UBI `useradata` → `/data`, `/var` |
| `mtd12` | `BKUPGRADE` | ~149 МБ | UBI `bkupgrade` → `/bkupgrade`, `/vendor/wiimu` |

Монтирование:

- `/` — `ubi0:aud8516m3v4-slc-32b-rootfs`, UBIFS `ro`. В отчёте активен слот `ROOTFS2`
  (`ubi.mtd=9`);
- `/data` и `/var` — один том `useradata`, UBIFS `rw,sync`: данные сразу уходят на флеш
  и сохраняются после перезагрузки;
- `/factory` — `rw,sync`, заводские данные. Не изменяйте;
- `/tmp` — tmpfs, очищается при перезагрузке.

## Шина I2C и периферия { #i2c }

| Шина:адрес | Чип | Назначение |
|---|---|---|
| `0-002c` | **LP8557** (`lp8557-led`) | драйвер подсветки |
| `0-0063` | `strobe_main` | драйвер вспышки/LED |
| `1-004c` | **PCM5121** | ЦАП |
| `1-0060` | **SYM827** | регулятор питания (DC-DC) |
| `2-0048` | **TAS5782M** | усилитель класса D |

Кнопки: `mtk-kpd` (клавиатура SoC), `mtk-pmic-keys` (питание) и `gpio-keys`.
В каталоге `/sys/class/leds` устройств нет.

## Звук { #audio }

Одна карта `mt-snd-card`:

| PCM | Имя | Направление |
|---|---|---|
| `00-00` | `DL1_Playback` | воспроизведение |
| `00-01` | `DMIC_Capture` | захват (цифровые микрофоны) |
| `00-02` | `I2S8CH Playback` | воспроизведение |
| `00-03` | `TDM_Capture` | захват |
| `00-04` | `AWB_Record` | захват |
| `00-05`, `00-06` | `BTCVSD_Capture`, `BTCVSD_Playback` | Bluetooth-голос (CVSD) |
| `00-07` | `DL1_AWB_Record` | захват выхода DL1 |
| `00-08` | `VOIP_Call_BT_Capture` | захват |
| `00-09` | `DL2_Playback` | воспроизведение |
| `00-10` | `ULM_Capture` | захват |
| `00-11` | `SPDIF_OUT Playback` | воспроизведение, S/PDIF |

## Прошивка { #firmware }

- quasar запускается с ролями `--calld`, `--glagold`, `--mediad`, `--updatesd`, `--wifid`,
  `--yiod`;
- ADB — сервис `android-tools-adbd.service` (systemd); сетевой режим включается файлом
  `/data/network_adb`, инструкция — в [руководстве по root](../start/root-jbl-link-music.md);
- датчики температуры: `mtktscpu`, `mtktspmic`, `mtktsAP` (в отчёте 58–73 °C), `mtktswmt`.

## Что ещё проверить { #todo }

- Как отключить обновления на Yocto-прошивке (роль `--updatesd`, конфиг запуска quasar).
- Какие из маркеров ADB, кроме `/data/network_adb`, реально нужны.
- Можно ли перемонтировать корень `/` в `rw` и сохраняются ли правки.
- Работает ли `dropbear` из каталога `contrib/bin` (сборка `armhf`) и Entware для ARMv7.

Есть данные — [дополните](../contributing.md).
