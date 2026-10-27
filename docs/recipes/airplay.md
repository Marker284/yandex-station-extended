# AirPlay (Shairport Sync)

Станция как приёмник **AirPlay 2** для iPhone, iPad и Mac. Скрипт
[`contrib/yandex-station-airplay-fix.sh`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/yandex-station-airplay-fix.sh)
чинит две известные проблемы уже установленного пакета AirPlay.

!!! info "Проверено на Станции Мини 3"
    `shairport-sync 4.3.7` (AirPlay 2) + `nqptp 1.2.4`. На других моделях пути те же,
    а патч `airplayd` применяется, только если байты в нужном месте совпадают.

!!! tip "Приёмник пропадает с телефона через несколько минут"
    Частая причина — IGMP snooping на роутере без querier: колонка перестаёт получать mDNS.
    Признаки и решение — в [Подводных камнях](../internals/gotchas.md#igmp).

## Что нужно заранее

- root по ADB ([шаг 1](../start/root.md));
- установленный пакет AirPlay в `/data/shairport` (`airplay.sh`, `airplayd`, `ap2/shairport-sync-ap2`).

!!! note "Откуда взять пакет `/data/shairport`"
    Инструкции по установке самого пакета в вики пока нет. Если знаете источник —
    [дополните страницу](../contributing.md). Другой путь — своя сборка shairport-sync без
    `/data/shairport`, см. [Станция Лайт 2](#lite2).

## Установка фикса

С компьютера:

```sh
./contrib/yandex-station-airplay-fix.sh 192.168.1.50:5555
```

| Флаг | Что делает |
|---|---|
| `--status` | только показать состояние |
| `--with-autostart` | автозапуск через `/etc/init.d/S99zairplay` |
| `--no-patch` | не патчить `airplayd`, поставить только хуки |
| `--uninstall` | убрать хуки, вернуть оригинальный `airplayd` |
| `--force` | патчить даже при несовпадении байтов (опасно) |

После переустановки пакета AirPlay (`airplay.sh setup`) запустите скрипт ещё раз —
конфиг пересоздаётся без хуков.

## Использование

На iPhone/Mac в той же Wi-Fi-сети: «Пункт управления» → AirPlay → выберите колонку.

Пока играет AirPlay, **Алиса выключена**. После паузы или остановки она возвращается
примерно через 2 секунды. Play надёжнее нажимать с телефона: после возврата Алисы
кнопку на колонке могут поймать оба демона.

---

## Что чинит скрипт

1. **AirPlay подключается, но звука нет** (или он появляется только после смены трека).
   `airplayd` зависает в функции часов (`time()`/`localtime_r`) и перестаёт читать
   `/tmp/sps.fifo`, а `shairport-sync` блокируется на записи. Скрипт патчит 4 байта по
   смещению 7344 и убирает этот вызов. Побочный эффект: может перестать обновляться время
   на дисплее (если важно — `--no-patch`).
2. **Пауза запускает Яндекс.Музыку.** `/dev/input/event1` читают и `airplayd`, и
   `maind --platformd`. Скрипт ставит хуки `shairport-sync`: на старте воспроизведения
   quasar (Алиса) останавливается, на паузе/остановке — запускается снова.

---

## Станция Лайт 2: AirPlay 2 как Bluetooth-источник Алисы { #lite2 }

!!! info "Проверено на Станции Лайт 2 (plum), прошивка 0.369.1.50"
    shairport-sync 5.6.2 (своя сборка: AirPlay 2, MPRIS, soxr) + nqptp 1.2.9 + avahi 0.8
    из Entware + [bt-proxy](bt-proxy.md). iPhone, iPad и Mac, вместе с настоящим
    Bluetooth-телефоном; автозапуск — перезагрузкой. На других моделях не проверялось.

Пакет `/data/shairport` не нужен, Алиса не выключается. Через [bt-proxy](bt-proxy.md) она видит
AirPlay как подключённый Bluetooth-телефон «AirPlay» и управляет им штатно: сама останавливает
свою музыку, когда заиграл AirPlay, и ставит AirPlay на паузу, когда включает своё; «дальше»,
«пауза», «продолжи», «тише» уходят в AirPlay. Звук AirPlay идёт через штатную цепочку Алисы
(`default` → `Master` → dmix 48 кГц), так что её ответы звучат поверх музыки.

### Установка

Нужны root по SSH и [`yse`](../start/packages.md). С компьютера, одной командой:

```sh
curl -fsSL https://raw.githubusercontent.com/Marker284/yandex-station-extended/main/contrib/airplay-lite2/install.sh | sh -s -- <IP колонки> --reboot
```

[`install.sh`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/airplay-lite2/install.sh)
ставит avahi из Entware, [bt-proxy](bt-proxy.md), готовую сборку shairport-sync + nqptp
([`contrib/packages/airplay-lite2-armhf.tar.gz`](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/packages/airplay-lite2-armhf.tar.gz)),
конфиги и автозапуск, отключает D-Bus-активацию `org.bluez`. `airplay_device_id` (MAC `wlan0`) и
имя хоста для avahi (`YandexLite-gen2-<deviceid>`) вычисляет на колонке; имя можно задать
явно: `AP_HOSTNAME=… sh install.sh …`. Откат — `sh install.sh <IP> --uninstall --reboot`.

??? note "Собрать и поставить вручную"
    1. Соберите shairport-sync и nqptp в Docker —
       [`contrib/airplay-lite2/Dockerfile`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/airplay-lite2/Dockerfile).
       Кросс-сборка под armhf в Debian buster: glibc 2.28 не новее системной (2.30), поэтому
       бинарники работают на штатной libc и штатной `libasound`; ffmpeg (только AAC/ALAC) и
       libplist — статически, ещё 9 библиотек — в `lib/` рядом (2,4 МБ вместе с бинарниками).
       Готовый архив собран им же:

        ```sh
        cd contrib/airplay-lite2
        docker build -t lite2-ap2 .
        docker run --rm lite2-ap2 tar -C /out -cf - bin lib | \
          ssh -p 2222 root@<IP колонки> 'mkdir -p /data/opt/airplay && tar -C /data/opt/airplay -xf -'
        ```

    2. [bt-proxy](bt-proxy.md#install) и `yse install avahi-dbus-daemon`.
    3. `shairport-sync.conf` и `asoundrc` (как `.asoundrc`) из
       [`contrib/airplay-lite2/`](https://github.com/Marker284/yandex-station-extended/tree/main/contrib/airplay-lite2)
       — в `/data/opt/airplay/`; в `shairport-sync.conf` — `airplay_device_id`, MAC `wlan0` без
       двоеточий.
    4. `/opt/etc/avahi/avahi-daemon.conf` — имя хоста, которое объявляет `maind`
       ([почему](../internals/gotchas.md#avahi)):

        ```ini
        [server]
        host-name=YandexLite-gen2-XXXXXXXX
        allow-interfaces=wlan0
        use-ipv6=no

        [publish]
        publish-addresses=no
        publish-hinfo=no
        publish-workstation=no
        ```

    5. Автозапуск — [`S99zairplay-lite2`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/airplay-lite2/S99zairplay-lite2)
       в `/etc/init.d/` (rootfs: `mount -o remount,rw /` … `mount -o remount,ro /`).

Проверка с мака: `dns-sd -B _airplay._tcp` показывает колонку, `cat /tmp/bt-proxy.log` на
колонке — `плеер org.mpris.MediaPlayer2.ShairportSync (AirPlay)`.

### Грабли { #lite2-gotchas }

- **Звук икает дважды в секунду.** В логе (`shairport-sync -v --statistics`) раз в ~0,5 с
  `Large negative (i.e. early) sync error of -2300 frames (-0.052 seconds)`. Карта `hw:0`
  фактически играет только 48 кГц и молча принимает 44100: поток идёт на ~9% быстрее, ошибка
  набегает до порога resync (0,05 с), и shairport перескакивает.
  `audio_backend_latency_offset_in_seconds` не помогает — это дрейф, а не задержка. Лечится
  `output_rate = 48000` (shairport 5.x) или выводом через dmix на 48 кГц.
- **`deviceid=00:00:00:00:00:00` в анонсе.** `interface = "wlan0"` MAC не даёт — нужен явный
  `airplay_device_id`.
- **MPRIS всегда `Stopped`.** Статус и трек MPRIS берёт из потока метаданных:
  `metadata = { enabled = "yes"; }` обязателен, иначе Алиса не узнает, что AirPlay играет.
- **`-d` и `-j` молча выходят.** Сборка без libdaemon не демонизируется. При загрузке shairport
  иногда выходит, поднявшись раньше окружения, поэтому `S99zairplay-lite2` держит его в цикле
  перезапуска, вывод — в `/tmp/shairport.log`.
- **shairport из Entware на Лайт 2 не подходит для общего звука.** Он 64-битный со своей
  alsa-lib 1.2.11: читает `/opt/etc/asound.conf`, а не штатный `/etc/asound.conf`, и не делит
  dmix с системной 1.2.1.2 (`unable to create IPC shm instance`). Подложить ему системную
  `libasound` нельзя — ей нужна `GLIBC_2.29`, у Entware 2.27.

### Ограничения

- Что источник исполняет «дальше» и «назад», зависит от него: команды уходят в shairport по
  MPRIS, а оттуда по каналу событий AirPlay 2.
- Громкость с iPhone и Алисы проверялась командами «тише»; двигает ли Алиса ползунок на
  iPhone, не проверялось.
- Есть YAM-плагин [Station-airplay](https://github.com/Yandex-Station-Universal-Repo/Station-airplay)
  с часами и подсветкой, но на Лайт 2 он работает в режиме «только AirPlay»: подготовка
  хоста выключает Алису.

---

## Идеи со Станции 2 { #station-2 }

!!! warning "Проверено на Станции 2 (`yandex,station-midi`), на Мини 3 не проверялось"
    Ниже — не замена рецепту, а три приёма из [репозитория про Станцию 2](https://github.com/derangedabbot/yandex-station-2-airplay),
    где AirPlay 2 собирается из исходников. Подробный разбор — `docs/03-airplay.md` там же.
    Пути к демонам, порты и способ запуска у каждой модели свои: сверяйте, прежде чем копировать.

### Обратное управление: пауза, «дальше», «назад»

DACP для AirPlay 2 не работает: источник не присылает `DACP-ID` в SETUP и не публикует
`_dacp._tcp` (проверяется с мака: `dns-sd -B _dacp._tcp` — пусто). Рабочий механизм — plist
на **канал событий аудио-сессии**:

```text
POST /command RTSP/1.0
Content-Type: application/x-apple-binary-plist

{ "type": "sendMediaRemoteCommand", "modernMediaRemoteCommand": <n> }
```

Номера как у Apple: `0` play, `1` pause, `2` toggle, `3` stop, `4` next, `5` previous.
Первоисточник — обсуждение shairport-sync
[#2262](https://github.com/mikebrady/shairport-sync/discussions/2262), там же отвечает автор.

Три грабли, каждая выглядит как «механизм не работает»:

1. **Канал.** Отправлять только в событийный канал **аудио/PTP**-соединения. На канале
   `SETUP (RC)` тот же endpoint несёт protobuf MediaRemote — plist там проглатывается.
2. **Канал должен быть уже открыт** (`event_channel_fd > 0`), иначе отправлять некуда.
3. **`dbus-send` без `--print-reply`.** Клиент пишет вызов и сразу закрывает соединение —
   команда молча отменяется, exit code 0, в логе пусто. На нашей musl/Alpine-сборке это
   воспроизводится всегда; на Debian и Raspberry Pi OS автор shairport-sync такого не видит —
   то есть это особенность окружения, но флаг ставить всё равно безвредно.

В `development` (5.6+) механизм уже в апстриме: `remote/remote.c`, `remote_simple_command()`
и `ap2_event_send_simple_modern_media_remote_command()`. Для `4.3.7` из этого рецепта патч
придётся портировать; у нас проверено на 5.5.1 (свой патч,
`scripts/build/airplay2/remote-control.patch`) и на 5.7-dev (апстрим, без патча).

### Арбитраж звука по TCP-сессии

`maind --mediad` держит `pcmC0D0p` постоянно, поэтому приёмник получает `EBUSY`: AirPlay
«подключился», звука нет. Определять «играет» по владению ALSA **нельзя** — устройством владеет
медиа-демон, признак всегда ложный, и круг замыкается: скрипт ждёт приёмник, приёмник ждёт скрипт.
Признак — **ESTABLISHED-соединение на порт приёмника** (`/proc/net/tcp`, `/proc/net/tcp6`, состояние `01`).

Порт зависит от версии: до 5.6 AirPlay 2 всегда слушал 7000 (`1B58`) и не смотрел на `port` из
конфига, в 5.6+ берётся значение из `shairport-sync.conf` (у нас `5000`, `1388`). Проверять оба,
иначе после обновления приёмника сессия не находится и звук держит медиа-демон.

Готовый распорядитель — [`contrib/audio-owner.sh`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/audio-owner.sh):
при сессии гасит медиа-демон (в цикле — супервизор поднимает его обратно), после сессии
перезапускает приёмник, чтобы тот отпустил ALSA, и поднимает демон заново. Сверху вынесены
`MEDIAD_BIN`, `AP_PORT_7000`, `AP_PORT_CONF`, каталог приёмника и подсветка — под Мини 3 их надо
сверить.

### Автозапуск и звук

- **Автозапуск не по номеру в init.d.** Скрипт ждёт появления `/data` и `/dev/snd`, и только
  потом поднимает шину D-Bus, avahi, приёмник и распорядителя: иначе приёмник стартует раньше
  звуковой карты.
- **Свой `ALSA_CONFIG_PATH`.** Системный `alsa.conf` тянет 32-битные плагины, и musl-бинарник
  падает с `Exec format error`.
- **mDNS рядом с `maind`** — раздел [«Свой mDNS (avahi) рядом с maind»](../internals/gotchas.md#avahi).
  На Станции 2 хватило того, что avahi получает ровно то имя хоста, которое публикует `maind`.

---

## Станция 2: AirPlay 2 одним набором { #station-2-bundle }

!!! info "Проверено на Станции 2 (`yandexmidi`, прошивка `0.369.1.50.*` от 21.10.2026)"
    `shairport-sync 5.6.2` (AirPlay 2) и `nqptp 1.2.9`, собраны из исходников. Схема та же, что
    [выше](#station-2): своя шина D-Bus, avahi с именем хоста колонки, распорядитель звука.

Скрипты — [`contrib/station2-media`](https://github.com/Marker284/yandex-station-extended/tree/main/contrib/station2-media).
Что в них сделано иначе:

- **Один каталог `/data/local/opt/ap2`.** Всё собрано под musl, а `patchelf` прописывает
  бинарникам интерпретатор `/data/local/opt/ap2/lib/ld-musl-aarch64.so.1` и `RUNPATH`
  `$ORIGIN/../lib`: они запускаются напрямую, без обёртки с загрузчиком и без
  `LD_LIBRARY_PATH`, который ломал бы 32-битные программы Яндекса.
- **Одна громкость с Алисой.** Звук AirPlay идёт через `softvol` на регуляторе Алисы
  `Master Playback Volume`, а `shairport-sync` двигает этот же регулятор
  (`mixer_control_name = "Master"`): сенсорная панель, голос и ползунок iPhone меняют одну
  громкость.
- **Установка за короткое окно ADB.** По ADB уходит только SSH (меньше 1 МБ), остальное — по SSH.
  На Станции 2 загрузка 15 МБ по ADB шла 100 с и обрывалась вместе с окном.
- **Сторож обновлений** `/etc/init.d/S96otaguard` на корневой ФС: переживает сброс колонки,
  подробности — ниже.

### Сборка

Docker на Linux или macOS (Apple Silicon — `colima start --arch aarch64 --vm-type vz`):

```sh
cd contrib/station2-media/build
docker run --rm --platform linux/arm64 -v "$PWD:/work" -v "$PWD/out:/out" \
  alpine:3.24 sh /work/ap2-build.sh
```

Внутри: минимальный статический ffmpeg (только `aac` и `alac`), `nqptp`, `shairport-sync` с
`--with-airplay-2`, avahi, dbus, dropbear и alsa-utils из пакетов Alpine, замыкание библиотек
и `patchelf`. Результат — `build/out/ap2/{bin,lib}`, около 14 МБ. Версии `shairport-sync` и
`nqptp` должны совпадать по интерфейсу памяти (`smi11` у обоих).

### Установка

Нужен root ADB ([шаг 1](../start/root.md)). Установщик запускают сразу, как только открылся
порт `5555`:

```sh
cd contrib/station2-media
./install.sh <IP колонки>              # SSH по ADB, затем всё остальное по SSH
./install.sh <IP колонки> --ssh-only   # повторно, когда SSH уже есть
```

Что делает:

- ключ `~/.ssh/yandex_station2` и dropbear на `2222`, вход только по ключу;
- [`yandex-noupdate.sh`](../start/ssh.md#kill-ota) и сторож обновлений, оригиналы файлов —
  рядом со скриптом, в `backup/ota`;
- набор в `/data/local/opt/ap2`, автозапуск `/etc/init.d/S97ap2`;
- имя хоста для avahi берёт из mDNS колонки (`hostname` у неё другой).

На колонке: `/data/local/opt/ap2/ap2.sh start|stop|restart|status`.

### Громкость

- Регулятор `Master Playback Volume` (моно, 0–255) Алиса двигает через `set_volume.sh` →
  `amixer set Master N%`. Системный `softvol` создаёт его **без шкалы в дБ**, поэтому
  `ap2.sh start` один раз открывает свой `softvol` на этом регуляторе с пустым выходом
  (`pcm.ap2prime`): шкала появляется и держится до перезагрузки.
- Шкала выхода — 36 дБ. На системных 51 дБ четверть ползунка — почти тишина, а вся слышимая
  громкость сжата в верхнюю половину.
- `shairport-sync` идёт с `chrt -r 30`: без реального времени звук делит процессор с демонами
  Яндекса.

### Обновления

`yandex-noupdate.sh` подменяет ключ, заглушает `device_ota_update.sh` и убирает `updatesd`. На
Станции 2 есть ещё одно звено: `device_ota_update.sh` вызывает `/usr/bin/apply_packed_ota`,
который кладёт образ в `/bkupgrade/ota/yandex_io_ota.swu`, ставит
`fw_setenv boot_to_recovery 1` и перезагружает колонку в recovery. `S96otaguard` раз в 2 минуты
возвращает заглушки (эталоны — в `/etc/otaguard`), гасит `updatesd`, удаляет скачанные образы
и сбрасывает `boot_to_recovery`. Разрешить штатное обновление: `touch /data/local/allow_ota`.

### Ограничения

- Пока играет AirPlay, медиа-демон Алисы остановлен: её плеер и голос молчат, после сессии
  возвращаются через пару секунд.
- После каждой сессии приёмник перезапускается, чтобы отпустить ALSA, — на несколько секунд
  колонка пропадает из списка AirPlay.
- В «Доме» колонка добавляется как AirPlay-динамик, но плеера и кнопок на её плитке нет:
  «Дом» при открытии плитки к колонке не обращается, а протокол MediaRemote, на котором
  работает этот плеер, в `shairport-sync` не реализован.
