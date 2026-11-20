# NabuStation - голосовой ассистент HA + Spotify + AndroidTV для Станции 1

**Коротко:** NabuStation — набор скриптов и конфигов для root-нутой Станции 1: голосовой спутник Home Assistant, музыка через Music Assistant/Snapcast, Spotify и, по желанию, Android TV с Now Playing, SmartTube и пультом с телефона.

Проверено на **Станции 1 (YNDX-0001, Allwinner R18, Android 6.0.1, Debian 13 + mainline 7.3)**. На других моделях не проверялось.

!!! warning "Root на Станции 1 — только AliceBridge"
    DNS-метод из [шага 1](../start/root.md) рассчитан на Amlogic-модели. На Станции 1 стоит Allwinner R18 + Android 6, поэтому используйте [AliceBridge](../start/root-android.md#station-1).

## Что понадобится

- Станция 1 (YNDX-0001) с root через [AliceBridge](../start/root-android.md#station-1).
- SSH и отключённые обновления: [шаг 2](../start/ssh.md), [отключение обновлений](station1-disable-updates.md).
- Компьютер с `adb` и SSH: [установка ADB](../start/adb.md).
- Home Assistant с Assist и `prefer_local_intents: true`.
- Linux-хост с systemd и Docker для voice server и Silero TTS. Это не аддон HA: при HA OS voice server ставится на отдельный Linux-компьютер.
- Music Assistant + Snapcast и, по желанию, Spotify Premium.
- Для Android TV — Android 6 на станции, root/ADB.

## Что ставится

| Модуль | Что даёт | Нужен |
|---|---|---|
| `station/` | микрофон, TTS-плеер, LED, кнопка, диск, громкость | для Debian-голоса |
| `voice-server/` | wake word «Окей Набу», AEC, HA Assist | для голоса |
| `silero-tts/` | русский TTS в Docker | для голоса |
| `home-assistant/` | интенты, фразы, now playing, громкость | для команд |
| `music-assistant/` | музыка, Spotify, like/unlike | по желанию |
| `android/` | TV Launcher, Now Playing, SmartTube, пульт | по желанию |

Можно поставить только ассистента, без Spotify и без музыки.

## Шаги

### 1. Root, SSH и обновления

1. Получите root через [AliceBridge](../start/root-android.md#station-1).
2. Настройте SSH: [шаг 2](../start/ssh.md).
3. Отключите обновления: [рецепт](station1-disable-updates.md).
4. По желанию ограничьте телеметрию: [рецепт](station1-privacy.md).

Перед изменениями сохраните заводской `boot` и способ восстановления: [если что-то сломалось](../start/recovery.md).

### 2. Выберите режим станции

- **Debian** — голос и музыка: [Debian на Станции 1](station1-debian.md).
- **Android TV** — TV Launcher, Now Playing, SmartTube, пульт: [ТВ-набор](station1-tv.md).

Режимы могут сосуществовать; возврат в Android описан в рецепте Debian.

### 3. Установите модуль станции

**Debian-режим.** По SSH на станции:

    git clone https://github.com/qwikly3/NabuStation.git
    cd NabuStation
    SNAPCAST_HOST=<HA_IP> ./station/install.sh

Скрипт поставит `alsa-utils`, `python3`, `netcat`, `runit`, `snapclient`, создаст `/root/voice`, `/etc/nabustation/station.env` и `/etc/asound.conf` с dmix.

Если нужен тот же MA-плеер, что был в Android, укажите `STATION_HOST_ID`. Иначе MA создаст новый.

Проверка:

    sv status voice volume voice-watch snapclient
    curl http://127.0.0.1:8098/health

**Android-режим.** На компьютере с ADB, станция загружена в Android:

    git clone https://github.com/qwikly3/NabuStation.git
    cd NabuStation
    ./android/scripts/fetch_apks.sh
    SNAPCAST_HOST=<HA_IP> HA_HOST=<HA_IP> ./android/scripts/install.sh

APK лежат в [релизе](https://github.com/qwikly3/NabuStation/releases/tag/v1.0.0), в git их нет. Скрипт скачает их, установит TV Launcher/Snapcast/SmartTube/Now Playing, разложит `/data/voice` и `/data/local/tmp`, включит boot-hook.

### 4. Voice server и Silero TTS

На Linux-хосте:

    sudo apt install libspeexdsp1 python3-venv
    git clone https://github.com/qwikly3/NabuStation.git
    cd NabuStation
    STATION_HOST=<STATION_IP> HA_HOST=127.0.0.1 ./voice-server/install.sh

Если HA на другом хосте: `HA_HOST=<HA_IP>`.

Установщик спросит long-lived token HA: **профиль → Security → Long-lived access tokens**.

Проверка:

    systemctl --user status station-voice.service
    journalctl --user -u station-voice.service -f

В логе должно быть `AEC: SpeexDSP`, `pipeline: ...`, `mic format: 5 channel(s)`.

Silero TTS:

    cd silero-tts
    docker compose up -d --build
    curl http://127.0.0.1:10400/health

Первый запуск скачивает модель. Образ рассчитан на x86_64; на ARM нужен другой HTTP TTS с интерфейсом `GET /tts?text=...&speaker=...&sr=...`.

### 5. Home Assistant: пакеты и фразы

В `/config/configuration.yaml`:

    homeassistant:
      packages: !include_dir_named packages

Скопируйте нужные файлы:

    mkdir -p /config/packages /config/custom_sentences/ru /config/scripts
    cp home-assistant/packages/nabustation_helpers.yaml /config/packages/
    cp home-assistant/packages/nabustation_core.yaml /config/packages/
    cp home-assistant/custom_sentences/ru/music_core.yaml /config/custom_sentences/ru/

    # по желанию:
    cp home-assistant/packages/nabustation_volume.yaml /config/packages/
    cp home-assistant/custom_sentences/ru/volume.yaml /config/custom_sentences/ru/
    cp home-assistant/packages/nabustation_spotify.yaml /config/packages/
    cp home-assistant/custom_sentences/ru/music_spotify.yaml /config/custom_sentences/ru/
    cp home-assistant/scripts/music_like.py /config/scripts/

Перезапустите HA и заполните helpers:

| Helper | Пример |
|---|---|
| `input_text.nabustation_media_player` | `media_player.station_1` |
| `input_text.nabustation_station_host` | `<STATION_IP>` |
| `input_text.nabustation_liked_playlist` | URI Liked Songs |

Проверка без голоса: Developer Tools → Actions → `conversation.process`:

    text: "что за трек"
    language: ru
    agent_id: conversation.home_assistant

### 6. Music Assistant и Spotify

Подробно: [music-assistant/README.md](https://github.com/qwikly3/NabuStation/blob/master/music-assistant/README.md).

1. Добавьте в MA Snapcast player provider.
2. MA volume = 100 %, Snapcast client volume = 100 %. Громкость — только на станции.
3. Spotify: provider Spotify, backend **Soloist**, Spotify Premium. Без librespot/spotifyd на станции.
4. Найдите URI Liked Songs:

    ```
    docker exec homeassistant mkdir -p /config/scripts
    docker cp tools/discover_ma.py homeassistant:/config/scripts/
    docker exec -it homeassistant python /config/scripts/discover_ma.py

5. Для точного like/unlike:

    ```
    docker cp music-assistant/patch_spotify_like.py music-assistant:/data/patch_spotify_like.py
    docker exec -i music-assistant python /data/patch_spotify_like.py
    docker restart music-assistant

После обновления MA патч нужно применить заново.

### 7. Android TV и пульт

1. Визуализатор на HA-хост:

    ```
    cd android/visualizer
    HA_TOKEN_FILE=$HOME/nabustation/voice/ha_token.txt \
    PLAYER_ENTITY=media_player.station_1 ./install.sh

2. Now Playing APK из релиза использует host `192.168.01.20:8099` (Java читает как `192.168.1.20`). Для другого HA-хоста:

    ```
    cd android/nowplaying
    ANDROID_HOME=/path/to/android-sdk python patch_host.py --host 192.168.01.20

Host — ровно 13 символов; при коротком IP добавьте ведущий ноль в октет. APK подписан debug-ключом, старую версию нужно удалить.

3. Пульт:
    ```
    http://<STATION_IP>:8080/station-remote-modes.apk

В приложении **SET** → IP станции и IP visualizer/HA.

4. Projectivy в релиз не входит. Если нужен — поставьте с [официальной страницы](https://github.com/spocky/miproja1/releases) и пропишите:
    ```
    LAUNCHER=com.spocky.projengmenu/com.spocky.projengmenu.ui.home.MainActivity

По умолчанию используется TV Launcher (`com.tvlauncher`).

### 8. Проверка команд

После wake word:

- «пауза» / «продолжи»
- «дальше» / «назад»
- «перемешай»
- «что за трек» / «что за песня»
- «поставь лайк» / «убери лайк»
- «громкость 5», «громче», «тише»

Громкость:

    curl http://<STATION_IP>:8098/health
    curl "http://<STATION_IP>:8098/volume?level=5"

## Что проверено

На Станции 1 (YNDX-0001):

- Android 6.0.1 и Debian 13 + mainline 7.3;
- root через AliceBridge, SSH, отключение обновлений;
- Debian-голос: 5-канальный TDM, `ch1-3` микрофоны, `ch4` reference, SpeexDSP AEC, openWakeWord `okay_nabu`, HA Assist, Silero TTS;
- музыка: Music Assistant + Snapcast, Spotify Premium/Soloist;
- Android TV: TV Launcher, Now Playing, SmartTube 32.68, Station Remote 1.4;
- громкость, LED, кнопка, диск.

Не проверялось: другие модели, AirPlay, USB Host.

## Если что-то не работает

| Симптом | Куда смотреть |
|---|---|
| Wake word не срабатывает | [голосовой тракт](../internals/voice.md), `arecord -D plughw:2,0 -f S16_LE -r 16000 -c 5`, `MIC_ORDER=debian`, `libspeexdsp1` |
| Нет TTS | `curl http://<HA_IP>:10400/health`, токен HA, лог `station-voice.service` |
| Нет музыки | MA volume 100 %, Snapcast 100 %, `sv status snapclient`, [сеть и порты](../internals/network.md) |
| Spotify like не работает | патч MA, `input_text.nabustation_liked_playlist`, `music_like.py` |
| Android-пульт offline | `adb root`, RemoteDaemon 8096, visualizer 8099, IP в SET |
| Станция не грузится | [восстановление](../start/recovery.md) |

## Как это работает

В Debian-режиме станция отдаёт 5 каналов TDM: `ch1-3` — микрофоны, `ch4` — reference усилителя. Voice server вычитает музыку через SpeexDSP, слушает openWakeWord и отправляет фразу в HA Assist. Ответ синтезирует Silero, музыка играет через `snapclient`.

В Android-режиме `tinycap-raw` + `mic-server` отдают поток на 8091, `RemoteDaemon` слушает 8096, visualizer — 8099, веб-пульт — 8080. Snapcast переподключается через `START_SERVICE`, SmartTube получает отдельный CPU-профиль.

## Благодарности

- [yandex-station-linux](https://github.com/MyszkinPL/yandex-station-linux) — Debian, ядро и DTS;
- [Home Assistant](https://github.com/home-assistant/core);
- [Music Assistant](https://github.com/music-assistant/server);
- [Snapcast](https://github.com/snapcast/snapcast);
- [Spotify Soloist](https://github.com/spotify/soloist);
- [openWakeWord](https://github.com/dscripka/openWakeWord) и [pyopen-wakeword](https://github.com/rhasspy/pyopen-wakeword);
- [SpeexDSP](https://github.com/xiph/speexdsp);
- [Silero models](https://github.com/snakers4/silero-models);
- [SmartTube](https://github.com/yuliskov/SmartTube);
- [TV Launcher](https://github.com/wiiguy/lightweight_androidtv_launcher), [Lite Launcher](https://github.com/anujmv/lite-tv-launcher);
- [LRCLIB](https://lrclib.net/).

Полный список: [CREDITS.md](https://github.com/qwikly3/NabuStation/blob/master/CREDITS.md).

Проект не аффилирован с Яндексом, Spotify, Home Assistant, Music Assistant, Snapcast и авторами Android-приложений. Silero-модели — CC BY-NC-SA 4.0.

!!! warning "Только свои устройства"
    Не публикуйте ключи из `devices.json`, MAC-адреса, серийные номера и токены.