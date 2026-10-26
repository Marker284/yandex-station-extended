# Yandex Station Extended

<p align="center">
  <img src="assets/images/logo.png" alt="YSE" width="140" style="border-radius: 18px;">
</p>

Открытая вики о том, как получить доступ к умным колонкам Яндекса и что с ними можно
сделать: SSH, LLM, Root, Airplay, Spotify и многое другое!

<div class="tg-banner" markdown>
<span class="tg-banner__icon">:fontawesome-brands-telegram:</span>
<div class="tg-banner__text" markdown>
**Чат сообщества в Telegram**<br>
Находки, новости и обсуждение проекта — в [@hackalice](https://t.me/hackalice).
</div>
[Открыть чат](https://t.me/hackalice){ .md-button .md-button--primary .tg-banner__button }
</div>

## С чего начать

1. **[Получение root](start/index.md#root-by-model)** — у каждой модели свой способ, без разборки (~15 минут).
2. **[Настройка SSH и перманентный ADB](start/ssh.md)** — чтобы доступ не пропал.
3. **[Пакеты `yse`](start/packages.md)** — `htop`, `tmux`, `nano`, `python` и тысячи других.
4. **[Если что-то сломалось](start/recovery.md)** — диагностика и откат.

## Разделы

<div class="grid cards" markdown>

-   :material-play-circle: **[Начало работы](start/index.md)**

    Получение ADB, Получение Root, Настройка SSH и других пакетов

-   :material-lightbulb-on: **[Полезное](recipes/index.md)**

    USB Host (флешки, Ethernet, наушники), AirPlay, LLM, Управление LED,
    плагины [YAM](recipes/yam.md).

-   :material-speaker: **[Устройства](devices/index.md)**

    Технические спецификации каждой Яндекс Станции.

-   :material-cog: **[Как это работает?](internals/architecture.md)**

    Прошивка quasar, сеть и порты, подводные камни, сборка своего софта.

</div>

## Модели

| Модель | Root и доступ |
|---|:---:|
| Лайт, Мини, Мини 2, Миди, Станция 2, Стрит, Умный хаб | ✅ проверено |
| Мини 3 (bergamot) | ✅ [retail CA и маркеры из factory](start/retail-ca-mini3.md) |
| Лайт 2 (Plum) | ✅ [retail CA из factory](start/retail-ca.md) |
| Станция 1-го поколения | ✅ [AliceBridge](start/root-android.md#station-1) |
| Станция Макс | ❌ Android |
| Станция 3 (orion) | ❌ [DNS-метод закрыт](devices/station-3.md#tls) |
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

Нашли что-то новое? Нажмите ✏️ вверху любой страницы и предложите правку. 
[Как дополнять вики?](contributing.md).

!!! warning "Только свои устройства"
    Модификация системных разделов может вывести колонку из строя. Не публикуйте
    персональные данные: ключи из `devices.json`, MAC-адреса, серийные номера, токены.
