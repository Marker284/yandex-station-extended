#!/bin/sh
# yandex-disable-telemetry.sh — отключение телеметрии (AppMetrica/clickdaemon,
# fluent-bit) на Яндекс Станциях на прошивке quasar / Buildroot, rootfs ro без
# verity. Запускать как root (adb/ssh). Проверено на Станции 3 (orion,
# factory-13), два устройства — см. docs/internals/telemetry.md в вики.
#
#   sh yandex-disable-telemetry.sh            # отключить (по умолчанию)
#   sh yandex-disable-telemetry.sh status     # показать текущее состояние
#   sh yandex-disable-telemetry.sh restore    # вернуть всё как было (из бэкапа)
#
# Что делает:
#   убирает задачи "telemetry" и "fluent-bitd" из launch.json, чтобы роли
#   maind --telemetry / maind --fluent-bitd вообще не стартовали. Остальные
#   роли (platformd, mediad, begemot, bulbik, ...) штатно переживают
#   отсутствие телеметрии: обращения к ней просто логируют таймаут
#   ("... service has expired"), без падений — это наблюдалось и до, и
#   после правки на живых колонках.
#   Правка делается с проверкой корректности и авто-откатом: если что-то не
#   так — launch.json остаётся исходным.
# Оригинал сохраняется в /data/opt/backup. Полностью обратимо (restore).
#
# После применения mount -o remount,ro / может разово отдать "Device or
# resource busy" без зависания — перезагрузка (reboot) решает и одновременно
# подтверждает, что правка переживает её.
set -u

Q=/system/vendor/quasar
LJ="$Q/launch.json"
BK=/data/opt/backup
TASKS="telemetry fluent-bitd"

say(){ echo "[*] $*"; }
err(){ echo "[!] $*" >&2; }

need_root(){ [ "$(id -u)" = 0 ] || { err "нужен root"; exit 1; }; }
rw(){ mount -o remount,rw / 2>/dev/null || { err "не удалось remount rw /"; exit 1; }; }
ro(){ sync; mount -o remount,ro / 2>/dev/null; }

backup(){
  mkdir -p "$BK" || return 1
  [ -s "$LJ" ] || return 1
  if [ ! -e "$BK/launch.json.orig" ] && [ ! -L "$BK/launch.json.orig" ]; then
    copy=$(mktemp "$BK/.launch.json.XXXXXX") || return 1
    cp -p "$LJ" "$copy" && cmp -s "$LJ" "$copy" &&
      mv "$copy" "$BK/launch.json.orig" || {
        rm -f "$copy"; return 1
      }
  fi
  [ -f "$BK/launch.json.orig" ] && [ -s "$BK/launch.json.orig" ] &&
    [ ! -L "$BK/launch.json.orig" ] || return 1
}

# грубая проверка launch.json: баланс { } [ ], есть рабочие демоны, нет
# убираемых ролей
json_ok(){
  f="$1"
  [ -s "$f" ] || return 1
  a=$(tr -cd '{' <"$f" | wc -c); b=$(tr -cd '}' <"$f" | wc -c)
  c=$(tr -cd '[' <"$f" | wc -c); d=$(tr -cd ']' <"$f" | wc -c)
  [ "$a" = "$b" ] && [ "$c" = "$d" ] || return 1
  grep -q -- '--mediad'    "$f" || return 1
  grep -q -- '--platformd' "$f" || return 1
  for t in $TASKS; do grep -q -- "--$t" "$f" && return 1; done
  return 0
}

# удалить task-объект, содержащий "--<task>": от его открывающей "{"-строки
# до ближайшей "}"/"}," строки. Рассчитано на pretty-printed launch.json
# (по одному полю на строку). Если формат иной — вернётся пусто/битое, и
# json_ok это отбракует, оставив исходный файл.
strip_task(){
  task="$1"
  awk -v pat="--$task" '
    { lines[NR]=$0 }
    index($0, pat) { key=NR }
    END{
      if (key==0) { for(i=1;i<=NR;i++) print lines[i]; exit }
      s=0; for(i=key;i>=1;i--){ if(lines[i] ~ /^[[:space:]]*\{[[:space:]]*$/){ s=i; break } }
      e=0; for(i=key;i<=NR;i++){ if(lines[i] ~ /^[[:space:]]*\},?[[:space:]]*$/){ e=i; break } }
      if (s==0 || e==0) { exit }   # границы не найдены -> пустой вывод -> json_ok отбракует
      for(i=1;i<=NR;i++){ if(i>=s && i<=e) continue; print lines[i] }
    }
  ' "$2"
}

# если удалённая задача была последней в массиве, у предыдущего элемента
# остаётся висячая запятая перед "]" — баланс {}/[] выше её не ловит
fix_trailing_commas(){
  awk '
    { lines[NR]=$0 }
    END{
      for(i=1;i<=NR;i++){
        if (lines[i] ~ /^[[:space:]]*\]/) {
          j=i-1
          while (j>=1 && lines[j] ~ /^[[:space:]]*$/) j--
          if (j>=1 && lines[j] ~ /,[[:space:]]*$/) sub(/,[[:space:]]*$/, "", lines[j])
        }
      }
      for(i=1;i<=NR;i++) print lines[i]
    }
  ' "$1"
}

do_disable(){
  need_root
  backup || { err "резервная копия не создана — launch.json не изменён"; exit 1; }
  rw
  TMP1=/tmp/.notlm.$$.1
  TMP2=/tmp/.notlm.$$.2

  cp "$LJ" "$TMP1"
  for t in $TASKS; do
    if grep -q -- "--$t" "$TMP1"; then
      strip_task "$t" "$TMP1" > "$TMP2" 2>/dev/null && mv "$TMP2" "$TMP1"
    fi
  done
  fix_trailing_commas "$TMP1" > "$TMP2" 2>/dev/null && mv "$TMP2" "$TMP1"

  if json_ok "$TMP1"; then
    cat "$TMP1" > "$LJ"
    say "telemetry и fluent-bitd убраны из launch.json"
  else
    err "правка launch.json не прошла проверку — оставляю исходный"
  fi
  rm -f "$TMP1" "$TMP2"

  ro
  echo
  say "ГОТОВО. Перезагрузи колонку: reboot"
}

do_restore(){
  need_root
  [ -f "$BK/launch.json.orig" ] && [ -s "$BK/launch.json.orig" ] &&
    [ ! -L "$BK/launch.json.orig" ] || { err "неполный бэкап $BK"; exit 1; }
  rw
  cp "$BK/launch.json.orig" "$LJ" && say "launch.json восстановлен"
  ro
  say "ГОТОВО. Перезагрузи колонку: reboot"
}

do_status(){
  echo "== статус телеметрии =="
  for t in $TASKS; do
    if grep -q -- "--$t" "$LJ" 2>/dev/null; then echo "launch.json : $t ПРИСУТСТВУЕТ"
    else echo "launch.json : $t убран"; fi
  done
  echo "-- процессы:"
  for t in $TASKS; do
    ps w 2>/dev/null | grep -q -- "[-]-$t" && echo "   maind --$t РАБОТАЕТ" || echo "   maind --$t не запущен"
  done
}

case "${1:-disable}" in
  disable) do_disable ;;
  restore) do_restore ;;
  status)  do_status ;;
  *) echo "usage: $0 [disable|status|restore]"; exit 1 ;;
esac
