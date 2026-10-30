#!/bin/sh
# Вывод YouTube Music: ytmd.py запускает его на каждый трек и убивает на паузе и стопе;
# звук приходит на stdin (S16LE, 44,1 кГц, стерео) от ytm-dec. Устройство держит медиа-демон
# колонки — освобождаем его, как для Spotify.
. /data/local/opt/ap2/common.sh
i=0
while pcm_busy && [ "$i" -lt 30 ]; do
  for p in $(pids_matching "$MEDIAD_MATCH"); do kill -9 "$p" 2>/dev/null; done
  sleep 0.2
  i=$((i+1))
done
export ALSA_CONFIG_PATH=$E/asound.conf
# shellcheck disable=SC2046
exec $(audio_prio) "$B/aplay" -q -D youtube -f S16_LE -c 2 -r 44100 -t raw --buffer-time=500000
