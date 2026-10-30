# SoundCloud голосом на Fiero Hi { #fiero-hi-soundcloud }

«Алиса, включи … на саундклауде» — колонка сама находит трек в SoundCloud и играет его.
Перемотка, пауза, переключение треков и громкость — голосом, громкость ещё и кнопками.
ПК, yt-dlp и python не нужны: поиск через `api-v2.soundcloud.com`, звук через `ffmpeg`
и системный `aplay`. Для доступа к SoundCloud из России нужен свой ключ VLESS.

**Проверено на:** [Fiero Hi](../devices/fiero-hi.md) (DNS FDNS-00024, Станция Лайт,
blackthorn), прошивка `0.369.1.50.4794652826.20261021.126`.
Голосом проверены запуск, перемотка, пауза и продолжение, громкость; кнопками — громкость.
Проверен автозапуск после перезагрузки. На других моделях не проверялось.

## Что понадобится { #requirements }

- Fiero Hi с [root и SSH](../devices/fiero-hi.md#root), Entware в `/opt`.
- Действующий ключ VLESS; проверено с `type=tcp`, `security=reality`,
  `flow=xtls-rprx-vision`.
- Около 16 МБ на `/data`; при игре xray занимает ~30 МБ в `/tmp` (RAM).

## Установка { #install }

1. Скопируйте файлы на колонку (с ПК, из корня репозитория):

    ```sh
    IP=<IP колонки>
    ssh -p 2222 root@$IP 'mkdir -p /data/opt/soundcloud'
    for f in alice-text.sh alice-text.awk voice-soundcloud.sh sc-play.sh sc-vpn.sh sc-boot.sh; do
      ssh -p 2222 root@$IP "cat > /data/opt/soundcloud/$f" < contrib/fiero-hi-soundcloud/$f
    done
    ```

    Дальше команды выполняются на колонке.

2. Поставьте `jq` и сделайте скрипты исполняемыми (`ffmpeg` и `socat` на Fiero Hi уже есть):

    ```sh
    export PATH=/opt/bin:/opt/sbin:$PATH
    opkg update && opkg install jq
    chmod 755 /data/opt/soundcloud/*.sh
    ```

3. Подготовьте xray. Целиком (29,7 МБ) он на `/data` не помещается, поэтому хранится
   сжатым (10,5 МБ) и распаковывается в `/tmp` при первом запуске:

    ```sh
    mkdir /tmp/xr && cd /tmp/xr
    opkg download xray-core
    gzip -dc xray-core_*.ipk | tar -x
    gzip -dc data.tar.gz | tar -x
    gzip -9 -c opt/sbin/xray > /data/opt/soundcloud/xray.gz
    cd / && rm -rf /tmp/xr
    ```

4. Задайте ключ VLESS и проверьте прокси:

    ```sh
    /data/opt/soundcloud/sc-vpn.sh set 'vless://…'
    /data/opt/soundcloud/sc-vpn.sh test     # через прокси: 200, … байт за 0.5 с
    ```

    Через прокси ходят только `curl` и `ffmpeg` плеера, остальной трафик колонки — напрямую.
    Ссылка хранится в `/data/opt/soundcloud/vless.url` с правами 600.

5. Включите автозапуск. Его вызывает штатный для Fiero Hi `ap-start.sh` (из `S99zairplay`),
   исходный файл сохраняется рядом:

    ```sh
    A=/data/opt/media/bin/ap-start.sh
    cp -p $A $A.bak
    sed -i '1a [ -x /data/opt/soundcloud/sc-boot.sh ] \&\& sh /data/opt/soundcloud/sc-boot.sh >> /data/opt/soundcloud/boot.log 2>\&1' $A
    sh /data/opt/soundcloud/sc-boot.sh      # sc-boot: ssh2223=up voice=up
    ```

    `sc-boot.sh` поднимает голосовой слушатель и SSH на порту 2223 (см.
    [SSH по ключу](#ssh-key)). xray запускается сам при первом «включи».

6. Проверьте:

    ```sh
    cd /data/opt/soundcloud
    ./sc-play.sh play lofi                            # играю: lofi (10 треков)
    sleep 5
    grep state /proc/asound/card0/pcm0p/sub0/status   # state: RUNNING — звук идёт
    ./sc-play.sh stop
    ```

### SSH по ключу { #ssh-key }

`/root` на Fiero Hi только для чтения, поэтому второй dropbear на 2223 берёт ключи из своей
папки (`-D`). Ключи dropbear не примет, если папки по пути открыты на запись группе или
всем, — у Entware они `777`:

```sh
D=/data/opt/etc/dropbear
chmod go-w /data/opt /data/opt/etc $D
mkdir -p $D/ak && chmod 700 $D/ak
echo 'ssh-ed25519 AAAA… ваш-ключ' >> $D/ak/authorized_keys
chmod 600 $D/ak/authorized_keys
```

После этого `sc-boot.sh` запускает dropbear на 2223 при каждой загрузке.

## Голосовые команды { #voice }

| Фраза | Что делает |
|---|---|
| «Алиса, включи *запрос* на саундклауде» | поиск и запуск до 10 найденных треков подряд |
| «перемотай на 30 секунд», «вперёд на 2 минуты», «назад на минуту», «на полминуты» | перемотка; без числа — на 10 с; числа цифрами и словами |
| «пауза», «стоп», «хватит», «выключи» | пауза, Алиса возвращается |
| «продолжи» | с того же места, в течение часа после паузы |
| «дальше», «следующий» | следующий трек |
| «предыдущий», «назад» | в начало трека; в первые 5 с трека — предыдущий трек |
| «сначала», «заново» | трек с начала |
| «громче», «тише» | ±10 % |
| «громкость 5», «громкость пять», «громкость 40 процентов» | 50 %, 50 %, 40 % |

Кнопки «+» и «−» меняют громкость шагом 5 %. Команды управления работают, пока
играет SoundCloud.

- После «включи … на саундклауде» Алиса отвечает своё и на секунду может включить
  свою музыку, затем играет SoundCloud — звук через 3–4 с.
- После перемотки звук возвращается через 4–5 с.
- Пока играет SoundCloud, Алиса голосом не отвечает; команды при этом выполняются.
- После «стоп» Алиса снова работает как обычно через 12–13 с.

## Замена ключа VLESS { #vless }

```sh
/data/opt/soundcloud/sc-vpn.sh set 'vless://…'
```

Конфиг xray пересобирается, xray перезапускается. Текущий сервер —
`sc-vpn.sh status`, скорость — `sc-vpn.sh test`.

## Если не работает { #troubleshooting }

```sh
cd /data/opt/soundcloud
tail voice.log                   # команды SoundCloud и фразы, которые их вызвали
cat /tmp/sc-ffmpeg.log           # ошибки ffmpeg последнего трека
./sc-vpn.sh status
```

- `state: PREPARED` дольше ~6 с — завис `dmix`; плеер перезапускает трек сам. Вручную:
  `./sc-play.sh stop`, затем, если к `dmix` никто не подключён (`ipcs -m`, `nattch` = 0 у
  ключей `0x400`/`0x401`): `ipcrm -M 0x400; ipcrm -M 0x401; ipcrm -S 0x400`.
- Алиса молчит — проверьте, что `maind --mediad` ровно один
  (`ps -o pid,ppid,args | grep mediad`) и громкость не 0 (`amixer sget Master`).

## Удаление { #uninstall }

```sh
cd /data/opt/soundcloud && ./sc-play.sh stop && ./sc-vpn.sh stop
cp -p /data/opt/media/bin/ap-start.sh.bak /data/opt/media/bin/ap-start.sh
for p in $(ps -o pid,args |
    awk '/[v]oice-soundcloud|[a]lice-text|[s]ocat -x -u TCP:127.0.0.1:9875/ {print $1}'); do
  kill $p
done
cd / && rm -rf /data/opt/soundcloud
opkg remove jq
```

SSH на 2223 удаление не трогает. Фоновая проверка `sc-play.sh`, которая возвращает Алису
после «стоп», доработает сама (до 10 мин) — её не завершать, иначе Алиса может остаться
без `mediad`.

## Как это работает { #how-it-works }

```text
aliced (127.0.0.1:9875) ─► alice-text.sh/.awk ─► voice-soundcloud.sh ─► sc-play.sh
                            текст фраз            разбор команд          поиск, плеер
api-v2.soundcloud.com ─(xray)─► HLS ─► ffmpeg ─► /usr/bin/aplay ─► softvol Master ─► dmix
```

- **Текст фраз.** `aliced` (в процессе `maind --platformd`, порт `9875` из `quasar.cfg`)
  рассылает кадры: 4 байта длины LE + protobuf; поле 253 = 3 — состояние Алисы, в поле 252:
  поле 1 — статус (1 — черновик, 3 — окончательная фраза), поле 2 — текст, поле 7 — id
  запроса. Окончательная фраза приходит 3–4 раза — повторы отсекаются по id запроса.
  Разбор — на `socat -x` и `awk`, без компиляции, по образцу `alice-text.c` из
  [`station2-media`][station2-media].
- **Поиск.** `client_id` берётся из HTML `m.soundcloud.com` (`"clientId":"…"`):
  `soundcloud.com` с колонки не открывается. Поток — HLS AAC, ссылки на сегменты подписаны.
- **VPN.** Без него CDN SoundCloud отдавал колонке сегмент 15 КБ за 15 с, через xray —
  за доли секунды. `curl` и `ffmpeg` получают `http_proxy`/`https_proxy` =
  `127.0.0.1:10809`; `ffmpeg` ходит через прокси по протоколу `httpproxy`.
- **Перемотка.** `ffmpeg -ss` по HLS SoundCloud (fMP4, `EXT-X-MAP`) не отдаёт ни байта,
  поэтому `sc-play.sh` собирает локальный плейлист с нужного сегмента (по `#EXTINF`),
  а остаток внутри сегмента отрезает после декодирования.
- **Вывод звука.** Только системный `/usr/bin/aplay`: `/etc/asound.conf` ведёт `default`
  через softvol `Master` в `dmix`. `aplay` из Entware читает `/opt/etc/asound.conf`, где
  `default` — сразу `hw:0,0`, мимо `Master`: громкость на него не действует.
- **Алиса на время SoundCloud.** На «включи … на саундклауде» Алиса включает своё, поэтому
  `maind --mediad` (её плеер) на время игры гасится — через `SIGTERM`, до 5 с. `mediad`
  всегда держит `dmix` открытым, и `kill -9` посреди записи оставляет семафор `dmix`
  (ключ `0x400`) занятым — весь звук виснет. Перед стартом плеера `dmix` пересоздаётся,
  если к нему никто не подключён; если звук всё же завис на ~6 с, трек перезапускается
  с того же места на новом `dmix`. После «стоп» `mediad` поднимает лаунчер quasar, но с
  растущей паузой (13 с, 57 с, больше 90 с подряд), поэтому через 10 с скрипт запускает свой
  экземпляр. Два `mediad` дерутся за звук, и Алиса молчит: когда лаунчер поднимает свой,
  экземпляр скрипта завершается через `SIGTERM`.
- **Громкость.** Кнопки обрабатывает `platformd` и сам меняет `Master`. Голосовые
  «громче/тише» выполняет `mediad`, а он погашен, поэтому их выполняет `sc-play.sh`.
- **Автозапуск.** Корневая ФС только для чтения, поэтому `sc-boot.sh` вызывается из
  `/data/opt/media/bin/ap-start.sh`, который запускает `S99zairplay`.

[station2-media]: https://github.com/Marker284/yandex-station-extended/tree/main/contrib/station2-media
