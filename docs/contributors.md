# Участники

Вики пишут люди, которые разбирают свои колонки и присылают находки. Спасибо всем!
Хотите в этот список — [дополните вики](contributing.md).

## Pull request'ы

| Кто | Что добавил |
|---|---|
| [@MyszkinPL](https://github.com/MyszkinPL) | [Станция 1-го поколения](devices/station-gen1.md): железо, загрузка, разметка eMMC ([#1](https://github.com/Marker284/yandex-station-extended/pull/1)) |
| [@whiteonred](https://github.com/whiteonred) | запуск Dropbear с пустым паролем root ([#2](https://github.com/Marker284/yandex-station-extended/pull/2)) |
| [@derangedabbot](https://github.com/derangedabbot) | [USB Host на Станции 2](devices/station-2.md#usb-host) и установка на неё ([#4](https://github.com/Marker284/yandex-station-extended/pull/4), [#13](https://github.com/Marker284/yandex-station-extended/pull/13)), отчёт [#3](https://github.com/Marker284/yandex-station-extended/issues/3); [AirPlay: идеи со Станции 2](recipes/airplay.md#station-2) и `contrib/audio-owner.sh` ([#16](https://github.com/Marker284/yandex-station-extended/pull/16)) |
| [@chelik0002](https://github.com/chelik0002) | [автозапуск SSH](start/ssh.md#dropbear): новый ключ, лог, `restart` ([#5](https://github.com/Marker284/yandex-station-extended/pull/5)); [Станция Миди](devices/station-midi.md): Zigbee, UART, разделы eMMC, DVFS, микрофоны ([#17](https://github.com/Marker284/yandex-station-extended/pull/17), [#20](https://github.com/Marker284/yandex-station-extended/pull/20)); [Станция 3 (Orion)](devices/station-3.md): железо, индикация, звук, I2C, разделы, NPU, Zigbee ([#39](https://github.com/Marker284/yandex-station-extended/pull/39), [#40](https://github.com/Marker284/yandex-station-extended/pull/40)); [Станция Макс с Zigbee](devices/station-max-zigbee.md) — `YNDX-00052`: Zigbee через Gowin FPGA, разметка eMMC, I2C, unifykeys ([#35](https://github.com/Marker284/yandex-station-extended/pull/35)); [вкладка TP-Link](start/root.md#dns-unlock) в шаге 3 ([#29](https://github.com/Marker284/yandex-station-extended/pull/29)) |
| [@krevetkqqq](https://github.com/krevetkqqq) | [root через локальный стенд](start/root.md#dns-unlock) — вариант 2 ([#6](https://github.com/Marker284/yandex-station-extended/pull/6)) |
| [@andy-ye](https://github.com/andy-ye) | [Голосовой тракт Алисы](internals/voice.md), заметки о `maind` и TLS ([#8](https://github.com/Marker284/yandex-station-extended/pull/8)) |
| [@Eld3rly](https://github.com/Eld3rly) | [root на Лайт 2: retail CA из factory](start/retail-ca.md) ([#9](https://github.com/Marker284/yandex-station-extended/pull/9)) |
| [@initialfox](https://github.com/initialfox) | [root с Android через AliceBridge](start/root-android.md), root Станции 1 ([#10](https://github.com/Marker284/yandex-station-extended/pull/10), [#14](https://github.com/Marker284/yandex-station-extended/pull/14), [#19](https://github.com/Marker284/yandex-station-extended/pull/19)) |
| [@Kastle86](https://github.com/Kastle86) | [LED-панель Станции 2](devices/station-2.md#led) и карта светодиодов ([#11](https://github.com/Marker284/yandex-station-extended/pull/11)) |
| [@amirilivice](https://github.com/amirilivice) | [quasard](recipes/llm.md#quasard) — свой сервер вместо облака Алисы ([#12](https://github.com/Marker284/yandex-station-extended/pull/12)) |
| [@novff](https://github.com/novff) | [LED-панель Станции 2](devices/station-2.md#led): формат пикселя RGBW, анимации панели и логотипа ([#21](https://github.com/Marker284/yandex-station-extended/pull/21)) |
| [@skrashevich](https://github.com/skrashevich) | [Quasar Bridge](recipes/llm.md#quasar-bridge) — своя LLM и Home Assistant с облачным голосом Алисы ([#22](https://github.com/Marker284/yandex-station-extended/pull/22)) |
| [@SCP2609](https://github.com/SCP2609) | ссылка на [BetterYAM](recipes/yam.md#betteryam) ([#23](https://github.com/Marker284/yandex-station-extended/pull/23)); [закрепление сетевого ADB](start/ssh.md#perm-adb), BetterYAM 0.1.22 ([#38](https://github.com/Marker284/yandex-station-extended/pull/38)) |
| [@ciphermoth-byte](https://github.com/ciphermoth-byte) | [Станция 3 (orion)](devices/station-3.md): сетевая разведка, проверка DNS-метода ([#25](https://github.com/Marker284/yandex-station-extended/pull/25), [#24](https://github.com/Marker284/yandex-station-extended/issues/24)) |
| [@denisbut1212](https://github.com/denisbut1212) | [DNS на OpenWrt](start/root.md#dns-unlock) только для доменов активации (Podkop), команды отката ([#26](https://github.com/Marker284/yandex-station-extended/pull/26)) |
| [@vladivanov2004](https://github.com/vladivanov2004) | [отключение обновлений на Станции 1](recipes/station1-disable-updates.md) — заморозка `maind --updatesd` и `contrib/station1-freeze-updatesd.sh` ([#34](https://github.com/Marker284/yandex-station-extended/pull/34)); [ТВ-набор для Станции 1](recipes/station1-tv.md): веб-пульт, Couchy, SmartTube, v2rayNG ([#50](https://github.com/Marker284/yandex-station-extended/pull/50)) |
| [@garenal1v3](https://github.com/garenal1v3) | [Директивы и capabilities](internals/directives.md): legacy и typed, `PayloadRaw` ([#27](https://github.com/Marker284/yandex-station-extended/pull/27)) |
| [@rison1337](https://github.com/rison1337) | [голосовой режим сайта ChatGPT](recipes/llm.md#chatgpt-web), [обработанный микрофон VQE](recipes/microphone.md), [озвучка текста через `START_VOCALIZE`](recipes/sounds.md#native-tts) и `contrib/alice-say.py`, [подсветка Лайт 2 / Plum](recipes/led.md#plum-led) ([#36](https://github.com/Marker284/yandex-station-extended/pull/36)) |
| [@ramory-l](https://github.com/ramory-l) | [Мини 3: retail CA из factory](start/retail-ca-mini3.md): resolver для `/register` в eQuasar, factory-4, хеш CA по сборкам, ADB после возврата DNS, DNS на Keenetic ([#31](https://github.com/Marker284/yandex-station-extended/pull/31)); [заметка по macOS и adb](internals/toolchain.md#adb-install) ([#31](https://github.com/Marker284/yandex-station-extended/pull/31)); [Лайт 1](devices/station-lite.md#root): порядок сброса, откат с `.50` через свой стенд, телефон на мобильном интернете ([#33](https://github.com/Marker284/yandex-station-extended/pull/33)) |
| [@dimakolychev](https://github.com/dimakolychev) | [Мини 3 Про на factory-12](devices/station-mini3-pro.md#factory-12): ADB после возврата DNS, подсветка и LED-часы, звук и микрофон, AirPlay, `yse`/Entware, дамп NAND ([#47](https://github.com/Marker284/yandex-station-extended/pull/47)) |
| [@chkzz](https://github.com/chkzz) | [bt-proxy](recipes/bt-proxy.md): MPRIS-плееры как Bluetooth-источник Алисы; [AirPlay 2 на Лайт 2](recipes/airplay.md) вместе с Алисой ([#42](https://github.com/Marker284/yandex-station-extended/pull/42)) |
| [@superkai-sdk1](https://github.com/superkai-sdk1) | Станция 2: [AirPlay 2 одним набором](recipes/airplay.md#station-2-bundle), общая с Алисой громкость, сторож OTA ([#43](https://github.com/Marker284/yandex-station-extended/pull/43)); [Spotify Connect](recipes/spotify.md) и голосовые команды ([#44](https://github.com/Marker284/yandex-station-extended/pull/44)) |

## Данные для страниц моделей

| Кто | Что |
|---|---|
| **@sharazhniy** | [Станция 2](devices/station-2.md), [Станция Стрит](devices/station-street.md) |
| **@egorsexy** | [Станция Миди](devices/station-midi.md) |
| **@guccimemer** | [Умный хаб](devices/yandex-hub.md) |
| **@ilyaleet**, **@rnsdr** | [Станция Макс](devices/station-max.md) |
| **[@shaderlaze](https://t.me/shaderlaze)** | [Станция 3](devices/station-3.md) |

## Сопровождение

[@Marker284](https://github.com/Marker284), Random_TNT.
