# Шаг 2. SSH и отключение обновлений

Делается сразу после [шага 1](root.md), пока работает ADB. Результат:

- обновления от Яндекса больше не ставятся — root не пропадёт;
- SSH на порту **2222** поднимается при каждой загрузке (ADB остаётся запасным входом).

Все команды — с компьютера, из клона репозитория
([Marker284/yandex-station-extended](https://github.com/Marker284/yandex-station-extended)).

## 1. Отключите обновления { #kill-ota }

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

## 2. Поставьте SSH (Dropbear) { #dropbear }

Статический `dropbear` под `aarch64` лежит в репозитории, в [`contrib/bin/`](https://github.com/Marker284/yandex-station-extended/tree/main/contrib/bin).

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
HK=/data/opt/etc/dropbear/hk_ed25519
LOG=/data/opt/etc/dropbear/dropbear.log
case "$1" in
  start)
    if [ -x "$DB" ] && [ -f "$HK" ]; then
      pidof dropbear >/dev/null 2>&1 || "$DB" -r "$HK" -p 2222 -B 2>>"$LOG"
    fi
    ;;
  stop)
    killall dropbear 2>/dev/null
    ;;
esac
exit 0
EOF
chmod +x /etc/init.d/S99zdropbear
sync; mount -o remount,ro /
/etc/init.d/S99zdropbear start
```

Подключение:

```sh
ssh -p 2222 root@192.168.1.120
```

!!! warning "Пароля у root нет"
    Войти может любой в вашей локальной сети. Не открывайте порты 2222 и 5555 наружу и не
    держите колонку в недоверенной сети.

## 3. Верните DNS

Теперь можно убрать `179.254.167.126` с роутера ([шаг 7](root.md#restore-dns)).

Дальше: **[шаг 3 — пакеты `yse`](packages.md)**.

---

## Как это устроено

- Корневая ФС `/` — ubifs, смонтирована только для чтения, но dm-verity на ней не включён:
  после `mount -o remount,rw /` правки сохраняются и переживают перезагрузку.
- `/data` — ссылка на `/bkupgrade/data` (отдельный раздел, ~87 МБ). Свой софт кладите в `/data/opt`.
- Скрипты `/etc/init.d/S??*` выполняет `rcS` по алфавиту при загрузке — так работают
  `S99zdropbear` и другие автозапуски из этой вики.
- Сброс к заводским настройкам кнопками очищает `/data` — после него шаги 1–2 придётся повторить.
