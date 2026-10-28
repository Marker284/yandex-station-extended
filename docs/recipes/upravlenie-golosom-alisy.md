# Управление голосом

Программа для управления озвучкой через колонки с веб-интерфейсов

Проверено на mini-2, lite-2.

## Что понадобится

- root ([шаг 1](../start/root.md))
- доступ по ssh

## Шаги

1. Установите на устройство socat, скорее всего он будет у вас в /opt/bin/socat. Если нет поменяйте в коде строчку 'exec /opt/bin/socat STDIO TCP:127.0.0.1:9875,connect-timeout=2'.
2. Создайте host с именем alice в ~/.ssh/config
3. Скачайте код: `curl -o alice-tts.tar.gz https://x0.at/vIwK.gz && tar xzf alice-tts.tar.gz`
4. Запусти run.sh и перейдите на localhost:8787