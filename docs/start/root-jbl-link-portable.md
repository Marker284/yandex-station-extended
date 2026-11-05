# Root и постоянный SSH на JBL Link Portable

Настройка [JBL Link Portable с Алисой](../devices/jbl-link-portable.md) через задний USB-C:
сетевой ADB, блокировка известного каталога OTA и SSH по ключу с автозапуском.
Понадобится около 20 минут.

**Проверено на:** JBL Link Portable с Алисой,
прошивка `1.80.0.228.3676569159.20251219.`, 4 ноября 2026 года; компьютер с macOS.
Команды ниже рассчитаны на оболочку Linux/macOS. Версия с Google Assistant не проверялась.

!!! warning "Сетевой ADB даёт root без пароля"
    Порт 5555 доступен другим устройствам в вашей сети. Используйте доверенную
    локальную сеть. SSH в этой инструкции принимает только ключи; порты наружу не открываются.

## Что понадобится { #requirements }

- Кабель USB-C с передачей данных; проверен USB-C ↔ USB-C.
- Компьютер с [ADB](adb.md), Git, Python 3.9+ и OpenSSH.
- Для автозапуска — clang с ARM target и ELF lld; Linux sysroot для сборки плагина не нужен.
- Колонка, уже настроенная в приложении и подключённая к домашней сети.

## Подготовьте файлы { #files }

Скачайте репозиторий на компьютер:

```sh
git clone --depth 1 --filter=blob:none --sparse \
  https://github.com/Marker284/yandex-station-extended.git
git -C yandex-station-extended sparse-checkout set contrib/bin contrib/jbl-link-portable
JBL_REPO="$PWD/yandex-station-extended"
JBL_DIR="$JBL_REPO/contrib/jbl-link-portable"
```

Если клон уже есть, укажите его абсолютный путь в JBL_REPO и задайте JBL_DIR.
Исходники команд находятся в [contrib/jbl-link-portable](https://github.com/Marker284/yandex-station-extended/tree/main/contrib/jbl-link-portable).
Они не меняют размеры разделов и содержимое корня.

## Закрепите ADB { #adb }

1. Подключите задний USB-C колонки к компьютеру. На Mac разрешите USB-аксессуар,
   если появится системный запрос. Выключите колонку кнопкой питания.

2. Запустите ожидание USB-устройства на компьютере:

    ```sh
    adb -d wait-for-usb-device shell "$(cat "$JBL_DIR/enable-adb.sh")"
    ```

3. Включите колонку обычным нажатием кнопки питания. Volume+ держать не нужно.
   Скрипт проверит root, создаст недостающие маркеры и защитит их от удаления.
   В конце должен появиться результат JBL_ROOT_ENABLED.

4. Перезагрузите колонку кнопкой питания. Дождитесь Wi-Fi и задайте её адрес
   на компьютере; замените IP_КОЛОНКИ своим значением:

    ```sh
    JBL_HOST='IP_КОЛОНКИ'
    JBL_TARGET="$JBL_HOST:5555"
    adb connect "$JBL_TARGET"
    adb -s "$JBL_TARGET" shell id
    ```

Успешная проверка возвращает uid=0(root). Если USB-окно пропущено из-за системного
запроса macOS, повторите выключение и ожидание. При нескольких USB ADB-устройствах
отключите остальные или укажите нужный транспорт явно.

??? tip "Проверенный USB-бэкенд на macOS"
    На проверенном компьютере использовался LIBUSB. Перезапуск ADB-сервера
    прерывает другие ADB-подключения этого компьютера:

    ```sh
    adb kill-server
    ADB_LIBUSB=1 adb start-server
    adb server-status
    ```

## Заблокируйте известный каталог OTA { #ota }

1. Выполните проверку каталога и включение блокировки:

    ```sh
    adb -s "$JBL_TARGET" shell "set -- enable; $(cat "$JBL_DIR/ota-guard.sh")"
    ```

2. Проверьте результат; ожидается JBL_OTA_DIRECTORY_BLOCKED:

    ```sh
    adb -s "$JBL_TARGET" shell "set -- status; $(cat "$JBL_DIR/ota-guard.sh")"
    ```

Атрибут immutable запрещает создавать новые файлы в корне `/bkupgrade`.
Подкаталог wiimu не блокируется рекурсивно. Если найдены неизвестные файлы,
готовый образ обновления или процесс установки, скрипт остановится.

Отказ в создании пустого тестового файла проверен после перезагрузки. Другие
каталоги и способы OTA не проверялись; это не отключение всех обновляющих процессов.

## Установите SSH по ключу { #ssh }

Шаги рассчитаны на первую установку. Если `/data/jbl-ssh` уже существует,
установщик откажется заменять его: сначала проверьте имеющийся SSH и ключи.

1. Создайте клиентский ключ на компьютере. При существующем ключе используйте его,
   не подтверждайте перезапись; JBL_KEY должен указывать на приватную часть:

    ```sh
    JBL_KEY="$HOME/.ssh/jbl_link_portable"
    test -f "$JBL_KEY" || ssh-keygen -t ed25519 -N '' -f "$JBL_KEY"
    test -s "$JBL_KEY.pub"
    ```

2. Создайте новый временный каталог на колонке:

    ```sh
    adb -s "$JBL_TARGET" shell \
      'test ! -e /tmp/jbl-ssh-install && mkdir -m 700 /tmp/jbl-ssh-install'
    ```

3. Передайте проверяемые бинарники, скрипты и только публичный клиентский ключ:

    ```sh
    adb -s "$JBL_TARGET" push "$JBL_REPO/contrib/bin/dropbear" /tmp/jbl-ssh-install/
    adb -s "$JBL_TARGET" push "$JBL_REPO/contrib/bin/dropbearkey" /tmp/jbl-ssh-install/
    adb -s "$JBL_TARGET" push "$JBL_DIR/ssh-service.sh" /tmp/jbl-ssh-install/
    adb -s "$JBL_TARGET" push "$JBL_DIR/install-ssh.sh" /tmp/jbl-ssh-install/
    adb -s "$JBL_TARGET" push "$JBL_KEY.pub" /tmp/jbl-ssh-install/authorized_keys
    ```

4. Запустите установку. Скрипт проверит модель прошивки и SHA-256 бинарников,
   создаст отдельный ключ сервера и запустит Dropbear на порту 2222:

    ```sh
    adb -s "$JBL_TARGET" shell 'sh /tmp/jbl-ssh-install/install-ssh.sh /tmp/jbl-ssh-install'
    ```

5. Получите публичный ключ сервера через доверенное ADB-подключение:

    ```sh
    mkdir -p "$JBL_DIR/private"
    chmod 700 "$JBL_DIR/private"
    adb -s "$JBL_TARGET" shell \
      '/tmp/jbl-ssh-install/dropbearkey -y -f /data/jbl-ssh/host_ed25519' |
      tr -d '\r' | awk '/^ssh-ed25519 / {print $1, $2}' > "$JBL_DIR/private/host.pub"
    test -s "$JBL_DIR/private/host.pub" &&
      printf '[%s]:2222 %s\n' "$JBL_HOST" "$(cat "$JBL_DIR/private/host.pub")" \
      > "$JBL_DIR/private/known_hosts"
    ```

6. Создайте локальный SSH config и проверьте вход:

    ```sh
    cat > "$JBL_DIR/private/ssh_config" <<EOF
    Host jbl
        HostName $JBL_HOST
        Port 2222
        User root
        IdentityFile "$JBL_KEY"
        UserKnownHostsFile "$JBL_DIR/private/known_hosts"
        StrictHostKeyChecking yes
        IdentitiesOnly yes
        BatchMode yes
        ConnectTimeout 5
    EOF
    chmod 600 "$JBL_DIR/private/ssh_config" "$JBL_DIR/private/known_hosts"
    ssh -F "$JBL_DIR/private/ssh_config" jbl id
    ```

Пароль root не меняется, парольный вход в Dropbear выключен. Приватный ключ клиента
остаётся на компьютере. До следующего раздела сервер запускается вручную через ADB.

## Закрепите автозапуск { #autostart }

1. Соберите ARMv7-плагин на компьютере. Укажите пути к clang и ELF lld,
   если они отсутствуют в PATH:

    ```sh
    python3 "$JBL_DIR/build.py"
    ```

2. Проверьте подготовленные файлы без обращения к колонке:

    ```sh
    python3 "$JBL_DIR/install-autostart.py"
    ```

3. Установите автозапуск через уже проверенный SSH:

    ```sh
    python3 "$JBL_DIR/install-autostart.py" --install \
      --ssh-config "$JBL_DIR/private/ssh_config"
    ```

4. Запишите boot_id перед перезагрузкой:

    ```sh
    ssh -F "$JBL_DIR/private/ssh_config" jbl cat /proc/sys/kernel/random/boot_id
    ```

5. Перезагрузите колонку обычной кнопкой питания. После подключения Wi-Fi
   проверьте прямой SSH, службы и маркер выполненного скрипта:

    ```sh
    ssh -F "$JBL_DIR/private/ssh_config" jbl \
      'systemctl is-active jbl-autostart.service jbl-ssh.service;
       cat /proc/sys/kernel/random/boot_id;
       cat /run/jbl-autostart-hooks.boot-id'
    ```

Обе службы должны быть active. Два boot_id должны совпасть между собой и отличаться
от значения до перезагрузки. Автозапуск проверен прямым SSH после reboot,
без запуска сервера через ADB-помощник.

!!! note "Автозапуск зависит от штатного сборщика логов"
    Плагин загружается при работе Fluent Bit с logs.cfg. Режим idle.cfg его не вызывает.
    Не отключайте fluent-bitd, если нужен этот способ автозапуска. Работа без сети
    или при принудительно отключённом логировании отдельно не проверялась.

## Если не получилось { #troubleshooting }

| Симптом | Что проверить |
|---|---|
| Компьютер не видит USB ADB | Кабель с данными, разрешение macOS, ожидание до включения |
| USB ADB пропал | Повторить загрузочное окно; затем проверить сетевой порт 5555 |
| SSH требует пароль или отвергает ключ | Публичный ключ, права каталогов и выбранный SSH config |
| SSH работает вручную, но не после reboot | Режим logs.cfg, службы и `/run/jbl-autostart.log` |
| Installer сообщает о существующем каталоге | Не заменять ключи и конфиги; проверить имеющуюся установку |

При остановленном SSH его можно поднять вручную через уже подключённый ADB:

```sh
adb -s "$JBL_TARGET" shell 'sh /data/jbl-ssh/service.sh start'
```

## Отключение изменений { #disable }

Снять блокировку известного каталога OTA:

```sh
adb -s "$JBL_TARGET" shell "set -- disable; $(cat "$JBL_DIR/ota-guard.sh")"
```

Отключить автозапуск, вернув оригинальные байты изменённого конфига:

```sh
ssh -F "$JBL_DIR/private/ssh_config" jbl 'sh /data/jbl-autostart/rollback.sh'
```

Скрипт проверяет хеши, оставляет установленные файлы и текущий SSH-сеанс.
Фактическое отключение рабочей установки ради проверки не выполнялось.
Чтобы остановить SSH до следующего ручного запуска:

```sh
adb -s "$JBL_TARGET" shell 'sh /data/jbl-ssh/service.sh stop'
```

## Как это работает { #how }

| Часть | Механизм |
|---|---|
| ADB | Пустые маркеры `/data/network_adb` и `/data/quasar_activate_adb`, защищённые `+i` |
| USB-окно | Временный `/tmp/lock_activated_adb`; один этот файл не переживает reboot |
| SSH | Статический ARMv7 Dropbear 2026.94, свои ключи и скрипт службы в `/data/jbl-ssh` |
| Права | Immutable сохраняет root:root и права собственных файлов при загрузке |
| Авторизация | Публичный ключ копируется в защищённый `/run/jbl-ssh-auth` для проверки Dropbear |
| Автозапуск | Include в существующем device.cfg из `/data`, плагин Fluent Bit и systemd |

Штатный onboot сначала отключает USB, затем включает его по постоянному маркеру.
При установке автозапуска исходные строки device.cfg сохраняются, добавляется один include.
Оригинал остаётся на колонке и в локальном private; этот каталог нельзя публиковать.
Файл защищён от перегенерации, а изменяемый variables.cfg остаётся штатным.

Плагин не создаёт лог-записей и не добавляет сетевых отправок. Он воссоздаёт unit
в `/run`, который выполняет короткие скрипты из `/data/jbl-autostart/hooks.d`.
Скрипты запускают SSH и создают проверочный маркер. Служба имеет таймаут 30 секунд
и не выполняется повторно в том же boot при обычных рестартах логгера.
