# YAM и BetterYAM: плагины и Web UI

[YAM](https://github.com/nyakokitsu/yam) (Y Application Manager) — менеджер пакетов `.yap`
с веб-панелью для колонки. На колонке работает демон `yamd`. Он ставит пакеты, запускает
Lua-скрипты и бинарники и даёт им доступ к железу: подсветке, громкости, датчикам, кнопкам,
часам и IPC Алисы. На компьютере — CLI `yam`, который ходит в API демона по сети.

[BetterYAM](https://github.com/Yandex-Station-Universal-Repo/BetterYAM/) —
форк YAM с отдельным демоном под каждую модель и более гибким Api. [Подробнее](#betteryam).

Оба проекта — сторонние и быстро меняются. Здесь описано состояние на YAM **0.1.15** и
BetterYAM **0.1.22** (октябрь 2026). Если что-то разошлось, смотрите `docs/` в их репозиториях.

!!! warning "Web UI и API без пароля"
    Панель на порту `8099` не спрашивает пароль. Любой в вашей сети может ставить пакеты, а
    с включёнными бинарниками — запускать на колонке свой код от root. Держите колонку только
    в доверенной сети и не пробрасывайте `8099` наружу.

## Что нужно

- root и ADB на колонке — см. [Получение root](../start/index.md#root-by-model);
- компьютер с `adb`: Windows 10/11 x64, Linux x86_64 или Mac на Apple Silicon;
- колонка с 64-битным ядром (`uname -m` = `aarch64`). На Станции Стрит ядро 32-битное
  (`armv7l`), [YAM](https://github.com/nyakokitsu/yam) демон ёё не найдет, в [BetterYAM](https://github.com/Yandex-Station-Universal-Repo/BetterYAM/) заявлена поддержка aarach32 демона.

## Установка

=== "Windows"

    1. Поставьте `adb`. Проще всего через winget:

        ```powershell
        winget install Google.PlatformTools
        ```

        Или вручную: скачайте
        [Platform Tools](https://developer.android.com/tools/releases/platform-tools),
        распакуйте, например, в `C:\platform-tools` и добавьте эту папку в `Path`
        («Параметры → Система → О системе → Дополнительные параметры системы →
        Переменные среды»). Откройте **новое** окно PowerShell и проверьте `adb version`.
        Установщик ищет `adb` в `Path`. Без него CLI поставится, но `yamd` на колонку
        не попадёт.

    2. Подключите колонку по ADB:

        ```powershell
        adb connect 192.168.xxx.xxx:5555   # IP вашей колонки
        adb devices                      # должна быть строка «192.168.xxx.xxx:5555  device»
        ```

        Если колонка не подключена, установщик сам спросит IP.

    3. Запустите установщик в обычном PowerShell, права администратора не нужны:

        ```powershell
        irm https://hackalice.me/install.ps1 | iex
        ```

        CLI ставится в `%LOCALAPPDATA%\YAM\bin`, папка добавляется в `Path`, а адрес
        колонки сохраняется в переменной `YAM_URL`.

    4. Проверьте: в том же окне `yam` работает сразу, в новых окнах — тоже.

        ```powershell
        yam device
        yam install nano
        ```

        Веб-панель — `http://192.168.xxx.xxx:8099` в браузере.

    Конкретная версия и удаление CLI:

    ```powershell
    & ([scriptblock]::Create((irm https://hackalice.me/install.ps1))) -Version 0.1.13
    & ([scriptblock]::Create((irm https://hackalice.me/install.ps1))) -Uninstall
    ```

    `-Uninstall` в Windows-установщике удаляет только CLI на компьютере. `yamd` с колонки
    уберите вручную:

    ```powershell
    adb shell "kill `$(cat /data/quazar/yam/yamd.pid); rm -rf /data/quazar/yam"
    ```

=== "Linux / macOS"

    Нужен Linux x86_64 или Mac на Apple Silicon. Linux на ARM и Mac на Intel установщик
    не поддерживает.

    ### YAM

    1. Поставьте `adb`: `sudo apt install adb` (Debian/Ubuntu),
       `brew install android-platform-tools` (macOS) или
       [Platform Tools](https://developer.android.com/tools/releases/platform-tools).
    2. Подключите колонку: `adb connect <IP>:5555`, затем `adb devices`.
    3. Запустите установщик:

        ```sh
        curl -fsSL https://hackalice.me/install.sh | sh
        ```

    4. Проверьте `yam device` и откройте `http://<IP колонки>:8099`.

    CLI ставится в `~/.local/bin/yam`. Если команда не находится, добавьте папку в `PATH`:
    `export PATH="$HOME/.local/bin:$PATH"` в `~/.bashrc` или `~/.zshrc`.

    Конкретная версия и удаление (CLI и `yamd` на колонке):

        ```sh
        curl -fsSL https://hackalice.me/install.sh | sh -s -- 0.1.13
        curl -fsSL https://hackalice.me/install.sh | sh -s -- --uninstall
        ```

    ### BetterYAM

    BetterYAM устанавливается поверх YAM и использует ту же систему подключения через `adb`.

    Установка:

        ```sh
        curl -fsSL https://hackalice.me/install.sh | sh -s -- --betteryam
        ```

    После установки проверить состояние можно через:

        ```sh
        yam device
        ```

    BetterYAM поддерживает плагины устройств, поэтому разработчики могут добавлять
    собственные модели и реализовывать для них дополнительную функциональность без
    изменения ядра проекта.

Что делает установщик:

1. Находит колонки в `adb devices` с `aarch64`. Если их несколько — спрашивает номер, если
   ни одной — спрашивает IP и подключается к `<IP>:5555`.
2. Скачивает последний релиз и сверяет SHA-256 с `SHA256SUMS` из того же релиза.
3. Ставит CLI на компьютер и запоминает адрес колонки (`YAM_URL=http://<IP>:8099`).
4. Копирует демон в `/data/quazar/yam( или betteryam)/bin` и запускает его.

### Автозапуск после перезагрузки { #autostart }

Установщик [YAM](https://github.com/nyakokitsu/yam) запускает `yamd` один раз через `start-stop-daemon` и в автозапуск его **не
добавляет**: после перезагрузки колонки демон не поднимется. Можно повторить установку или
добавить скрипт по образцу [автозапуска SSH](../start/ssh.md). Пример ниже на колонке не
проверялся; на Мини 3 Про корень после перезагрузки откатывается, там такой способ не
сработает (см. [её страницу](../devices/station-mini3-pro.md)).

**BetterYAM:** [BetterYAM](https://github.com/Yandex-Station-Universal-Repo/BetterYAM/) создает скрипт автозапуска для своего демона в init. Способ автозапуска зависит от устройства и от того,
сохраняются ли изменения в корневой файловой системе после перезагрузки.

## Создание автозапуска для YAMd
```sh
adb shell
mount -o remount,rw /
cat > /etc/init.d/S99zyam <<'EOF'
#!/bin/sh
# Autostart yamd on :8099 (delete this file to remove).
P=/data/quazar/yam
case "$1" in
  start)
    [ -x "$P/bin/yamd" ] || exit 0
    start-stop-daemon --start --background --make-pidfile --pidfile "$P/yamd.pid" \
      --startas "$P/bin/yamd" -- --data-dir "$P/data" ;;
  stop) killall yamd 2>/dev/null ;;  # pid changes after a self-update
esac
exit 0
EOF
chmod +x /etc/init.d/S99zyam
sync; mount -o remount,ro /
```

## Пакеты

`.yap` — ZIP или `tar.gz` с `plugin.toml` в корне. Бывают двух видов:

- **Lua** — скрипт, которому доступен API колонки: подсветка, громкость, датчики, голосовые
  команды. Работает сразу.
- **binary** — обычная программа. Нужна сборка под колонку (обычно AArch64 musl). Бинарники
  по умолчанию **запрещены**: включите «Разрешить бинарники плагинов» в настройках Web UI.

По режиму запуска пакет — `oneshot` (запустился, отработал, вывод сразу в терминал) или
`service` (работает в фоне и поднимается заново после перезапуска `yamd`).

Без аргументов `yam install` берёт пакеты из реестра
[yapkg](https://github.com/nyakokitsu/yapkg) — того же, что использует
[`yse`](../start/packages.md#yap). Другой реестр задаётся `--registry` или `YAM_REGISTRY_URL`.

```sh
yam install nano                 # последняя версия из реестра
yam install nano 8.0             # конкретная версия
yam install ./package.yap        # локальный архив (или через Web UI)
yam list                         # установленные пакеты
yam enable zip                   # включить (без этого oneshot не запустится)
yam run zip --help               # запустить oneshot с аргументами
yam tui nano                     # интерактивная программа через ADB-терминал
yam service enable sensor-agent  # включить фоновый пакет и запустить
yam service logs sensor-agent
yam service restart sensor-agent
yam service disable sensor-agent # остановить и убрать из автозапуска yamd
yam rm nano
```

Прямой доступ к железу без пакетов:

```sh
yam device                       # модель, архитектура и возможности (features)
yam sensors                      # датчики: свет, температура, батарея
yam led set '#4285F4' '#EA4335' '#FBBC05'
yam led off
yam logo set ...                 # логотип Миди, 6 цветов
yam clock status                 # сегментные часы, где они есть
```

Пакеты из apkg-репозиториев (например,
[initialfox/yandex-station-repo](https://github.com/initialfox/yandex-station-repo))
переводятся в `.yap` скриптом `tools/convert_apkg.py` из репозитория YAM.

## Модели и подсветка

Модель `yamd` определяет по подсветке в `/sys/class/leds`, а затем по device-tree. Подсветка
из коробки:

| Профиль | Модель | Светодиодов |
| --- | --- | --- |
| `micro` | Станция Лайт | 3 |
| `plum` | Станция Лайт 2 | 3 |
| `mini2` | Станция Мини 2 | 6 |
| `midi` | Станция Миди | 24 (кольцо) + логотип |
| `sysfs-ring`, `custom` | другие — вручную, по шаблону пути в sysfs | — |

Остальные возможности (громкость через `amixer`, звук через `aplay`, Bluetooth, кнопки
`/dev/input`, датчики) включаются, если найдены на колонке. Что нашлось — показывает
`yam device`. Модель можно задать вручную: `--model` у `yamd` или `device.toml` в
`/data/quazar/yam/data`.

## Свой Lua-плагин

Минимальный пакет — два файла в архиве: `plugin.toml` и `main.lua`.

```toml
id = "hello-ring"
name = "Hello ring"
version = "1.0.0"
entry = "main.lua"
permissions = ["led"]

[launch]
kind = "lua"
mode = "oneshot"

[compatibility]
features = ["led.ring.rgb"]
```

```lua
alice.set({"#FF0000", "#00FF00", "#0000FF"})
alice.sleep(2000)
alice.off()
```

```sh
zip hello-ring.yap plugin.toml main.lua
yam install hello-ring.yap && yam enable hello-ring && yam run hello-ring
```

Каждое API требует своё разрешение в `permissions`. Без разрешения API недоступно:

| Разрешение | Что даёт |
| --- | --- |
| `led` | `alice.set(colors)`, `off()`, `play(path)`, `logo.set()` |
| `volume`, `audio` | громкость, воспроизведение файла |
| `sensors`, `clock`, `display` | датчики, сегментные часы, подсветка экрана |
| `input` | события кнопок — только устройства из `[input] devices` |
| `commands` | `alice.command.listen(фраза, функция)` — свои голосовые команды |
| `ipc.alarm`, `ipc.speech` | события будильника и распознанная речь |
| `ipc.read`, `ipc.control` | сырой Quasar IPC (protobuf) к сервисам из `[ipc] services` |
| `network` | HTTPS к хостам из `[network] allow`; локальные адреса запрещены |
| `bluetooth`, `system`, `exec` | Bluetooth, сведения о системе, запуск программ |

Пример своей голосовой команды (пакет в режиме `service`, разрешение `commands` и
`[commands] phrases = ["ананас"]` в манифесте):

```lua
alice.command.listen("ананас", function(message)
  alice.command.cancel()          -- не отдавать фразу Алисе
  alice.set({"#FFFF00", "#FFFF00", "#FFFF00"})
end)
```

Полный список функций — в
[PLUGIN_API.md](https://github.com/nyakokitsu/yam/blob/main/docs/PLUGIN_API.md), примеры
пакетов — в [`examples/`](https://github.com/nyakokitsu/yam/tree/main/examples).

!!! warning "Текст речи — персональные данные"
    `ipc.speech` и `commands` получают всё, что колонка распознала. Не ставьте пакеты с
    этими разрешениями и `network` вместе, если не доверяете автору. `ipc.control` и `exec`
    могут менять состояние системы — давайте их только своим пакетам.

## Автообновление

`yamd` сам проверяет GitHub Releases YAM через минуту после старта и затем каждые 6 часов.
Если бинарник изменился — скачивает новый и перезапускается. Хеш сверяется с `SHA256SUMS`
из того же релиза, то есть это защита от битой загрузки, а не подпись. Чтобы обновлять
вручную, снимите галочку в Web UI или пропишите в `/data/quazar/yam/data/settings.toml`:

```toml
[updates]
enabled = false
```

## BetterYAM { #betteryam }

[BetterYAM](https://github.com/Yandex-Station-Universal-Repo/BetterYAM) взял
за основу YAM, но у каждой модели свой демон (`betteryamd`) со своим API и Web UI. Пакеты
`.yap`, Lua API и CLI совместимы с YAM. CLI называется `byam`, `yam` ставится как псевдоним.

Сейчас поддерживается только **Станция Мини (1-го поколения)**, сборка armv7. Модель
установщик определяет по `uname -n` (например, `YandexStationMini_729E` → `YandexStationMini`)
и сверяет с `manifest.json` релиза. Для Миди, Мини 3, Лайт 2 и других моделей демона пока
нет, и установка завершается ошибкой.

```sh
curl -fsSL https://raw.githubusercontent.com/Yandex-Station-Universal-Repo/BetterYAM/refs/heads/main/install.sh | sh
```

Windows: `irm https://raw.githubusercontent.com/Yandex-Station-Universal-Repo/BetterYAM/refs/heads/main/install.ps1 | iex`.
Удаление — `sh -s -- --uninstall`, как у YAM. Демон ставится в `/data/quazar/betteryam` и
слушает `8099` на LAN-адресе колонки. Автозапуска нет — как и у YAM, см. [выше](#autostart).

Что умеет демон для Мини:

- кольцо из 6 RGB-светодиодов, кнопки (`/dev/input`), громкость ALSA `Master`, звук WAV
  через `aplay`, датчик приближения;
- статус Bluetooth; включение и выключение — только при остановленном Quasar;
- Wi-Fi через `wpa_cli` прошивки: список, добавление и удаление сетей из Web UI и Lua
  (разрешение `wifi`);
- экспериментальная своя точка доступа `BetterYAM-XXXX` для настройки Wi-Fi с телефона.
  Нужен статический `hostapd`, на железе пока не проверялась.

Неподдержанные функции возвращают понятную ошибку, а в `GET /device` у них
`capabilities: false`. Подробности и чек-лист для новой модели — в
[DEPLOYMENT.md](https://github.com/Yandex-Station-Universal-Repo/BetterYAM/blob/main/docs/DEPLOYMENT.md)
и [ADDING_DEVICES.md](https://github.com/Yandex-Station-Universal-Repo/BetterYAM/blob/main/docs/ADDING_DEVICES.md).

## Чем отличается от `yse`

[`yse`](../start/packages.md) ставит программы в Entware и запускается на самой колонке по
SSH. YAM — менеджер плагинов с веб-панелью и API к железу колонки, управляется с компьютера.
Реестр `.yap` у них общий. Ставить можно оба, они не мешают друг другу.
