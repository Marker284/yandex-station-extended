# Устройства

Раздел с разбором конкретных моделей Станций: SoC, карта флеша, I2C-периферия,
индикация, звук и всё, что специфично именно для железа модели. Общие для всех
Amlogic-станций механизмы (прошивка, доступ, сеть) вынесены в раздел
[Как это устроено](../internals/architecture.md).

## Две аппаратные платформы

Прежде чем смотреть матрицу — важно: Станции делятся как минимум на два мира,
и приёмы модификации у них разные.

| Платформа | SoC | CPU / ядро | Прошивка | Примеры |
|---|---|---|---|---|
| **Amlogic A1 / Buildroot** | Amlogic A1 | Cortex-A35, **32-бит**, Linux 5.15 | нативный `maind` | Стрит (Mango) |
| **Amlogic AXG / Buildroot** | Amlogic AXG (A113) | Cortex-A53, Linux 4.9 | нативный `maind` | Лайт, Мини, Мини 2, Станция 2 |
| **Amlogic A5 / Buildroot** | Amlogic A5 | Cortex-A55 до 2 ГГц, Linux 5.4 | нативный `maind` | Миди (Cucumber) |
| **Amlogic A4 / Buildroot** | Amlogic A4 | Cortex-A53 до 2 ГГц, Linux 5.4, NAND+UBI | нативный `maind` | Мини 3 Про (Pickle) |
| **Amlogic / Android 9** | Amlogic (TV-класс) | Cortex-A53 @1.8 ГГц, Android 9 | quasar как APK | Станция Макс |
| **MediaTek MT8516 / Yocto** | MediaTek MT8516 (MT8167) | Cortex-A35, **32-бит**, Linux 4.4, NAND+UBI | `maind` на Yocto + systemd | JBL Link Music |
| **Allwinner / Android** | Allwinner R18 (sun50iw1) | Cortex-A53, Android 6 | quasar как APK | Станция (1 пок) |

Раздел [«Как это устроено»](../internals/architecture.md) описывает преимущественно
**Amlogic/Buildroot** (maind, `gst-launch`, init.d) — применимо ко всем
Amlogic-поколениям (с поправкой на версию ядра; Стрит вдобавок 32-битная). Общее для
всех миров — протокол [glagol](../internals/network.md#glagol) (`:1961`).

## Матрица поддержки { #support-matrix }

| Модель | Кодовое имя (DT) | SoC | Статус | Страница |
|---|---|---|---|---|
| Станция Лайт | `Yandex Station Micro v1.2` | Amlogic AXG (A113) | ✅ подробно | [Лайт](station-lite.md) |
| Станция Лайт 2 | `plum` | Amlogic AXG (A113X) | ✅ разобрана | [Лайт 2](station-lite2.md) |
| Станция Мини 2 | `yandex,station-mini2` | Amlogic AXG | ✅ разобрана | [Мини 2](station-mini2.md) |
| Станция Мини (1 пок) | `amlogic, axg` | Amlogic AXG | ✅ разобрана | [Мини](station-mini.md) |
| Станция Миди | `yandex,cucumber-dvt2` | Amlogic A5 (A55) | ✅ разобрана | [Миди](station-midi.md) |
| Станция 2 | `yandex,station-midi` ⚠️ | Amlogic AXG | ✅ разобрана | [Станция 2](station-2.md) |
| Станция Стрит | `Yandex Station Mango DVT` | Amlogic A1 (A35, 32-бит) | ✅ разобрана | [Стрит](station-street.md) |
| Станция Макс | `yandexstation_2` ⚠️ | Amlogic + Android 9 | ✅ разобрана | [Макс](station-max.md) |
| Станция (1-го поколения) | `tulip-d1` | Allwinner R18 (sun50iw1) | ✅ разобрана | [Станция gen1](station-gen1.md) |
| Умный хаб Яндекса (не колонка) | `yandex,saturn` | Amlogic AXG | ✅ разобран | [Умный хаб](yandex-hub.md) |
| Станция Мини 3 | `yandex,station-mini3` (bergamot) | Amlogic AXG | ✅ разобрана | [Мини 3](station-mini3.md) |
| Станция Мини 3 Про | `yandex,pickle-evt` (pickle) | Amlogic A4 (A53) | ✅ разобрана | [Мини 3 Про](station-mini3-pro.md) |
| JBL Link Music (с Алисой) | `mediatek,mt8167` | MediaTek MT8516 (A35, 32-бит) | ✅ разобрана | [JBL Link Music](jbl-link-music.md) |
| Станция 3 | ? (`platform=orion`) | ? | 🌐 только сеть, без root | [Станция 3](station-3.md) |
| Станция Дуо Макс | ? | ? | ⏳ нужны данные | — |
| Станция Про | ? | ? | ⏳ нужны данные | — |

⚠️ **Кодовые имена Яндекса перекрещены**, ориентируйтесь на SoC/ОС:

- `yandex,station-midi` (DT) = розничная **Станция 2** (Buildroot/AXG) — **не** «Миди»;
- розничная **Станция Миди** = кодовое имя **Cucumber** (`yandex,cucumber`, A5);
- `yandexstation_2` (Android `ro.product.device`) = розничная **Станция Макс** — **не**
  «Станция 2».

!!! note
    Прочерки — это приглашение дополнить. Минимальный набор для новой модели:
    вывод `uname -a`, `cat /proc/device-tree/model`, `cat /proc/mtd`,
    `cat /proc/cpuinfo`, список I2C (`/sys/bus/i2c/devices`), версия quasar
    (`/system/vendor/quasar/VERSION`). Формат — см. [Как дополнять](../contributing.md).

## Что считать «специфичным для модели»

В страницу устройства идёт то, что отличается между моделями:

- SoC и ревизия, частоты CPU, объём ОЗУ;
- карта разделов флеша (`/proc/mtd`, UBI);
- I2C-периферия: усилитель, LED-драйвер/экспандер, сенсоры касания;
- схема индикации (сколько LED-зон, как адресуются);
- звуковой тракт (ЦАП/усилитель, микрофоны, частоты);
- физические кнопки и сенсоры.

Всё, что одинаково на уровне прошивки (как включается ADB, как работает OTA,
`gst-launch`, glagol, сборка софта), — в [«Как это устроено»](../internals/architecture.md).
