# Подсветка (LED)

Как управлять подсветкой зависит от модели:

| Модель | Как устроено | Где описано |
|---|---|---|
| Лайт | 3 RGB-зоны кольца через sysfs | ниже |
| Лайт 2 / Plum | 3 RGB-зоны через sysfs; штатный trigger `led_ring_fb` | [временное управление](#plum-led) |
| Мини 2 | 6 RGB-зон + LED-часы через sysfs | [`contrib/install-rgb-alice-mini2.sh`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/install-rgb-alice-mini2.sh), [страница модели](../devices/station-mini2.md) |
| Станция 2 | панель из 88 светодиодов через framebuffer `/dev/fb0` (`89×1`) | [страница модели](../devices/station-2.md#led) |
| Мини 3 | кольцо через framebuffer `/dev/fb0` | [страница модели](../devices/station-mini3.md), [`contrib/ring.sh`](https://github.com/Marker284/yandex-station-extended/blob/main/contrib/ring.sh) |

## Станция Лайт: sysfs

Зоны — `/sys/class/leds/micro:{red,green,blue}:ring{1,2,3}`, яркость 0–255:

```sh
ls /sys/class/leds/
echo 255 > /sys/class/leds/micro:red:ring1/brightness    # зона 1 — красный
echo 0   > /sys/class/leds/micro:red:ring1/brightness    # погасить
```

## Лайт 2 / Plum: временное управление { #plum-led }

Проверено на **YNDX-00028 / Plum**, прошивка
`0.369.1.50.4794654278.20261021.133`. Пути зон:
`/sys/class/leds/plum:{red,green,blue}:ring{1,2,3}`.
Это девять отдельных атрибутов яркости 0–255, сгруппированных в три RGB-зоны.

Для краткой индикации через уже настроенный SSH-псевдоним `alice`:

1. Закройте чат и остановите GPT-мост, если он работает, чтобы два обработчика
   не управляли одними LED одновременно.
2. Клонируйте [Alisa-ChatGPT-voice-assistant][led-project] на ПК. В каталоге проекта
   передайте проверенный [station/indicator.sh][plum-indicator] на колонку:

    ```sh
    ssh alice 'mkdir -p /data/opt/alice-led'
    ssh alice 'umask 077; cat > /data/opt/alice-led/indicator.sh' < station/indicator.sh
    ```

3. Подайте синий кадр на одну секунду и освободите кольцо:

    ```sh
    {
        printf 'B\n'
        sleep 1
        printf '0\n'
    } | ssh alice 'sh /data/opt/alice-led/indicator.sh'
    ```

Обработчик рассчитан на BusyBox `sh` проверенной Plum и использует `read -t`.
Нужен читаемый `/sys/kernel/debug/gpio` с меткой `mute-switch`.
При неизвестном состоянии кнопки или отключённых микрофонах обработчик не удерживает LED.

### Команды и возврат анимаций { #plum-led-ownership }

| Строка на stdin обработчика | Действие |
|---|---|
| `B` | синий кадр: 0, 0, 160 в каждой зоне |
| `F r1 g1 b1 r2 g2 b2 r3 g3 b3` | кадр из девяти целых значений 0–255 |
| `F 0 0 0 0 0 0 0 0 0` | погасить, продолжая удерживать управление |
| `0` | освободить LED и вернуть сохранённые триггеры |
| EOF или отсутствие команды 2 секунды | завершиться с освобождением LED |

При захвате сохраняются значения яркости и **активный trigger каждого цвета**,
затем триггеры отключаются. При освобождении обработчик возвращает сохранённое
состояние, учитывая появление другого владельца.

На этой Plum простой возврат яркости недостаточен: запись нуля может отключить
LED-trigger. Если оставить `none`, штатная анимация Алисы продолжает формироваться,
но на кольце её не видно. Поэтому последней операцией возвращается прежний trigger,
обычно `led_ring_fb`, а не только цвет.

Штатная красная индикация имеет приоритет: обработчик читает состояние `mute-switch`
и освобождает LED при mute или неизвестном значении. Переходы hi/lo/unknown проверены
на тестовых файлах; физическое нажатие кнопки в этом испытании не проверялось.

### Радуга в голосовом режиме { #plum-led-rainbow }

В [GPT-мосте](llm.md#chatgpt-web) контроллер [indicator.py][rainbow-controller]
формирует кадры до 10 раз/с: три оттенка со сдвигом на 120°, оборот за 6 секунд,
плавная пульсация с периодом 2 секунды, яркость не выше 160/255.
Радуга включается во время ответа GPT; в паузах режима кольцо удерживается погашенным,
после выхода возвращается штатное управление. `ALICE_LED_STYLE=blue` выбирает синий стиль.

На устройстве проверены 30 цветовых кадров, подавление штатной анимации во время
удержания LED и её возврат после освобождения. Проверка запускала голосовой ввод
через IPC, а не акустическое произнесение слова «Алиса».
Тесты EOF, тайм-аута, повторных циклов и нового владельца —
[tests/test_voice_controls.py][led-tests].

Для удаления отдельного демонстрационного обработчика завершите его и выполните:

```sh
ssh alice 'rm /data/opt/alice-led/indicator.sh && rmdir /data/opt/alice-led'
```

Системные файлы и автозапуск этот пример не меняет.

[led-project]: https://github.com/rison1337/Alisa-ChatGPT-voice-assistant
[plum-indicator]: https://github.com/rison1337/Alisa-ChatGPT-voice-assistant/blob/972e637/station/indicator.sh
[rainbow-controller]: https://github.com/rison1337/Alisa-ChatGPT-voice-assistant/blob/972e637/indicator.py
[led-tests]: https://github.com/rison1337/Alisa-ChatGPT-voice-assistant/blob/972e637/tests/test_voice_controls.py

## Анимации прошивки: формат `.led`

Анимации лежат в `/system/vendor/quasar/ledpatterns/*.led` (на Лайт — 33 штуки:
`alice_listening`, `alice_speaking`, `timer`, `volume`, `bluetooth_*`, `error` …).
Формат текстовый:

```text
gammacorrection          # применять гамма-коррекцию
loop                     # зациклить
1D761D  1D761D  1D761D   1000   # цвет зон ring1 ring2 ring3 и длительность кадра, мс
2D8624  2D8624  2D8624   1000
```

Подробнее — на [странице Лайт](../devices/station-lite.md#led-format).
