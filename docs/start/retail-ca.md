# Шаг 1. Root на Станции Лайт 2: retail CA из factory

**Основной способ для [Станции Лайт 2 (Plum)](../devices/station-lite2.md).** Колонка
загружается в factory mode, и в retail-разделе заменяется только CA-бандл — после этого
обычная прошивка доверяет подменному серверу eQuasar, а он включает сетевой ADB с root.
Версия прошивки не меняется, откатывать ничего не нужно, в том числе на сборках после
обновления 21 октября 2026 года, которые [DNS-методу](root.md) уже не поддаются.

После этого шага переходите к [шагу 2](ssh.md): SSH и отключение обновлений.

??? note "Другие модели"
    Принцип годится для колонок на **Amlogic/Buildroot** с нативными `quasar`/`maind`, но
    проверен только на Лайт 2: вход в factory mode и номера MTD/UBI у других моделей нужно
    уточнять. Android-модели (Станция Макс, Станция первого поколения) так не открываются.
    Для Мини 3 есть свой вариант — [retail CA и маркеры из factory](retail-ca-mini3.md).
    Для остальных Buildroot-моделей основной способ — [DNS-метод](root.md).

Для Plum в проверенной разметке:

- `mtd3` — раздел `system`;
- UBI-том внутри него называется `rootfs`;
- `/bkupgrade` — отдельный раздел данных;
- после normal-загрузки файл виден как
  `/system/vendor/quasar/certs/ca-certificates.crt`.

На других моделях проверьте номера MTD и UBI перед монтированием.

## Что понадобится

- Linux-хост в одной сети с колонкой;
- [eQuasar](https://git.gay/iwakura/eQuasar/), nginx и DNS-сервер;
- роутер, в настройках DHCP которого можно указать собственный DNS-сервер;
- `adb`;
- [файл `retail-ca-certificates-with-aaa.pem`](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/packages/retail-ca-certificates-with-aaa.pem).

## 1. Установка и запуск eQuasar

[eQuasar](https://git.gay/iwakura/eQuasar/) — готовая конфигурация nginx для
перехвата запросов Quasar. Она отвечает за `get_sync_info` с включённым network
ADB и возвращает `{"hasUpdate":false}` на `check_updates`, а остальные запросы
проксирует дальше.

Скачайте репозиторий:

~~~sh
git clone https://git.gay/iwakura/eQuasar.git
cd eQuasar
~~~

### Вариант с системным nginx

Если nginx ещё не установлен на Ubuntu/Debian:

~~~sh
sudo apt update
sudo apt install -y nginx
~~~

Скопируйте файлы из репозитория в пути, которые использует конфигурация
eQuasar:

~~~sh
sudo install -d /opt/fakequasar
sudo cp -r copymetoroot/opt/fakequasar/certs /opt/fakequasar/
sudo install -d /etc/nginx/sites-enabled
sudo cp copymetoroot/etc/nginx/sites-enabled/quasar \
  /etc/nginx/sites-enabled/quasar
sudo nginx -t
sudo systemctl reload nginx
~~~

В каталоге `copymetoroot/opt/fakequasar/certs` уже лежат сертификаты и ключ,
на которые ссылается nginx-конфигурация. Вики не содержит их содержимое — нужно
использовать файлы из самого репозитория eQuasar.

### Вариант с Docker

Вместо установки системного nginx можно запустить compose-конфигурацию из
репозитория:

~~~sh
docker compose up -d --build
~~~

### Настройка DNS

В настройках DNS-сервера направьте на IP машины с eQuasar (`<IP_EQUASAR>`):

~~~text
quasar.yandex.net
quasar.yandex.ru
scbh.yandex.net
~~~

Следующие домены направьте на `127.0.0.1` или другой недоступный адрес:

~~~text
strm.yandex.ru
rpc.alice.yandex.net
uniproxy.alice.yandex.net
alice.yandex.net
alice-ats.yandex.net
alice-ats-test.yandex.net
~~~

Укажите этот DNS-сервер в настройках DHCP роутера. Для доменов eQuasar не должно
быть рабочих AAAA-записей, иначе колонка может уйти по IPv6 мимо nginx.

### Проверка eQuasar до включения колонки

Проверьте ответы nginx с Linux-хоста:

~~~sh
curl -sk -w '\nHTTP %{http_code}\n' \
  --resolve quasar.yandex.net:443:<IP_EQUASAR> \
  https://quasar.yandex.net/check_updates
~~~

Ожидается:

~~~text
{"hasUpdate":false}
HTTP 200
~~~

Проверьте, что network ADB включён:

~~~sh
curl -sk --resolve quasar.yandex.net:443:<IP_EQUASAR> \
  https://quasar.yandex.net/get_sync_info
~~~

В ответе должны быть `"remoteActivation":true` и `"network":true`.

Логи системного nginx можно посмотреть так:

~~~sh
sudo tail -f /var/log/nginx/quasar.yandex.net.access.log
~~~

Для Docker:

~~~sh
docker compose logs -f quasar
~~~

Оставьте eQuasar запущенным на всём протяжении процедуры.

## 2. Загрузка колонки в factory mode

Следующий способ входа в factory mode актуален для **Plum / Станции Лайт 2**.
Для остальных колонок способ сброса и входа в factory mode нужно искать отдельно
по запросу `как сбросить колонку <название колонки>`.

1. Отключите колонку от питания.
2. Зажмите кнопку отключения микрофона.
3. Не отпуская кнопку, подключите питание.
4. Через приложение умного дома подключите колонку к сети, в которой через DHCP
   выдан DNS-сервер eQuasar.

Приложение может сообщить, что настроить колонку не удалось. Это можно
игнорировать, если в логе eQuasar уже видны запросы колонки, а `check_updates`
возвращает `{"hasUpdate":false}`.

Если в логах нет запросов или `check_updates` возвращает `true`, остановитесь и
исправьте DNS/nginx до продолжения.

Найдите IP колонки в списке клиентов роутера.

## 3. Подключение по ADB

~~~sh
adb connect <IP_колонки>:5555
adb wait-for-device
adb root
adb shell id
~~~

Ожидается:

~~~text
uid=0(root)
~~~

Передайте CA-бандл во временный каталог:

~~~sh
adb push \
  /path/to/retail-ca-certificates-with-aaa.pem \
  /data/local/tmp/retail-ca-certificates.crt
~~~

## 4. Проверка разметки и подключение retail

Войдите в shell factory-системы:

~~~sh
adb shell
~~~

Сначала проверьте разметку:

~~~sh
cat /proc/mtd
cat /proc/cmdline
mount | grep -E 'ubi|ubifs|system|bkupgrade'
ubinfo -a
~~~

### Определение MTD-номера

В выводе `/proc/mtd` найдите строку, имя которой — `system`:

~~~text
dev:    size   erasesize  name
mtd0: ...      ...        "env"
mtd2: ...      ...        "factory"
mtd3: ...      ...        "system"
mtd4: ...      ...        "bkupgrade"
~~~

В этом примере нужный раздел — `mtd3`, поэтому MTD-номер для `ubiattach` —
`3`. В команду передаётся только число, без префикса `mtd`:

~~~sh
ubiattach /dev/ubi_ctrl -m 3
~~~

`bkupgrade` не является retail-системой: не выбирайте его только потому, что он
есть в списке. Целевой раздел должен содержать путь
`system/vendor/quasar/certs/ca-certificates.crt` после монтирования. Если в
`/proc/mtd` нет строки `"system"` и назначение разделов нельзя однозначно
определить по `mount` и `cat /proc/cmdline`, остановитесь и не подставляйте номер
наугад.

### Проверка уже подключённого UBI

Перед `ubiattach` проверьте `ubinfo -a`. Если в выводе есть блок с нужным
`MTD device number` и томом `rootfs`, UBI уже подключён. Например:

~~~text
UBI device number 2
MTD device number: 3
...
Name: rootfs
~~~

В этом случае повторно выполнять `ubiattach` не нужно: номер UBI-устройства —
`2`, и после создания точки монтирования можно сразу использовать `ubi2:rootfs`.

Если нужного UBI-блока нет, подключите найденный выше MTD-раздел:

Создайте точку монтирования и подключите `rootfs`:

~~~sh
mkdir -p /mnt/retail
ubiattach /dev/ubi_ctrl -m <MTD_НОМЕР>
ubinfo -a
~~~

После `ubiattach` найдите в его выводе строку вида:

~~~text
UBI device number 2
~~~

Именно этот номер подставляется в имя тома. Для примера выше команда будет
такой:

~~~sh
mount -t ubifs -o rw ubi2:rootfs /mnt/retail
~~~

Если у вас выведен другой номер, замените `2` на него.

Проверьте целевой файл и режим монтирования:

~~~sh
TARGET=/mnt/retail/system/vendor/quasar/certs/ca-certificates.crt
test -f "$TARGET" && echo OK
mount | grep '/mnt/retail'
~~~

Ожидается `OK` и режим `rw`.

Если раздел подключился как ro:

~~~sh
mount -o remount,rw /mnt/retail
~~~

Если remount не сработал, остановитесь. Не используйте `dd`, `ubiformat`,
`erase` и запись всего MTD-раздела.

## 5. Замена CA-бандла

Сохраните оригинал и замените только файл trust store:

~~~sh
cp -a "$TARGET" "$TARGET.orig"
cp /data/local/tmp/retail-ca-certificates.crt "$TARGET"
chmod 0644 "$TARGET"
chown 0:0 "$TARGET"
sync
~~~

Проверьте результат:

~~~sh
grep -c 'BEGIN CERTIFICATE' "$TARGET"
sha256sum "$TARGET"
grep -c 'MIIEMjCCAxqgAwIBAgIBATANBgkqhkiG9w0BAQUFADB7MQswCQYDVQQGEwJHQjEb' "$TARGET"   # корень AAA: 1
~~~

Проверка выполняется уже по файлу, записанному в retail-раздел. Ожидается `123`
сертификата и SHA-256:

~~~text
5b62f4434ecee31e1e0dfbd57a50fce15be54c4fdfc0f4ccc4a140f0c88f68db
~~~

Если хеш не совпадает, не перезагружайте колонку.

## 6. Возврат в normal/retail

Проверьте текущие переменные загрузчика:

~~~sh
fw_printenv upgrade_step boot_to_recovery
~~~

Для проверенной AXG factory-конфигурации выставьте normal-загрузку:

~~~sh
fw_setenv upgrade_step 1
fw_setenv boot_to_recovery 0
fw_printenv upgrade_step boot_to_recovery
~~~

Ожидается:

~~~text
upgrade_step=1
boot_to_recovery=0
~~~

Если переменных нет или factory-образ использует другую схему загрузки, не
подставляйте имена наугад.

Размонтируйте retail и перезагрузите колонку:

~~~sh
sync
mount -o remount,ro /mnt/retail
umount /mnt/retail
exit
adb reboot
~~~

## 7. Проверка normal-загрузки

После загрузки retail-системы проверьте файл:

~~~sh
adb shell sha256sum /system/vendor/quasar/certs/ca-certificates.crt
~~~

Хеш должен совпадать с:

~~~text
5b62f4434ecee31e1e0dfbd57a50fce15be54c4fdfc0f4ccc4a140f0c88f68db
~~~

Root ADB в обычной прошивке выдаёт eQuasar, поэтому не выключайте его, пока не сделаете
[шаг 2](ssh.md): SSH и отключение обновлений. После этого остановите eQuasar и верните
обычные DNS-настройки.

Дальше: **[шаг 2 — SSH и обновления](ssh.md)**.

## Восстановление исходного CA-бандла

Загрузите колонку в factory mode, подключите retail-раздел по шагу 4 и выполните:

~~~sh
TARGET=/mnt/retail/system/vendor/quasar/certs/ca-certificates.crt
test -f "$TARGET.orig" || { echo 'original backup is missing'; exit 1; }
cp -a "$TARGET.orig" "$TARGET"
chmod 0644 "$TARGET"
chown 0:0 "$TARGET"
sync
mount -o remount,ro /mnt/retail
umount /mnt/retail
~~~

После этого снова выставьте normal-загрузку:

~~~sh
fw_setenv upgrade_step 1
fw_setenv boot_to_recovery 0
reboot
~~~

Если `$TARGET.orig` отсутствует, не подбирайте другой CA-бандл и не стирайте раздел.
Используйте [восстановление](recovery.md) для конкретной модели.

## Если что-то не получилось

??? failure "В factory mode колонка начала обновляться и загрузилась обычная Алиса"
    eQuasar не перехватил запросы колонки: перехват не работает. Начните
    инструкцию заново и перед повторным подключением колонки проверьте, что eQuasar
    запущен,
    DNS указывает на него, а `check_updates` возвращает
    `{"hasUpdate":false}`.

??? failure "Приложение пишет «не удалось настроить Алису»"
    Проверьте лог eQuasar. В factory важны запросы Quasar и появление ADB, а не
    финальный экран приложения.

??? failure "adb connect не работает"
    Проверьте актуальный IP после загрузки factory mode. Убедитесь, что компьютер
    и колонка находятся в одной LAN без AP isolation, а порты `80`/`443` eQuasar
    доступны и DNS-подмена работает.

??? failure "ubiattach сообщает, что устройство уже подключено"
    Не повторяйте `ubiattach`. Найдите существующий `ubiN:rootfs` через `ubinfo -a`.

??? failure "Файл CA не найден"
    Проверьте, что в выбранном UBI-томе есть файл по пути
    `/mnt/retail/system/vendor/quasar/certs/ca-certificates.crt`. Если директории `certs` нет, проверьте наличие файла по пути `/mnt/retail/system/vendor/quasar/ca-certificates.crt` Если после этого файла всё ещё нет,
    остановитесь.

??? failure "Retail-система загрузилась, но ADB нет"
    eQuasar должен работать на протяжении всей процедуры — от загрузки factory
    mode до получения root-доступа в retail-прошивке. Если после замены CA и
    normal-загрузки ADB не появился, начните инструкцию заново и повторите
    подключение через eQuasar. Не перезаписывайте boot или recovery наугад.
