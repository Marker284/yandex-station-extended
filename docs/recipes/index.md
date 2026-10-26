# Рецепты

Что можно сделать с колонкой после [получения доступа](../start/index.md#root-by-model).

| Рецепт | Что даёт | Модели |
|---|---|---|
| [USB Host (OTG)](usb-host.md) | флешки и SSD, USB-Ethernet, USB-наушники/ЦАП через хаб | Лайт, Станция 2 |
| [AirPlay](airplay.md) | колонка как приёмник AirPlay 2 | проверено на Мини 3 |
| [Свои звуки](sounds.md) | проигрывание файлов и потоков, звук при включении | все Amlogic |
| [Обработанный микрофон](microphone.md) | штатный VQE-выход 16 кГц на Linux-ПК | Лайт 2 / Plum, проверенная сборка |
| [Fastfetch](fastfetch.md) | информер с логотипом Алисы | все `aarch64` |
| [Подсветка](led.md) | управление кольцом, возврат штатных анимаций, формат `.led` | Лайт, Лайт 2, Мини 2, Мини 3 |
| [YAM и BetterYAM](yam.md) | плагины `.yap` с веб-панелью и Lua API к подсветке, кнопкам, датчикам, голосовым командам | `aarch64`; BetterYAM — Мини |
| [Своя LLM вместо Алисы](llm.md) | гибрид с LLM и Home Assistant ([Quasar Bridge](llm.md#quasar-bridge)), свой бэкенд ([quasard](llm.md#quasard)) или [голосовой режим сайта ChatGPT](llm.md#chatgpt-web) | Quasar Bridge — Станция 2, Quasar 3.21; quasard — ~1.56 и 3.x; ChatGPT — Лайт 2 / Plum |
| [Колонка без Яндекса](standalone.md) | заблокированные подписочные Станции | — |

Готовые скрипты — в каталоге
[`contrib/`](https://github.com/Marker284/yandex-station-extended/tree/main/contrib)
([описание](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/README.md)).
