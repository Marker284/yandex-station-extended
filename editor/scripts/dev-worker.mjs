// Локальный Worker для разработки редактора.
//
//   npm run dev:worker -- --fake          фейковый GitHub с содержимым этого репозитория
//   npm run dev:worker                    настоящий GitHub (нужны переменные ниже)
//
// Для настоящего GitHub: GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET, SESSION_KEY и OAuth App
// с callback http://127.0.0.1:8787/auth/callback.

import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { serveWorker } from './node-adapter.mjs';
import { createFakeGitHub } from './fake-github.mjs';

const root = fileURLToPath(new URL('../..', import.meta.url));
const fake = process.argv.includes('--fake');
const port = Number(process.env.PORT || 8787);

function repoFiles() {
  const files = { 'mkdocs.yml': readFileSync(join(root, 'mkdocs.yml'), 'utf8') };
  const walk = (dir) => {
    for (const name of readdirSync(dir)) {
      const p = join(dir, name);
      if (statSync(p).isDirectory()) walk(p);
      else if (p.endsWith('.md')) files[relative(root, p)] = readFileSync(p, 'utf8');
    }
  };
  walk(join(root, 'docs'));
  return files;
}

const env = {
  UPSTREAM_OWNER: process.env.UPSTREAM_OWNER || 'Marker284',
  UPSTREAM_REPO: process.env.UPSTREAM_REPO || 'yandex-station-extended',
  UPSTREAM_BRANCH: 'main',
  SITE_URL: 'https://hackalice.me',
  ALLOWED_ORIGINS: process.env.ALLOWED_ORIGINS || 'http://127.0.0.1:8000,http://localhost:8000',
  GITHUB_CLIENT_ID: process.env.GITHUB_CLIENT_ID || 'dev-client',
  GITHUB_CLIENT_SECRET: process.env.GITHUB_CLIENT_SECRET || 'dev-secret',
  SESSION_KEY: process.env.SESSION_KEY || 'dev-session-key-dev-session-key-0123456789',
};

if (fake) {
  const gh = createFakeGitHub({ files: repoFiles() });
  const ghPort = await gh.listen(Number(process.env.FAKE_GITHUB_PORT || 0));
  env.GITHUB_API_BASE = `http://127.0.0.1:${ghPort}`;
  env.GITHUB_OAUTH_BASE = `http://127.0.0.1:${ghPort}`;
  console.log(`Фейковый GitHub: http://127.0.0.1:${ghPort} (вход сразу как @tester)`);
}

await serveWorker(env, { port, opts: fake ? { forkWaitMs: 10 } : {} });
console.log(`Worker редактора: http://127.0.0.1:${port}`);
