// Превью страницы в стилях Material: Markdown → HTML → DOMPurify → .md-typeset.

import MarkdownIt from 'markdown-it';
import DOMPurify from 'dompurify';
import { wikiMarkdown } from './mdext.js';
import { pageUrlPath, resolveRelative } from '../../shared/paths.js';

const md = wikiMarkdown(new MarkdownIt({ html: true, linkify: true, typographer: false }));

DOMPurify.addHook('uponSanitizeAttribute', (node, data) => {
  // style разрешаем только безопасный (без url и expression)
  if (data.attrName === 'style' && /url\(|expression|@import/i.test(data.attrValue)) data.keepAttr = false;
});

export function renderMarkdown(src) {
  return DOMPurify.sanitize(md.render(src), {
    ADD_ATTR: ['data-line', 'data-tabs', 'target', 'open', 'checked', 'for', 'name'],
    ADD_TAGS: ['details', 'summary'],
    FORBID_TAGS: ['style', 'form', 'iframe', 'object', 'embed', 'script'],
  });
}

/**
 * Рисует превью и чинит ссылки: относительные пути из Markdown → адреса сайта,
 * картинки, ещё не отправленные в репозиторий, → blob: из памяти.
 */
export function renderInto(el, src, { pagePath, siteRoot, pendingImages }) {
  el.innerHTML = renderMarkdown(src);
  const root = new URL(siteRoot, location.href);
  for (const img of el.querySelectorAll('img[src]')) {
    const s = img.getAttribute('src');
    if (/^(https?:|data:|blob:)/i.test(s)) continue;
    const repoPath = resolveRelative(pagePath, s.split('#')[0]);
    if (pendingImages?.has(repoPath)) img.src = pendingImages.get(repoPath).url;
    else if (repoPath.startsWith('docs/')) img.src = new URL(repoPath.slice(5), root).href;
    img.loading = 'lazy';
  }
  for (const a of el.querySelectorAll('a[href]')) {
    const href = a.getAttribute('href');
    if (href.startsWith('#')) {
      a.addEventListener('click', (e) => {
        e.preventDefault();
        const target = el.querySelector(`[id="${CSS.escape(decodeURIComponent(href.slice(1)))}"]`);
        target?.scrollIntoView({ block: 'start', behavior: 'smooth' });
      });
      continue;
    }
    if (!/^(https?:|mailto:)/i.test(href)) {
      const [file, hash] = href.split('#');
      const repoPath = resolveRelative(pagePath, file);
      if (repoPath.endsWith('.md')) a.href = new URL(pageUrlPath(repoPath), root).href + (hash ? `#${hash}` : '');
      else if (repoPath.startsWith('docs/')) a.href = new URL(repoPath.slice(5), root).href;
    }
    a.target = '_blank';
    a.rel = 'noopener';
  }
}

/** Элемент превью, ближайший к строке исходника (для синхронной прокрутки). */
export function elementForLine(el, line) {
  let best = null;
  for (const node of el.querySelectorAll('[data-line]')) {
    const l = Number(node.getAttribute('data-line'));
    if (l <= line) best = node;
    else break;
  }
  return best;
}
