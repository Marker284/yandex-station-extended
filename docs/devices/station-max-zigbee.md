# Станция Макс с Zigbee

Розничное имя — **Яндекс Станция Макс**, SKU на днище — **`YNDX-00052`** (ревизия со
встроенным Zigbee-координатором). Внутренний идентификатор платформы тот же, что у
обычной Макс: **`yandexstation_2`** (`ro.yndx.quasar.platform`, `ro.yndx.build.board`),
build-профиль `yandexstation_2_tv/127`. Железо и ОС совпадают с
[«Станция Макс»](station-max.md) почти полностью — отличие в **Zigbee-подсистеме** и
мелочах платы.

Всё ниже проверено на **`YNDX-00052`, прошивка `5000000896`**: дамп разделов, `live.dts`,
`lsmod`, `kallsyms`, `getprop`, U-Boot `env`, `quasar.cfg`. Догадки помечены явно.

!!! warning "Путаница кодовых имён (важно)"
    `yandexstation_2` — это **Станция Макс**, а не розничная [«Станция 2»](station-2.md).
    Дополнительно: **`YNDX-00052` (Макс с Zigbee) и `YNDX-0008` (Макс) — один и тот же
    `yandexstation_2`** с одинаковым fingerprint. В приложении и в `quasar.cfg` ревизия с
    Zigbee тоже определяется как `YNDX-0008`, поэтому различить их по ПО нельзя — только
    по SKU на корпусе и по наличию узла `zigbee` в device-tree.

## Платформа в двух словах { #platform }

| | |
|---|---|
| Внутр. имя | `yandexstation_2` (`yandexstation_2_tv/127`), SKU `YNDX-00052` |
| ОС | **YaOS_X** (`ro.yndx.build.os`), поколение 3 (`ro.yndx.build.generation`) на **Android 9** (SDK 28) |
| Fingerprint | `Yandex/yandexstation_2/yandexstation_2:9/PPR1.180610.011/5000000896:user/release-keys` |
| Сборка | `5000000896`, `ro.build.date` — 14 окт. 2026, патч безопасности `2018-08-05` |
| SoC | **Amlogic S905X2**, ревизия кристалла `g12a_s905x2_rev35f` (`ro.boot.hardware.amlogic_dt_id`), 4× Cortex-A53 (`0xd03`) |
| GPU | **Mali-G52** (Bifrost, узел DT `/bifrost`, драйвер `mali_kbase`), DVFS 125…850 МГц |
| ОЗУ | **2 ГБ** (`MemTotal 2038276 kB`) |
| Хранилище | **eMMC** `mmcblk0` 15 267 840 блоков (≈14.56 ГБ user-area), 21 раздел + `boot0`/`boot1` (по 4 МБ) + `rpmb` |
| Ядро | Linux **4.9.113** aarch64 (Linaro GCC 6.3.1), `#1 SMP PREEMPT` |
| Безопасность | **AVB 1.1** + **dm-verity enforcing** + **SELinux enforcing**, `vbmeta.device_state=locked`, `verifiedbootstate=green`, `jtag=disable` |
| Усилители | **2× SY6045S** (I2C `2-0x2a`, `2-0x2b`) |
| ЦАП/АЦП | **ES8156** (I2C `0-0x08`), **ES7210** 4-кан. АЦП микрофонов (I2C `2-0x40`) |
| Индикация | `fb4` «YNDX LED screen» 25×16 + `fb5` «YNDX LED ring» 24×1, 2× **IS31FL3236** |
| Умный дом | **Zigbee NCP на UART** + провайдеры `Zigbee`/`Matter`/`WiFi` в `quasar.cfg` |
| ТВ/видео | **ATBM8881** (`atbm8881_fe`) + `aml_hardware_dmx`, полный набор `amvdec_*` |
| Управление | `rotary-volume` (поворотное кольцо), `gpio_keypad`, HDMI-CEC |
| RTC | **PCF8563** (I2C `2-0x51`) |
| Радио | **Intel** `iwlwifi`/`iwlmvm` по PCIe (`fc700000`, MSI IRQ 64) + BT `btusb`/`btintel` |

## Zigbee: как он устроен { #zigbee }

Это главное отличие ревизии. Координатор — **внешний NCP-чип на UART**, которым управляет
связка из своего драйвера и демона `iotd`.

**Device-tree** (`live.dts`) — отдельный узел с двумя GPIO:

```text
zigbee {
    compatible = "yandex,zigbee-control";
    status = "okay";
    zb-reset-gpios = <0x9c 0x0 0x0>;
    zb-boot-gpios  = <0x9c 0x1 0x0>;
};
```

**Драйвер** — модуль `zigbee_control.ko` (в `lsmod` как `zigbee_control`). По символам из
`kallsyms` (`zb_control_probe`, `zb_claim_gpio`, `zb_control_remove`) он занимается
**только линиями reset и boot**: `zb-boot-gpios` — вход в загрузчик чипа для
перепрошивки, `zb-reset-gpios` — сброс. Данные через него не идут.

**Транспорт** — символьное устройство `/dev/zigbee_uart`. Правила из `vendor.img`:

```text
symlink /dev/ttyS4   /dev/lp_uart
symlink /dev/lp_uart /dev/zigbee_uart
symlink /dev/ttyS4   /dev/zigbee_uart
/dev/lp_uart         u:object_r:zigbee_device:s0
/dev/zigbee_uart     u:object_r:zigbee_device:s0
/dev/lp_uart         0666  root  root
```

Нюанс этой платформы: **`ttyS4` — не родной UART Amlogic.** Узел `serial@4000`
(`uart_AO_B`, которому по алиасам DT соответствует `ttyS4`) в `live.dts` имеет
`status = "disabled"`, а TTY-драйвер с именем `lp_uart` зарегистрирован модулем
**`gowin_led_device.ko`** — тем самым, что обслуживает LED-экран. В `kallsyms` символы
`lp_uart_init`, `lp_uart_open`, `lp_uart_write`, `lp_uart_rx_work`, `lp_uart_poll`,
`lp_uart_ops` помечены как `[gowin_led_device]`. То есть Zigbee-линия поднята **через
Gowin FPGA**, а не через контроллер SoC: ядро Amlogic отдаёт наружу только
`serial@3000`/`uart_AO` (консоль) и `serial@ffd24000`/`uart_A`.

**Демон и прошивка** — секция `zigbee` в `quasar.cfg` (`com.yandex.io.sdk`):

| Параметр | Значение |
|---|---|
| `tty.port` | `/dev/zigbee_uart` |
| `firmware` | `${QUASAR}/zigbee/gateway.ybl` (234 044 байта, формат Silicon Labs `.ybl`) |
| `networkFileName` | `${DATA}/data/zigbee/network.dat` |
| `deviceDbFileName` | `${DATA}/data/zigbee/device.lmdb` |
| `ota.*` | свой OTA-склад для прошивок Zigbee-устройств (`ota.lmdb`, лимит 6144 КБ, TTL 12 ч) |
| `zbControl` | `true` |
| `enableSystemDiscovery` | `true` |

Метрики в `quasar.cfg` используют терминологию **EmberZNet/EZSP**: `zigbeeNCPInitFailed`,
`zigbeeNcpReset`, `zigbeeNcpException`, `zigbeeEnterBootloaderFailed`,
`zigbeeFirmwareUpdateFailed`. Вместе с форматом `.ybl` это указывает на **Silicon Labs
EFR32** в роли NCP — конкретная модель по дампу не определяется, нужна маркировка на
плате. В `zigbee/http/` лежит ещё и мини-веб-интерфейс (`index.html` + bootstrap).

Провайдеры умного дома в `quasar.cfg` (`iot.providers`): `Zigbee: true`, `Matter: true`,
`WiFi: true`.

## Чем принципиально отличается { #differences }

- **Это YaOS (Android TV), а не Buildroot.** Стек quasar — Android-приложения:
  `com.yandex.io.sdk` лежит в `/system/priv-app/ServicesIosdk/ServicesIosdk.apk`,
  `com.yandex.tv.alice` — в `/vendor/app/YandexTvAlice/YandexTvAlice.apk`. Рабочий каталог
  конфигов — `/data/data/com.yandex.io.sdk/files/system/` (там же `quasar.cfg`, `led.cfg`,
  `ledpatterns/`, `frontal_animation/`, `zigbee/gateway.ybl`). Приёмы из
  [«Как это устроено»](../internals/architecture.md) (maind/aliced, init.d) неприменимы.
- **A/B-слотов на этой ревизии нет.** В U-Boot `env` логика слотов есть
  (`get_valid_slot`, при `avb2=0` корень берётся с `mmcblk0p23`/`p24` для `_a`/`_b`), но
  физически на диске только `mmcblk0p1…p21` — разделы слотов не нарезаны, устройство
  одно-слотовое, грузится с `p18`.
- **Батареи нет, но Android считает иначе.** `dtbo`-оверлей добавляет в `/` узлы
  `dummy-battery` и `dummy-charger` (`amlogic, dummy-battery`/`-charger`), а загрузчик
  передаёт `ro.boot.fake_battery=42` — иначе `healthd`/`BatteryService` выключают колонку.
- **Идентификация платы по EEPROM.** Модуль `quasar_pcba_ids.ko` (DT-узел `pcba_ids`,
  `compatible = "pcba-ids"`) читает шесть EEPROM `24c01` и unifykeys. Имена плат из DT:
  `som`, `bp`, `led_display`, `led_ring`, `mics`, `dc_ethernet` — по одному EEPROM на
  субплату. Похоже, именно так прошивка различает ревизии (не проверялось).

## Разметка (Android, eMMC) { #partitions }

Имена разделов задаёт **device-tree**, узел `/partitions` (`parts = 18`, порядок — по
ссылкам `part-0`…`part-17`, а не по порядку узлов в тексте DTS). Сверка этих размеров с
`/proc/partitions` даёт однозначную карту:

```text
раздел            блоков (1 КБ)   размер    имя (by-name)
mmcblk0             15267840      14.56 ГБ  (вся user-area)
mmcblk0p1               4096          4 МБ  bootloader
mmcblk0p2              65536         64 МБ  reserved
mmcblk0p3            1146880       1120 МБ  cache
mmcblk0p4               8192          8 МБ  env
mmcblk0p5               8192          8 МБ  logo
mmcblk0p6              24576         24 МБ  recovery
mmcblk0p7               8192          8 МБ  misc
mmcblk0p8               8192          8 МБ  dtbo
mmcblk0p9               8192          8 МБ  cri_data
mmcblk0p10             16384         16 МБ  param
mmcblk0p11             16384         16 МБ  boot
mmcblk0p12             16384         16 МБ  rsv
mmcblk0p13             16384         16 МБ  metadata
mmcblk0p14              2048          2 МБ  vbmeta
mmcblk0p15             32768         32 МБ  tee
mmcblk0p16            524288        512 МБ  vendor
mmcblk0p17            131072        128 МБ  odm
mmcblk0p18           1515520       1480 МБ  system      (dm-verity -> dm-0 = /)
mmcblk0p19            131072        128 МБ  product
mmcblk0p20           1572864       1536 МБ  sysrecovery
mmcblk0p21           9822208       9.37 ГБ  data

mmcblk0boot0 / mmcblk0boot1 — по 4096 (4 МБ);  mmcblk0rpmb — 4096
zram0 — 262144 (256 МБ);  dm-0 — 1491524 (/);  dm-1 — 515932 (/vendor)
```

Привязка держится на четырёх независимых якорях: `p18` = `system` (прямо из
`dm=`/`root=/dev/dm-0` в cmdline), а `dtbo` = `p8`, `vbmeta` = `p14`,
`sysrecovery` = `p20` — по образам разделов. Остальные имена из DT ложатся на размеры без
расхождений.

Единственное отклонение от порядка DT: **`cache` вынесен в начало** (`p3`), хотя в DT он
стоит `part-15` — его, как `bootloader`, `reserved` и `env`, создаёт прошивальщик Amlogic
до разделов из таблицы. Разделы `cri_data`, `param` и `cache` помечены в DT `mask = 0x2`
(не перезаписываются при обновлении), `data` — `mask = 0x4`, остальные — `0x1`.

!!! note "Как снять имена разделов на живом устройстве"
    На Android это **`/dev/block/by-name/`** (на этой плате —
    `/dev/block/platform/soc/ffe07000.mmc/by-name/`), а не `/dev/disk/by-name/`, как на
    десктопном Linux. Но под `uid=2000(shell)` каталог `/dev/block/` не листается. Без
    root работают два обходных пути:

    ```sh
    cat /sys/block/mmcblk0/mmcblk0p*/uevent | grep PARTNAME
    cat /proc/device-tree/partitions/*/pname
    ```

`df -h`: `/` 1.4 ГБ (занято 1.2 ГБ, 89 %), `/vendor` 488 МБ (dm-verity, 71 %),
`/odm` 124 МБ, `/product` 122 МБ, **`/data` 9.1 ГБ** (занято 1.6 ГБ), `/cache` 1.0 ГБ,
`/metadata` 11 МБ, `/mnt/vendor/param` 11 МБ, `/mnt/vendor/tee` 27 МБ, `/tmp` 128 МБ
(tmpfs), `/tmp/untrusted` 70 МБ.

!!! note "`/data` здесь 9.1 ГБ"
    На странице обычной Макс указано `/data` 1.9 ГБ. На этом экземпляре раздел
    `mmcblk0p21` — 9 822 208 блоков, и `df` показывает 9.1 ГБ. Похоже, 1.9 ГБ относится к
    другой конфигурации флеша; при сверке моделей это стоит перепроверять.

## Шина I2C { #i2c }

Живой скан `/sys/bus/i2c/devices` (не вывод по списку драйверов): две шины, `i2c-0` —
`ffd1f000.i2c`.

| Шина:адрес | Чип | Назначение |
|---|---|---|
| `0-0x08` | **ES8156** | стерео-ЦАП (линейный выход) |
| `0-0x30` | `meson-g12a` | узел SoC (имя драйвера в sysfs) |
| `0-0x3c` | **IS31FL3236** (`is31fl3236,gva`) | LED-драйвер №1 — диоды кольца 1…12 |
| `0-0x3f` | **IS31FL3236** (`is31fl3236,gva`) | LED-драйвер №2 — диоды кольца 13…24 |
| `0-0x51`, `0-0x52`, `0-0x54`…`0-0x57` | **24c01** ×6 | EEPROM субплат (`som`, `bp`, `led_display`, `led_ring`, `mics`, `dc_ethernet`) |
| `0-0x53` | **LTR-308ALS-01** | датчик освещённости (автояркость) |
| `2-0x2a` | **SY6045S** | УМЗЧ класса D №1 |
| `2-0x2b` | **SY6045S** | УМЗЧ класса D №2 |
| `2-0x40` | **ES7210** (`es7210_2ch`) | 4-канальный АЦП микрофонного массива |
| `2-0x51` | **PCF8563** | RTC |

SPI: `spi32766.0` → `spi:led_screen` (фронтальная матрица).

!!! warning "Драйвер в сборке ≠ чип на плате"
    В `lsmod` и в `/vendor/lib/modules/` есть `snd-soc-tas5825m`, `snd-soc-pcm1774`,
    `snd-soc-tlv320adc3101`, а также Wi-Fi-модули Realtek `88x2es` (RTL8822) и UNISOC
    `sprdwl_ng`/`uwe5621_bsp_sdio`. **Соответствующих устройств на шинах нет:** в I2C-скане
    отсутствуют адреса TAS5825M, PCM1774 и TLV320ADC3101, а из радио реально работает
    только Intel (`iwlwifi` на PCIe `fc700000`, 88 758 прерываний); `88x2es` в сборке есть,
    но не загружен, `sprd*`/`uwe5621` в `lsmod` отсутствуют вовсе. Это один образ прошивки
    на несколько ревизий плат — по составу модулей нельзя судить о распаянных чипах.

## Индикация: LED-экран и кольцо { #leds }

Оба выведены как обычные Linux-фреймбуферы:

| Устройство | `name` | `virtual_size` | `bits_per_pixel` | `stride` | Кадр |
|---|---|---|---|---|---|
| `/dev/graphics/fb4` | `YNDX LED screen` | `25,16` | 24 | 75 | 1200 Б |
| `/dev/graphics/fb5` | `YNDX LED ring` | `24,1` | 24 | 72 | 72 Б |

Кольцо дополнительно доступно поканально:
`/sys/class/leds/station2:{red,green,blue}:ring{1..24}`, причём диоды 1…12 висят на
`0-0x3c`, а 13…24 — на `0-0x3f`.

Модули: `gowin_led_device` (FPGA-мост, он же держит `lp_uart` для Zigbee),
`quasar_led_screen`, `quasar_led_ring`, `leds-is31fl32xx`. Яркость по умолчанию приходит
из загрузчика: `ro.boot.led_ring_brightness=255`, `ro.boot.led_screen_brightness=100`.

GIF-анимации фронтального экрана и паттерны кольца лежат в
`/data/data/com.yandex.io.sdk/files/system/` — `frontal_animation/25x16/*.gif` и
`ledpatterns/*.led` (есть и `zigbee_identification.led` — подсветка при привязке
Zigbee-устройства).

## Звук { #audio }

Одна звуковая карта + loopback:

```text
0 [AMLAUGESOUND]: AML-AUGESOUND - AML-AUGESOUND
1 [Loopback    ]: Loopback - Loopback 1
```

`/proc/asound/devices`: воспроизведение `0-0`, `0-2`, `0-3`; запись `0-0`, `0-1`.
Тракт по факту: ЦАП **ES8156** → 2× **SY6045S**, микрофоны — **ES7210** (4 канала).
Детектор джека — отдельное устройство ввода `AML-AUGESOUND Headphones` (`event3`).
Акустические профили и эквалайзер — в `sound_presets/` внутри каталога `io.sdk`.

## Устройства ввода { #input }

| Узел | Имя | Назначение |
|---|---|---|
| `event0` | `gpio_keypad` | физические кнопки (в т.ч. отключение микрофонов) |
| `event1` | `cec_input` | команды пульта ТВ по HDMI-CEC |
| `event2` | `rotary-volume` | поворотное кольцо громкости |
| `event3` | `AML-AUGESOUND Headphones` | детектор кабеля 3.5 мм |

## Ключи: unifykeys { #unifykeys }

`/sys/class/unifykeys` — 21 ключ. Полезно для понимания, что лежит в eFUSE/secure-хранилище
и почему устройство нельзя просто «переподписать»:

```text
usid(normal) mac(efuse) hdcp(secure) secure_boot_set(efuse) mac_bt(normal)
mac_wifi(normal) hdcp2_tx hdcp2_rx widevinekeybox(secure) deviceid(efuse)
hdcp22_fw_private(secure) PlayReadykeybox25(secure) prpubkeybox(secure)
prprivkeybox(secure) attestationkeybox(secure) netflix_mgkid(secure)
hdcp14_rx key_blob secret_key(secure) eth_exphy_para localization
```

U-Boot читает `deviceid`, `mac` и `localization` через `keyman` и подставляет их в
`bootargs` (скрипт `cmdline_keys`).

## Доступ { #access }

- **Root «из коробки» нет:** AVB 1.1 + dm-verity `enforcing` + SELinux `enforcing`,
  `ro.secure=1`, `ro.adb.secure=1`, `ro.boot.vbmeta.device_state=locked`,
  `ro.boot.rh_unlock=0`.
- **`ro.boot.flash.locked` на этой платформе нет.** Состояние блокировки смотреть по
  `ro.boot.vbmeta.device_state` (`locked`) и `ro.boot.verifiedbootstate` (`green`).
- **Отладочный путь заложен в U-Boot env, а не в fastboot.** Из скрипта `storeboot`:

    ```sh
    if test "${rabbit_hole_debug}" = 1; then setenv rh_unlock 1; else setenv rh_unlock 0; fi
    setenv bootargs ${bootargs} androidboot.rh_unlock=${rh_unlock}
    adb_en_l=0
    if test ${rh_unlock} = 1; then adb_en_l=1; fi
    if test ${otg_force_device} = 1; then adb_en_l=1; fi
    if test ${adb_en_l} = 1; then setenv bootargs ${bootargs} androidboot.adb_enable=1; fi
    ```

    То есть `rabbit_hole_debug=1` → `rh_unlock=1` **и** принудительный ADB;
    `otg_force_device=1` включает ADB независимо. Режим SELinux тоже задаётся из env
    (`androidboot.selinux=${EnableSelinux}`). В заводском env `rabbit_hole_debug=0`,
    `lock=10001000`, `upgrade_step=2`. Сложность не в отсутствии механизма, а в записи в
    раздел `env` при подписанном загрузчике и ключах eFUSE — способ записи не найден.
- **Заводской сетевой режим:** `set_factory_env` переводит `bootcmd` в `factoryboot`,
  который поднимает DHCP и грузится по сети.
- Загрузчик — U-Boot `2015.01-g7ebc07b-dirty`, ожидаемая базовая версия
  `01.01.180822.145544` (`ro.build.expect.bootloader`). Раздел `bootloader` и оба
  аппаратных `mmcblk0boot0`/`boot1` побайтово идентичны (один SHA-256).
- Раздел `sysrecovery` (`p20`, 1.5 ГБ) содержит целиком заводской пакет **Amlogic USB
  Burning Tool** (`IMAGE_PACK_MAGIC = 0x27b51956`): `DDR.USB`, `UBOOT.USB`,
  `aml_sdc_burn.ini`, `*.PARTITION`. То есть восстановление через USB Burning Tool для
  этой платы подтверждено, а заводской образ извлекается прямо из устройства.

## ПО: YaOS / Яндекс ТВ { #software }

73 установленных пакета. Специфичное для Яндекса:

- **Голос/quasar:** `com.yandex.io.sdk`, `com.yandex.tv.alice`, `com.yandex.tv.services`,
  `com.yandex.tv.services.platform`, `com.yandex.tv.services.privileged`;
- **Медиа/ТВ:** `ru.kinopoisk.yandex.tv`, `com.yandex.tv.live`,
  `com.yandex.tv.input.efir`, `com.yandex.tv.videoplayer`, `com.yandex.tv.webplayer`,
  `com.yandex.tv.ytplayer`, `com.yandex.tv.music`, `com.yandex.devices.player`;
- **Оболочка и сервис:** `com.yandex.tv.home`, `com.yandex.tv.settings`,
  `com.yandex.tv.setupwizard`, `com.yandex.tv.keyboard`, `ru.yandex.androidkeyboard.tv`,
  `com.yandex.tv.daydream`, `com.yandex.tv.vendor.config`,
  `com.yandex.tv.bugreportsender`, `com.yandex.tv.remotechecker`,
  `ru.yandex.bleremotecontrol`, `com.yandex.devices.appstore`,
  `com.yandex.devices.payment`, `com.yandex.devices.farm.companion`,
  `com.yandex.launcher.updaterapp`, `com.yandex.server.SystemExtensionService`,
  `com.yandex.android.advid`, `com.yandex.prebuiltstub`.

Перехват клавиш задан в `/vendor/build.prop`: `yndx.intercept.tv.key=com.yandex.tv.home`,
`yndx.intercept.settings.key=com.yandex.tv.setupwizard`.

!!! note "Расхождение со страницей обычной Макс"
    На этом экземпляре (build `5000000896`) **нет** `com.yandex.browser.tv` и
    `ru.yandex.games`, которые перечислены на странице Макс. Зато есть
    `com.yandex.tv.ytplayer`, `com.yandex.devices.*` и `com.yandex.tv.daydream`. Список
    приложений стоит считать привязанным к конкретной сборке, а не к модели.

## Что ещё проверить { #todo }

- Точная модель EFR32 в роли Zigbee NCP (по маркировке на плате) и скорость `lp_uart`.
- Можно ли из userspace дёргать `zb-reset`/`zb-boot` и войти в Silabs-загрузчик NCP без
  root (SELinux-метка устройства — `zigbee_device`).
- Сверить карту разделов с живым `/dev/block/by-name/` из root-контекста (здесь она
  восстановлена из device-tree и по размерам).
- Протокол `gowin_led_device` между SoC и FPGA (SPI `spi32766.0` + собственный TTY).
- Назначение `atbm8881_fe` на колонке без антенного входа.
- Реально ли различаются `YNDX-00052` и `YNDX-0008` по данным EEPROM (`pcba_ids`).
- Возможность записи в раздел `env` — единственный найденный путь к `rabbit_hole_debug`.

---

*Данные сняты с одного экземпляра `YNDX-00052` на прошивке `5000000896`. Серийные номера,
`device-id` и MAC не публикуются, приватные ключи устройства — тоже.*
