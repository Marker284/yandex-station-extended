<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>LED-паттерны для Yandex Station Mini 2 — инструкция</title>
<style>
  :root {
    --bg: #14151a;
    --card: #1e2028;
    --text: #e8e8ee;
    --muted: #a0a4b0;
    --accent: #ffe600;
    --accent2: #744dff;
    --border: #33363f;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    font-family: "Segoe UI", Arial, sans-serif;
    background: var(--bg);
    color: var(--text);
    line-height: 1.6;
  }
  .wrap { max-width: 860px; margin: 0 auto; padding: 32px 20px 64px; }
  header {
    border-bottom: 3px solid;
    border-image: linear-gradient(90deg, var(--accent), var(--accent2)) 1;
    padding-bottom: 20px;
    margin-bottom: 28px;
  }
  h1 { margin: 0 0 8px; font-size: 1.9em; line-height: 1.25; }
  .subtitle { color: var(--muted); margin: 0; }
  h2 {
    font-size: 1.3em;
    margin: 36px 0 12px;
    padding-left: 12px;
    border-left: 4px solid var(--accent);
  }
  section {
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 20px 24px;
    margin-bottom: 16px;
  }
  ol, ul { padding-left: 24px; }
  li { margin: 8px 0; }
  code, .mono {
    font-family: Consolas, "Courier New", monospace;
    background: #12131a;
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 2px 7px;
    font-size: 0.92em;
  }
  pre {
    background: #12131a;
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 12px 16px;
    overflow-x: auto;
  }
  pre code { background: none; border: none; padding: 0; }
  .note {
    border-left: 4px solid var(--accent2);
    background: rgba(116, 77, 255, 0.08);
    border-radius: 0 8px 8px 0;
    padding: 10px 14px;
    margin: 14px 0;
    font-size: 0.95em;
  }
  .warn {
    border-left: 4px solid #ff8800;
    background: rgba(255, 136, 0, 0.08);
    border-radius: 0 8px 8px 0;
    padding: 10px 14px;
    margin: 14px 0;
    font-size: 0.95em;
  }
  .step-num {
    display: inline-block;
    width: 26px; height: 26px;
    background: var(--accent);
    color: #14151a;
    border-radius: 50%;
    text-align: center;
    font-weight: 700;
    margin-right: 8px;
  }
  table { border-collapse: collapse; width: 100%; margin: 10px 0; }
  th, td { border: 1px solid var(--border); padding: 8px 12px; text-align: left; }
  th { background: #12131a; }
  footer { color: var(--muted); font-size: 0.85em; margin-top: 40px; text-align: center; }
</style>
</head>
<body>
<div class="wrap">

<header>
  <h1>Свои цвета подсветки на Yandex Station Mini 2</h1>
  <p class="subtitle">led_gen_gui.py — редактор LED-паттернов и генератор установщика</p>
  <a href="https://github.com/artemon0103/led_gen_gui/tree/main">Download!</a>
</header>

<section>
  <h1>Важно</h1>
  <p>
    Программа базируется на коде: "Marker284".
  </p>
  <h2>Для чего нужно</h2>
  <p>
    Программа позволяет перекрасить кольцевую подсветку Яндекс Станции Мини 2
    в свои цвета: отдельно для режимов «Слушает», «Говорит» и «Думает».
    Вместо стандартной розовой подстветки станция будет светить, например, белым,
    жёлтым или любым другим цветом — с сохранением родной анимации
    (пульсации при разговоре и «вращающегося луча» в режиме размышления).
  </p>
  <ul>
    <li>Настройка цвета для каждого действия и отдельных зон кольца;</li>
    <li>живой предпросмотр анимации поверх фотографии панели;</li>
    <li>ручное редактирование кадров, яркости и скорости;</li>
    <li>генерация готового установщика либо установка напрямую по SSH.</li>
  </ul>
</section>

<section>
  <h2>Что понадобится</h2>
  <table>
    <tr><th>Что</th><th>Зачем</th></tr>
    <tr><td>Python 3.8+ (для Windows)</td><td>запуск программы; tkinter входит в стандартную установку</td></tr>
    <tr><td>Pillow — <code>pip install pillow</code></td><td>предпросмотр поверх фото панели (необязательно)</td></tr>
    <tr><td>paramiko — <code>pip install paramiko</code></td><td>подключение к колонке по SSH с паролем (необязательно)</td></tr>
    <tr><td>SSH-доступ к колонке (root)</td><td>установка паттернов; SSH уже должен быть включён на устройстве</td></tr>
    <tr><td>Фото верхней панели</td><td>для фото-предпросмотра; сохранить как <code>station_top.png</code> рядом со скриптом</td></tr>
  </table>
  <div class="warn">
    Изменяются системные файлы устройства. OTA-обновление может перезаписать
    паттерны — установку придётся повторить. Программа автоматически делает
    бэкап стоковых паттернов перед установкой — сохраните путь из журнала,
    он нужен для отката.
  </div>
</section>

<section>
  <h2>Шаги</h2>

  <p><span class="step-num">1</span><strong>Установите зависимости.</strong>
    Откройте командную строку и выполните:</p>
  <pre><code>pip install pillow paramiko</code></pre>
  <p>Python и tkinter уже должны быть установлены.</p>

  <p><span class="step-num">2</span><strong>Подготовьте файл программы.</strong>
    Сохраните код как <code>led_gen_gui.py</code> и вставьте три base64-блока
    стоковых паттернов из оригинального скрипта в константу
    <code>ORIGINAL_PAYLOADS</code> (поля <code>listening</code>,
    <code>speaking</code>, <code>thinking</code>).</p>

  <p><span class="step-num">3</span><strong>Запустите программу.</strong></p>
  <pre><code>python led_gen_gui.py</code></pre>
  <p>Откроется окно с редактором паттернов.</p>

  <p><span class="step-num">4</span><strong>Настройте цвета в «Создателе кадров».</strong>
    Задайте цвет для каждого действия (HEX или через палитру),
    при желании — цвета отдельных зон в таблице ниже. Нажмите
    «Создать кадры» — анимации пересоберутся в выбранные цвета.</p>

  <p><span class="step-num">5</span><strong>При необходимости — тонкая настройка.</strong>
    В «Редакторе кадров» можно поправить отдельные кадры и зоны,
    в «Общих настройках» — яркость и скорость анимации.
    Предпросмотр покажет, как это будет выглядеть.</p>

  <p><span class="step-num">6</span><strong>Установите паттерны.</strong>
    Два способа на выбор:</p>
  <ul>
    <li><strong>Через скрипт:</strong> нажмите «Сгенерировать установщик (.sh)…»,
      затем запустите его с компьютера, где настроен SSH к колонке(и чтобы ssh колонки был на порту 22):
      <pre><code>sh install_led.sh <ip колонки></code></pre></li>
    <li><strong>Без скрипта:</strong> в разделе «Без скрипта» введите IP колонки,
      порт (обычно 22), пользователя <code>root</code> и пароль,
      нажмите «Проверить подключение», затем «Установить паттерны».</li>
  </ul>
  <p>После установки программа сама перезапустит Quasar — подсветка
    сменится сразу.</p>

  <p><span class="step-num">7</span><strong>Сохраните путь бэкапа.</strong>
    Путь к каталогу со стоковыми паттернами появится в журнале
    (вида <code>/data/quasar/rgb-alice-backup-…</code>). Чтобы вернуть
    стандартную подсветку, нажмите «Скрипт восстановления…» или кнопку
    «Восстановить из бэкапа…» и укажите этот путь.</p>
</section>

<div class="note">
  Если «Проверить подключение» не проходит: убедитесь, что SSH на колонке
  включён и доступен root, IP верный и устройства в одной сети. Без paramiko
  пароль ssh спросит в консоли, откуда запущен Python.
</div>

<footer>Инструкция к led_gen_gui.py — редактору LED-паттернов Yandex Station Mini 2</footer>

</div>
</body>
</html>
