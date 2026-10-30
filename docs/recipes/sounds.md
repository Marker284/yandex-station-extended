# Свои звуки

В прошивке есть GStreamer: через `maind --gst-launch` колонка проигрывает файлы и
интернет-потоки без дополнительного софта.

## Проиграть файл или поток

```sh
cd /system/vendor/quasar
LD_LIBRARY_PATH=/system/vendor/quasar:libs ./maind --gst-launch \
  "filesrc location=/data/sounds/my.mp3 ! decodebin ! audioconvert ! audioresample ! alsasink"
```

Поток: замените `filesrc location=…` на `souphttpsrc location=<URL>`.
Звук идёт в ALSA default, то есть туда же, куда и Алиса, и регулируется её громкостью.

## Озвучить свой текст голосом Алисы { #native-tts }

Проверено на **Лайт 2 YNDX-00028 / Plum**, прошивка
`0.369.1.50.4794654278.20261021.133`, и на [Fiero Hi](../devices/fiero-hi.md), прошивка
`0.369.1.50.4794652826.20261021.126`. Используется действующая авторизация колонки
и **облачный TTS Яндекса**; локальный синтез этим способом не запускается.

1. Подготовьте на ПК Python 3.11+ и OpenSSH, а на колонке — root-SSH и `socat`
   (`socat` из Entware в `/opt/bin` скрипт находит сам).
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

??? note "Если root получен через AliceBridge"
    Root-SSH и `socat` ставятся с телефона в [AliceBridge](../start/root-android.md),
    без компьютера:

    1. В панели управления колонки установите **YSE/Entware** и **SSH**
       (пользователь `root`, порт `2222`).
    2. В интерактивном терминале колонки смените пароль `1` на свой и поставьте `socat`:

        ```sh
        passwd
        /data/opt/bin/yse install socat
        ```

    3. На ПК добавьте ключ для входа без пароля по [инструкции SSH](../start/ssh.md)
       и укажите порт в псевдониме:

        ```text
        Host alice
            HostName <IP колонки>
            User root
            Port 2222
        ```

    Дальше — шаги 2 и 3 выше. AliceBridge подключается к Fiero Hi и определяет её
    как Станцию Лайт 1. Установка `socat` из приложения и запуск клиента после неё
    на Fiero Hi отдельно не проверялись.

Для проверки сборки запроса без SSH и без звука:

```sh
python3 contrib/alice-say.py --dry-run 'Проверка синтеза речи.'
```

На колонку скрипт ничего не ставит: текст уходит по stdin SSH, ключи и токены Яндекса
не извлекаются, системные файлы и автозапуск не меняются.

### Интерфейс и проверка результата { #native-tts-protocol }

SSH запускает `socat` к локальному IPC `127.0.0.1:9875` **на колонке**;
открывать этот порт для сети не требуется. Формат — длина uint32 little-endian,
затем protobuf. В `Remoting` выбирается `AliceCapability`, метод
`START_VOCALIZE` (18), `events=true` и `TVocalizeDirective` с текстом и режимом `Append` (1).
Формат сопоставлен со [схемой AliceCapability][alice-proto].

Клиент сначала подписывается на `AliceCapabilityListener`, затем ждёт в поле 18
`TTS_STARTED` (6) и `TTS_COMPLETED` (1); на Fiero Hi между ними приходит ещё событие 5.
Кадры событий от `aliced` помечены `253=3`, а на Fiero Hi — `253=210` с именем
`AliceCapability` в поле 7; клиент принимает оба варианта. По умолчанию ожидание
ограничено 30 секундами; для длинной фразы можно задать `--timeout 60`, максимум — 120 секунд.
Допускается до 2000 символов текста; длинные фразы отдельно не испытывались на устройстве.

Сам запрос проверен короткой фразой: на Plum получены события начала и конца озвучки
и переход `SPEAKING → IDLE`; на Fiero Hi клиент запущен целиком — вывод «Озвучка началась»
и «Колонка подтвердила завершение озвучки», а тот же запрос (байт в байт) подтверждён на слух.

!!! warning "Тайм-аут не значит, что колонка промолчала"
    На Plum запускался прежний вспомогательный скрипт, а не этот клиент. На Fiero Hi запрос,
    отправленный, пока Алиса ещё договаривала предыдущую фразу, событий не получил и
    закончился тайм-аутом — дождитесь конца ответа и повторите. О результатах на других
    моделях напишите в [обсуждениях](https://github.com/Marker284/yandex-station-extended/issues).

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

Удалить: `rm /etc/init.d/S98chime`, предварительно перемонтировав корневую файловую
систему на запись.

## Системные звуки

На свежих прошивках (проверено на Мини 2, 0.369.1.50) системные звуки лежат в
`/data/quasar/data/sounds/{common,ru-RU}/*.opus` — это rw-раздел (`/data` — симлинк на
`/bkupgrade/data`), замена не требует `remount,rw`. Путь `/system/vendor/quasar/sounds/`
относится к старым сборкам и factory-образам — там корень придётся перемонтировать.

Сигнал отклика на «Алису» берётся из набора `seam_activation_feedback_1..9.opus`: какой
прозвучит, решает секция `activation_feedback_player` в `quasar.cfg` (`probabilities`,
значения 11–100, по виду кумулятивные). Формат файлов — Opus 48 кГц, моно.

Лежат в `/system/vendor/quasar/sounds/`: `common/` (общие: `spotter_start.opus`,
`spotter_cancel.opus`, `volume_sound.opus`, `notification_sound.opus`, `timer.opus`,
`calls_*`…) и `ru-RU/` (фразы). Формат — Ogg Opus.

Конвертировать свой файл:

```sh
ffmpeg -i my.mp3 -c:a libopus -ar 48000 -ac 1 -b:a 64k my.opus
```

Заменить системный звук можно в rootfs (`mount -o remount,rw /`). Сначала заберите
оригинал к себе — на колонке запасной копии не останется:

```sh
adb pull /system/vendor/quasar/sounds/common/timer.opus ./timer.opus.orig
```

После замены перезагрузите колонку.

## Откат { #rollback }

- Звук при включении — `rm /etc/init.d/S98chime` (корень в режиме записи).
- Подменённые системные звуки — вернуть на место копии, снятые перед заменой:
  `adb push ./timer.opus.orig /system/vendor/quasar/sounds/common/timer.opus`.
- Проигрывание через GStreamer и озвучивание текста ничего на колонке не меняют:
  убирать нечего.
