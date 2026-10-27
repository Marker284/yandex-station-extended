// CodeMirror 6: настройка под вики, команды тулбара, подсветка изменённых и опасных строк.

import { EditorState, StateEffect, StateField, RangeSetBuilder, EditorSelection } from '@codemirror/state';
import {
  EditorView,
  Decoration,
  GutterMarker,
  ViewPlugin,
  drawSelection,
  dropCursor,
  gutterLineClass,
  highlightActiveLine,
  highlightActiveLineGutter,
  highlightSpecialChars,
  keymap,
  lineNumbers,
  placeholder,
} from '@codemirror/view';
import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands';
import { parser as markdownParser, GFM } from '@lezer/markdown';
import { HighlightStyle, Language, LanguageSupport, bracketMatching, defineLanguageFacet, indentUnit, syntaxHighlighting } from '@codemirror/language';
import { highlightSelectionMatches, search, searchKeymap } from '@codemirror/search';
import { tags as t } from '@lezer/highlight';

// Markdown без вложенных HTML/CSS/JS-парсеров из @codemirror/lang-markdown (−200 КБ сборки)
const markdownLang = new Language(
  defineLanguageFacet({ commentTokens: { block: { open: '<!--', close: '-->' } } }),
  markdownParser.configure([GFM]),
  [],
  'markdown',
);
const markdown = () => new LanguageSupport(markdownLang);

// ---------- внешний вид: цвета из переменных Material (светлая и тёмная тема сами)

const theme = EditorView.theme({
  '&': { height: '100%', fontSize: '14px', backgroundColor: 'var(--yse-source-bg)', color: 'var(--md-default-fg-color)' },
  '.cm-scroller': { fontFamily: 'var(--md-code-font-family, monospace)', lineHeight: '1.65' },
  '.cm-content': { padding: '14px 0 40vh', caretColor: 'var(--md-primary-fg-color)' },
  '.cm-line': { padding: '0 18px 0 6px' },
  '.cm-gutters': { backgroundColor: 'var(--yse-source-bg)', color: 'var(--md-default-fg-color--light)', border: 'none' },
  '.cm-lineNumbers .cm-gutterElement': { padding: '0 10px 0 14px', minWidth: '44px' },
  '.cm-activeLine': { backgroundColor: 'var(--yse-active-line)' },
  '.cm-activeLineGutter': { backgroundColor: 'transparent', color: 'var(--md-default-fg-color)' },
  '&.cm-focused': { outline: 'none' },
  '&.cm-focused .cm-cursor': { borderLeftColor: 'var(--md-primary-fg-color)', borderLeftWidth: '2px' },
  '&.cm-focused .cm-selectionBackground, .cm-selectionBackground, ::selection': { backgroundColor: 'var(--yse-selection) !important' },
  '.cm-searchMatch': { backgroundColor: 'var(--yse-search-match)' },
  '.cm-placeholder': { color: 'var(--md-default-fg-color--light)' },
  '.cm-panels': { backgroundColor: 'var(--md-default-bg-color)', color: 'var(--md-default-fg-color)', borderColor: 'var(--md-default-fg-color--lightest)' },
  '.cm-panels input, .cm-panels button': { fontFamily: 'inherit', fontSize: '13px' },
});

const highlight = HighlightStyle.define([
  { tag: t.heading, color: 'var(--yse-syntax-heading)', fontWeight: '700' },
  { tag: t.strong, fontWeight: '700' },
  { tag: t.emphasis, fontStyle: 'italic' },
  { tag: t.strikethrough, textDecoration: 'line-through' },
  { tag: [t.link, t.url], color: 'var(--md-typeset-a-color)' },
  { tag: t.monospace, color: 'var(--yse-syntax-code)' },
  { tag: [t.processingInstruction, t.meta], color: 'var(--md-default-fg-color--light)' },
  { tag: t.quote, color: 'var(--md-default-fg-color--light)', fontStyle: 'italic' },
  { tag: t.contentSeparator, color: 'var(--md-default-fg-color--light)' },
  { tag: [t.angleBracket, t.tagName, t.attributeName], color: 'var(--yse-syntax-html)' },
  { tag: t.list, color: 'var(--yse-syntax-heading)' },
]);

// ---------- строки !!!, ???, === — подсветка как «служебные»

const blockMarkRe = /^\s*(!!!|\?\?\?\+?|===[!+]?)\s/;
const blockMark = Decoration.line({ class: 'cm-yse-block' });

const blockMarks = ViewPlugin.fromClass(
  class {
    constructor(view) {
      this.decorations = this.build(view);
    }
    update(u) {
      if (u.docChanged || u.viewportChanged) this.decorations = this.build(u.view);
    }
    build(view) {
      const b = new RangeSetBuilder();
      for (const { from, to } of view.visibleRanges) {
        for (let pos = from; pos <= to; ) {
          const line = view.state.doc.lineAt(pos);
          if (blockMarkRe.test(line.text)) b.add(line.from, line.from, blockMark);
          pos = line.to + 1;
        }
      }
      return b.finish();
    }
  },
  { decorations: (v) => v.decorations },
);

// ---------- отметки строк: изменённые (зелёные) и с найденными данными (красные)

export const setLineMarks = StateEffect.define();

const changedLine = Decoration.line({ class: 'cm-yse-changed' });
const dangerLine = Decoration.line({ class: 'cm-yse-danger' });
class ChangedGutter extends GutterMarker {
  elementClass = 'cm-yse-changed-gutter';
}
class DangerGutter extends GutterMarker {
  elementClass = 'cm-yse-danger-gutter';
}
const changedGutter = new ChangedGutter();
const dangerGutter = new DangerGutter();

/** { changed: Set<номер строки>, danger: Set<номер строки> } */
const lineMarks = StateField.define({
  create: () => ({ changed: new Set(), danger: new Set() }),
  update(v, tr) {
    for (const e of tr.effects) if (e.is(setLineMarks)) return e.value;
    return v;
  },
});

function buildMarks(state, gutter) {
  const { changed, danger } = state.field(lineMarks);
  const b = new RangeSetBuilder();
  const total = state.doc.lines;
  const all = [...new Set([...changed, ...danger])].filter((n) => n >= 1 && n <= total).sort((a, b2) => a - b2);
  for (const n of all) {
    const line = state.doc.line(n);
    if (gutter) b.add(line.from, line.from, danger.has(n) ? dangerGutter : changedGutter);
    else b.add(line.from, line.from, danger.has(n) ? dangerLine : changedLine);
  }
  return b.finish();
}

const markDecorations = EditorView.decorations.compute([lineMarks, 'doc'], (s) => buildMarks(s, false));
const markGutter = gutterLineClass.compute([lineMarks, 'doc'], (s) => buildMarks(s, true));

// ---------- команды тулбара

function wrap(view, before, after = before, fallback = 'текст') {
  const { state } = view;
  const changes = state.changeByRange((range) => {
    const text = state.sliceDoc(range.from, range.to);
    if (text.startsWith(before) && text.endsWith(after) && text.length >= before.length + after.length) {
      const inner = text.slice(before.length, text.length - after.length);
      return { changes: { from: range.from, to: range.to, insert: inner }, range: EditorSelection.range(range.from, range.from + inner.length) };
    }
    const body = text || fallback;
    return {
      changes: { from: range.from, to: range.to, insert: before + body + after },
      range: EditorSelection.range(range.from + before.length, range.from + before.length + body.length),
    };
  });
  view.dispatch(state.update(changes, { scrollIntoView: true, userEvent: 'input' }));
  view.focus();
  return true;
}

function prefixLines(view, makePrefix) {
  const { state } = view;
  const lines = new Set();
  for (const r of state.selection.ranges) {
    for (let p = r.from; p <= r.to; ) {
      const l = state.doc.lineAt(p);
      lines.add(l.number);
      p = l.to + 1;
    }
  }
  const nums = [...lines].sort((a, b) => a - b);
  const changes = nums.map((n, i) => {
    const l = state.doc.line(n);
    const prefix = makePrefix(i);
    const m = /^(#{1,6} |[-*] |\d+\. )/.exec(l.text);
    if (m && m[0] === prefix) return { from: l.from, to: l.from + m[0].length, insert: '' };
    return { from: l.from, to: l.from + (m ? m[0].length : 0), insert: prefix };
  });
  view.dispatch({ changes, scrollIntoView: true, userEvent: 'input' });
  view.focus();
  return true;
}

/** Вставляет блок с пустыми строками вокруг; `select` — что выделить внутри. */
export function insertBlock(view, text, select) {
  const { state } = view;
  let r = state.selection.main;
  let line = state.doc.lineAt(r.from);
  // без выделения блок встаёт после текущей строки, а не разрывает её
  if (r.empty && line.text.trim() !== '') {
    // на строке «!!! note» / «=== "…"» — пропускаем её тело с отступом
    if (blockMarkRe.test(line.text)) {
      for (let n = line.number + 1; n <= state.doc.lines; n++) {
        const next = state.doc.line(n);
        if (next.text.trim() === '') continue;
        if (!/^( {4}|\t)/.test(next.text)) break;
        line = next;
      }
    }
    r = EditorSelection.cursor(line.to);
  }
  const atLineStart = r.from === line.from && line.text.trim() === '';
  let before = '';
  if (!atLineStart) before = '\n\n';
  else if (line.number > 1 && state.doc.line(line.number - 1).text.trim() !== '') before = '\n';
  const after = r.to < state.doc.length ? '\n\n' : '\n';
  const insert = before + text + after;
  const start = r.from + before.length;
  let sel = EditorSelection.cursor(start + text.length);
  if (select) {
    const i = text.indexOf(select);
    if (i >= 0) sel = EditorSelection.range(start + i, start + i + select.length);
  }
  view.dispatch({ changes: { from: r.from, to: r.to, insert }, selection: sel, scrollIntoView: true, userEvent: 'input' });
  view.focus();
  return true;
}

export const commands = {
  bold: (v) => wrap(v, '**', '**', 'жирный текст'),
  italic: (v) => wrap(v, '*', '*', 'курсив'),
  code: (v) => wrap(v, '`', '`', 'код'),
  link: (v) => {
    const r = v.state.selection.main;
    const text = v.state.sliceDoc(r.from, r.to) || 'текст ссылки';
    const insert = `[${text}](https://)`;
    v.dispatch({
      changes: { from: r.from, to: r.to, insert },
      selection: EditorSelection.range(r.from + text.length + 3, r.from + insert.length - 1),
      scrollIntoView: true,
      userEvent: 'input',
    });
    v.focus();
    return true;
  },
  heading: (v) => prefixLines(v, () => '## '),
  list: (v) => prefixLines(v, () => '- '),
  olist: (v) => prefixLines(v, (i) => `${i + 1}. `),
  codeblock: (v) => {
    const r = v.state.selection.main;
    const sel = v.state.sliceDoc(r.from, r.to);
    return insertBlock(v, `\`\`\`sh\n${sel || 'команда'}\n\`\`\``, sel ? undefined : 'команда');
  },
  admonition: (v, type = 'note', title = 'Заголовок', collapsible = false) => {
    const r = v.state.selection.main;
    const sel = v.state.sliceDoc(r.from, r.to) || 'Текст заметки.';
    const body = sel.split('\n').map((l) => (l ? `    ${l}` : '')).join('\n');
    return insertBlock(v, `${collapsible ? '???' : '!!!'} ${type} "${title}"\n${body}`, title);
  },
  tabs: (v) => insertBlock(v, '=== "Вариант 1"\n\n    Текст для первого варианта.\n\n=== "Вариант 2"\n\n    Текст для второго варианта.', 'Вариант 1'),
  table: (v) => insertBlock(v, '| Модель | Значение |\n|---|---|\n| Мини 2 | … |\n| Лайт | … |', 'Модель'),
  keys: (v) => wrap(v, '++', '++', 'ctrl+c'),
};

export function createEditor(parent, { doc, onChange, onSave, onSubmit, onPasteFiles }) {
  const state = EditorState.create({
    doc,
    extensions: [
      lineNumbers(),
      highlightActiveLineGutter(),
      highlightSpecialChars(),
      history(),
      drawSelection(),
      dropCursor(),
      EditorState.allowMultipleSelections.of(true),
      indentUnit.of('    '),
      EditorState.tabSize.of(4),
      bracketMatching(),
      highlightActiveLine(),
      highlightSelectionMatches(),
      search({ top: true }),
      markdown(),
      syntaxHighlighting(highlight),
      EditorView.lineWrapping,
      placeholder('Начните писать Markdown…'),
      blockMarks,
      lineMarks,
      markDecorations,
      markGutter,
      theme,
      EditorView.contentAttributes.of({ 'aria-label': 'Исходный текст страницы (Markdown)', spellcheck: 'true', lang: 'ru' }),
      keymap.of([
        { key: 'Mod-b', run: commands.bold },
        { key: 'Mod-i', run: commands.italic },
        { key: 'Mod-k', run: commands.link },
        { key: 'Mod-e', run: commands.code },
        { key: 'Mod-s', run: () => (onSave?.(), true), preventDefault: true },
        { key: 'Mod-Enter', run: () => (onSubmit?.(), true) },
        ...searchKeymap,
        ...historyKeymap,
        ...defaultKeymap,
        indentWithTab,
      ]),
      EditorView.updateListener.of((u) => {
        if (u.docChanged) onChange?.(u.state.doc.toString(), u);
      }),
      EditorView.domEventHandlers({
        paste(e) {
          const files = [...(e.clipboardData?.files || [])].filter((f) => f.type.startsWith('image/'));
          if (!files.length) return false;
          e.preventDefault();
          onPasteFiles?.(files);
          return true;
        },
        drop(e, view) {
          const files = [...(e.dataTransfer?.files || [])].filter((f) => f.type.startsWith('image/'));
          if (!files.length) return false;
          e.preventDefault();
          const pos = view.posAtCoords({ x: e.clientX, y: e.clientY });
          if (pos != null) view.dispatch({ selection: { anchor: pos } });
          onPasteFiles?.(files);
          return true;
        },
      }),
    ],
  });
  return new EditorView({ state, parent });
}

/** Заменяет весь текст (например, после восстановления черновика). */
export function setDoc(view, text) {
  view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text }, selection: { anchor: 0 } });
}

/** Ищет фрагмент из отрисованной страницы в Markdown и выделяет его. */
export function revealQuote(view, quote) {
  const doc = view.state.doc.toString();
  let from = -1;
  let len = 0;
  const exact = doc.indexOf(quote);
  if (exact >= 0) {
    from = exact;
    len = quote.length;
  } else {
    // между словами в исходнике может быть разметка: **, `, [](…), перенос строки
    const words = quote.split(/\s+/).filter(Boolean).slice(0, 12).map((w) => w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
    for (let n = words.length; n >= 2 && from < 0; n--) {
      const re = new RegExp(words.slice(0, n).join('[^\\n]{0,40}?\\s*[^\\n]{0,40}?'), 'i');
      const m = re.exec(doc);
      if (m) {
        from = m.index;
        len = m[0].length;
      }
    }
  }
  if (from < 0) return false;
  view.dispatch({
    selection: EditorSelection.range(from, from + len),
    effects: EditorView.scrollIntoView(from, { y: 'center' }),
  });
  view.focus();
  return true;
}

export function gotoLine(view, n) {
  const line = view.state.doc.line(Math.min(Math.max(1, n), view.state.doc.lines));
  view.dispatch({ selection: { anchor: line.from, head: line.to }, effects: EditorView.scrollIntoView(line.from, { y: 'center' }) });
  view.focus();
}

/** Номер первой видимой строки (с 0) — для прокрутки превью. */
export function topVisibleLine(view) {
  const block = view.lineBlockAtHeight(view.scrollDOM.scrollTop + 4);
  return view.state.doc.lineAt(block.from).number - 1;
}
