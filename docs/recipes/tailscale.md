# Tailscale на колонке: своя LLM мимо порезанного Cloudflare

Колонка ходит к своему LLM-эндпоинту (например, адрес `QUASAR_LLM_BASE_URL` у
[Quasar Bridge](llm.md#quasar-bridge)) напрямую по закрытой сети Tailscale: без Cloudflare и
без открытых портов. Нужно, если эндпоинт опубликован через Cloudflare, а провайдер колонки
замораживает соединения к адресам Cloudflare после ~16 КБ: мост ждёт ответ 60 секунд и
говорит «Сейчас не получилось получить ответ».

**Проверено на:** Станция Мини 2, прошивка 0.369.1.46, Tailscale 1.104.5 (`arm`),
Quasar Bridge 0.7.1, 07.11.2026.

## Ваш ли это случай { #diagnose }

Признаки в `service.log` моста: `native_route_decision` с `"route":"llm"`, а `native_route`
того же запроса ровно через 60 секунд. До LLM-эндпоинта запрос не доходит или ответ не
возвращается. Часто падает 3-4-й запрос подряд по одному соединению.

Проверка с компьютера в той же сети, что колонка (без VPN на компьютере): скачать со своего
домена за Cloudflare страницу больше 50 КБ.

```sh
curl -s -o /dev/null --max-time 15 -w '%{size_download} байт за %{time_total} с\n' \
  https://<ваш-домен>/<большая-страница>
```

Если загрузка останавливается на 16-18 тыс. байт и висит до тайм-аута, а без Cloudflare
та же проверка проходит, это этот случай. Само замедление описано в
[блоге Cloudflare](https://blog.cloudflare.com/russian-internet-users-are-unable-to-access-the-open-internet/).

## Что понадобится { #requirements }

- Root и SSH на колонке, см. [SSH](../start/ssh.md).
- Аккаунт Tailscale и сервер с LLM-эндпоинтом в той же сети Tailscale.
- Около 30 МБ свободного места на `/data` (на ubifs `tailscaled` занимает ~27 МБ вместо 38)
  и ~10 МБ памяти.
- Ядро с TUN: `ls -l /dev/net/tun` и `zcat /proc/config.gz | grep CONFIG_TUN=y`.

!!! warning "На Мини 2 нужен архив `arm`, а не `arm64`"
    Ядро на Мини 2 64-битное, но система 32-битная: `file` у бинарников показывает
    ARM 32-bit. Нужен `tailscale_<версия>_arm.tgz`.

## Установка { #install }

1. На компьютере скачать `tailscale_<версия>_arm.tgz` с
   [pkgs.tailscale.com](https://pkgs.tailscale.com/stable/), сверить `sha256` с файлом
   `.sha256` рядом и распаковать.
2. Положить на колонку только `tailscaled`. Утилита `tailscale` (32 МБ) нужна один раз для
   входа и живёт во временной папке.

    ```sh
    ssh -p 2222 root@<колонка> 'mkdir -p /data/opt/tailscale/state'
    cat tailscaled | ssh -p 2222 root@<колонка> \
      'cat > /data/opt/tailscale/tailscaled && chmod 755 /data/opt/tailscale/tailscaled'
    ```

3. Создать сторож запуска `/data/opt/tailscale/supervise.sh`: перезапускает `tailscaled`
   при падении и держит журнал не больше 1 МБ.

    ```sh
    #!/bin/sh
    # Сторож tailscaled. Проверено на Мини 2, 0.369.1.46. Откат - раздел «Откат» рецепта.
    D=/data/opt/tailscale
    L=$D/tailscaled.log
    mkdir -p /run/tailscale $D/state
    export GOMEMLIMIT=40MiB GOGC=50 GOMAXPROCS=1
    # если замерзает сервер управления Tailscale (см. «Ограничения»), раскомментировать:
    # export TS_FORCE_NOISE_443=true
    trim() {
      s=$(wc -c <"$L" 2>/dev/null || echo 0)
      if [ "$s" -gt 1048576 ]; then
        tail -c 200000 "$L" >"$L.tmp" && cat "$L.tmp" >"$L"; rm -f "$L.tmp"
      fi
    }
    ( while sleep 600; do trim; done ) &
    TRIM=$!; TS=""
    trap 'kill $TRIM $TS 2>/dev/null; exit 0' TERM INT
    while true; do
      trim
      "$D/tailscaled" --statedir="$D/state" --socket=/run/tailscale/tailscaled.sock \
        --port=41641 --no-logs-no-support >>"$L" 2>&1 &
      TS=$!; wait $TS
      echo "$(date '+%F %T') tailscaled exited rc=$?" >>"$L"
      sleep 5
    done
    ```

4. Создать автозапуск `/etc/init.d/S94tailscaled`: он стартует раньше моста (`S96`).
   Корень только для чтения, поэтому его временно перемонтируют.

    ```sh
    #!/bin/sh
    # Автозапуск tailscaled. Откат: удалить этот файл и /data/opt/tailscale.
    D=/data/opt/tailscale; P=/run/tailscale/supervise.pid
    case "${1:-start}" in
      start)
        [ -x "$D/tailscaled" ] || exit 0
        mkdir -p /run/tailscale
        if [ -f "$P" ] && kill -0 "$(cat "$P")" 2>/dev/null; then exit 0; fi
        setsid sh "$D/supervise.sh" </dev/null >/dev/null 2>&1 &
        echo $! >"$P" ;;
      stop)
        [ -f "$P" ] && kill "$(cat "$P")" 2>/dev/null
        sleep 1; killall tailscaled 2>/dev/null; rm -f "$P" ;;
      restart) "$0" stop; sleep 2; "$0" start ;;
    esac
    exit 0
    ```

    ```sh
    mount -o remount,rw /
    cat > /etc/init.d/S94tailscaled    # вставить скрипт выше
    chmod 755 /etc/init.d/S94tailscaled
    sync; mount -o remount,ro /
    /etc/init.d/S94tailscaled start
    ```

5. Войти в Tailscale. Утилита - во временную папку, после входа её удаляют:

    ```sh
    cat tailscale | ssh -p 2222 root@<колонка> 'cat > /tmp/tailscale && chmod 755 /tmp/tailscale'
    ssh -p 2222 root@<колонка> '/tmp/tailscale --socket=/run/tailscale/tailscaled.sock up \
      --hostname=<имя> --accept-dns=false --accept-routes=false --netfilter-mode=off'
    ```

    Открыть показанную ссылку и подтвердить вход. `--accept-dns=false` оставляет штатный
    `unbound` колонки, `--netfilter-mode=off` не даёт Tailscale трогать iptables. Проверка:
    `tailscale status` показывает `Running`, затем `rm /tmp/tailscale`. В админке Tailscale
    стоит отключить срок ключа узла (Disable key expiry), иначе через 180 дней колонка
    выпадет из сети.

6. На сервере открыть эндпоинт только в сеть Tailscale, например
   `tailscale serve --bg --tcp <порт> tcp://127.0.0.1:<порт>`. На колонке указать мосту адрес
   в сети Tailscale в `/data/opt/quasar-bridge/runtime.env`:

    ```sh
    QUASAR_LLM_BASE_URL="http://<tailnet-адрес-сервера>:<порт>/v1"
    ```

    и перезапустить мост: `/etc/init.d/S96quasar-bridge restart`. Трафик внутри Tailscale
    шифрует WireGuard, поэтому `http` здесь допустим.

## Использование { #usage }

После перезагрузки колонка через 10-20 секунд снова в сети Tailscale (сторож в `S94`), мост
ходит по ней. Проверка с колонки:

```sh
wget -q -O - http://<tailnet-адрес-сервера>:<порт>/health
```

Попутно SSH к колонке доступен из сети Tailscale, без компьютера в её домашней сети.

Колонку с root и сторонними программами стоит изолировать. Пример политики (ACL): колонке
открыт только эндпоинт, к колонке - только SSH с ваших машин.

```json
"grants": [
  {"src": ["<колонка>"], "dst": ["<сервер>"], "ip": ["tcp:<порт>"]},
  {"src": ["<ваш-компьютер>"], "dst": ["<колонка>"], "ip": ["tcp:2222", "icmp:*"]}
]
```

## Ограничения { #limits }

- **Сервер управления Tailscale тоже может замерзать.** Признаки: вход подтверждён, а колонка
  остаётся в `NeedsLogin`, в журнале `control: map response long-poll timed out!`, в
  `netstat` у соединения висит неподтверждённый `Send-Q`. На проверенной колонке провайдер
  замораживал соединение к серверу управления по IPv6 и по порту 80, а IPv4 с TLS на 443
  проходил. Лечение: закрепить `controlplane.tailscale.com` на IPv4 в `/etc/hosts` колонки
  (адреса - из `nslookup controlplane.tailscale.com`) и включить `TS_FORCE_NOISE_443=true` в
  сторож. Если Tailscale сменит адреса, колонка выпадет из сети: сверять по `nslookup`.
- **Профиль сохраняется только после первой карты сети.** Если вход застрял и `tailscaled`
  перезапустили, вход подтверждают заново.
- **Память и место.** `tailscaled` берёт около 10 МБ ОЗУ (держит `GOMEMLIMIT`), утилиту
  `tailscale` на `/data` не хранят. Временная копия в `/tmp` занимает ОЗУ - после входа её
  удаляют.
- Ретранслятор DERP, если прямой путь не установился, находится за рубежом и может тормозить
  так же. На проверенной колонке путь до сервера был прямым.
- Проверено только на Мини 2.

## Откат { #rollback }

```sh
# мост - обратно на прежний адрес: вернуть QUASAR_LLM_BASE_URL в runtime.env
vi /data/opt/quasar-bridge/runtime.env
/etc/init.d/S96quasar-bridge restart
# Tailscale целиком
/etc/init.d/S94tailscaled stop
mount -o remount,rw /
rm /etc/init.d/S94tailscaled
# если правили /etc/hosts - вернуть исходный
sync; mount -o remount,ro /
rm -r /data/opt/tailscale
```

Узел колонки удалить и в админке Tailscale.
