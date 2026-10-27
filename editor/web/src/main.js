// Веб-редактор вики hackalice.me.
// Экраны: вход через GitHub → редактор (исходник + превью) → отправка → PR создан.

import { Api, ApiError } from './api.js';
import { h, clear, icon, spinner, formatTime, plural, store } from './dom.js';
import { createEditor, commands, setDoc, setLineMarks, revealQuote, gotoLine, topVisibleLine, insertBlock } from './cm.js';
import { renderInto, elementForLine } from './preview.js';
import { lineStats, rebase } from './diff.js';
import { scanChange, hasBlocking } from '../../shared/scan.js';
import {
  IMAGES_DIR,
  IMAGE_TYPES,
  MAX_IMAGE_BYTES,
  imageFileName,
  isValidPagePath,
  pageUrlPath,
  relativeLink,
  slugify,
} from '../../shared/paths.js';
import './editor.css';

const root = document.getElementById('yse-editor');
root.setAttribute('data-booted', '');
window.__yseEditorBooted = true;

// Горячие клавиши Material (s, f, / — поиск; n, p, «.» — соседние страницы) не должны
// срабатывать, пока человек печатает в редакторе или в окнах редактора.
root.addEventListener('keydown', (e) => e.stopPropagation());
root.addEventListener('keyup', (e) => e.stopPropagation());

const cfg = {
  api: root.dataset.api,
  repo: root.dataset.repo,
  repoUrl: root.dataset.repoUrl,
  siteRoot: new URL(root.dataset.siteRoot || '/', location.href).href,
  editUri: root.dataset.editUri,
};
const params = new URLSearchParams(location.search);
const api = cfg.api ? new Api(cfg.api) : null;

/** Состояние открытой правки. */
const S = {
  path: null,
  isNew: false,
  newPage: null, // { section, dir, title }
  original: '', // версия main: от неё считаем «+/−» и проверяем только свои строки
  baseSha: null, // sha файла, от которого начата правка (для проверки конфликта)
  pr: null, // { number, url, title } — дорабатываем свой PR
  images: new Map(), // repoPath → { name, base64, url, size }
  view: null,
  editor: null,
  preview: null,
  findings: [],
  stats: { added: 0, removed: 0, changedLines: new Set() },
  submitted: false,
  sections: [],
};

const siteUrl = (path) => new URL(path ? pageUrlPath(path) : '', cfg.siteRoot).href;
const githubEditUrl = (path) => (path ? `${cfg.editUri.replace(/\/$/, '')}/${path.replace(/^docs\//, '')}` : cfg.repoUrl);

// ======================================================================
// Общие куски интерфейса

function stepper(current) {
  const steps = ['Правка', 'Отправка', 'Готово'];
  return h(
    'ol',
    { class: 'yse-stepper', 'aria-label': 'Шаги' },
    steps.map((name, i) => {
      const n = i + 1;
      const state = n < current ? 'done' : n === current ? 'current' : 'todo';
      return [
        i > 0 && h('li', { class: `yse-stepper__bar${n <= current ? ' is-done' : ''}`, 'aria-hidden': 'true' }),
        h(
          'li',
          { class: `yse-stepper__step is-${state}`, 'aria-current': state === 'current' ? 'step' : null },
          h('span', { class: 'yse-stepper__dot' }, state === 'done' ? icon('check', 13) : String(n)),
          name,
        ),
      ];
    }),
  );
}

function modal(content, { label, onClose, wide } = {}) {
  const overlay = h('div', { class: 'yse-overlay', role: 'presentation' });
  const dialog = h('div', { class: `yse-dialog${wide ? ' yse-dialog--wide' : ''}`, role: 'dialog', 'aria-modal': 'true', 'aria-label': label }, content);
  overlay.append(dialog);
  const onKey = (e) => {
    if (e.key === 'Escape' && onClose) close();
  };
  function close() {
    document.removeEventListener('keydown', onKey);
    overlay.remove();
    onClose?.();
  }
  document.addEventListener('keydown', onKey);
  root.append(overlay);
  requestAnimationFrame(() => dialog.querySelector('[autofocus], input, textarea, button')?.focus());
  return { overlay, dialog, close, remove: () => (document.removeEventListener('keydown', onKey), overlay.remove()) };
}

function checkItem(text) {
  return h('li', { class: 'yse-checklist__item' }, h('span', { class: 'yse-check yse-check--ok' }, icon('check', 13)), h('span', null, text));
}

function message(kind, ...children) {
  return h('div', { class: `yse-msg yse-msg--${kind}`, role: kind === 'danger' ? 'alert' : 'status' }, icon(kind === 'ok' ? 'check' : kind === 'info' ? 'alert' : 'warning', 18), h('div', { class: 'yse-msg__body' }, children));
}

function fatal(title, text, actions = []) {
  clear(
    root,
    h(
      'div',
      { class: 'yse-center' },
      h('div', { class: 'yse-card yse-card--narrow' }, h('div', { class: 'yse-card__icon yse-card__icon--warn' }, icon('alert', 24)), h('h1', null, title), h('p', { class: 'yse-muted' }, text), h('div', { class: 'yse-actions' }, actions)),
    ),
  );
}

// ======================================================================
// Вход

function signInScreen(onDone, error) {
  // фон — «скелет» страницы, как в макете
  clear(
    root,
    h(
      'div',
      { class: 'yse-skeleton', 'aria-hidden': 'true' },
      h('div', { class: 'yse-skeleton__bar', style: 'width: 40%; height: 28px' }),
      h('div', { class: 'yse-skeleton__bar', style: 'width: 70%' }),
      h('div', { class: 'yse-skeleton__bar', style: 'width: 62%' }),
      h('div', { class: 'yse-skeleton__bar', style: 'width: 66%' }),
      h('div', { class: 'yse-skeleton__bar', style: 'width: 70%; height: 56px' }),
    ),
  );
  const err = h('div', { class: 'yse-login__error' }, error ? message('danger', `Вход не выполнен: ${error}`) : null);
  const btn = h('button', { type: 'button', class: 'yse-btn yse-btn--dark yse-btn--block yse-btn--lg' }, icon('user'), 'Продолжить через GitHub');
  const back = params.get('path') && isValidPagePath(params.get('path')) ? siteUrl(params.get('path')) : cfg.siteRoot;
  const m = modal(
    [
      h('div', { class: 'yse-card__icon' }, icon('lock', 24)),
      h('h1', { class: 'yse-dialog__title' }, 'Войдите, чтобы предложить правку'),
      h('p', { class: 'yse-muted' }, 'Правка уйдёт мейнтейнерам как Pull Request от вашего имени.'),
      h(
        'ul',
        { class: 'yse-checklist' },
        checkItem('Права на репозиторий не нужны: сайт сам сделает форк и ветку.'),
        checkItem('GitHub попросит доступ к публичным репозиториям. Токен не хранится в браузере в открытом виде: сервер редактора шифрует его и использует только для правок этой вики.'),
        checkItem('Вы остаётесь автором: ник попадёт в историю Git и в список участников вики.'),
      ),
      err,
      btn,
      h('a', { class: 'yse-link-muted', href: back }, 'Отмена'),
    ],
    { label: 'Вход через GitHub' },
  );
  btn.addEventListener('click', async () => {
    btn.disabled = true;
    clear(btn, spinner(), 'Ждём подтверждения в окне GitHub…');
    try {
      await api.login();
      m.remove();
      onDone();
    } catch (e) {
      btn.disabled = false;
      clear(btn, icon('user'), 'Продолжить через GitHub');
      if (e.message !== 'closed') clear(err, message('danger', `Вход не выполнен: ${e.message}`));
    }
  });
}

/** Если сессия истекла посреди работы — вход поверх редактора, текст не теряется. */
function reauth() {
  return new Promise((resolve) => {
    const btn = h('button', { type: 'button', class: 'yse-btn yse-btn--dark yse-btn--block yse-btn--lg' }, icon('user'), 'Войти снова');
    const m = modal(
      [
        h('div', { class: 'yse-card__icon' }, icon('lock', 24)),
        h('h1', { class: 'yse-dialog__title' }, 'Сессия истекла'),
        h('p', { class: 'yse-muted' }, 'Войдите через GitHub ещё раз — ваш текст и картинки на месте.'),
        btn,
      ],
      { label: 'Повторный вход', onClose: () => resolve(false) },
    );
    btn.addEventListener('click', async () => {
      btn.disabled = true;
      try {
        await api.login();
        m.remove();
        renderUser();
        resolve(true);
      } catch {
        btn.disabled = false;
      }
    });
  });
}

// ======================================================================
// Новая страница

const NEW_DRAFT = 'yse-draft:new';

function pageTemplate(title) {
  return `# ${title}

Коротко: что это и для каких моделей проверено.

## Что понадобится

- колонка с root ([шаг 1](../start/root.md))
-

## Шаги

1.

!!! warning "Только свои устройства"
    Не публикуйте ключи из \`devices.json\`, MAC-адреса, серийные номера и токены.
`;
}

async function newPageScreen() {
  clear(root, h('div', { class: 'yse-center' }, h('div', { class: 'yse-boot' }, h('div', { class: 'yse-spinner' }), h('p', null, 'Загружаем разделы…'))));
  const { sections } = await api.sections();
  S.sections = sections;
  clear(root);
  const draft = store.get(NEW_DRAFT);
  const wantDir = params.get('dir');
  const sectionSel = h(
    'select',
    { id: 'np-section', class: 'yse-input' },
    sections.map((s) => h('option', { value: s.title, selected: s.dir === wantDir || null }, s.title)),
  );
  const title = h('input', { id: 'np-title', class: 'yse-input', type: 'text', placeholder: 'Например: Своя прошивка звуков', maxlength: '80', autofocus: true });
  const slug = h('input', { id: 'np-slug', class: 'yse-input yse-input--mono', type: 'text', placeholder: 'adres-stranitsy', pattern: '[a-z0-9][a-z0-9-]*', maxlength: '60' });
  const urlPreview = h('div', { class: 'yse-hint yse-mono' });
  const err = h('div');
  let slugTouched = false;
  const dirOf = () => sections.find((s) => s.title === sectionSel.value)?.dir;
  const update = () => {
    if (!slugTouched) slug.value = slugify(title.value);
    urlPreview.textContent = `${new URL(`${dirOf()}/${slug.value || '…'}/`, cfg.siteRoot).href}`;
  };
  title.addEventListener('input', update);
  slug.addEventListener('input', () => {
    slugTouched = true;
    slug.value = slug.value.toLowerCase().replace(/[^a-z0-9-]/g, '-');
    update();
  });
  sectionSel.addEventListener('change', update);
  update();

  const create = h('button', { type: 'submit', class: 'yse-btn yse-btn--primary yse-btn--lg' }, icon('plus'), 'Создать страницу');
  const form = h(
    'form',
    { class: 'yse-form', novalidate: true },
    h('div', { class: 'yse-card__icon' }, icon('file', 24)),
    h('h1', { class: 'yse-dialog__title' }, 'Новая страница'),
    h('p', { class: 'yse-muted' }, 'Страница появится в меню выбранного раздела, когда мейнтейнер примет правку.'),
    draft &&
      h(
        'div',
        { class: 'yse-msg yse-msg--info' },
        icon('clock', 18),
        h(
          'div',
          { class: 'yse-msg__body' },
          `Есть черновик «${draft.title}» от ${formatTime(draft.savedAt)}. `,
          h('button', { type: 'button', class: 'yse-linkbtn', onClick: () => (m.remove(), openNewPage(draft)) }, 'Продолжить его'),
        ),
      ),
    h('label', { class: 'yse-label', for: 'np-section' }, 'Раздел'),
    sectionSel,
    h('label', { class: 'yse-label', for: 'np-title' }, 'Заголовок'),
    title,
    h('label', { class: 'yse-label', for: 'np-slug' }, 'Адрес (латиницей)'),
    slug,
    urlPreview,
    err,
    h('div', { class: 'yse-actions yse-actions--split' }, h('a', { class: 'yse-btn yse-btn--ghost', href: cfg.siteRoot }, 'Отмена'), create),
  );
  const m = modal(form, { label: 'Новая страница' });
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const t = title.value.trim();
    const dir = dirOf();
    const path = `docs/${dir}/${slug.value}.md`;
    if (!t) return clear(err, message('danger', 'Введите заголовок.'));
    if (!slug.value || !isValidPagePath(path)) return clear(err, message('danger', 'Адрес — латиница, цифры и дефисы.'));
    create.disabled = true;
    clear(create, spinner(), 'Проверяем адрес…');
    try {
      const f = await api.file(path);
      if (f.exists) {
        create.disabled = false;
        clear(create, icon('plus'), 'Создать страницу');
        return clear(err, message('danger', 'Такая страница уже есть. ', h('a', { href: `?path=${encodeURIComponent(path)}` }, 'Открыть её в редакторе')));
      }
      m.remove();
      openNewPage({ path, section: sectionSel.value, dir, title: t, content: pageTemplate(t) });
    } catch (ex) {
      create.disabled = false;
      clear(create, icon('plus'), 'Создать страницу');
      clear(err, message('danger', ex.message));
    }
  });
}

function openNewPage(d) {
  S.path = d.path;
  S.isNew = true;
  S.newPage = { section: d.section, dir: d.dir, title: d.title };
  S.original = '';
  S.baseSha = null;
  history.replaceState(null, '', `?new=1&dir=${encodeURIComponent(d.dir)}`);
  editorScreen(d.content);
}

// ======================================================================
// Черновики

const draftKey = () => (S.isNew ? NEW_DRAFT : `yse-draft:${S.pr ? `pr${S.pr.number}` : 'main'}:${S.path}`);

function saveDraft(content) {
  const d = S.isNew
    ? { path: S.path, section: S.newPage.section, dir: S.newPage.dir, title: S.newPage.title, content, savedAt: Date.now() }
    : { content, original: S.original, baseSha: S.baseSha, savedAt: Date.now() };
  const ok = store.set(draftKey(), d);
  const el = root.querySelector('.yse-draft-status');
  if (el) {
    clear(el, ok ? icon('check', 15) : icon('warning', 15), ok ? `Черновик сохранён в браузере · ${formatTime(d.savedAt)}` : 'Браузер не даёт сохранить черновик');
    el.classList.toggle('is-warn', !ok);
  }
}

// ======================================================================
// Загрузка страницы

async function openExisting(path, prNumber) {
  clear(root, h('div', { class: 'yse-center' }, h('div', { class: 'yse-boot' }, h('div', { class: 'yse-spinner' }), h('p', null, 'Загружаем страницу…'))));
  const f = await api.file(path, prNumber);
  if (!f.exists && !prNumber) {
    return fatal('Страница не найдена', `Файла ${path} нет в репозитории — возможно, его переименовали.`, [
      h('a', { class: 'yse-btn yse-btn--primary', href: cfg.siteRoot }, 'На главную'),
      h('a', { class: 'yse-btn', href: '?new=1' }, 'Создать новую страницу'),
    ]);
  }
  S.path = path;
  S.isNew = false;
  S.pr = f.pr || null;
  S.original = f.original;
  S.baseSha = f.sha;
  editorScreen(f.content);

  // черновик
  const d = store.get(draftKey());
  if (d && d.content !== f.content) {
    if (d.baseSha === f.sha) {
      setDoc(S.editor, d.content);
      banner('info', [`Восстановлен ваш черновик от ${formatTime(d.savedAt)}. `, h('button', { type: 'button', class: 'yse-linkbtn', onClick: (e) => (setDoc(S.editor, f.content), store.del(draftKey()), e.target.closest('.yse-msg').remove()) }, 'Начать заново')]);
    } else {
      const merged = rebase(d.original, d.content, f.content);
      if (merged != null) {
        setDoc(S.editor, merged);
        banner('info', [`Восстановлен черновик от ${formatTime(d.savedAt)} и перенесён на свежую версию страницы. `, h('button', { type: 'button', class: 'yse-linkbtn', onClick: (e) => (setDoc(S.editor, f.content), store.del(draftKey()), e.target.closest('.yse-msg').remove()) }, 'Начать заново')]);
      } else {
        banner('warn', [`Есть черновик от ${formatTime(d.savedAt)}, но страницу с тех пор изменили и перенести правку автоматически не вышло. `, h('button', { type: 'button', class: 'yse-linkbtn', onClick: () => showMine(d.content) }, 'Показать черновик')]);
      }
    }
  }

  // переход к выделенному на странице фрагменту
  const q = params.get('quote');
  if (q && !revealQuote(S.editor, q)) {
    banner('info', 'Не нашли выделенный фрагмент в исходнике — поищите вручную (Ctrl+F).');
  }

  // уже открытый PR по этой странице
  if (!S.pr) {
    api
      .prs(path)
      .then(({ prs }) => {
        if (!prs.length) return;
        const p = prs[0];
        banner('info', [
          `У вас уже открыт PR #${p.number} «${p.title}» по этой странице. `,
          h('a', { href: `?path=${encodeURIComponent(path)}&pr=${p.number}` }, 'Продолжить в нём'),
          ' или отправить эту правку отдельно.',
        ]);
      })
      .catch(() => {});
  }
}

// ======================================================================
// Редактор

function banner(kind, content) {
  const box = root.querySelector('.yse-banners');
  const el = message(kind === 'warn' ? 'warn' : kind, content);
  el.append(h('button', { type: 'button', class: 'yse-iconbtn yse-msg__close', 'aria-label': 'Закрыть', onClick: () => el.remove() }, icon('x', 16)));
  box?.append(el);
  return el;
}

/** Панель «Ваша версия» — когда правку не удалось перенести автоматически. */
function showMine(text) {
  const box = root.querySelector('.yse-banners');
  root.querySelector('.yse-mine')?.remove();
  const ta = h('textarea', { class: 'yse-input yse-input--mono yse-mine__text', readonly: true, rows: '8', 'aria-label': 'Ваша версия текста' });
  ta.value = text;
  const copy = h('button', { type: 'button', class: 'yse-btn' }, icon('copy', 16), 'Скопировать');
  copy.addEventListener('click', async () => {
    await navigator.clipboard?.writeText(text).catch(() => ta.select());
    clear(copy, icon('check', 16), 'Скопировано');
  });
  box.append(
    h(
      'div',
      { class: 'yse-mine' },
      h('div', { class: 'yse-mine__head' }, h('strong', null, 'Ваша версия'), h('span', { class: 'yse-muted' }, ' — перенесите нужные куски в редактор'), h('div', { class: 'yse-spacer' }), copy, h('button', { type: 'button', class: 'yse-iconbtn', 'aria-label': 'Скрыть', onClick: (e) => e.target.closest('.yse-mine').remove() }, icon('x', 16))),
      ta,
    ),
  );
}

function renderUser() {
  const slot = root.querySelector('.yse-user');
  if (!slot) return;
  const u = api.user;
  if (!u) return clear(slot);
  const menu = h(
    'div',
    { class: 'yse-menu', hidden: true, role: 'menu' },
    h('a', { class: 'yse-menu__item', role: 'menuitem', href: `https://github.com/${u.login}`, target: '_blank', rel: 'noopener' }, icon('external', 16), 'Профиль на GitHub'),
    h(
      'button',
      {
        type: 'button',
        class: 'yse-menu__item',
        role: 'menuitem',
        onClick: async () => {
          await api.logout();
          location.reload();
        },
      },
      icon('logout', 16),
      'Выйти',
    ),
  );
  const btn = h(
    'button',
    { type: 'button', class: 'yse-userbtn', 'aria-haspopup': 'menu', 'aria-expanded': 'false' },
    u.avatar ? h('img', { class: 'yse-avatar', src: `${u.avatar}${u.avatar.includes('?') ? '&' : '?'}s=64`, alt: '' }) : h('span', { class: 'yse-avatar' }, u.login[0]),
    h('span', { class: 'yse-userbtn__name' }, `@${u.login}`),
    icon('chevron', 14),
  );
  btn.addEventListener('click', (e) => {
    e.stopPropagation();
    menu.hidden = !menu.hidden;
    btn.setAttribute('aria-expanded', String(!menu.hidden));
  });
  document.addEventListener('click', () => {
    menu.hidden = true;
    btn.setAttribute('aria-expanded', 'false');
  });
  clear(slot, btn, menu);
}

function toolButton(name, label, run, { text } = {}) {
  return h(
    'button',
    { type: 'button', class: `yse-tool${text ? ' yse-tool--text' : ''}`, title: label, 'aria-label': text ? null : label, onMouseDown: (e) => e.preventDefault(), onClick: () => run(S.editor) },
    icon(name, 17),
    text && h('span', { class: 'yse-tool__label' }, text),
  );
}

const ADMONITIONS = [
  ['note', 'Заметка', 'Заметка'],
  ['tip', 'Совет', 'Совет'],
  ['info', 'Инфо', 'Информация'],
  ['warning', 'Внимание', 'Внимание'],
  ['danger', 'Опасно', 'Опасно'],
  ['failure', 'Если не работает', 'Если не работает', true],
];

function admonitionMenu() {
  const menu = h(
    'div',
    { class: 'yse-menu yse-menu--tool', hidden: true, role: 'menu' },
    ADMONITIONS.map(([type, label, title, collapsible]) =>
      h(
        'button',
        {
          type: 'button',
          role: 'menuitem',
          class: `yse-menu__item yse-adm-item yse-adm-item--${type}`,
          onMouseDown: (e) => e.preventDefault(),
          onClick: () => {
            menu.hidden = true;
            commands.admonition(S.editor, type, title, collapsible);
          },
        },
        h('span', { class: 'yse-adm-dot' }),
        label,
        h('code', null, collapsible ? `??? ${type}` : `!!! ${type}`),
      ),
    ),
  );
  const btn = h('button', { type: 'button', class: 'yse-tool yse-tool--text', title: 'Заметка (admonition)', 'aria-label': 'Заметка', 'aria-haspopup': 'menu', onMouseDown: (e) => e.preventDefault() }, icon('warning', 17), h('span', { class: 'yse-tool__label' }, 'Заметка'), icon('chevron', 13));
  btn.addEventListener('click', (e) => {
    e.stopPropagation();
    menu.hidden = !menu.hidden;
  });
  document.addEventListener('click', () => (menu.hidden = true));
  return h('div', { class: 'yse-tool-wrap' }, btn, menu);
}

function viewSwitch() {
  const opts = [
    ['source', 'Исходник'],
    ['split', 'Рядом'],
    ['preview', 'Превью'],
  ];
  const wrap = h('div', { class: 'yse-seg', role: 'group', 'aria-label': 'Вид' });
  const set = (v) => {
    S.view = v;
    store.set('yse-editor-view', v);
    root.querySelector('.yse-panes')?.setAttribute('data-view', v);
    for (const b of wrap.children) b.setAttribute('aria-pressed', String(b.dataset.v === v));
    if (v !== 'source') updatePreview();
    S.editor?.requestMeasure();
  };
  for (const [v, label] of opts) wrap.append(h('button', { type: 'button', class: 'yse-seg__btn', 'data-v': v, 'aria-pressed': String(S.view === v), onClick: () => set(v) }, label));
  return wrap;
}

let previewTimer = 0;
let analyzeTimer = 0;
let draftTimer = 0;

function updatePreview() {
  if (!S.preview || S.view === 'source') return;
  renderInto(S.preview, S.editor.state.doc.toString(), { pagePath: S.path, siteRoot: cfg.siteRoot, pendingImages: S.images });
  syncPreview();
}

function syncPreview() {
  if (S.view !== 'split') return;
  const pane = S.preview.parentElement;
  const line = topVisibleLine(S.editor);
  const el = elementForLine(S.preview, line);
  if (!el) return (pane.scrollTop = 0);
  pane.scrollTop = el.getBoundingClientRect().top - S.preview.getBoundingClientRect().top - 12;
}

function analyze() {
  const text = S.editor.state.doc.toString();
  S.stats = lineStats(S.original, text);
  S.findings = scanChange(S.original, text);
  const danger = new Set(S.findings.filter((f) => f.severity === 'block').map((f) => f.line));
  S.editor.dispatch({ effects: setLineMarks.of({ changed: S.stats.changedLines, danger }) });
  renderStatus();
}

function renderStatus() {
  const bar = root.querySelector('.yse-statusbar');
  if (!bar) return;
  const { added, removed } = S.stats;
  const files = 1 + S.images.size + (S.isNew ? 1 : 0);
  const blocking = S.findings.filter((f) => f.severity === 'block');
  const warns = S.findings.filter((f) => f.severity === 'warn');
  let scan;
  if (blocking.length) {
    const f = blocking[0];
    scan = h(
      'button',
      { type: 'button', class: 'yse-status-scan is-danger', onClick: () => gotoLine(S.editor, f.line) },
      icon('warning', 15),
      `${f.label} в строке ${f.line}${blocking.length > 1 ? ` и ещё ${blocking.length - 1}` : ''} — уберите перед отправкой`,
    );
  } else if (warns.length) {
    scan = h('button', { type: 'button', class: 'yse-status-scan is-warn', onClick: () => gotoLine(S.editor, warns[0].line) }, icon('warning', 15), `Проверьте строку ${warns[0].line}: похоже на ${warns[0].label}`);
  } else {
    scan = h('span', { class: 'yse-status-scan is-ok' }, icon('shield', 15), 'Ключи и MAC-адреса не найдены');
  }
  clear(
    bar,
    h(
      'span',
      { class: 'yse-status-diff' },
      S.isNew ? h('span', { class: 'is-add' }, 'новая страница') : [h('span', { class: 'is-add' }, `+${added}`), ' ', h('span', { class: 'is-del' }, `−${removed}`)],
      ` · ${files} ${plural(files, 'файл', 'файла', 'файлов')}`,
      S.images.size ? ` (${S.images.size} ${plural(S.images.size, 'картинка', 'картинки', 'картинок')})` : '',
    ),
    scan,
    h('span', { class: 'yse-spacer' }),
    h('span', { class: 'yse-status-hint' }, 'Ctrl+B / I / K · Ctrl+S — черновик · Ctrl+Enter — отправить'),
  );
  const send = root.querySelector('.yse-send');
  if (send) send.disabled = !S.isNew && added === 0 && removed === 0 && S.images.size === 0;
}

// ---- картинки

const pickImage = h('input', { type: 'file', accept: Object.values(IMAGE_TYPES).filter((v, i, a) => a.indexOf(v) === i).join(','), multiple: true, hidden: true });
pickImage.addEventListener('change', () => {
  addImages([...pickImage.files]);
  pickImage.value = '';
});

async function addImages(files) {
  for (const file of files) {
    if (file.size > MAX_IMAGE_BYTES) {
      banner('warn', `«${file.name}» больше 2 МБ — уменьшите картинку и вставьте снова.`);
      continue;
    }
    const ext = (file.type.split('/')[1] || 'png').replace('jpeg', 'jpg');
    if (!(ext in IMAGE_TYPES)) {
      banner('warn', `«${file.name}»: подходят PNG, JPG, WebP и GIF.`);
      continue;
    }
    const pageSlug = S.path.split('/').pop().replace(/\.md$/, '');
    const baseName = imageFileName(file.name && file.name !== 'image.png' ? file.name : `${pageSlug}.${ext}`).replace(/\.\w+$/, '');
    const suffix = Math.random().toString(36).slice(2, 6);
    const name = `${baseName.startsWith(pageSlug) ? '' : `${pageSlug}-`}${baseName}-${suffix}.${ext}`.slice(-90);
    const repoPath = `${IMAGES_DIR}${name}`;
    const base64 = await new Promise((resolve, reject) => {
      const r = new FileReader();
      r.onload = () => resolve(String(r.result).split(',')[1]);
      r.onerror = reject;
      r.readAsDataURL(file);
    });
    S.images.set(repoPath, { name, base64, url: URL.createObjectURL(file), size: file.size });
    const alt = baseName.replace(/-/g, ' ');
    const link = relativeLink(S.path, repoPath);
    const r = S.editor.state.selection.main;
    const line = S.editor.state.doc.lineAt(r.from);
    if (line.text.trim()) insertBlock(S.editor, `![${alt}](${link})`, alt);
    else {
      S.editor.dispatch({ changes: { from: r.from, to: r.to, insert: `![${alt}](${link})` }, scrollIntoView: true });
      S.editor.focus();
    }
  }
  renderStatus();
  updatePreview();
}

function editorScreen(content) {
  if (!S.view) {
    const saved = store.get('yse-editor-view');
    S.view = saved || (window.innerWidth < 960 ? 'source' : 'split');
  }
  const back = S.isNew ? new URL(`${S.newPage.dir}/`, cfg.siteRoot).href : siteUrl(S.path);
  const send = h('button', { type: 'button', class: 'yse-btn yse-btn--primary yse-send', onClick: () => openSubmit() }, S.pr ? `Добавить в PR #${S.pr.number}` : 'Отправить правку');
  const preview = h('article', { class: 'md-typeset yse-preview', 'aria-label': 'Превью страницы' });
  const sourcePane = h('div', { class: 'yse-pane yse-pane--source' });
  clear(
    root,
    h(
      'div',
      { class: 'yse-shell' },
      h(
        'header',
        { class: 'yse-topbar' },
        h('a', { class: 'yse-btn yse-btn--ghost', href: back }, icon('back', 16), 'Отмена'),
        h('span', { class: 'yse-divider', 'aria-hidden': 'true' }),
        h('code', { class: 'yse-path', title: S.path }, S.path),
        S.isNew && h('span', { class: 'yse-chip yse-chip--new' }, 'новая'),
        S.pr && h('a', { class: 'yse-chip', href: S.pr.url, target: '_blank', rel: 'noopener', title: S.pr.title }, icon('pr', 14), `PR #${S.pr.number}`),
        h('span', { class: 'yse-draft-status', role: 'status' }),
        h('span', { class: 'yse-spacer' }),
        h('div', { class: 'yse-user' }),
        send,
      ),
      h('div', { class: 'yse-banners' }),
      h(
        'div',
        { class: 'yse-toolbar', role: 'toolbar', 'aria-label': 'Форматирование' },
        toolButton('heading', 'Заголовок', commands.heading),
        toolButton('bold', 'Жирный (Ctrl+B)', commands.bold),
        toolButton('italic', 'Курсив (Ctrl+I)', commands.italic),
        toolButton('link', 'Ссылка (Ctrl+K)', commands.link),
        toolButton('code', 'Код в строке (Ctrl+E)', commands.code),
        toolButton('list', 'Список', commands.list),
        toolButton('olist', 'Нумерованный список', commands.olist),
        h('span', { class: 'yse-toolbar__sep', 'aria-hidden': 'true' }),
        admonitionMenu(),
        toolButton('codeblock', 'Блок команд', commands.codeblock, { text: 'Команды' }),
        toolButton('tabs', 'Вкладки', commands.tabs, { text: 'Вкладки' }),
        toolButton('table', 'Таблица', commands.table, { text: 'Таблица' }),
        toolButton('image', 'Картинка (можно вставить из буфера)', () => pickImage.click(), { text: 'Картинка' }),
        toolButton('keyboard', 'Клавиши ++ctrl+c++', commands.keys),
        h('span', { class: 'yse-spacer' }),
        viewSwitch(),
      ),
      h('div', { class: 'yse-panes', 'data-view': S.view }, sourcePane, h('div', { class: 'yse-pane yse-pane--preview' }, h('div', { class: 'yse-pane__label' }, 'Превью'), preview)),
      h('footer', { class: 'yse-statusbar' }),
      pickImage,
    ),
  );
  S.preview = preview;
  S.editor = createEditor(sourcePane, {
    doc: content,
    onChange: () => {
      clearTimeout(previewTimer);
      clearTimeout(analyzeTimer);
      clearTimeout(draftTimer);
      previewTimer = setTimeout(updatePreview, 150);
      analyzeTimer = setTimeout(analyze, 250);
      draftTimer = setTimeout(() => saveDraft(S.editor.state.doc.toString()), 800);
    },
    onSave: () => saveDraft(S.editor.state.doc.toString()),
    onSubmit: () => openSubmit(),
    onPasteFiles: addImages,
  });
  S.editor.scrollDOM.addEventListener('scroll', () => requestAnimationFrame(syncPreview), { passive: true });
  renderUser();
  analyze();
  updatePreview();
  S.editor.focus();
}

window.addEventListener('beforeunload', (e) => {
  if (S.images.size && !S.submitted) {
    e.preventDefault();
    e.returnValue = '';
  }
});

// ======================================================================
// Отправка

function defaultTitle(text) {
  if (S.isNew) return `Новая страница: ${S.newPage.title}`;
  const h1 = /^#\s+(.+?)\s*(\{[^}]*\})?\s*$/m.exec(text)?.[1];
  return `${h1 || S.path.replace(/^docs\//, '')}: правка`;
}

function fileRow(name, meta, onRemove) {
  return h(
    'li',
    { class: 'yse-filelist__item' },
    icon(name.match(/\.(png|jpe?g|webp|gif)$/i) ? 'image' : 'file', 16),
    h('code', null, name),
    h('span', { class: 'yse-spacer' }),
    meta,
    onRemove && h('button', { type: 'button', class: 'yse-iconbtn', 'aria-label': `Убрать ${name}`, onClick: onRemove }, icon('x', 15)),
  );
}

function openSubmit() {
  if (!S.editor) return;
  analyze();
  const text = S.editor.state.doc.toString();
  const blocking = S.findings.filter((f) => f.severity === 'block');
  const { added, removed } = S.stats;
  const noChanges = !S.isNew && added === 0 && removed === 0 && S.images.size === 0;

  const saved = store.get(`yse-submit:${S.path}`) || {};
  const title = h('input', { id: 'pr-title', class: 'yse-input', type: 'text', maxlength: '120', value: saved.title || (S.pr ? 'Правка по ревью' : defaultTitle(text)) });
  const desc = h('textarea', { id: 'pr-desc', class: 'yse-input', rows: '3', maxlength: '4000', placeholder: 'Например: добавил проверку, что обновления остались выключенными после перезагрузки.' });
  desc.value = saved.description || '';
  const tested = h('input', { id: 'pr-tested', class: 'yse-input', type: 'text', maxlength: '300', placeholder: 'Модель и прошивка, например: Мини 2, 1.104.4', value: saved.tested || '' });
  const consent = h('input', { id: 'pr-ok', type: 'checkbox' });
  const err = h('div', { class: 'yse-submit-error' });
  const submitBtn = h('button', { type: 'submit', class: 'yse-btn yse-btn--primary yse-btn--lg' }, icon('pr'), S.pr ? `Добавить в PR #${S.pr.number}` : 'Создать Pull Request');
  const files = h('ul', { class: 'yse-filelist' });

  const renderFiles = () => {
    clear(
      files,
      fileRow(S.path, S.isNew ? h('span', { class: 'is-add' }, 'новая') : [h('span', { class: 'is-add' }, `+${added}`), ' ', h('span', { class: 'is-del' }, `−${removed}`)]),
      S.isNew && fileRow('mkdocs.yml', h('span', { class: 'yse-muted' }, `пункт в меню «${S.newPage.section}»`)),
      [...S.images].map(([path, img]) =>
        fileRow(path.replace(/^docs\//, ''), h('span', { class: 'yse-muted' }, `${Math.ceil(img.size / 1024)} КБ`), () => {
          S.images.delete(path);
          URL.revokeObjectURL(img.url);
          renderFiles();
          renderStatus();
          updatePreview();
        }),
      ),
    );
  };
  renderFiles();

  const refresh = () => {
    submitBtn.disabled = !consent.checked || !title.value.trim() || blocking.length > 0 || noChanges;
  };
  consent.addEventListener('change', refresh);
  title.addEventListener('input', refresh);
  refresh();

  const form = h(
    'form',
    { class: 'yse-form', novalidate: true },
    stepper(2),
    h('h1', { class: 'yse-dialog__title' }, S.pr ? `Добавить правку в PR #${S.pr.number}` : 'Отправить правку мейнтейнерам'),
    h('div', { class: 'yse-mono yse-hint' }, S.pr ? S.pr.title : `${cfg.repo} ← @${api.user?.login || 'вы'}:wiki/…`),
    blocking.length > 0 &&
      message('danger', [
        h('strong', null, 'Похоже на личные данные — отправка заблокирована.'),
        h(
          'ul',
          { class: 'yse-findings' },
          blocking.map((f) =>
            h('li', null, h('button', { type: 'button', class: 'yse-linkbtn', onClick: () => (m.remove(), gotoLine(S.editor, f.line)) }, `строка ${f.line}`), `: ${f.label} — `, h('code', null, f.excerpt)),
          ),
        ),
        'Замените на плейсхолдер, например ',
        h('code', null, '<MAC-колонки>'),
        '.',
      ]),
    noChanges && message('info', 'В правке пока нет изменений.'),
    h('label', { class: 'yse-label', for: 'pr-title' }, 'Название'),
    title,
    h('label', { class: 'yse-label', for: 'pr-desc' }, 'Что изменилось и зачем'),
    desc,
    h('label', { class: 'yse-label', for: 'pr-tested' }, 'На чём проверено ', h('span', { class: 'yse-muted' }, '(если есть)')),
    tested,
    h('div', { class: 'yse-label' }, 'Файлы'),
    files,
    h('div', { class: 'yse-label' }, 'Автопроверки после отправки'),
    h(
      'ul',
      { class: 'yse-checklist yse-checklist--todo' },
      ['Поиск ключей, MAC-адресов и токенов в тексте', 'Сборка сайта без ошибок и битых ссылок', 'Ревью мейнтейнера'].map((t) =>
        h('li', { class: 'yse-checklist__item' }, h('span', { class: 'yse-check yse-check--todo' }), t),
      ),
    ),
    h('div', { class: 'yse-consent' }, consent, h('label', { for: 'pr-ok' }, 'Я не публикую личные данные: ключи, MAC-адреса, серийные номера, токены.')),
    err,
    h(
      'div',
      { class: 'yse-actions yse-actions--split' },
      h('button', { type: 'button', class: 'yse-btn yse-btn--ghost', onClick: () => m.close() }, icon('back', 16), 'Назад к редактору'),
      submitBtn,
    ),
  );
  const m = modal(form, { label: 'Отправка правки', onClose: () => S.editor.focus() });
  const remember = () => store.set(`yse-submit:${S.path}`, { title: title.value, description: desc.value, tested: tested.value });
  [title, desc, tested].forEach((el) => el.addEventListener('input', remember));

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (submitBtn.disabled) return;
    submitBtn.disabled = true;
    clear(submitBtn, spinner(), S.pr ? 'Добавляем коммит…' : 'Создаём форк, коммит и PR…');
    clear(err);
    const payload = {
      title: title.value.trim(),
      description: desc.value.trim(),
      tested: tested.value.trim(),
      page: { path: S.path, content: S.editor.state.doc.toString(), baseSha: S.baseSha },
      images: [...S.images].map(([path, img]) => ({ path, base64: img.base64 })),
      ...(S.isNew ? { newPage: { section: S.newPage.section, title: S.newPage.title } } : {}),
      ...(S.pr ? { pr: S.pr.number } : {}),
    };
    try {
      const res = await api.submit(payload);
      S.submitted = true;
      store.del(draftKey());
      store.del(`yse-submit:${S.path}`);
      m.remove();
      doneScreen(res, payload);
    } catch (ex) {
      submitBtn.disabled = false;
      clear(submitBtn, icon('pr'), S.pr ? `Добавить в PR #${S.pr.number}` : 'Создать Pull Request');
      if (!(ex instanceof ApiError)) return clear(err, message('danger', ex.message));
      if (ex.status === 401) {
        m.remove();
        if (await reauth()) openSubmit();
        return;
      }
      if (ex.code === 'conflict') {
        m.remove();
        return handleConflict(ex.data.current);
      }
      if (ex.code === 'sensitive') {
        const danger = new Set(ex.data.findings.map((f) => f.line));
        S.editor.dispatch({ effects: setLineMarks.of({ changed: S.stats.changedLines, danger }) });
        return clear(err, message('danger', ['Сервер нашёл похожее на личные данные: ', ex.data.findings.map((f) => `строка ${f.line} (${f.label})`).join(', '), '.']));
      }
      clear(err, message('danger', ex.message));
    }
  });
}

function handleConflict(current) {
  const mine = S.editor.state.doc.toString();
  const merged = rebase(S.original, mine, current.content);
  S.original = current.content;
  S.baseSha = current.sha;
  if (merged != null) {
    setDoc(S.editor, merged);
    banner('info', 'Пока вы правили, страницу успели изменить. Ваша правка перенесена на свежую версию — проверьте результат и отправьте ещё раз.');
  } else {
    setDoc(S.editor, current.content);
    showMine(mine);
    banner('warn', 'Пока вы правили, страницу успели изменить, и перенести правку автоматически не вышло. В редакторе — свежая версия, ваша — в панели ниже.');
  }
  analyze();
  updatePreview();
}

// ======================================================================
// Готово

function doneScreen(res, payload) {
  const pr = res.pr;
  const back = S.isNew ? new URL(`${S.newPage.dir}/`, cfg.siteRoot).href : siteUrl(S.path);
  const steps = h('ul', { class: 'yse-progress' });
  const row = (state, text, note) =>
    h(
      'li',
      { class: `yse-progress__item is-${state}` },
      h('span', { class: 'yse-progress__dot' }, state === 'done' ? icon('check', 12) : null),
      h('span', null, text),
      note && h('span', { class: 'yse-progress__note' }, note),
    );
  const paint = (st) => {
    const checks = {
      none: ['current', 'запускаются'],
      pending: ['current', 'идут сейчас'],
      success: ['done', 'пройдены'],
      failure: ['fail', 'есть ошибки — подробности в PR'],
    }[st?.checksState || 'none'];
    const merged = st?.state === 'merged';
    const closed = st?.state === 'closed';
    clear(
      steps,
      row('done', res.updated ? 'Коммит добавлен в ветку' : 'Форк и ветка созданы', 'готово'),
      row('done', res.updated ? `PR #${pr.number} обновлён` : 'Pull Request открыт', 'готово'),
      row(checks[0], 'Автопроверки: личные данные, сборка', checks[1]),
      row(merged ? 'done' : closed ? 'fail' : checks[0] === 'done' ? 'current' : 'todo', 'Ревью мейнтейнера', merged ? 'принято' : closed ? 'PR закрыт' : st?.reviewComments ? `комментариев: ${st.reviewComments}` : 'ожидание'),
      row(merged ? 'done' : 'todo', 'Публикация на сайте', merged ? 'через пару минут' : 'ожидание'),
    );
  };
  paint(null);

  const added = S.isNew ? null : lineStats(S.original, payload.page.content);
  clear(
    root,
    h(
      'div',
      { class: 'yse-done' },
      stepper(3),
      h(
        'div',
        { class: 'yse-done__grid' },
        h(
          'section',
          { class: 'yse-card' },
          h('div', { class: 'yse-card__icon yse-card__icon--ok' }, icon('check', 26)),
          h('h1', null, res.updated ? 'Правка добавлена в PR' : 'Правка отправлена'),
          h('p', { class: 'yse-muted' }, 'Мейнтейнеры получили уведомление. Пока идут проверки, можно открыть Pull Request на GitHub.'),
          h(
            'a',
            { class: 'yse-prcard', href: pr.url, target: '_blank', rel: 'noopener' },
            icon('pr', 20),
            h(
              'div',
              null,
              h('div', { class: 'yse-prcard__title' }, pr.title),
              h('div', { class: 'yse-prcard__meta' }, `#${pr.number} · открыт · ${S.path.replace(/^docs\//, '')} `, added ? [h('span', { class: 'is-add' }, `+${added.added}`), ' ', h('span', { class: 'is-del' }, `−${added.removed}`)] : h('span', { class: 'is-add' }, 'новая страница')),
            ),
          ),
          steps,
          h(
            'div',
            { class: 'yse-actions' },
            h('a', { class: 'yse-btn yse-btn--primary', href: back }, 'Вернуться на страницу'),
            h('a', { class: 'yse-btn', href: pr.url, target: '_blank', rel: 'noopener' }, 'Открыть PR на GitHub', icon('external', 15)),
            h('a', { class: 'yse-btn yse-btn--ghost', href: `?path=${encodeURIComponent(S.path)}&pr=${pr.number}` }, icon('edit', 15), 'Доработать'),
          ),
        ),
        h(
          'aside',
          { class: 'yse-card yse-card--side' },
          h('h2', null, 'Что дальше'),
          h('p', null, 'Если мейнтейнер оставит комментарий, GitHub пришлёт письмо. Доработать правку можно здесь же: кнопка «Доработать» или карандаш на странице — изменения уйдут в тот же PR.'),
          h('p', null, 'После принятия правки ваш ник появится на странице «Участники».'),
          h('p', { class: 'yse-muted' }, 'Хотите исправить ещё что-то? Откройте любую страницу и нажмите карандаш: вход повторять не придётся.'),
        ),
      ),
    ),
  );
  history.replaceState(null, '', `?path=${encodeURIComponent(S.path)}&pr=${pr.number}&done=1`);

  // опрос статуса, пока вкладка открыта (до 15 минут)
  const started = Date.now();
  const poll = async () => {
    if (!document.contains(steps)) return;
    try {
      const st = await api.pr(pr.number);
      paint(st);
      if (st.state !== 'open' && st.checksState !== 'pending') return;
    } catch {
      /* попробуем позже */
    }
    if (Date.now() - started < 15 * 60 * 1000) setTimeout(poll, document.hidden ? 30000 : 10000);
  };
  setTimeout(poll, 3000);
}

// ======================================================================
// Старт

async function start() {
  try {
    if (!api.user) await api.me();
    const path = params.get('path');
    if (params.get('new')) return await newPageScreen();
    if (path) {
      if (!isValidPagePath(path)) return fatal('Неверный адрес', `Путь «${path}» не похож на страницу вики.`, [h('a', { class: 'yse-btn yse-btn--primary', href: cfg.siteRoot }, 'На главную')]);
      return await openExisting(path, params.get('pr'));
    }
    fatal('Какую страницу править?', 'Откройте нужную страницу вики и нажмите карандаш над заголовком — или создайте новую.', [
      h('a', { class: 'yse-btn yse-btn--primary', href: '?new=1' }, icon('plus', 16), 'Новая страница'),
      h('a', { class: 'yse-btn', href: cfg.siteRoot }, 'На главную'),
    ]);
  } catch (e) {
    if (e instanceof ApiError && e.status === 401) return signInScreen(start);
    const path = params.get('path');
    fatal('Не получилось открыть редактор', e.message, [
      h('button', { type: 'button', class: 'yse-btn yse-btn--primary', onClick: () => location.reload() }, 'Попробовать снова'),
      h('a', { class: 'yse-btn', href: githubEditUrl(path) }, 'Править на GitHub'),
    ]);
  }
}

if (!api) {
  const path = params.get('path');
  fatal('Редактор ещё не подключён', 'Сервер редактора не настроен. Пока править страницы можно на GitHub.', [
    h('a', { class: 'yse-btn yse-btn--primary', href: githubEditUrl(path) }, 'Править на GitHub'),
  ]);
} else if (!api.signedIn) {
  signInScreen(start, api.redirectError);
} else {
  start();
}
