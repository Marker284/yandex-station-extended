# Станция Лайт (Micro v1.2)

Розничное имя — **Яндекс Станция Лайт**; в device-tree — `Yandex Station Micro v1.2`
(`yandex,station-micro`). Данные ниже сняты с живого устройства (прошивка quasar 3.21,
`0.369.1.48…20261019`).

Общие для платформы вещи (доступ, прошивка, сеть) — в разделе
[Как это устроено](../internals/architecture.md). Здесь — только то, что специфично для
железа этой модели.

## Платформа в двух словах

| | |
|---|---|
| SoC | **Amlogic AXG (A113-семейство)**, `amlogic, axg` |
| CPU | 4× ARM Cortex-A53 (part `0xd03` r0p4), до **1.2 ГГц**, governor `interactive` |
| Частоты | 100 / 250 / 500 / 667 / 1000 / 1200 МГц |
| ОЗУ | **~244 МБ** LPDDR (MemTotal 243956 kB) |
| Флеш | **NAND** (не eMMC), UBI поверх MTD |
| Ядро | **Linux 4.9.68 aarch64** (64-бит), PREEMPT, Linaro GCC 6.3 |
| Userspace | **32-бит armhf**, glibc 2.30, `/lib/ld-linux-armhf.so.3`, Buildroot 2020.02.1 |
| TEE | **OP-TEE** (TrustZone), keymaster TA |
| Температура | один `soc_thermal`, idle ~42 °C, пассивное охлаждение |
| Звук | ALSA card0 `AML-AUGESOUND`, усилитель **NTP8910A** (I2C), микрофоны **PDM** |
| Радио | **Unisoc UWE5621** (Wi-Fi 2.4/5 + BT combo, SDIO) |
| Сеть | только Wi-Fi (`wlan0`) + Wi-Fi Direct (`p2p0`); Ethernet — через USB-хаб в [режиме USB Host](../recipes/usb-host.md) |

!!! note "Архитектурная особенность"
    Ядро **64-битное** (aarch64), а весь userspace — **32-битный armhf**. Свой софт
    удобнее собирать статикой под **aarch64/musl** — см.
    [Сборка софта](../internals/toolchain.md).

### Kernel cmdline

```
androidboot.serialno=... androidboot.deviceid=... androidboot.localization=RU.RU
androidboot.rpmb_state=0 androidboot.rh_unlock=0
ubi.mtd=system root=ubi0:rootfs rootfstype=ubifs ubi.mtd=bkupgrade
otg_device=1 no_console_suspend printk_no_block ramoops.pstore_en=1 ...
```

Важные флаги: `rh_unlock=0` (закрывает вход по UART, см.
[UART](../start/recovery.md#serial)), `otg_device=1` (Type-C в режиме device — host-режим
включается в рантайме, см. [USB Host](../recipes/usb-host.md)), `ramoops.*` (pstore для крэш-логов).

## Карта флеша (MTD / UBI)

```
mtd0  "bootloader"  2 MB     U-Boot / BL2+BL3x
mtd1  "tpl"         2 MB
mtd2  "boot"       10 MB     uImage + dtb
mtd3  "system"     80 MB  -> ubi0:rootfs  (ubifs, RO)
mtd4  "nv"          1 MB  -> /tee (jffs2, RO) — TEE/secure nv
mtd5  "bkupgrade" 105 MB  -> ubi1:bkupgrade (ubifs, RW) = /bkupgrade, сюда же /data
mtd6  "recovery"   50 MB     recovery-образ
```

DT-таблица логических разделов: `boot, cache, crypt, data, instaboot, logo, misc,
recovery, rsv, system, tee` (`instaboot` — snapshot/hibernation, `misc` — recovery-BCB,
`logo` — экран загрузки).

Файловые системы:

- `/` — ubifs **RO** (раздел `system`). dm-verity в ядре есть (`CONFIG_DM_VERITY=y`),
  но на rootfs **не применён** → `mount -o remount,rw /` работает (основа durable-правок,
  см. [Доступ](../start/ssh.md)).
- `/data` → симлинк на `/bkupgrade/data` (ubi1, RW, ~87 МБ, ubifs прозрачно жмёт) —
  сюда ставится свой софт (`/data/opt`).
- `/tmp`, `/run`, `/dev/shm` — tmpfs. `/tee` — jffs2 RO на разделе `nv`.

## Шина I2C и периферия

Две шины Meson I2C: `i2c-0` (`ffd1f000.i2c`, домен EE/cbus) и `i2c-1`
(`ff805000.i2c`, домен AO/aobus).

| Шина:адрес | Чип | Назначение | Статус |
|---|---|---|---|
| `0-0x12` | **AW96103** (aw9610x_sar) | ёмкостный SAR-сенсор (касание/приближение сверху) | ✓ |
| `0-0x37` | CY8CMBR3108 (CapSense) | touch-кнопки (другая ревизия) | ✗ probe −5 |
| `0-0x50` | 24C02 | EEPROM 2 кбит (заводские данные платы) | ✓ |
| `1-0x2a` | **NTP8910A** | Class-D усилитель (активный) | ✓ `TDM-B` |
| `1-0x2c` | TAS5825M | Class-D усилитель (другая ревизия) | ✗ нет pdn_gpio |
| `1-0x54` | SN3112 | LED-драйвер (другая ревизия) | ✗ нет чипа |
| `1-0x5b` | **AW9110** | LED/GPIO-экспандер (кольцо RGB) | ✓ |

!!! info "Про «failed probe» в dmesg"
    На этой ревизии платы живут AW96103, 24C02, NTP8910A и AW9110. Пары
    `cy8cmbr3108` / `tas5825m` / `sn3112` — заготовки под другую ревизию, не распаяны;
    ошибки probe в dmesg — норма.

Инструменты I2C есть прямо на борту (busybox): `i2cdetect`, `i2cget`, `i2cset`,
`i2cdump`, `i2ctransfer`.

!!! danger "Осторожно с записью в I2C"
    Запись в усилитель (`0x2a`) или SAR-сенсор (`0x12`) может сорвать работу Алисы.
    Делать осознанно и с бэкапом регистров (`i2cdump`).

## LED-кольцо

- `/sys/class/leds/micro:{red,green,blue}:ring{1,2,3}` — **3 RGB-зоны**, яркость
  0–255, пишется из userspace напрямую (sysfs, root).
- Прошивочный плеер анимаций: `/system/vendor/quasar/led_util` (симлинк на `maind`).
- Палитры-калибровки: `ledconfigs/*.json` — матрица 3×3 цветокоррекции
  (`{"type":"matrix","matrix":[[…],[…],[…]]}`).
- Анимации: `ledpatterns/*.led` (33 шт: `alice_listening`, `alice_speaking`, `timer`,
  `volume`, `bluetooth_*`, `call_*`, `error`, `iot_discovery`, `update_applying`, …).

### Формат `.led` (декодирован) { #led-format }

```
gammacorrection          # заголовок: применять гамма-коррекцию
loop                     # зациклить анимацию
RRGGBB  RRGGBB  RRGGBB   1000   # цвет ring1 ring2 ring3  +  длительность кадра (мс)
1D761D  1D761D  1D761D   1000
2D8624  2D8624  2D8624   1000
...
```

Три hex-цвета (по одному на зону кольца) и время удержания кадра в мс. Формат
тривиально пишется руками → можно делать свои анимации (см.
[Рецепты](../recipes/led.md)).

## Звуковой тракт

- ALSA card0 `AML-AUGESOUND`:
  - `device 0` — `TDM-B` → усилитель NTP8910A (playback **и** capture);
  - `device 1` — `PDM-dummy` capture (микрофонная PDM-матрица).
- `amixer`-контролы: `Master` (0–255), `SPK mute`, `PDM Gain` (0–48), **`Loopback`**
  (аппаратный AEC-reference: TDMIN/PDMIN → TDMOUT), EQ/HCIC, `SPDIFIN Sample Rate`.
- Железо фиксировано на **48000 Гц** (ресемпл делает pipeline).
- Утилиты: `aplay`, `arecord` (запись с микрофонов), `alsamixer`, `alsactl`.
- Громкость: `/system/vendor/quasar/set_volume.sh N` = `amixer set Master N%`.

## Прочее железо

- **GPIO**: `gpiochip0` (AO, 497–511), `gpiochip1` (EE, 411–496). Именованные:
  `pdn` (power-down усилителя), `sdio_wifi`, `bt_rfkill`, `aw9110_shdn`, `3V3 WLAN`.
- **ADC (SARADC)**: `iio:device0`, 8 каналов (`in_voltageN_raw`) — board-id резисторы,
  определение ревизии.
- **PWM**: `pwmchip0`. **RTC**, **`/dev/hwrng`** (аппаратный ГСЧ), **`/dev/watchdog`**.
- **Вход**: `event0` = `gpio-keys-filter` (физическая кнопка), `event1` = `sar0_pad0`
  (касание через SAR-сенсор).

## Получение root { #root }

- Основной способ — [DNS-метод](../start/root.md). Сброс у Лайт свой: сначала подать питание,
  потом сразу зажать кнопку паузы до жёлто-зелёной подсветки.
- На сборках после 21 октября 2026 года (`0.369.1.50…`) — [свой стенд](../start/root.md#local-stand)
  с откатом: сброс грузит factory-образ из `recovery` (`0.5.1.20…20230208.factory-4`), стенд
  ставит ему `0.369.1.46.4778262442.20261013.297`, и уже эта сборка включает ADB с root.
- Дальше — [SSH и отключение обновлений](../start/ssh.md).

## Что проверено именно на этой модели

- rootfs RW без verity → durable-правки переживают ребут.
- Отключение OTA тремя правками rootfs — работает после перезагрузки.
- Сетевой ADB поднимается по маркерам `/data/quasar/activate_adb_*` + `activate_network_adb`.
- `maind --gst-launch` играет через родной GStreamer.
- USB Host (OTG) через хаб с питанием: флешки/SSD, Ethernet RTL8153, USB-звук — [рецепт](../recipes/usb-host.md).

Подробности методов — в разделе [«Как это устроено»](../internals/architecture.md).
