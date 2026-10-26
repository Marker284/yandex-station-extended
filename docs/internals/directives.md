# Директивы и capabilities

Как бэкенд управляет колонкой. Сервер отвечает на запрос директивами: `AliceResponse` →
`directive_sequencer` → capabilities (общая схема — в [«Голосовом тракте Алисы»](voice.md)).
Снято со Станции Мини 2 (`yandexmini_2`, прошивка 0.369.1.46): по строкам бинаря
`/system/vendor/quasar/maind`, логу `/data/quasar/daemons_logs/maind.log`
(`directive_sequencer routeDirective … via <Capability>`), `quasar.cfg`, схемам
[v3rt3p/quasar-protos](https://github.com/v3rt3p/quasar-protos) и серверу
[v3rt3p/quasar-server](https://github.com/v3rt3p/quasar-server). Помечено *(вывод)* то, что не
подтверждено напрямую.

!!! abstract "Главное"
    На прошивке сосуществуют два поколения директив, и у них **разный провод**. Легаси-директивы
    принимают `google.protobuf.Struct` в `TDirective.Payload`. Typed-директивы (`*_directive`)
    Struct/JSON **не принимают**: им нужно сериализованное proto-сообщение в
    `TDirective.PayloadRaw` и номер в `TDirective.DirectiveType`.

## Легаси-директивы: Struct в `Payload` { #legacy }

Payload — `google.protobuf.Struct`, ключи в `snake_case`.

| Группа | Директивы и payload |
|---|---|
| Громкость | `sound_set_level` `{new_level, new_percent_level}`, `sound_louder`, `sound_quiter`, `sound_mute`, `sound_unmute` |
| Плеер | `player_pause` `{smooth: false}`, `player_continue`, `player_next_track`, `player_previous_track` |
| Bluetooth | `start_bluetooth`, `stop_bluetooth` |
| Легаси-таймеры | `set_timer` `{duration, listening_is_possible}`; `cancel_timer`, `pause_timer`, `resume_timer` `{timer_id}` |

Шкала громкости — 0–10 (`volume_capability` в `quasar.cfg`).

Подтверждение: имена директив и ключей — строковые литералы в `maind`; quasar-server шлёт их на
реальные станции; в логе колонки виден роутинг, например `player_previous_track` →
`PlaybackControlCapability`.

## Typed-директивы: proto в `PayloadRaw` { #typed }

`maind` собран с **protobuf-lite** — без рефлексии, поэтому перевести Struct/JSON в
proto-сообщение он не может. В логе:

```text
Try to convert directive to proto in no reflection IOSDK
alarm_capability.cpp: Cannot convert directive to proto: {"timer":…}
```

Такие директивы шлют **сериализованным** сообщением в `TDirective.PayloadRaw` (поле 15) и
обязательно с `TDirective.DirectiveType`:

| Директива | Сообщение в `PayloadRaw` | `DirectiveType` |
|---|---|---|
| `timer_set_directive` | `NAlice.TAlarmCapability.TTimerSetDirective` | 112 |
| `timer_cancel_directive` | `NAlice.TAlarmCapability.TTimerCancelDirective` | 113 |
| `timer_pause_directive` | `NAlice.TAlarmCapability.TTimerPauseDirective` | 114 |
| `timer_resume_directive` | `NAlice.TAlarmCapability.TTimerResumeDirective` | 115 |
| `timer_stop_directive` | `NAlice.TAlarmCapability.TTimerStopDirective` | 276 |
| `alarm_add_directive` | `NAlice.TAlarmCapability.TAlarmAddDirective` | 32 |
| `alarm_cancel_directive` | `NAlice.TAlarmCapability.TAlarmCancelDirective` | 132 |
| `alarm_snooze_directive` | `NAlice.TAlarmCapability.TAlarmSnoozeDirective` | 116 |
| `set_do_not_disturb_directive` | `NAlice.TDoNotDisturbCapability.TSetDoNotDisturbStateDirective` | 224 |

### Поля payload { #typed-payload }

Ниже — payload в `snake_case`, как его удобно собирать на стороне бэкенда; поля один к одному
ложатся на поля proto-сообщения из таблицы выше.

| Директива | Payload |
|---|---|
| `timer_set_directive` | `{timer: {timer_id, start_timestamp, duration, remaining}}` |
| `alarm_add_directive` | `{alarm: {alarm_id, local_time, timezone, activation_days, edit_timestamp}}` |
| `alarm_cancel_directive` | `{alarm_id}` |
| `alarm_snooze_directive` | `{alarm_id, duration_sec}` |
| `set_do_not_disturb_directive` | `{force_do_not_disturb_state: "ForceEnable" \| "ForceDisable"}` |

Остановить звенящий будильник — легаси-директива `alarm_stop` (Struct в `Payload`, без
полей).

Будильник целиком:

```json
{
  "alarm": {
    "alarm_id": "<ALARM_ID>",
    "local_time": {"hours": 7, "minutes": 30, "seconds": 0},
    "timezone": {"timezone_name": "Europe/Moscow", "offset_seconds": 10800},
    "activation_days": [{"weekday": "MONDAY"}, {"weekday": "FRIDAY"}],
    "edit_timestamp": 1790000000
  }
}
```

Разовый будильник — `activation_days: [{"date": {"year": 2026, "month": 10, "day": 27}}]`.
Enum передаётся **именем** (`"ForceEnable"`, `"MONDAY"`) — так же quasar-server передаёт
`audio_player_rewind.type`.

## Будильники без iCalendar { #alarms }

В `maind` этой прошивки нет кода iCalendar вообще — ни `BEGIN:VCALENDAR`, ни `DTSTART`, ни
`RRULE`. Поэтому классическая директива `alarms_update` `{state: <iCalendar>}` здесь не
разбирается. Будильники ставятся typed-директивами выше, а их список колонка отдаёт только через
`CapabilityUpdateState` (`TAlarmCapability.State.Alarms`).

## Что не путать { #pitfalls }

| Директива | На самом деле | Для колонки нужно |
|---|---|---|
| `stop_current_sound_alarm_directive` | `TIotSoundAlarmCapability` — сирены IoT-датчиков (протечка, дым) | звенящий будильник — `alarm_stop`, таймер — `timer_stop_directive` |
| `set_absolute_level_directive`, `set_relative_level_directive` | `TLevelCapability` — общий уровень endpoint'а (например, IoT-диммеры) | собственная громкость — `sound_*` |

## Состояние устройства { #state }

Колонка рапортует `TDeviceState` — громкость, плеер, таймеры (`ActiveTimers`), звенящий
будильник (`AlarmState.CurrentlyPlaying`):

- в каждом запросе — `VoiceInput`/`TextInput`, поле `Request.DeviceStateRaw`;
- отдельно — событием `CapabilityUpdateState`.

Список будильников в `TDeviceState` не приходит — только в `TAlarmCapability.State`.

## Источник { #source }

Снято в проекте syrinx — своём бэкенде для колонки (GPL-3.0, репозиторий в публикации).
Про подмену облачного адреса — [«Своя LLM вместо Алисы»](../recipes/llm.md) и
[«Колонка без Яндекса»](../recipes/standalone.md).
