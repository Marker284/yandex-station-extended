# ТВ-набор для Станции 1 { #station1-tv }

Станция 1 выводит экран Алисы по HDMI. Рецепт ставит рядом ТВ-лаунчер, YouTube-клиент и
VPN-клиент, а управляет ими веб-пульт в браузере телефона: Bluetooth-пульты к Станции 1 не
подключаются.

**Проверено на:** Яндекс Станция 1 (tulip), прошивка 2.369.5.46, root, SSH (Dropbear) и Entware от
[AliceBridge](../start/root-android.md#station-1), телевизор 1080p по HDMI. Версии приложений:
Couchy Launcher 1.0.6, SmartTube 32.68, v2rayNG 1.9.45. На других моделях не проверялось.

**Не проверялось:** работа VPN, воспроизведение YouTube через VPN, режим «Couchy при загрузке»
после перезагрузки (настройка сохраняется, но сценарий загрузки не прогонялся).

!!! danger "Веб-пульт работает без пароля"
    lighttpd слушает порт **8080 на всех интерфейсах**, а CGI `/cgi-bin/k` работает
    с правами root: любой в вашей сети может запускать приложения, вводить текст и
    перезагружать колонку — пароля нет. Держите колонку только в доверенной сети и не
    пробрасывайте порт 8080 наружу. То же касается SSH на порту 2222 (см.
    [шаг 2](../start/ssh.md#dropbear)).

## Что ставится { #what }

| Компонент | Откуда | Зачем |
|---|---|---|
| Веб-пульт | [`contrib/station1-tv/`](https://github.com/Marker284/yandex-station-extended/tree/main/contrib/station1-tv) | кнопки, запуск приложений, настройки; `http://<STATION_IP>:8080` |
| Couchy Launcher | [conreo/couchy-launcher](https://github.com/conreo/couchy-launcher) | ТВ-лаунчер под управление с пульта, без сервисов Google |
| SmartTube | [yuliskov/SmartTube](https://github.com/yuliskov/SmartTube) | YouTube для ТВ, без сервисов Google |
| v2rayNG 1.9.45 | [2dust/v2rayNG](https://github.com/2dust/v2rayNG/releases/tag/1.9.45) | VPN (VLESS, VMess, Trojan, Shadowsocks) |
| lighttpd | Entware | отдаёт страницу пульта и выполняет CGI |

Официальные YouTube и лаунчер Android TV требуют сервисов Google и Android TV — на Станции 1
их нет (Android 6.0.1, API 23). Happ и Incy не ставятся: им нужен Android 7.0+
(`minSdkVersion 24`, ошибка `INSTALL_FAILED_OLDER_SDK`). У v2rayNG 1.9.45 `minSdkVersion 21`.

## Установка { #install }

Нужно заранее: root, SSH и Entware через AliceBridge, клон репозитория, Windows с OpenSSH.

1. Из клона репозитория запустите установщик:

    ```powershell
    powershell -ExecutionPolicy Bypass -File contrib/station1-tv/install.ps1 -Ip <STATION_IP>
    ```

    Пароль root спросят дважды. С SSH-ключом — `-Key <путь к ключу>`. Если на компьютере
    включён VPN и колонка без него недоступна — `-BindAddress <IP компьютера в локальной сети>`.

2. Скрипт скачивает APK с GitHub-релизов (Couchy и SmartTube — последние, v2rayNG — 1.9.45),
   одним архивом отправляет их на колонку вместе с файлами пульта и запускает
   `install-on-speaker.sh`. В конце он печатает адрес пульта.

3. Откройте в браузере телефона адрес пульта (порт 8080):

    ```text
    http://<STATION_IP>:8080
    ```

Повторный запуск безопасен: приложения обновляются поверх (`pm install -r`), их данные
остаются.

## Пульт { #remote }

- крестовина и OK, «Назад», Play/Pause, меню, громкость;
- запуск приложений: «Алиса», «Лаунчер» (Couchy), «YouTube» (SmartTube), «VPN» (v2rayNG);
- ввод текста для поиска — только латиница (`input text`);
- нажатие обрабатывается примерно за 1,2 с, при удержании стрелки повторяются раз в 0,9 с.

В разделе «Настройки»:

- **VPN (v2rayNG)** — поле для ключа (vless, vmess, trojan, Shadowsocks) или ссылки подписки
  (по протоколу HTTPS): ссылка уходит в v2rayNG, набирать её стрелками не нужно;
- **Лаунчер при загрузке** — Алиса или Couchy (хранится в `/data/dropbear/tv.conf`);
- **Выгрузить лаунчер Яндекса** — `am force-stop ru.yandex.quasar.app`;
- **Перезагрузить колонку**.

!!! warning "Без лаунчера Яндекса Алиса перестаёт отвечать голосом"
    Служба Алисы работает внутри `ru.yandex.quasar.app`. Это касается и режима
    «Couchy при загрузке», и кнопки выгрузки. Чтобы вернуть голос, выберите «Алиса» и
    перезагрузите колонку.

## VPN и YouTube { #vpn }

Если DNS роутера или провайдера не отдаёт адрес youtube.com, SmartTube показывает
`Unable to resolve host "www.youtube.com"`. Тогда:

1. Пульт → «Настройки» → «VPN (v2rayNG)» → вставить ключ или ссылку подписки → «Добавить».
2. На телевизоре v2rayNG пишет, удался ли импорт.
3. Выберите сервер, нажмите ▶ внизу справа и подтвердите запрос Android на VPN кнопкой OK.

<a id="rollback"></a>

## Откат { #uninstall }

```sh
sed -i '/remote.sh/d' /data/dropbear/start.sh
rm -rf /opt/share/remote /data/dropbear/remote.sh /data/dropbear/tv.conf /opt/etc/lighttpd/remote.conf
pm uninstall com.conreo.couchytv; pm uninstall org.smarttube.stable; pm uninstall com.v2ray.ang
/opt/bin/opkg remove lighttpd-mod-cgi lighttpd
reboot
```

## Как это работает { #how-it-works }

- `lighttpd` (Entware) слушает порт 8080; `/cgi-bin/k` — скрипт на `sh`, который вызывает
  `input keyevent` и `am start`. Пульт запускается из `/data/dropbear/start.sh` скриптом
  `remote.sh`; он же при `BOOT_LAUNCHER=couchy` ждёт `sys.boot_completed`, открывает Couchy и
  выгружает лаунчер Яндекса.
- `opkg` на Станции 1 качает через `wget`, а `wget` из busybox не резолвит DNS (на Android нет
  `/etc/resolv.conf`). Установщик кладёт `/opt/bin/wget` — обёртку над `/bin/curl` с
  сертификатами `/system/vendor/quasar/ca-certificates.crt`.
- v2rayNG 1.9.45 декодирует параметр `url` в `v2rayng://install-config?url=…` дважды
  (`getQueryParameter` и `URLDecoder`). Поэтому CGI кодирует ссылку второй раз (`%` → `%25`),
  иначе портятся `%2F` и `+` и импорт падает с ошибкой `import subscription failed`.

### Что не работает { #gotchas }

- **Утилита monkey (`monkey --port`).** Быстрее `input keyevent` (~150 мс против ~1,2 с),
  но, пока она запущена, процесс Алисы `maind --platformd` перезапускается каждые 30–80 секунд
  (видно в `/data/quasar/launcher2.log`). Вдобавок `monkey` падает при повторном подключении клиента
  (`MonkeySourceNetworkViews.setup`).
- **Bluetooth-пульты и телефон как Bluetooth-клавиатура.** В стеке Bluetooth Станции 1 нет
  профиля HID: при подключении в logcat появляется сообщение
  `L2CAP - rcvd conn req for unknown PSM: 17`.
  Доступны только A2DP Sink, AVRCP и GATT.
- **Couchy как лаунчер по умолчанию.** После установки второго лаунчера кнопка «Домой»
  показывает выбор `Select a Home app`. Рецепт лаунчер по умолчанию не меняет: Couchy
  открывается поверх лаунчера Яндекса.
