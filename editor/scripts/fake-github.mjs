// Фейковый GitHub в памяти: OAuth и нужная редактору часть REST API.
// Для тестов и локальной разработки без настоящего GitHub (npm run dev:worker -- --fake).

import http from 'node:http';
import { createHash, randomBytes } from 'node:crypto';

const blobSha = (buf) => createHash('sha1').update(Buffer.concat([Buffer.from(`blob ${buf.length}\0`), buf])).digest('hex');
const rnd = () => randomBytes(20).toString('hex');

export function createFakeGitHub({ owner = 'Marker284', repo = 'yandex-station-extended', files = {}, users } = {}) {
  /** sha → Buffer */
  const blobs = new Map();
  /** sha → { files: Map<path, blobSha> } */
  const trees = new Map();
  /** sha → { tree, parents, message, author } */
  const commits = new Map();
  /** full → { owner, name, refs: Map, parent?: full, collaborators: Set } */
  const repos = new Map();
  const pulls = [];
  const tokens = new Map(); // token → login
  const codes = new Map(); // code → login
  const log = [];
  const people = users || { tester: { id: 101, name: 'Тест Тестов' }, [owner]: { id: 1, name: owner } };
  let loginAs = Object.keys(people)[0];

  function putBlob(buf) {
    const sha = blobSha(buf);
    blobs.set(sha, buf);
    return sha;
  }
  function putTree(map) {
    const sha = createHash('sha1').update(JSON.stringify([...map].sort())).digest('hex');
    trees.set(sha, { files: new Map(map) });
    return sha;
  }

  const initial = new Map(Object.entries(files).map(([p, c]) => [p, putBlob(Buffer.from(c))]));
  const rootCommit = rnd();
  commits.set(rootCommit, { tree: putTree(initial), parents: [], message: 'init' });
  repos.set(`${owner}/${repo}`, {
    owner,
    name: repo,
    refs: new Map([['main', rootCommit]]),
    collaborators: new Set([owner]),
  });

  function resolveRef(r, ref) {
    if (r.refs.has(ref)) return r.refs.get(ref);
    if (commits.has(ref)) return ref;
    return null;
  }

  function send(res, status, data, headers = {}) {
    res.writeHead(status, { 'Content-Type': 'application/json', ...headers });
    res.end(data === undefined ? '' : JSON.stringify(data));
  }

  const repoJson = (full, login) => {
    const r = repos.get(full);
    return {
      full_name: full,
      name: r.name,
      owner: { login: r.owner },
      fork: !!r.parent,
      permissions: { push: r.collaborators.has(login), pull: true },
    };
  };

  const prJson = (p) => ({
    number: p.number,
    title: p.title,
    body: p.body,
    state: p.state,
    merged_at: null,
    html_url: `https://github.com/${owner}/${repo}/pull/${p.number}`,
    user: { login: p.user },
    head: { ref: p.headRef, sha: repos.get(p.headRepo).refs.get(p.headRef), repo: repoJson(p.headRepo, p.user) },
    base: { ref: p.base },
    comments: 0,
    review_comments: 0,
    updated_at: new Date().toISOString(),
    maintainer_can_modify: !!p.maintainer_can_modify,
  });

  async function handler(req, res) {
    const url = new URL(req.url, 'http://x');
    let body = '';
    for await (const c of req) body += c;
    const json = body ? JSON.parse(body) : {};
    const p = url.pathname;
    log.push(`${req.method} ${p}`);

    // ---- OAuth
    if (p === '/login/oauth/authorize') {
      const code = rnd();
      codes.set(code, loginAs);
      const back = new URL(url.searchParams.get('redirect_uri'));
      back.searchParams.set('code', code);
      back.searchParams.set('state', url.searchParams.get('state'));
      res.writeHead(302, { Location: back.toString() });
      return res.end();
    }
    if (p === '/login/oauth/access_token') {
      const login = codes.get(json.code);
      if (!login) return send(res, 200, { error: 'bad_verification_code' });
      codes.delete(json.code);
      const t = `gho_${rnd()}`;
      tokens.set(t, login);
      return send(res, 200, { access_token: t, token_type: 'bearer', scope: 'public_repo' });
    }
    const appToken = /^\/applications\/[^/]+\/token$/.exec(p);
    if (appToken && req.method === 'DELETE') {
      tokens.delete(json.access_token);
      return send(res, 204);
    }

    // ---- API: авторизация
    const auth = /^Bearer (.+)$/.exec(req.headers.authorization || '');
    const login = auth && tokens.get(auth[1]);
    if (!login) return send(res, 401, { message: 'Bad credentials' });

    if (p === '/user') return send(res, 200, { login, id: people[login]?.id ?? 7, name: people[login]?.name, avatar_url: `https://avatars.example/${login}` });

    const m = /^\/repos\/([^/]+)\/([^/]+)(\/.*)?$/.exec(p);
    if (!m) return send(res, 404, { message: 'Not Found' });
    const full = `${m[1]}/${m[2]}`;
    const rest = m[3] || '';
    const r = repos.get(full);
    if (!r) return send(res, 404, { message: 'Not Found' });

    if (!rest && req.method === 'GET') return send(res, 200, repoJson(full, login));

    if (rest === '/forks' && req.method === 'POST') {
      const forkFull = `${login}/${r.name}`;
      if (!repos.has(forkFull)) {
        repos.set(forkFull, { owner: login, name: r.name, parent: full, refs: new Map([['main', r.refs.get('main')]]), collaborators: new Set([login]) });
      }
      return send(res, 202, repoJson(forkFull, login));
    }

    const canWrite = r.collaborators.has(login);

    let mm;
    if ((mm = /^\/contents\/(.+)$/.exec(rest)) && req.method === 'GET') {
      const sha = resolveRef(r, url.searchParams.get('ref') || 'main');
      const tree = sha && trees.get(commits.get(sha).tree);
      const path = decodeURIComponent(mm[1]);
      const b = tree?.files.get(path);
      if (!b) return send(res, 404, { message: 'Not Found' });
      return send(res, 200, { type: 'file', path, sha: b, encoding: 'base64', content: blobs.get(b).toString('base64') });
    }
    if ((mm = /^\/git\/ref\/heads\/(.+)$/.exec(rest)) && req.method === 'GET') {
      const sha = r.refs.get(decodeURIComponent(mm[1]));
      if (!sha) return send(res, 404, { message: 'Not Found' });
      return send(res, 200, { ref: `refs/heads/${mm[1]}`, object: { sha, type: 'commit' } });
    }
    if ((mm = /^\/git\/commits\/([0-9a-f]+)$/.exec(rest)) && req.method === 'GET') {
      const c = commits.get(mm[1]);
      if (!c) return send(res, 404, { message: 'Not Found' });
      return send(res, 200, { sha: mm[1], tree: { sha: c.tree }, parents: c.parents.map((s) => ({ sha: s })), message: c.message });
    }
    if (rest === '/git/blobs' && req.method === 'POST') {
      if (!canWrite) return send(res, 403, { message: 'Forbidden' });
      const buf = Buffer.from(json.content, json.encoding === 'base64' ? 'base64' : 'utf8');
      return send(res, 201, { sha: putBlob(buf) });
    }
    if (rest === '/git/trees' && req.method === 'POST') {
      if (!canWrite) return send(res, 403, { message: 'Forbidden' });
      const base = json.base_tree ? new Map(trees.get(json.base_tree).files) : new Map();
      for (const e of json.tree) {
        if (e.sha === null) base.delete(e.path);
        else base.set(e.path, e.sha ?? putBlob(Buffer.from(e.content)));
      }
      return send(res, 201, { sha: putTree(base) });
    }
    if (rest === '/git/commits' && req.method === 'POST') {
      if (!canWrite) return send(res, 403, { message: 'Forbidden' });
      const sha = rnd();
      commits.set(sha, { tree: json.tree, parents: json.parents, message: json.message, author: login });
      return send(res, 201, { sha });
    }
    if (rest === '/git/refs' && req.method === 'POST') {
      if (!canWrite) return send(res, 403, { message: 'Forbidden' });
      const name = json.ref.replace('refs/heads/', '');
      if (r.refs.has(name)) return send(res, 422, { message: 'Reference already exists' });
      r.refs.set(name, json.sha);
      return send(res, 201, { ref: json.ref, object: { sha: json.sha } });
    }
    if ((mm = /^\/git\/refs\/heads\/(.+)$/.exec(rest)) && req.method === 'PATCH') {
      if (!canWrite) return send(res, 403, { message: 'Forbidden' });
      const name = decodeURIComponent(mm[1]);
      const old = r.refs.get(name);
      if (!json.force && !commits.get(json.sha).parents.includes(old)) return send(res, 422, { message: 'Update is not a fast forward' });
      r.refs.set(name, json.sha);
      return send(res, 200, { object: { sha: json.sha } });
    }
    if (rest === '/merge-upstream' && req.method === 'POST') {
      if (r.parent) r.refs.set('main', repos.get(r.parent).refs.get('main'));
      return send(res, 200, { message: 'ok' });
    }
    if (rest === '/pulls' && req.method === 'POST') {
      const [headOwner, headRef] = json.head.includes(':') ? json.head.split(':') : [r.owner, json.head];
      const headRepo = `${headOwner}/${r.name}`;
      if (!repos.get(headRepo)?.refs.has(headRef)) return send(res, 422, { message: 'Validation Failed: head' });
      const pr = { number: 100 + pulls.length + 1, title: json.title, body: json.body, state: 'open', user: login, headRepo, headRef, base: json.base, maintainer_can_modify: json.maintainer_can_modify };
      pulls.push(pr);
      return send(res, 201, prJson(pr));
    }
    if (rest === '/pulls' && req.method === 'GET') return send(res, 200, pulls.filter((x) => x.state === 'open').map(prJson));
    if ((mm = /^\/pulls\/(\d+)$/.exec(rest))) {
      const pr = pulls.find((x) => x.number === Number(mm[1]));
      return pr ? send(res, 200, prJson(pr)) : send(res, 404, { message: 'Not Found' });
    }
    if ((mm = /^\/pulls\/(\d+)\/files$/.exec(rest))) {
      const pr = pulls.find((x) => x.number === Number(mm[1]));
      if (!pr) return send(res, 404, { message: 'Not Found' });
      const head = trees.get(commits.get(repos.get(pr.headRepo).refs.get(pr.headRef)).tree).files;
      const base = trees.get(commits.get(r.refs.get('main')).tree).files;
      const changed = [...head].filter(([k, v]) => base.get(k) !== v).map(([k]) => ({ filename: k }));
      return send(res, 200, changed);
    }
    if (/^\/commits\/[0-9a-f]+\/check-runs$/.test(rest)) {
      return send(res, 200, { check_runs: [{ name: 'wiki-pr-check', status: 'completed', conclusion: 'success', html_url: 'https://github.com/x' }] });
    }
    if (/^\/commits\/[0-9a-f]+\/status$/.test(rest)) return send(res, 200, { statuses: [] });

    return send(res, 404, { message: `Not Found (${req.method} ${rest})` });
  }

  const server = http.createServer((req, res) =>
    handler(req, res).catch((e) => {
      console.error(e);
      send(res, 500, { message: String(e) });
    }),
  );

  return {
    server,
    log,
    repos,
    pulls,
    setLogin: (l) => (loginAs = l),
    /** Текст файла в ветке репозитория. */
    file(full, ref, path) {
      const rr = repos.get(full);
      const sha = resolveRef(rr, ref);
      const b = trees.get(commits.get(sha).tree).files.get(path);
      return b ? blobs.get(b) : null;
    },
    commit(full, ref) {
      return commits.get(resolveRef(repos.get(full), ref));
    },
    /** Прямой коммит в main (имитация чужой правки). */
    pushMain(path, content) {
      const rr = repos.get(`${owner}/${repo}`);
      const parent = rr.refs.get('main');
      const files = new Map(trees.get(commits.get(parent).tree).files);
      files.set(path, putBlob(Buffer.from(content)));
      const sha = rnd();
      commits.set(sha, { tree: putTree(files), parents: [parent], message: 'other' });
      rr.refs.set('main', sha);
    },
    listen(port = 0) {
      return new Promise((resolve) => server.listen(port, '127.0.0.1', () => resolve(server.address().port)));
    },
    close: () => new Promise((r) => server.close(r)),
  };
}
