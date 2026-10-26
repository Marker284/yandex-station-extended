<div align="center">

<img src="docs/assets/images/logo.png" alt="Yandex Station Extended" width="140">

# Yandex Station Extended

**Открытая вики о том, как получить доступ к умным колонкам Яндекса и что с ними делать дальше**

[![Сайт](https://img.shields.io/badge/%D0%B2%D0%B8%D0%BA%D0%B8-hackalice.me-7a55ff?style=for-the-badge&logo=materialformkdocs&logoColor=white)](https://hackalice.me)
[![Telegram](https://img.shields.io/badge/%D1%87%D0%B0%D1%82-@hackalice-26a5e4?style=for-the-badge&logo=telegram&logoColor=white)](https://t.me/hackalice)

[![Deploy](https://img.shields.io/github/actions/workflow/status/Marker284/yandex-station-extended/deploy.yml?branch=main&label=deploy&logo=githubactions&logoColor=white)](https://github.com/Marker284/yandex-station-extended/actions/workflows/deploy.yml)
[![Last commit](https://img.shields.io/github/last-commit/Marker284/yandex-station-extended?label=%D0%BE%D0%B1%D0%BD%D0%BE%D0%B2%D0%BB%D0%B5%D0%BD%D0%BE)](https://github.com/Marker284/yandex-station-extended/commits/main)
[![Contributors](https://img.shields.io/github/contributors/Marker284/yandex-station-extended?label=%D1%83%D1%87%D0%B0%D1%81%D1%82%D0%BD%D0%B8%D0%BA%D0%B8)](https://hackalice.me/contributors/)
[![PRs welcome](https://img.shields.io/badge/PR-welcome-brightgreen)](CONTRIBUTING.md)
[![Stars](https://img.shields.io/github/stars/Marker284/yandex-station-extended?style=flat&label=%E2%98%85)](https://github.com/Marker284/yandex-station-extended/stargazers)

</div>

---

Яндекс Станции внутри — обычный Linux. Здесь собрано всё, что сообщество узнало о них: как
получить root без разборки, закрепить доступ и отключить обновления. Ещё — как поставить свой
софт и подключить USB-периферию, и как устроены прошивка, сеть и железо каждой модели.

<div align="center">

**⭐ Пригодилось? Поставьте звезду — это мотивирует вести проект дальше.**

</div>

> [!IMPORTANT]
> Пошаговые инструкции живут **на сайте — [hackalice.me](https://hackalice.me)**. Этот README —
> только витрина. Всё описанное — для **своих** устройств.

## Что можно сделать

- 🔓 **[Получить root](https://hackalice.me/start/#root-by-model)** — у каждой модели свой способ:
  DNS-метод, правка CA из factory mode, ADB по USB, приложение для Android.
- 🔐 **[SSH и защита от обновлений](https://hackalice.me/start/ssh/)** — чтобы доступ не пропал.
- 📦 **[Пакеты](https://hackalice.me/start/packages/)** — `yse` (Entware и `.yap`),
  [YAM](https://hackalice.me/recipes/yam/) с веб-панелью и Lua-плагинами.
- 🔌 **[USB Host](https://hackalice.me/recipes/usb-host/)** — флешки, USB-Ethernet, наушники и ЦАП.
- 🎵 **[AirPlay](https://hackalice.me/recipes/airplay/)**, [свои звуки](https://hackalice.me/recipes/sounds/),
  [подсветка](https://hackalice.me/recipes/led/), [своя LLM вместо Алисы](https://hackalice.me/recipes/llm/).
- 🧩 **[Железо моделей](https://hackalice.me/devices/)** — SoC, разделы флеша, I2C, звук, индикация.
- ⚙️ **[Как это устроено](https://hackalice.me/internals/architecture/)** — прошивка quasar,
  сеть и порты, голосовой тракт Алисы, сборка своего софта.

## Модели

| Модель | Root | Подробнее |
|---|:---:|---|
| **Мини 1 (2019)** | ✅ | [Root и ADB по USB — инструкция](docs/start/root-mini1-usb.md) |
| Лайт, Мини 2, Миди, Станция 2, Стрит, Умный хаб | ✅ | [DNS-метод](https://hackalice.me/start/root/) |
| Мини 3 | ✅ | [retail CA и маркеры](https://hackalice.me/start/retail-ca-mini3/) |
| Лайт 2 | ✅ | [retail CA из factory](https://hackalice.me/start/retail-ca/) |
| Станция 1-го поколения | ✅ | [AliceBridge](https://hackalice.me/start/root-android/#station-1) |
| JBL Link Music (с Алисой) | ✅ | [ADB по USB на старте](https://hackalice.me/start/root-jbl-link-music/) |
| Мини 3 Про | 🟡 | [только закрепление доступа](https://hackalice.me/devices/station-mini3-pro/) |
| Станция 3 | ❌ | [DNS-метод закрыт](https://hackalice.me/devices/station-3/) |
| Станция Макс | ❌ | [Android-платформа](https://hackalice.me/devices/station-max/) |

Актуальная таблица — на сайте: [какой способ для вашей колонки](https://hackalice.me/start/#root-by-model).
Нет вашей модели? [Пришлите данные](https://github.com/Marker284/yandex-station-extended/issues/new/choose).

## Что в репозитории

```text
docs/          страницы вики (Markdown) — сайт hackalice.me собирается отсюда
  start/       получение root, SSH, пакеты, восстановление
  recipes/     рецепты: USB, AirPlay, YAM, LLM…
  devices/     страницы моделей
  internals/   прошивка, сеть, сборка софта
contrib/       скрипты и статические бинарники для колонок (описание — contrib/README.md)
mkdocs.yml     навигация и настройки сайта (MkDocs Material)
```

## ⭐ Поддержите звездой

Если вики пригодилась — **поставьте звезду репозиторию** (кнопка ★ Star вверху страницы).
Проект ведут энтузиасты в свободное время, и каждая звезда показывает, что он нужен. Это
лучшая мотивация продолжать: разбирать новые модели, искать способы root и дописывать
инструкции.

## Как помочь

Вики пишет сообщество — нашли что-то новое, исправили ошибку или разобрали новую модель?

- ✏️ Самое простое: на любой странице сайта нажмите карандаш и предложите правку прямо
  в браузере.
- 🛠️ Правила оформления, локальная сборка и как писать PR —
  в **[CONTRIBUTING.md](CONTRIBUTING.md)**.
- 🐞 Данные о модели или ошибка в инструкции —
  [issue](https://github.com/Marker284/yandex-station-extended/issues/new/choose).
- 💬 Находки, новости и обсуждение — [@hackalice](https://t.me/hackalice) в Telegram.

Все, чьи правки вошли в вики, — на странице **[Участники](https://hackalice.me/contributors/)**.

## Дисклеймер

Проект неофициальный и не связан с ООО «Яндекс». Модификация прошивки может лишить гарантии
и вывести колонку из строя — всё на свой риск и только со своими устройствами. Не публикуйте
ключи, токены, MAC-адреса и серийные номера.
