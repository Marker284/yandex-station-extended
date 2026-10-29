# Шаг 3. Пакеты: `yse`

`yse` — маленький шелл-скрипт, который ставит пакеты из двух источников:

- **Entware** (opkg) — тысячи пакетов для ARM: `htop`, `tmux`, `nano`, `mc`, `python`, `git`,
  `exfat-fuse`, `usbutils` и другие;
- **реестры `.yap` на GitHub** — готовые сборки под Станции, по умолчанию
  [yapkg](https://github.com/nyakokitsu/yapkg) (около 80 пакетов: `btop`, `jq`, `rclone`,
  `restic`, `wireguard`, `ripgrep`, `sd`). Новые пакеты в реестр сейчас не принимают:
  YAM переезжает на свой формат, см. [предупреждение в рецепте](../recipes/packagemanagers.md).

Всё ставится в `/data/opt`, системные файлы не трогаются. Незнакомые слова разобраны
в [словаре](../glossary.md).

## Установка

[:material-download: Скачать `yse`](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/bin/yse){ .md-button .md-button--primary }
[:material-download: Скачать установщик](https://github.com/Marker284/yandex-station-extended/raw/main/contrib/install-yse.sh){ .md-button }

**Одной командой с компьютера** — Linux, macOS или WSL; нужен `adb` или `ssh`.
В обычной командной строке Windows этот установщик не работает: там ставьте
[вручную](#manual), двумя командами `adb`.

```sh
# последним аргументом — IP вашей колонки
curl -fsSL https://raw.githubusercontent.com/Marker284/yandex-station-extended/main/contrib/install-yse.sh | sh -s -- 192.168.1.120
```

Установщик скачает `yse`, зальёт его на колонку по ADB (порт 5555), а если ADB недоступен —
по SSH (порт 2222), и сразу развернёт Entware (`yse bootstrap`). Только по SSH: добавьте
`--ssh` после IP, только по ADB — `--adb`.

<a id="manual"></a>

??? note "Вручную, без установщика — работает и в Windows"
    ```sh
    adb push yse /data/opt/bin/yse
    adb shell chmod +x /data/opt/bin/yse
    adb shell /data/opt/bin/yse bootstrap
    ```

После установки **переподключитесь по SSH** — `yse` и пакеты будут вызываться без полного пути:

```sh
yse install htop
```

Исходники: [`contrib/bin/yse`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/bin/yse),
[`contrib/install-yse.sh`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/install-yse.sh).
Обновить `yse` до новой версии — запустить установщик ещё раз.

## Команды

```sh
yse bootstrap            # развернуть Entware (один раз; нужен и для .yap)
yse update               # обновить списки Entware и .yap-реестров
yse install <pkg>...     # установить
yse install yap:<pkg>    # явно из .yap-реестра
yse install ent:<pkg>    # явно из Entware
yse remove  <pkg>...     # удалить
yse search  <строка>     # найти (у .yap-пакетов пометка [yap/<реестр>])
yse info    <pkg>
yse list [-a]            # установленные / все доступные
yse upgrade              # обновить установленные (оба источника)
yse sources              # список .yap-реестров
eval "$(yse env)"        # PATH для текущей сессии без переподключения
```

Без префикса пакет берётся из Entware, а если там его нет — из `.yap`. Чтобы наоборот:
`YSE_PREFER=yap`. Архитектура — `YSE_ARCH`, зеркало Entware — `YSE_ENT_MIRROR`.

## Пакеты `.yap` с GitHub { #yap }

```sh
yse search jq
yse install yap:btop
btop
```

- Пакет скачивается с GitHub, проверяется по `sha256` из индекса, распаковывается в
  `/data/opt/yap/<имя>/`, а команда появляется в `/data/opt/bin`.
- Перед установкой проверяется свободное место — пакеты бывают большими (`node` — 26 МБ).
- Чужие файлы в `/data/opt/bin` не перезаписываются: например, если `fastfetch` вы положили
  туда сами, `yap:fastfetch` откажется ставиться.
- Если та же команда есть в Entware, в PATH раньше окажется версия из Entware — `yse`
  предупредит и подскажет полный путь.
- Только `aarch64` (на Стрит не подходит).

Тот же реестр используют плагины [YAM](../recipes/packagemanagers.md) — менеджера с веб-панелью
и доступом к железу колонки.

### Свой реестр

Реестры перечисляются в `/data/opt/etc/yse/sources`, по одному на строку: имя и адрес
`index.json`. Пока файла нет, используется yapkg.

```text
yapkg   https://raw.githubusercontent.com/nyakokitsu/yapkg/registry/index.json
my      https://raw.githubusercontent.com/<you>/<repo>/registry/index.json
```

После правки — `yse update`.

!!! warning "Клиент apkg на Станции Лайт затирает системные файлы"
    Пакеты yapkg перепакованы из [initialfox/yandex-station-repo](https://github.com/initialfox/yandex-station-repo),
    у которого есть свой клиент `apkg`. На Buildroot он ставит в `/usr/local/bin` на
    корневой файловой системе (на Лайт там свободно ~12 МБ) и в `/opt`, который занят Entware.
    Те же пакеты безопасно ставит `yse install yap:<pkg>`.

## Модели

| Модель | Архитектура Entware |
|---|---|
| Лайт, Лайт 2, Мини 2, Мини 3, Станция 2, Миди | `aarch64-k3.10` (проверено на Лайт) |
| Стрит | `armv7sf-k3.2` |
| Макс, Станция 1-го поколения | не подходит (Android, нет root) |

На Станции Лайт под `/data` весь раздел `bkupgrade` — около 87 МБ, из них половина свободна
после Entware и нескольких пакетов. Проверяйте `df -h /data` перед установкой больших пакетов.

## Удалить { #uninstall }

```sh
for c in /data/opt/bin/*; do grep -q '^# yse-yap ' "$c" 2>/dev/null && rm "$c"; done   # запускалки .yap
rm -rf /data/opt/bin/yse /data/opt/entware /data/opt/yap /data/opt/var/yse /data/opt/etc/yse
mount -o remount,rw / && rm /opt && mkdir /opt && sync && mount -o remount,ro /
```

## Как это устроено

- Busybox на колонке не умеет TLS: установщик Entware качается по HTTP с `bin.entware.net`,
  а пакеты `.yap` — утилитой `curl` из Entware, которую `yse` ставит сам. Дальше Entware
  пользуется своим `wget` с TLS.
- Entware самодостаточен (свой загрузчик и glibc в `/opt`), поэтому 64-битные пакеты работают,
  хотя системное пользовательское пространство колонки 32-битное.
- `bootstrap` задаёт записываемый `HOME=/data/opt/home` (домашний каталог root лежит на
  разделе только для чтения) и превращает `/opt/etc/shells` в обычный файл — иначе установка
  оболочек (`fish`, `bash`, `zsh`) завершается с ошибкой «Read-only file system».
- `.yap` — это `tar.gz` с файлом `plugin.toml` (параметры `id`, `version`, `[launch] path` и
  совместимость `features = ["arch.aarch64"]`) и каталогом пакета. Пакеты yapkg собраны на musl
  и содержат свои библиотеки: обёртка запускает бинарный файл через собственный
  `ld-musl` — поэтому они не зависят ни от системы, ни от Entware. Индекс реестра — `index.json`
  со ссылкой и контрольной суммой `sha256` каждого архива.

Дальше: **[если что-то сломалось](recovery.md)** · **[рецепты](../recipes/index.md)**.
