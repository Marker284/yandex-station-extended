# station2-media — AirPlay 2 и Spotify для Станции 2

Набор для Станции 2 (`yandexmidi`): `shairport-sync` с AirPlay 2, `nqptp`, avahi, dbus,
dropbear и распорядитель звука в одном каталоге `/data/local/opt/ap2` на колонке.
Описание и ограничения — [рецепт AirPlay, раздел про Станцию 2](https://hackalice.me/recipes/airplay/#station-2-bundle).

Проверено на Станции 2, прошивка `0.369.1.50.*` от 21.10.2026.

| Файл | Что делает |
|---|---|
| `build/ap2-build.sh` | сборка в `alpine:3.24` (arm64): ffmpeg с `aac`/`alac`, `nqptp`, `shairport-sync`, пакеты Alpine, `patchelf` |
| `install.sh <IP>` | SSH по ADB, затем по SSH: набор, `yandex-noupdate.sh`, сторож обновлений, автозапуск |
| `device/ap2.sh` | `start`/`stop`/`restart`/`status`: шина D-Bus, avahi, `nqptp`, приёмник, распорядитель |
| `device/common.sh` | общие функции: поиск процессов, медиа-демон Алисы, приоритет звука |
| `device/audio-owner.sh` | отдаёт звук AirPlay и возвращает его Алисе после сессии |
| `device/S97ap2` | автозапуск: SSH на `2222`, затем AirPlay, когда появятся `/data` и звуковая карта |
| `device/S96otaguard` | сторож обновлений на корневой ФС |
| `device/etc/` | ALSA (громкость через регулятор Алисы, приглушение), D-Bus, avahi, `shairport-sync` |
| `build/spotify-build.sh` | `librespot 0.8.0` (avahi, rustls, ALSA-микшер) в тот же набор |
| `build/voice-build.sh` | `alice-text` из `build/voice/alice-text.c`, `jq`, `curl` и сертификаты для Web API |
| `device/spotify-sink.sh` | вывод `librespot`: забирает звук у медиа-демона Алисы на время игры |
| `device/spotify-api.sh` | Spotify Web API: найти и включить на колонке, пауза, дальше, назад |
| `device/voice-spotify.sh` | «Алиса, поставь …» → Spotify; приглушение музыки, пока Алиса слушает |
| `spotify-login.sh <IP>` | вход `librespot` по OAuth через SSH-туннель |
| `spotify-webapi-login.sh <Client ID> <IP>` | ключ Web API (PKCE) для голосовых команд |

Spotify — [рецепт Spotify Connect](https://hackalice.me/recipes/spotify/).

Установщик кладёт рядом с собой `known_hosts` колонки и `backup/ota` с оригиналами файлов
обновления — оба в `.gitignore`.
