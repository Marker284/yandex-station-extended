#!/bin/sh
# yandex-micro-kit.sh — Яндекс Станция Лайт/Micro (quasar/Buildroot, rootfs ro без verity)
# Одним заходом: 1) убирает авто-обновления (OTA), 2) включает и фиксирует сетевой ADB.
# Запускать как root на самой колонке (через adb/ssh). Полностью обратимо.
#
#   sh yandex-micro-kit.sh            # сделать всё (OTA off + ADB on&lock)  [по умолчанию]
#   sh yandex-micro-kit.sh status     # показать состояние
#   sh yandex-micro-kit.sh restore    # вернуть заводское поведение
#
set -u
Q=/system/vendor/quasar
LJ="$Q/launch.json"; PUB="$Q/ota_script.pub"; OTASH="$Q/device_ota_update.sh"
BK=/data/opt/backup
MQ=/data/quasar/activate_adb_quasmodrom
MN=/data/quasar/activate_network_adb

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
rw(){ mount -o remount,rw / 2>/dev/null || { err "remount rw / не удался"; exit 1; }; }
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

json_ok(){
  f="$1"; [ -s "$f" ] || return 1
  a=$(tr -cd '{' <"$f"|wc -c); b=$(tr -cd '}' <"$f"|wc -c)
  c=$(tr -cd '[' <"$f"|wc -c); d=$(tr -cd ']' <"$f"|wc -c)
  [ "$a" = "$b" ] && [ "$c" = "$d" ] || return 1
  grep -q -- '--mediad' "$f" && grep -q -- '--platformd' "$f" || return 1
  grep -q -- '--updatesd' "$f" && return 1
  return 0
}

strip_updatesd(){
  awk '
    { lines[NR]=$0 }
    /--updatesd/ { key=NR }
    END{
      if (key==0){ for(i=1;i<=NR;i++) print lines[i]; exit }
      s=0; for(i=key;i>=1;i--){ if(lines[i] ~ /^[[:space:]]*\{[[:space:]]*$/){ s=i; break } }
      e=0; for(i=key;i<=NR;i++){ if(lines[i] ~ /^[[:space:]]*\},?[[:space:]]*$/){ e=i; break } }
      if (s==0 || e==0){ exit }
      for(i=1;i<=NR;i++){ if(i>=s && i<=e) continue; print lines[i] }
    }' "$1"
}

ota_off(){
  backup || { err "резервная копия не создана — системные файлы не изменены"; exit 1; }
  rw; TMP=/tmp/.kit.$$
  printf '%s\n' "$DUMMY_PUB" > "$PUB" && say "ota_script.pub -> чужой ключ (OTA не пройдёт подпись)"
  printf '#!/bin/sh\n# disabled by yandex-micro-kit\nlogger -t noupdate "OTA apply blocked" 2>/dev/null\nexit 0\n' > "$OTASH"
  chmod +x "$OTASH" && say "device_ota_update.sh -> заглушка (без flash/reboot)"
  if grep -q -- '--updatesd' "$LJ"; then
    strip_updatesd "$LJ" > "$TMP" 2>/dev/null
    if json_ok "$TMP"; then cat "$TMP" > "$LJ"; say "updatesd убран из launch.json"
    else err "launch.json не прошёл проверку -> оставлен исходный (защита на ключе/аплаере)"; fi
    rm -f "$TMP"
  else say "updatesd в launch.json уже нет"; fi
  ro
}

adb_on(){
  # создать маркеры -> onboot поднимет сетевой adbd; запустить сразу; зафиксировать chattr +i
  for m in "$MQ" "$MN"; do
    [ -e "$m" ] || : > "$m"
    chattr +i "$m" 2>/dev/null && say "маркер зафиксирован: $m" || say "маркер: $m (chattr +i не применился)"
  done
  pidof adbd >/dev/null 2>&1 || { start-stop-daemon -S -b -x adbd 2>/dev/null && say "adbd запущен (сеть, :5555)"; }
  pidof adbd >/dev/null 2>&1 && say "adbd работает" || err "adbd не поднялся"
}

do_all(){ need_root; ota_off; adb_on; echo; say "ГОТОВО. Перезагрузи: reboot"; }

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
  for m in "$MQ" "$MN"; do chattr -i "$m" 2>/dev/null && say "маркер разлочен: $m"; done
  say "ГОТОВО (OTA и управление ADB возвращены облаку). Перезагрузи: reboot"
}

do_status(){
  echo "== OTA =="
  grep -q -- '--updatesd' "$LJ" 2>/dev/null && echo "  launch.json : updatesd ЕСТЬ (апдейтер стартует)" || echo "  launch.json : updatesd убран"
  head -2 "$OTASH" 2>/dev/null | grep -q "disabled by yandex-micro-kit" && echo "  applier     : заглушён" || echo "  applier     : штатный"
  cmp -s "$PUB" "$BK/ota_script.pub.orig" 2>/dev/null && echo "  ota key     : штатный" || echo "  ota key     : подменён"
  ps w 2>/dev/null | grep -q -- '[-]-updatesd' && echo "  процесс     : maind --updatesd РАБОТАЕТ" || echo "  процесс     : updatesd не запущен"
  echo "== ADB =="
  for m in "$MQ" "$MN"; do
    if [ -e "$m" ]; then lsattr "$m" 2>/dev/null | grep -q 'i' && echo "  $(basename "$m"): есть, immutable" || echo "  $(basename "$m"): есть, НЕ immutable"
    else echo "  $(basename "$m"): НЕТ"; fi
  done
  pidof adbd >/dev/null 2>&1 && echo "  adbd        : работает" || echo "  adbd        : не запущен"
}

case "${1:-all}" in
  all|disable) do_all ;;
  restore)     do_restore ;;
  status)      do_status ;;
  *) echo "usage: $0 [all|status|restore]"; exit 1 ;;
esac
