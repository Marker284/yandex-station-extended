# Голосовой тракт Алисы

Как колонка слышит, распознаёт и отвечает. Снято с Amlogic-Станции (quasar 3.21): по
`quasar.cfg` (`audiod`, `aliced`, `audiosender`, `bio_capability`), моделям в `spotter_models/`
и `bio_lingware/`, путям исходников в `strings maind` и логам `maind.log`. Помечено *(вывод)*
то, что не подтверждено напрямую.

!!! abstract "Главное"
    На устройстве распознаётся **только ключевое слово и ~25 коротких команд**. Полное
    распознавание речи (ASR) и понимание (VINS/Megamind) — **в облаке** (`withLocalVins: false`).
    Без доступа к `uniproxy` колонка не превращает речь в текст.

```text
 4 PDM-микрофона ─┐                       maind --platformd (aliced)
 (ALSA card0 dev2 │   ┌──────────────┐    ┌─────────────────────────────────────┐
  "dmicarray",    ├──►│ Yandex VQE   │───►│ канал vqe_0 (16 кГц, моно)          │
  48 кГц, 4 кан.) │   │ AEC + beam-  │    │  ├─ activation spotter "алиса"/"яндекс"
 петля динамика ──┘   │ forming + NS │    │  ├─ counteractivation (ложные срабатывания)
 raw_spk_0/1          └──────────────┘    │  ├─ command spotter (стоп/громче/…)
 (эталон для эхоподавления)               │  └─ bio: ECAPA-TDNN голосовой отпечаток,
                                          │          пол/возраст (tflite)
                                          └──────────────┬──────────────────────┘
                                   срабатывание "Алиса"  │ earcon + LED
                                                         ▼
                              SpeechKit: Opus-кодирование (OggOpusEncoder)
                                                         │
                  wss://uniproxy.alice.yandex.net/uni.ws │ protobuf (useProtoAliceApi),
                                                         │ сжатие zstd
                                                         ▼
                ┌──────────────── облако Яндекса ────────────────────────┐
                │ VoiceInput → ASR (модель quasar-general, partials)      │
                │   → AsrResult (текст) → VINS/Megamind (смысл, навыки)   │
                │   → AliceResponse (директивы) + TtsSpeak (речь, Opus)   │
                └────────────────────────────┬───────────────────────────┘
                                             ▼
                   directive_sequencer → capabilities (музыка → mediad,
                   уведомления, будильники, громкость, GeoSync, …)
                   TTS → audio_client: appsrc ! opusparse ! opusdec ! alsasink
```

## 1. Захват звука — `audiod`

Внутри `maind --platformd`. ALSA card 0, device 2 (`PDM-dummy`, в конфиге `dmicarray`),
`inRate` 48000, `micChannels` 4, `spkChannels` 2, `outRate` 16000. Каналы
(`audiosender.availableChannels`): `raw_mic_0..3`, `raw_spk_0..1` (что играет динамик) и `vqe_0`.
`brokenMicDetector` следит за RMS микрофонов.

## 2. Обработка — Yandex VQE

`vqe.type: yandex`, `preset: yandexmini`, `omniMode: true`. Эхоподавление по `raw_spk_*` (Алиса
слышит вас поверх своей музыки), формирование луча, шумоподавление *(вывод по набору каналов)*.
Выход — канал **`vqe_0`**: его слушают спотеры (`spotterChannelName`) и его же отправляют в
облако (`speechkitLogChannels`).

Для Лайт 2 / Plum проверен [захват обработанного `vqe_0`](../recipes/microphone.md)
через экспортированный интерфейс VQE. Конфигурация Plum отличается от приведённого выше
профиля `yandexmini`: два микрофонных канала и один опорный, выход — моно 16 кГц.

## 3. Локальные нейросети

Движок `nnet`, признаки `cmn:lda`, модели в `spotter_models/` (обновляются с CDN Яндекса в
`/data/quasar/data/spotter_model`, сборочные — fallback):

| Модель | Задача |
|---|---|
| `activation/alisa`, `activation/yandex` | ключевые слова «Алиса» / «Яндекс», работают всегда |
| `counteractivation` | подавление ложных срабатываний (например «Алиса» из рекламы по ТВ) |
| `command` | ~25 команд **без** ключевого слова: дальше, назад, громче, тише, стоп, хватит, пауза, играй, включи/выключи, свет, телевизор, блютуз, лайк/дизлайк… (`words.txt`) |
| `vad` | `<speech_started>` / `<speech_finished>` |
| `bio_lingware/*` | голосовой отпечаток (ECAPA-TDNN) + пол/возраст — «узнавание» пользователя (`MatchedUser`, `Biometry.Classification`) |

Подтверждено логом: `command_spotter_capability.cpp: Command phrase spotted: ^ дизлайк`.

## 4. Активация → поток в облако (SpeechKit)

- На срабатывание: earcon (`playStartVoiceInputEarcon`, `activation_feedback_player`) и анимация LED.
- `RecognizerSession`/`Recorder` → `OggOpusEncoder` → `UniProxyImpl` по WebSocket на `uniProxyUrl`.
- Протокол: **protobuf Alice API** (`useProtoAliceApi: true`), сжатие **zstd** (`wsUseZstd: true`).
- Соединение держится постоянно (в логе `UniProxyProtocolState … PongTimeoutElapsed` при обрывах).

| Клиентские события | Серверные события |
|---|---|
| `VoiceInput`, `TextInput`, `AsrRecognize`, `LogSpotter`, `MatchedUser`, `TtsGenerate` | `InputStartAck`, `AsrResult`, `SpotterValidation`, `AliceResponse`, `TtsSpeak`, `TtsTimings` |

- `SpotterValidation` — сервер перепроверяет ключевое слово по присланному аудио *(вывод по названию)*.
- `vadEnabled: false` → конец фразы определяет **сервер**, а не локальный VAD.

## 5. Облако

ASR: `shortRecognizerModel: quasar-general`, промежуточные гипотезы (`enable_partials`).
`music_recognizer` — распознавание играющей музыки. Диалог и навыки — VINS/Megamind;
`experiments`/`supportedFeatures` сообщают серверу, что умеет устройство (так он и отличает
«болталку» от команд умного дома — маршрутизация на стороне облака).

## 6. Ответ

- `AliceResponse` → `directive_sequencer routeDirective … via <Capability>` (в логе: `set_timezone`/
  `set_location` через GeoSyncCapability, `notify` через NotificationCapability).
- Речь: `TtsSpeak` → `audio_client_tts_player.cpp` → GStreamer:
  `appsrc ! opusparse ! opusdec ! volume ! alsasink`. Музыка — в `maind --mediad`.
- Текстовые запросы (из приложения) идут как `Vins.TextInput` и **минуют ASR**.

## Отправка аудио помимо запросов

`audiosender` держит кольцевой буфер `historySeconds: 10` по всем 7 каналам.
`cachingSoundLogSender` / `logsound/*` (`SoundLogStorage`, `UniProxyLogSender`,
`random_sound_logger`) отправляют «звуковые логи» срабатываний; случайная запись включена для
групп `allowedForRandomLoggingQuasmodromGroups: ["beta"]`.

## Что это значит для своего ASR/LLM

Это прямо отвечает на вопросы из [«Своя LLM вместо Алисы»](../recipes/llm.md):

- **Текст запроса без uniproxy не получить** — ASR облачный. Нужно либо перехватить поток на
  `uni.ws` (TLS + protobuf, как с quasar-бэкендом), либо забирать звук самостоятельно: каналы
  `vqe_0`/`raw_mic_*` живут внутри `maind`, ALSA-устройство `hw:0,2` занято `audiod`
  *(одновременный захват не проверялся)*.
- **Произнести свой текст** проще всего локально — через API glagol на порту 1961, как это
  делает интеграция YandexStation для Home Assistant (см. [Сеть → glagol](network.md#glagol));
  для Plum также проверен [вызов `START_VOCALIZE` через SSH](../recipes/sounds.md#native-tts).
  Оба варианта используют облачный синтез; из облака ответ приходит как `AliceResponse.TtsSpeak`.
- **Подмена адреса**: пиннинга сертификатов нет (см. [Подводные камни](gotchas.md)),
  `uniProxyUrl` можно увести на свой сервер, в том числе по `ws://` без TLS.
- **Рабочий пример** — [quasard](../recipes/llm.md#quasard): свой uniproxy (JSON и protobuf
  `AAPI`), ASR, LLM и TTS вместо облака.

!!! warning "Приватность"
    Колонка постоянно держит соединение с облаком, а для «beta»-групп может отправлять случайные
    звуковые фрагменты. При изоляции это стоит учитывать.
