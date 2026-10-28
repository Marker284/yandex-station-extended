# Debian на Станции 1 { #station1-debian }

Рецепт ставит на первую Станцию чистый **Debian 13 (trixie)** со своим ядром **Linux 7.3**,
собранным под это железо: рядом с Алисой или вместо неё. Ставится одной командой из Android
Станции; установщик проверяет каждый шаг, а удаление возвращает всё как было.

**Проверено на:** Яндекс Станция 1 (YNDX-0001, `tulip`), прошивка `2.369.5.46`, root через
[AliceBridge](../start/root-android.md#station-1) (`boot-root.img`), SSH в Android, выпуск
установщика `debian-v8`. На других моделях не проверялось и не запустится: ядро и установщик
сделаны под эту плату.

Исходники, выпуски и подробный гайд — в репозитории
[MyszkinPL/yandex-station-linux](https://github.com/MyszkinPL/yandex-station-linux)
([гайд](https://github.com/MyszkinPL/yandex-station-linux/blob/main/docs/INSTALL-DEBIAN.md),
[выпуски](https://github.com/MyszkinPL/yandex-station-linux/releases)).

## Что получается { #what }

- Debian 13 arm64: `apt`, SSH (dropbear), runit для своих служб, chrony, ALSA.
- Ядро 7.3 под Станцию: 4 ядра с DVFS 480–1152 МГц (через прошивку SCP), Wi-Fi и Bluetooth
  (AP6356S), оба усилителя TAS5751M, микрофоны, кнопки, сторожевой таймер.
- Сети Wi-Fi из Android Debian берёт сам. Без знакомой сети через 3 минуты поднимается своя
  открытая сеть «Станция-XXXX» со страницей настройки Wi-Fi.
- Изменения в Debian (пакеты, настройки) хранятся на флеше и переживают перезагрузку.

Алисы в Debian нет — это Android; голосовой помощник и музыка — что поставите сами.

## Требования { #requirements }

- Станция 1 (YNDX-0001) в сети Wi-Fi.
- Оболочка root в Android Станции с полными правами, например SSH после
  [AliceBridge](../start/root-android.md#station-1).
- Место: 400 МБ в `/cache` и 150 МБ в `/data`. Если в `/cache` лежит скачанное обновление
  Android (`update_*.zip`, ~600 МБ), установщик подскажет, как его удалить.

## Установка { #install }

1. Зайти по SSH в Android Станции под root.
2. Выполнить:

    ```sh
    curl -kfsSL https://github.com/MyszkinPL/yandex-station-linux/releases/latest/download/install.sh | sh
    ```

3. Дождаться проверки Станции: модель, root, разметка eMMC, прошивки Wi-Fi и усилителей,
   место, сеть, загрузчик. Если что-то не так, установщик ничего не меняет и показывает все
   найденные проблемы сразу, у каждой — что сделать.
4. На экране настроек выбрать нужное (цифра пункта, затем вариант) и нажать Enter:

    ```text
       1  Загрузка        Debian через Android — надёжно, ~3 мин после включения
       2  Вход по SSH     пароль — придумаю и покажу в конце
       3  Ещё сеть Wi-Fi  нет (Debian возьмёт сети, сохранённые в Android)
       4  Часовой пояс    Москва (МСК)

       Enter — установить    1–4 — изменить    q — выйти
    ```

5. Записать пароль root из рамки в конце (если выбран пароль, а не ключ): больше он нигде не
   показывается. Станция перезагрузится сама.
6. Зайти в Debian: `ssh root@<STATION_IP>` — адрес обычно тот же, что был в Android.

Без вопросов, одной строкой (флаги — после `sh -s --`):

```sh
curl -kfsSL https://github.com/MyszkinPL/yandex-station-linux/releases/latest/download/install.sh | sh -s -- install --yes --mode direct --key "ssh-ed25519 AAAA... me@pc"
```

Установщик остаётся в `/data/local/tmp/station-debian.run`; остальные команды — им же:
`sh /data/local/tmp/station-debian.run status` и т. д.

!!! tip "Строки `__bionic_open_tzdata_path`"
    Их печатает curl самого Android — безвредно. Если после вставки команды shell пишет
    `00~curl: not found`, терминал вставил служебные коды: открыть новое окно терминала
    или выполнить `printf '\033[?2004l'` и вставить команду снова.

## Режимы загрузки { #boot-modes }

| Режим | Как включается Станция | Android |
|---|---|---|
| Debian через Android (`--mode debian`) | Android, через ~2 мин держания Wi-Fi передаёт Станцию Debian; Debian в сети через ~3 мин после включения | остаётся основной системой |
| Debian сразу (`--mode direct`) | Debian из раздела boot, SSH через ~15 с | переезжает в recovery: кнопка Алисы 10 с или `station-android` в Debian, обратно — обычная перезагрузка Android |
| Android (`--mode android`) | Android с Алисой, как было | Debian — по команде `enter` |

Быструю загрузку установщик предлагает, только если boot0 и U-Boot совпадают с теми, на
которых она проверена (sha256 зашиты в установщик); иначе доступна обычная. Если Debian
трижды подряд не поднялся, первый код образа (до ядра) сам ставит в PMIC флаг загрузки
recovery и перезагружает Станцию в Android.

<a id="rollback"></a>

## Вернуться в Android и удалить { #uninstall }

Из Debian:

- `station-android` или кнопка Алисы 10 с — в Android (в режиме «через Android» он после
  этого остаётся в Android);
- `station-reboot` — перезагрузка.

Из Android (`sh /data/local/tmp/station-debian.run <команда>`):

| Команда | Что делает |
|---|---|
| `status` | что установлено и как прошла последняя загрузка Debian |
| `enter` | загрузить Debian сейчас |
| `access` | новый пароль root или ещё ключ, если старый потерян |
| `update` | новое ядро из выпуска этого установщика; Debian и его данные не трогает |
| `uninstall` | убрать всё: стоковый recovery, прежний boot (с root AliceBridge), `rc.local` |

## Что меняется на Станции { #changes }

- Раздел `recovery`: ядро Debian (стоковый сохраняется в `/data/local/station/backup/`).
- При быстрой загрузке ещё `boot`: там ядро Debian, прежний образ (в том числе
  `boot-root.img` AliceBridge) переносится в `recovery` и сохраняется в `backup/`.
- `/system/etc/rc.local`: одна строка запуска передачи в Debian;
  `/system/recovery-from-boot.p` переименовывается, чтобы Android не вернул стоковый recovery.
- `/cache/station/`: Debian и его изменения; `/data/local/station/`: установщик и журнал.
- Последние 4 МБ раздела `misc` (Android их не использует): журнал загрузки Debian.

Загрузчики (boot0, U-Boot) не трогаются. Каждая запись в раздел сверяется обратным чтением;
при сбое установщик возвращает прежнее содержимое.

## Как это работает { #how-it-works }

- Образ для `boota` — Android boot image, в котором вместо ядра лежит небольшой загрузчик
  (shim): он взводит сторожевой таймер, включает питание Wi-Fi (DLDO4 AXP803) и подменяет
  вендорский DTB на свой, затем передаёт управление ядру 7.3.
- Одноразовая загрузка `recovery` — флаг `0x10` в регистре `0x0F` AXP803; U-Boot сам
  сбрасывает его в `0x0E`. Из Android его ставит `echo 0f10 > axp81x_reg`.
- Прошивки Wi-Fi, Bluetooth и усилителей — файлы Яндекса: init при каждой загрузке копирует их
  из раздела `system` Android и сверяет с известными sha256, в образ они не входят.
- При быстрой загрузке счётчик неудачных загрузок хранится в регистре RTC `GP7`
  (`0x01F0011C`): boot0 читает только `GP0`–`GP5`, U-Boot, BL31, SCP и ядро Android `GP6`–`GP7`
  не трогают; при отключении питания счётчик сбрасывается.

Для своих программ (приложение, бот) у установщика есть режим `--machine`: строки `@...` на
stdout и коды выхода —
[INTEGRATION.md](https://github.com/MyszkinPL/yandex-station-linux/blob/main/docs/INTEGRATION.md).
