# Bluetooth пульт подключение к Лайт

Физические кнопки управления **чем угодно** в умном доме — Bluetooth-пульт,
подключённый напрямую к Станции Лайт. Колонка работает как всегда-доступный
BT-приёмник с **бипом подтверждения** на каждое нажатие; кнопка → любая ваша
команда: музыка, свет, сцены, ТВ, роутер.

Работает в двух режимах:

- **с sa_client** — готовая раскладка управления музыкой LMS из коробки;
- **без sa_client** — назначьте на кнопки **любые свои команды** (LMS напрямую,
  Home Assistant, MQTT, любой HTTP, локальный shell). Об этом ниже.

Проверено на пультах: **G20S PRO**, **ATV Remote 3**, **Xiaomi RC**, **BPR2S**.

## Что понадобится

- колонка с root ([шаг 1](../start/root.md));
- пульт (батарейки заряжены) и ноутбук в той же сети;
- sa_client — **опционально** (нужен только для готовой музыкальной раскладки).

!!! tip "Почему нужен свой приёмник событий"
    Вендорское ядро колонки доставляет input-события HID только при захвате
    узла через `EVIOCGRAB`. Установщик кладёт статик `btrcv`, который делает
    это сам — обычный `cat /dev/input/eventN` событий «не видит».

## Шаги

1. **Установка на колонку** (из комплекта `alice-root-wizard`, с ноутбука):

    ```bash
    ./bt_remote.sh <IP_колонки> --player <ИмяПлеераLMS> --room <Комната>
    # пример:
    ./bt_remote.sh 192.168.1.122 --player "JBL white" --room Гараж
    ```

    Скрипт ставит Entware bluez (bluetoothd `input,hog`), приёмник `btrcv`,
    слушатель кнопок, утилиты подключения и персистентные бонды. Вендорский
    D-Bus, bluealsa и Алиса не трогаются. `--player/--room` нужны только для
    режима sa_client — если его нет, укажите любого существующего плеера LMS
    (или заглушку).

2. **Подключение пульта.** Зажмите комбо паринга, поднесите пульт к колонке
   и выполните на ней:

    ```bash
    ssh -p 2222 root@<IP_колонки>
    /data/opt/bin/bt-connect.sh
    ```

    **3 бипа = готово.** Комбо: G20S = `OK+Return` · ATV3 = `Back+Home` ·
    Xiaomi = `Home+Menu` · BPR2S = `OK+Vol−`. Без SSH — кнопка 🔑 на
    `http://<сервер>:8888/stations`.

3. **Проверка**: нажимайте кнопки — колонка пикает, действия в логе
   `/tmp/btkeys.log`.

## Свои команды на кнопки (без sa_client)

Вся магия — в одном файле: `/data/opt/bin/btkeys-grab.sh`. Каждое нажатие
приходит туда как **числовой код кнопки**, дальше — ваш `case`. Универсальный
способ узнать код любой, даже не размеченной кнопки: нажмите её и посмотрите
`/tmp/btkeys.log` — там будет строка вида `код 302 (не маплено)`.

Куда может уходить нажатие:

### LMS напрямую (без sa_client)

LMS управляется обычным JSON-RPC — слушатель уже содержит хелпер `lms()`:

```sh
# в case-блоке btkeys-grab.sh, примеры:
106|163) lms '{"id":1,"method":"slim.request","params":["JBL white",["playlist","index","+1"]]}' ;;  # ▶
105|165) lms '{"id":1,"method":"slim.request","params":["JBL white",["playlist","index","-1"]]}' ;;  # ◀
353|164) lms '{"id":1,"method":"slim.request","params":["JBL white",["pause"]]}' ;;                   # OK
115)     lms '{"id":1,"method":"slim.request","params":["JBL white",["mixer","volume","+5"]]}' ;;    # VOL+
114)     lms '{"id":1,"method":"slim.request","params":["JBL white",["mixer","volume","-5"]]}' ;;    # VOL−
```

Любой плеер LMS (все squeezelite-устройства дома), плейлисты, избранное,
группы, power — полный API JSON-RPC (документация LMS, CLI/JSON-API).
Плеер указывается по имени или MAC.

### Home Assistant

Два способа, оба — одна строка `busybox wget`:

**Webhook (без токена — проще всего):** в HA создайте автоматизацию с
триггером webhook (`/api/webhook/bt_remote`), а кнопке:

```sh
busybox wget -q -O /dev/null --header='Content-Type: application/json' \
  --post-data='{"btn":"next","room":"guest"}' http://<HA>:8123/api/webhook/bt_remote
```

Внутри автоматизации — **что угодно**: свет, сцены, TV, любые media_player
(включая LMS, Spotify, Chromecast).

**REST API (с долгоживущим токеном)** — прямое управление сущностями:

```sh
busybox wget -q -O /dev/null \
  --header='Authorization: Bearer <долгоживущий_токен>' \
  --header='Content-Type: application/json' \
  --post-data='{"entity_id":"media_player.gostinaya"}' \
  http://<HA>:8123/api/services/media_player/media_next_track
```

### MQTT (HA / openHAB / Node-RED)

`opkg install mosquitto-client-ssl` (или `mosquitto-client`) и:

```sh
mosquitto_pub -h <broker> -t "remote/guest/next" -m press
```

Подписчики получают событие — идеальный вариант, когда пульт должен влиять
сразу на несколько систем.

### Любой HTTP-гаджет и локальный shell

Нажатие — это просто команда от root на колонке: `wget` на любой URL (Kodi
JSON-RPC, VLC HTTP, роутер, espHome), либо локальное действие — `aplay`,
перезапуск сервиса и т.п. Ограничений нет.

После правки `btkeys-grab.sh` перезапустите слушателя:
`/data/opt/bin/bt-listeners-start.sh`.

## Готовая раскладка sa_client (если он есть)

| Кнопка | Действие |
|---|---|
| OK | Play / Pause |
| VOL+ / VOL− | Громкость плеера LMS |
| ◀ / ▶ | Предыдущий / следующий трек |
| ▲ / ▼ | Предыдущий / следующий канал (избранное) |
| Home | «Переключи сюда» (музыку в эту комнату) |
| Search | «Что играет» (голосовой ответ) |
| 1–9 | Каналы избранного LMS №1–№9 |

Кнопки уходят на `/cmd` клиента (`http://<сервер>:8888`) — команды
`next/prev/play_pause/volume_*/channel/switch_here/whats_playing`.
После смены IP сервера — `/stations` → «Перенацелить сюда».

## Ограничения и заметки

- Пульт подключается к **одной** колонке; для нескольких комнат — по
  установке на каждую.
- Коды кнопок у разных пультов совпадают (стандартные keycodes), но новые
  модели проверяйте через лог.
- Полный журнал экспериментов — `lite-bt.md` в репозитории
  lyrion-yandex-bridge.

!!! warning "Только свои устройства"
    Не публикуйте ключи из `devices.json`, MAC-адреса, серийные номера и токены.