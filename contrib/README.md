# Community Tools, Binaries & Scripts

Полезные утилиты, скомпилированные бинарники и скрипты автоматизации, собранные сообществом исследователей умных колонок Яндекс.

Все файлы хранятся прямо в этом репозитории — их можно скачать через браузер по прямым ссылкам или напрямую с помощью `wget` / `curl` на колонку.

---

## 📦 Готовые статические бинарники (каталог `contrib/bin/`)

Скомпилированы статически под архитектуру **`aarch64-linux-musl`** (работают на Станциях Лайт, Лайт 2, Мини 1, Мини 2, Мини 3, Станция 2, Миди):

| Программа | Размер | Прямая ссылка на скачивание | Описание |
|---|---|---|---|
| **`fastfetch`** | 1.1 МБ | [Скачать fastfetch](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/bin/fastfetch) | Системный информер с цветным логотипом Алисы и выводом температуры. |
| **`dropbear`** | 2.7 МБ | [Скачать dropbear](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/bin/dropbear) | Легковесный автономный SSH-сервер. |
| **`dropbearkey`**| 2.3 МБ | [Скачать dropbearkey](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/bin/dropbearkey) | Генератор ED25519/RSA хост-ключей для Dropbear. |
| **`nano`** | 325 КБ | [Скачать nano](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/bin/nano) | Удобный консольный текстовый редактор. |
| **`zsh`** | 3.6 МБ | [Скачать zsh](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/bin/zsh-5.9.2-aarch64-musl) | Мощная командная оболочка Zsh (версия 5.9.2). |
| **`yse`** | 20 КБ | [Скачать yse](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/bin/yse) | Пакетный менеджер: Entware + `.yap`-пакеты с GitHub. Установщик с ПК — [`install-yse.sh`](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/install-yse.sh), [инструкция](https://hackalice.me/start/packages/). |

---

## 🧩 Модули ядра для USB Host (каталог `contrib/modules/`)

Собраны под ядро Яндекса Станции Лайт (`4.9.68`, `vermagic=4.9.y SMP preempt mod_unload aarch64`)
скриптом [`build/build-modules.sh`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/modules/build/build-modules.sh),
проверены на живом устройстве. Ставятся вместе со скриптами [`contrib/otg/`](https://github.com/Marker284/yandex-station-extended/tree/main/contrib/otg)
через `install.sh` — подробно в гайде [USB Host (OTG)](../docs/recipes/usb-host.md).

| Модуль | Назначение | Прямая ссылка на скачивание |
|---|---|---|
| **`sd_mod.ko`** | SCSI-диски: без него usb-storage не даёт `/dev/sda` | [Скачать sd_mod.ko](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/modules/sd_mod.ko) |
| **`usb-storage.ko`** | USB-флешки, SSD/HDD, картридеры | [Скачать usb-storage.ko](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/modules/usb-storage.ko) |
| **`uas.ko`** | USB Attached SCSI для быстрых дисков | [Скачать uas.ko](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/modules/uas.ko) |
| **`r8152.ko`** | Ethernet Realtek RTL8152/RTL8153 | [Скачать r8152.ko](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/modules/r8152.ko) |
| **`ax88179_178a.ko`** | Ethernet ASIX AX88179 (1G) | [Скачать ax88179_178a.ko](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/modules/ax88179_178a.ko) |
| **`asix.ko`** | Ethernet ASIX AX8817x (100M) | [Скачать asix.ko](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/modules/asix.ko) |
| **`cdc_ether.ko`** | CDC Ethernet-адаптеры и модемы | [Скачать cdc_ether.ko](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/modules/cdc_ether.ko) |
| **`cdc_ncm.ko`** | CDC NCM-адаптеры | [Скачать cdc_ncm.ko](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/modules/cdc_ncm.ko) |
| **`usbnet.ko`** | база USB-сетевых драйверов | [Скачать usbnet.ko](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/modules/usbnet.ko) |
| **`mii.ko`** | MII-библиотека для сетевых драйверов | [Скачать mii.ko](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/modules/mii.ko) |
| **`snd-usb-audio.ko`** | USB-звуковые карты и ЦАП | [Скачать snd-usb-audio.ko](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/modules/snd-usb-audio.ko) |
| **`snd-usbmidi-lib.ko`** | USB MIDI (зависимость snd-usb-audio) | [Скачать snd-usbmidi-lib.ko](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/modules/snd-usbmidi-lib.ko) |
| **`snd-rawmidi.ko`** | ALSA rawmidi (патч: без `current->pids`) | [Скачать snd-rawmidi.ko](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/modules/snd-rawmidi.ko) |
| **`snd-hwdep.ko`** | ALSA hwdep | [Скачать snd-hwdep.ko](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/modules/snd-hwdep.ko) |

> ⚠️ **Старые модули удалены.** Первая версия этого каталога (модули под чужие заголовки ядра)
> роняла колонку при подключении Ethernet и при воспроизведении звука. `ext4`/`exfat` в ядре для
> этой прошивки собрать безопасно нельзя — для exFAT/NTFS используйте `yse install exfat-fuse ntfs-3g`.

---

## 🎁 Готовые пакеты и медиа (каталог `contrib/packages/`)

| Файл | Размер | Прямая ссылка | Описание |
|---|---|---|---|
| **`mac-startup-chime-t2.mp3`** | 63 КБ | [Скачать MP3](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/packages/mac-startup-chime-t2.mp3) | Легендарный звук запуска Apple Mac (чип T2) для автозагрузки Станции. |
| **`mini2-ssh.tar.gz`** | 7.6 МБ | [Скачать архив](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/packages/mini2-ssh.tar.gz) | Готовый самораспаковывающийся архив SSH для Станции Мини 2. |
| **`librespot-micro-installer.zip`**| 2.3 МБ | [Скачать zip](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/packages/librespot-micro-installer.zip) | Установщик клиента Spotify Connect для Станции Лайт. |
| **`Station1_ROOT.zip`** | 2.8 МБ | [Скачать zip](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/packages/Station1_ROOT.zip) | Архив инструментов рутирования для первой Станции (Allwinner). |

---

## 📜 Индекс скриптов автоматизации (каталог `contrib/`)

### Безопасность и блокировка обновлений:
* **[`yandex-noupdate.sh`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/yandex-noupdate.sh)** — полная блокировка OTA-обновлений, вырезание `updatesd` и подмена публичного ключа.
* **[`killswitch.sh`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/killswitch.sh)** — аварийный киллсвич для мгновенной изоляции колонки от облачных серверов Яндекса.
* **[`rollback.sh`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/rollback.sh)** — скрипт отката изменений и восстановления заводских файлов.
* **[`yandex-station-privacy.sh`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/yandex-station-privacy.sh)** — отключение отправки логов и телеметрии (`telemetryd`, `fluent-bitd`).

### Доступ и ADB:
* **[`install-s97adb.sh`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/install-s97adb.sh)** — добавление демона ADB в автозагрузку через `/etc/init.d/S97adb`.
* **[`patch_boot.py`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/patch_boot.py)** — модификация boot-образа ядра для снятия флага `rh_unlock=0` (UART-консоль).
* **[`patch_max_adb_candidate.py`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/patch_max_adb_candidate.py)** — патчер для включения отладки на Станции Макс.
* **[`decrypt_ota.py`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/decrypt_ota.py)** — распаковка и расшифровка OTA-пакетов прошивки.

### Звук, медиа и стриминг:

* **[`alice-say.py`](alice-say.py)** — самостоятельный клиент озвучки текста через
  штатный `AliceCapability.START_VOCALIZE` по root-SSH. На ПК нужны Python 3.11+
  и OpenSSH, на колонке — `socat`. Протокол проверен на Лайт 2 / Plum;
  используется облачный TTS Яндекса. Ничего не устанавливает и не меняет в прошивке.
  [Рецепт](https://hackalice.me/recipes/sounds/#native-tts), проверка пакетов и ошибок:
  `python3 -m unittest discover -s contrib/tests -v`.
* **[`yandex-station-airplay-fix.sh`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/yandex-station-airplay-fix.sh)** — автоустановка и фикс Shairport Sync (AirPlay 2) с решением конфликта ALSA.
* **[`spotify.sh`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/spotify.sh)** — запуск клиента Spotify Connect (`librespot`).
* **[`music.go`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/music.go)** / **[`qstream.go`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/qstream.go)** — стриминг звука через сокет `tcp_alsa_writer`.
* **[`mic-tap.sh`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/mic-tap.sh)** — захват микрофонного потока с PDM-матрицы.

### Индикация и LED:
* **[`install-rgb-alice-mini2.sh`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/install-rgb-alice-mini2.sh)** — управление 6 RGB-зонами Станции Мини 2.
* **[`smiley_editor.py`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/smiley_editor.py)** — визуальный редактор пиксельных смайликов и анимаций часов.
* **[`ring.sh`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/ring.sh)** — прямое управление кольцевой подсветкой через `/dev/fb0` на Станции Мини 3.
