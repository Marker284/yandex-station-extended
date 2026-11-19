# СберПортал (stargate)

Умный дисплей Сбера с экраном, микрофонами и камерой на **Android 9 (StarOS)**.
К семейству Яндекс Станций не относится, но после получения root на него ставится
**Centaur** — лаунчер Яндекс Станции и набор сервисов Яндекса, и портал начинает
работать как **Станция Дуо Макс**: «Алиса», музыка и ответы на экране.

Пошаговый рецепт — [СберПортал → Яндекс Станция](../recipes/sberportal-centaur.md),
исходники и инструменты — в репозиториях
[sber-portal/sberportal](https://github.com/sber-portal/sberportal),
[sber-portal/sberportal-root](https://github.com/sber-portal/sberportal-root) и
[sber-portal/sberportal-centaur](https://github.com/sber-portal/sberportal-centaur).

## Платформа в двух словах { #platform }

| Что | Значение |
|---|---|
| Внутр. имя | `stargate` |
| Производитель | Сбер (SberDevices), не Яндекс |
| ОС | **StarOS** на базе **Android 9** (SDK 28), сборка `1.102.34` |
| SoC | **Amlogic A311D** (G12B), 4× Cortex-A73 + 2× Cortex-A53, Mali-G52 |
| Ядро | Linux **4.9.268** aarch64 |
| Хранилище | eMMC, два слота `_a` / `_b`, активный `_b` |
| Безопасность | **AVB 1.1 + dm-verity enforcing + SELinux enforcing** |
| Загрузчик | U-Boot, заблокирован, среда в разделе `env` (8 МБ, `mmcblk0p4`) |
| ADB | по сети, `:5555`, включается в кабинете разработчика Сбера |
| Приложения | 32-битные (`armeabi-v7a`) при 64-битном ядре |

## Что работает { #features }

| Что | Состояние | Где описано |
|---|---|---|
| Root | работает: эксплойт Mali **CVE-2022-38181** | [sberportal-root](https://github.com/sber-portal/sberportal-root) |
| Постоянный root после перезагрузки | работает: правка `preboot` в U-Boot env | [sberportal-root](https://github.com/sber-portal/sberportal-root) |
| Centaur и «Алиса» | работает: Centaur 4.16.1, `armeabi-v7a` | [рецепт](../recipes/sberportal-centaur.md) |
| Подавление ассистента Сбера | работает | [sberportal-centaur](https://github.com/sber-portal/sberportal-centaur) |
| Блокировка OTA прошивки | работает | [sberportal-centaur](https://github.com/sber-portal/sberportal-centaur) |
| SSH | не проверялось | — |
| USB Host | не проверялось | — |
| AirPlay | не проверялось | — |
| Spotify Connect | не проверялось | — |
| Подсветка | не проверялось | — |
| Свои звуки | не проверялось | — |

## Получение root { #root }

`adb root` на заводской прошивке не работает: adbd собран как production и
сбрасывает привилегии. Root ставится в два приёма:

1. **Одноразовый пролёт эксплойтом** CVE-2022-38181 (ошибка в Mali shrinker)
   даёт `uid=0` в домене `shell` при SELinux permissive.
2. **Правка среды U-Boot**: в переменную `preboot` добавляются два аргумента
   ядра.

    ```text
    androidboot.selinux=permissive
    androidboot.rabbith.adb_root=1
    ```

    Вендорский механизм rabbith в adbd после этого разрешает `adb root` всегда.
    Системные разделы и vbmeta не меняются, AVB и dm-verity остаются целыми.

После этого ставится APK авто-root, и `adb root` работает сразу после загрузки.
Эксплойт нужен только для первой записи env — после OTA правку приходится
повторять. Команды, скрипты и разбор — в
[sberportal-root](https://github.com/sber-portal/sberportal-root).

!!! warning "Эксплойт флаки"
    При неудаче ядро может уйти в перезагрузку. Скрипт просто повторяют — на
    второй-третий прогон срабатывает.

## Чем отличается { #differences }

- **Это не Buildroot и не YaOS.** StarOS — Android 9 со своей оболочкой, но без
  сервисов Яндекса. Centaur здесь не обновляется системой: он ставится обычным
  APK с debug-подписью, потому что подписей Яндекса на устройстве не было.
- **Закрытая загрузка**, как у [Станции Макс](station-max.md): AVB 1.1 и
  dm-verity на системных разделах. Пересобрать системный раздел нельзя, поэтому
  root держится на среде загрузчика, а не на правке rootfs.
- **Два слота A/B.** Обновления Sber приходят на неактивный слот; после
  перезагрузки активный меняется. Поэтому блокировка OTA — часть рецепта, а не
  необязательный шаг.
- **32-битные приложения.** Centaur 3.x для Дуо Макс (Android 11, arm64) на
  портал не ставится: нужна последняя 32-битная сборка 4.16.1.

## Разделы флеша { #partitions }

Разметка eMMC (по `by-name`):

```text
p19 vendor_a    p20 vendor_b    1204 МБ
p21 system_a    p22 system_b     800 МБ   активный слот _b, корень dm-0 "vroot"
p23 sdvtz_a     p24 sdvtz_b      300 МБ   StarOS, SquashFS
p25 data        p26 dt_sdsr … p31 cache
```

Отдельного `boot`-раздела с ядром в привычном виде нет: ядро и загрузчик живут
в `boot`/`bootloader` и не трогаются. Среда U-Boot лежит в `env`
(`mmcblk0p4`): формат `crc32(LE, 4 байта) + data`, `CONFIG_ENV_SIZE=0x10000`
(64 КБ), валидная копия одна, в нулевом смещении.

## ПО: StarOS { #software }

Оболочка Сбера:

| Пакет | Что это |
|---|---|
| `ru.sberdevices.assistant` | ассистент Сбера |
| `ru.sberdevices.music` | СберЗвук |
| `ru.sberdevices.app.starkeyboard` | штатная клавиатура |
| `ru.sberdevices.services` | сервис платформы, persistent |

Сервис платформы **нельзя отключать**: `pm disable-user` приводит к бесконечной
перезагрузке. Микрофон ему закрывают через
`cmd appops set ru.sberdevices.services RECORD_AUDIO deny` — этого достаточно,
чтобы Сбер не отвечал.

После установки Centaur штатный ассистент и СберЗвук отключаются, HOME
переназначается на Centaur, а яркость и шторка обрабатываются обвязкой из
[sberportal-centaur](https://github.com/sber-portal/sberportal-centaur).

## Что ещё проверить { #todo }

- Шина I2C и периферия: усилитель, LED-кольцо, датчик света.
- Звуковой тракт: сколько микрофонов, какой ЦАП и усилитель.
- Точный объём ОЗУ и частоты CPU.
- USB Host и внешние накопители.
- Поведение после заводского сброса: какие шаги рецепта нужно повторять.
