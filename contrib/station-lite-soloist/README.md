# Spotify Soloist для Станции Лайт (`yandexmicro`)

Сборка и установка официального клиента Spotify Soloist со своим рантаймом Debian trixie.
Инструкция — [рецепт в вики](../../docs/recipes/station-lite-spotify-soloist.md).

| Файл | Где работает | Что делает |
|---|---|---|
| `build/build-kit.py` | компьютер | индекс Debian → зависимости → .deb со сверкой SHA256 → ELF-замыкание → каталог `kit/` |
| `deploy.py` | компьютер | копирует `kit/` по ADB и запускает `install.sh` на колонке |
| `device/install.sh` | колонка | проверка, замена каталога, init-скрипт в rootfs, запуск, откат при ошибке |
| `device/soloist-svc.sh` | колонка | служба: сеть, `p2p0`, CP15, tmpfs-кэш, PulseAudio, Soloist, перезапуски |
| `device/audio-gate.sh` | колонка | держит системный `aplay` (общий dmix с Алисой) только пока играет музыка |
| `device/spotify-voice.sh` | колонка | голосовые команды по журналу Quasar Bridge → `soloist ctl` |
| `device/volume-sync.sh` | колонка | громкость Soloist следует за громкостью Алисы |
| `device/lib.sh`, `soloist.conf.example` | колонка | общие функции и настройки (переопределяются в `etc/soloist.conf`) |
| `device/S97soloist` | колонка | init-скрипт (шаблон, путь подставляет `install.sh`) |

Бинарник Soloist здесь не хранится: `build-kit.py` скачивает его с CDN Spotify
(Spotify просит не распространять его архивы и бинарники).

## Тесты

```sh
python3 -m unittest discover -s build/tests        # сборщик: любая ОС
BB=/path/to/busybox sh tests/run.sh                 # скрипты колонки: Linux, python3
```

`tests/run.sh` запускает скрипты под busybox с заглушками `ip`, `mount`, `aplay`, PulseAudio
и Soloist, ничего в системе не меняя. Нужен busybox, который ищет команды по `PATH`
(например, динамический `busybox` из Debian, не `busybox-static`); в нём нет `nohup`,
тест берёт системный.
