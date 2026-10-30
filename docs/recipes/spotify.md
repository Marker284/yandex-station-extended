# Spotify Connect (Станция 2)

Станция 2 как устройство Spotify Connect: колонку видно в приложении Spotify, громкость общая с
Алисой, а на «Алиса, поставь …» музыка включается из Spotify вместо Яндекс Музыки.

**Проверено на:** Станция 2 (`yandexmidi`), прошивка `0.369.1.50.*` от 21.10.2026,
librespot 0.8.0, подписка Spotify Premium. Ставится поверх
[AirPlay 2 одним набором](airplay.md#station-2-bundle): тот же каталог
`/data/local/opt/ap2`, распорядитель звука и автозапуск.

## Что понадобится { #requirements }

- набор из [рецепта AirPlay](airplay.md#station-2-bundle) и SSH по ключу;
- Spotify Premium — с бесплатным аккаунтом librespot не работает;
- доступ к серверам Spotify из домашней сети — если провайдер его режет, см.
  [ниже](#dpi);
- аккаунт, которому Spotify выдаёт librespot ключи треков, — на части аккаунтов вход проходит,
  а звука нет, см. [ниже](#audio-key);
- на компьютере с x86 Linux — эмуляция arm64 для `docker --platform linux/arm64`
  (`qemu-user-static`); Docker Desktop на macOS и Windows её уже содержит.

## Сборка и установка

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

## Вход

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

## Как устроено

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
устройства, а у группы Spotify должен быть рабочий узел.

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
для первого после входа; смена шлюза (`ap-gew1` → `ap-gew4`) и выход через европейский прокси не помогли,
официальное приложение на том же аккаунте играет. Исправления в librespot на конец октября
2026 нет — см. [#1649](https://github.com/librespot-org/librespot/issues/1649),
[#1664](https://github.com/librespot-org/librespot/issues/1664) и
[#1735](https://github.com/librespot-org/librespot/issues/1735): в последнем на одной машине
один Premium-аккаунт играет, другой получает ту же ошибку.

Пока исправления нет, проверьте другой аккаунт или слушайте по Bluetooth. Чтобы librespot не
пролистывал треки, его можно выключить, не удаляя набор и вход:

```sh
chmod -x /data/local/opt/ap2/bin/librespot          # выключить: ap2.sh его пропускает
kill $(pidof librespot)
chmod +x /data/local/opt/ap2/bin/librespot && /data/local/opt/ap2/ap2.sh spotify   # включить
```

## Голосом: «Алиса, поставь …»

Алиса отдаёт распознанный текст фразы в локальный канал `127.0.0.1:9875`. `alice-text` берёт
из него только финальный текст и смену состояния, `voice-spotify.sh` разбирает фразу, а
`spotify-api.sh` ищет и включает через Spotify Web API:

| Фраза | Что делает |
|---|---|
| «Алиса, поставь / включи X» | исполнитель, если первый найденный трек — его, иначе трек |
| «Алиса, поставь песню / альбом / плейлист X» | трек, альбом или плейлист |
| «Алиса, поставь музыку» | любимые треки |
| «Алиса, пауза / продолжи / дальше / назад» | управляет Spotify, если он играл в последний час |

!!! note "Голосом проверена только часть команд"
    «Поставь» с именем исполнителя, «пауза» и «тише» во время музыки. Альбом, плейлист,
    «поставь музыку», «дальше» и «назад» работают по коду, голосом не проверялись.

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

### Приглушение, пока Алиса слушает

Свою музыку Алиса на время слушания приглушает, а AirPlay и Spotify — нет, и команда тонет в
музыке. `alice-text` печатает смену состояния: `@state 1` — слушает, `3` — распознала,
`0` — свободна; номера совпадают с `onAliceStateChanged` в `maind.log`. На время слушания
`voice-spotify.sh` опускает отдельный регулятор `AP2 Duck` до 25% (около −22 дБ). Громкость
Алисы он не трогает, а если «свободна» не придёт, громкость вернётся через 15 с.

Короткие команды без обращения («громче», «пауза») колонка слышит, но включены они только для
собственного плеера Алисы (`Phrase … is disabled in commandPhrasesConfig`). Для Spotify и
AirPlay нужно говорить «Алиса, …».

## Откат { #rollback }

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
