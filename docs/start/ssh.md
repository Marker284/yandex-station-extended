# Шаг 2. SSH и отключение обновлений

Делается сразу после шага 1 — [подмены DNS](root.md) или способа с сертификатом
для [Лайт 2](retail-ca.md) и [Мини 3](retail-ca-mini3.md), — пока работает ADB. Результат:

Незнакомые слова разобраны в [словаре](../glossary.md).

- обновления от Яндекса больше не ставятся — root не пропадёт;
- SSH на порту **2222** поднимается при каждой загрузке (ADB остаётся запасным входом).

Все команды выполняются с компьютера, из клона репозитория
[Marker284/yandex-station-extended](https://github.com/Marker284/yandex-station-extended).

## 1. Закрепите сетевой ADB { #perm-adb }

Прошивка поднимает `adbd` на порту **5555**, если при загрузке находит в `/data/quasar`
маркеры `activate_adb_quasmodrom` и `activate_network_adb` (см.
[Архитектуру прошивки](../internals/architecture.md)). После root они уже есть, но сброс
настроек или обновление их удаляют — `chattr +i` защищает файлы от удаления:

```sh
adb shell 'mkdir -p /data/quasar &&
  touch /data/quasar/activate_adb_quasmodrom /data/quasar/activate_network_adb &&
  chattr +i /data/quasar/activate_adb_quasmodrom /data/quasar/activate_network_adb'
```

Проверка после перезагрузки колонки:

```sh
adb connect 192.168.1.120:5555   # IP вашей колонки
adb devices
```

Постоянным входом считайте SSH, его ставят [ниже на этой странице](#dropbear). ADB
оставляйте запасным: на части моделей маркеры живут не всегда.

??? note "Где маркеры другие или не держатся: Мини 3, Мини 3 Про, Миди"
    На Мини 3 Про с прошивкой `.50` корень после перезагрузки откатывается, и маркеры
    не сохраняются. На заводской factory-12 они называются иначе —
    `/data/quasar_activate_*`, через подчёркивание, см.
    [страницу модели](../devices/station-mini3-pro.md#factory-12).

    На Мини 3 после возврата DNS настоящий Яндекс присылает конфиг без `adbd`, и прошивка
    сама вызывает `activate_adb.sh … deactivate` — подробнее в
    [разделе про возврат DNS](retail-ca-mini3.md#adb-after-dns). Держит ли `chattr +i`
    маркеры в этом случае, на устройстве не проверялось.

    На Миди с заводской factory-6 маркеры тоже через подчёркивание. `chattr +i` на них
    выдерживает ту же команду `deactivate`, запущенную вручную, — см.
    [страницу модели](../devices/station-midi.md#factory-6-adb).

## 2. Отключите обновления { #kill-ota }

!!! warning "Резервная копия лежит на колонке и пропадёт при сбросе"
    Скрипт сохраняет оригиналы трёх системных файлов в `/data/opt/backup` и без удачной
    копии ничего не правит. Но сам каталог живёт на колонке: сразу после запуска скрипта
    заберите его к себе командой `adb pull /data/opt/backup ./backup-колонки`.

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

Вернуть всё в исходное состояние:
`sh /data/opt/yandex-noupdate.sh restore` (оригиналы лежат в `/data/opt/backup`).

??? note "`updatesd ПРИСУТСТВУЕТ` после скрипта"
    На сборках без роли `--platformd` (Миди factory-6) скрипт не меняет `launch.json`:
    проверка результата ищет `--platformd`. Ключ и заглушка при этом ставятся — см.
    [страницу Миди](../devices/station-midi.md#factory-6-ota).

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

Одной командой `adb shell '/etc/init.d/S99zdropbear start'` сервер тоже стартует, но сеанс
не завершается: `dropbear` уходит в фон, не закрыв вывод. Прервите сеанс (Ctrl+C) — сервер
продолжит работать (проверено на Миди factory-6).

Подключение, пароль пустой — на запрос нажмите Enter:

```sh
ssh -p 2222 root@192.168.1.120   # IP вашей колонки
```

Если не пускает — смотрите лог `/data/opt/etc/dropbear/dropbear.log` (через `adb shell`) и
перезапустите сервер: `/etc/init.d/S99zdropbear restart`.

??? note "Ставили автозапуск по старой версии этой страницы — почините строку запуска"
    Раньше здесь был запуск с `-E` и без `-B`, с ним сервер не стартует: эта сборка
    `dropbear` собрана без syslog, пишет в stderr всегда, и флага `-E` в ней нет.
    Опция `-e` — это другое, передача окружения в сессию, для запуска она не нужна.
    Почините уже установленный скрипт через `adb shell`:

    ```sh
    mount -o remount,rw /
    sed -i 's/ -E 2>>/ 2>>/; s/-p 2222 2>>/-p 2222 -B 2>>/' /etc/init.d/S99zdropbear
    grep -- '-p 2222' /etc/init.d/S99zdropbear      # должно быть: -p 2222 -B 2>>"$LOG"
    sync; mount -o remount,ro /
    /etc/init.d/S99zdropbear stop; /etc/init.d/S99zdropbear start
    ```

!!! danger "Доступ по SSH открыт без пароля для всей локальной сети"
    Dropbear запускается с ключом `-B` (разрешить пустой пароль), иначе вход отклоняется.
    Войти может любой в вашей локальной сети. Не открывайте порты 2222 и 5555 наружу и не
    держите колонку в недоверенной сети.

## 4. Верните DNS

Теперь можно убрать настройки DNS `179.254.167.126` с роутера, подробнее в
[шаге 7](root.md#restore-dns).

Дальше: **[шаг 3 — пакеты `yse`](packages.md)**.

## Как это устроено

- Корневая ФС `/` смонтирована только для чтения, но dm-verity на ней не включён: после
  `mount -o remount,rw /` правки сохраняются и переживают перезагрузку. ФС на Лайте — ubifs,
  на [Миди](../devices/station-midi.md#partitions) — ext4, там это проверено на factory-6.
- `/data` на Лайте — ссылка на `/bkupgrade/data` (отдельный раздел, ~87 МБ), на Миди —
  свой раздел eMMC (2.5 ГБ). Свой софт кладите в `/data/opt`.
- Скрипты `/etc/init.d/S??*` выполняет `rcS` по алфавиту при загрузке — так работают
  `S99zdropbear` и другие автозапуски из этой вики.
- Сброс к заводским настройкам кнопками очищает `/data` — после него шаги 1–3 придётся повторить.
