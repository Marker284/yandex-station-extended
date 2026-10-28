# Yandex Station Extended

<p align="center">
  <img src="assets/images/logo.png" alt="YSE" width="140" style="border-radius: 18px;">
</p>

Открытая вики о том, как получить доступ к умным колонкам Яндекса и что с ними можно
сделать дальше: SSH, свой софт, USB-периферия, AirPlay, свои звуки. Всё — для своих устройств.

<div class="tg-banner" markdown>
<span class="tg-banner__icon">:fontawesome-brands-telegram:</span>
<div class="tg-banner__text" markdown>
**Чат сообщества в Telegram**<br>
Находки, новости и обсуждение проекта — в [@hackalice](https://t.me/hackalice).
</div>
[Открыть чат](https://t.me/hackalice){ .md-button .md-button--primary .tg-banner__button }
</div>

## С чего начать

1. **[Получение root](start/index.md#root-by-model)** — у каждой модели свой способ,
   без разборки (~15 минут).
2. **[SSH и отключение обновлений](start/ssh.md)** — чтобы доступ не пропал.
3. **[Пакеты `yse`](start/packages.md)** — `htop`, `tmux`, `nano`, `python` и тысячи других.
4. **[Если что-то сломалось](start/recovery.md)** — диагностика и откат.

## Разделы

<div class="grid cards" markdown>

-   :material-play-circle: **[Начало работы](start/index.md)**

    Root, SSH, защита от обновлений, пакеты, восстановление.

-   :material-lightbulb-on: **[Рецепты](recipes/index.md)**

    USB Host (флешки, Ethernet, наушники), AirPlay, свои звуки, Fastfetch, подсветка,
    плагины [YAM](recipes/yam.md).

-   :material-speaker: **[Устройства](devices/index.md)**

    Железо каждой модели: SoC, флеш, I2C, звук, подсветка.

-   :material-cog: **[Как это устроено](internals/architecture.md)**

    Прошивка quasar, сеть и порты, подводные камни, сборка своего софта.

</div>

## Модели

| Модель | Root и доступ |
|---|:---:|
| Мини, Мини 2, Миди, Станция 2, Стрит, Умный хаб | ✅ проверено |
| Лайт (1-го поколения) | ✅ проверено; сборки после 21.10.2026 — [свой стенд](start/root.md#local-stand) с откатом на `.46` |
| Мини 3 (bergamot) | ✅ [retail CA и маркеры из factory](start/retail-ca-mini3.md) |
| Лайт 2 (Plum) | ✅ [retail CA из factory](start/retail-ca.md) |
| Станция 1-го поколения | ✅ [AliceBridge](start/root-android.md#station-1) |
| Станция Макс (YNDX-0008) | ✅ [ADB Max](start/adb-max.md) |
| Станция 3 (orion) | ✅ [DNS-метод](start/root.md) (свой стенд — [только с CA из бандла](devices/station-3.md#tls)) |
| JBL Link Music (с Алисой) | ✅ [ADB по USB на старте](start/root-jbl-link-music.md) |

Подробнее — в [каталоге устройств](devices/index.md#support-matrix).

<div class="tg-banner gh-banner" markdown>
<span class="tg-banner__icon">:fontawesome-solid-star:</span>
<div class="tg-banner__text" markdown>
**Поставьте звезду на GitHub**<br>
Вики ведут энтузиасты в свободное время. Каждая ⭐ показывает, что проект нужен,
и мотивирует развивать его дальше.
</div>
[:fontawesome-brands-github: Поставить звезду](https://github.com/Marker284/yandex-station-extended){ .md-button .md-button--primary .tg-banner__button }
</div>

---

Нашли что-то новое? Нажмите ✏️ вверху любой страницы и предложите правку —
[как дополнять вики](contributing.md).

!!! warning "Только свои устройства"
    Модификация системных разделов может вывести колонку из строя. Не публикуйте
    персональные данные: ключи из `devices.json`, MAC-адреса, серийные номера, токены.
