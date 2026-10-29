# Станция Мини 2

Розничное имя — **Яндекс Станция Мини 2**; device-tree — `Yandex Station Mini 2`
(`yandex,station-mini2`, `amlogic, axg`). Та же платформа, что и у
[Станции Лайт](station-lite.md) (Amlogic AXG + Buildroot + quasar), но богаче по
периферии: отдельный ЦАП, кольцо из 6 RGB-зон, LED-часы, датчик освещённости,
RTC и выход на наушники.

Общие механизмы (доступ, прошивка, сеть) — в разделе
[Как это устроено](../internals/architecture.md).

## Платформа в двух словах { #platform }

| Что | Значение |
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
| quasar | 3.21 (`0.369.1.25…20260928`, `0.369.1.46…20261013`); стоковая на 26.10.2026 — `0.372.1.13…20261021` (свой сервер не принимает) |
| factory-образ | `0.17.1.32.1145264292.20211203.factory-3` (после сброса) |
| Температура | `soc_thermal` ~42 °C в простое |

## Что работает { #features }

| Что | Состояние | Где описано |
|---|---|---|
| Root и SSH | работает | [подмена DNS](../start/root.md) |
| USB Host (OTG) | не проверялось | — |
| AirPlay | не проверялось | — |
| Spotify Connect | не проверялось | — |
| Плеер как Bluetooth-источник | не проверялось | — |
| Свои звуки | не проверялось | — |
| Обработанный микрофон | не проверялось | — |
| Подсветка | работает | [Подсветка](../recipes/led.md) |
| YAM | работает | [профиль mini2](../recipes/packagemanagers.md) |
| Своя LLM | не проверялось | — |

## Получение root { #root }

Основной способ — **[подмена DNS](../start/root.md)**: сброс колонки, свой DNS на роутере,
дальше сетевой ADB. На Мини 2 проверен. После него — [SSH и отключение
обновлений](../start/ssh.md).

Запасной путь без компьютера — [AliceBridge](../start/root-android.md) с Android-телефона;
полный проход на этой модели пока не проверяли.

На сборках после 21 октября 2026 года — через
[свой сервер обновлений](../start/root.md#local-stand):

- стоковая `0.372.1.13.4794674157.20261021.302` не доверяет сертификату сервера (TLS-алерт
  `unknown_ca`); сброс до factory `0.17.1.32…`, затем откат на
  `0.369.1.46.4778262943.20261013.299`;
- OTA-файл Мини 2 — архив **cpio newc** (начинается с `070702`), а не zip, хотя по ссылке
  называется `.zip`. `crc32` совпадает с `metadata.json`, в конце нули;
- после возврата обычного DNS Quasar выключает ADB при синхронизации с облаком
  (`Deactivate adb by quasmodrom config`), SSH остаётся — см.
  [шаг 7](../start/root.md#restore-dns).

## Чем отличается { #differences }

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

## Разделы флеша { #partitions }

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

## Шина I2C и периферия { #i2c }

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

## Индикация { #led }

- **Кольцо, 6 RGB-зон**: `/sys/class/leds/mini2:{red,green,blue}:ring{1..6}` (18 каналов).
- **LED-часы**: `/sys/class/leds/mini2:white:clock*` — сегменты `clockA1`…`clockG4`, `clockDEGREE`,
  `clockMINUS`, `clockPLUS1`…`clockPLUS4`.
- Framebuffer нет (`/dev/fb*` отсутствует), у всех светодиодов `trigger` = `none`: прошивка
  сама пишет `brightness` в sysfs. Понять, что кольцо занято Алисой, можно только по значениям
  `brightness`; способ «смотреть на кадр прошивки в `/dev/fb0`», как на Станции 2 и Мини 3,
  здесь не работает.
- Заглушить родные часы можно bind-mount своих файлов поверх `.../clock*/brightness`. Без `-t`
  BusyBox `mount` (1.31.1) принимает двоеточие в пути источника за NFS-адрес
  (`mount: bad address '/tmp/x/mini2'`), поэтому указывайте тип:
  `mount -t none --bind <файл> <цель>`.
- Всё пишется из userspace напрямую (sysfs, root). Готовый скрипт для кольца —
  [`contrib/install-rgb-alice-mini2.sh`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/install-rgb-alice-mini2.sh).
- Формат анимаций прошивки — `.led` (как на Лайте, но 6 зон вместо 3): см.
  [формат `.led`](station-lite.md#led-format). Количество hex-колонок в кадре
  соответствует числу зон — **нужно проверить** на этой модели.

## Звук { #audio }

- ALSA card0 `AML-AUGESOUND`: `TDM-B-sy6045s-hifi` (playback+capture),
  `PDM-dummy` (микрофоны).
- Тракт: `TDM-B` → ЦАП **ES8156** → усилитель **SY6045S**.
- Есть выход на наушники (отдельный input `AML-AUGESOUND Headphones`).

## Вход { #input }

- `sar0_pad0` (`/dev/input/event0`) — касание через SAR-сенсор AW96103. Коды клавиш:
  `KEY_VOLUMEDOWN` 114, `KEY_VOLUMEUP` 115, `KEY_VOICECOMMAND` 582 (активация Алисы). Прошивка
  читает это устройство, поэтому записанные в него события `input_event` она обрабатывает как
  нажатия.
- `AML-AUGESOUND Headphones` — детектор подключения наушников.
- Отдельного `gpio-keys` нет (на Лайте — `gpio-keys-filter`).

## Окружение { #environment }

- В разделе `tee` лежат данные защищённой среды OP-TEE (Keymaster). UUID доверенного
  приложения Keymaster одинаков у всех экземпляров модели, а `AmlKeymasterMasterKey` — не ключ
  устройства, а фиксированная строка-константа Amlogic (её hex `416D6C4B…` расшифровывается в
  ASCII `AmlKeymasterMasterKey`), с которой выводится мастер-ключ. Самого ключа в открытом виде
  в разделе нет.
- **Сборка под это ядро.** Linux 4.9.68 не знает `clock_gettime64` (syscall 403, появился в 5.1).
  Бинарник из современного тулчейна при каждом вызове таймера сначала стучится в 403, получает
  `-ENOSYS` и откатывается на 32-битный вызов — libc это умеет. Но ядро колонки (модификация,
  в ванильном такого нет) на каждый неизвестный syscall пишет в `dmesg` полный дамп регистров
  из `do_ni_syscall`, забивая кольцевой буфер и тратя процессор. В логе это выглядит так:

    ```text
    dropbear[7253]: syscall 403
    CPU: 3 PID: 7253 Comm: dropbear Tainted: G           O    4.9.68 #1
    Hardware name: Yandex Station Mini 2 (DT)
    …дальше полный дамп регистров x0–x30…
    ```

    Собирайте под целевое ядро (SDK 4.9) или статически, иначе лог засоряется на каждый таймер.
- iptables `1.8.3 (legacy)` без модуля `multiport` (`Couldn't load match 'multiport'`) и без
  `LOG` (`unknown option "--log-prefix"`). Правила для нескольких портов пишите по одному на
  порт, для отладки считайте пакеты правилами со счётчиком (`-m comment`).
- Порты `maind --platformd`: `tcp 1961` (glagol), `tcp/udp 7447` (Zenoh), `tcp 5081` (SIP для
  звонков) — как на Лайт, см. [Сеть](../internals/network.md).

## Что ещё проверить { #todo }

- Точный формат `.led` для 6 зон.
- Отключение OTA по общей схеме ([шаг 2](../start/ssh.md#kill-ota)) работает: после
  `yandex-noupdate.sh` `updatesd` не запускается, `0.369.1.46…299` держится после перезагрузок.
- Карту регистров ES8156 / SY6045S через `i2cdump` (аккуратно).
