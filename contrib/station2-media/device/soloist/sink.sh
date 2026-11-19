#!/bin/sh
# Вывод Soloist: PCM из FIFO PulseAudio (S16LE, 44,1 кГц, стерео) на колонку. Как
# spotify-sink.sh у librespot, но устройство spotify_solo — мимо регулятора Master
# (громкость и так делает усилитель, см. apply_gain в soloist.sh).
# Если Алиса успела включить Яндекс Музыку, её медиа-демон занимает устройство сразу после
# kill: поэтому убить и тут же открыть, при «Resource busy» — снова.
. /data/local/opt/ap2/common.sh
export ALSA_CONFIG_PATH=$E/asound.conf
i=0
while [ "$i" -lt 40 ]; do
  for p in $(pids_matching "$MEDIAD_MATCH"); do kill -9 "$p" 2>/dev/null; done
  t0=$(date +%s)
  # shellcheck disable=SC2046
  $(audio_prio) "$B/aplay" -q -D spotify_solo -f S16_LE -c 2 -r 44100 -t raw \
    --buffer-time=500000 < /run/soloist/pcm.fifo
  # играл дольше пары секунд — закончил штатно (пауза, остановка)
  [ $(( $(date +%s) - t0 )) -ge 3 ] && exit 0
  i=$((i+1))
  sleep 0.1
done
exit 1
