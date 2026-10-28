# Плееры как Bluetooth-источник Алисы (bt-proxy)

`bt-proxy` показывает Алисе любой MPRIS-плеер колонки как подключённый Bluetooth-телефон.
Дальше всё делает сама Алиса, штатной логикой Bluetooth:

- отдаёт плееру звук, когда он заиграл, и забирает обратно («Алиса, включи музыку»);
- понимает «дальше», «назад», «пауза», «продолжи», «тише»;
- уступает звук, пока слушает, и показывает анимацию Bluetooth на кольце.

Источники не играют друг поверх друга: последний заигравший ставит остальных на паузу —
и другие плееры, и настоящие Bluetooth-телефоны.

MPRIS (`org.mpris.MediaPlayer2.*`) — стандартный D-Bus-интерфейс плееров Linux, его умеют
shairport-sync (`--with-mpris-interface`), spotifyd, mpd через mpd-mpris и другие. Писать код
под каждый плеер не нужно: появился на шине — появился у Алисы.

!!! info "Проверено на Станции Лайт 2 (plum), прошивка 0.369.1.50"
    С [AirPlay](airplay.md#lite2) (shairport-sync 5.6.2) и настоящим Bluetooth-телефоном
    одновременно; автозапуск — перезагрузкой. Другие плееры и модели не проверялись.

## Как это работает { #how }

`maind` узнаёт о Bluetooth по системной D-Bus: объекты службы `org.bluez` (BlueZ) и
`org.bluealsa`. Встать рядом нельзя — имя `org.bluez` у `bluetoothd`. Поэтому:

1. `bluetoothd`, `bluealsa`, `bluealsa-aplay` и агент сопряжения переезжают на приватную шину
   (`/tmp/btbus/socket`) — достаточно `DBUS_SYSTEM_BUS_ADDRESS` при запуске;
2. на системной шине имена `org.bluez` и `org.bluealsa` держит `bt-proxy` и пересылает всё как
   есть: вызовы `maind` — на приватную шину, ответы и сигналы — обратно, обратные вызовы
   `bluetoothd` в объекты клиентов — тому, кто их зарегистрировал. Тела и файловые дескрипторы
   не разбираются, поэтому настоящий Bluetooth работает как раньше;
3. MPRIS-плееры на приватной шине `bt-proxy` дорисовывает в ответы `org.bluez` виртуальными
   устройствами `dev_02_A1_*` и сам отвечает на вызовы к ним.

### Контракт `maind` { #contract }

Снят записью `dbus-monitor` во время настоящего Bluetooth-сеанса и сверен с `maind.log`.

| Объект | Что `maind` читает или делает |
|---|---|
| `Device1` | `Name`, `Address`, `Connected`; телеметрия `CurrentRSSI` (int16), `AFH` (string), `LQ`, `TPL` (int16) — свойства прошивки Яндекса |
| `MediaControl1` | `Connected`, `Player` |
| `…/fd0`, `MediaTransport1` | `State` (`idle` / `pending` / `active`), `Volume` uint16 0–127 — пишет сам: общая громкость |
| `…/player0`, `MediaPlayer1` | `Status`, `Track` (Title, Artist, Album, Duration); вызывает `Play`, `Pause`, `Next`, `Previous` |
| `org.bluealsa.PCM1` | `Underruns`, `SoftVolume` — только для настоящих устройств |

Последовательность подключения, на которую `maind` реагирует:

```text
InterfacesAdded  Device1 {Connected: false}
PropertiesChanged Device1 {Connected: true}
InterfacesAdded  MediaControl1 {Connected: true}
InterfacesAdded  …/fd0 (MediaTransport1), …/player0 (MediaPlayer1)
PropertiesChanged MediaControl1 {Player: …/player0, Connected: true}  ->  «Bt source connected»
PropertiesChanged MediaTransport1 State: pending -> active
PropertiesChanged MediaPlayer1 Status: playing  ->  «Bluetooth player is playing», «Take audio focus»
```

## Установка { #install }

Нужны root по SSH и `/data/opt` (`yse bootstrap` его создаёт). Для AirPlay на Лайт 2 всё это
делает [установщик](airplay.md#lite2) — шаги ниже нужны, если ставите bt-proxy для другого плеера.

1. Скопируйте на колонку [`contrib/bin/bt-proxy`](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/bin/bt-proxy)
   (статический ARMv7 musl, 1,2 МБ) и [`contrib/bt-proxy/bus.conf`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/bt-proxy/bus.conf)
   в `/data/opt/btproxy/`, сделайте `bt-proxy` исполняемым.
2. Отключите D-Bus-активацию `org.bluez` и поставьте автозапуск
   [`contrib/bt-proxy/S55zbtproxy`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/bt-proxy/S55zbtproxy):

    ```sh
    mount -o remount,rw /
    mv /usr/share/dbus-1/system-services/org.bluez.service \
       /usr/share/dbus-1/system-services/org.bluez.service.disabled
    cp S55zbtproxy /etc/init.d/ && chmod 755 /etc/init.d/S55zbtproxy
    mount -o remount,ro /
    reboot
    ```

3. Проверка после загрузки:

    ```sh
    dbus-send --system --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus \
      org.freedesktop.DBus.GetNameOwner string:org.bluez        # то же имя, что у bt-proxy
    tr '\0' '\n' < /proc/$(pidof bluetoothd)/environ | grep DBUS  # unix:path=/tmp/btbus/socket
    cat /tmp/bt-proxy.log                                         # найденные плееры
    ```

Плеер подключается так: запустите его с `DBUS_SYSTEM_BUS_ADDRESS=unix:path=/tmp/btbus/socket`
(шина пускает только root). Имя, которое увидит Алиса, задаёт `ALIASES` в `S55zbtproxy`
по суффиксу MPRIS-имени: `ShairportSync=AirPlay,spotifyd=Spotify`.

## Откат { #rollback }

Удалить `/etc/init.d/S55zbtproxy`, вернуть `org.bluez.service.disabled` на место
и перезагрузиться.

### Переменные `bt-proxy` { #env }

| Переменная | Что задаёт |
|---|---|
| `BT_PRIVATE_BUS` | адрес приватной шины, по умолчанию `unix:path=/tmp/btbus/socket` |
| `MPRIS_BUS` | шина плееров, по умолчанию та же приватная |
| `BT_PROXY_ALIASES` | имена устройств у Алисы, `суффикс=имя,…` |
| `BT_PROXY_FAKE` | отладка: сразу устройство с этим именем в статусе Playing, без плеера |

Сборка из исходников — [`contrib/bt-proxy/build.sh`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/bt-proxy/build.sh)
(Rust, `cargo-zigbuild`).

## Как подключить свой плеер { #player }

Плееру не нужно знать ни про `bt-proxy`, ни про Алису — нужны четыре условия.

1. **MPRIS** (`org.mpris.MediaPlayer2.<имя>`, интерфейс `org.mpris.MediaPlayer2.Player`):

    | Что | Зачем |
    |---|---|
    | `PlaybackStatus`: `Playing` / `Paused` / `Stopped` | кто играет: фокус Алисы и пауза остальных |
    | `Metadata`: `xesam:title`, `xesam:artist`, `xesam:album`, `mpris:length` | название трека |
    | `Volume` 0–1 (если есть) | общая громкость: `MediaTransport1.Volume` 0–127 |
    | `Play`, `Pause`, `Next`, `Previous`, `Stop` | «продолжи», «пауза», «дальше», «назад» |
    | сигнал `PropertiesChanged` при каждом изменении | `bt-proxy` не опрашивает плеер |

    Устройство появляется у Алисы при первом `Playing`, после `Stopped` живёт ещё минуту и
    сразу исчезает, когда плеер уходит с шины.

2. **Приватная шина.** Плеер запускается от root с
   `DBUS_SYSTEM_BUS_ADDRESS=unix:path=/tmp/btbus/socket` и регистрирует MPRIS на «системной»
   шине. Плееры, умеющие только сессионную шину, переключите в системный режим.
3. **Звук через штатную alsa-lib колонки.** Чтобы ответы Алисы звучали поверх музыки, плеер
   пишет в `default` системной `libasound`: на Лайт 2 это armhf под glibc не новее 2.30.
   Entware (aarch64, своя alsa-lib) и готовые сборки под свежие дистрибутивы этого не дают — и
   не делят dmix с Алисой. Собрать под колонку можно так же, как shairport:
   [`contrib/airplay-lite2/Dockerfile`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/airplay-lite2/Dockerfile)
   (Debian buster, кросс-сборка под armhf). Свой регулятор громкости — softvol в `.asoundrc`,
   как [`asoundrc`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/airplay-lite2/asoundrc) у AirPlay.
4. **Автозапуск после `S55zbtproxy`** — свой init-скрипт по образцу
   [`S99zairplay-lite2`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/airplay-lite2/S99zairplay-lite2)
   и имя для Алисы в `ALIASES` в `S55zbtproxy`.

Проверка: в `/tmp/bt-proxy.log` строка `плеер org.mpris.MediaPlayer2.<имя> (<имя у Алисы>)`,
после воспроизведения в `/data/quasar/daemons_logs/maind.log` — `Bt source connected` и
`Bluetooth player is playing`. Без плеера цепочку можно проверить `BT_PROXY_FAKE=<имя>`.

??? example "Набросок: Spotify Connect через spotifyd (не проверялось)"
    В spotifyd MPRIS встроен. Готовые релизы armv7 собраны под более новую glibc, поэтому
    собирать его нужно под колонку (Rust, alsa и dbus из buster). Конфиг:

    ```toml
    [global]
    device_name = "Yandex Lite 2"
    backend = "alsa"
    device = "spotify"      # softvol в .asoundrc, по образцу airplay
    use_mpris = true
    dbus_type = "system"    # с DBUS_SYSTEM_BUS_ADDRESS приватной шины
    ```

    `ALIASES` в `S55zbtproxy` уже содержит `spotifyd=Spotify`.

## Другие модели { #models }

Нужен тот же Bluetooth-стек: `maind` ходит в BlueZ по D-Bus. Проверка на колонке:

```sh
ps | grep -E "bluetoothd|bluealsa"
grep -c BluezBluetoothImpl /system/vendor/quasar/maind
ls /etc/init.d/ | grep -iE "blue|bt"
```

Если всё есть, отличаться будут имена init-скриптов Bluetooth в `S55zbtproxy` (`BT=…`) и
флаги демонов. Результаты с других моделей присылайте в [issue](https://github.com/Marker284/yandex-station-extended/issues/new/choose).

## Грабли { #gotchas }

- **D-Bus-активация поднимает второй `bluetoothd`.** Если `bt-proxy` не держит `org.bluez`
  (перезапуск, падение), системная шина по `org.bluez.service` запускает ещё один
  `bluetoothd` на тот же адаптер. Отсюда шаг с `.disabled` и цикл-супервизор в `S55zbtproxy`.
- **Пачка сигналов в одну миллисекунду не доходит.** `maind` подписывается на сигналы
  устройства только после обработки его `InterfacesAdded`, поэтому `bt-proxy` шлёт
  последовательность подключения с паузами ~400 мс.
- **Без `MediaControl1 {Player}` в `PropertiesChanged` источника нет.** Если положить `Player`
  сразу в `InterfacesAdded`, `maind` видит устройство, но не пишет «Bt source connected».
- **Призраки после аварийного выхода.** Пока `bt-proxy` не работает, сигналы об удалении
  объектов теряются, и `maind` держит мёртвые устройства и транспорты — на них спотыкаются
  следующие подключения. По `SIGTERM` `bt-proxy` сам снимает свои устройства; после `kill -9`
  лечится перезапуском `maind --platformd` (его поднимет супервизор).
- **Звук плееров идёт мимо `bluealsa-aplay -S`**, который разводит только настоящие телефоны.
  Поэтому арбитраж «последний заигравший побеждает» делает `bt-proxy`: ставит на паузу другие
  MPRIS-плееры и настоящие телефоны (`MediaPlayer1.Pause`, на телефон — по AVRCP).
- **«Включи Bluetooth» не нужен.** Он открывает видимость для сопряжения новых устройств,
  а виртуальные устройства в эфир не выходят.
