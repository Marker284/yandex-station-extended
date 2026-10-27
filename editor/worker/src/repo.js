// Операции с репозиторием вики от имени пользователя: чтение, форк, коммит, PR.

import { enc } from './github.js';
import { b64ToUtf8, gitBlobSha, randomId, utf8ToB64 } from './crypto.js';
import { scanChange, hasBlocking } from '../../shared/scan.js';
import {
  IMAGE_TYPES,
  MAX_IMAGE_BYTES,
  MAX_PAGE_BYTES,
  addToNav,
  isValidImagePath,
  isValidPagePath,
  navSections,
  pageUrlPath,
} from '../../shared/paths.js';

export class HttpError extends Error {
  constructor(status, code, message, extra = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.extra = extra;
  }
}

export const BRANCH_PREFIX = 'wiki/';

export function upstream(env) {
  return {
    owner: env.UPSTREAM_OWNER || 'Marker284',
    repo: env.UPSTREAM_REPO || 'yandex-station-extended',
    branch: env.UPSTREAM_BRANCH || 'main',
    get full() {
      return `${this.owner}/${this.repo}`;
    },
  };
}

/** Файл из репозитория: { content, sha } или null. */
export async function readFile(gh, fullName, path, ref) {
  const data = await gh.get(`/repos/${fullName}/contents/${enc(path)}?ref=${encodeURIComponent(ref)}`, { allow404: true });
  if (!data) return null;
  if (Array.isArray(data) || data.type !== 'file') throw new HttpError(400, 'not-a-file', 'Это не файл');
  let content;
  if (data.content && data.encoding === 'base64') content = b64ToUtf8(data.content);
  else {
    // файлы > 1 МБ приходят без content — берём blob
    const blob = await gh.get(`/repos/${fullName}/git/blobs/${data.sha}`);
    content = b64ToUtf8(blob.content);
  }
  return { content, sha: data.sha };
}

export async function getSections(gh, env) {
  const up = upstream(env);
  const yml = await readFile(gh, up.full, 'mkdocs.yml', up.branch);
  return yml ? navSections(yml.content) : [];
}

/** Открытый PR пользователя, созданный редактором. */
async function getOwnPr(gh, up, login, number) {
  const pr = await gh.get(`/repos/${up.full}/pulls/${Number(number)}`, { allow404: true });
  if (!pr || pr.user?.login?.toLowerCase() !== login.toLowerCase()) {
    throw new HttpError(404, 'pr-not-found', 'PR не найден или он не ваш');
  }
  if (pr.state !== 'open') throw new HttpError(409, 'pr-closed', 'PR уже закрыт или влит');
  if (!pr.head?.ref?.startsWith(BRANCH_PREFIX) || !pr.head.repo) {
    throw new HttpError(409, 'pr-foreign', 'Этот PR создан не через редактор');
  }
  return pr;
}

/** Файл для редактора: из main или из ветки вашего PR. */
export async function loadForEdit(gh, env, login, path, prNumber) {
  if (!isValidPagePath(path)) throw new HttpError(400, 'bad-path', 'Недопустимый путь страницы');
  const up = upstream(env);
  if (prNumber) {
    const pr = await getOwnPr(gh, up, login, prNumber);
    const file = await readFile(gh, pr.head.repo.full_name, path, pr.head.sha);
    const base = await readFile(gh, up.full, path, up.branch);
    return {
      path,
      exists: !!file,
      content: file?.content ?? '',
      sha: file?.sha ?? null,
      // базовая версия main — для подсчёта «+/−» и проверки только своих строк
      original: base?.content ?? '',
      pr: { number: pr.number, url: pr.html_url, title: pr.title },
    };
  }
  const file = await readFile(gh, up.full, path, up.branch);
  return { path, exists: !!file, content: file?.content ?? '', sha: file?.sha ?? null, original: file?.content ?? '' };
}

/** Открытые PR пользователя из редактора, которые меняют этот файл. */
export async function listOwnPrs(gh, env, login, path) {
  const up = upstream(env);
  const pulls = await gh.get(`/repos/${up.full}/pulls?state=open&per_page=100`);
  const mine = pulls.filter(
    (p) => p.user?.login?.toLowerCase() === login.toLowerCase() && p.head?.ref?.startsWith(BRANCH_PREFIX),
  );
  const out = [];
  for (const p of mine.slice(0, 10)) {
    if (path) {
      const files = await gh.get(`/repos/${up.full}/pulls/${p.number}/files?per_page=100`);
      if (!files.some((f) => f.filename === path)) continue;
    }
    out.push({ number: p.number, title: p.title, url: p.html_url, updated: p.updated_at });
  }
  return out;
}

/** Статус PR для экрана «Готово». */
export async function prStatus(gh, env, number) {
  const up = upstream(env);
  const pr = await gh.get(`/repos/${up.full}/pulls/${Number(number)}`, { allow404: true });
  if (!pr) throw new HttpError(404, 'pr-not-found', 'PR не найден');
  const sha = pr.head.sha;
  const [runs, combined] = await Promise.all([
    gh.get(`/repos/${up.full}/commits/${sha}/check-runs?per_page=50`).catch(() => ({ check_runs: [] })),
    gh.get(`/repos/${up.full}/commits/${sha}/status`).catch(() => ({ statuses: [] })),
  ]);
  const checks = [
    ...(runs.check_runs || []).map((r) => ({
      name: r.name,
      state: r.status !== 'completed' ? 'pending' : r.conclusion === 'success' || r.conclusion === 'skipped' || r.conclusion === 'neutral' ? 'success' : 'failure',
      url: r.html_url,
    })),
    ...(combined.statuses || []).map((s) => ({ name: s.context, state: s.state === 'error' ? 'failure' : s.state, url: s.target_url })),
  ];
  let checksState = 'none';
  if (checks.length) {
    if (checks.some((c) => c.state === 'failure')) checksState = 'failure';
    else if (checks.some((c) => c.state === 'pending')) checksState = 'pending';
    else checksState = 'success';
  }
  return {
    number: pr.number,
    url: pr.html_url,
    title: pr.title,
    state: pr.merged_at ? 'merged' : pr.state,
    reviewComments: pr.review_comments + pr.comments,
    checks,
    checksState,
  };
}

const MAGIC = {
  png: [0x89, 0x50, 0x4e, 0x47],
  jpg: [0xff, 0xd8, 0xff],
  jpeg: [0xff, 0xd8, 0xff],
  gif: [0x47, 0x49, 0x46, 0x38],
  webp: [0x52, 0x49, 0x46, 0x46],
};

function checkImage(img) {
  if (!isValidImagePath(img.path)) throw new HttpError(400, 'bad-image-path', `Недопустимый путь картинки: ${img.path}`);
  let bin;
  try {
    bin = atob(img.base64);
  } catch {
    throw new HttpError(400, 'bad-image', 'Картинка повреждена');
  }
  if (bin.length > MAX_IMAGE_BYTES) throw new HttpError(413, 'image-too-big', 'Картинка больше 2 МБ');
  const ext = img.path.split('.').pop().toLowerCase();
  const magic = MAGIC[ext];
  if (!(ext in IMAGE_TYPES) || !magic.every((b, i) => bin.charCodeAt(i) === b)) {
    throw new HttpError(400, 'bad-image', `Файл ${img.path} — не ${ext.toUpperCase()}`);
  }
}

function prBody({ description, tested, path, isNew, login, siteUrl }) {
  const url = `${siteUrl.replace(/\/$/, '')}/${pageUrlPath(path)}`;
  return [
    '## Что добавлено или исправлено',
    '',
    description?.trim() || '_Автор не оставил описания._',
    '',
    `Страница: ${isNew ? 'новая, ' : ''}[\`${path}\`](${url})`,
    '',
    '## На чём проверено',
    '',
    tested?.trim() || '_не указано_',
    '',
    '## Чек-лист',
    '',
    '- [x] нет ключей, токенов, MAC-адресов (проверено редактором)',
    '- [ ] `mkdocs build` проходит (проверит CI)',
    '- [ ] факты и команды проверены мейнтейнером',
    '',
    `<sub>Отправлено через [редактор вики](${siteUrl.replace(/\/$/, '')}/edit/) пользователем @${login}.</sub>`,
  ].join('\n');
}

async function sleep(ms) {
  await new Promise((r) => setTimeout(r, ms));
}

/** Репозиторий, куда пушить ветку: сам upstream (есть права) или форк пользователя. */
async function headRepo(gh, up, opts) {
  const repo = await gh.get(`/repos/${up.full}`);
  if (repo.permissions?.push) return { full: up.full, owner: up.owner, isFork: false };
  const fork = await gh.post(`/repos/${up.full}/forks`, { default_branch_only: true });
  // форк создаётся асинхронно — ждём, пока появится
  for (let i = 0; i < (opts.forkWaitTries ?? 20); i++) {
    const ok = await gh.get(`/repos/${fork.full_name}`, { allow404: true });
    if (ok) break;
    await sleep(opts.forkWaitMs ?? 1500);
  }
  return { full: fork.full_name, owner: fork.owner.login, isFork: true };
}

/**
 * Отправка правки: проверки → форк → коммит (страница, картинки, nav) → PR.
 * @param {import('./github.js').GitHub} gh
 */
export async function submit(gh, env, user, input, opts = {}) {
  const up = upstream(env);
  const page = input?.page;
  if (!page || !isValidPagePath(page.path)) throw new HttpError(400, 'bad-path', 'Недопустимый путь страницы');
  if (typeof page.content !== 'string') throw new HttpError(400, 'bad-request', 'Нет текста страницы');
  if (new TextEncoder().encode(page.content).length > MAX_PAGE_BYTES) {
    throw new HttpError(413, 'page-too-big', 'Страница больше 300 КБ');
  }
  const images = Array.isArray(input.images) ? input.images : [];
  if (images.length > 10) throw new HttpError(400, 'too-many-images', 'Не больше 10 картинок за раз');
  images.forEach(checkImage);
  const title = String(input.title || '').trim().slice(0, 120);
  if (!title) throw new HttpError(400, 'no-title', 'Укажите название правки');
  const isNew = !!input.newPage;

  // 1. Где строим коммит и от какой версии
  let pr = null;
  let target;
  let branch;
  let parentSha;
  if (input.pr) {
    pr = await getOwnPr(gh, up, user.login, input.pr);
    target = { full: pr.head.repo.full_name, owner: pr.head.repo.owner.login, isFork: pr.head.repo.full_name !== up.full };
    branch = pr.head.ref;
    const ref = await gh.get(`/repos/${target.full}/git/ref/heads/${enc(branch)}`);
    parentSha = ref.object.sha;
  } else {
    const ref = await gh.get(`/repos/${up.full}/git/ref/heads/${enc(up.branch)}`);
    parentSha = ref.object.sha;
  }

  // 2. Конфликт: страница поменялась, пока человек правил
  const current = await readFile(gh, pr ? target.full : up.full, page.path, parentSha);
  if (isNew && !pr && current) throw new HttpError(409, 'exists', 'Страница с таким адресом уже есть');
  if (!isNew && !current) throw new HttpError(404, 'not-found', 'Страница не найдена — возможно, её переименовали');
  if (current && page.baseSha && current.sha !== page.baseSha) {
    throw new HttpError(409, 'conflict', 'Страницу изменили, пока вы её правили', {
      current: { content: current.content, sha: current.sha },
    });
  }

  // 3. Персональные данные — только в добавленных строках
  const base = pr ? (await readFile(gh, up.full, page.path, up.branch))?.content ?? '' : current?.content ?? '';
  const findings = scanChange(base, page.content);
  if (hasBlocking(findings)) {
    throw new HttpError(422, 'sensitive', 'В правке похоже на ключи, токены или MAC-адреса', { findings });
  }
  if (current && current.content === page.content && !images.length) {
    throw new HttpError(400, 'no-changes', 'В правке нет изменений');
  }

  // 4. Новая страница — пункт в nav
  const tree = [{ path: page.path, mode: '100644', type: 'blob', content: page.content }];
  if (isNew) {
    const sectionTitle = String(input.newPage.section || '');
    const pageTitle = String(input.newPage.title || '').trim().slice(0, 80);
    if (!pageTitle) throw new HttpError(400, 'no-title', 'Укажите заголовок страницы');
    const yml = await readFile(gh, pr ? target.full : up.full, 'mkdocs.yml', parentSha);
    const section = navSections(yml.content).find((s) => s.title === sectionTitle);
    if (!section) throw new HttpError(400, 'bad-section', 'Нет такого раздела');
    if (!page.path.startsWith(`docs/${section.dir}/`)) throw new HttpError(400, 'bad-path', 'Путь не в папке раздела');
    const nextYml = addToNav(yml.content, section.title, pageTitle, page.path);
    if (nextYml !== yml.content) tree.push({ path: 'mkdocs.yml', mode: '100644', type: 'blob', content: nextYml });
  }

  // 5. Куда пушить
  if (!pr) target = await headRepo(gh, up, opts);

  // 6. Картинки — блобами (бинарные данные); существующие не перезаписываем
  for (const img of images) {
    const taken = await gh.get(`/repos/${up.full}/contents/${enc(img.path)}?ref=${encodeURIComponent(up.branch)}`, { allow404: true });
    if (taken) throw new HttpError(409, 'image-exists', `Картинка ${img.path.slice(5)} уже есть — переименуйте файл`);
  }
  for (const img of images) {
    const blob = await gh.post(`/repos/${target.full}/git/blobs`, { content: img.base64, encoding: 'base64' });
    tree.push({ path: img.path, mode: '100644', type: 'blob', sha: blob.sha });
  }

  // 7. Дерево и коммит поверх parentSha
  const parent = await gh.get(`/repos/${target.full}/git/commits/${parentSha}`).catch(async (e) => {
    if (e.status !== 404 && e.status !== 422) throw e;
    // форк отстал от upstream — синхронизируем и пробуем снова
    await gh.post(`/repos/${target.full}/merge-upstream`, { branch: up.branch }).catch(() => {});
    return gh.get(`/repos/${target.full}/git/commits/${parentSha}`);
  });
  const newTree = await gh.post(`/repos/${target.full}/git/trees`, { base_tree: parent.tree.sha, tree });
  const description = String(input.description || '').trim().slice(0, 4000);
  const message = `${title}\n\n${description ? `${description}\n\n` : ''}Отправлено через редактор вики.`;
  const commit = await gh.post(`/repos/${target.full}/git/commits`, {
    message,
    tree: newTree.sha,
    parents: [parentSha],
  });

  // 8. Ветка
  if (pr) {
    await gh.patch(`/repos/${target.full}/git/refs/heads/${enc(branch)}`, { sha: commit.sha, force: false });
    return { pr: { number: pr.number, url: pr.html_url, title: pr.title }, commit: commit.sha, updated: true, findings };
  }
  const name = page.path.slice('docs/'.length).replace(/\.md$/, '').replace(/[^a-z0-9]+/g, '-');
  branch = `${BRANCH_PREFIX}${name}-${randomId(6)}`;
  await gh.post(`/repos/${target.full}/git/refs`, { ref: `refs/heads/${branch}`, sha: commit.sha });

  // 9. Pull Request
  const created = await gh.post(`/repos/${up.full}/pulls`, {
    title,
    head: target.isFork ? `${target.owner}:${branch}` : branch,
    base: up.branch,
    body: prBody({
      description,
      tested: input.tested,
      path: page.path,
      isNew,
      login: user.login,
      siteUrl: env.SITE_URL || 'https://hackalice.me',
    }),
    ...(target.isFork ? { maintainer_can_modify: true } : {}),
  });
  return { pr: { number: created.number, url: created.html_url, title: created.title }, commit: commit.sha, updated: false, findings };
}

export { gitBlobSha };
