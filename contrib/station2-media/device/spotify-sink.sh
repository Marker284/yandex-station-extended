#!/bin/sh
# Вывод librespot (--backend subprocess). librespot запускает его на старте
# воспроизведения и убивает на паузе и стопе; звук приходит на stdin (S16LE, 44,1 кГц,
# стерео). Устройство держит медиа-демон колонки — освобождаем его, как для AirPlay.
. /data/local/opt/ap2/common.sh
i=0
while pcm_busy && [ "$i" -lt 30 ]; do
  for p in $(pids_matching "$MEDIAD_MATCH"); do kill -9 "$p" 2>/dev/null; done
  sleep 0.2
  i=$((i+1))
done
export ALSA_CONFIG_PATH=$E/asound.conf
# буфер 0,5 с переживает короткие провалы сети и процессора
# shellcheck disable=SC2046
exec $(audio_prio) "$B/aplay" -q -D spotify -f S16_LE -c 2 -r 44100 -t raw --buffer-time=500000
