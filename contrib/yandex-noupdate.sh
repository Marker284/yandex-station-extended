#!/bin/sh
# yandex-noupdate.sh — отключение авто-обновлений (OTA) на Яндекс Станции Лайт/Micro
# Прошивка quasar / Buildroot, rootfs ro без verity. Запускать как root (adb/ssh).
#
#   sh yandex-noupdate.sh            # отключить обновления (по умолчанию)
#   sh yandex-noupdate.sh status     # показать текущее состояние
#   sh yandex-noupdate.sh restore    # вернуть всё как было (из бэкапа)
#
# Что делает:
#   1) подменяет /system/vendor/quasar/ota_script.pub на чужой RSA-ключ
#      -> любой OTA-пакет проваливает проверку подписи и отвергается (главная защита);
#   2) заглушает /system/vendor/quasar/device_ota_update.sh (на всякий случай, без reboot);
#   3) пытается убрать задачу "updatesd" из launch.json (чтобы апдейтер вообще не стартовал).
#      Эта правка делается с проверкой корректности и авто-откатом: если что-то не так —
#      launch.json остаётся исходным, а защита держится на пунктах 1-2.
# Оригиналы сохраняются в /data/opt/backup. Полностью обратимо (restore).
set -u

Q=/system/vendor/quasar
LJ="$Q/launch.json"
PUB="$Q/ota_script.pub"
OTASH="$Q/device_ota_update.sh"
BK=/data/opt/backup

DUMMY_PUB='-----BEGIN RSA PUBLIC KEY-----
MIIBCgKCAQEAjQ29hAZE6u/Tly4UA7VIrzN+TweZM0nWT6L0HkYR2evczsdMPhZL
NZxzoZYt5ogstEMydG20xAs9m/k6qZ65sDiLkO9uNaGkR7JUn4+/0bOgJ7MWqgkU
hduLRgRsTQeOjuS16rjwnBxo5vwmb6P2cH+pof9Mri0IOHMuquQzF17YD7vxVIg8
w0c9FEyuoxc0DuedVVU2E9paPp5BkaUtkAqbz7hGzfij9aH8FBg/AkY5CKsFrdPo
gyVfA4qg84zQ7Y7PT7i1WSxPk4ShFtwYO5hYaEiZ+fCsf8Pp8Nd8RSa2kuObXE2X
Qt5QqXHjDoI9jyBgx7igBWAKHvQBwix/AwIDAQAB
-----END RSA PUBLIC KEY-----'

say(){ echo "[*] $*"; }
err(){ echo "[!] $*" >&2; }

need_root(){ [ "$(id -u)" = 0 ] || { err "нужен root"; exit 1; }; }
rw(){ mount -o remount,rw / 2>/dev/null || { err "не удалось remount rw /"; exit 1; }; }
ro(){ sync; mount -o remount,ro / 2>/dev/null; }

backup(){
  mkdir -p "$BK" || return 1
  for name in launch.json ota_script.pub device_ota_update.sh; do
    [ -s "$Q/$name" ] || return 1
    if [ ! -e "$BK/$name.orig" ] && [ ! -L "$BK/$name.orig" ]; then
      copy=$(mktemp "$BK/.$name.XXXXXX") || return 1
      cp -p "$Q/$name" "$copy" && cmp -s "$Q/$name" "$copy" &&
        mv "$copy" "$BK/$name.orig" || {
          rm -f "$copy"; return 1
        }
    fi
    [ -f "$BK/$name.orig" ] && [ -s "$BK/$name.orig" ] &&
      [ ! -L "$BK/$name.orig" ] || return 1
  done
}

# грубая проверка launch.json: баланс { } [ ], есть рабочие демоны, нет updatesd
json_ok(){
  f="$1"
  [ -s "$f" ] || return 1
  a=$(tr -cd '{' <"$f" | wc -c); b=$(tr -cd '}' <"$f" | wc -c)
  c=$(tr -cd '[' <"$f" | wc -c); d=$(tr -cd ']' <"$f" | wc -c)
  [ "$a" = "$b" ] && [ "$c" = "$d" ] || return 1
  grep -q -- '--mediad'   "$f" || return 1
  grep -q -- '--platformd' "$f" || return 1
  grep -q -- '--updatesd' "$f" && return 1
  return 0
}

# удалить task-объект, содержащий "--updatesd": от его открывающей "{"-строки
# до ближайшей "}"/"}," строки. Рассчитано на pretty-printed launch.json
# (по одному полю на строку). Если формат иной — вернётся пусто/битое, и
# json_ok это отбракует, оставив исходный файл.
strip_updatesd(){
  awk '
    { lines[NR]=$0 }
    /--updatesd/ { key=NR }
    END{
      if (key==0) { for(i=1;i<=NR;i++) print lines[i]; exit }
      s=0; for(i=key;i>=1;i--){ if(lines[i] ~ /^[[:space:]]*\{[[:space:]]*$/){ s=i; break } }
      e=0; for(i=key;i<=NR;i++){ if(lines[i] ~ /^[[:space:]]*\},?[[:space:]]*$/){ e=i; break } }
      if (s==0 || e==0) { exit }   # границы не найдены -> пустой вывод -> json_ok отбракует
      for(i=1;i<=NR;i++){ if(i>=s && i<=e) continue; print lines[i] }
    }
  ' "$1"
}

do_disable(){
  need_root
  backup || { err "резервная копия не создана — системные файлы не изменены"; exit 1; }
  rw
  TMP=/tmp/.noupd.$$

  # 1) левый OTA-ключ
  printf '%s\n' "$DUMMY_PUB" > "$PUB" && say "ota_script.pub заменён на чужой ключ"

  # 2) заглушка аплаера (без flash, без reboot)
  printf '#!/bin/sh\n# disabled by yandex-noupdate.sh\nlogger -t noupdate "OTA apply blocked" 2>/dev/null\nexit 0\n' > "$OTASH"
  chmod +x "$OTASH" && say "device_ota_update.sh заглушён"

  # 3) убрать updatesd из launch.json (с проверкой + откатом)
  if grep -q -- '--updatesd' "$LJ"; then
    strip_updatesd "$LJ" > "$TMP" 2>/dev/null
    if json_ok "$TMP"; then
      cat "$TMP" > "$LJ"; say "updatesd убран из launch.json"
    else
      err "правка launch.json не прошла проверку — оставляю исходный (защита держится на ключе/аплаере)"
    fi
    rm -f "$TMP"
  else
    say "updatesd в launch.json уже нет"
  fi

  ro
  echo
  say "ГОТОВО. Перезагрузи колонку: reboot"
}

do_restore(){
  need_root
  for name in launch.json ota_script.pub device_ota_update.sh; do
    [ -f "$BK/$name.orig" ] && [ -s "$BK/$name.orig" ] &&
      [ ! -L "$BK/$name.orig" ] || { err "неполный бэкап $BK"; exit 1; }
  done
  rw
  [ -f "$BK/ota_script.pub.orig" ]       && cp "$BK/ota_script.pub.orig"       "$PUB"   && say "ota_script.pub восстановлен"
  [ -f "$BK/device_ota_update.sh.orig" ] && cp "$BK/device_ota_update.sh.orig" "$OTASH" && chmod +x "$OTASH" && say "device_ota_update.sh восстановлен"
  [ -f "$BK/launch.json.orig" ]          && cp "$BK/launch.json.orig"          "$LJ"    && say "launch.json восстановлен"
  ro
  say "ГОТОВО. Перезагрузи колонку: reboot"
}

do_status(){
  echo "== статус обновлений =="
  if grep -q -- '--updatesd' "$LJ" 2>/dev/null; then echo "launch.json : updatesd ПРИСУТСТВУЕТ (апдейтер стартует)"
  else echo "launch.json : updatesd убран"; fi
  if head -2 "$OTASH" 2>/dev/null | grep -q "disabled by yandex-noupdate"; then echo "applier     : заглушён"
  else echo "applier     : штатный"; fi
  if cmp -s "$PUB" "$BK/ota_script.pub.orig" 2>/dev/null; then echo "ota key     : штатный (или бэкап совпал)"
  else echo "ota key     : подменён"; fi
  echo "-- процессы апдейтера:"
  ps w 2>/dev/null | grep -q -- '[-]-updatesd' && echo "   maind --updatesd РАБОТАЕТ" || echo "   maind --updatesd не запущен"
}

case "${1:-disable}" in
  disable) do_disable ;;
  restore) do_restore ;;
  status)  do_status ;;
  *) echo "usage: $0 [disable|status|restore]"; exit 1 ;;
esac
