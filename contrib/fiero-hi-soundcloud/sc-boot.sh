#!/bin/sh
# Проверено: Fiero Hi (Станция Лайт, blackthorn), прошивка 0.369.1.50.*. Откат — README.md рядом.
# Автозапуск SoundCloud при загрузке: вызывается из /data/opt/media/bin/ap-start.sh
# (его запускает S99zairplay на rootfs). Повторный запуск безопасен — поднимает только то, чего нет.
#   - dropbear на :2223 с ключами из /data/opt/etc/dropbear/ak (на :2222 /root только для чтения);
#   - голосовой слушатель voice-soundcloud.sh. xray стартует сам при первом play.
export PATH=/opt/bin:/opt/sbin:/usr/bin:/bin:/usr/sbin:/sbin
DIR=$(cd "$(dirname "$0")" && pwd)
D=/data/opt/etc/dropbear

has() { ps -o args 2>/dev/null | grep -q "$1"; }

# свой лог dropbear пишет в stderr — в ak.log, а не в boot.log (иначе он растёт с каждым входом)
has '[d]ropbear .*-p 2223' || /data/opt/bin/dropbear -r "$D/hk_ed25519" -p 2223 -D "$D/ak" 2>>"$D/ak.log"
has '[v]oice-soundcloud.sh' || (cd "$DIR" && setsid ./voice-soundcloud.sh </dev/null >/dev/null 2>&1 &)
echo "$(date '+%m-%d %H:%M:%S') sc-boot: ssh2223=$(has '[d]ropbear .*-p 2223' && echo up || echo DOWN) voice=$(has '[v]oice-soundcloud.sh' && echo up || echo DOWN)"
