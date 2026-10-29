# Шаг 1. Root на JBL Link Music: ADB по USB на старте

Способ для **[JBL Link Music с Алисой](../devices/jbl-link-music.md)**. При включении
колонка на несколько секунд поднимает ADB по USB с правами root, а затем `maind` его
отключает. В это окно с компьютера пишутся маркеры, после которых ADB работает **по сети**
(порт `5555`) и переживает перезагрузку. Разбирать колонку и менять прошивку не нужно.

Проверено на прошивке `1.80.0.228.3676124705.20251219`.

!!! warning "ADB по сети — root без пароля"
    Порт `5555` открыт для всех в вашей сети, и любой, кто к нему подключится, получит root.
    Держите колонку только в доверенной сети.

## Как это работает

- **USB.** При старте ядро включает USB-гаджет `rndis,adb` (`VID_0E8D&PID_2005`).
  `android-tools-adbd.service` запускает `adbd` после `sleep 4`. Параллельно стартует
  `maind` и через 5–10 секунд выключает гаджет:
  `echo 0 > /sys/class/android_usb/android0/enable`.
- **Защита от отключения.** Скрипт `activate_adb.sh` не трогает ADB, если есть файл
  `/tmp/lock_activated_adb`. Если успеть его создать, USB-ADB остаётся до перезагрузки.
- **Сеть.** При запуске `adbd` проверяет `/data/network_adb`. Есть файл — слушает TCP `5555`,
  нет — работает только по USB (FunctionFS `/dev/usb-ffs/adb`). `/data` — UBIFS на NAND,
  смонтирован `rw,sync`, поэтому маркер сохраняется.

## Что понадобится

- кабель **Micro-USB с линиями данных** — кабель «только для зарядки» не подойдёт;
- компьютер с утилитой `adb`, например из
  пакета [Platform Tools](https://developer.android.com/tools/releases/platform-tools);
- доступ к розетке колонки: питание придётся передёрнуть.

## 1. Подключите кабель

1. Снимите круглую резиновую подложку на дне колонки.
2. В углублении найдите сервисный разъём Micro-USB.
3. Подключите кабель к колонке и к компьютеру. Колонку пока можно не выключать.

## 2. Запустите ожидание на компьютере

Команда ждёт, пока колонка появится по USB, и сразу выполняет на ней payload:

```sh
adb wait-for-usb-device shell "\
  touch /tmp/lock_activated_adb && \
  mkdir -p /data/quasar && \
  touch /data/network_adb \
        /data/quasar_activate_adb \
        /data/quasar_activate_network_adb \
        /data/quasar/activate_network_adb \
        /data/quasar/activate_adb_quasmodrom && \
  sync && id"
```

Команда одинакова для Linux, macOS, Windows (cmd и PowerShell). Что она делает:

- `/tmp/lock_activated_adb` — не даёт `maind` выключить USB-ADB до перезагрузки;
- `/data/network_adb` — включает ADB по сети, главный маркер;
- остальные файлы — маркеры ADB, которые проверяют скрипты quasar на других моделях.
  Оставлены как в исходной инструкции, на JBL их роль отдельно не проверялась.

??? note "Вариант на Python"
    Исходная версия способа — скрипт `usb_catcher.py`. Он запускает ту же команду и
    проверяет, что в ответе есть `uid=0(root)`:

    ```python
    import subprocess

    payload = (
        "touch /tmp/lock_activated_adb && "
        "mkdir -p /data/quasar && "
        "touch /data/quasar_activate_adb && "
        "touch /data/network_adb && "
        "touch /data/quasar_activate_network_adb && "
        "touch /data/quasar/activate_network_adb && "
        "touch /data/quasar/activate_adb_quasmodrom && "
        "sync && id"
    )
    print("[*] Waiting for the speaker on USB...", flush=True)
    proc = subprocess.run(["adb", "wait-for-usb-device", "shell", payload],
                          capture_output=True, text=True)
    print(proc.stdout, proc.stderr)
    if "uid=0(root)" in proc.stdout:
        print("[+] Root shell reached, markers written to NAND.")
    ```

## 3. Передёрните питание

1. Выньте блок питания колонки из розетки на 5 секунд.
2. Включите обратно.
3. Как только появится USB-устройство, `adb` выполнит команду. Успех выглядит так:

    ```text
    uid=0(root) gid=0(root)
    ```

Если команда так и ждёт, проверьте кабель (нужен с данными) и `adb devices`. На Windows
устройство `VID_0E8D&PID_2005` должно появиться в диспетчере устройств как ADB-интерфейс;
если оно без драйвера, установите ADB-драйвер и повторите.

## 4. Закрепите маркеры

USB-ADB работает до перезагрузки. Пока он есть, защитите маркеры от удаления скриптами
прошивки атрибутом `immutable`:

```sh
adb shell
chattr +i /data/network_adb /data/quasar_activate_adb
chattr +i /data/quasar/activate_network_adb /data/quasar/activate_adb_quasmodrom
sync
exit
```

Снять защиту — `chattr -i <файл>`.

## 5. Проверьте ADB по сети

1. Отключите кабель и верните подложку на место — USB больше не нужен.
2. Передёрните питание ещё раз.
3. Подключитесь по сети (IP колонки — в настройках роутера):

    ```sh
    adb connect <IP>:5555
    adb -s <IP>:5555 shell id   # uid=0(root) gid=0(root)
    ```

## Обновления

Обновление прошивки может закрыть этот способ. Готового способа отключить обновления
для JBL пока нет: [`yandex-noupdate.sh`](ssh.md#kill-ota) рассчитан на Станции с Buildroot,
а здесь Yocto с systemd и корнем `ro`.

- Блокировать домен `quasar.yandex.net` целиком нельзя: через него работает и сама Алиса.
- Подменить DNS-фильтром (AdGuard, Pi-hole) только ответ на `GET /check_updates`
  (`{"hasUpdate": false}`) не получится: запрос идёт по HTTPS, а DNS видит только имя хоста.

Если найдёте рабочий способ — [дополните](../contributing.md).

## Что дальше

- **SSH и пакеты.** Ядро и userspace здесь 32-битные (`armv7l`). Сборки под `aarch64` не
  запустятся, в том числе [`.yap`](packages.md#yap) и [YAM](../recipes/packagemanagers.md). Нужны
  сборки под ARMv7: Entware `armv7sf-k3.2`, а `dropbear` из `contrib/bin` (armhf) стоит проверить.
- **Железо и разделы** — на [странице модели](../devices/jbl-link-music.md).
