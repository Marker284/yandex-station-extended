import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { createFakeGitHub } from '../scripts/fake-github.mjs';
import { serveWorker } from '../scripts/node-adapter.mjs';
import { seal, open } from '../worker/src/crypto.js';

const mkdocs = readFileSync(new URL('../../mkdocs.yml', import.meta.url), 'utf8');
const SITE = 'http://127.0.0.1:8000';
const KEY = 'test-session-key-test-session-key-0123456789';
const UP = 'Marker284/yandex-station-extended';

let gh;
let base;
let worker;

const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
).toString('base64');

beforeAll(async () => {
  gh = createFakeGitHub({
    files: {
      'mkdocs.yml': mkdocs,
      'docs/start/ssh.md': '# SSH и обновления\n\nПосле root подключитесь по SSH.\n',
      'docs/recipes/index.md': '# Рецепты\n',
    },
  });
  const ghPort = await gh.listen();
  const env = {
    SITE_URL: 'https://hackalice.me',
    ALLOWED_ORIGINS: SITE,
    GITHUB_CLIENT_ID: 'cid',
    GITHUB_CLIENT_SECRET: 'secret',
    SESSION_KEY: KEY,
    GITHUB_API_BASE: `http://127.0.0.1:${ghPort}`,
    GITHUB_OAUTH_BASE: `http://127.0.0.1:${ghPort}`,
  };
  worker = await serveWorker(env, { port: 0, opts: { forkWaitMs: 1 } });
  base = `http://127.0.0.1:${worker.port}`;
});

afterAll(async () => {
  await gh.close();
  worker.server.close();
});

/** Проходит OAuth как пользователь и возвращает сессию. */
async function signIn(login = 'tester') {
  gh.setLogin(login);
  let res = await fetch(`${base}/auth/login?origin=${encodeURIComponent(SITE)}&mode=redirect&return=/edit/?path=x`, { redirect: 'manual' });
  expect(res.status).toBe(302);
  res = await fetch(res.headers.get('location'), { redirect: 'manual' }); // GitHub authorize
  res = await fetch(res.headers.get('location'), { redirect: 'manual' }); // наш callback
  const loc = new URL(res.headers.get('location'));
  expect(loc.origin).toBe(SITE);
  expect(loc.pathname).toBe('/edit/');
  return new URLSearchParams(loc.hash.slice(1)).get('yse-session');
}

const call = (session, path, init = {}) =>
  fetch(`${base}${path}`, {
    ...init,
    headers: { Origin: SITE, Authorization: `Bearer ${session}`, 'Content-Type': 'application/json', ...(init.headers || {}) },
  });

describe('crypto', () => {
  it('сессия не открывается как state и наоборот', async () => {
    const s = await seal(KEY, 'session', { t: 'x' }, 60);
    expect(await open(KEY, 'session', s)).toMatchObject({ t: 'x' });
    expect(await open(KEY, 'state', s)).toBeNull();
    expect(await open(`${KEY}x`, 'session', s)).toBeNull();
    expect(await open(KEY, 'session', `${s.slice(0, -2)}AA`)).toBeNull();
    const old = await seal(KEY, 'session', { t: 'x' }, -1);
    expect(await open(KEY, 'session', old)).toBeNull();
  });
});

describe('auth', () => {
  it('чужой origin не пускает', async () => {
    const res = await fetch(`${base}/auth/login?origin=https://evil.example`, { redirect: 'manual' });
    expect(res.status).toBe(400);
    const api = await fetch(`${base}/api/me`, { headers: { Origin: 'https://evil.example' } });
    expect(api.status).toBe(403);
  });

  it('popup-режим отдаёт сессию через postMessage только своему origin', async () => {
    gh.setLogin('tester');
    let res = await fetch(`${base}/auth/login?origin=${encodeURIComponent(SITE)}`, { redirect: 'manual' });
    res = await fetch(res.headers.get('location'), { redirect: 'manual' });
    res = await fetch(res.headers.get('location'), { redirect: 'manual' });
    const html = await res.text();
    expect(res.status).toBe(200);
    expect(html).toContain('"yse-auth"');
    expect(html).toContain(`postMessage(m,"${SITE}")`);
    expect(res.headers.get('content-security-policy')).toContain("default-src 'none'");
  });

  it('без сессии — 401, с сессией — профиль', async () => {
    expect((await call('garbage', '/api/me')).status).toBe(401);
    const s = await signIn();
    const me = await (await call(s, '/api/me')).json();
    expect(me.login).toBe('tester');
  });

  it('CORS preflight', async () => {
    const res = await fetch(`${base}/api/submit`, { method: 'OPTIONS', headers: { Origin: SITE } });
    expect(res.status).toBe(204);
    expect(res.headers.get('access-control-allow-origin')).toBe(SITE);
  });
});

describe('правка через форк', () => {
  let s;
  let pr;
  beforeAll(async () => {
    s = await signIn('tester');
  });

  it('отдаёт страницу и разделы', async () => {
    const f = await (await call(s, '/api/file?path=docs/start/ssh.md')).json();
    expect(f.exists).toBe(true);
    expect(f.content).toContain('SSH');
    expect(f.sha).toMatch(/^[0-9a-f]{40}$/);
    const bad = await call(s, '/api/file?path=../mkdocs.yml');
    expect(bad.status).toBe(400);
    const { sections } = await (await call(s, '/api/sections')).json();
    expect(sections.map((x) => x.dir)).toContain('recipes');
  });

  it('блокирует MAC-адрес', async () => {
    const f = await (await call(s, '/api/file?path=docs/start/ssh.md')).json();
    const res = await call(s, '/api/submit', {
      method: 'POST',
      body: JSON.stringify({ title: 't', page: { path: f.path, content: `${f.content}\nmac 5c:c3:36:1a:2b:9e\n`, baseSha: f.sha } }),
    });
    expect(res.status).toBe(422);
    const j = await res.json();
    expect(j.error).toBe('sensitive');
    expect(j.findings[0].rule).toBe('mac');
  });

  it('создаёт форк, коммит с картинкой и PR', async () => {
    const f = await (await call(s, '/api/file?path=docs/start/ssh.md')).json();
    const content = `${f.content}\nПроверьте после перезагрузки.\n\n![Схема](../assets/images/scheme.png)\n`;
    const res = await call(s, '/api/submit', {
      method: 'POST',
      body: JSON.stringify({
        title: 'Дополнить SSH',
        description: 'Добавил проверку',
        tested: 'Мини 2',
        page: { path: f.path, content, baseSha: f.sha },
        images: [{ path: 'docs/assets/images/scheme.png', base64: PNG }],
      }),
    });
    const j = await res.json();
    expect(res.status, JSON.stringify(j)).toBe(200);
    pr = j.pr;
    expect(pr.number).toBeGreaterThan(100);
    const p = gh.pulls.find((x) => x.number === pr.number);
    expect(p.headRepo).toBe('tester/yandex-station-extended');
    expect(p.headRef).toMatch(/^wiki\/start-ssh-[a-z0-9]{6}$/);
    expect(p.maintainer_can_modify).toBe(true);
    expect(p.body).toContain('Добавил проверку');
    expect(p.body).toContain('Мини 2');
    expect(p.body).toContain('https://hackalice.me/start/ssh/');
    expect(gh.file('tester/yandex-station-extended', p.headRef, 'docs/start/ssh.md').toString()).toBe(content);
    expect(gh.file('tester/yandex-station-extended', p.headRef, 'docs/assets/images/scheme.png').toString('base64')).toBe(PNG);
    // main не тронут
    expect(gh.file(UP, 'main', 'docs/start/ssh.md').toString()).toBe(f.content);
    expect(gh.commit('tester/yandex-station-extended', p.headRef).author).toBe('tester');
  });

  it('показывает PR по странице и его статус', async () => {
    const { prs } = await (await call(s, '/api/prs?path=docs/start/ssh.md')).json();
    expect(prs.map((x) => x.number)).toContain(pr.number);
    const st = await (await call(s, `/api/pr?number=${pr.number}`)).json();
    expect(st).toMatchObject({ state: 'open', checksState: 'success' });
  });

  it('дорабатывает тот же PR вторым коммитом', async () => {
    const f = await (await call(s, `/api/file?path=docs/start/ssh.md&pr=${pr.number}`)).json();
    expect(f.pr.number).toBe(pr.number);
    expect(f.content).toContain('Проверьте после перезагрузки');
    expect(f.original).not.toContain('Проверьте после перезагрузки');
    const res = await call(s, '/api/submit', {
      method: 'POST',
      body: JSON.stringify({ title: 'Правка по ревью', pr: pr.number, page: { path: f.path, content: `${f.content}Ещё строка.\n`, baseSha: f.sha } }),
    });
    const j = await res.json();
    expect(res.status, JSON.stringify(j)).toBe(200);
    expect(j.updated).toBe(true);
    const p = gh.pulls.find((x) => x.number === pr.number);
    expect(gh.file(p.headRepo, p.headRef, 'docs/start/ssh.md').toString()).toContain('Ещё строка.');
    expect(gh.pulls.length).toBe(1);
  });

  it('чужой PR дорабатывать нельзя', async () => {
    const other = await signIn('Marker284');
    const res = await call(other, `/api/file?path=docs/start/ssh.md&pr=${pr.number}`);
    expect(res.status).toBe(404);
  });

  it('конфликт, если main изменился', async () => {
    const f = await (await call(s, '/api/file?path=docs/start/ssh.md')).json();
    gh.pushMain('docs/start/ssh.md', `${f.content}Чужая правка.\n`);
    const res = await call(s, '/api/submit', {
      method: 'POST',
      body: JSON.stringify({ title: 't', page: { path: f.path, content: `${f.content}Моя.\n`, baseSha: f.sha } }),
    });
    expect(res.status).toBe(409);
    const j = await res.json();
    expect(j.error).toBe('conflict');
    expect(j.current.content).toContain('Чужая правка.');
  });

  it('без изменений — ошибка', async () => {
    const f = await (await call(s, '/api/file?path=docs/start/ssh.md')).json();
    const res = await call(s, '/api/submit', {
      method: 'POST',
      body: JSON.stringify({ title: 't', page: { path: f.path, content: f.content, baseSha: f.sha } }),
    });
    expect((await res.json()).error).toBe('no-changes');
  });

  it('существующую картинку не перезаписывает', async () => {
    gh.pushMain('docs/assets/images/taken.png', 'x');
    const f = await (await call(s, '/api/file?path=docs/start/ssh.md')).json();
    const res = await call(s, '/api/submit', {
      method: 'POST',
      body: JSON.stringify({
        title: 't',
        page: { path: f.path, content: `${f.content}y\n`, baseSha: f.sha },
        images: [{ path: 'docs/assets/images/taken.png', base64: PNG }],
      }),
    });
    expect(res.status).toBe(409);
    expect((await res.json()).error).toBe('image-exists');
  });

  it('подделанная картинка отклоняется', async () => {
    const f = await (await call(s, '/api/file?path=docs/start/ssh.md')).json();
    const res = await call(s, '/api/submit', {
      method: 'POST',
      body: JSON.stringify({
        title: 't',
        page: { path: f.path, content: `${f.content}x\n`, baseSha: f.sha },
        images: [{ path: 'docs/assets/images/a.png', base64: Buffer.from('<script>').toString('base64') }],
      }),
    });
    expect((await res.json()).error).toBe('bad-image');
  });
});

describe('новая страница', () => {
  it('создаёт файл и пункт в nav', async () => {
    const s = await signIn('tester');
    const res = await call(s, '/api/submit', {
      method: 'POST',
      body: JSON.stringify({
        title: 'Новая страница: Мой рецепт',
        newPage: { section: 'Рецепты', title: 'Мой рецепт' },
        page: { path: 'docs/recipes/moy-retsept.md', content: '# Мой рецепт\n\nТекст.\n', baseSha: null },
      }),
    });
    const j = await res.json();
    expect(res.status, JSON.stringify(j)).toBe(200);
    const p = gh.pulls.find((x) => x.number === j.pr.number);
    const yml = gh.file(p.headRepo, p.headRef, 'mkdocs.yml').toString();
    expect(yml).toContain('      - Мой рецепт: recipes/moy-retsept.md');
    expect(gh.file(p.headRepo, p.headRef, 'docs/recipes/moy-retsept.md').toString()).toContain('Текст.');
  });

  it('нельзя перезаписать существующую и выйти из папки раздела', async () => {
    const s = await signIn('tester');
    const exists = await call(s, '/api/submit', {
      method: 'POST',
      body: JSON.stringify({ title: 'x', newPage: { section: 'Начало работы', title: 'SSH' }, page: { path: 'docs/start/ssh.md', content: '# x\n' } }),
    });
    expect((await exists.json()).error).toBe('exists');
    const wrongDir = await call(s, '/api/submit', {
      method: 'POST',
      body: JSON.stringify({ title: 'x', newPage: { section: 'Рецепты', title: 'X' }, page: { path: 'docs/devices/x.md', content: '# x\n' } }),
    });
    expect((await wrongDir.json()).error).toBe('bad-path');
  });

  it('владелец пушит ветку прямо в репозиторий, без форка', async () => {
    const s = await signIn('Marker284');
    const f = await (await call(s, '/api/file?path=docs/recipes/index.md')).json();
    const res = await call(s, '/api/submit', {
      method: 'POST',
      body: JSON.stringify({ title: 'Рецепты: правка', page: { path: f.path, content: `${f.content}\nНовое.\n`, baseSha: f.sha } }),
    });
    const j = await res.json();
    expect(res.status, JSON.stringify(j)).toBe(200);
    const p = gh.pulls.find((x) => x.number === j.pr.number);
    expect(p.headRepo).toBe(UP);
    expect(p.maintainer_can_modify).toBeUndefined();
    expect(gh.repos.has('Marker284/yandex-station-extended')).toBe(true);
  });

  it('выход отзывает токен', async () => {
    const s = await signIn('tester');
    const out = await call(s, '/auth/logout', { method: 'POST' });
    expect(out.status).toBe(204);
    const me = await call(s, '/api/me');
    expect(me.status).toBe(401);
  });
});
