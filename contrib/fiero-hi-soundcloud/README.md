# fiero-hi-soundcloud — SoundCloud голосом на Fiero Hi

«Алиса, включи … на саундклауде», перемотка, пауза, треки и громкость — без ПК и без
yt-dlp/python. Установка, команды и устройство — в
[рецепте](../../docs/recipes/fiero-hi-soundcloud.md).

Проверено на Fiero Hi (Станция Лайт, blackthorn), прошивка
`0.369.1.50.4794652826.20261021.126`.

| Файл | Что делает |
|---|---|
| `alice-text.sh`, `alice-text.awk` | текст фраз и состояние Алисы из `127.0.0.1:9875` (`socat -x` + `awk`) |
| `voice-soundcloud.sh` | разбор фраз → команды `sc-play.sh`; лог `voice.log` — только команды SoundCloud |
| `sc-play.sh` | `play <запрос>`, `next`, `prev`, `seek <±с>`, `pause`, `resume`, `stop`, `volume <+N\|-N\|N>` |
| `sc-vpn.sh` | VLESS-прокси на xray: `set 'vless://…'`, `start`, `stop`, `restart`, `status`, `test` |
| `sc-boot.sh` | автозапуск: голосовой слушатель и SSH на 2223 |

На колонке всё лежит в `/data/opt/soundcloud/`; там же создаются `xray.gz`, `vless.url`,
`xray.json` (права 600), `client_id` и логи. Вне каталога меняется только
`/data/opt/media/bin/ap-start.sh` (копия — `ap-start.sh.bak`).

Откат — раздел [«Удаление»](../../docs/recipes/fiero-hi-soundcloud.md#uninstall) рецепта.
