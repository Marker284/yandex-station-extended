# Отключение обновлений на Станции 1 { #station1-disable-updates }

Рецепт останавливает службу обновлений Алисы, если колонка с root по кругу пытается поставить
обязательное обновление, а Алиса отвечает с ошибками.

!!! note "Проверено"
    Яндекс Станция 1 (`tulip`), прошивка `2.369.5.46`, root через AliceBridge, SSH (dropbear) в
    `/data/dropbear`. На других моделях и прошивках не проверялось.

!!! warning
    Колонка перестаёт получать исправления ошибок и безопасности. Если Яндекс перестанет
    обслуживать старую прошивку, Алиса может перестать работать совсем.

Для моделей на Linux (Лайт, Мини и др.) обновления отключаются скриптом `yandex-noupdate.sh`
из [шага 2](../start/ssh.md#kill-ota). На Станции 1 (Android) он не подходит: рецепт ниже
только замораживает службу обновлений и ничего не меняет в `/system`.

## Признаки { #symptoms }

- В `/sensors_cache/logs/updatesd.log` каждые ~40 секунд повторяется одна и та же пара строк:
  `Has update: version: ...` и `Executing OTA script ...`.
- На часть запросов Алиса не отвечает: подсветка переливается и гаснет. В
  `/sensors_cache/logs/maind.log` при этом видно `onRequestError: ... error=ErrorDeviceNotReady,
  errorText=Настройте станцию заново`.
- Каждые ~30 секунд перезапускается локальный сервер на порту 1961: в `maind.log` повторяется
  `Restarting WS server due to new auth data`. Приложения на телефоне не могут подключиться.

## Шаги { #steps }

1. Скопировать
   [`contrib/station1-freeze-updatesd.sh`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/station1-freeze-updatesd.sh)
   на колонку (из клона репозитория):

    ```sh
    ssh root@<STATION_IP> 'cat > /data/dropbear/freeze_updatesd.sh' < contrib/station1-freeze-updatesd.sh
    ```

2. Проверить синтаксис:

    ```sh
    /sbin/busybox sh -n /data/dropbear/freeze_updatesd.sh && echo OK
    ```

3. Добавить запуск в `/data/dropbear/start.sh` сразу после строки `#!/system/bin/sh`:

    ```sh
    /sbin/busybox sed -i '1a /sbin/busybox setsid /sbin/busybox sh /data/dropbear/freeze_updatesd.sh </dev/null >>/data/dropbear/freeze.log 2>\&1 \&' /data/dropbear/start.sh
    ```

4. Перезагрузить колонку:

    ```sh
    sync; reboot
    ```

5. После загрузки убедиться, что служба заморожена:

    ```sh
    cat /data/dropbear/freeze.log
    for p in /proc/[0-9]*; do
        case "$(tr '\0' ' ' < $p/cmdline 2>/dev/null)" in
            *maind\ --updatesd*) grep State $p/status;;
        esac
    done
    ```

    В журнале должны появиться строки `freeze started` и `froze <pid>`, а состояние процесса
    должно быть `T (stopped)`. Нового `updatesd.log` в этой загрузке не появляется.

!!! warning
    При переустановке SSH через AliceBridge `start.sh` перезаписывается. После этого шаг 3 нужно
    повторить.

## Откат { #rollback }

1. Удалить строку с `freeze_updatesd.sh` из `/data/dropbear/start.sh`:

    ```sh
    /sbin/busybox sed -i '/freeze_updatesd/d' /data/dropbear/start.sh
    ```

2. Перезагрузить колонку. Служба обновлений запустится как обычно.

## Как это работает { #how-it-works }

- Службы Алисы запускает `quasar_launcher2` по списку из `/system/vendor/quasar/launch.json`.
  Обновлениями занимается задача `updatesd` (`maind --updatesd`). Если её завершить, лаунчер
  перезапускает её.
- AliceBridge подменяет `/system/vendor/quasar/device_ota_update.sh` заглушкой, которая
  возвращает `exit 1`. Если сервер требует обязательное обновление (при регистрации отвечает
  `"hasCriticalUpdate":true`), `updatesd` бесконечно повторяет проверку файла и запуск установки.
  Именно в это время Алиса отвечает с ошибками.
- `SIGSTOP` оставляет процесс живым, но он ничего не делает. Лаунчер видит, что процесс есть,
  и не перезапускает его.
- Скрипт работает в фоне и проверяет процессы раз в 3 секунды. Это нужно, потому что время запуска
  `start.sh` после загрузки меняется: наблюдалось и 28 секунд (раньше `updatesd`, который
  стартует примерно на 37-й секунде), и около 10 минут.
- Подменить `launch.json` через `mount -o bind` из `start.sh` нельзя: лаунчер читает его на
  ~34-й секунде загрузки, и `start.sh` может запуститься позже.
- Через системный `/system/bin/sh` фоновый скрипт после загрузки не оставался работать, а через
  `/sbin/busybox sh` работает. Причина не выяснена.

## Ограничения { #limits }

- Между загрузкой и запуском `start.sh` служба обновлений успевает поработать. Если `start.sh`
  запускается поздно, Алиса может ненадолго уйти в режим обновления. Поставить прошивку служба
  всё равно не может: установка заблокирована заглушкой AliceBridge.
- Сервер Яндекса уже знает, что колонке нужно обновление. После остановки `updatesd` Алиса
  отвечала нормально, но это проверено только на одной колонке, и поведение сервера может
  измениться.
