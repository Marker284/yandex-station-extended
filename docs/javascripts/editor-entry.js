/* Вход в веб-редактор со страниц вики: плашка при выделении текста, «Сообщить об ошибке»
   и обход instant-навигации для ссылок на /edit/. Работает, только если в mkdocs.yml задан
   extra.editor.api. Сам редактор — editor/web (собирается в assets/editor/). */
(function () {
  var api = document.querySelector('meta[name="yse-editor-api"]');
  if (!api || !api.content) return;
  var repo = (document.querySelector('meta[name="yse-editor-repo"]') || {}).content || '';

  function card() {
    return document.querySelector('.yse-suggest[data-yse-path]');
  }

  // ---- кнопка «Создать статью» в шапке сайта
  function editorUrl() {
    var m = document.querySelector('meta[name="yse-editor-url"]');
    return m && m.content ? new URL(m.content, location.href).href : '';
  }

  function addHeaderButton() {
    var header = document.querySelector('.md-header__inner');
    if (!header) return;
    var url = editorUrl();
    if (!url) return;
    var link = header.querySelector('.yse-new');
    if (!link) {
      link = document.createElement('a');
      link.className = 'md-header__button yse-new';
      link.title = 'Написать новую статью вики';
      link.setAttribute('data-yse-edit', '');
      link.innerHTML =
        '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 5v14"/><path d="M5 12h14"/></svg>' +
        '<span class="yse-new__label">Создать статью</span>';
      var source = header.querySelector('.md-header__source');
      if (source) header.insertBefore(link, source);
      else header.appendChild(link);
    }
    link.href = url + '?new=1';
  }

  addHeaderButton();

  // ---- ссылки на редактор открываем полной загрузкой (instant-навигация его не запустит)
  document.addEventListener(
    'click',
    function (e) {
      var a = e.target.closest && e.target.closest('a[data-yse-edit]');
      if (!a || e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey) return;
      e.preventDefault();
      e.stopImmediatePropagation();
      location.href = a.href;
    },
    true,
  );

  // Если редактор открыли instant-навигацией (например, «назад»), его скрипт не
  // выполнится — перезагружаем страницу. Но ровно один раз за вкладку: если сборка
  // редактора не отдаётся (например, идёт выкладка сайта), бесконечные перезагрузки
  // показывали бы вечный спиннер вместо подсказки «что-то долго».
  if (window.document$ && window.document$.subscribe) {
    window.document$.subscribe(function () {
      addHeaderButton(); // instant-навигация меняет содержимое, шапка остаётся
      var el = document.getElementById('yse-editor');
      var booted = !el || el.hasAttribute('data-booted') || window.__yseEditorBooted;
      try {
        if (booted) return sessionStorage.removeItem('yse-editor-retry');
        if (sessionStorage.getItem('yse-editor-retry')) return;
        sessionStorage.setItem('yse-editor-retry', '1');
      } catch (e) {
        if (booted) return;
      }
      location.reload();
    });
  }

  // ---- «Сообщить об ошибке» — issue на GitHub с адресом страницы и цитатой
  function reportUrl(quote) {
    var c = card();
    var title = (c && c.getAttribute('data-yse-title')) || document.title;
    var body =
      '**Страница:** ' + location.href.split('#')[0] + '\n' +
      (quote ? '**Фрагмент:**\n\n> ' + quote.replace(/\n+/g, '\n> ') + '\n' : '') +
      '\n**Модель и прошивка:**\n\n### Что не так\n\n';
    return (
      'https://github.com/' + repo + '/issues/new?labels=bug' +
      '&title=' + encodeURIComponent(title + ': ') +
      '&body=' + encodeURIComponent(body)
    );
  }

  document.addEventListener('click', function (e) {
    var a = e.target.closest && e.target.closest('[data-yse-report]');
    if (!a) return;
    e.preventDefault();
    window.open(reportUrl(a.getAttribute('data-quote') || ''), '_blank', 'noopener');
  });

  // ---- плашка над выделенным текстом
  var bubble = null;
  var quote = '';

  function hide() {
    if (bubble) bubble.hidden = true;
  }

  function run(what) {
    var c = card();
    if (!c) return;
    if (what === 'edit') {
      location.href =
        c.getAttribute('data-yse-edit-url') +
        '?path=' + encodeURIComponent(c.getAttribute('data-yse-path')) +
        '&quote=' + encodeURIComponent(quote.slice(0, 300));
    } else {
      window.open(reportUrl(quote), '_blank', 'noopener');
    }
    hide();
  }

  function ensureBubble() {
    if (bubble) return bubble;
    bubble = document.createElement('div');
    bubble.className = 'yse-bubble';
    bubble.hidden = true;
    bubble.innerHTML =
      '<a href="#" class="yse-bubble__edit" data-yse-bubble="edit">' +
      '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4Z"/></svg>' +
      'Предложить правку</a>' +
      '<a href="#" data-yse-bubble="report">' +
      '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 15s1-1 4-1 5 2 8 2 4-1 4-1V3s-1 1-4 1-5-2-8-2-4 1-4 1z"/><path d="M4 22v-7"/></svg>' +
      'Ошибка</a>';
    // Действие — на mousedown, а не на click: при нажатии браузер успевает снять
    // выделение, плашка прячется, и до click дело не доходит — кнопка «срабатывала
    // через раз». Цитата к этому моменту уже сохранена в quote.
    bubble.addEventListener('mousedown', function (e) {
      e.preventDefault();
      var a = e.target.closest('[data-yse-bubble]');
      if (a) {
        e.stopPropagation();
        run(a.getAttribute('data-yse-bubble'));
      }
    });

    // мышь отработала выше; это — для клавиатуры (Enter на выбранной ссылке)
    bubble.addEventListener('click', function (e) {
      var a = e.target.closest('[data-yse-bubble]');
      if (!a) return;
      e.preventDefault();
      if (e.detail === 0) run(a.getAttribute('data-yse-bubble'));
    });
    document.body.appendChild(bubble);
    return bubble;
  }

  function onSelect() {
    var sel = window.getSelection();
    var c = card();
    if (!c || !sel || sel.isCollapsed || !sel.rangeCount) return hide();
    var text = sel.toString().trim();
    var article = c.closest('article') || document.querySelector('.md-content__inner');
    var range = sel.getRangeAt(0);
    if (text.length < 3 || !article || !article.contains(range.commonAncestorContainer) || c.contains(range.commonAncestorContainer)) {
      return hide();
    }
    quote = text;
    var rect = range.getBoundingClientRect();
    var b = ensureBubble();
    b.hidden = false;
    var top = rect.top + window.scrollY - b.offsetHeight - 10;
    if (top < window.scrollY + 60) top = rect.bottom + window.scrollY + 10;
    var left = rect.left + window.scrollX + rect.width / 2 - b.offsetWidth / 2;
    left = Math.max(8, Math.min(left, document.documentElement.clientWidth - b.offsetWidth - 8));
    b.style.top = top + 'px';
    b.style.left = left + 'px';
  }

  document.addEventListener('mouseup', function () { setTimeout(onSelect, 0); });
  document.addEventListener('keyup', function (e) { if (e.shiftKey) onSelect(); });
  document.addEventListener('selectionchange', function () {
    var sel = window.getSelection();
    if (!sel || sel.isCollapsed) hide();
  });
  window.addEventListener('scroll', function () { if (bubble && !bubble.hidden) onSelect(); }, { passive: true });
})();
