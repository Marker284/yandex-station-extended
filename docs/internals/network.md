# Сеть и порты

Снято со Станции Лайт (прошивка 3.21, с включёнными ADB и SSH).

## Интерфейсы

| Интерфейс | Назначение |
|---|---|
| `wlan0` | Wi-Fi, адрес по DHCP от роутера |
| `p2p0` | Wi-Fi Direct, адрес `169.254.x.x` |

Радио — комбо-чип Unisoc UWE5621 (Wi-Fi + Bluetooth, SDIO). Ethernet на плате нет, но его
можно добавить USB-адаптером: [USB Host](../recipes/usb-host.md).

## Открытые порты

| Порт | Что это |
|---|---|
| `tcp 1961` | glagol (`glagold`) — локальный API управления |
| `tcp 5555` | ADB (после [получения root](../start/index.md#root-by-model)) |
| `tcp 2222` | SSH, Dropbear (после [шага 2](../start/ssh.md)) |
| `tcp 5081` | SIP для звонков (`maind --platformd`, в `quasar.cfg` — `sip_use_tcp`, `sip_use_tls`; проверено на Мини 2) |
| `tcp/udp 7447` | Zenoh |
| `udp 5353` | mDNS (`maind --platformd`); свой avahi рядом — см. [Подводные камни](gotchas.md#avahi) |
| `udp 11125` | `net_clock` |
| `tcp 127.0.0.1:11124` | `multiroomd` |
| `127.0.0.1:53` | локальный DNS `unbound` |
| `127.0.0.1:98xx–99xx` | внутренние порты демонов quasar (номера — в `quasar.cfg`) |

## DNS: `unbound`

На колонке работает свой резолвер `unbound` на `127.0.0.1:53`. Запросы он пересылает DNS
роутера и DNS Яндекса (`77.88.8.1`, `77.88.8.2`, `77.88.8.8`, `77.88.8.88`). Кроме того, в
`quasar.cfg` есть таблица `DnsFallbackMap` — запасные адреса на случай, если DNS не
отвечает. Поэтому одной подмены DNS может не хватить, чтобы изолировать колонку от Яндекса.

### Откуда берётся конфиг `unbound` { #unbound-config }

Проверено на Мини 2 (`0.369.1.46…299`):

1. Форвардеры и параметры приходят из облака, в `get_sync_info`:
   `config.system_config.unbound` — `forwarders` (адреса `77.88.8.x`) и `serverParams` (строки
   конфига). Quasar сохраняет их в `/data/quasar/data/user_config.dat`.
2. При старте Quasar пишет из них `/data/unbound.conf.head` (это тот же файл, что
   `/bkupgrade/data/unbound.conf.head`).
3. Хук dhcpcd `/lib/dhcpcd/dhcpcd-hooks/21-unbound.conf` склеивает head с DNS из DHCP
   (`forward-addr` роутера) в `/etc/unbound/unbound.conf` и перезапускает `unbound`.

Что из этого следует:

- **DNS роутера колонка спрашивает не одна.** С форвардерами `77.88.8.x` имя
  `quasar.yandex.net` может разрешиться в настоящий адрес, хотя DNS роутера указывает на стенд,
  и синхронизация уйдёт в облако. Стенду на своей точке доступа помогает перехват всего
  `udp/tcp 53` (DNAT) на свой DNS.
- **Править файлы на колонке бесполезно.** При следующей синхронизации Quasar перезаписывает
  `user_config.dat` и head облачной копией. Надёжнее отдавать нужный блок в ответе
  `get_sync_info`. Если отдать `"forwarders": []`, в конфиге остаётся только DNS из DHCP.
  Строки `local-zone: "clck.yandex.net." refuse` в `serverParams` закрывают телеметрию.
- `user_config.dat` — не JSON, а контейнер в стиле protobuf с JSON внутри (длины —
  varint). Если всё же править его руками, длины полей нужно пересчитать.

## glagol (порт 1961) { #glagol }

Локальный API, через который колонкой управляют приложения и интеграции (например,
[YandexStation для Home Assistant](https://github.com/AlexxIT/YandexStation)). Протокол
в этой вики пока не описан — см. исходники интеграции.
