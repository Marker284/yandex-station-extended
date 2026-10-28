# Установка ADB на компьютер

Android Debug Bridge — утилита, которой колонкой управляют с компьютера. Она нужна
с самого первого шага, [получения root](index.md#root-by-model), и дальше для установки
пакетов и своих скриптов.

Незнакомые слова разобраны в [словаре](../glossary.md).

=== "macOS"
    ```sh
    brew install android-platform-tools
    # Проверка:
    adb version
    ```

    !!! warning "`No route to host` при открытом порте"
        Если `nc -z <IP_колонки> 5555` проходит, а `adb connect` пишет `No route to host`, adb
        блокирует защита «Локальная сеть». По наблюдению автора, системным `nc` и `ssh` доступ
        в LAN открыт, а сторонним программам, включая adb, — нет. Разрешите своё приложение-терминал
        в «Системные настройки» → «Конфиденциальность и безопасность» → «Локальная сеть».
        Если запроса не появляется (например, adb запускает фоновый агент), пробросьте порт
        через SSH на роутер — его делает системный `ssh`:

        ```sh
        ssh -f -N -L 127.0.0.1:15555:<IP_колонки>:5555 <роутер>
        adb connect 127.0.0.1:15555
        ```

        Локальный порт берите не из диапазона 5555–5585: его adb сканирует в поисках эмуляторов.

=== "Linux (Ubuntu / Debian / Arch)"
    ```sh
    # Ubuntu / Debian / Mint:
    sudo apt install adb

    # Arch Linux / Manjaro:
    sudo pacman -S android-tools
    ```

=== "Windows"
    1. Скачайте официальный архив: [Google SDK Platform-Tools for Windows](https://dl.google.com/android/repository/platform-tools-latest-windows.zip).
    2. Распакуйте папку `platform-tools` (например, в `C:\platform-tools`).
    3. Запустите командную строку (CMD или PowerShell) из этой папки и выполните `adb.exe version`.

Проверка связи с колонкой, когда ADB на ней уже поднят:

```sh
adb connect 192.168.1.120:5555   # IP вашей колонки
adb devices                      # колонка должна быть в списке
```

Версия имеет значение: код возврата `adb shell` пробрасывают только platform-tools 24
и новее, на старых сборках часть проверок в скриптах вики молча проходит.
