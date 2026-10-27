// Минимальный клиент GitHub REST API для Worker.

export class GitHubError extends Error {
  constructor(status, message, body) {
    super(message);
    this.status = status;
    this.body = body;
  }
}

export class GitHub {
  /**
   * @param {string} token OAuth-токен пользователя
   * @param {{ apiBase?: string, fetch?: typeof fetch }} [opts]
   */
  constructor(token, opts = {}) {
    this.token = token;
    this.base = (opts.apiBase || 'https://api.github.com').replace(/\/$/, '');
    this.fetch = opts.fetch || ((...a) => fetch(...a));
  }

  async request(method, path, body, { allow404 = false } = {}) {
    const res = await this.fetch(`${this.base}${path}`, {
      method,
      headers: {
        Accept: 'application/vnd.github+json',
        Authorization: `Bearer ${this.token}`,
        'User-Agent': 'yse-wiki-editor',
        'X-GitHub-Api-Version': '2022-11-28',
        ...(body ? { 'Content-Type': 'application/json' } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (allow404 && res.status === 404) return null;
    const text = await res.text();
    let data = null;
    try {
      data = text ? JSON.parse(text) : null;
    } catch {
      data = text;
    }
    if (!res.ok) {
      const msg = (data && data.message) || `GitHub ${res.status}`;
      throw new GitHubError(res.status, msg, data);
    }
    return data;
  }

  get = (path, opts) => this.request('GET', path, undefined, opts);
  post = (path, body) => this.request('POST', path, body);
  patch = (path, body) => this.request('PATCH', path, body);
}

/** Путь в API с экранированием каждого сегмента. */
export const enc = (path) => path.split('/').map(encodeURIComponent).join('/');
