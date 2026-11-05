# ГигаЧат на Яндекс Станции 1

Коротко: полностью автономный голосовой ассистент («Джарвис») на базе **GigaChat**, офлайн-распознавания речи **Vosk** и синтеза речи **Piper** поверх Debian 13 на первой Станции. Работает без серверов Яндекса, поддерживает физические кнопки, поворотное кольцо громкости и автозапуск через `runit`.

## Что понадобится

- колонка с root ([шаг 1](../start/root.md))
- установленный Debian 13 ([шаг 2](https://hackalice.me/recipes/station1-debian/))
- авторизационный ключ **GigaChat API** (`GIGACHAT_CREDENTIALS`), полученный в личном кабинете разработчика Сбера

## Архитектура решения

В образе Debian для Станции 1 нет Android-окружения и штатной Алисы, но работают все аппаратные узлы платы `tulip`: микрофонная матрица, усилители `TAS5751M` (`snddaudio1`), кнопка активации, кнопка отключения микрофона и энкодер громкости.

Связка компонентов в `/opt/jarvis`:

- **Vosk (`vosk-model-small-ru-0.22`)** — локальное распознавание русской речи и ключевого слова без отправки аудиопотока в облако.
- **GigaChat API** — генерация ответов и поиск актуальной информации в сети (Web Search). Запросы текущего времени и даты обрабатываются локально по системным часам Debian (`chrony`) для мгновенного ответа.
- **Piper (`ru_RU-dmitri-medium.onnx`)** — локальный нейросетевой TTS-движок, удерживающий модель в памяти через `piper_worker.py` для быстрого отклика.
- **runit (`/etc/service/jarvis`)** — системный супервизор Debian на Станции, отвечающий за автостарт при подаче питания, логирование (`svlogd`) и перезапуск при сбоях.

## Шаги

### 1. Установка системных зависимостей и сертификатов НУЦ Минцифры

Зайдите на Станцию в Debian по SSH под `root` и установите базовые пакеты для работы со звуком, Python и сборки окружения:

```sh
apt update
apt install -y python3 python3-venv python3-pip alsa-utils curl ca-certificates nano
```

Для работы с API Сбера установите корневой сертификат Минцифры по пути, который проверяет управляющий скрипт:
```sh
curl -kfsSL [https://gu-st.ru/content/lending/russian_trusted_root_ca_pem.crt](https://gu-st.ru/content/lending/russian_trusted_root_ca_pem.crt) \
  -o /usr/local/share/ca-certificates/russian_trusted_root_ca_pem.crt
update-ca-certificates
```
### 2. Подготовка каталога /opt/jarvis, виртуальных окружений и моделей
Создайте рабочую структуру каталогов и два виртуальных окружения — основное (venv) и для голосового синтезатора (piper-venv):

```sh
mkdir -p /opt/jarvis/models/piper
cd /opt/jarvis

python3 -m venv /opt/jarvis/venv
/opt/jarvis/venv/bin/pip install --upgrade pip
/opt/jarvis/venv/bin/pip install vosk gigachat evdev sounddevice

python3 -m venv /opt/jarvis/piper-venv
/opt/jarvis/piper-venv/bin/pip install --upgrade pip
/opt/jarvis/piper-venv/bin/pip install piper-tts
```
Скачайте модель распознавания речи Vosk и голосовую модель Piper:
```sh
cd /opt/jarvis/models
curl -fSL [https://alphacephei.com/vosk/models/vosk-model-small-ru-0.22.zip](https://alphacephei.com/vosk/models/vosk-model-small-ru-0.22.zip) -o vosk.zip
unzip vosk.zip && rm -f vosk.zip

cd /opt/jarvis/models/piper
curl -fSL [https://huggingface.co/rhasspy/piper-voices/resolve/main/ru/ru_RU/dmitri/medium/ru_RU-dmitri-medium.onnx](https://huggingface.co/rhasspy/piper-voices/resolve/main/ru/ru_RU/dmitri/medium/ru_RU-dmitri-medium.onnx) \
  -o ru_RU-dmitri-medium.onnx
curl -fSL [https://huggingface.co/rhasspy/piper-voices/resolve/main/ru/ru_RU/dmitri/medium/ru_RU-dmitri-medium.onnx.json](https://huggingface.co/rhasspy/piper-voices/resolve/main/ru/ru_RU/dmitri/medium/ru_RU-dmitri-medium.onnx.json) \
  -o ru_RU-dmitri-medium.onnx.json
```

Поместите файлы рабочего кода `jarvis.py` и `piper_worker.py` в каталог `/opt/jarvis/`
### 3. Настройка ключа GigaChat
Создайте закрытый файл конфигурации `/etc/jarvis/gigachat.env` с вашим ключом авторизации 
```sh
mkdir -p /etc/jarvis
cat > /etc/jarvis/gigachat.env <<'EOF'
GIGACHAT_CREDENTIALS="ВАШ_КЛЮЧ_АВТОРИЗАЦИИ_BASE64"
GIGACHAT_SCOPE="GIGACHAT_API_PERS"
GIGACHAT_VERIFY_SSL_CERTS="true"
EOF

chmod 600 /etc/jarvis/gigachat.env
chown root:root /etc/jarvis/gigachat.env
```

!!! warning "Только свои устройства"
Не публикуйте ключи из `devices.json`, `gigachat.env`, MAC-адреса, серийные номера и токены

### 4. Проверка системного времени и часового пояса
Корректное время необходимо для проверки SSL-сертификатов GigaChat и мгновенных ответов ассистента на вопросы о времени и дате без обращения к облаку.

Убедитесь, что служба `chrony` активна в `runit`, а часовой пояс настроен верно:
```sh
sv status /etc/service/chrony
date
```

Если часовой пояс отличается от вашего, задайте его (например, для Москвы):
```sh
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
echo "Europe/Moscow" > /etc/timezone
```
### 5. Установка единого скрипта управления и автозапуска (jarvisctl)
Чтобы не управлять процессами вручную и обеспечить автоматический старт помощника при включении Станции в розетку, создайте управляющий скрипт `/root/jarvis-control.sh`. Он проверит целостность всех моделей и библиотек, создаст службу runit в `/etc/service/jarvis` и настроит ротацию логов через `svlogd` в `/var/log/jarvis`.

Откройте редактор:
```sh 
nano /root/jarvis-control.sh
```

Вставьте следующий код:
```sh 
#!/bin/sh
# ==========================================
# JARVIS CONTROL
# Управление голосовым помощником Яндекс Станции
# ==========================================

set -eu

BASE="/opt/jarvis"
SERVICE="/etc/service/jarvis"
ENV_FILE="/etc/jarvis/gigachat.env"
LOG_DIR="/var/log/jarvis"

PYTHON="$BASE/venv/bin/python"
PIPER="$BASE/piper-venv/bin/piper"

MODEL="$BASE/models/vosk-model-small-ru-0.22"
VOICE="$BASE/models/piper/ru_RU-dmitri-medium.onnx"

ACTION="${1:-install}"

die() {
    echo "ОШИБКА: $1"
    exit 1
}

require_root() {
    [ "$(id -u)" = 0 ] || die "Запусти от root"
}

check_files() {
    echo "=== ПРОВЕРКА JARVIS ==="

    for file in \
        "$BASE/jarvis.py" \
        "$BASE/piper_worker.py" \
        "$PYTHON" \
        "$PIPER" \
        "$ENV_FILE" \
        "$MODEL/am/final.mdl" \
        "$VOICE" \
        "$VOICE.json" \
        "/usr/local/share/ca-certificates/russian_trusted_root_ca_pem.crt"
    do
        [ -e "$file" ] \vert{}\vert{} die "Нет файла: $file"
        echo "[OK] $file"
    done

    sh -n "$ENV_FILE" || die "Ошибка env-файла"

    sh -c '
        set -a
        . "$1"
        test -n "${GIGACHAT_CREDENTIALS:-}"
    ' sh "$ENV_FILE" || die "Нет ключа GigaChat"

    "$PYTHON" -m py_compile "$BASE/jarvis.py" ||
        die "Ошибка синтаксиса jarvis.py"

    "$PYTHON" -c 'import vosk, gigachat' ||
        die "Не загружаются библиотеки Python"

    "$PIPER" --help >/dev/null 2>&1 ||
        die "Не запускается Piper"

    command -v runsv >/dev/null ||
        die "Не установлен runsv"

    command -v svlogd >/dev/null ||
        die "Не установлен svlogd"

    command -v amixer >/dev/null ||
        die "Не установлен ALSA"

    echo
    echo "Все основные компоненты проверены."
}

install_service() {
    echo "=== УСТАНОВКА JARVIS ==="

    check_files

    mkdir -p "$LOG_DIR"
    mkdir -p "$SERVICE/log"

    chmod 600 "$ENV_FILE"
    chown root:root "$ENV_FILE"

    if [ -f "$SERVICE/run" ] \vert{}\vert{} [ -f "$SERVICE/log/run" ]; then
        BACKUP="/root/jarvis-service-backup-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$BACKUP"

        [ ! -f "$SERVICE/run" ] ||
            cp -a "$SERVICE/run" "$BACKUP/run"

        [ ! -f "$SERVICE/log/run" ] ||
            cp -a "$SERVICE/log/run" "$BACKUP/log-run"

        echo "Резервная копия: $BACKUP"
    fi

    sv down "$SERVICE" >/dev/null 2>&1 || true

    cat > "$SERVICE/run" <<'RUN'
#!/bin/sh

exec 2>&1

cd /opt/jarvis || exit 111

export HOME=/root
export PYTHONUNBUFFERED=1
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

set -a
. /etc/jarvis/gigachat.env
set +a

if [ -z "${GIGACHAT_CREDENTIALS:-}" ]; then
    echo "ОШИБКА: отсутствует GigaChat credentials"
    exit 111
fi

echo "================================"
echo "JARVIS STARTING"
echo "================================"

exec /opt/jarvis/venv/bin/python -u /opt/jarvis/jarvis.py
RUN

    cat > "$SERVICE/log/run" <<'LOG'
#!/bin/sh
exec svlogd -tt /var/log/jarvis
LOG

    chmod 755 "$SERVICE/run"
    chmod 755 "$SERVICE/log/run"

    chown -R root:root "$SERVICE" "$LOG_DIR"

    echo "Служба создана."
    echo "Запускаем Jarvis..."

    i=0
    while [ "$i" -lt 30 ]; do
        if sv up "$SERVICE" >/dev/null 2>&1; then
            break
        fi
        sleep 1
        i=$((i + 1))
    done

    sleep 8

    if sv status "$SERVICE"; then
        echo
        echo "JARVIS УСПЕШНО ЗАПУЩЕН"
    else
        echo
        echo "ОШИБКА ЗАПУСКА"
        tail -n 60 "$LOG_DIR/current" 2>/dev/null || true
        exit 1
    fi
}

show_status() {
    echo "================================"
    echo "JARVIS STATUS"
    echo "================================"

    echo
    echo "Основная служба:"
    sv status "$SERVICE" || true

    echo
    echo "Журналирование:"
    sv status "$SERVICE/log" || true

    echo
    echo "Громкость:"
    amixer -c snddaudio1 sget "Subwoofer Master" || true
    amixer -c snddaudio1 sget "Tweeters Master" || true

    echo
    echo "Аппаратные устройства:"
    for e in /sys/class/input/event*; do
        [ -f "$e/device/name" ] || continue
        echo "/dev/input/${e##*/}: $(cat "$e/device/name")"
    done

    echo
    echo "Последние записи журнала:"
    tail -n 30 "$LOG_DIR/current" 2>/dev/null || true
}

show_logs() {
    [ -f "$LOG_DIR/current" ] ||
        die "Журнал пока не создан"

    tail -n 80 -f "$LOG_DIR/current"
}

require_root

case "$ACTION" in
    install) install_service ;;
    check)   check_files ;;
    start)   sv up "$SERVICE"; show_status ;;
    stop)    sv down "$SERVICE"; echo "Jarvis остановлен." ;;
    restart) sv restart "$SERVICE"; echo "Jarvis перезапущен." ;;
    status)  show_status ;;
    logs)    show_logs ;;
    *)
        echo "Использование: $0 {install|check|start|stop|restart|status|logs}"
        exit 0
        ;;
esac
```

Сделайте скрипт исполняемым, создайте короткую ссылку jarvisctl и запустите установку службы:
``` sh 
chmod +x /root/jarvis-control.sh
ln -sf /root/jarvis-control.sh /usr/local/bin/jarvisctl
jarvisctl install
```

### 6. Управление и проверка работы
После установки управлять помощником можно одной командой `jarvisctl`:
| Команда           | Действие                                                  |
| ----------------- | --------------------------------------------------------- |
| `jarvisctl check` | Проверить целостность файлов, моделей, библиотек и ключей |
| `jarvisctl status` | Показать статус службы `runit`, уровень громкости ALSA и хвост лога
| `jarvisctl logs` | Открыть журнал работы в реальном времени (`/var/log/jarvis/current`)
| `jarvisctl restart` | Перезапустить помощника
| `jarvisctl stop` | Остановить службу
| `jarvisctl start` | Запустить службу

Убедитесь, что в выводе `jarvisctl status` служба имеет статус `run: /etc/service/jarvis: (pid ...)`, и проверьте работу колонки:

* вращение кольца регулирует громкость (`Subwoofer Master` / `Tweeters Master`);


* нажатие кнопки активации включает прослушивание;


* кнопка микрофона аппаратно и программно отключает запись;


* ассистент отвечает голосом на вопросы.
