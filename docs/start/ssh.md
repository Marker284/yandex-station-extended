# Шаг 2. SSH и отключение обновлений

Делается сразу после [шага 1](root.md), пока работает ADB. Результат:

- обновления от Яндекса больше не ставятся — root не пропадёт;
- SSH на порту **2222** поднимается при каждой загрузке (ADB остаётся запасным входом).

Все команды — с компьютера, из клона репозитория
([Marker284/yandex-station-extended](https://github.com/Marker284/yandex-station-extended)).


## 1. Включаем перманентный ADB доступ { #permADB }

```sh
mkdir -p /data/quasar
touch /data/quasar/activate_adb_quasmodrom
touch /data/quasar/activate_network_adb
chattr +i /data/quasar/activate_adb_quasmodrom
chattr +i /data/quasar/activate_network_adb
```

Проверка после перезагрузки:

```adb devices
```

??? info "Что делает скрипт"
    Создает файлы которые читает система при загрузке станции, если находит - включает ADB.


## 2. Отключите обновления { #kill-ota }

```sh
adb push contrib/yandex-noupdate.sh /data/opt/yandex-noupdate.sh
adb shell sh /data/opt/yandex-noupdate.sh
adb shell reboot
```

Проверка после перезагрузки:

```sh
adb shell sh /data/opt/yandex-noupdate.sh status
```

```text
launch.json : updatesd убран
applier     : заглушён
ota key     : подменён
```

Вернуть всё как было: `sh /data/opt/yandex-noupdate.sh restore` (оригиналы лежат в `/data/opt/backup`).

??? info "Что делает скрипт"
    Все правки — в `/system/vendor/quasar/` (rootfs временно перемонтируется в `rw`):

    1. `ota_script.pub` заменяется чужим ключом — любой OTA-пакет не проходит проверку подписи.
       Это главная защита.
    2. `device_ota_update.sh` заменяется заглушкой.
    3. Из `launch.json` убирается демон `maind --updatesd` (с проверкой результата: если правка
       не удалась, файл остаётся исходным, а защита держится на пунктах 1–2).

## 3. Поставьте SSH (Dropbear) { #dropbear }

Статический `dropbear` (32-битный ARM, armhf) лежит в репозитории, в [`contrib/bin/`](https://github.com/Marker284/yandex-station-extended/tree/main/contrib/bin).

```sh
adb shell mkdir -p /data/opt/bin /data/opt/etc/dropbear
adb push contrib/bin/dropbear contrib/bin/dropbearkey /data/opt/bin/
adb shell chmod +x /data/opt/bin/dropbear /data/opt/bin/dropbearkey
adb shell /data/opt/bin/dropbearkey -t ed25519 -f /data/opt/etc/dropbear/hk_ed25519
```

Автозапуск — скрипт `/etc/init.d/S99zdropbear` (стартует после `S99quasar`, когда ADB уже
поднят как запасной вход):

```sh
adb shell
mount -o remount,rw /
cat > /etc/init.d/S99zdropbear <<'EOF'
#!/bin/sh
# Autostart dropbear SSH on :2222 (delete this file to remove).
DB=/data/opt/bin/dropbear
DIR=/data/opt/etc/dropbear
HK=$DIR/hk_ed25519
LOG=$DIR/dropbear.log
start() {
  [ -x "$DB" ] || { echo "$(date) no $DB" >> "$LOG"; return 1; }
  # host key lost (e.g. /data wiped) -> make a new one
  [ -s "$HK" ] || /data/opt/bin/dropbearkey -t ed25519 -f "$HK" >> "$LOG" 2>&1 || return 1
  pidof dropbear >/dev/null 2>&1 && return 0
  # -B: root has an empty password, without it dropbear refuses the login.
  # This build has no syslog: its messages go to stderr, i.e. to $LOG (no -E flag here).
  "$DB" -r "$HK" -p 2222 -B 2>>"$LOG"
}
case "$1" in
  start)   start ;;
  stop)    killall dropbear 2>/dev/null ;;
  restart) killall dropbear 2>/dev/null; sleep 1; start ;;
esac
exit 0
EOF
chmod +x /etc/init.d/S99zdropbear
sync; mount -o remount,ro /
/etc/init.d/S99zdropbear start
```

Подключение (пароль пустой — просто Enter):

```sh
ssh -p 2222 root@192.168.1.120
```

Если не пускает — смотрите лог `/data/opt/etc/dropbear/dropbear.log` (через `adb shell`) и
перезапустите сервер: `/etc/init.d/S99zdropbear restart`.

!!! note "Флага `-E` у этой сборки нет"
    `dropbear` из `contrib/bin` собран без syslog и всегда пишет сообщения в stderr — поэтому
    они и так попадают в `dropbear.log`. Флаг `-E` («писать в stderr вместо syslog») в такой
    сборке не существует, и с ним сервер не запускается. Не путайте с `-e` — это другая опция
    (передать окружение сервера в сессию), для запуска она не нужна.

??? tip "Ставили автозапуск раньше и SSH не поднимается"
    В ранних версиях этой страницы Dropbear запускался с `-E` и без `-B`. Исправьте строку
    запуска в уже установленном скрипте — через `adb shell` (перезапуск по SSH оборвёт сам сеанс):

    ```sh
    mount -o remount,rw /
    sed -i 's/ -E 2>>/ 2>>/; s/-p 2222 2>>/-p 2222 -B 2>>/' /etc/init.d/S99zdropbear
    grep -- '-p 2222' /etc/init.d/S99zdropbear      # должно быть: -p 2222 -B 2>>"$LOG"
    sync; mount -o remount,ro /
    /etc/init.d/S99zdropbear stop; /etc/init.d/S99zdropbear start
    ```

!!! warning "Пароля у root нет"
    Поэтому Dropbear запускается с `-B` (разрешить пустой пароль): без него вход отклоняется.
    Войти может любой в вашей локальной сети. Не открывайте порты 2222 и 5555 наружу и не
    держите колонку в недоверенной сети.

## 4. Верните DNS

Теперь можно убрать настройки DNS (`179.254.167.126`) с роутера ([шаг 7](root.md#restore-dns)).

Дальше: **[шаг 3 — пакеты `yse`](packages.md)**.

---
