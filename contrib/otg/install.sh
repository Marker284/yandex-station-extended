#!/bin/sh
# Установка USB Host (OTG) на Станцию Лайт (Yandex Station Micro) и Станцию 2
# (Yandex Station Midi) — Amlogic AXG, ядро 4.9.68, PHY ffe09000.
#
# Запуск на колонке из каталога, куда скопированы contrib/otg, contrib/modules и contrib/bin/fuse2fs
# (например: scp -r contrib/otg contrib/modules root@<ip>:/data/otg-src/ &&
#  scp contrib/bin/fuse2fs root@<ip>:/data/otg-src/bin/):
#   sh /data/otg-src/otg/install.sh
#
# Что делает:
#   /data/otg/otg-host.sh      — переключение Type-C в host + загрузка драйверов
#   /data/otg/usb-mount.sh     — монтирование разделов в /tmp/usb/<метка>
#   /data/otg/ff-usb.sh        — строки «USB OTG» для fastfetch
#   /data/otg/zram-swap.sh     — сжатый swap в памяти (включается вместе с Entware на USB)
#   /data/otg/bin/fuse2fs      — ext4 через FUSE (в ядре ext4 нет)
#   /data/otg/audio-route.sh   — весь звук на USB-карту / обратно на динамик (+ правило mdev,
#                                команда usb-audio on|off|status в /usr/bin)
#   /data/otg/modules/*.ko     — модули, собранные под ядро Яндекса
#   /etc/init.d/S97otg-host    — автозапуск с защитой от бутлупа
# Старый /etc/init.d/S98usb_modules (битые модули из ранней версии гайда) удаляется.
set -e
SRC=$(cd "$(dirname "$0")/.." && pwd)
D=/data/otg

# Платформа и регистры PHY у Лайта (yandex,station-micro) и Станции 2
# (yandex,station-midi) совпадают: см. docs/devices/station-2.md.
if grep -q "yandex,station-midi" /proc/device-tree/compatible 2>/dev/null; then
	MODEL="Станция 2 (yandex,station-midi)"
elif grep -q "yandex,station-micro" /proc/device-tree/compatible 2>/dev/null; then
	MODEL="Станция Лайт (yandex,station-micro)"
else
	echo "Это не Станция Лайт (yandex,station-micro) и не Станция 2 (yandex,station-midi) — регистры PHY другие, выходим."
	exit 1
fi
[ "$(uname -r)" = "4.9.68" ] || { echo "Ядро $(uname -r), модули собраны под 4.9.68 — выходим."; exit 1; }
command -v devmem >/dev/null || { echo "Нет devmem в busybox — выходим."; exit 1; }

mkdir -p $D/modules $D/bin
cp "$SRC/otg/otg-host.sh" "$SRC/otg/usb-mount.sh" "$SRC/otg/ff-usb.sh" "$SRC/otg/audio-route.sh" "$SRC/otg/zram-swap.sh" $D/
cp "$SRC"/modules/*.ko $D/modules/
[ -f "$SRC/bin/fuse2fs" ] && cp "$SRC/bin/fuse2fs" $D/bin/fuse2fs && chmod +x $D/bin/fuse2fs
chmod +x $D/otg-host.sh $D/usb-mount.sh $D/ff-usb.sh $D/audio-route.sh $D/zram-swap.sh
( cd "$SRC/modules" && sha256sum -c SHA256SUMS >/dev/null ) || { echo "Контрольные суммы модулей не сошлись."; exit 1; }

mount -o remount,rw /
if [ -f /etc/init.d/S98usb_modules ]; then
	cp -p /etc/init.d/S98usb_modules $D/S98usb_modules.bak
	rm /etc/init.d/S98usb_modules
	echo "Старый S98usb_modules убран (копия: $D/S98usb_modules.bak)"
fi
cp "$SRC/otg/S97otg-host" /etc/init.d/S97otg-host
# USB sound card hotplug -> audio-route.sh auto (mdev matches DEVNAME, e.g. snd/controlC1)
if ! grep -q audio-route /etc/mdev.conf; then
	cp -p /etc/mdev.conf $D/mdev.conf.orig
	sed -i '/^snd\/pcm\.\*/i snd/controlC[1-9]\troot:audio 660 */data/otg/audio-route.sh auto >> /tmp/audio-route.log 2>\&1' /etc/mdev.conf
	echo "Правило mdev для USB-звука добавлено (вступит в силу после перезагрузки)"
fi
chmod +x /etc/init.d/S97otg-host
# короткая команда: usb-audio off / on / status
ln -sf $D/audio-route.sh /usr/bin/usb-audio
sync
mount -o remount,ro / || true

echo "Готово ($MODEL). Для exFAT/NTFS: yse install exfat-fuse ntfs-3g"
echo "Перезагрузите колонку; лог первого запуска — $D/last.log"
