// YSE wiki editor — Cloudflare Worker.
//
//   GET  /auth/login?origin=…&mode=popup|redirect&return=/path   → GitHub OAuth
//   GET  /auth/callback                                           ← GitHub OAuth
//   POST /auth/logout                                             отзыв токена
//   GET  /api/me                                                  кто вошёл
//   GET  /api/file?path=docs/…md[&pr=N]                           страница для правки
//   GET  /api/sections                                            разделы nav для новой страницы
//   GET  /api/prs?path=docs/…md                                   ваши открытые PR по странице
//   GET  /api/pr?number=N                                         статус PR и проверок
//   POST /api/submit                                              правка → коммит → PR
//
// Браузер получает не токен GitHub, а зашифрованную сессию (Authorization: Bearer …).
// Через этот Worker ею можно только читать вики и предлагать правки в docs/ и nav.

import { GitHub, GitHubError } from './github.js';
import { open, seal } from './crypto.js';
import { HttpError, getSections, listOwnPrs, loadForEdit, prStatus, submit } from './repo.js';

const SESSION_TTL = 30 * 24 * 3600;
const STATE_TTL = 10 * 60;
const MAX_BODY = 25 * 1024 * 1024;

function allowedOrigins(env) {
  return String(env.ALLOWED_ORIGINS || 'https://hackalice.me')
    .split(',')
    .map((s) => s.trim().replace(/\/$/, ''))
    .filter(Boolean);
}

function cors(env, req) {
  const origin = req.headers.get('Origin');
  if (!origin || !allowedOrigins(env).includes(origin)) return {};
  return {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Authorization, Content-Type',
    'Access-Control-Max-Age': '86400',
    Vary: 'Origin',
  };
}

function json(data, status, headers) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', ...headers },
  });
}

const escapeHtml = (s) =>
  String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

/** Страница, которая отдаёт сессию окну редактора и закрывается. */
function popupPage(origin, message) {
  const payload = JSON.stringify(message).replace(/</g, '\\u003c');
  const target = JSON.stringify(origin);
  const text = message.type === 'yse-auth' ? 'Вход выполнен, окно можно закрыть.' : `Вход не выполнен: ${escapeHtml(message.error)}`;
  return new Response(
    `<!doctype html><html lang="ru"><head><meta charset="utf-8"><title>Вход в редактор вики</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{font:16px system-ui,sans-serif;display:grid;place-items:center;min-height:90vh;margin:0;color:#1f2430}</style>
</head><body><p>${text}</p><script>
(function(){var m=${payload};try{if(window.opener){window.opener.postMessage(m,${target});window.close();}}catch(e){}})();
</script></body></html>`,
    {
      headers: {
        'Content-Type': 'text/html; charset=utf-8',
        'Cache-Control': 'no-store',
        'Content-Security-Policy': "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'",
        'Referrer-Policy': 'no-referrer',
      },
    },
  );
}

function oauthBase(env) {
  return (env.GITHUB_OAUTH_BASE || 'https://github.com').replace(/\/$/, '');
}

async function login(req, env) {
  const url = new URL(req.url);
  const origin = (url.searchParams.get('origin') || '').replace(/\/$/, '');
  if (!allowedOrigins(env).includes(origin)) return new Response('Origin не разрешён', { status: 400 });
  const mode = url.searchParams.get('mode') === 'redirect' ? 'redirect' : 'popup';
  let ret = url.searchParams.get('return') || '/edit/';
  if (!ret.startsWith('/') || ret.startsWith('//')) ret = '/edit/';
  const state = await seal(env.SESSION_KEY, 'state', { o: origin, m: mode, r: ret.slice(0, 500) }, STATE_TTL);
  const auth = new URL(`${oauthBase(env)}/login/oauth/authorize`);
  auth.searchParams.set('client_id', env.GITHUB_CLIENT_ID);
  auth.searchParams.set('redirect_uri', `${url.origin}/auth/callback`);
  auth.searchParams.set('scope', 'public_repo');
  auth.searchParams.set('state', state);
  auth.searchParams.set('allow_signup', 'true');
  return Response.redirect(auth.toString(), 302);
}

async function callback(req, env) {
  const url = new URL(req.url);
  const state = await open(env.SESSION_KEY, 'state', url.searchParams.get('state') || '');
  if (!state) return new Response('Ссылка входа устарела. Попробуйте ещё раз.', { status: 400 });
  const fail = (error) =>
    state.m === 'popup'
      ? popupPage(state.o, { type: 'yse-auth-error', error })
      : Response.redirect(`${state.o}${state.r}#yse-auth-error=${encodeURIComponent(error)}`, 302);

  if (url.searchParams.get('error')) return fail('доступ не выдан');
  const code = url.searchParams.get('code');
  if (!code) return fail('нет кода авторизации');

  const tokenRes = await fetch(`${oauthBase(env)}/login/oauth/access_token`, {
    method: 'POST',
    headers: { Accept: 'application/json', 'Content-Type': 'application/json', 'User-Agent': 'yse-wiki-editor' },
    body: JSON.stringify({
      client_id: env.GITHUB_CLIENT_ID,
      client_secret: env.GITHUB_CLIENT_SECRET,
      code,
      redirect_uri: `${url.origin}/auth/callback`,
    }),
  });
  const tok = await tokenRes.json().catch(() => ({}));
  if (!tok.access_token) return fail(tok.error_description || 'GitHub не выдал токен');

  const gh = new GitHub(tok.access_token, { apiBase: env.GITHUB_API_BASE });
  const user = await gh.get('/user');
  const session = await seal(env.SESSION_KEY, 'session', { t: tok.access_token, l: user.login, i: user.id }, SESSION_TTL);
  const profile = { login: user.login, name: user.name || user.login, avatar: user.avatar_url };
  if (state.m === 'popup') return popupPage(state.o, { type: 'yse-auth', session, user: profile });
  return Response.redirect(`${state.o}${state.r}#yse-session=${session}`, 302);
}

async function sessionFrom(req, env) {
  const h = req.headers.get('Authorization') || '';
  const m = /^Bearer\s+(.+)$/.exec(h);
  const s = m && (await open(env.SESSION_KEY, 'session', m[1]));
  if (!s) throw new HttpError(401, 'auth', 'Нужно войти через GitHub');
  return { token: s.t, login: s.l, id: s.i };
}

async function logout(req, env) {
  const s = await sessionFrom(req, env).catch(() => null);
  if (s && env.GITHUB_CLIENT_SECRET) {
    // отзываем токен у GitHub — сессия становится бесполезной
    await fetch(`${(env.GITHUB_API_BASE || 'https://api.github.com').replace(/\/$/, '')}/applications/${env.GITHUB_CLIENT_ID}/token`, {
      method: 'DELETE',
      headers: {
        Authorization: `Basic ${btoa(`${env.GITHUB_CLIENT_ID}:${env.GITHUB_CLIENT_SECRET}`)}`,
        Accept: 'application/vnd.github+json',
        'Content-Type': 'application/json',
        'User-Agent': 'yse-wiki-editor',
      },
      body: JSON.stringify({ access_token: s.token }),
    }).catch(() => {});
  }
  return null;
}

async function readJson(req) {
  const len = Number(req.headers.get('Content-Length') || 0);
  if (len > MAX_BODY) throw new HttpError(413, 'too-big', 'Слишком большой запрос');
  const text = await req.text();
  if (text.length > MAX_BODY) throw new HttpError(413, 'too-big', 'Слишком большой запрос');
  try {
    return JSON.parse(text);
  } catch {
    throw new HttpError(400, 'bad-json', 'Некорректный JSON');
  }
}

async function api(req, env, path, opts) {
  const url = new URL(req.url);
  const s = await sessionFrom(req, env);
  const gh = new GitHub(s.token, { apiBase: env.GITHUB_API_BASE, fetch: opts.fetch });
  switch (`${req.method} ${path}`) {
    case 'GET /api/me': {
      const u = await gh.get('/user');
      return { login: u.login, name: u.name || u.login, avatar: u.avatar_url };
    }
    case 'GET /api/file':
      return loadForEdit(gh, env, s.login, url.searchParams.get('path') || '', url.searchParams.get('pr'));
    case 'GET /api/sections':
      return { sections: await getSections(gh, env) };
    case 'GET /api/prs':
      return { prs: await listOwnPrs(gh, env, s.login, url.searchParams.get('path') || '') };
    case 'GET /api/pr':
      return prStatus(gh, env, url.searchParams.get('number'));
    case 'POST /api/submit':
      return submit(gh, env, s, await readJson(req), opts);
    default:
      throw new HttpError(404, 'not-found', 'Нет такого метода');
  }
}

export async function handle(req, env, opts = {}) {
  const url = new URL(req.url);
  const path = url.pathname.replace(/\/+$/, '') || '/';
  const ch = cors(env, req);
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: ch });
  if (req.headers.get('Origin') && !ch['Access-Control-Allow-Origin'] && path.startsWith('/api')) {
    return json({ error: 'origin', message: 'Origin не разрешён' }, 403);
  }
  try {
    if (path === '/' || path === '/health') return json({ ok: true, service: 'yse-wiki-editor' }, 200, ch);
    if (path === '/auth/login' && req.method === 'GET') return await login(req, env);
    if (path === '/auth/callback' && req.method === 'GET') return await callback(req, env);
    if (path === '/auth/logout' && req.method === 'POST') {
      await logout(req, env);
      return new Response(null, { status: 204, headers: ch });
    }
    if (path.startsWith('/api/')) return json(await api(req, env, path, opts), 200, ch);
    return json({ error: 'not-found' }, 404, ch);
  } catch (e) {
    if (e instanceof HttpError) return json({ error: e.code, message: e.message, ...e.extra }, e.status, ch);
    if (e instanceof GitHubError) {
      if (e.status === 401) return json({ error: 'auth', message: 'Сессия GitHub истекла, войдите снова' }, 401, ch);
      if (e.status === 403 && /rate limit/i.test(e.message)) {
        return json({ error: 'rate-limit', message: 'GitHub ограничил запросы, попробуйте через минуту' }, 429, ch);
      }
      return json({ error: 'github', message: `GitHub: ${e.message}` }, 502, ch);
    }
    console.error(e);
    return json({ error: 'internal', message: 'Внутренняя ошибка сервера редактора' }, 500, ch);
  }
}

export default {
  fetch: (req, env) => handle(req, env),
};
