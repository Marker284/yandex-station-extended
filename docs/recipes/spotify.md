# Spotify Connect (Станция 2)

Станция 2 как устройство Spotify Connect: колонку видно в приложении Spotify, громкость общая с
Алисой, а на «Алиса, поставь …» музыка включается из Spotify вместо Яндекс Музыки.

**Проверено на:** Станция 2 (`yandexmidi`), прошивка `0.369.1.50.*` от 21.10.2026, подписка
Spotify Premium: Spotify Soloist 1.3.10 — ноябрь 2026, librespot 0.8.0 — октябрь 2026.
Ставится поверх [AirPlay 2 одним набором](airplay.md#station-2-bundle): тот же каталог
`/data/local/opt/ap2`, распорядитель звука и автозапуск.

## Какой способ выбрать { #choose }

Звук в Spotify Connect отдаёт один из двух клиентов. Голосовые команды и приглушение работают
с обоими.

| | [Soloist](#soloist) | [librespot](#librespot) |
|---|---|---|
| Что это | официальный клиент Spotify для колонок и усилителей | открытая реализация протокола |
| Аккаунты, созданные с 2024–2025 года | играют | вход есть, звука нет — [ниже](#audio-key) |
| Сборка | окружение ~20 МБ, сам клиент качает колонка | `librespot` из исходников, ~30 минут под эмуляцией |
| Место на `/data` | ~55 МБ и кэш до 100 МБ | ~16 МБ |
| Обновление | сборка живёт 90 дней, колонка обновляет её сама | по желанию |
| Первый вход | выбрать колонку в Spotify с телефона в той же сети | OAuth через SSH-туннель |

Если librespot на аккаунте уже даёт `error audio key 0 1`, ставьте Soloist. Ставить оба не
нужно: при установленном Soloist `ap2.sh` librespot не запускает.

## Что понадобится { #requirements }

- набор из [рецепта AirPlay](airplay.md#station-2-bundle) и SSH по ключу;
- Spotify Premium — с бесплатным аккаунтом не работают ни librespot, ни Soloist;
- доступ к серверам Spotify из домашней сети — если провайдер его режет, см.
  [ниже](#dpi);
- на компьютере с x86 Linux — эмуляция arm64 для `docker --platform linux/arm64`
  (`qemu-user-static`); Docker Desktop на macOS и Windows её уже содержит;
- для Soloist — ключ на [developer.spotify.com/dashboard/soloist](https://developer.spotify.com/dashboard/soloist):
  его выпускает аккаунт с Premium, ключ личный.

## Soloist { #soloist }

### Сборка и установка Soloist { #soloist-install }

```sh
cd contrib/station2-media/build
docker run --rm --platform linux/arm64 -v "$PWD:/work" -v "$PWD/out:/out" \
  alpine:3.24 sh /work/voice-build.sh
docker run --rm --platform linux/arm64 -v "$PWD:/work" -v "$PWD/out:/out" \
  debian:trixie sh /work/soloist-build.sh
cd .. && ./soloist-install.sh <IP колонки> <ключ Soloist>
```

`voice-build.sh` даёт `curl` и `jq`: они нужны и Soloist, и голосовым командам.
`soloist-build.sh` собирает только окружение, сам клиент в набор не попадает:
`soloist-install.sh` запускает на колонке `soloist.sh update`, и та качает его с
`soloist-builds.spotifycdn.com`. Распространять сборки Soloist Spotify не разрешает.

Установщик кладёт всё в `/data/local/opt/ap2/soloist`, ключ — в `soloist/etc/api-key` с
правами `600`, обновляет `ap2.sh`, `audio-owner.sh`, `voice-spotify.sh`, `spotify-api.sh` и
`etc/asound.conf` и перезапускает набор. Отдельного автозапуска нет: Soloist поднимает
`ap2.sh` из `/etc/init.d/S97ap2`.

### Вход в Soloist { #soloist-login }

Soloist не открывает браузер и не спрашивает пароль. Первый вход — с телефона в той же сети:
Spotify → значок устройств → «Станция 2» → любой трек. В `soloist.log` появляется
`logged in as …`, вход сохраняется в `soloist/data` и переживает перезагрузку.

```sh
/data/local/opt/ap2/soloist/soloist.sh status
tail /data/local/tmp/ap2/soloist.log
```

### Как устроен Soloist { #soloist-how }

- **Окружение.** Soloist собран под glibc 2.38+, а у колонки 32-битный userland с glibc 2.30
  при ядре aarch64. Рядом лежит загрузчик glibc 2.41 из Debian, клиент запускается через него:
  `lib/ld-linux-aarch64.so.1 --library-path lib soloist`. Бинарник Spotify не патчится.
- **Звук.** Soloist выводит звук только в PulseAudio или PipeWire. Свой PulseAudio 17 отдаёт
  его в FIFO через `module-pipe-sink`. `soloist.sh` читает события `soloist ctl trace` и на
  время игры запускает `sink.sh`: тот, как `spotify-sink.sh` у librespot, освобождает
  устройство от медиа-демона Алисы и запускает `aplay`. На паузе дольше 3 с звук
  возвращается Алисе.
- **Громкость.** Громкость Алисы — это усилитель: регулятор `Master` двигает `SY6045S Master`
  (50% — −25,5 дБ, 20% — −41 дБ), и через усилитель идёт любой звук. Soloist же сам ослабляет
  свой поток на `60·lg(v/100)` дБ (50% — −18 дБ), и вдвоём выходило слишком тихо: Spotify
  на 50% звучал как Алиса на 2. Поэтому выход PulseAudio это ослабление снимает, поток идёт
  мимо `Master` (устройство `spotify_solo` в `asound.conf`), а ползунок Spotify и `Master`
  синхронизируются в обе стороны. Spotify на 50% — то же, что Алиса на 5.
- **Обновление.** Сборка Soloist перестаёт запускаться через 90 дней (код выхода 10).
  `soloist.sh` тогда сам скачивает свежую. Вручную — `soloist.sh update`.
- **Переход с Яндекс Музыки.** На «Алиса, включи музыку» Алиса сначала включает своё, и её
  медиа-демон занимает устройство сразу после остановки. `sink.sh` останавливает его и тут же
  открывает устройство, при `Resource busy` — снова, а `audio-owner.sh` не возвращает Алису,
  пока `/run/soloist/state` — `playing` или `buffering`. От команды до Spotify — около 4 с.

Сообщение `unrecognized option '--type=crashpad-handler'` в `soloist.log` безвредно: Soloist
пытается запустить сборщик падений через `/proc/self/exe`, а это загрузчик glibc.

## librespot { #librespot }

### Сборка librespot { #librespot-install }

```sh
cd contrib/station2-media/build
docker run --rm --platform linux/arm64 -v "$PWD:/work" -v "$PWD/out:/out" \
  alpine:3.24 sh /work/spotify-build.sh
docker run --rm --platform linux/arm64 -v "$PWD:/work" -v "$PWD/out:/out" \
  alpine:3.24 sh /work/voice-build.sh
cd .. && ./install.sh <IP колонки> --ssh-only
```

`spotify-build.sh` собирает `librespot` с `alsa-backend`, `with-avahi` и
`rustls-tls-webpki-roots`. Объявление идёт через тот же Avahi, что у AirPlay, — второго mDNS
рядом с `maind` нет, а TLS не зависит от OpenSSL и сертификатов колонки.

### Вход в librespot { #librespot-login }

Поиск колонки в локальной сети с телефона срабатывает не всегда, надёжнее один раз войти по
OAuth. Дальше `librespot` берёт сохранённый вход из `spotify-cache` и виден в Spotify как
устройство аккаунта из любой сети:

```sh
./spotify-login.sh <IP колонки>
```

Скрипт поднимает на колонке `librespot --enable-oauth --oauth-port 5588`, пробрасывает этот
порт на компьютер по SSH (`-L 5588:127.0.0.1:5588`) и открывает страницу входа Spotify в
браузере. После «Принимаю» ответ уходит через туннель на колонку.

!!! note "VS Code Remote сбивает вход"
    Если на компьютере открыт VS Code с удалённым подключением (WSL, SSH), он замечает порт
    5588, пробрасывает его и сам открывает `http://localhost:5588/`. librespot принимает этот
    запрос за ответ OAuth и завершается: `Auth code param not found in URI http://localhost/`.
    Перед входом отключите автопроброс этого порта в настройках VS Code:
    `"remote.portsAttributes": { "5588": { "onAutoForward": "ignore" } }`.
    То же бывает от любого запроса на `127.0.0.1:5588` во время входа, например от проверки
    порта через `curl`.

### Как устроен librespot { #librespot-how }

- **Звук.** `librespot` с `--backend subprocess` запускает `spotify-sink.sh` на старте
  воспроизведения и убивает на паузе. Приёмник освобождает устройство от медиа-демона Алисы и
  запускает `aplay` с буфером 0,5 с; на паузе распорядитель сразу возвращает звук Алисе.
- **Громкость.** `--mixer alsa --alsa-mixer-control Master`: ползунок Spotify двигает регулятор
  Алисы. Кривая — `--volume-ctrl log --volume-range 25`.
- **Стартовая громкость.** Без `--initial-volume` `librespot` ставит 50% или сохранённое
  значение и этим переставляет громкость Алисы. `ap2.sh` переводит текущее значение `Master`
  в проценты кривой Spotify и передаёт его явно, а сохранённое значение удаляет.

!!! warning "Значение volume-range ниже 25 ломает регулировку громкости"
    На регуляторе со шкалой в дБ `librespot` считает такой диапазон «узким аппаратным» и молча
    переходит на линейную шкалу от минимума регулятора. Нужно 25 или больше.

## Провайдер режет Spotify { #dpi }

Признак — в логе `could not initialize spirc: Service unavailable { client error (Connect) }`.
Вход с телефона при этом проходит: собственный протокол Spotify на порту 4070 не трогают, а
HTTPS к `*.spotify.com` рвётся сразу после TLS ClientHello. Проверка с колонки:

```sh
/data/local/opt/ap2/bin/curl -sS -o /dev/null -w "%{http_code}\n" \
  --cacert /data/local/opt/ap2/lib/ca-certificates.crt https://apresolve.spotify.com/
```

`librespot` ходит только через HTTP-прокси без шифрования, поэтому прокси на внешнем сервере
не поможет: DPI видит имя Spotify и внутри такого туннеля. Рабочий вариант — обход на роутере.
В стандартных правилах XKeen (Mihomo) группа Spotify уже есть (`spotify@domain`). Колонку
нужно добавить в ту же политику доступа Keenetic, через которую XKeen проксирует остальные
устройства, а у группы Spotify должен быть рабочий узел. Soloist за DPI не проверялся; ему
нужны те же `*.spotify.com` и для обновлений — `soloist-builds.spotifycdn.com`.

## Вход есть, звука нет { #audio-key }

Признак — колонка видна в Spotify, вход проходит (`Authenticated as …` в `spotify.log`), но
каждый трек через несколько секунд пропускается, а в логе:

```text
ERROR librespot_core::audio_key] error audio key 0 1
WARN  librespot_playback::player] Unable to load key, continuing without decryption: Service unavailable { audio key error }
ERROR librespot_playback::player] Skipping to next track, unable to load track …
```

Spotify не выдаёт librespot ключ расшифровки трека. Это не ошибка установки и не DPI:
соединение со шлюзом `ap-*.spotify.com` при этом открыто. Проверено на Станции 2, прошивка
`0.369.1.46`, librespot 0.8.0, октябрь 2026: ключ не выдан ни для одного трека, в том числе
для первого после входа; смена шлюза (`ap-gew1` → `ap-gew4`) и выход через европейский
прокси не помогли, официальное приложение на том же аккаунте играет. Мейнтейнеры librespot
7 ноября 2026 закрыли обсуждение итогом: не работают аккаунты, созданные позже примерно
2024–2025 года, на всех версиях librespot; официальные клиенты используют другую, закрытую
схему расшифровки, обхода нет — см. [#1649](https://github.com/librespot-org/librespot/issues/1649),
[#1664](https://github.com/librespot-org/librespot/issues/1664) и
[#1735](https://github.com/librespot-org/librespot/issues/1735).

Решение — [Soloist](#soloist): на аккаунте с этой ошибкой он играет. Другой вариант —
Bluetooth. Чтобы librespot не пролистывал треки, его можно выключить, не удаляя набор и вход:

```sh
chmod -x /data/local/opt/ap2/bin/librespot          # выключить: ap2.sh его пропускает
kill $(pidof librespot)
chmod +x /data/local/opt/ap2/bin/librespot && /data/local/opt/ap2/ap2.sh spotify   # включить
```

## Голосом: «Алиса, поставь …» { #voice }

Алиса отдаёт распознанный текст фразы в локальный канал `127.0.0.1:9875`. `alice-text` берёт
из него только финальный текст и смену состояния, `voice-spotify.sh` разбирает фразу, а
`spotify-api.sh` ищет и включает через Spotify Web API. Колонку он находит по имени
«Станция 2» — так называются и librespot, и Soloist.

| Фраза | Что делает |
|---|---|
| «Алиса, поставь / включи X» | исполнитель, если первый найденный трек — его, иначе трек |
| «Алиса, поставь песню / альбом / плейлист X» | трек, альбом или плейлист |
| «Алиса, поставь музыку» / «… любимое» | любимые треки |
| «Алиса, включи любимое вперемешку» | любимые треки со случайного места и с перемешиванием |
| «Алиса, поставь альбом / плейлист X вперемешку» | то же для альбома или плейлиста |
| «Алиса, перемешай» / «… по порядку» | перемешивание включить / выключить |
| «Алиса, пауза / продолжи / дальше / назад» | управляет Spotify, если он играл в последний час |

Вместо «вперемешку» можно сказать «в случайном порядке» или «рандомно».

!!! note "Голосом проверена только часть команд"
    «Поставь» с именем исполнителя, «включи музыку», «включи любимое вперемешку», «пауза» и
    «тише» во время музыки. Альбом, плейлист, «перемешай», «по порядку», «дальше» и «назад»
    работают по коду и через `spotify-api.sh`, голосом не проверялись.

- Умный дом, таймеры, будильники и громкость остаются Алисе.
- Алиса отвечает как обычно и успевает на секунду-две включить своё — Spotify её перебивает.
  От фразы до звука около 7 с.
- Падежное окончание мешает поиску, поэтому при пустом результате запрос повторяется без него
  («маркула» → «маркул»).
- В лог `voice.log` попадают только музыкальные команды, остальная речь никуда не пишется.

Ключ Web API — своё приложение на [developer.spotify.com](https://developer.spotify.com/dashboard)
(Web API, Redirect URI `<http://127.0.0.1:5589/callback>`) и вход по PKCE без секрета:

```sh
./spotify-webapi-login.sh <Client ID> <IP колонки>
```

Ключи лежат в `etc/spotify-webapi.json` на колонке с правами `600`. Web API
(`api.spotify.com`) провайдер режет так же, и он идёт через тот же обход.

В ноябре 2026 Web API отвечал на `PUT /me/player/play` и `/shuffle` не пустым телом, а
строкой-идентификатором. `spotify-api.sh` считает ошибкой только ответ с `"error"`, иначе
каждый запуск записывался бы в `voice.log` как «не вышло».

### Приглушение, пока Алиса слушает { #ducking }

Свою музыку Алиса на время слушания приглушает, а AirPlay и Spotify — нет, и команда тонет в
музыке. `alice-text` печатает смену состояния: `@state 1` — слушает, `3` — распознала,
`0` — свободна; номера совпадают с `onAliceStateChanged` в `maind.log`. На время слушания
`voice-spotify.sh` опускает отдельный регулятор `AP2 Duck` до 25% (около −22 дБ). Громкость
Алисы он не трогает, а если «свободна» не придёт, громкость вернётся через 15 с. Устройство
`spotify_solo` у Soloist тоже идёт через `AP2 Duck`.

Короткие команды без обращения («громче», «пауза») колонка слышит, но включены они только для
собственного плеера Алисы (`Phrase … is disabled in commandPhrasesConfig`). Для Spotify и
AirPlay нужно говорить «Алиса, …».

## Откат { #rollback }

Только Soloist — librespot вернётся, если он установлен:

```sh
./soloist-install.sh <IP колонки> --remove
```

Установщик кладёт свои файлы в `/data/local/opt/ap2` и прописывает два автозапуска.
Чтобы вернуть колонку как было, с root по SSH:

```sh
rm -f /etc/init.d/S97ap2 /etc/init.d/S96otaguard
rm -rf /data/local/opt/ap2
sh /data/opt/yandex-noupdate.sh restore
reboot
```

Последняя команда возвращает штатные обновления: установщик отключает их
[скриптом из шага 2](../start/ssh.md#kill-ota) и кладёт оригиналы в `/data/opt/backup`.

!!! warning "Риск блокировки аккаунта Spotify"
    Подключение сторонних демонов Spotify Connect, таких как librespot, может приводить к
    блокировке аккаунта со стороны сервиса: поддержка Spotify расценивает подобные клиенты как
    небезопасное подключение. Soloist — клиент самого Spotify, но запуск на колонке со своим
    загрузчиком glibc Spotify не описывает и не поддерживает.
