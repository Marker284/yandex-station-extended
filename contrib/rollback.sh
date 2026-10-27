#!/bin/sh
# ==============================================================================
# Скрипт отката / прошивки дампов Яндекс Станции Мини 2 (Amlogic A113X)
# Только root ADB в среде восстановления; USB Burning Tool здесь не реализован.
# На устройстве этот вариант не проверялся. --write явно разрешает запись разделов.
# Пользовательские данные не удаляются; откат возможен только из собственных дампов.
# ==============================================================================

set -eu

[ "$#" = 3 ] && [ "$3" = --write ] || {
    echo "Usage: sh rollback.sh <adb-serial> <image-dir> --write" >&2
    echo "WARNING: raw NAND restore is unverified and can brick the station." >&2
    exit 2
}
DEVICE_IP=$1
IMAGE_DIR=$2
case "$DEVICE_IP" in ''|-*|*[!a-zA-Z0-9_.:-]*) exit 2 ;; esac
export MSYS_NO_PATHCONV=1
command -v adb >/dev/null 2>&1 || { echo 'adb not found' >&2; exit 1; }

echo "=== Яндекс Станция Мини 2: Мастер отката прошивки ==="
echo "Целевое устройство ADB: $DEVICE_IP"
echo "Каталог с дампами:      $IMAGE_DIR"
echo "------------------------------------------------------"

if [ ! -d "$IMAGE_DIR" ]; then
    echo "[-] Ошибка: каталог $IMAGE_DIR не найден."
    echo "    Создайте папку $IMAGE_DIR и поместите туда образы:"
    echo "    - boot.img       (ядро + initramfs, раздел mtd2)"
    echo "    - system.ubi     (UBI образ корневой системы, раздел mtd3)"
    echo "    - recovery.img   (рекавери, раздел mtd6)"
    exit 1
fi

found=0
for image in boot.img system.ubi system.img recovery.img; do
    if [ -e "$IMAGE_DIR/$image" ]; then
        [ -s "$IMAGE_DIR/$image" ] || { echo "Empty image: $image" >&2; exit 1; }
        found=1
    fi
done
[ "$found" = 1 ] || { echo 'No images found; nothing to restore.' >&2; exit 1; }
[ ! -e "$IMAGE_DIR/system.ubi" ] || [ ! -e "$IMAGE_DIR/system.img" ] || {
    echo 'Provide either system.ubi or system.img, not both.' >&2; exit 1
}

echo "[1/4] Проверка связи со станцией через ADB..."
adb connect "$DEVICE_IP" || true
if ! adb -s "$DEVICE_IP" get-state 1>/dev/null 2>&1; then
    echo "[-] Устройство $DEVICE_IP недоступно по ADB!"
    echo "    Этот скрипт требует уже работающий ADB в среде восстановления."
    exit 1
fi
[ "$(adb -s "$DEVICE_IP" shell id -u | tr -d '\r\n')" = 0 ] || {
    echo 'Root ADB is required.' >&2; exit 1
}
adb -s "$DEVICE_IP" shell 'set -eu
    tr "\000" "\n" < /proc/device-tree/compatible | grep -qx "yandex,station-mini2"
    grep -q "^mtd2:.*\"boot\"$" /proc/mtd
    grep -q "^mtd3:.*\"system\"$" /proc/mtd
    grep -q "^mtd6:.*\"recovery\"$" /proc/mtd'
if [ -e "$IMAGE_DIR/system.ubi" ] || [ -e "$IMAGE_DIR/system.img" ]; then
    # Never erase an attached UBI device, including the running retail rootfs.
    adb -s "$DEVICE_IP" shell 'set -eu
        for path in /sys/class/ubi/ubi*/mtd_num; do
            [ -f "$path" ] || continue
            if [ "$(cat "$path")" = 3 ]; then
                echo "Refusing system restore: mtd3 is attached to UBI." >&2; exit 1
            fi
        done'
fi
echo "[+] Станция на связи в режиме root!"

echo "[2/4] Отключение демонов Quasar для освобождения разделов..."
adb -s "$DEVICE_IP" shell "killall -9 maind quasar_launcher2 hardvold 2>/dev/null || true"
sleep 2

echo "[3/4] Прошивка разделов MTD / UBI..."

# 1. Прошивка Boot (mtd2)
if [ -f "$IMAGE_DIR/boot.img" ]; then
    echo " -> Загрузка и прошивка boot.img (mtd2)..."
    adb -s "$DEVICE_IP" push "$IMAGE_DIR/boot.img" /tmp/boot.img
    adb -s "$DEVICE_IP" shell "flash_erase /dev/mtd2 0 0 && nandwrite -p /dev/mtd2 /tmp/boot.img && rm /tmp/boot.img"
    echo " [+] Boot раздел успешно прошит!"
fi

# 2. Прошивка System UBI (mtd3)
if [ -f "$IMAGE_DIR/system.ubi" ]; then
    echo " -> Загрузка и прошивка system.ubi (mtd3)..."
    adb -s "$DEVICE_IP" push "$IMAGE_DIR/system.ubi" /tmp/system.ubi
    adb -s "$DEVICE_IP" shell "ubiformat /dev/mtd3 -f /tmp/system.ubi -y && rm /tmp/system.ubi"
    echo " [+] Корневой раздел System успешно прошит!"
elif [ -f "$IMAGE_DIR/system.img" ]; then
    echo " -> Загрузка и прошивка system.img (mtd3)..."
    adb -s "$DEVICE_IP" push "$IMAGE_DIR/system.img" /tmp/system.img
    adb -s "$DEVICE_IP" shell "flash_erase /dev/mtd3 0 0 && nandwrite -p /dev/mtd3 /tmp/system.img && rm /tmp/system.img"
    echo " [+] Раздел System успешно прошит!"
fi

# 3. Прошивка Recovery (mtd6)
if [ -f "$IMAGE_DIR/recovery.img" ]; then
    echo " -> Загрузка и прошивка recovery.img (mtd6)..."
    adb -s "$DEVICE_IP" push "$IMAGE_DIR/recovery.img" /tmp/recovery.img
    adb -s "$DEVICE_IP" shell "flash_erase /dev/mtd6 0 0 && nandwrite -p /dev/mtd6 /tmp/recovery.img && rm /tmp/recovery.img"
    echo " [+] Recovery успешно прошит!"
fi

echo "[4/4] Синхронизация и перезагрузка (без очистки /data)..."

echo "======================================================"
echo "[+] Откат на целевую прошивку завершен!"
echo "    Перезагружаю станцию: adb -s $DEVICE_IP reboot"
adb -s "$DEVICE_IP" shell sync
adb -s "$DEVICE_IP" reboot
echo "======================================================"
