# USB Host (OTG): флешки, Ethernet, наушники

Как перевести порт Type-C **Станции Лайт** в режим **USB Host** и подключить через хаб
с питанием SSD/флешки, USB-Ethernet и USB-звуковую карту. Всё делается в рантайме:
ядро, U-Boot и загрузчик **не трогаются**, перезагрузка без скрипта возвращает заводской режим.

Готовые файлы: 👉 **[`contrib/otg/`](https://github.com/Marker284/yandex-station-extended/tree/main/contrib/otg)**
(скрипты) и **[`contrib/modules/`](https://github.com/Marker284/yandex-station-extended/tree/main/contrib/modules)**
(модули ядра).

!!! success "Проверено на живом устройстве"
    Станция Лайт (`yandex,station-micro`, Micro v1.2), ядро 4.9.68, прошивка от 19.10.2026.
    Хаб Fresco Logic с питанием + SSD Patriot Burst Elite 240G (мост RTL9201), Ethernet RTL8153,
    USB-звук C&T, — всё определяется на 480 Мбит/с, переживает перезагрузку, чтение SSD ~32 МБ/с.

!!! success "Проверено также на Станции 2 (`yandex,station-midi`)"
    SoC тот же — **Amlogic AXG**, ядро 4.9.68, USB2-PHY `ffe09000` с теми же регистрами
    (`usb_r0 0x8000006A`, `u2p_r0 0x10252000`), симптом при загрузке тот же
    (`xHCI host not responding … HC died`). Модули из `contrib/modules` грузятся как есть.
    Отличия: проверка модели в `install.sh` рассчитана на `yandex,station-micro`, а картридер
    на Станции 2 не сообщает о вставке карты — нужно `unbind`/`bind` USB-устройства.
    Регистры, шина и замеры — в [`devices/station-2.md`](../devices/station-2.md#usb-host).

!!! danger "Модули из первой версии этого гайда были битыми"
    Ранее здесь лежали модули с подписью `4.9.y`, собранные под **чужие** заголовки ядра.
    Они роняли колонку: `r8152`/`usbnet` — kernel oops в `register_netdevice` при появлении
    `eth0` (колонка зависает и уходит в `watchdog_reboot`), `snd-usb-audio` — oops при открытии
    PCM. Если у вас есть `/etc/init.d/S98usb_modules` — удалите его (это делает `install.sh`).
    Менять `otg_device` в U-Boot тоже **не нужно** — это ничего не даёт (см. ниже).

---

## Железо и подключение

* Type-C на Станции — **только вход питания** (sink). Повышающего преобразователя нет,
  5 В наружу колонка не отдаёт: пассивный OTG-переходник просто не заработает.
* Нужен **USB-C хаб с Power Delivery / pass-through** (или активный OTG Y-кабель):
  блок питания — в PD-вход хаба, хаб — в Станцию. Хаб питает и колонку, и периферию,
  а линии D+/D- идут к контроллеру колонки.
* Работает только **USB 2.0** (480 Мбит/с): у USB3-PHY в device-tree нет портов (`This phy has no usb port` в dmesg).

---

## Установка

1. Скопируйте `contrib/otg` и `contrib/modules` на колонку и запустите установщик:

    ```sh
    # на ПК, из клона репозитория
    scp -P 2222 -r contrib/otg contrib/modules root@<ip>:/data/otg-src/
    # на колонке
    sh /data/otg-src/otg/install.sh
    ```

    Установщик проверит модель и ядро, разложит файлы в `/data/otg/`, поставит
    `/etc/init.d/S97otg-host` и уберёт старый `S98usb_modules`.

2. Для exFAT/NTFS поставьте FUSE-драйверы из Entware (FUSE в ядре есть):

    ```sh
    yse install exfat-fuse ntfs-3g
    ```

3. Перезагрузите колонку. Через ~30 с после старта:

    ```sh
    cat /data/otg/last.log        # что сделал скрипт
    ls /sys/bus/usb/devices/      # 1-1, 1-1.x … — устройства хаба
    ```

### Что делает автозапуск

`S97otg-host` через 15 с после загрузки запускает `/data/otg/otg-host.sh`
(драйверы → переключение порта), затем `/data/otg/usb-mount.sh`.

* **Защита от бутлупа:** перед переключением пишется флаг `/data/otg/boot-pending`, после
  успешного старта он удаляется. Если колонка зависла и перезагрузилась — флаг остался, и
  следующая загрузка пройдёт **без** OTG.
* **Выключить насовсем:** `touch /data/otg/disable` и перезагрузка.
* После переключения ADB/gadget по USB не работает — порт занят хостом. SSH по Wi-Fi работает как обычно.

---

## Использование

**Диски.** Все разделы монтируются в `/tmp/usb/<метка>` (exFAT и NTFS — через FUSE, FAT — ядром):

```sh
/data/otg/usb-mount.sh        # смонтировать всё (например, после подключения флешки)
/data/otg/usb-mount.sh -u     # отмонтировать всё перед отключением
```

**Ethernet.** Интерфейс `eth0` появляется сам, штатный `dhcpcd` получает адрес, как только
вставлен кабель.

**Звук.** USB-карта — `card 1`:

```sh
cat /proc/asound/cards
aplay -D hw:1,0 -f S24_3LE -r 48000 -c 2 file.wav    # формат смотрите в /proc/asound/card1/stream0
```

**Весь звук — в USB-наушники / ЦАП.** Все плееры колонки (Алиса, музыка, системные звуки,
AirPlay/Bluetooth) пишут в ALSA `default`: `softvol "Master"` → `dmix_spk` → `hw:0,0` (усилитель).
[`audio-route.sh`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/otg/audio-route.sh)
переключает только `dmix_spk` на USB-карту, поэтому громкость (кнопки, «Алиса, громче») работает и в наушниках:

```sh
/data/otg/audio-route.sh usb       # всё на USB-карту (формат/частота берутся из /proc/asound/cardN/stream0)
/data/otg/audio-route.sh speaker   # обратно на динамик
/data/otg/audio-route.sh status
/data/otg/audio-route.sh gain -25  # ослабление на USB (по умолчанию -20 дБ, 0 — без ослабления)
touch /data/otg/audio-no-usb       # не переключаться на USB автоматически
```

* Шкала громкости Алисы рассчитана на встроенный усилитель, а USB-ЦАП отдаёт в наушники полный
  линейный уровень — без поправки даже средняя громкость «орёт». Поэтому на USB-маршруте `plug`-слой
  дополнительно ослабляет сигнал (`ttable`, по умолчанию −20 дБ). Шаги громкости кнопками и голосом
  сохраняются — сдвигается вся шкала. Собственный регулятор USB-карт обычно бесполезен (у C&T — 0…0,39 дБ).

* Подключили карту — звук ушёл на неё, отключили — вернулся на динамик (правило `snd/controlC[1-9]` в
  `/etc/mdev.conf`; `mdev -d` кэширует правила, поэтому оно начинает работать после перезагрузки).
* При загрузке маршрут сначала сбрасывается на динамик, а на USB его переключает hotplug, когда OTG поднимет карту.
* Новый маршрут подхватывается со следующего звука: alsa-lib перечитывает `/etc/asound.conf` при открытии устройства.
* Эхоподавление Алисы берёт опорный сигнал с выхода усилителя (`Loopback`), в режиме наушников он молчит —
  для наушников это не мешает.

**lsusb.** Встроенный `lsusb` — из busybox и показывает только `ID vid:pid` без названий
(`1d6b:0002`/`1d6b:0003` — это корневые хабы xHCI). Полноценный — из Entware:

```sh
yse install usbutils     # lsusb с базой usb.ids, lsusb -t — дерево с драйверами
lsusb -t 2>/dev/null     # ядро 4.9 не отдаёт rx_lanes/tx_lanes — предупреждения можно скрыть
```

**fastfetch.** [`ff-usb.sh`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/otg/ff-usb.sh)
выдаёт по одной строке: сначала устройство, затем его разделы. Пустые слоты fastfetch скрывает сам
(скрипт завершается с кодом 1). Добавьте в `modules` после `disk`:

```jsonc
{ "type": "command", "key": "USB OTG", "keyColor": "38;2;122;85;255", "text": "/data/otg/ff-usb.sh 1" },
{ "type": "command", "key": "       ", "text": "/data/otg/ff-usb.sh 2" },
{ "type": "command", "key": "       ", "text": "/data/otg/ff-usb.sh 3" },
{ "type": "command", "key": "       ", "text": "/data/otg/ff-usb.sh 4" },
```

```text
USB OTG: Burst Elite 240G · 223.6 GiB · USB 480 Mbit/s
       : ├ Ventoy  17.2 GiB / 100.0 GiB (17%) · exfat
       : ├ VTOYEFI  27 MiB / 32 MiB (86%) · vfat
       : └ DATA  4 MiB / 123.5 GiB (0%) · exfat
```

---

## Диагностика

| Симптом | Причина |
|---|---|
| `invalid module format`, в dmesg `version magic '4.9.68 …' should be '4.9.y …'` | модуль собран без `KERNELVERSION = 4.9.y` |
| Колонка зависает при подключении хаба, `reboot_reason = watchdog_reboot` | загружены старые модули (`S98usb_modules`) |
| `xHCI host not responding … HC died` | xHCI перепривязан без переключения регистров |
| `mount: … Invalid argument` на разделе | exFAT/NTFS — нужен `exfat-fuse`/`ntfs-3g` |
| `fuse: mount failed: Device or resource busy` | раздел держит упавший ядерный `mount` — только перезагрузка |

Ловить падения удобно, читая лог ядра по сети в реальном времени — после oops колонка
часто виснет, а `pstore` чистится при загрузке:

```sh
ssh -p 2222 root@<ip> 'cat /proc/kmsg' | tee kmsg.log
```

---

## Как это работает

### Почему «просто включить OTG» не работало

Порт Type-C — это **порт 1 USB2-PHY** (`usb2phy@ffe09000`). Он один, а контроллеров два:

| Контроллер | Что это | Кому отдан порт по умолчанию |
|---|---|---|
| `dwc2_a` (`ff400000`, драйвер `dwc_otg`) | device/gadget | ✅ ему (`usb_r0.u2d_act = 1`) |
| `dwc3` → `xhci-hcd` (`ff500000`) | host | ❌ его USB2-порт 1 **отключён** в glue-регистре (`usb_r1.u3h_host_u2_port_disable = 0x2`) |

У узла `usb3phy` в device-tree `otg = <0>` — переключения по ID-пину нет (а ID-пина у Type-C-sink и
нет). Параметр `otg_device=1` в cmdline влияет только на `dwc2` (форсирует SLAVE), к хосту
отношения не имеет. xHCI при этом стартует, но на «пустом» порту: при попытке поднять его
руками он видит мусорное full-speed устройство и умирает с
`xHCI host not responding to stop endpoint command … HC died`.

Переключение — 4 регистра (база `0xffe09000`, раскладка как в Amlogic `phy-aml-new-usb3.c`, `set_mode()`):

| Адрес | Регистр | Было | Стало | Смысл |
|---|---|---|---|---|
| `0xffe09084` | `usb_r1` | `0x01002000` | `0x01000000` | включить USB2-порт 1 у xHCI |
| `0xffe09080` | `usb_r0` | `0x8000006A` | `0x0000006A` | `u2d_act=0`: порт → xHCI |
| `0xffe09090` | `usb_r4` | `0x00000002` | `0x00000000` | `p21_SLEEPM0=0` |
| `0xffe09020` | `u2p_r0` (порт 1) | `0x10252000` | `0x10252060` | подтяжки 15 кОм на D+/D- (роль хоста) |

Порядок важен: отвязать `dwc2_a` (`dwc_otg/unbind`) и `xhci-hcd.0.auto` (`xhci-hcd/unbind`),
записать регистры, снова привязать `xhci-hcd.0.auto`.

!!! warning "Не отвязывайте `dwc3`"
    `echo ff500000.dwc3 > /sys/bus/platform/drivers/dwc3/unbind` даёт kernel oops в
    `dwc3_remove` (вендорский PHY без нужных ops). Перепривязывать нужно дочерний `xhci-hcd.0.auto`.

### Модули ядра

В ядре Яндекса нет ни `usb-storage`, ни `sd_mod` (`CONFIG_BLK_DEV_SD` выключен — без него
даже рабочий `usb-storage` не даст `/dev/sda`), ни сетевых USB-драйверов, ни `snd-usb-audio`.
Встроены только хаб, HID (клавиатуры/мыши/геймпады), `cdc_acm` и `usbserial`.

| Модуль | Для чего | Статус |
|---|---|---|
| `sd_mod`, `usb-storage`, `uas` | флешки, SSD/HDD, картридеры | ✅ |
| `r8152` | Ethernet RTL8152/8153 (почти все хабы) | ✅ |
| `ax88179_178a`, `asix` | Ethernet ASIX 1G / 100M | ✅ (собраны, железом не проверены) |
| `cdc_ether`, `cdc_ncm`, `usbnet`, `mii` | CDC-адаптеры, модемы, база | ✅ |
| `snd-usb-audio`, `snd-usbmidi-lib`, `snd-hwdep`, `snd-rawmidi` | USB-звук / ЦАП | ✅ |
| `ext4`, `exfat`, `ntfs` в ядре | файловые системы | ❌ **нельзя**, см. ниже — используйте FUSE |

#### Почему модули сложно собрать правильно

Исходников ядра Яндекса нет в открытом доступе. Подпись модулей должна быть `vermagic=4.9.y SMP preempt mod_unload aarch64`
(именно `4.9.y`, хотя `uname -r` = `4.9.68`), но совпадения подписи мало — должны совпасть
**структуры ядра**. Что пришлось учесть ([`build-modules.sh`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/modules/build/build-modules.sh)):

1. База — Amlogic `buildroot-aml-4.9` (4.9.40) + stable-разница 4.9.40→4.9.68 для заголовков и нужных драйверов.
2. Конфиг — ровно `/proc/config.gz` колонки + только новые `=m` ([`config.fragment`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/modules/build/config.fragment)).
3. [`yandex-axg.patch`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/modules/build/yandex-axg.patch):
    * `CONFIG_WIRELESS_EXT`/`WEXT_PRIV` — их включает вендорский Wi-Fi-драйвер, в чистом дереве они
      пропадают, и `struct net_device` сдвигается (вероятная причина падения старых модулей);
    * `CONFIG_AMLOGIC_PAGE_TRACE` — меняет `struct page` (`flags` делится на `s_flags`+`trace`) и `ZONES_PGOFF`;
    * `KERNELVERSION = 4.9.y`;
    * `snd-rawmidi`: не трогать `current->pids` (см. следующий пункт).
4. **`struct task_struct` у Яндекса другая** (из Android/EAS-патчей): например `cred` по смещению
   1776 вместо 1656, `mm` — 1184 вместо 1056 (сверено дизассемблированием живого ядра через `/dev/mem`).
   Поэтому годятся только драйверы, которые **не обращаются к `current->…`** — все модули из
   таблицы проверены на это. `ext4`/`jbd2` (`current->journal_info`) и `exfat` (`current->cred`)
   по этой причине **не поставляются**: `exfat` проверочно уронил ядро при `mount`.

Сборка воспроизводима (повторная сборка с нуля даёт байт-в-байт те же `.ko`), контрольные суммы — `contrib/modules/SHA256SUMS`.
