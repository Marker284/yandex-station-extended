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
- **GigaChat API** — генерация ответов и поиск актуальной информации в сети (Web Search).
- **Piper (`ru_RU-dmitri-medium.onnx`)** — локальный нейросетевой TTS-движок, удерживающий модель в памяти через `piper_worker.py` для быстрого отклика.
- **runit (`/etc/service/jarvis`)** — системный супервизор Debian на Станции, отвечающий за автостарт при подаче питания, логирование (`svlogd`) и перезапуск при сбоях.

## Шаги

### 1. Установка системных зависимостей и сертификатов НУЦ Минцифры

Зайдите на Станцию в Debian по SSH под `root` и установите базовые пакеты для работы со звуком, архивами и Python:

```sh
apt update
apt install -y python3 python3-venv python3-pip alsa-utils curl ca-certificates unzip nano
```

Для работы с API Сбера установите корневой сертификат Минцифры по пути, который проверяет управляющий скрипт:

```sh
curl -kfsSL https://gu-st.ru/content/lending/russian_trusted_root_ca_pem.crt \
  -o /usr/local/share/ca-certificates/russian_trusted_root_ca_pem.crt
update-ca-certificates
```

### 2. Подготовка каталога `/opt/jarvis`, виртуальных окружений и моделей

Создайте рабочую структуру каталогов и два виртуальных окружения — основное (`venv`) и для голосового синтезатора (`piper-venv`):

```sh
mkdir -p /opt/jarvis/models/piper
cd /opt/jarvis

python3 -m venv /opt/jarvis/venv
/opt/jarvis/venv/bin/pip install --upgrade pip
/opt/jarvis/venv/bin/pip install vosk gigachat

python3 -m venv /opt/jarvis/piper-venv
/opt/jarvis/piper-venv/bin/pip install --upgrade pip
/opt/jarvis/piper-venv/bin/pip install piper-tts
```

Скачайте модель распознавания речи **Vosk** и голосовую модель **Piper**:

```sh
cd /opt/jarvis/models
curl -fSL https://alphacephei.com/vosk/models/vosk-model-small-ru-0.22.zip -o vosk.zip
unzip vosk.zip && rm -f vosk.zip

cd /opt/jarvis/models/piper
curl -fSL https://huggingface.co/rhasspy/piper-voices/resolve/main/ru/ru_RU/dmitri/medium/ru_RU-dmitri-medium.onnx \
  -o ru_RU-dmitri-medium.onnx
curl -fSL https://huggingface.co/rhasspy/piper-voices/resolve/main/ru/ru_RU/dmitri/medium/ru_RU-dmitri-medium.onnx.json \
  -o ru_RU-dmitri-medium.onnx.json
```

### 3. Создание рабочих скриптов помощника

Создайте скрипт постоянного фонового воркера синтеза речи `/opt/jarvis/piper_worker.py`:

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

Создайте вспомогательный модуль нормализации текста перед озвучиванием `/opt/jarvis/text_normalizer.py`:

```sh
cat > /opt/jarvis/text_normalizer.py <<'EOF'
import re


def normalize_for_speech(text: str) -> str:
    text = re.sub(r"https?://\S+", "", text)
    text = re.sub(r"[*_`#~<>]", "", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text
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

        print(
            "Jarvis: Аппаратное управление подключено. "
            + ("Микрофон выключен." if mic_muted else "Микрофон включён.")
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
        fragment = " ".join(words[:remaining]).rstrip(" ,;:—-")
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
    "Все числа, даты и единицы измерения пиши полностью словами на русском языке. "
    "Не используй цифры, латинские сокращения и математические символы. "
    "Используй правильные падежи и различай количественные и порядковые числительные. "
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
  answer = clean_answer(answer, max_sentences, max_words=None if detailed else 25)

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
        base_url="https://api.giga.chat/v1",
        ca_bundle_file="/usr/local/share/ca-certificates/russian_trusted_root_ca_pem.crt",
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

### 4. Настройка ключа GigaChat

Создайте закрытый файл конфигурации `/etc/jarvis/gigachat.env` с вашим ключом авторизации:

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
    Не публикуйте ключи из `devices.json`, `gigachat.env`, MAC-адреса, серийные номера и токены.

### 5. Проверка системного времени и часового пояса

Корректное время необходимо для проверки SSL-сертификатов GigaChat. Убедитесь, что служба `chrony` активна в `runit`, а часовой пояс настроен верно:

```sh
sv status /etc/service/chrony
date
```

Если часовой пояс отличается от вашего, задайте его (например, для Москвы):

```sh
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
echo "Europe/Moscow" > /etc/timezone
```

### 6. Установка единого скрипта управления и автозапуска (`jarvisctl`)

Чтобы не управлять процессами вручную и обеспечить автоматический старт помощника при включении Станции в розетку, создайте управляющий скрипт `/root/jarvis-control.sh`. Он проверит целостность всех моделей и библиотек, создаст службу `runit` в `/etc/service/jarvis` и настроит ротацию логов через `svlogd` в `/var/log/jarvis`.

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
        "$BASE/text_normalizer.py" \
        "$PYTHON" \
        "$PIPER" \
        "$ENV_FILE" \
        "$MODEL/am/final.mdl" \
        "$VOICE" \
        "$VOICE.json" \
        "/usr/local/share/ca-certificates/russian_trusted_root_ca_pem.crt"
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
```

Сделайте скрипт исполняемым, создайте короткую ссылку `jarvisctl` и запустите установку службы:

```sh
chmod +x /root/jarvis-control.sh
ln -sf /root/jarvis-control.sh /usr/local/bin/jarvisctl
jarvisctl install
```

### 7. Управление и проверка работы

После установки управлять помощником можно одной командой `jarvisctl`:

| Команда             | Действие                                                     |
| :------------------ | :----------------------------------------------------------- |
| `jarvisctl check`   | Проверить целостность файлов, моделей, библиотек и ключей    |
| `jarvisctl status`  | Показать статус службы `runit`, уровень громкости ALSA и хвост лога |
| `jarvisctl logs`    | Открыть журнал работы в реальном времени (`/var/log/jarvis/current`) |
| `jarvisctl restart` | Перезапустить помощника                                      |
| `jarvisctl stop`    | Остановить службу                                            |
| `jarvisctl start`   | Запустить службу                                             |

Убедитесь, что в выводе `jarvisctl status` служба имеет статус `run: /etc/service/jarvis: (pid ...)`, и проверьте работу колонки:

- вращение кольца регулирует громкость (`Subwoofer Master` / `Tweeters Master`);
- нажатие кнопки активации включает прослушивание;
- кнопка микрофона аппаратно и программно отключает запись;
- ассистент отвечает голосом на вопросы.