# Fastfetch с логотипом Алисы

Системный информер с логотипом Алисы, температурой CPU и строкой **USB OTG** для
подключённых дисков.

```text
root@yandex-station-lite
OS: Buildroot 2020.02.1 aarch64
Host: Yandex Station Micro v1.2
Kernel: Linux 4.9.68
CPU: axg (4) @ 1.20 GHz - 42.0°C
Memory: 107.36 MiB / 238.24 MiB (45%)
Disk (/): 52.57 MiB / 64.84 MiB (81%)
USB OTG: Burst Elite 240G · 223.6 GiB · USB 480 Mbit/s
       : ├ Ventoy  17.2 GiB / 100.0 GiB (17%) · exfat
       : └ DATA  4 MiB / 123.5 GiB (0%) · exfat
Local IP (wlan0): 192.168.1.120/24
```

## Установка

Статический `fastfetch` под `aarch64` — в [`contrib/bin/`](https://github.com/Marker284/yandex-station-extended/tree/main/contrib/bin):

```sh
adb push contrib/bin/fastfetch /data/opt/bin/fastfetch
adb shell chmod +x /data/opt/bin/fastfetch
```

## Логотип

`/data/opt/etc/fastfetch/yandexstation.txt` (`$1` — цвет из конфига):

```text
$1         @@@@@@@@@@
$1       @@@@@@@@@@@@@@
$1     @@@@@@@    @@@@@@@
$1    @@@@@@        @@@@@@
$1   @@@@@@           @@@@@
$1  @@@@@              @@@@@
$1 @@@@@                @@@@@
$1@@@@@                  @@@@@
$1@@@@                    @@@@
$1@@@@                    @@@@
$1@@@@                    @@@@
$1@@@@@@@@@          @@@@@@@@@
$1  @@@@@@@@@@@@@@@@@@@@@@@@@
$1     @@@@@@@@@@@@@@@@@@
```

## Конфиг

`/etc/fastfetch/config.jsonc` (rootfs: `mount -o remount,rw /`, после правки — `remount,ro`):

```jsonc
{
    "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
    "logo": {
        "type": "file",
        "source": "/data/opt/etc/fastfetch/yandexstation.txt",
        "color": { "1": "1;38;2;122;85;255" },   // фиолетовый Алисы #7A55FF
        "padding": { "top": 1 }
    },
    "modules": [
        "title", "separator", "os", "host", "kernel", "uptime", "packages", "shell", "terminal",
        { "type": "cpu", "temp": true },
        "memory",
        { "type": "disk", "folders": "/", "format": "{1} / {2} ({3})" },
        // строки USB OTG — нужен /data/otg/ff-usb.sh из рецепта USB Host
        { "type": "command", "key": "USB OTG", "keyColor": "38;2;122;85;255", "text": "/data/otg/ff-usb.sh 1" },
        { "type": "command", "key": "       ", "text": "/data/otg/ff-usb.sh 2" },
        { "type": "command", "key": "       ", "text": "/data/otg/ff-usb.sh 3" },
        { "type": "command", "key": "       ", "text": "/data/otg/ff-usb.sh 4" },
        "localip", "break", "colors"
    ]
}
```

Строки `USB OTG` работают со скриптом из рецепта [USB Host](usb-host.md). Без него их можно
удалить: модули `command`, которые завершились с ошибкой, fastfetch не показывает.

Запуск: `fastfetch`.

## Откат { #rollback }

```sh
rm /data/opt/bin/fastfetch
rm -rf /data/opt/etc/fastfetch
```

Строки `USB OTG` из конфига удаляются вместе с ним; если конфиг нужен, уберите из
`modules` только пункты `command`.
