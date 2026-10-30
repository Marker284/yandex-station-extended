#!/bin/sh
# YouTube Music с консоли колонки:
#   ytm.sh play [auto|track|album|playlist] <запрос>
#   ytm.sh pause | resume | next | prev | stop | status | queue
#   ytm.sh update — свежий yt-dlp с GitHub (YouTube часто ломает старые версии)
. /data/local/opt/ap2/common.sh
PY=/opt/bin/python3
Y=$AP/ytm

update() {
  [ -x /opt/bin/curl ] || { echo "нет /opt/bin/curl — нужен Entware (yse bootstrap)" >&2; return 1; }
  tmp=$Y/yt-dlp.zip
  /opt/bin/curl -fsSL -o "$tmp" https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp ||
    { rm -f "$tmp"; return 1; }
  # zip-приложение распаковываем и компилируем заранее: из архива импорт на колонке на секунды дольше
  rm -rf "$Y/lib.new"
  "$PY" -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$tmp" "$Y/lib.new" &&
    "$PY" -m compileall -q "$Y/lib.new/yt_dlp" >/dev/null || { rm -rf "$tmp" "$Y/lib.new"; return 1; }
  rm -rf "$tmp" "$Y/lib.old"
  [ -d "$Y/lib" ] && mv "$Y/lib" "$Y/lib.old"
  mv "$Y/lib.new" "$Y/lib" && rm -rf "$Y/lib.old"
  echo "yt-dlp $("$PY" "$Y/lib" --version)"
  # демон держит yt-dlp в памяти — перезапуск подхватит новую версию
  for p in $(pids_matching "$Y/ytmd.py"); do kill "$p" 2>/dev/null; done
  "$AP/ap2.sh" ytm
}

case "${1:-}" in
  update) update ;;
  play)
    shift
    case "${1:-}" in auto|track|album|playlist) mode=$1; shift ;; *) mode=auto ;; esac
    [ -n "$*" ] || { echo "usage: $0 play [auto|track|album|playlist] <запрос>" >&2; exit 1; }
    exec "$PY" "$Y/ytmd.py" ctl play "$mode" "$*" ;;
  pause|resume|next|prev|stop|status|queue) exec "$PY" "$Y/ytmd.py" ctl "$1" ;;
  *) echo "usage: $0 play [auto|track|album|playlist] <запрос> | pause | resume | next | prev | stop | status | queue | update" >&2
     exit 1 ;;
esac
