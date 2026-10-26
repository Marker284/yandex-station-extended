#!/bin/sh
# Хук shairport-sync run_this_before_play_begins: забрать звуковую карту у maind --mediad.
# mediad может держать pcmC0D0p постоянно (PREPARED без воспроизведения) — тогда AirPlay
# подключается, но звука нет. quasar_launcher2 перезапускает mediad через ~5 с, и новый
# карту не берёт, пока ему не понадобится; shairport сам повторяет открытие ALSA.
#
# Лайт 2 (plum), прошивка 0.369.1.50: механизм проверен вручную (kill mediad -> карта свободна,
# shairport её занимает), хук в сборе не проверялся. На других моделях не проверялось.
# Подключение в /opt/etc/shairport-sync.conf:
#   sessioncontrol = { run_this_before_play_begins = "/opt/etc/airplay-take-audio.sh";
#                      wait_for_completion = "yes"; };
# Откат: убрать sessioncontrol из конфига.
for p in /proc/[0-9]*; do
  ls -l "$p/fd" 2>/dev/null | grep -q pcmC0D0p || continue
  case "$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)" in
    *maind\ --mediad*) kill "${p#/proc/}" ;;
  esac
done
exit 0
