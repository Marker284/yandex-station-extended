// Плагины markdown-it под расширения вики (pymdownx / Material), чтобы превью
// выглядело как сайт: admonition (!!!), details (???), вкладки (===), attr_list,
// клавиши (++ctrl+c++), иконки (:material-…:), номера строк исходника для синхронизации.

const ADMONITION = /^(!!!|\?\?\?\+?)\s+([\w-]+)(?:\s+"(.*)")?\s*$/;
const TAB = /^===(!|\+)?\s+"(.*)"\s*$/;

const escapeHtml = (s) =>
  String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

function lineText(state, line) {
  return state.src.slice(state.bMarks[line] + state.tShift[line], state.eMarks[line]);
}
const isEmpty = (state, line) => state.bMarks[line] + state.tShift[line] >= state.eMarks[line];

/** Конец блока с отступом +4 от начала `start`: [start+1, end). */
function indentedEnd(state, start, endLine) {
  let next = start + 1;
  while (next < endLine) {
    if (isEmpty(state, next)) {
      next++;
      continue;
    }
    if (state.sCount[next] - state.blkIndent < 4) break;
    next++;
  }
  let last = next;
  while (last > start + 1 && isEmpty(state, last - 1)) last--;
  return { next, last };
}

function tokenizeInner(state, from, to, type) {
  const old = { parent: state.parentType, max: state.lineMax, indent: state.blkIndent };
  state.parentType = type;
  state.lineMax = to;
  state.blkIndent += 4;
  state.md.block.tokenize(state, from, to);
  state.parentType = old.parent;
  state.lineMax = old.max;
  state.blkIndent = old.indent;
}

function html(state, content, line) {
  const t = state.push('html_block', '', 0);
  t.content = content;
  t.map = [line, line + 1];
  return t;
}

function titleCase(type) {
  const map = {
    note: 'Note', abstract: 'Abstract', info: 'Info', tip: 'Tip', success: 'Success', question: 'Question',
    warning: 'Warning', failure: 'Failure', danger: 'Danger', bug: 'Bug', example: 'Example', quote: 'Quote',
  };
  return map[type] || type.charAt(0).toUpperCase() + type.slice(1);
}

function admonition(state, startLine, endLine, silent) {
  if (state.sCount[startLine] - state.blkIndent >= 4) return false;
  const m = ADMONITION.exec(lineText(state, startLine));
  if (!m) return false;
  if (silent) return true;
  const [, marker, type, title] = m;
  const { next, last } = indentedEnd(state, startLine, endLine);
  const cls = `admonition ${escapeHtml(type)}`;
  const heading = title === undefined ? titleCase(type) : title;
  if (marker === '!!!') {
    html(state, `<div class="${cls}">${heading ? `<p class="admonition-title">${escapeHtml(heading)}</p>` : ''}\n`, startLine);
    tokenizeInner(state, startLine + 1, last, 'admonition');
    html(state, '</div>\n', last);
  } else {
    html(state, `<details class="${escapeHtml(type)}"${marker === '???+' ? ' open' : ''}><summary>${escapeHtml(heading || titleCase(type))}</summary>\n`, startLine);
    tokenizeInner(state, startLine + 1, last, 'admonition');
    html(state, '</details>\n', last);
  }
  state.line = next;
  return true;
}

let tabSetCounter = 0;

function tabbed(state, startLine, endLine, silent) {
  if (state.sCount[startLine] - state.blkIndent >= 4) return false;
  if (!TAB.test(lineText(state, startLine))) return false;
  if (silent) return true;
  const tabs = [];
  let line = startLine;
  while (line < endLine) {
    const m = TAB.exec(lineText(state, line));
    if (!m || state.sCount[line] !== state.sCount[startLine] || (tabs.length && m[1] === '!')) break;
    const { next, last } = indentedEnd(state, line, endLine);
    tabs.push({ title: m[2], from: line + 1, to: last, selected: m[1] === '+' });
    line = next;
    // между вкладками допускаются пустые строки
    let peek = line;
    while (peek < endLine && isEmpty(state, peek)) peek++;
    if (peek < endLine && TAB.test(lineText(state, peek)) && !/^===!/.test(lineText(state, peek))) line = peek;
    else break;
  }
  const id = ++tabSetCounter;
  const checked = Math.max(0, tabs.findIndex((t) => t.selected));
  const inputs = tabs
    .map((t, i) => `<input${i === checked ? ' checked="checked"' : ''} id="__tabbed_${id}_${i + 1}" name="__tabbed_${id}" type="radio">`)
    .join('');
  const labels = tabs.map((t, i) => `<label for="__tabbed_${id}_${i + 1}">${escapeHtml(t.title)}</label>`).join('');
  html(state, `<div class="tabbed-set tabbed-alternate" data-tabs="${id}:${tabs.length}">${inputs}<div class="tabbed-labels">${labels}</div>\n<div class="tabbed-content">\n`, startLine);
  for (const t of tabs) {
    html(state, '<div class="tabbed-block">\n', t.from - 1);
    tokenizeInner(state, t.from, t.to, 'tabbed');
    html(state, '</div>\n', t.to);
  }
  html(state, '</div></div>\n', line);
  state.line = line;
  return true;
}

/** { #id .class key=value } в конце заголовка, абзаца или после картинки/ссылки. */
const ATTRS = /\s*\{:?\s*((?:[#.][\w-]+|[\w-]+=(?:"[^"]*"|'[^']*'|[^\s}]+))(?:\s+(?:[#.][\w-]+|[\w-]+=(?:"[^"]*"|'[^']*'|[^\s}]+)))*)\s*\}\s*$/;

function parseAttrs(str) {
  const out = { id: null, classes: [], other: [] };
  for (const part of str.match(/[#.][\w-]+|[\w-]+=(?:"[^"]*"|'[^']*'|[^\s}]+)/g) || []) {
    if (part[0] === '#') out.id = part.slice(1);
    else if (part[0] === '.') out.classes.push(part.slice(1));
    else {
      const i = part.indexOf('=');
      out.other.push([part.slice(0, i), part.slice(i + 1).replace(/^["']|["']$/g, '')]);
    }
  }
  return out;
}

function applyAttrs(token, a) {
  if (a.id) token.attrSet('id', a.id);
  if (a.classes.length) token.attrJoin('class', a.classes.join(' '));
  for (const [k, v] of a.other) if (/^(width|height|title|align|alt)$/.test(k)) token.attrSet(k, v);
}

function attrList(state) {
  const tokens = state.tokens;
  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i];
    if (t.type !== 'inline' || !t.children?.length) continue;
    // после картинок и ссылок внутри строки: ![](x){ width=300 }
    for (let j = 1; j < t.children.length; j++) {
      const c = t.children[j];
      const prev = t.children[j - 1];
      if (c.type !== 'text' || !(prev.type === 'image' || prev.type === 'link_close')) continue;
      const m = /^\{:?\s*([^}]*)\}/.exec(c.content);
      if (!m || !/[#.=]/.test(m[1])) continue;
      let target = prev;
      if (prev.type === 'link_close') {
        for (let k = j - 1; k >= 0; k--) if (t.children[k].type === 'link_open') { target = t.children[k]; break; }
      }
      applyAttrs(target, parseAttrs(m[1]));
      c.content = c.content.slice(m[0].length);
    }
    // в конце блока: ## Заголовок { #id }
    const last = t.children[t.children.length - 1];
    if (last.type !== 'text') continue;
    const m = ATTRS.exec(last.content);
    const open = tokens[i - 1];
    if (!m || !open || !/_open$/.test(open.type)) continue;
    applyAttrs(open, parseAttrs(m[1]));
    last.content = last.content.slice(0, m.index);
  }
}

/** ++ctrl+alt+del++ → клавиши */
function keys(state, silent) {
  const src = state.src.slice(state.pos);
  const m = /^\+\+([\w-]+(?:\+[\w-]+)*)\+\+/.exec(src);
  if (!m) return false;
  if (!silent) {
    const t = state.push('html_inline', '', 0);
    const names = m[1].split('+').map((k) => `<kbd class="key-${escapeHtml(k.toLowerCase())}">${escapeHtml(k.length === 1 ? k.toUpperCase() : k.charAt(0).toUpperCase() + k.slice(1))}</kbd>`);
    t.content = `<span class="keys">${names.join('<span>+</span>')}</span>`;
  }
  state.pos += m[0].length;
  return true;
}

/** :material-cog: и т.п. — иконки сервера нет в браузере, показываем значок-заглушку. */
function iconShortcode(state, silent) {
  const m = /^:((?:material|fontawesome|octicons|simple)-[a-z0-9-]+):/.exec(state.src.slice(state.pos));
  if (!m) return false;
  if (!silent) {
    const t = state.push('html_inline', '', 0);
    t.content = `<span class="twemoji yse-icon-shortcode" title=":${escapeHtml(m[1])}:"></span>`;
  }
  state.pos += m[0].length;
  return true;
}

/** Номер строки исходника на блоках — для синхронной прокрутки и перехода к фрагменту. */
function sourceLines(state) {
  for (const t of state.tokens) {
    if (t.map && t.nesting >= 0 && t.level === 0 && t.type !== 'inline') t.attrSet('data-line', String(t.map[0]));
  }
}

export function wikiMarkdown(md) {
  md.block.ruler.before('fence', 'admonition', admonition, { alt: ['paragraph', 'reference', 'blockquote', 'list'] });
  md.block.ruler.before('fence', 'tabbed', tabbed, { alt: ['paragraph', 'reference', 'blockquote', 'list'] });
  md.inline.ruler.before('emphasis', 'keys', keys);
  md.inline.ruler.before('emphasis', 'icon_shortcode', iconShortcode);
  md.core.ruler.after('inline', 'attr_list', attrList);
  md.core.ruler.push('source_lines', sourceLines);

  // блоки кода — как у Material (обёртка .highlight, язык в классе)
  md.renderer.rules.fence = (tokens, idx) => {
    const t = tokens[idx];
    const info = t.info.trim();
    const lang = (/^[\w+#-]+/.exec(info) || [''])[0];
    const title = /title="([^"]*)"/.exec(info);
    const line = t.attrGet('data-line');
    return `<div class="${lang ? `language-${escapeHtml(lang)} ` : ''}highlight"${line ? ` data-line="${line}"` : ''}>${title ? `<span class="filename">${escapeHtml(title[1])}</span>` : ''}<pre><span></span><code>${escapeHtml(t.content)}</code></pre></div>\n`;
  };

  // html_block с data-line тоже нужен для прокрутки: оборачиваем только открывающие
  const htmlBlock = md.renderer.rules.html_block;
  md.renderer.rules.html_block = (tokens, idx, ...rest) => {
    const t = tokens[idx];
    const out = htmlBlock ? htmlBlock(tokens, idx, ...rest) : t.content;
    // атрибут markdown у <div markdown> — служебный
    return out.replace(/(<[a-z][^>]*?)\s+markdown(?:="[^"]*")?(\s*>)/gi, '$1$2');
  };
  return md;
}
