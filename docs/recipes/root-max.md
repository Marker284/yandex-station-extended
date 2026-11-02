# Станция Макс — ROOT Max

Сервисная отладка и выполнение административных команд на Яндекс Станции Макс (`yandexstation_2`,
YNDX-0008) через стандартный сетевой сеанс ADB.

## Особенности платформы

На Станции Макс установлена операционная система Android TV (YaOS_X, Android 9).
В отличие от моделей на Buildroot, здесь действует заводская защита целостности
(Android Verified Boot, dm-verity). Системный сервис `adbd` собран в режиме production,
а команда `adb root` возвращает `adbd cannot run as root in production builds`.

Здесь используется отдельный сервисный подход — выполнение команд с повышенными привилегиями
в оперативной памяти через существующую сессию ADB.

Подробные исходные материалы проекта доступны в
[репозитории автора](https://github.com/amirilivice/yandex-station-2-s905x2-root).

## Что понадобится

- Станция Макс на прошивке **`PPR1.180610.011.20220415`**, ядро `4.9.113-g985a1e6b`;
- Сетевой доступ к порту 5555 (через dns или другой способ);
- Компьютер с установленной утилитой `adb`;
- **Android NDK** (проверено на r26d) и Python 3 — для сборки вспомогательной утилиты.

Прошивку **не обновляйте** до и во время работы: при смене версии ядра системные адреса меняются.

## 1. Проверка версии прошивки

Параметры утилиты рассчитаны на конкретную сборку системы. Перед началом проверьте
свойства устройства:

```sh
adb shell getprop ro.build.fingerprint
```

Ожидаемый ответ:

```text
Yandex/yandexstation_2/yandexstation_2:9/PPR1.180610.011/20220415:user/release-keys
```

Последнее поле — номер сборки, и он у ревизий разный: на [Станции Макс](../devices/station-max.md)
снят `5000000896`. Важна часть `PPR1.180610.011`: утилита рассчитана на неё.

Если отпечаток сборки отличается — остановитесь. Параметры потребуется пересчитать под вашу
версию по инструкции в репозитории проекта.

Также зафиксируйте текущие параметры окружения:

```sh
adb shell getprop ro.product.device      # yandexstation_2
adb shell uname -a                        # 4.9.113-g985a1e6b
adb shell id                              # uid=2000(shell)
adb shell getenforce                      # Enforcing
```

## 2. Подключение по ADB

Подключение выполняется стандартным способом:

```sh
adb connect <IP-колонки>:5555
adb devices          # статус: <IP-колонки>:5555    device
adb shell id         # uid=2000(shell)
```

Особенности среды:
- Каталог `/data/local/tmp` доступен для записи (системный `/tmp` закрыт).
- Системный журнал `dmesg` закрыт настройкой `kernel.dmesg_restrict`.

## 3. Сборка служебного модуля

Склонируйте исходный код утилиты и запустите сборку:

```sh
git clone https://github.com/amirilivice/yandex-station-2-s905x2-root
cd yandex-station-2-s905x2-root
python tools/build.py /path/to/android-ndk-r26d
```

Сборщик компилирует бинарный файл для архитектуры ARM.

Команда, которую нужно выполнить с системными правами, указывается при сборке:

```sh
python tools/build.py /path/to/ndk \
    --payload "id > /data/local/tmp/who.txt; getenforce >> /data/local/tmp/who.txt"
```

По умолчанию без флага `--payload` выполняется диагностическая команда: вывод идентификатора,
проверка состояния защиты и возврат настроек в исходное состояние.

## 4. Запуск утилиты на устройстве

Запуск через автоматизированный скрипт:

```sh
python tools/build.py /path/to/android-ndk-r26d --device --serial <IP-колонки>:5555
```

Или вручную через консоль ADB:

```sh
adb push src/reader4 /data/local/tmp/app_tool
adb shell "chmod 755 /data/local/tmp/app_tool"
adb shell "rm -f /data/local/tmp/tool.log; \
  timeout 240 /data/local/tmp/app_tool > /data/local/tmp/tool.log 2>&1; \
  echo RUN_DONE; id; getenforce"
```

**Правила запуска:**
1. Перед запуском проверяйте `uptime` — устройство должно проработать после старта
   не менее трёх минут.
2. Не запускайте утилиту несколько раз подряд без перезагрузки системы.

## 5. Проверка работы

Проверьте лог выполнения:

```sh
adb shell cat /data/local/tmp/tool.log
```

При корректном выполнении в логе отобразится выполнение назначенной команды от имени администратора.

## Особенности и ограничения

- **Действие в рамках одной команды:** повышенные права предоставляются только для процесса,
  запущенного утилитой. После его завершения консоль остаётся в обычном режиме `uid=2000(shell)`.
- **Защита накопителя:** разделы `/system` и `/vendor` защищены проверками целостности dm-verity
  на уровне ядра и загрузчика. Запись на системные разделы не сохраняется. Но для `/product` и `/odm` нет защиты
- **Временный характер:** все изменения происходят исключительно в оперативной памяти и не
  затрагивают постоянную прошивку.

## Возврат в исходное состояние

Поскольку утилита не производит записи в системные разделы, обычная перезагрузка возвращает
колонку в стандартный заводской режим:

```sh
adb shell reboot
```

После перезагрузки статус системы возвращается в штатное состояние:

```sh
adb shell getenforce          # Enforcing
```

Очистите временные файлы в каталоге:

```sh
adb shell rm -f /data/local/tmp/app_tool /data/local/tmp/tool.log
```

## Подводные камни { #подводные-камни }

- Перед запуском проверяйте время непрерывной работы (`uptime`).
- Не запускайте процедуру повторно без предварительной перезагрузки устройства.
- Не используйте исполняемые файлы, собранные под другие версии ядра или устройства.

## Постоянный рут (Требуется подтверждение пробуйте на свой страх и риск)

В `/odm` можно смонтировать loop ext с своими бинарниками, так как `$PATH` содержит `*/odm/bin*`.

Примерно так:

```sh
mount -o loop /data/local/tmp/fs.ext4 /odm
```

Если заглянуть в раздел `product`, который не проверяется при запуске, можно увидеть:

```
app  build.prop  lib  lib64  lost+found  media
```

Можно поправить `build.prop` или добавить свои приложения в `app` или `priv-app` (предварительно создав каталог).

**При создании новых файлов нужно назначить им правильный контекст SELinux:**

```sh
chcon -R u:object_r:system_file:s0 /product/"новые файлы"
```

Также можно попробовать отредактировать build.prop для отключения selinux и запуска adb с root:

```sh
PROP=/product/build.prop
BAK=/data/local/tmp/build.prop.bak.$(date +%s)

echo "Backup: $BAK"
cp "$PROP" "$BAK"

echo "Remount /product rw"
mount -o remount,rw /product

read -r -d '' BLOCK <<'EOF'

ro.build.type=userdebug
ro.build.tags=test-keys
ro.debuggable=1
ro.force.debuggable=1
service.adb.root=1
persist.sys.usb.config=adb
persist.service.adb.enable=1
persist.adb.tcp.port=5555
service.adb.tcp.port=5555
ro.adb.secure=0
ro.secure=0

ro.boot.selinux=permissive
androidboot.selinux=permissive
ro.build.selinux=0
persist.sys.selinux=permissive
EOF

echo "Appending block to $PROP"
printf '%s\n' "$BLOCK" >> "$PROP"

echo "Sync + remount ro"
sync
mount -o remount,ro /product 2>/dev/null || true

echo "Backup at: $BAK"
echo "Done. Reboot to apply."
```

Вернуть обратно:

```sh
PROP=/product/build.prop

BAK=$(ls -1t /data/local/tmp/build.prop.bak.* 2>/dev/null | head -n1)

if [ -z "$BAK" ]; then
  echo "Backup not found in /data/local/tmp"
  exit 1
fi

echo "Restore from: $BAK"
mount -o remount,rw /product

cp "$BAK" "$PROP"

echo "Sync + remount ro"
sync
mount -o remount,ro /product 2>/dev/null || true

echo "Done. Reboot to apply: reboot"
```
