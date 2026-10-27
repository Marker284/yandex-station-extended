// Клиент сервера редактора: вход через GitHub (popup или переход) и вызовы /api.

import { store } from './dom.js';

const SESSION_KEY = 'yse-editor-session';
const USER_KEY = 'yse-editor-user';

export class ApiError extends Error {
  constructor(status, data) {
    super(data?.message || `Ошибка ${status}`);
    this.status = status;
    this.code = data?.error || 'unknown';
    this.data = data || {};
  }
}

export class Api {
  constructor(base) {
    this.base = base.replace(/\/$/, '');
    this.origin = new URL(this.base).origin;
    this.session = store.get(SESSION_KEY);
    this.user = store.get(USER_KEY);
    this.takeSessionFromHash();
  }

  get signedIn() {
    return !!this.session;
  }

  /** После входа в режиме перехода сессия приходит в #yse-session=… */
  takeSessionFromHash() {
    const m = /[#&]yse-session=([^&]+)/.exec(location.hash);
    const err = /[#&]yse-auth-error=([^&]+)/.exec(location.hash);
    if (m) this.setSession(decodeURIComponent(m[1]), null);
    if (m || err) history.replaceState(null, '', location.pathname + location.search);
    this.redirectError = err ? decodeURIComponent(err[1]) : null;
  }

  setSession(session, user) {
    this.session = session;
    this.user = user;
    store.set(SESSION_KEY, session);
    if (user) store.set(USER_KEY, user);
    else store.del(USER_KEY);
  }

  clear() {
    this.session = null;
    this.user = null;
    store.del(SESSION_KEY);
    store.del(USER_KEY);
  }

  loginUrl(mode) {
    const u = new URL(`${this.base}/auth/login`);
    u.searchParams.set('origin', location.origin);
    u.searchParams.set('mode', mode);
    u.searchParams.set('return', location.pathname + location.search);
    return u.toString();
  }

  /** Вход в отдельном окне; если окно заблокировано — обычный переход. */
  login() {
    return new Promise((resolve, reject) => {
      const w = 520;
      const hgt = 720;
      const popup = window.open(
        this.loginUrl('popup'),
        'yse-github-login',
        `width=${w},height=${hgt},left=${Math.max(0, (screen.width - w) / 2)},top=${Math.max(0, (screen.height - hgt) / 2)}`,
      );
      if (!popup) {
        location.href = this.loginUrl('redirect');
        return;
      }
      const onMessage = (e) => {
        if (e.origin !== this.origin || !e.data || typeof e.data !== 'object') return;
        if (e.data.type === 'yse-auth') {
          done();
          this.setSession(e.data.session, e.data.user);
          resolve(e.data.user);
        } else if (e.data.type === 'yse-auth-error') {
          done();
          reject(new Error(e.data.error || 'Вход не выполнен'));
        }
      };
      const timer = setInterval(() => {
        if (popup.closed) {
          done();
          reject(new Error('closed'));
        }
      }, 500);
      const done = () => {
        clearInterval(timer);
        window.removeEventListener('message', onMessage);
      };
      window.addEventListener('message', onMessage);
    });
  }

  async logout() {
    const s = this.session;
    this.clear();
    if (s) {
      await fetch(`${this.base}/auth/logout`, { method: 'POST', headers: { Authorization: `Bearer ${s}` } }).catch(() => {});
    }
  }

  async call(method, path, body) {
    let res;
    try {
      res = await fetch(`${this.base}${path}`, {
        method,
        headers: {
          ...(this.session ? { Authorization: `Bearer ${this.session}` } : {}),
          ...(body ? { 'Content-Type': 'application/json' } : {}),
        },
        body: body ? JSON.stringify(body) : undefined,
      });
    } catch {
      throw new ApiError(0, { error: 'network', message: 'Сервер редактора недоступен. Проверьте интернет и попробуйте ещё раз.' });
    }
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      if (res.status === 401) this.clear();
      throw new ApiError(res.status, data);
    }
    return data;
  }

  async me() {
    const u = await this.call('GET', '/api/me');
    this.user = u;
    store.set(USER_KEY, u);
    return u;
  }

  file(path, pr) {
    const q = new URLSearchParams({ path });
    if (pr) q.set('pr', pr);
    return this.call('GET', `/api/file?${q}`);
  }

  sections = () => this.call('GET', '/api/sections');
  prs = (path) => this.call('GET', `/api/prs?path=${encodeURIComponent(path)}`);
  pr = (number) => this.call('GET', `/api/pr?number=${encodeURIComponent(number)}`);
  submit = (payload) => this.call('POST', '/api/submit', payload);
}
