# SoundCloud на Станции 1

Самостоятельный установщик `install.sh` для root-терминала AliceBridge.
Голос берётся из локального IPC Алисы; HDMI, специальные возможности и READ_LOGS не нужны.
ТВ-набор, AirPlay и скрипт метрик для него не нужны. Устанавливает NewPipe,
голосовой мост и v2rayNG. Действующий VPN-ключ предоставляет пользователь.

Исходники: `soundcloud/`, `src/VlessLink.java`; сборка: `build.py`.
JDK 17, Android SDK 23 или новее + build-tools с aapt2/zipalign/apksigner, R8/D8.
Задайте JAVA_HOME, ANDROID_SDK_ROOT и при необходимости STATION_R8_JAR.

NewPipe 0.29.1 распространяется под GPL-3.0-or-later, см. COPYING.NewPipe.
Исходная версия: https://github.com/TeamNewPipe/NewPipe/tree/v0.29.1
Точное изменение анимации: soundcloud/NewPipe-station1.patch.
Дополнительные компоненты фонового плеера: soundcloud/newpipe/*.java.
Регистрация компонентов: soundcloud/manifest_patch.py; бинарная правка
закреплённого APK: soundcloud/newpipe_patch.py. Доступ к приёмнику команд
защищён разрешением signature: оба APK подписываются одним локальным ключом.
Обработка HTTPS и разрешения сети NewPipe не меняются.

Ключ подписи создаётся локально вне репозитория, не публикуйте его и его пароль.
При смене ключа обновление APK через pm install -r перестанет проходить.
