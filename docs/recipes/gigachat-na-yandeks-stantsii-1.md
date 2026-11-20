# Автономный голосовой помощник с GigaChat в Debian

Рецепт заменяет штатную Алису связкой из локального распознавания речи Vosk, генерации
ответов через GigaChat API и офлайн-синтеза речи Piper. Помощник откликается на имя
«Джарвис», работает без серверов Яндекса, поддерживает физические кнопки, кольцо
громкости и автозапуск при подаче питания.

**Проверено на:** Станция 1, Debian 13 (Bookworm), ноябрь 2026.

## Что понадобится { #requirements }

- Станция 1 с [полученным root](../start/root.md) и установленным
  [Debian 13](station1-debian.md)
- доступ к колонке по [SSH](../start/ssh.md) от имени `root`
- авторизационный ключ GigaChat API (`GIGACHAT_CREDENTIALS`) из личного кабинета
  разработчика Сбера

## Установка { #install }

### 1. Системные пакеты и сертификаты { #deps }

Подключитесь к Станции по SSH под `root` и установите пакеты для работы со звуком,
архивами и Python:

```sh
apt update
apt install -y python3 python3-venv python3-pip \
  alsa-utils curl ca-certificates unzip
```

Установите корневой сертификат Минцифры для подключения к API Сбера:

```sh
curl -kfsSL \
  [https://gu-st.ru/content/lending/russian_trusted_root_ca_pem.crt](https://gu-st.ru/content/lending/russian_trusted_root_ca_pem.crt) \
  -o /usr/local/share/ca-certificates/russian_trusted_root_ca_pem.crt
update-ca-certificates
```

### 2. Виртуальные окружения и модели { #models }

Создайте рабочий каталог `/opt/jarvis` и два виртуальных окружения — основное
и отдельное для синтезатора речи:

```sh
mkdir -p /opt/jarvis/models/piper
cd /opt/jarvis

python3 -m venv /opt/jarvis/venv
/opt/jarvis/venv/bin/pip install --upgrade pip
/opt/jarvis/venv/bin/pip install vosk gigachat num2words

python3 -m venv /opt/jarvis/piper-venv
/opt/jarvis/piper-venv/bin/pip install --upgrade pip
/opt/jarvis/piper-venv/bin/pip install piper-tts
```

Скачайте русскую модель распознавания речи Vosk и голосовую модель Piper:

```sh
cd /opt/jarvis/models
curl -fSL \
  [https://alphacephei.com/vosk/models/vosk-model-small-ru-0.22.zip](https://alphacephei.com/vosk/models/vosk-model-small-ru-0.22.zip) \
  -o vosk.zip
unzip vosk.zip && rm -f vosk.zip

cd /opt/jarvis/models/piper
VOICE_URL="[https://huggingface.co/rhasspy/piper-voices/resolve/main](https://huggingface.co/rhasspy/piper-voices/resolve/main)"
VOICE_PATH="ru/ru_RU/dmitri/medium/ru_RU-dmitri-medium.onnx"
curl -fSL "$VOICE_URL/$VOICE_PATH" -o ru_RU-dmitri-medium.onnx
curl -fSL "$VOICE_URL/$VOICE_PATH.json" -o ru_RU-dmitri-medium.onnx.json
```

### 3. Скрипты помощника { #scripts }

Создайте скрипт фонового процесса синтеза речи `/opt/jarvis/piper_worker.py`:

```sh
cat > /opt/jarvis/piper_worker.py <<'EOF'
import sys
import time
import subprocess

from piper import PiperVoice

MODEL = "/opt/jarvis/models/piper/ru_RU-dmitri-medium.onnx"
CONFIG = MODEL + ".json"

print("Загрузка модели Piper...", file=sys.stderr, flush=True)

voice = PiperVoice.load(MODEL, config_path=CONFIG)

print("READY", flush=True)


def speak(text):
    start = time.perf_counter()

    audio = bytearray()

    rate = voice.config.sample_rate
    channels = 1

    # Сначала полностью генерируем ответ в RAM
    for chunk in voice.synthesize(text):
        audio.extend(chunk.audio_int16_bytes)
        rate = chunk.sample_rate
        channels = chunk.sample_channels

    synth_time = time.perf_counter() - start

    if not audio:
        return

    audio_duration = len(audio) / (rate * channels * 2)

    # Затем воспроизводим уже готовый звук
    play_start = time.perf_counter()

    subprocess.run(
        [
            "aplay", "-q",
            "-D", "default",
            "-t", "raw",
            "-f", "S16_LE",
            "-r", str(rate),
            "-c", str(channels)
        ],
        input=bytes(audio),
        check=True
    )

    play_time = time.perf_counter() - play_start

    print(
        f"[Piper] Синтез: {synth_time:.2f} сек | "
        f"Аудио: {audio_duration:.2f} сек | "
        f"Воспроизведение: {play_time:.2f} сек",
        file=sys.stderr,
        flush=True
    )


try:
    for line in sys.stdin:
        text = line.rstrip("\r\n")

        if text == "__QUIT__":
            break

        try:
            speak(text)
            print("DONE", flush=True)

        except Exception as e:
            print("ERROR: " + str(e), flush=True)

except KeyboardInterrupt:
    pass

print("Piper worker завершён.", file=sys.stderr, flush=True)
EOF
```

Создайте модуль нормализации чисел, дат и сокращений `/opt/jarvis/text_normalizer.py`:

```sh
cat > /opt/jarvis/text_normalizer.py <<'EOF'
import re
from num2words import num2words

MONTHS = {
    1: "января", 2: "февраля", 3: "марта",
    4: "апреля", 5: "мая", 6: "июня",
    7: "июля", 8: "августа", 9: "сентября",
    10: "октября", 11: "ноября", 12: "декабря"
}

DAYS = {
    1: "первое", 2: "второе", 3: "третье",
    4: "четвертое", 5: "пятое", 6: "шестое",
    7: "седьмое", 8: "восьмое", 9: "девятое",
    10: "десятое", 11: "одиннадцатое",
    12: "двенадцатое", 13: "тринадцатое",
    14: "четырнадцатое", 15: "пятнадцатое",
    16: "шестнадцатое", 17: "семнадцатое",
    18: "восемнадцатое", 19: "девятнадцатое",
    20: "двадцатое", 21: "двадцать первое",
    22: "двадцать второе", 23: "двадцать третье",
    24: "двадцать четвертое", 25: "двадцать пятое",
    26: "двадцать шестое", 27: "двадцать седьмое",
    28: "двадцать восьмое", 29: "двадцать девятое",
    30: "тридцатое", 31: "тридцать первое"
}

GENITIVE = {
    "первый": "первого", "второй": "второго",
    "третий": "третьего", "четвертый": "четвертого",
    "пятый": "пятого", "шестой": "шестого",
    "седьмой": "седьмого", "восьмой": "восьмого",
    "девятый": "девятого", "десятый": "десятого",
    "одиннадцатый": "одиннадцатого",
    "двенадцатый": "двенадцатого",
    "тринадцатый": "тринадцатого",
    "четырнадцатый": "четырнадцатого",
    "пятнадцатый": "пятнадцатого",
    "шестнадцатый": "шестнадцатого",
    "семнадцатый": "семнадцатого",
    "восемнадцатый": "восемнадцатого",
    "девятнадцатый": "девятнадцатого",
    "двадцатый": "двадцатого"
}

GEN_SMALL = {
    0: "нуля", 1: "одного", 2: "двух",
    3: "трех", 4: "четырех", 5: "пяти",
    6: "шести", 7: "семи", 8: "восьми",
    9: "девяти", 10: "десяти",
    11: "одиннадцати", 12: "двенадцати",
    13: "тринадцати", 14: "четырнадцати",
    15: "пятнадцати", 16: "шестнадцати",
    17: "семнадцати", 18: "восемнадцати",
    19: "девятнадцати"
}

GEN_TENS = {
    20: "двадцати", 30: "тридцати",
    40: "сорока", 50: "пятидесяти",
    60: "шестидесяти", 70: "семидесяти",
    80: "восьмидесяти", 90: "девяноста"
}


def cardinal(value, gender="m"):
    raw = str(value).replace(" ", "").replace(",", ".")

    sign = ""
    if raw.startswith("+"):
        sign, raw = "плюс ", raw[1:]
    elif raw.startswith("-"):
        sign, raw = "минус ", raw[1:]

    if "." in raw:
        whole, fraction = raw.split(".", 1)
        denominator = {
            1: "десятых", 2: "сотых",
            3: "тысячных", 4: "десятитысячных",
            5: "стотысячных", 6: "миллионных"
        }.get(len(fraction), "долей")

        result = (
            num2words(int(whole), lang="ru")
            + " целых "
            + num2words(int(fraction), lang="ru")
            + " " + denominator
        )
    else:
        if len(raw) > 1 and raw.startswith("0"):
            names = [
                "ноль", "один", "два", "три", "четыре",
                "пять", "шесть", "семь", "восемь", "девять"
            ]
            result = " ".join(names[int(x)] for x in raw)
        else:
            result = num2words(int(raw or "0"), lang="ru")

        if gender == "f":
            parts = result.split()
            if parts[-1] == "один":
                parts[-1] = "одна"
            elif parts[-1] == "два":
                parts[-1] = "две"
            result = " ".join(parts)

    return sign + result.replace("-", " ")


def ordinal(number):
    try:
        return num2words(int(number), lang="ru", to="ordinal")
    except Exception:
        return cardinal(number)


def year_genitive(number):
    words = ordinal(number).split()
    words[-1] = GENITIVE.get(words[-1], words[-1])
    return " ".join(words)


def year_locative(number):
    forms = {
        "первый": "первом", "второй": "втором",
        "третий": "третьем", "четвертый": "четвертом",
        "пятый": "пятом", "шестой": "шестом",
        "седьмой": "седьмом", "восьмой": "восьмом",
        "девятый": "девятом", "десятый": "десятом"
    }
    words = ordinal(number).split()
    words[-1] = forms.get(words[-1], words[-1])
    return " ".join(words)


def genitive(number):
    n = int(number)

    if n in GEN_SMALL:
        return GEN_SMALL[n]

    if n < 100:
        tens = n // 10 * 10
        remainder = n % 10

        result = GEN_TENS[tens]
        if remainder:
            result += " " + GEN_SMALL[remainder]

        return result

    return cardinal(n)


def plural(number, forms):
    raw = str(number).replace(",", ".")

    if "." in raw:
        return forms[2]

    n = abs(int(raw))
    last_two = n % 100

    if 11 <= last_two <= 14:
        return forms[2]

    last = n % 10

    if last == 1:
        return forms[0]
    if 2 <= last <= 4:
        return forms[1]

    return forms[2]


def quantity(number, forms, tail="", gender="m"):
    return (
        cardinal(number, gender)
        + " "
        + plural(number, forms)
        + tail
    )


def normalize_for_speech(text):
    text = text.replace("\u00a0", " ")

    names = {
        "NASA": "НАСА",
        "Artemis": "Артемида",
        "Orion": "Орион",
        "Apollo": "Аполлон",
        "SpaceX": "Спейс Икс",
        "Blue Origin": "Блю Ориджин",
        "Teghaza": "Тегаза"
    }

    text = re.sub(
        r"\bArtemis\s+II\b", "Артемида два",
        text, flags=re.I
    )
    text = re.sub(
        r"\bArtemis\s+III\b", "Артемида три",
        text, flags=re.I
    )

    for old, new in names.items():
        text = re.sub(re.escape(old), new, text, flags=re.I)

    def numeric_date(m):
        day, month, year = map(int, m.groups())

        if month not in MONTHS or day not in DAYS:
            return m.group(0)

        return (
            DAYS[day] + " " + MONTHS[month]
            + " " + year_genitive(year) + " года"
        )

    text = re.sub(
        r"(?<!\d)(\d{1,2})[./](\d{1,2})[./](\d{4})(?!\d)",
        numeric_date,
        text
    )

    months = "|".join(MONTHS.values())

    def textual_date(m):
        day, month, year = m.groups()
        return (
            DAYS[int(day)] + " " + month
            + " " + year_genitive(year) + " года"
        )

    text = re.sub(
        rf"(?<!\d)(\d{{1,2}})\s+({months})\s+(\d{{4}})\s+года\b",
        textual_date, text, flags=re.I
    )

    text = re.sub(
        r"(?<!\d)(\d{4})\s+года\b",
        lambda m: year_genitive(m.group(1)) + " года",
        text
    )

    text = re.sub(
        r"(?<!\d)(\d{4})\s+году\b",
        lambda m: year_locative(m.group(1)) + " году",
        text
    )

    text = re.sub(
        r"(?<!\d)(\d{4})\s+год\b",
        lambda m: ordinal(m.group(1)) + " год",
        text
    )

    text = re.sub(
        rf"(?<!\d)(\d{{1,2}})\s+({months})\b",
        lambda m: DAYS[int(m.group(1))] + " " + m.group(2),
        text, flags=re.I
    )

    range_units = {
        "м/с": "метров в секунду",
        "km/s": "километров в секунду",
        "км/ч": "километров в час",
        "км": "километров",
        "м": "метров",
        "см": "сантиметров",
        "мм": "миллиметров",
        "°c": "градусов Цельсия",
        "%": "процентов"
    }

    def range_replace(m):
        return (
            "от " + genitive(m.group(1))
            + " до " + genitive(m.group(2))
            + " " + range_units[m.group(3).lower()]
        )

    range_pattern = (
        r"(?<!\w)(\d+)\s*[–—-]\s*(\d+)\s*"
        r"(км/ч|м/с|km/s|км|см|мм|м|°C|%)"
        r"(?!\w)"
    )

    text = re.sub(
        range_pattern, range_replace, text, flags=re.I
    )

    rules = [
        (r"(?P<n>[+-]?\d+(?:[.,]\d+)?)\s*(?:км/ч|km/h)",
         ("километр", "километра", "километров"), " в час", "m"),

        (r"(?P<n>[+-]?\d+(?:[.,]\d+)?)\s*(?:м/с|m/s)",
         ("метр", "метра", "метров"), " в секунду", "m"),

        (r"(?P<n>[+-]?\d+(?:[.,]\d+)?)\s*°\s*C",
         ("градус", "градуса", "градусов"), " Цельсия", "m"),

        (r"(?P<n>[+-]?\d+(?:[.,]\d+)?)\s*%",
         ("процент", "процента", "процентов"), "", "m"),

        (r"(?P<n>[+-]?\d+(?:[.,]\d+)?)\s*(?:кВт)",
         ("киловатт", "киловатта", "киловатт"), "", "m"),

        (r"(?P<n>[+-]?\d+(?:[.,]\d+)?)\s*(?:ГБ)",
         ("гигабайт", "гигабайта", "гигабайтов"), "", "m"),

        (r"(?P<n>[+-]?\d+(?:[.,]\d+)?)\s*(?:МБ)",
         ("мегабайт", "мегабайта", "мегабайтов"), "", "m"),

        (r"(?P<n>[+-]?\d+(?:[.,]\d+)?)\s*(?:км)",
         ("километр", "километра", "километров"), "", "m"),

        (r"(?P<n>[+-]?\d+(?:[.,]\d+)?)\s*(?:см)",
         ("сантиметр", "сантиметра", "сантиметров"), "", "m"),

        (r"(?P<n>[+-]?\d+(?:[.,]\d+)?)\s*(?:мм)",
         ("миллиметр", "миллиметра", "миллиметров"), "", "m"),

        (r"(?P<n>[+-]?\d+(?:[.,]\d+)?)\s*(?:кг)",
         ("килограмм", "килограмма", "килограммов"), "", "m"),

        (r"(?P<n>[+-]?\d+(?:[.,]\d+)?)\s*(?:мл)",
         ("миллилитр", "миллилитра", "миллилитров"), "", "m"),

        (r"(?P<n>[+-]?\d+(?:[.,]\d+)?)\s*(?:л)",
         ("литр", "литра", "литров"), "", "m"),

        (r"(?P<n>[+-]?\d+(?:[.,]\d+)?)\s*(?:г)",
         ("грамм", "грамма", "граммов"), "", "m"),

        (r"(?P<n>[+-]?\d+(?:[.,]\d+)?)\s*(?:м)",
         ("метр", "метра", "метров"), "", "m")
    ]

    for pattern, forms, tail, gender in rules:
        text = re.sub(
            pattern,
            lambda m: quantity(
                m.group("n"), forms, tail, gender
            ),
            text,
            flags=re.I
        )

    abbreviations = {
        r"\bм/с\b": "метров в секунду",
        r"\bкм/ч\b": "километров в час",
        r"\bкм\b": "километров",
        r"\bсм\b": "сантиметров",
        r"\bмм\b": "миллиметров",
        r"\bкг\b": "килограммов",
        r"\bмл\b": "миллилитров",
        r"\bмлн\.": "миллионов",
        r"\bмлрд\.": "миллиардов",
        r"\bтыс\.": "тысяч",
        r"\bруб\.": "рублей",
        r"\bдолл\.": "долларов",
        r"\bшт\.": "штук",
        r"\bмин\.": "минут",
        r"\bсек\.": "секунд",
        r"\bГБ\b": "гигабайтов",
        r"\bМБ\b": "мегабайтов",
        r"\bТБ\b": "терабайтов",
        r"\bМГц\b": "мегагерц",
        r"\bГГц\b": "гигагерц",
        r"\bдБ\b": "децибел"
    }

    for pattern, replacement in abbreviations.items():
        text = re.sub(pattern, replacement, text, flags=re.I)

    ordinal_forms = {
        "й": {
            1: "первый", 2: "второй", 3: "третий",
            4: "четвертый", 5: "пятый"
        },
        "го": {
            1: "первого", 2: "второго", 3: "третьего",
            4: "четвертого", 5: "пятого"
        },
        "я": {
            1: "первая", 2: "вторая", 3: "третья"
        },
        "е": {
            1: "первое", 2: "второе", 3: "третье"
        }
    }

    def ordinal_suffix(m):
        n = int(m.group(1))
        suffix = m.group(2)
        return ordinal_forms.get(suffix, {}).get(n, ordinal(n))

    text = re.sub(
        r"(?<!\w)(\d+)-(го|й|я|е)\b",
        ordinal_suffix, text
    )

    number_pattern = (
        r"(?<!\w)([+-]?\d{1,3}(?:[ \u00a0]\d{3})+"
        r"(?:[.,]\d+)?|[+-]?\d+(?:[.,]\d+)?)(?!\w)"
    )

    text = re.sub(
        number_pattern,
        lambda m: cardinal(m.group(1)),
        text
    )

    symbols = {
        "№": "номер",
        "&": "и",
        "=": "равно",
        "%": "процентов",
        "°": "градусов",
        "$": "долларов",
        "€": "евро",
        "₽": "рублей",
        "+": "плюс",
        "/": "или"
    }

    for symbol, word in symbols.items():
        text = text.replace(symbol, " " + word + " ")

    text = re.sub(r"[()\[\]{}<>]", " ", text)
    text = re.sub(r"\s+", " ", text)
    text = re.sub(r"\s+([,.!?;:])", r"\1", text)

    return text.strip()
EOF
```

Создайте основной скрипт голосового помощника `/opt/jarvis/jarvis.py`:

```sh
cat > /opt/jarvis/jarvis.py <<'EOF'
import os
from pathlib import Path
import re
import json
import struct
import subprocess
import select
import threading
import fcntl
from datetime import date

from vosk import Model, KaldiRecognizer, SetLogLevel
from gigachat import GigaChat
from text_normalizer import normalize_for_speech
from gigachat.models import (
  ChatCompletionRequest,
  ChatMessage,
  ChatTool,
  ChatToolConfig,
  ChatWebSearchTool
)

SetLogLevel(-1)

MODEL_PATH = "/opt/jarvis/models/vosk-model-small-ru-0.22"

PIPER_WORKER = "/opt/jarvis/piper_worker.py"
PIPER_PYTHON = "/opt/jarvis/piper-venv/bin/python"
CA_CERT = (
    "/usr/local/share/ca-certificates/"
    "russian_trusted_root_ca_pem.crt"
)

armed = False
mic_muted = False


class PiperWorker:
    def __init__(self):
        print("Запуск постоянного Piper...")

        self.proc = subprocess.Popen(
            [PIPER_PYTHON, PIPER_WORKER],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            bufsize=1
        )

        status = self.proc.stdout.readline().strip()

        if status != "READY":
            self.close()
            raise RuntimeError(
                "Piper не загрузился: " + status
            )

        print("Piper загружен и готов.")

    def speak(self, text):
        if self.proc.poll() is not None:
            raise RuntimeError("Процесс Piper завершился")

        text = " ".join(text.split())

        if not text:
            return

        self.proc.stdin.write(text + "\n")
        self.proc.stdin.flush()

        result = self.proc.stdout.readline().strip()

        if result != "DONE":
            raise RuntimeError(
                "Ошибка Piper: " + result
            )

    def close(self):
        if not hasattr(self, "proc"):
            return

        if self.proc.poll() is None:
            try:
                if self.proc.stdin and not self.proc.stdin.closed:
                    self.proc.stdin.write("__QUIT__\n")
                    self.proc.stdin.flush()
                    self.proc.stdin.close()

                self.proc.wait(timeout=5)

            except Exception:
                self.proc.terminate()

                try:
                    self.proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait()

        if self.proc.stdout:
            self.proc.stdout.close()


def hardware_controls():
    global armed, mic_muted

    event_format = "@llHHi"
    event_size = struct.calcsize(event_format)

    def find_device(device_name):
        for entry in sorted(os.listdir("/sys/class/input")):
            if not entry.startswith("event"):
                continue

            name_path = f"/sys/class/input/{entry}/device/name"

            try:
                name = Path(name_path).read_text().strip()
            except OSError:
                continue

            if name == device_name:
                return "/dev/input/" + entry

        raise FileNotFoundError(device_name)

    fds = {}
    buffers = {}

    try:
        for name in ("rotary-encoder", "gpio-keys"):
            fd = os.open(
                find_device(name),
                os.O_RDONLY | os.O_NONBLOCK
            )
            fds[fd] = name
            buffers[fd] = bytearray()

        gpio_fd = next(
            fd for fd, name in fds.items()
            if name == "gpio-keys"
        )

        try:
            state = bytearray(3)
            fcntl.ioctl(gpio_fd, 0x8003451b, state, True)
            mic_muted = bool(state[1] & (1 << 6))
        except OSError:
            pass

        status_msg = (
            "Микрофон выключен."
            if mic_muted else "Микрофон включён."
        )
        print(
            "Jarvis: Аппаратное управление подключено. "
            + status_msg
        )

        while True:
            ready, _, _ = select.select(
                list(fds), [], [], 1.0
            )

            for fd in ready:
                try:
                    data = os.read(fd, event_size * 32)
                except BlockingIOError:
                    continue

                buffers[fd].extend(data)

                while len(buffers[fd]) >= event_size:
                    raw = bytes(buffers[fd][:event_size])
                    del buffers[fd][:event_size]

                    _, _, event_type, code, value = struct.unpack(
                        event_format, raw
                    )

                    device = fds[fd]

                    if (
                        device == "rotary-encoder"
                        and event_type == 2
                        and code == 7
                        and value != 0
                    ):
                        amount = abs(value)
                        direction = "+" if value > 0 else "-"

                        for control in (
                            "Subwoofer Master",
                            "Tweeters Master"
                        ):
                            subprocess.run(
                                [
                                    "amixer", "-q",
                                    "-c", "snddaudio1",
                                    "sset", control,
                                    f"{amount}%{direction}"
                                ],
                                stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL
                            )

                    elif (
                        device == "gpio-keys"
                        and event_type == 1
                        and code == 583
                        and value == 1
                    ):
                        if not mic_muted:
                            armed = True
                            print(
                                "\nJarvis: Кнопка нажата. Слушаю тебя."
                            )

                    elif (
                        device == "gpio-keys"
                        and event_type == 5
                        and code == 14
                        and value in (0, 1)
                    ):
                        mic_muted = bool(value)

                        if mic_muted:
                            armed = False
                            print("\nJarvis: Микрофон выключен.")
                        else:
                            print("\nJarvis: Микрофон включён.")

    except Exception as e:
        print("Jarvis: Ошибка аппаратного управления:", e)

    finally:
        for fd in fds:
            try:
                os.close(fd)
            except OSError:
                pass


def clean_answer(text, max_sentences, max_words=None):
    text = re.sub(
        r"\[sources=\[[^\]]*\]\]",
        "",
        text,
        flags=re.IGNORECASE
    )
    text = re.sub(
        r"\[([^\]]+)\]\(https?://[^)]+\)",
        r"\1",
        text
    )
    text = re.sub(r"https?://\S+", "", text)
    text = re.sub(r"(?m)^\s*#{1,6}\s*", "", text)
    text = re.sub(r"(?m)^\s*[-*•]\s*", "", text)
    text = re.sub(r"[*_`#]", "", text)
    text = re.sub(r"\s+", " ", text).strip()

    protected = "\uE000"

    for abbreviation in (
        "т.д.", "т.п.", "т.е.", "т.к.", "т.ч.",
        "г.", "ул.", "д.", "им.", "стр.", "рис."
    ):
        text = re.sub(
            re.escape(abbreviation),
            abbreviation.replace(".", protected),
            text,
            flags=re.IGNORECASE
        )

    sentences = re.split(
        r'(?<=[.!?])\s+(?=[А-ЯЁA-Z0-9«„"“])',
        text
    )

    sentences = [
        part.strip()
        for part in sentences
        if part.strip()
    ]

    sentences = sentences[:max_sentences]

    if max_words is not None:
        limited = []
        remaining = max_words

        for sentence in sentences:
            words = sentence.split()

            if len(words) <= remaining:
                limited.append(sentence)
                remaining -= len(words)
            elif remaining > 0:
                fragment = " ".join(
                    words[:remaining]
                ).rstrip(" ,;:—-")
                if fragment and fragment[-1] not in ".!?":
                    fragment += "."
                if fragment:
                    limited.append(fragment)
                break
            else:
                break

        sentences = limited

    text = " ".join(sentences)

    return text.replace(protected, ".").strip()


def ask_gigachat(client, question):
    today = date.today().strftime("%d.%m.%Y")

    detailed = bool(re.search(
        r"\b(подробн\w*|развернут\w*|развёрнут\w*|детальн\w*|"
        r"полный разбор|пошагово|с деталями)\b",
        question,
        flags=re.IGNORECASE
    ))

    if detailed:
        answer_style = (
            "Пользователь запросил подробный ответ. "
            "Дай содержательное объяснение примерно "
            "в 5–10 предложениях. Раскрой важные детали, "
            "но не повторяй одно и то же."
        )
        max_sentences = 10
    else:
        answer_style = (
            "Это обычный режим. Ответь строго в 1–3 "
            "коротких предложениях, желательно не более "
            "25 слов. Не добавляй вступление и вывод, "
            "если они не нужны."
        )
        max_sentences = 3

    prompt = (
        "Все числа, даты и единицы измерения пиши полностью "
        "словами на русском языке. Не используй цифры, латинские "
        "сокращения и математические символы. Используй правильные "
        "падежи и различай количественные и порядковые числительные. "
        f"Сегодня {today}. "
        "Ты Jarvis — голосовой помощник. "
        "Общайся исключительно на русском. "
        "Для ответа обязательно используй подключённый "
        "веб-поиск, а не только знания модели. "
        "Проверяй актуальные сведения, даты и факты "
        "по найденным источникам. "
        "Не выдумывай события, цифры и ссылки. "
        "Если надёжных результатов нет или источники "
        "расходятся, честно скажи об этом. "
        "Не используй Markdown, списки, заголовки "
        "и URL в самом ответе: источники будут "
        "показаны отдельно в консоли. "
        + answer_style
        + "\nЗапрос пользователя: " + question
    )

    request = ChatCompletionRequest(
        model="GigaChat-3-Ultra",
        messages=[
            ChatMessage(
                role="user",
                content=prompt
            )
        ],
        tools=[
            ChatTool(
                web_search=ChatWebSearchTool(
                    type="actual_info_web_search"
                )
            )
        ],
        tool_config=ChatToolConfig(
            mode="forced",
            tool_name="web_search"
        )
    )

    response = client.chat.create(request)

    data = response.model_dump(exclude_none=True)

    messages = data.get("messages", [])

    if not messages:
        raise RuntimeError("GigaChat не вернул сообщение")

    message = messages[0]
    content = message.get("content", [])

    if isinstance(content, str):
        content = [{"text": content}]

    text_parts = []
    sources_by_url = {}

    for part in content:
        if not isinstance(part, dict):
            continue

        part_text = part.get("text")

        if part_text:
            text_parts.append(part_text)

        inline = part.get("inline_data") or {}
        source_map = inline.get("sources") or {}

        source_items = (
            source_map.values()
            if isinstance(source_map, dict)
            else source_map
        )

        for source in source_items:
            if not isinstance(source, dict):
                continue

            url = source.get("url", "").strip()
            title = source.get("title", "").strip()

            if url and url not in sources_by_url:
                sources_by_url[url] = {
                    "title": title or url,
                    "url": url
                }

    answer = " ".join(text_parts).strip()
    answer = clean_answer(
        answer, max_sentences, max_words=None if detailed else 25
    )

    if not answer:
        raise RuntimeError("GigaChat вернул пустой ответ")

    return answer, list(sources_by_url.values())


def parse_command(text):
    global armed

    text = text.lower().strip()

    if not text:
        return None

    match = re.search(r"\bджарвис\b", text)

    if match:
        question = (
            text[:match.start()] +
            " " +
            text[match.end():]
        ).strip(" ,.!?;:")

        if not question:
            armed = True
            print("\nJarvis: Слушаю тебя.")
            return None

        armed = False
        return question

    if armed:
        armed = False
        return text

    print("[Без активации — игнорирую]")
    return None


def start_microphone():
    return subprocess.Popen(
        [
            "arecord", "-q",
            "-D", "hw:2,0",
            "-t", "raw",
            "-f", "S32_LE",
            "-r", "16000",
            "-c", "5"
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        bufsize=0
    )


def stop_microphone(proc):
    if proc.poll() is None:
        proc.terminate()

        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()

    if proc.stdout:
        proc.stdout.close()


def main():
    global armed

    for path in [
        MODEL_PATH + "/am/final.mdl",
        PIPER_WORKER,
        PIPER_PYTHON,
        "/opt/jarvis/models/piper/ru_RU-dmitri-medium.onnx"
    ]:
        if not os.path.isfile(path):
            raise FileNotFoundError(path)

    if not os.environ.get("GIGACHAT_CREDENTIALS"):
        raise RuntimeError("Не загружен GigaChat API key")

    print("Загрузка Vosk...")
    model = Model(MODEL_PATH)

    print("Подключение GigaChat...")

    with GigaChat(
        credentials=os.environ["GIGACHAT_CREDENTIALS"],
        scope="GIGACHAT_API_PERS",
        model="GigaChat-3-Ultra",
        base_url="[https://api.giga.chat/v1](https://api.giga.chat/v1)",
        ca_bundle_file=CA_CERT,
        verify_ssl_certs=True,
        max_retries=2,
    ) as client:

        piper = PiperWorker()
        threading.Thread(
            target=hardware_controls, daemon=True
        ).start()

        try:
            print("\n==============================")
            print("       JARVIS VOICE MVP")
            print("==============================")
            print("Vosk: готов")
            print("GigaChat: подключён")
            print("Piper: постоянно загружен")
            print("------------------------------")
            print("Скажи: Джарвис, привет")
            print("Или сначала: Джарвис")
            print("Для выхода нажми Ctrl+C")
            print("==============================\n")

            while True:
                rec = KaldiRecognizer(model, 16000)
                pending = bytearray()
                was_muted = mic_muted

                proc = start_microphone()
                restart = False

                print("Jarvis слушает...")

                try:
                    while True:
                        chunk = proc.stdout.read(32000)

                        if not chunk:
                            raise RuntimeError(
                                "Микрофон остановился"
                            )

                        if mic_muted:
                            pending.clear()
                            if not was_muted:
                                rec = KaldiRecognizer(model, 16000)
                                was_muted = True
                            continue

                        if was_muted:
                            rec = KaldiRecognizer(model, 16000)
                            pending.clear()
                            was_muted = False

                        pending.extend(chunk)

                        usable = (len(pending) // 20) * 20

                        if not usable:
                            continue

                        raw = bytes(pending[:usable])
                        del pending[:usable]

                        pcm = bytearray(
                            (usable // 20) * 2
                        )

                        for i, frame in enumerate(
                            struct.iter_unpack("<5I", raw)
                        ):
                            # ADC2 R
                            x = (frame[2] >> 16) & 0xffff

                            if x >= 32768:
                                x -= 65536

                            struct.pack_into(
                                "<h", pcm, i * 2, x
                            )

                        if rec.AcceptWaveform(bytes(pcm)):
                            result = json.loads(rec.Result())
                            recognized = result.get("text", "")

                            if not recognized:
                                continue

                            print("\nТы:", recognized)

                            question = parse_command(recognized)

                            if not question:
                                continue

                            stop_microphone(proc)

                            print("Jarvis: Думаю...")

                            try:
                                answer, sources = ask_gigachat(
                                    client, question
                                )

                                answer = normalize_for_speech(answer)
                                print("Jarvis:", answer)

                                print("Jarvis: Говорю...")
                                piper.speak(answer)

                                print(
                                    "\nJarvis закончил отвечать."
                                )

                            except Exception as e:
                                print("Ошибка:", str(e))

                            restart = True
                            break

                        else:
                            partial = json.loads(
                                rec.PartialResult()
                            ).get("partial", "")

                            if partial:
                                print(
                                    "\rСлышу: " + partial + " " * 10,
                                    end="",
                                    flush=True
                                )

                finally:
                    stop_microphone(proc)

                if not restart:
                    break

        finally:
            print("\nОстановка Piper...")
            piper.close()
            print("Piper остановлен.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nJarvis выключен.")
EOF
```

### 4. Ключ API и системное время { #config }

Запишите ключ авторизации в закрытый файл `/etc/jarvis/gigachat.env`, подставив своё
значение вместо заглушки:

```sh
mkdir -p /etc/jarvis
cat > /etc/jarvis/gigachat.env <<'EOF'
GIGACHAT_CREDENTIALS="<REDACTED>"
GIGACHAT_SCOPE="GIGACHAT_API_PERS"
GIGACHAT_VERIFY_SSL_CERTS="true"
EOF

chmod 600 /etc/jarvis/gigachat.env
chown root:root /etc/jarvis/gigachat.env
```

Проверьте работу службы синхронизации времени `chrony` и текущую дату, иначе проверка
сертификатов завершится ошибкой:

```sh
sv status /etc/service/chrony
date
```

Если часовой пояс не совпадает с вашим, установите нужный (в примере — Москва):

```sh
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
echo "Europe/Moscow" > /etc/timezone
```

### 5. Служба автозапуска { #service }

Создайте управляющий скрипт `/root/jarvis-control.sh`. Скрипт проверяет целостность
моделей и библиотек, создаёт службу автозапуска и настраивает ротацию журнала:

```sh
cat > /root/jarvis-control.sh <<'EOF'
#!/bin/sh

set -eu

BASE="/opt/jarvis"
SERVICE="/etc/service/jarvis"
ENV_FILE="/etc/jarvis/gigachat.env"
LOG_DIR="/var/log/jarvis"

PYTHON="$BASE/venv/bin/python"
PIPER="$BASE/piper-venv/bin/piper"

MODEL="$BASE/models/vosk-model-small-ru-0.22"
VOICE="$BASE/models/piper/ru_RU-dmitri-medium.onnx"
CA_CERT="/usr/local/share/ca-certificates/russian_trusted_root_ca_pem.crt"

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
        "$BASE/text_normalizer.py" \
        "$PYTHON" \
        "$PIPER" \
        "$ENV_FILE" \
        "$MODEL/am/final.mdl" \
        "$VOICE" \
        "$VOICE.json" \
        "$CA_CERT"
    do
        [ -e "$file" ] || die "Нет файла: $file"
        echo "[OK] $file"
    done

    sh -n "$ENV_FILE" || die "Ошибка env-файла"

    sh -c '
        set -a
        . "$1"
        test -n "${GIGACHAT_CREDENTIALS:-}"
    ' sh "$ENV_FILE" || die "Нет ключа GigaChat"

    "$PYTHON" -m py_compile \
        "$BASE/jarvis.py" \
        "$BASE/text_normalizer.py" \
        "$BASE/piper_worker.py" ||
        die "Ошибка синтаксиса Python-скриптов"

    "$PYTHON" -c 'import vosk, gigachat, num2words' ||
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

    if [ -f "$SERVICE/run" ] || [ -f "$SERVICE/log/run" ]; then
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
EOF
```

Сделайте скрипт исполняемым, добавьте симлинк `jarvisctl` и зарегистрируйте службу:

```sh
chmod +x /root/jarvis-control.sh
ln -sf /root/jarvis-control.sh /usr/local/bin/jarvisctl
jarvisctl install
```

## Использование { #usage }

Активировать помощника можно двумя способами:

- сказать «Джарвис» и сразу произнести вопрос или дождаться готовности к приёму;
- нажать верхнюю кнопку активации на корпусе и задать вопрос.

Для развёрнутого ответа (до десяти предложений вместо одного-трёх) добавьте в запрос
слово «подробно» или «пошагово». Вращение верхнего кольца регулирует громкость низких
и высоких частот, а кнопка отключения микрофона блокирует запись.

Управление службой выполняется через `jarvisctl`:

| Команда | Действие |
|---|---|
| `jarvisctl check` | Проверить наличие файлов, моделей, библиотек и ключей |
| `jarvisctl status` | Показать статус службы, громкость ALSA и конец журнала |
| `jarvisctl logs` | Открыть журнал `/var/log/jarvis/current` в реальном времени |
| `jarvisctl restart` | Перезапустить помощника |
| `jarvisctl stop` | Остановить службу |
| `jarvisctl start` | Запустить службу |

## Ограничения { #limits }

- Рецепт рассчитан на образ Debian 13, где нет Android-окружения и штатной Алисы.
- Распознавание и синтез речи работают локально, но для ответов нужен доступ в интернет
  к серверам GigaChat API.
- Контекст диалога между репликами не сохраняется: каждый вопрос обрабатывается отдельно.
- Во время озвучивания ответа микрофон отключается, поэтому перебить помощника голосом
  нельзя.
- Светодиодное кольцо для индикации состояний помощника не используется.

## Откат { #rollback }

Остановите службу и удалите созданные файлы:

```sh
jarvisctl stop
rm -rf /etc/service/jarvis /var/log/jarvis /etc/jarvis /opt/jarvis
rm -f /usr/local/bin/jarvisctl /root/jarvis-control.sh
```

## Как это работает { #how }

В образе Debian для Станции 1 доступны все аппаратные узлы платы: микрофонная матрица,
усилители TAS5751M на звуковой карте `snddaudio1`, физические кнопки и энкодер громкости.

| Компонент | Роль в системе |
|---|---|
| Vosk | Локальное распознавание речи и ключевого слова (`vosk-model-small-ru-0.22`) |
| GigaChat API | Генерация ответов с веб-поиском через модель `GigaChat-3-Ultra` |
| `text_normalizer.py` | Перевод чисел, дат, единиц измерения и символов в слова |
| Piper | Синтез речи (`ru_RU-dmitri-medium.onnx`), удерживаемый в памяти |
| `runit` и `svlogd` | Автозапуск службы `/etc/service/jarvis` и ротация журнала |