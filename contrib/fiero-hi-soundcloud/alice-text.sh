#!/bin/sh
# Проверено: Fiero Hi (Станция Лайт, blackthorn), прошивка 0.369.1.50.*. Откат — README.md рядом.
# alice-text без компиляции: socat -x печатает кадры канала Алисы в hex (в stderr, без буферизации),
# alice-text.awk достаёт из них текст фраз. При обрыве переподключаемся.
export PATH=/opt/bin:/opt/sbin:/usr/bin:/bin:/usr/sbin:/sbin
DIR=$(dirname "$0")
while true; do
    socat -x -u TCP:127.0.0.1:9875 /dev/null 2>&1 | awk -f "$DIR/alice-text.awk"
    sleep 2
done
