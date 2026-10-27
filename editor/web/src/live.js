// Правка прямо в превью: клик — каретка, дальше просто печатать.
//
// Превью не конвертируется обратно в Markdown. Каждый блок превью знает свои строки
// исходника (`data-line`/`data-end` из mdext.js), правка сопоставляется с исходником
// посимвольно (livemap.js) и вносится в него точечно — разметка вики не страдает.
// Пока каретка внутри блока, превью не перерисовывается, чтобы не прыгал курсор;
// перерисовка — при переходе к другому блоку и при уходе из превью.

import { caretToSource, sourceEdit } from './livemap.js';

const snapshots = new WeakMap();

// Части превью без своих строк в исходнике: заголовок admonition, ярлыки вкладок,
// имя файла у блока кода. Их правку некуда перенести, поэтому они только для чтения.
const CHROME = '.admonition-title, .tabbed-labels, .filename, summary';

/** Запомнить текст блоков — вызывается после каждой полной отрисовки превью. */
export function markBlocks(preview) {
  for (const el of preview.querySelectorAll('[data-line]')) snapshots.set(el, el.textContent);
  for (const el of preview.querySelectorAll(CHROME)) el.contentEditable = 'false';
}

function blockOf(preview, node) {
  const start = node instanceof Element ? node : node?.parentElement;
  const el = start?.closest('[data-line]');
  return el && preview.contains(el) ? el : null;
}

/** Смещение точки (node, offset) в тексте блока. */
function offsetIn(el, node, nodeOffset) {
  const range = document.createRange();
  range.selectNodeContents(el);
  try {
    range.setEnd(node, nodeOffset);
  } catch {
    return 0;
  }
  return range.toString().length;
}

/** Поставить каретку на смещение `offset` в тексте блока. */
function setCaret(el, offset) {
  const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
  let left = offset;
  let node;
  let last = null;
  while ((node = walker.nextNode())) {
    last = node;
    if (left <= node.nodeValue.length) {
      const sel = window.getSelection();
      const range = document.createRange();
      range.setStart(node, left);
      range.collapse(true);
      sel.removeAllRanges();
      sel.addRange(range);
      return true;
    }
    left -= node.nodeValue.length;
  }
  const sel = window.getSelection();
  const range = document.createRange();
  if (last) range.setStart(last, last.nodeValue.length);
  else range.setStart(el, 0); // пустой блок: каретка внутрь самого элемента
  range.collapse(true);
  sel.removeAllRanges();
  sel.addRange(range);
  return true;
}

/**
 * Пустая строка исходника не даёт блока в превью, поэтому после Enter каретке некуда
 * встать. Ставим заготовку абзаца с теми же границами — в неё и пойдёт набранное.
 */
function placeholderBlock(preview, line, afterLine) {
  const anchor = preview.querySelector(`[data-line="${afterLine}"]`);
  if (!anchor) return null;
  const p = document.createElement('p');
  p.dataset.line = String(line);
  p.dataset.end = String(line + 1);
  p.append(document.createElement('br'));
  anchor.after(p);
  snapshots.set(p, '');
  return p;
}

/** Строки блока в координатах документа CodeMirror. */
function blockRange(view, el) {
  const doc = view.state.doc;
  const first = Number(el.dataset.line) + 1;
  const last = Number(el.dataset.end);
  if (!Number.isFinite(first) || !Number.isFinite(last)) return null;
  const a = Math.min(Math.max(first, 1), doc.lines);
  const b = Math.min(Math.max(last, a), doc.lines);
  // содержимое фенса в превью заканчивается переводом строки — он должен попасть в срез,
  // иначе текст блока перестаёт быть подпоследовательностью исходника
  const tail = el.dataset.code === '1' && b < doc.lines ? 1 : 0;
  return { from: doc.line(a).from, to: doc.line(b).to + tail };
}

const countLines = (s) => (s.match(/\n/g) || []).length;

/**
 * После правки, изменившей число строк, блоки ниже съезжают. Полной перерисовки
 * пока нет (каретка внутри блока), поэтому границы правятся прямо в разметке превью.
 */
function shiftBlocks(preview, afterLine, delta) {
  if (!delta) return;
  for (const el of preview.querySelectorAll('[data-line]')) {
    const line = Number(el.dataset.line);
    const end = Number(el.dataset.end);
    if (Number.isFinite(line) && line > afterLine) el.dataset.line = String(line + delta);
    if (Number.isFinite(end) && end > afterLine) el.dataset.end = String(end + delta);
  }
}

/**
 * Включает правку в превью.
 *
 * @param preview  элемент превью
 * @param opts.getView   () => EditorView левой панели
 * @param opts.rerender  (restore) => void — полная перерисовка превью
 * @param opts.notify    (text) => void — подсказка, когда блок правится только слева
 */
export function enableLiveEdit(preview, { getView, rerender, notify }) {
  const opts = {}; // команды отмены CodeMirror, см. setHistory
  let current = null; // блок, в котором каретка
  let dirty = false; // в текущем блоке есть неотрисованная правка
  let typing = false; // идёт ввод — перерисовку превью снаружи придержать

  const reset = () => {
    current = null;
    dirty = false;
    typing = false;
  };

  /** Переносит правку блока в исходник. true — перенесена или нечего переносить. */
  function flush(el) {
    const view = getView();
    if (!view || !el || !el.isConnected) return true;
    const before = snapshots.get(el);
    const after = el.textContent;
    if (before === undefined || before === after) return true;
    const range = blockRange(view, el);
    if (!range) return false;
    const src = view.state.doc.sliceString(range.from, range.to);
    const edit = sourceEdit(before, after, src);
    if (!edit) return false;
    view.dispatch({
      changes: { from: range.from + edit.from, to: range.from + edit.to, insert: edit.insert },
    });
    shiftBlocks(preview, Number(el.dataset.line), countLines(edit.insert) - countLines(src.slice(edit.from, edit.to)));
    snapshots.set(el, after);
    return true;
  }

  /** Правка не сопоставилась: вернуть блок к исходному виду и сказать об этом. */
  function revert(el) {
    rerender();
    notify?.('Этот фрагмент правится только в исходнике — разметка не даёт перенести правку.');
    reset();
    if (el) {
      const again = preview.querySelector(`[data-line="${el.dataset.line}"]`);
      if (again) setCaret(again, 0);
    }
  }

  /** Смещение каретки в документе CodeMirror, если она внутри блока. */
  function caretDocOffset(el) {
    const view = getView();
    const sel = window.getSelection();
    if (!view || !sel || !sel.rangeCount) return null;
    const range = blockRange(view, el);
    if (!range) return null;
    const text = el.textContent;
    const offset = offsetIn(el, sel.anchorNode, sel.anchorOffset);
    const src = view.state.doc.sliceString(range.from, range.to);
    const inSrc = caretToSource(text, src, offset);
    return inSrc === null ? null : range.from + inSrc;
  }

  // ---- смена блока: отрисовать предыдущий и вернуть каретку туда, куда кликнули

  function onSelectionChange() {
    if (!preview.contains(document.activeElement) && document.activeElement !== preview) return;
    const sel = window.getSelection();
    if (!sel || !sel.anchorNode) return;
    const el = blockOf(preview, sel.anchorNode);
    if (el === current) return;
    if (current && dirty) {
      const line = el ? Number(el.dataset.line) : null;
      const offset = el && sel.anchorNode ? offsetIn(el, sel.anchorNode, sel.anchorOffset) : 0;
      if (!flush(current)) return revert(current);
      dirty = false;
      rerender();
      if (line !== null) {
        const again = preview.querySelector(`[data-line="${line}"]`);
        if (again) {
          setCaret(again, offset);
          current = again;
          return;
        }
      }
    }
    current = el;
  }

  document.addEventListener('selectionchange', onSelectionChange);

  preview.addEventListener('input', () => {
    const sel = window.getSelection();
    const el = (sel && sel.anchorNode && blockOf(preview, sel.anchorNode)) || current;
    if (!el) return revert(null); // правка попала туда, где нет строк исходника
    current = el;
    typing = true;
    if (!flush(el)) return revert(el);
    dirty = true;
  });

  // Enter, Shift+Enter и Backspace правим сами: браузер склеил бы блоки в DOM, а наша
  // привязка к строкам исходника этого не переживёт. Через keydown, а не beforeinput —
  // в режиме contenteditable="plaintext-only" Chrome beforeinput не шлёт.
  preview.addEventListener('keydown', (e) => {
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    const sel = window.getSelection();
    const el = (sel && sel.anchorNode && blockOf(preview, sel.anchorNode)) || current;
    if (!el) return;

    // правка через границу блоков браузером склеила бы разметку — только слева
    if (sel && !sel.isCollapsed && blockOf(preview, sel.focusNode) !== el) {
      if (e.key.length === 1 || e.key === 'Enter' || e.key === 'Backspace' || e.key === 'Delete') {
        e.preventDefault();
        notify?.('Правка нескольких блоков сразу — в левой панели.');
      }
      return;
    }

    if (e.key === 'Enter') {
      e.preventDefault();
      if (!flush(el)) return revert(el);
      const view = getView();
      const at = caretDocOffset(el);
      if (at === null || !view) return revert(el);
      // Shift+Enter и перевод строки внутри кода — одна строка, Enter в тексте — новый блок
      const insert = el.dataset.code === '1' || e.shiftKey ? '\n' : '\n\n';
      view.dispatch({ changes: { from: at, insert } });
      const line = view.state.doc.lineAt(at + insert.length).number - 1;
      const from = Number(el.dataset.line);
      rerender();
      const next = preview.querySelector(`[data-line="${line}"]`) || placeholderBlock(preview, line, from);
      focusBlock(next, 0);
      return;
    }

    // Backspace в начале блока и Delete в конце склеили бы два блока
    const collapsed = sel && sel.isCollapsed;
    const offset = collapsed ? offsetIn(el, sel.anchorNode, sel.anchorOffset) : -1;
    if (e.key === 'Backspace' && collapsed && offset === 0) {
      e.preventDefault();
      joinWithPrevious(el);
      return;
    }
    if (e.key === 'Delete' && collapsed && offset === el.textContent.length) {
      const blocks = [...preview.querySelectorAll('[data-line]')];
      const next = blocks.find((b) => Number(b.dataset.line) > Number(el.dataset.line) && !b.contains(el) && !el.contains(b));
      if (!next) return;
      e.preventDefault();
      joinWithPrevious(next);
    }
  });

  /** Склейка блока с предыдущим: в исходнике убираем разделяющие пустые строки. */
  function joinWithPrevious(el) {
    if (!flush(el)) return revert(el);
    const view = getView();
    const range = blockRange(view, el);
    if (!view || !range || range.from === 0) return;
    let from = range.from;
    while (from > 0 && view.state.doc.sliceString(from - 1, from) === '\n') from--;
    if (from === range.from) return;
    view.dispatch({ changes: { from, to: range.from, insert: '' } });
    const line = view.state.doc.lineAt(from).number - 1;
    rerender();
    const joined = preview.querySelector(`[data-line="${line}"]`);
    focusBlock(joined, joined ? joined.textContent.length : 0);
  }

  /**
   * Каретка в блок после перерисовки. Заодно помечает, что правят превью: иначе
   * отложенная перерисовка из левой панели сотрёт блок вместе с кареткой.
   */
  function focusBlock(el, offset) {
    reset();
    if (!el) return;
    current = el;
    typing = true;
    // после перерисовки innerHTML фокус мог уйти с панели — вернуть, иначе каретки не видно
    if (!preview.contains(document.activeElement)) preview.focus({ preventScroll: true });
    setCaret(el, offset);
  }

  // Отменой заведует CodeMirror: иначе история браузера разойдётся с исходником.
  // Клавиша берётся из e.code, а не из e.key: при русской раскладке Ctrl+Z приходит
  // как «я», и сравнение с 'z' ничего не находило.
  preview.addEventListener('keydown', (e) => {
    if (!(e.ctrlKey || e.metaKey)) return;
    const isUndo = e.code === 'KeyZ' && !e.shiftKey;
    const isRedo = e.code === 'KeyY' || (e.code === 'KeyZ' && e.shiftKey);
    if (!isUndo && !isRedo) return;
    e.preventDefault();
    if (current && dirty && !flush(current)) return revert(current);
    const view = getView();
    if (!view) return;
    const line = current ? Number(current.dataset.line) : null;
    (isUndo ? opts.undo : opts.redo)?.(view);
    rerender();
    reset();
    // каретка остаётся в превью: уводить её в левую панель посреди набора незачем
    const again = line === null ? null : preview.querySelector(`[data-line="${line}"]`);
    if (again) focusBlock(again, again.textContent.length);
  });

  /** Обернуть выделение в превью разметкой (`**`, `*`, `` ` ``) — прямо в исходнике. */
  function wrapSelection(marker) {
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed || !sel.rangeCount) return;
    const el = blockOf(preview, sel.anchorNode);
    if (!el || blockOf(preview, sel.focusNode) !== el) {
      notify?.('Выделение вышло за один блок — разметка ставится в левой панели.');
      return;
    }
    if (!flush(el)) return revert(el);
    const view = getView();
    const range = blockRange(view, el);
    if (!view || !range) return;
    const src = view.state.doc.sliceString(range.from, range.to);
    const text = el.textContent;
    const r = sel.getRangeAt(0);
    const from = caretToSource(text, src, offsetIn(el, r.startContainer, r.startOffset));
    const to = caretToSource(text, src, offsetIn(el, r.endContainer, r.endOffset));
    if (from === null || to === null || to <= from) return revert(el);
    const line = Number(el.dataset.line);
    const end = offsetIn(el, r.endContainer, r.endOffset);
    view.dispatch({
      changes: [
        { from: range.from + from, insert: marker },
        { from: range.from + to, insert: marker },
      ],
    });
    rerender();
    focusBlock(preview.querySelector(`[data-line="${line}"]`), end);
  }

  // Ctrl+B/I/K браузер превратил бы в <b>/<i>, которым нет места в Markdown
  preview.addEventListener('keydown', (e) => {
    if (!(e.ctrlKey || e.metaKey) || e.shiftKey) return;
    const marker = { KeyB: '**', KeyI: '*', KeyE: '`' }[e.code];
    if (marker) {
      e.preventDefault();
      wrapSelection(marker);
      return;
    }
    if (e.code === 'KeyU' || e.code === 'KeyK') {
      e.preventDefault();
      notify?.(e.code === 'KeyK' ? 'Ссылку ставит кнопка на панели или левая панель.' : 'Подчёркивания в разметке вики нет.');
    }
  });

  preview.addEventListener('focusout', () => {
    if (preview.contains(document.activeElement)) return;
    if (current && dirty && !flush(current)) return revert(current);
    const had = dirty;
    reset();
    if (had) rerender();
  });

  // Обычный contenteditable, не plaintext-only: для plaintext-only Chrome навязывает
  // white-space: pre-wrap, и переводы строк из разметки markdown-it становятся видны —
  // отступы расходятся с сайтом. Вставку из буфера и форматирование браузером,
  // ради которых был plaintext-only, закрываем сами (ниже).
  preview.contentEditable = 'true';
  preview.spellcheck = true;

  // вставка — только текстом: иначе в превью попадёт чужой HTML, которому нет места
  // в Markdown, а правка перестанет сопоставляться с исходником
  preview.addEventListener('paste', (e) => {
    e.preventDefault();
    const text = e.clipboardData?.getData('text/plain');
    if (text) document.execCommand('insertText', false, text);
  });

  // перетаскивание файлов и текста в превью: картинки добавляются кнопкой на панели
  preview.addEventListener('drop', (e) => e.preventDefault());
  preview.addEventListener('dragover', (e) => e.preventDefault());

  return {
    /** Перерисовку превью снаружи придержать, пока в нём печатают. */
    isEditing: () => typing || (current !== null && dirty),
    /** Команды отмены берём у CodeMirror. */
    setHistory: (undo, redo) => {
      opts.undo = undo;
      opts.redo = redo;
    },
    reset,
  };
}
