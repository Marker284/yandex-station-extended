#!/bin/sh
# yandex-disable-wizard.sh — отключение begemot/bulbik на Яндекс Станциях на
# прошивке quasar / Buildroot, rootfs ro без verity. Запускать как root
# (adb/ssh). Проверено на Станции 3 (orion, factory-13), два устройства — см.
# docs/recipes/station3-disable-wizard.md в вики.
#
#   sh yandex-disable-wizard.sh            # отключить (по умолчанию)
#   sh yandex-disable-wizard.sh status     # показать текущее состояние
#   sh yandex-disable-wizard.sh restore    # вернуть всё как было (из бэкапа)
#
# Что делает:
#   убирает задачи "begemot" (поисковый wizard: погода, калькулятор) и
#   "bulbik" (сценарии умного дома/Megamind — 258MB бинарник с захардко-
#   женными облачными URL Яндекса: iot.quasar.yasmina.yango.com,
#   market.yandex.ru, avatars.mds.yandex.net, embedded YDB-клиент и grpc) из
#   launch.json. Оба — чисто облачные роли, без интернета бесполезны;
#   освобождает ~250MB RSS. ВАЖНО: базовая LED-индикация на физические
#   кнопки (mute, свайп громкости по кольцу, ambient, кнопка диалога) от
#   bulbik НЕ зависит — проверено нажатием кнопок на живых устройствах после
#   отключения. Что не проверялось — реальное срабатывание mute/смены
#   громкости/микрофона "под капотом" (без звука на момент проверки).
#   Бэкап отдельный от yandex-disable-telemetry.sh — откатывается
#   независимо от решения по телеметрии.
#   Правка делается с проверкой корректности и авто-откатом: если что-то не
#   так — launch.json остаётся исходным.
set -u

Q=/system/vendor/quasar
LJ="$Q/launch.json"
BK=/data/opt/backup
ORIG=$BK/launch.json.orig-pre-wizard
TASKS="begemot bulbik"

say(){ echo "[*] $*"; }
err(){ echo "[!] $*" >&2; }

need_root(){ [ "$(id -u)" = 0 ] || { err "нужен root"; exit 1; }; }
rw(){ mount -o remount,rw / 2>/dev/null || { err "не удалось remount rw /"; exit 1; }; }
ro(){ sync; mount -o remount,ro / 2>/dev/null; }

backup(){
  mkdir -p "$BK" || return 1
  [ -s "$LJ" ] || return 1
  if [ ! -e "$ORIG" ] && [ ! -L "$ORIG" ]; then
    copy=$(mktemp "$BK/.launch.json.wizard.XXXXXX") || return 1
    cp -p "$LJ" "$copy" && cmp -s "$LJ" "$copy" &&
      mv "$copy" "$ORIG" || { rm -f "$copy"; return 1; }
  fi
  [ -f "$ORIG" ] && [ -s "$ORIG" ] && [ ! -L "$ORIG" ] || return 1
}

json_ok(){
  f="$1"
  [ -s "$f" ] || return 1
  a=$(tr -cd '{' <"$f" | wc -c); b=$(tr -cd '}' <"$f" | wc -c)
  c=$(tr -cd '[' <"$f" | wc -c); d=$(tr -cd ']' <"$f" | wc -c)
  [ "$a" = "$b" ] && [ "$c" = "$d" ] || return 1
  grep -q -- '--mediad'    "$f" || return 1
  grep -q -- '--platformd' "$f" || return 1
  for t in $TASKS; do grep -q -- "\"name\": \"$t\"" "$f" && return 1; done
  return 0
}

strip_task(){
  task="$1"
  awk -v pat="\"name\": \"$task\"" '
    { lines[NR]=$0 }
    index($0, pat) { key=NR }
    END{
      if (key==0) { for(i=1;i<=NR;i++) print lines[i]; exit }
      s=0; for(i=key;i>=1;i--){ if(lines[i] ~ /^[[:space:]]*\{[[:space:]]*$/){ s=i; break } }
      e=0; for(i=key;i<=NR;i++){ if(lines[i] ~ /^[[:space:]]*\},?[[:space:]]*$/){ e=i; break } }
      if (s==0 || e==0) { exit }
      for(i=1;i<=NR;i++){ if(i>=s && i<=e) continue; print lines[i] }
    }
  ' "$2"
}

# если удалённая задача была последней в массиве, у предыдущего элемента
# остаётся висячая запятая перед "]" — баланс {}/[] её не ловит
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
  TMP1=/tmp/.nowiz.$$.1
  TMP2=/tmp/.nowiz.$$.2

  cp "$LJ" "$TMP1"
  for t in $TASKS; do
    if grep -q -- "\"name\": \"$t\"" "$TMP1"; then
      strip_task "$t" "$TMP1" > "$TMP2" 2>/dev/null && mv "$TMP2" "$TMP1"
    fi
  done
  fix_trailing_commas "$TMP1" > "$TMP2" 2>/dev/null && mv "$TMP2" "$TMP1"

  if json_ok "$TMP1"; then
    cat "$TMP1" > "$LJ"
    say "begemot и bulbik убраны из launch.json"
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
  [ -f "$ORIG" ] && [ -s "$ORIG" ] && [ ! -L "$ORIG" ] || { err "неполный бэкап $ORIG"; exit 1; }
  rw
  cp "$ORIG" "$LJ" && say "launch.json восстановлен (begemot/bulbik вернутся)"
  ro
  say "ГОТОВО. Перезагрузи колонку: reboot"
}

do_status(){
  echo "== статус begemot/bulbik =="
  for t in $TASKS; do
    if grep -q -- "\"name\": \"$t\"" "$LJ" 2>/dev/null; then echo "launch.json : $t ПРИСУТСТВУЕТ"
    else echo "launch.json : $t убран"; fi
  done
  echo "-- процессы:"
  for t in $TASKS; do
    # [b]ulbik вместо bulbik — иначе grep матчит свою же командную строку
    first=$(printf '%s' "$t" | cut -c1)
    rest=$(printf '%s' "$t" | cut -c2-)
    ps w 2>/dev/null | grep -q -- "/$t/[$first]$rest " && echo "   $t РАБОТАЕТ" || echo "   $t не запущен"
  done
}

case "${1:-disable}" in
  disable) do_disable ;;
  restore) do_restore ;;
  status)  do_status ;;
  *) echo "usage: $0 [disable|status|restore]"; exit 1 ;;
esac
