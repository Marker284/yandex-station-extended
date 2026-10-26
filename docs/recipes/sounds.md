# Свои звуки

В прошивке есть GStreamer: через `maind --gst-launch` колонка проигрывает файлы и
интернет-потоки без дополнительного софта.

## Проиграть файл или поток

```sh
cd /system/vendor/quasar
LD_LIBRARY_PATH=/system/vendor/quasar:libs ./maind --gst-launch \
  "filesrc location=/data/sounds/my.mp3 ! decodebin ! audioconvert ! audioresample ! alsasink"
```

Поток: замените `filesrc location=…` на `souphttpsrc location=http://…`.
Звук идёт в ALSA `default`, то есть туда же, куда и Алиса, и регулируется её громкостью.

## Озвучить свой текст голосом Алисы { #native-tts }

Проверено на **Лайт 2 YNDX-00028 / Plum**, прошивка
`0.369.1.50.4794654278.20261021.133`. Используется действующая авторизация колонки
и **облачный TTS Яндекса**; локальный синтез этим способом не запускается.

1. Подготовьте на ПК Python 3.11+ и OpenSSH, а на колонке — root-SSH и `socat`.
   Настройте SSH-псевдоним `alice` со своим адресом, портом и ключом.
   Заранее проверьте ключ хоста: скрипт использует `StrictHostKeyChecking=yes`
   и не запрашивает интерактивный пароль.
2. Закройте сторонний голосовой чат и дождитесь окончания текущего ответа Алисы.
   Нужны работающий Quasar, привязка к аккаунту и интернет у колонки.
3. В каталоге клонированного репозитория этой вики запустите
   [contrib/alice-say.py][alice-say]:

    ```sh
    python3 contrib/alice-say.py --host alice 'Привет! Это мой текст.'
    ```

Для проверки сборки запроса без SSH и без звука:

```sh
python3 contrib/alice-say.py --dry-run 'Проверка синтеза речи.'
```

Скрипт не требует Python-библиотек проекта GPT и ничего не устанавливает на колонку.
Текст передаётся по stdin SSH, а не подставляется в удалённую shell-команду.
Ключи и токены Яндекса не извлекаются, системные файлы и автозапуск не меняются.

### Интерфейс и проверка результата { #native-tts-protocol }

SSH запускает `socat` к локальному IPC `127.0.0.1:9875` **на колонке**;
открывать этот порт для сети не требуется. Формат — длина uint32 little-endian,
затем protobuf. В `Remoting` выбирается `AliceCapability`, метод
`START_VOCALIZE` (18), `events=true` и `TVocalizeDirective` с текстом и режимом `Append` (1).
Формат сопоставлен со [схемой AliceCapability][alice-proto].

Клиент сначала подписывается на `AliceCapabilityListener`, затем ждёт
`TTS_STARTED` (6) и `TTS_COMPLETED` (1). По умолчанию ожидание ограничено 30 секундами;
для длинной фразы можно задать `--timeout 60`, максимум — 120 секунд.
Допускается до 2000 символов текста; длинные фразы отдельно не испытывались на устройстве.

Протокол проверен короткой фразой: получены события начала/конца озвучки и переход
`SPEAKING → IDLE`. Новый самостоятельный клиент использует тот же пакет, что проверенный
ранее вспомогательный скрипт. Его тесты не подключаются к колонке:

```sh
python3 -m unittest discover -s contrib/tests -v
```

Клиент ожидает события TTS без сопоставления идентификатора конкретной реплики,
поэтому параллельную озвучку нужно исключить. Тайм-аут или разрыв SSH означает отсутствие
подтверждения; он не доказывает, что колонка не успела начать говорить.

[alice-say]: https://github.com/Marker284/yandex-station-extended/blob/main/contrib/alice-say.py
[alice-proto]: https://github.com/v3rt3p/quasar-protos/blob/master/alice/protos/endpoint/capabilities/alice/capability.proto

## Звук при включении (Mac Chime)

Файл в репозитории: [`contrib/packages/mac-startup-chime-t2.mp3`](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/packages/mac-startup-chime-t2.mp3).

```sh
adb shell mkdir -p /data/sounds
adb push contrib/packages/mac-startup-chime-t2.mp3 /data/sounds/chime.mp3
adb shell
mount -o remount,rw /
cat > /etc/init.d/S98chime <<'EOF'
#!/bin/sh
[ "$1" = start ] || exit 0
cd /system/vendor/quasar
LD_LIBRARY_PATH=/system/vendor/quasar:libs ./maind --gst-launch \
  "filesrc location=/data/sounds/chime.mp3 ! decodebin ! audioconvert ! audioresample ! alsasink" \
  >/dev/null 2>&1 &
EOF
chmod +x /etc/init.d/S98chime
sync; mount -o remount,ro /
```

Удалить: `rm /etc/init.d/S98chime` (rootfs в `rw`).

## Системные звуки

Лежат в `/system/vendor/quasar/sounds/`: `common/` (общие: `spotter_start.opus`,
`spotter_cancel.opus`, `volume_sound.opus`, `notification_sound.opus`, `timer.opus`,
`calls_*`…) и `ru-RU/` (фразы). Формат — Ogg Opus.

Конвертировать свой файл:

```sh
ffmpeg -i my.mp3 -c:a libopus -ar 48000 -ac 1 -b:a 64k my.opus
```

Заменить системный звук можно в rootfs (`mount -o remount,rw /`), **сохранив оригинал**.
Подхватывает ли его Алиса без перезагрузки — не проверяли.
