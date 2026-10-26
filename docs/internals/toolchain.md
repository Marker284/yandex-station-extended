# Сборка своего софта под Станцию

Руководство по кросс-компиляции и сборке статических бинарников для процессоров Amlogic и Allwinner в умных колонках Яндекс.

---

## Ядро 64-бит, userspace 32-бит

На большинстве современных Станций (Лайт, Мини 2, Станция 2, Миди):

* **Ядро Linux — 64-битное (`aarch64`, ARMv8-A).**
* **Системное окружение (Userspace) — 32-битное (`armhf`, glibc 2.30).**

Что из этого следует:

1. **Статическая сборка под `aarch64-linux-musl` — лучший путь:**
   Поскольку ядро поддерживает 64-битный режим, полностью статические бинарники `aarch64` исполняются ядром напрямую и на 100% независимы от старых системных библиотек в `/lib` и `/usr/lib`.
2. **Динамическая сборка под `armhf` (32-бит):**
   Если программе нужны системные библиотеки прошивки (GStreamer, ALSA, D-Bus), собирайте её 32-битным тулчейном под **glibc не новее 2.30**.

---

## Сборка через Zig (рекомендуемый инструмент)

[Zig](https://ziglang.org/) содержит встроенные кросс-компиляторы под все архитектуры и готовую библиотеку `musl`. Это позволяет собирать программы под ARM без установки гигабайтных кросс-тулчейнов.

### 1. Настройка псевдо-компиляторов

Создайте скрипты-обёртки на вашем компьютере (например, в каталоге `~/zbin`):

```sh
mkdir -p ~/zbin

# ~/zbin/aarch64-cc
cat << 'EOF' > ~/zbin/aarch64-cc
#!/bin/sh
exec zig cc -target aarch64-linux-musl "$@"
EOF

# ~/zbin/aarch64-cxx
cat << 'EOF' > ~/zbin/aarch64-cxx
#!/bin/sh
exec zig c++ -target aarch64-linux-musl "$@"
EOF

chmod +x ~/zbin/aarch64-cc ~/zbin/aarch64-cxx
export PATH="$HOME/zbin:$PATH"
```

Для 32-битной Станции Стрит (SoC Amlogic A1 / Mango) используйте таргет:
```text
-target arm-linux-musleabihf
```

---

### 2. Кросс-компиляция проектов на CMake

Создайте файл описания тулчейна `toolchain-aarch64.cmake`:

```cmake
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(CMAKE_C_COMPILER zig;cc;-target;aarch64-linux-musl)
set(CMAKE_CXX_COMPILER zig;c++;-target;aarch64-linux-musl)

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
```

Пример сборки любого проекта:

```sh
cmake -B build -DCMAKE_TOOLCHAIN_FILE=toolchain-aarch64.cmake -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
```

После компиляции уменьшите размер бинарника утилитой strip:
```sh
zig objcopy --strip-all build/my_program
```

---

## Уже проверенные и работающие утилиты

Все готовые бинарники уже скомпилированы и выложены в репозиторий в папку [`contrib/bin/`](https://github.com/Marker284/yandex-station-extended/tree/main/contrib/bin):

| Программа | Архитектура | Ссылка на бинарник | Примечания |
|---|---|---|---|
| **Fastfetch** | `aarch64` | [📥 Скачать fastfetch](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/bin/fastfetch) | Информер с цветным логотипом Алисы и датчиком температуры CPU. |
| **Dropbear (SSH)** | `aarch64` | [📥 Скачать dropbear](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/bin/dropbear) | Автономный SSH-сервер со статическим musl. |
| **Dropbearkey** | `aarch64` | [📥 Скачать dropbearkey](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/bin/dropbearkey) | Генератор ED25519/RSA хост-ключей. |
| **Nano** | `aarch64` | [📥 Скачать nano](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/bin/nano) | Удобный консольный текстовый редактор. |
| **Zsh** | `aarch64` | [📥 Скачать zsh](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/bin/zsh-5.9.2-aarch64-musl) | Мощная командная оболочка Zsh (5.9.2). |
| **yse** | shell | [📥 Скачать yse](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/bin/yse) | Пакетный менеджер поверх Entware — [шаг 3](../start/packages.md). |
| **htop, tmux, …** | `aarch64` / `armv7` | `yse install <pkg>` | Из Entware в `/opt`. |

---

## Заливка и запуск на колонке

Все собранные бинарники и библиотеки должны размещаться в доступном для записи разделе `/data`:

```sh
# 1. Загрузка файла по ADB
adb connect <IP_колонки>:5555
adb push my_program /data/opt/bin/
adb shell chmod +x /data/opt/bin/my_program

# 2. Проверка запуска
adb shell /data/opt/bin/my_program
```

Если утилите требуются собственные конфиги или базы данных, создавайте их в `/data/opt/etc/` или `/data/opt/home/`.

---

## Установка ADB на компьютер { #adb-install }

Чтобы управлять колонкой с компьютера через Android Debug Bridge:

=== "macOS"
    ```sh
    brew install android-platform-tools
    # Проверка:
    adb version
    ```

    !!! warning "`No route to host` при открытом порте"
        Если `nc -z <IP_колонки> 5555` проходит, а `adb connect` пишет `No route to host`, adb
        блокирует защита «Локальная сеть»: системным `nc` и `ssh` доступ в LAN открыт, сторонним
        программам — нет. Включите своё приложение-терминал в «Системные настройки» →
        «Конфиденциальность и безопасность» → «Локальная сеть». Если запроса не появляется
        (например, adb запускает фоновый агент), пробросьте порт через SSH на роутер — его
        делает системный `ssh`:

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

