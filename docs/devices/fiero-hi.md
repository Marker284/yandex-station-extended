# Fiero Hi (партнёрская Станция Лайт / Micro)

Розничная колонка с Алисой под маркой **Fiero** (собственный бренд сети DNS), сертификатная
модель **`FDNS-00024`**. Внутри — это
**[Станция Лайт](station-lite.md)** поколения *Micro v1.2*: тот же SoC, та же прошивка quasar,
те же приёмы доступа. Отличается только розничный бренд и строка платформы в облаке —
**`blackthorn`**.

Данные ниже сняты с живого устройства (прошивка `0.369.1.50…20261021`, factory-образ
`0.5.1.3…factory-5`). Общее для платформы — в разделе
[Как это устроено](../internals/architecture.md); здесь — специфика модели. Железо совпадает со
[Станцией Лайт](station-lite.md), поэтому её страница — основной справочник, а здесь только то,
что отличается или подтверждено на этом экземпляре.

## Платформа в двух словах { #platform }

| Что | Значение |
|---|---|
| Розничное имя | Fiero Hi (DNS), модель `FDNS-00024` |
| Платформа в облаке (`platform=`) | `blackthorn` |
| Device-tree model | `Yandex Station Micro v1.2` (`yandex,station-micro`, `amlogic, axg`) |
| SoC | **Amlogic AXG (A113-семейство)**, ревизия кремния RevB |
| CPU | 4× ARM Cortex-A53 (part `0xd03`), до **1.2 ГГц** |
| ОЗУ | **~244 МБ** (MemTotal 243956 kB) |
| Флеш | **NAND 256 МБ**, Toshiba `TC58NVG1S3HBAI4` (SLC, страница 2048, OOB 128, стирание 128 КиБ), UBI поверх MTD |
| Ядро | **Linux 4.9.68 aarch64**, Buildroot |
| TEE | **OP-TEE** (TrustZone); раздел `nv` смонтирован в `/tee` (jffs2) |
| Звук | ALSA card0 `AML-AUGESOUND`, усилитель **NTP8910A** (I2C, TDM-B), микрофоны **PDM** |
| Радио | **Unisoc UWE5621** (Wi-Fi + BT combo, SDIO; драйверы `aml_sdio`/`vlsicomm`/`sdio_bt`) |
| Сеть | только Wi-Fi (`wlan0`) + Wi-Fi Direct (`p2p0`) |
| Сервисные интерфейсы | UART-консоль `ttyS0` (base_baud 1500000), USB2 **OTG** (`otg_device=1`) |

### Kernel cmdline { #cmdline }

```text
androidboot.serialno=<REDACTED> androidboot.deviceid=<REDACTED> androidboot.localization=RU.RU
androidboot.rpmb_state=0 androidboot.rh_unlock=0
ubi.mtd=system root=ubi0:rootfs rootfstype=ubifs ubi.mtd=bkupgrade
otg_device=1 no_console_suspend printk_no_block ramoops.pstore_en=1 ...
```

Штатная загрузка — `root=ubi0:rootfs` из `system`. Заводской сброс кнопкой грузит `recovery`
с `rootfstype=ramfs` (корень в ОЗУ) — именно этот образ проходит `register → get_sync_info`.

## Что работает { #features }

| Что | Состояние | Где описано |
|---|---|---|
| Root и SSH | работает | [подмена DNS](#root) |
| Подсветка (кольцо RGB) | работает | [Подсветка Лайт](../recipes/led.md#lite-led) |
| Свои звуки | работает | [озвучивание текста](../recipes/sounds.md#native-tts) |

## Получение root { #root }

Способ — как у [Станции Лайт](station-lite.md#root): [DNS-метод](../start/root.md). Нюанс именно
этого экземпляра (сборка `.50`):

- **Обычная прошивка `get_sync_info` не запрашивает** — через неё ADB не включить.
- Нужен **полный аппаратный сброс кнопкой** (отключить питание → зажать «Воспроизведение/Пауза»
  → подать питание, держать до жёлто-зелёной подсветки). Он грузит заводской образ `factory-5`,
  а тот проходит `POST /register → GET /get_sync_info`, и в ответ (локальным сервером eQuasar или
  [своим сервером обновлений](../start/root.md#local-stand)) включается `adbd` на `:5555` с root.
- При настройке облачные адреса Алисы (`rpc.alice.yandex.net`, `uniproxy.alice.yandex.net`)
  стоит временно завернуть на свой сервер/в чёрную дыру, иначе колонка завершает настройку через
  облако и до `get_sync_info` не доходит.

Проверка: `adb connect <IP>:5555` → `adb shell id` → `uid=0(root)`.

Дальше — [SSH и отключение обновлений](../start/ssh.md). Закрепление проверено на этом
экземпляре: маркеры `/data/quasar/activate_adb_quasmodrom` + `activate_network_adb` с `chattr +i`
держат ADB после возврата DNS и перезагрузки; SSH (Dropbear, `:2222`) ставится как у Лайт.

!!! warning "Пиннинг голосового канала"
    Провиженинг (`quasar.yandex.net`) проверяет сертификат только по CA — подменяется. А
    `rpc.alice`/`uniproxy` используют **пиннинг**: подменный сертификат (даже валидный по CA)
    колонка отвергает на TLS-рукопожатии. Перехватить голосовой канал этим способом нельзя.

## Разделы флеша { #partitions }

```text
mtd0  "bootloader"  2 MB     U-Boot / BL2+BL3x (через MTD читается частично — особенность Amlogic)
mtd1  "tpl"         2 MB
mtd2  "boot"       10 MB     Android boot image (ANDROID!), ramdisk пустой
mtd3  "system"     80 MB  -> ubi0:rootfs (ubifs, RO)
mtd4  "nv"          1 MB  -> /tee (jffs2, RO) — TEE secure nv
mtd5  "bkupgrade" 105 MB  -> ubi1 (ubifs, RW) = /bkupgrade, сюда же /data
mtd6  "recovery"   50 MB     заводской образ (ANDROID! + зашифрованный ramdisk ~23 МБ)
```

`/` — ubifs RO без применённого dm-verity → `mount -o remount,rw /` переживает перезагрузку.
`/data` → симлинк на `/bkupgrade/data` (ubi1, RW), свой софт — в `/data/opt`.

## Шина I2C и периферия { #i2c }

Две шины Meson I2C. В последнем столбце — статус на этом экземпляре (по `sysfs` и `dmesg`):

| Шина:адрес | Чип | Назначение | Статус |
|---|---|---|---|
| `0-0x12` | **AW9610x** (`aw9610x_sar`) | ёмкостный SAR-сенсор (касание/приближение) | ✓ |
| `0-0x37` | CY8CMBR3108 (CapSense) | touch-кнопки (другая ревизия) | ✗ probe −5 |
| `0-0x50` | 24C02 | EEPROM 2 кбит (заводские данные платы) | ✓ |
| `1-0x2a` | **NTP8910A** | Class-D усилитель (активный) | ✓ `TDM-B` |
| `1-0x2c` | TAS5825M | Class-D усилитель (другая ревизия) | не используется: в ALSA — NTP8910A |
| `1-0x54` | SN3112 | LED-драйвер (другая ревизия) | ✗ probe −5 |
| `1-0x5b` | **AW9110(B)** | LED/GPIO-экспандер (кольцо RGB) | ✓ |

Набор живых чипов совпадает со [Станцией Лайт](station-lite.md#i2c): AW9610x, 24C02, NTP8910A и
AW9110. `cy8cmbr3108` и `sn3112` не отвечают по I2C — ошибки probe в `dmesg` для них норма.

## Индикация { #led }

`/sys/class/leds/micro:{red,green,blue}:ring{1,2,3}` — **3 RGB-зоны** (кольцо), драйвер
**AW9110** на `1-0x5b`. Формат анимаций `.led` и калибровки — как у
[Станции Лайт](station-lite.md#led) и в [рецепте подсветки](../recipes/led.md).

## Звук { #audio }

- ALSA card0 `AML-AUGESOUND`: `device 0` — `TDM-B` → NTP8910A (playback+capture), `device 1` —
  `PDM-dummy` capture (матрица из **4 микрофонов**).
- `asound.conf`: `softvol` «Master Playback Volume» → `dmix`, запись через `multi_capture`.
- Громкость: `/system/vendor/quasar/set_volume.sh N`. Детали — на
  [странице Лайт](station-lite.md#audio).

## Сервисные интерфейсы { #interfaces }

- **UART-консоль** `ttyS0` (`ff803000`, base_baud 1500000). `console=ttyS0,115200` задан только
  в cmdline заводского образа (`recovery`); в штатной cmdline консоли нет.
- **USB2 OTG** (`otg_device=1`), USB3 нет. **Wi-Fi/BT** — Unisoc UWE5621 по SDIO (MAC Wi-Fi в
  eFuse). **OP-TEE** (`optee`, `optee_armtz`).

## Открытые порты { #ports }

На штатно работающей колонке открыты **`1961`** (glagol, TLS, сертификат Yandex) и
**`5081`** — [звонки Алисы](../internals/calls.md): взаимный TLS, пускает только по внутреннему
сертификату прошивки. ADB на `5555` появляется после активации.

## Что проверено именно на этой модели { #tested }

- Внутри — Станция Лайт Micro v1.2 (Amlogic AXG), прошивка quasar.
- Root получен DNS-методом **через заводской образ** (обычная `.50` не шлёт `get_sync_info`).
- ADB по маркерам `/data/quasar/activate_adb_*` + SSH (Dropbear `:2222`) переживают перезагрузку;
  блокировка OTA — тремя правками rootfs, как у Лайт.
- Сняты сырые дампы всех MTD; `system`/`boot`/`recovery` — полные, ramdisk `recovery` зашифрован.
  SHA-256 на устройстве и на ПК совпали для всех разделов, кроме `bkupgrade`: он смонтирован на
  запись и меняется во время снятия. `bootloader` через MTD читается частично — сверены первые
  128 КиБ.
- Полный вывод с устройства (модель, MTD, UBI, I2C, звук, LED, модули, `dmesg`) —
  [`contrib/dumps/fiero-hi-recon.txt`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/dumps/fiero-hi-recon.txt).

Подробности методов — в разделе [«Как это устроено»](../internals/architecture.md), железо —
на странице [Станции Лайт](station-lite.md).
