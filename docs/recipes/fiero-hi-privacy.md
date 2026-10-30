# Ограничить отправку метрик на Fiero Hi { #fiero-hi-privacy }

Скрипт направляет точные имена узлов аналитики в `127.0.0.1` строками в `/etc/hosts`.
Алиса, `quasar.cfg` и DNS-серверы не меняются, блокировка снимается одной командой.

**Проверено на:** [Fiero Hi](../devices/fiero-hi.md) (Станция Лайт Micro v1.2), прошивка
`0.369.1.50.4794652826.20261021.126`, root, Dropbear, 31 октября 2026. Проверены применение,
отказ отправки в журнале телеметрии, отсутствие пакетов на адреса метрик, работа после
перезагрузки, обычная голосовая команда при блокировке и откат с совпадением SHA-256
исходного `hosts`. На других моделях не проверялось.

## Что понадобится { #requirements }

- Fiero Hi с root и доступом к консоли: [SSH](../start/ssh.md) или терминал
  [AliceBridge](../start/root-android.md).
- Для загрузки скрипта на колонке — `curl` из [Entware](../start/packages.md).
  Сам скрипт Entware не использует.

## Применение { #apply }

1. На колонке скачайте скрипт и включите блокировку:

    ```sh
    export PATH=/opt/bin:/opt/sbin:$PATH
    base=https://raw.githubusercontent.com/Marker284/yandex-station-extended/main
    curl -fsSL "$base/contrib/fiero-hi-privacy.sh" -o /data/opt/fiero-hi-privacy.sh &&
    sh /data/opt/fiero-hi-privacy.sh apply
    ```

    Скрипт сохраняет копию `hosts` в `/data/opt/fiero-hi-privacy/`, на время правки
    монтирует корень на запись и дописывает строки между метками
    `# fiero-hi-privacy begin` и `# fiero-hi-privacy end`. Правка лежит на корневом разделе,
    поэтому сохраняется после перезагрузки без отдельного автозапуска.

2. Перезагрузите колонку: уже открытые соединения телеметрии закроются, а новые
   пойдут на `127.0.0.1`.

3. Проверьте состояние — все узлы должны резолвиться в `127.0.0.1`:

    ```sh
    sh /data/opt/fiero-hi-privacy.sh check
    ```

    В журнале телеметрии отправка теперь заканчивается ошибкой подключения:

    ```sh
    grep 'curl error' /data/quasar/daemons_logs/telemetry.log | tail -n 2
    ```

    ```text
    … appmetricaBatchSender error: curl error: 7, delaying next attempt for 43980ms; queue.size=2
    … clickdaemonBatchSender error: curl error: 7, delaying next attempt for 42528ms; queue.size=1
    ```

4. Проверьте обычную голосовую команду. Если в работе колонки что-то изменилось,
   выполните [откат](#restore).

## Откат { #restore }

```sh
sh /data/opt/fiero-hi-privacy.sh restore
```

Команда убирает только свои строки между метками и сверяет `hosts` с сохранённой копией
по SHA-256. Если файл с тех пор меняли другим способом, скрипт сообщит об этом, и копию
в `/data/opt/fiero-hi-privacy/hosts.orig` нужно сравнить вручную.

## Что блокируется { #endpoints }

| Узлы | Назначение |
|---|---|
| `startup.mobile.yandex.net`, `startup.appmetrica.yandex.net` | запуск и настройки AppMetrica |
| `report.appmetrica.yandex.net` | отправка отчётов AppMetrica |
| `clck.yandex.net` | пакеты метрик clickdaemon и журналы Fluent Bit |
| `startup.appmetrica.yango.com`, `report.appmetrica.yango.com`, `clck.yasmina.yango.com` | региональные узлы из той же конфигурации |

На проверенной колонке `startup.mobile.yandex.net`, `report.appmetrica.yandex.net`
и `clck.yandex.net` указаны в `quasar.cfg` (`teleme3d`, `fluent-bit`) и в сохранённых адресах
`/data/quasar/quasar_metricad.json`. Список совпадает с
[рецептом для Станции 1](station1-privacy.md) и не распространяется на остальные домены Яндекса.

Как это проверяли: на время проверки в `iptables` добавлялись правила, которые только
считают пакеты на настоящие адреса этих узлов. Без блокировки после перезапуска
`maind --telemetry` за минуту на них ушло около 60 пакетов. С блокировкой, в том числе
после перезагрузки, — ни одного.

## Ограничения { #limits }

- Блокировка не удаляет идентификаторы, локальные записи и очереди: неотправленные пакеты
  остаются в очереди (`queue.size` в журнале), телеметрия повторяет попытки.
- Fluent Bit на проверенной колонке был выключен облачной выборкой (`samplingRatio`).
  Если его включат, он отправляет журналы на `clck.yandex.net`, который заблокирован.
- Обновление прошивки перезаписывает корневой раздел вместе с `/etc/hosts`.
- Облачный трафик Алисы, запись голоса и согласие «Помогать Алисе стать лучше» этот
  рецепт не затрагивает — см. [Телеметрия](../internals/telemetry.md#when).
