// Пути страниц, транслит имён файлов и правка `nav` в mkdocs.yml.
// Общий код для браузера и Worker.

export const DOCS_DIR = 'docs/';
export const IMAGES_DIR = 'docs/assets/images/';
export const MAX_PAGE_BYTES = 300 * 1024;
export const MAX_IMAGE_BYTES = 2 * 1024 * 1024;
export const IMAGE_TYPES = { png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', webp: 'image/webp', gif: 'image/gif' };

const SEGMENT = /^[a-z0-9][a-z0-9._-]*$/;

/** Путь страницы внутри репозитория: docs/<dir>/<name>.md, только латиница. */
export function isValidPagePath(path) {
  if (typeof path !== 'string' || !path.startsWith(DOCS_DIR) || !path.endsWith('.md')) return false;
  const rel = path.slice(DOCS_DIR.length);
  const parts = rel.split('/');
  if (parts.length > 4) return false;
  return parts.every((p) => SEGMENT.test(p) && p !== '..' && !p.includes('..'));
}

/** Путь картинки: docs/assets/images/<name>.<png|jpg|webp|gif>. */
export function isValidImagePath(path) {
  if (typeof path !== 'string' || !path.startsWith(IMAGES_DIR)) return false;
  const name = path.slice(IMAGES_DIR.length);
  if (!SEGMENT.test(name) || name.includes('..') || name.includes('/')) return false;
  const ext = name.split('.').pop().toLowerCase();
  return ext in IMAGE_TYPES;
}

/** docs/start/ssh.md → start/ssh/ ; docs/index.md → '' ; docs/recipes/index.md → recipes/ */
export function pageUrlPath(path) {
  let rel = path.slice(DOCS_DIR.length).replace(/\.md$/, '');
  if (rel === 'index') return '';
  if (rel.endsWith('/index')) rel = rel.slice(0, -'index'.length);
  else rel += '/';
  return rel;
}

/** Путь до файла из адреса страницы: /start/ssh/ → docs/start/ssh.md (без проверки index). */
export function pathFromUrl(pathname) {
  const clean = pathname.replace(/^\/+|\/+$/g, '');
  if (!clean) return 'docs/index.md';
  return `${DOCS_DIR}${clean}.md`;
}

/** Относительная ссылка из одной страницы на другой файл репозитория (как пишут в Markdown вики). */
export function relativeLink(fromPage, toFile) {
  const from = fromPage.split('/').slice(0, -1);
  const to = toFile.split('/');
  let i = 0;
  while (i < from.length && i < to.length - 1 && from[i] === to[i]) i++;
  return [...Array(from.length - i).fill('..'), ...to.slice(i)].join('/');
}

/** Разрешает относительную ссылку из Markdown-файла в путь репозитория. */
export function resolveRelative(fromPage, href) {
  const parts = fromPage.split('/').slice(0, -1);
  for (const seg of href.split('/')) {
    if (seg === '..') parts.pop();
    else if (seg !== '.' && seg !== '') parts.push(seg);
  }
  return parts.join('/');
}

const TRANSLIT = {
  а: 'a', б: 'b', в: 'v', г: 'g', д: 'd', е: 'e', ё: 'e', ж: 'zh', з: 'z', и: 'i', й: 'y', к: 'k',
  л: 'l', м: 'm', н: 'n', о: 'o', п: 'p', р: 'r', с: 's', т: 't', у: 'u', ф: 'f', х: 'h', ц: 'ts',
  ч: 'ch', ш: 'sh', щ: 'sch', ъ: '', ы: 'y', ь: '', э: 'e', ю: 'yu', я: 'ya',
  ә: 'a', ғ: 'g', қ: 'k', ң: 'n', ө: 'o', ұ: 'u', ү: 'u', һ: 'h', і: 'i',
};

/** «Своя LLM вместо Алисы» → svoya-llm-vmesto-alisy */
export function slugify(title) {
  return title
    .toLowerCase()
    .split('')
    .map((c) => (c in TRANSLIT ? TRANSLIT[c] : c))
    .join('')
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60)
    .replace(/-+$/, '');
}

/** Безопасное имя картинки: «Скрин 1.PNG» → skrin-1.png */
export function imageFileName(original, fallback = 'image') {
  const dot = original.lastIndexOf('.');
  const ext = (dot > 0 ? original.slice(dot + 1) : '').toLowerCase();
  const base = slugify(dot > 0 ? original.slice(0, dot) : original) || fallback;
  return `${base}.${ext in IMAGE_TYPES ? ext : 'png'}`;
}

// ---------- mkdocs.yml: разделы и вставка страницы в nav ----------

function navBlock(lines) {
  const start = lines.findIndex((l) => /^nav:\s*$/.test(l));
  if (start === -1) return null;
  let end = start + 1;
  while (end < lines.length && (lines[end].trim() === '' || /^\s/.test(lines[end]))) end++;
  return { start, end };
}

function unquote(s) {
  s = s.trim();
  if ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'"))) return s.slice(1, -1);
  return s;
}

/**
 * Разделы верхнего уровня nav, в которые можно добавить страницу.
 * @returns {{ title: string, dir: string }[]}
 */
export function navSections(yml) {
  const lines = yml.split('\n');
  const block = navBlock(lines);
  if (!block) return [];
  const sections = [];
  let current = null;
  for (let i = block.start + 1; i < block.end; i++) {
    const l = lines[i];
    const top = /^  - (.+?):\s*$/.exec(l);
    if (top) {
      current = { title: unquote(top[1]), dir: null };
      sections.push(current);
      continue;
    }
    if (/^  - /.test(l)) {
      current = null;
      continue;
    }
    if (current && !current.dir) {
      const m = /([a-z0-9_-]+)\/[a-z0-9._/-]+\.md\s*$/.exec(l);
      if (m) current.dir = m[1];
    }
  }
  return sections.filter((s) => s.dir);
}

function yamlKey(title) {
  // Перевод строки и управляющие символы всегда в кавычки: иначе заголовок
  // с \n вставил бы в nav лишний пункт.
  return /^[^\s"'#&*!|>%@`{}[\],?:-][^:#]*$/.test(title) && !/\s$/.test(title) && !/[\u0000-\u001f]/.test(title)
    ? title
    : JSON.stringify(title);
}

/**
 * Добавляет страницу в конец раздела nav. Текст файла меняется построчно,
 * остальной mkdocs.yml (комментарии, порядок) остаётся как был.
 * @returns {string | null} новый текст или null, если раздел не найден
 */
export function addToNav(yml, sectionTitle, pageTitle, pagePath) {
  const lines = yml.split('\n');
  const block = navBlock(lines);
  if (!block) return null;
  const rel = pagePath.slice(DOCS_DIR.length);
  let headerIdx = -1;
  for (let i = block.start + 1; i < block.end; i++) {
    const m = /^  - (.+?):\s*$/.exec(lines[i]);
    if (m && unquote(m[1]) === sectionTitle) {
      headerIdx = i;
      break;
    }
  }
  if (headerIdx === -1) return null;
  let last = headerIdx;
  let indent = null;
  for (let i = headerIdx + 1; i < block.end; i++) {
    const l = lines[i];
    if (l.trim() === '') continue;
    const ind = /^(\s*)/.exec(l)[1].length;
    if (ind <= 2) break;
    if (indent === null && /^\s*- /.test(l)) indent = ind;
    last = i;
  }
  if (lines.some((l) => l.trim().endsWith(` ${rel}`) || l.trim() === `- ${rel}`)) return yml;
  const pad = ' '.repeat(indent ?? 6);
  lines.splice(last + 1, 0, `${pad}- ${yamlKey(pageTitle)}: ${rel}`);
  return lines.join('\n');
}
