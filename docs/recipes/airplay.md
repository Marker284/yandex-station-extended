# AirPlay (Shairport Sync)

Станция как приёмник **AirPlay 2** для iPhone, iPad и Mac. Скрипт
[`contrib/yandex-station-airplay-fix.sh`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/yandex-station-airplay-fix.sh)
чинит две известные проблемы уже установленного пакета AirPlay.

!!! info "Проверено на Станции Мини 3"
    `shairport-sync 4.3.7` (AirPlay 2) + `nqptp 1.2.4`. На других моделях пути те же,
    а патч `airplayd` применяется, только если байты в нужном месте совпадают.

## Что нужно заранее

- root по ADB ([шаг 1](../start/root.md));
- установленный пакет AirPlay в `/data/shairport` (`airplay.sh`, `airplayd`, `ap2/shairport-sync-ap2`).

!!! note "Откуда взять пакет `/data/shairport`"
    Инструкции по установке самого пакета в вики пока нет. Если знаете источник —
    [дополните страницу](../contributing.md). Другой путь — AirPlay 2 из Entware без
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

## Станция Лайт 2: AirPlay 2 из Entware { #lite2 }

!!! info "Проверено на Станции Лайт 2 (plum), прошивка 0.369.1.50"
    `shairport-sync-openssl 4.3.6` (AirPlay 2, Avahi, soxr) + `nqptp 1.2.4` + `avahi 0.8`
    из Entware (`aarch64-3.10`). Воспроизведение с iPad, автозапуск — по ребуту.
    На других моделях не проверялось.

Пакет `/data/shairport` не нужен: всё ставится из Entware через [`yse`](../start/packages.md)
в `/data/opt`, rootfs меняется только ради автозапуска. Места в `/data` уходит ~33 МБ
(вместе с `libffmpeg-full`).

### Установка

1. Поставьте пакеты (нужен `yse bootstrap`):

    ```sh
    yse install shairport-sync-openssl nqptp avahi-dbus-daemon
    ```

2. Узнайте имя хоста, которое объявляет `maind` (например, с мака:
   `dns-sd -G v4 <имя>.local` или `avahi-resolve -a <IP колонки>` — см.
   [Свой mDNS рядом с maind](../internals/gotchas.md#avahi)). На Лайт 2 оно вида
   `YandexLite-gen2-XXXXXXXX`. В `/opt/etc/avahi/avahi-daemon.conf`:

    ```ini
    [server]
    host-name=YandexLite-gen2-XXXXXXXX
    allow-interfaces=wlan0
    use-ipv4=yes
    use-ipv6=no

    [publish]
    publish-addresses=no
    publish-hinfo=no
    publish-workstation=no
    ```

3. `/opt/etc/shairport-sync.conf` — `airplay_device_id` задайте явно, это MAC `wlan0`
   (`cat /sys/class/net/wlan0/address`) без двоеточий:

    ```text
    general = { name = "Yandex Lite 2"; interface = "wlan0"; airplay_device_id = 0xXXXXXXXXXXXXL; };
    alsa = { output_device = "default"; };
    sessioncontrol = { run_this_before_play_begins = "/opt/etc/airplay-take-audio.sh";
                       wait_for_completion = "yes"; };
    ```

4. `/opt/etc/asound.conf` — вывод через dmix на 48 кГц (копия штатного `dmix_spk`
   из `/etc/asound.conf`, но со своим `ipc_key`; оригинал Entware сохраните рядом):

    ```text
    pcm.!default { type plug; slave.pcm "dmix_spk"; }
    pcm.dmix_spk {
      type dmix
      ipc_key 2048
      ipc_key_add_uid false
      ipc_perm 0666
      slave { pcm "hw:0,0"; channels 2; rate 48000; buffer_size 7680; period_size 960; }
    }
    ```

5. Арбитраж звука — [`contrib/airplay-take-audio.sh`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/airplay-take-audio.sh)
   в `/opt/etc/` (`chmod 755`). Хук из шага 3 перед началом воспроизведения завершает
   `maind --mediad`, если тот держит карту; супервизор поднимает его заново через ~5 с.

6. Автозапуск — [`contrib/S99zairplay-entware`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/S99zairplay-entware)
   (установка и откат — в шапке скрипта):

    ```sh
    mount -o remount,rw / && cp S99zairplay-entware /etc/init.d/ \
      && chmod 755 /etc/init.d/S99zairplay-entware; mount -o remount,ro /
    /etc/init.d/S99zairplay-entware start
    ```

Проверка с мака: `dns-sd -B _airplay._tcp` показывает колонку, а `dns-sd -B _yandexio._tcp` —
по-прежнему штатный сервис `maind`.

### Грабли { #lite2-gotchas }

- **AirPlay подключается, а звука нет.** `maind --mediad` иногда держит `pcmC0D0p` постоянно:
  `/proc/asound/card0/pcm0p/sub0/status` — `state: PREPARED` без воспроизведения, минутами,
  `owner_pid` — mediad. Сразу после загрузки карта свободна, что заставляет mediad её
  занять — не выяснено. Если mediad завершить, `quasar_launcher2` (`launch.json`: `delay 5`)
  поднимает новый, и тот карту не берёт; shairport повторяет открытие ALSA и захватывает её.
  Это и делает хук из шага 5.
- **Звук икает дважды в секунду.** В логе (`shairport-sync -v --statistics`) раз в ~0,5 с
  `Large negative (i.e. early) sync error of -2300 frames (-0.052 seconds)`. Карта `hw:0`
  фактически играет только 48 кГц и молча принимает 44100: поток идёт на ~9% быстрее,
  расхождение набегает до порога resync (0,05 с), и shairport перескакивает.
  `audio_backend_latency_offset_in_seconds` не помогает — это дрейф, а не задержка.
  Лечится dmix на 48 кГц из шага 4, после него `sync error` в логе нет.
- **`output_device = "default"` без шага 4 — тот же `hw:0`.** shairport из Entware работает
  со своей alsa-lib (1.2.11), она читает `/opt/etc/asound.conf`, а не системный
  `/etc/asound.conf`; в Entware `default` — это `plug` прямо на `hw`.
- **`deviceid=00:00:00:00:00:00` в анонсе.** `interface = "wlan0"` MAC не даёт — нужен явный
  `airplay_device_id`.
- **Штатные `/opt/etc/init.d` из Entware не годятся.** `S20dbus` проверяет `pidof dbus-daemon`,
  видит системный dbus колонки и свой не запускает; `S50shairport-sync` передаёт `-d hw:0,0`
  мимо dmix из шага 4.

### Ограничения

- **Пока играет AirPlay, звуки колонки не выводятся.** Смешать с Алисой через общий dmix не
  получается: alsa-lib Entware (1.2.11) и системная (1.2.1.2) не делят сегмент shared memory,
  системный `aplay` в это время падает с `unable to create IPC shm instance`. Подсунуть
  shairport системную alsa-lib нельзя — ей нужна `GLIBC_2.29`, у Entware 2.27. Поэтому у
  dmix из шага 4 свой `ipc_key`: с общим `1024` версии мешают друг другу через shared memory,
  а со своим остаётся честный `EBUSY` на карте. После остановки AirPlay карта
  освобождается, и звук колонки возвращается. Как ведёт себя сама Алиса, если ответить ей
  во время AirPlay, не проверялось.
- Хук из шага 5 обрывает то, что играла Алиса: AirPlay всегда забирает звук себе.
  Механизм проверен вручную (mediad завершён — карта свободна — shairport её занял),
  хук в сборе — не проверялся.
- Имя хоста в `avahi-daemon.conf` привязано к имени, которое объявляет `maind`: если оно
  сменится, AirPlay пропадёт из сети, сама колонка не пострадает.

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
