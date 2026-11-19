# Xray только для NewPipe (Станция 1)

Скрипты к разделу [«Подписка вместо одного ключа»](https://hackalice.me/recipes/station1-soundcloud/#xray).
Проверено на Станции 1 (Android 6.0.1, quasar 2.369.5.46, AliceBridge), Xray-core 26.11.9,
ноябрь 2026.

| Файл | Что делает |
|---|---|
| `run.sh` | `start`/`stop`/`restart`/`status`/`update`/`selftest`/`setup`/`boot`: Xray и правило iptables, которое направляет в него только TCP NewPipe |
| `sub-update.sh` | скачивает подписку (адрес — `/data/xray/sub.url`, в `curl` через stdin), собирает конфиг со всеми серверами за балансировщиком, проверяет его `xray run -test` и перезапускает Xray только при изменениях |
| `extract.awk` | маленький разборщик JSON: достаёт из подписки все outbound с тегом `proxy` |
| `watch.sh` | сторож: раз в минуту проверяет SoundCloud через туннель, перезапускает упавший Xray, обновляет подписку раз в 12 часов или после трёх неудачных проверок подряд |
| `gemini-test.sh` | необязательно: ищет серверы, через которые отвечает API Gemini, для [своей LLM](https://hackalice.me/recipes/llm/#llm-alice-station1) |

Бинарник Xray не входит в набор: возьмите `Xray-android-arm64-v8a.zip` из
[релизов XTLS/Xray-core](https://github.com/XTLS/Xray-core/releases) и сверьте SHA-256 с
файлом `.dgst` рядом.
