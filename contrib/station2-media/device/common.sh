# Общие функции для ap2.sh и audio-owner.sh (подключается через «.»).
AP=/data/local/opt/ap2
B=$AP/bin
E=$AP/etc
LOGD=/data/local/tmp/ap2
MEDIAD_BIN=/system/vendor/quasar/maind
MEDIAD_MATCH="$MEDIAD_BIN --mediad"
# Имя колонки в Spotify Connect (librespot) и в поиске устройства через Web API
SPOTIFY_NAME="Станция 2"
export DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/ap2_bus
# из SSH-сессии dropbear приходит PATH=/usr/bin:/bin, а start-stop-daemon лежит в /sbin
export PATH=/sbin:/usr/sbin:/bin:/usr/bin

mkdir -p "$LOGD"

# Поиск процессов по подстроке командной строки. Один ps на весь список (перебор
# /proc с tr на каждый процесс стоил ~0,5 с и сотни запусков программ за проход).
# Шаблон идёт через окружение, а не аргументом: иначе awk находил бы сам себя, а
# ps|grep — того, кто его запустил; свою оболочку и родителя исключаем явно.
pids_matching() {
  ps -o pid,args 2>/dev/null | PAT=$1 ME=$$ PARENT=$PPID awk '
    NR > 1 {
      line = $0; sub(/^ *[0-9]+ /, "", line)
      if (index(line, ENVIRON["PAT"]) && $1 != ENVIRON["ME"] && $1 != ENVIRON["PARENT"]) print $1
    }'
}

holds_pcm() { # pid — держит ли процесс устройство воспроизведения
  [ -n "$1" ] || return 1
  for f in /proc/$1/fd/*; do
    case "$(readlink "$f" 2>/dev/null)" in *pcmC0D0p*) return 0;; esac
  done
  return 1
}

pcm_busy() {
  for f in /proc/[0-9]*/fd/*; do
    case "$(readlink "$f" 2>/dev/null)" in *pcmC0D0p*) return 0;; esac
  done
  return 1
}

# Префикс запуска для звуковых процессов: реальное время, если ядро разрешает, иначе
# nice. Без него вывод звука делит процессор с демонами Яндекса и иногда заикается.
audio_prio() {
  if chrt -r 30 true 2>/dev/null; then echo "chrt -r 30"; else echo "nice -n -10"; fi
}

# Лог длиннее 1 МБ начинаем заново: /data маленький
trim_log() {
  [ -f "$1" ] && [ "$(wc -c < "$1")" -gt 1048576 ] && : > "$1"
  return 0
}

# Медиа-демон колонки (голос Алисы и её плеер). Лаунчер quasar поднимает его после
# падения не сразу (до 600 с), поэтому поднимаем сами и следим, чтобы он был один:
# два экземпляра дерутся за звук, и Алиса молчит.
start_mediad() {
  [ -x "$MEDIAD_BIN" ] || return 0
  PIDS=$(pids_matching "$MEDIAD_MATCH")
  N=$(printf '%s\n' "$PIDS" | grep -c .)
  if [ "$N" -gt 1 ]; then
    for p in $PIDS; do kill -9 "$p" 2>/dev/null; done
    sleep 2
    echo "$(date): убрал дубли mediad (было $N)" >> "$LOGD/owner.log"
    N=0
  fi
  if [ "$N" -eq 0 ]; then
    cd /data/quasar 2>/dev/null || cd /
    MALLOC_ARENA_MAX=2 CA_CERTIFICATES=/system/vendor/quasar/ca-certificates.crt \
      nohup "$MEDIAD_BIN" --mediad >> /data/quasar/mediad.log 2>&1 < /dev/null &
    echo "$(date): mediad поднят" >> "$LOGD/owner.log"
  fi
}
