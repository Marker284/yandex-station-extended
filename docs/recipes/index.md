# Рецепты

Что можно сделать с колонкой после [получения доступа](../start/index.md#root-by-model).

| Рецепт | Что даёт | Модели |
|---|---|---|
| [USB Host (OTG)](usb-host.md) | флешки и SSD, USB-Ethernet, USB-наушники/ЦАП через хаб | Лайт, Станция 2 |
| [AirPlay](airplay.md) | колонка как приёмник AirPlay 2 | Мини 3; Лайт 2 — вместе с Алисой |
| [Плееры как Bluetooth](bt-proxy.md) | любой MPRIS-плеер — Bluetooth-источник Алисы: фокус, «дальше / пауза», общая громкость | Лайт 2 / Plum |
| [Свои звуки](sounds.md) | проигрывание файлов и потоков, звук при включении | все Amlogic |
| [Обработанный микрофон](microphone.md) | штатный VQE-выход 16 кГц на Linux-ПК | Лайт 2 / Plum, проверенная сборка |
| [Fastfetch](fastfetch.md) | информер с логотипом Алисы | все `aarch64` |
| [Подсветка](led.md) | управление кольцом, возврат штатных анимаций, формат `.led` | Лайт, Лайт 2, Мини 2, Мини 3 |
| [YAM и BetterYAM](packagemanagers.md) | плагины `.yap` с веб-панелью и Lua API к подсветке, кнопкам, датчикам, голосовым командам | `aarch64`; BetterYAM — Мини |
| [Своя LLM вместо Алисы](llm.md) | гибрид с LLM и Home Assistant ([Quasar Bridge](llm.md#quasar-bridge)), свой бэкенд ([quasard](llm.md#quasard)) или [ChatGPT Voice: нативно или через ПК](llm.md#chatgpt-web) | Quasar Bridge — Станция 2, Quasar 3.21; quasard — ~1.56 и 3.x; ChatGPT — Лайт 2 / Plum |
| [Колонка без Яндекса](standalone.md) | заблокированные подписочные Станции | — |
| [Отключение обновлений](station1-disable-updates.md) | остановка цикла обязательного OTA, из-за которого Алиса отвечает с ошибками | проверено на Станции 1, прошивка 2.369.5.46 |
| [Spotify Connect](spotify.md) | колонка как приёмник Spotify и «Алиса, поставь …» через Spotify | Станция 2 |
| [Debian на Станции 1](station1-debian.md) | Debian 13 со своим ядром Linux 7.3 рядом с Алисой или вместо неё, одной командой; удаление возвращает сток | проверено на Станции 1, прошивка 2.369.5.46 |
| [ТВ-набор для Станции 1](station1-tv.md) | веб-пульт в браузере телефона, ТВ-лаунчер, YouTube (SmartTube) и VPN (v2rayNG) на HDMI | проверено на Станции 1, прошивка 2.369.5.46 |

Готовые скрипты собраны в каталоге
[`contrib/`](https://github.com/Marker284/yandex-station-extended/tree/main/contrib), их
назначение описано в [его README](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/README.md).
