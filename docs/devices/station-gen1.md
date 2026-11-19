# Станция (1-е поколение)

Розничное имя — **Яндекс Станция** (большая, первое поколение, 2018, модель **YNDX-0001**).
Это **другая аппаратная платформа**, не как у младших Станций: **Allwinner R18** + **Android 6.0.1**
(а не Amlogic + Buildroot). Полноценный медиацентр с **HDMI-выходом**.

!!! info "Приёмы для Amlogic не подходят к платформе Android"
    Станции делятся как минимум на два мира:

    - **Amlogic AXG + Buildroot + quasar/maind** — [Лайт](station-lite.md),
      [Мини 2](station-mini2.md), [Мини](station-mini.md);
    - **Allwinner + Android + quasar как APK** — эта модель (и другие ТВ-ориентированные).

    Многие приёмы из раздела [«Как это устроено»](../internals/architecture.md) (maind-демоны,
    `gst-launch`, init.d) к Android-платформе **не применимы** напрямую — там Android
    и APK. Общее — протокол **glagol** (`:1961`).

## Платформа в двух словах { #platform }

| Что | Значение |
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

## Что работает { #features }

| Что | Состояние | Где описано |
|---|---|---|
| Root и SSH | работает | [AliceBridge](../start/root-android.md#station-1) |
| Отключение обновлений | работает | [отключение обновлений](../recipes/station1-disable-updates.md) |
| ТВ-набор | работает | [ТВ-набор](../recipes/station1-tv.md) |
| USB Host (OTG) | не проверялось | — |
| AirPlay | не проверялось | — |
| Spotify Connect | не проверялось | — |
| Плеер как Bluetooth-источник | не проверялось | — |
| Свои звуки | не проверялось | — |
| Обработанный микрофон | не проверялось | — |
| Подсветка | не проверялось | — |
| YAM | не проверялось | — |
| Своя LLM | работает (свой мост по схеме llm-alice) | [своя LLM](../recipes/llm.md#llm-alice-station1) |

## Получение root { #root }

DNS-метод на Станции 1 не работает (Android-платформа). Постоянный root даёт
**[AliceBridge](../start/root-android.md#station-1)**: после подключения по ADB приложение сохраняет
резервную копию раздела `boot` на телефон, записывает подготовленный образ с root, сверяет
SHA-256 записанного раздела и перезагружает колонку. SSH после установки из приложения —
на порту **22**.

Сброс настроек колонки заводской `boot` **не возвращает** — для этого нужен заводской образ
(ссылка на странице AliceBridge).

## Доступ { #access }

- **ADB** — обычный Android adb (`:5555`); root — через [AliceBridge](#root) или
  по-андроидному (зависит от сборки, SELinux `permissive` помогает).
- **glagol** — тот же локальный API на `:1961` (WebSocket/TLS), как на всех Станциях.
- Энтузиасты ставят свои бинарники в `/data/local/bin` (Android-путь) — например,
  `zsh`, `fastfetch`; можно поднять свой dropbear-SSH.

### Вход по SSH-ключу в Dropbear от AliceBridge { #ssh-key }

**Проверено на:** Станция 1, Android 6.0.1 (`MOB30J`), quasar 2.369.5.46, Dropbear 2022.82
из AliceBridge (`/data/dropbear/start.sh`, порт 22), ноябрь 2026.

Dropbear из AliceBridge собран с musl и берёт домашний каталог root из `/etc/passwd`, а там
он равен `/data`. Каталог `/data` принадлежит `system` и доступен на запись группе, поэтому
Dropbear отклоняет ключ из `/data/.ssh/authorized_keys` и пускает только по паролю.
Bionic `/etc/passwd` не читает, поэтому подмена файла затрагивает только Dropbear.

1. Создайте отдельный домашний каталог с ключом:

    ```sh
    mkdir -p /data/root/.ssh && chmod 700 /data/root /data/root/.ssh
    cat > /data/root/.ssh/authorized_keys   # вставьте публичный ключ, затем Ctrl+D
    chmod 600 /data/root/.ssh/authorized_keys
    ```

2. Сделайте копию `passwd`, в которой у root домашний каталог `/data/root`:

    ```sh
    sed 's#^\(root:[^:]*:0:0:[^:]*:\)[^:]*#\1/data/root#' /system/etc/passwd \
      > /data/dropbear/passwd.home && chmod 644 /data/dropbear/passwd.home
    ```

3. В `/data/dropbear/start.sh` **до** строки запуска Dropbear добавьте подмену:

    ```sh
    /sbin/busybox grep -q "^root:[^:]*:0:0:[^:]*:/data/root:" /etc/passwd || \
      { [ -f /data/dropbear/passwd.home ] && \
        /sbin/busybox mount -o bind /data/dropbear/passwd.home /system/etc/passwd; }
    ```

4. Перезагрузите колонку и проверьте вход по ключу. Пароль остаётся запасным входом.

Откат: удалите строки из `start.sh` и перезагрузите колонку. Переустановка SSH из приложения
AliceBridge перезаписывает `start.sh`, после неё строки нужно добавить снова.

### Android-команды по SSH { #android-env }

В SSH-сессии нет переменных окружения Android (`BOOTCLASSPATH`, `ANDROID_ROOT` и других),
поэтому `am`, `pm`, `input` и `wm` падают с кодом 134. Переменные можно взять у системного
процесса `netd`:

```sh
for kv in $(/sbin/busybox tr "\000" "\n" < /proc/$(/sbin/busybox pidof netd)/environ |
  /sbin/busybox grep -E "^(ANDROID_[A-Z_]*|BOOTCLASSPATH|SYSTEMSERVERCLASSPATH|EXTERNAL_STORAGE|ASEC_MOUNTPOINT)="); do
  export "$kv"
done
```

После этого работают `am start`, `input keyevent`, `pm list packages` и `screencap`
(в том числе без HDMI).

### Открытые порты { #ports }

Снято на той же колонке после AliceBridge (`netstat -ltnp`):

| Порт | Кто слушает | Замечание |
|---|---|---|
| `0.0.0.0:22` | Dropbear из AliceBridge | вход root по паролю или ключу |
| `0.0.0.0:5555` | `adbd` | ADB доступен из всей локальной сети, AliceBridge проверяет его состояние |
| `:::1961` | `maind` | [glagol](../internals/network.md#glagol) |
| `0.0.0.0:5081` | `maind` | [звонки Алисы (SIP)](../internals/calls.md) |
| `127.0.0.1:98xx`, `11124` | службы quasar | локальный IPC, например `aliced` на `9875` (порт берётся из `quasar.cfg`) |

!!! warning "ADB открыт для всей сети"
    Если ADB после настройки SSH не нужен, учитывайте, что любой узел в вашей сети видит
    порт 5555. Требует ли `adbd` подтверждения ключа на этой сборке, не проверялось.

### Экран без HDMI { #screen }

**Проверено на:** та же колонка, HDMI не подключён.

- `screencap -p` работает и без монитора, но кадр 1920×1080 в PNG занимает около 2 с.
- Быстрее — скрытый API `android.view.SurfaceControl.screenshot(int, int)` из программы,
  запущенной от root через `app_process`: кадр 960×540 получается за ~25 мс, сжатие в JPEG
  (`Bitmap.compress`) — ещё ~50 мс, то есть 6–10 кадров в секунду.
- Ввод через `InputManager.injectInputEvent` (тапы, свайпы, клавиши, текст латиницей через
  `KeyCharacterMap`) работает в обычных Android-приложениях, например в браузере.
- Экран Алисы (`ru.yandex.quasar.app`, он же домашний экран) на касания, D-pad и `Home` не
  реагирует — ни на внедрённые события, ни на `input` из оболочки. Срабатывает только `Back`,
  и то для приложений поверх него. Команда glagol `{"command":"control","action":"go_right"}`
  возвращает `SUCCESS`, но экран не меняется. Управлять экраном Алисы можно только фразами
  — командой `sendText` через [glagol](../internals/network.md#glagol).
- Приложения запускаются поверх Алисы через `am start -n <пакет>/<активность>`, вернуть её экран
  можно через `am start -a android.intent.action.MAIN -c android.intent.category.HOME`.

## Чем отличается { #differences }

- **SoC Allwinner R18** (ARM+Android), а не Amlogic+Buildroot. Соответственно — всё
  дерево `sunxi_*` драйверов (`sunxi_daudio`, `sunxi_sndhdmi`, `sunxi-ths` и т.д.).
- **Полный Android 6** со своим init, SELinux, `/system/priv-app`, и **quasar — это
  APK** (`ru.yandex.quasar.app`, `/system/priv-app/Quasar-Webmusic`), а не нативный
  `maind`-стек (хотя нативные роли `--platformd/--mediad` тоже присутствуют).
- **HDMI-выход** и звук по HDMI (`sndhdmi`) — модель задумана как ТВ-приставка-колонка.
- **Звук 2.1** на двух усилителях **TAS5751M**: `1-0x2a` — сабвуфер, `1-0x2b` — пищалки.
- **dm-verity включён** (`verity_block`) — раздел `system` подписан; durable-правки системного
  раздела сложнее, чем на Buildroot-моделях без verity.

## Разделы флеша { #partitions }

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

## Шина I2C и периферия { #i2c }

| Шина:адрес | Чип | Назначение |
|---|---|---|
| `1-0x2a` | **TAS5751M** | усилитель сабвуфера (моно, PBTL) |
| `1-0x2b` | **TAS5751M** | усилитель пищалок (стерео, BTL) |
| `1-0x18`…`1-0x1b` | **TLV320ADC3101** ×4 | 7 микрофонов и 1 опорный канал |
| `0-0x18` | **TLV320ADC3101** | 2 опорных канала (выходы усилителей) |

## Звук { #audio }

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

## Загрузка и прошивка платформы { #boot-firmware }

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

!!! warning "Выключение и сброс через PSCI требуют отключения от розетки"
    - **Выключение** (`poweroff`, PSCI `SYSTEM_OFF`), судя по разбору прошивки SCP, полностью
      снимает питание (запись `0x80` в регистр `0x32` AXP803): батареи нет, и Станция включится
      только после переподключения в розетку.
    - Перезагрузка через **PSCI `SYSTEM_RESET`** может подвесить плату до отключения питания.
      Надёжно перезагружает только **сторожевой таймер SoC**.
    - Не трогайте boot0, U-Boot, `env` и раздел `boot`: без них Станция не загрузится.

## Свой Linux { #linux }

На Станции 1 работает mainline-ядро **Linux 7.3** (DVFS, Wi-Fi, Bluetooth, оба усилителя,
микрофоны, кольцо, кнопки) и чистый **Debian 13**: ставится одной командой из Android, рядом
с Алисой или вместо неё, удаление возвращает сток —
[Debian на Станции 1](../recipes/station1-debian.md). Исходники ядра и патчей —
[MyszkinPL/yandex-station-linux](https://github.com/MyszkinPL/yandex-station-linux).

## Что ещё проверить { #todo }

- Влияние SELinux-политики на root из AliceBridge.
- Требует ли `adbd` на `:5555` подтверждения ключа после AliceBridge.
- Формат прошивки Allwinner (Tina/`tinaos`) и разделы `lback`/`rboot`/`media_data`.
