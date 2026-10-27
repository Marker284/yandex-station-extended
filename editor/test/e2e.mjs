// Сквозная проверка в браузере: собранный сайт + Worker + фейковый GitHub.
//
//   cd editor && npm run build && (cd .. && mkdocs build) && node test/e2e.mjs [папка-для-скриншотов]
//
// mkdocs.yml должен указывать extra.editor.api: http://127.0.0.1:8787 (или задайте
// YSE_SITE_DIR с уже собранным так сайтом).

import http from 'node:http';
import { readFileSync, existsSync, statSync, mkdirSync, readdirSync } from 'node:fs';
import { join, extname, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { chromium } from 'playwright';
import { createFakeGitHub } from '../scripts/fake-github.mjs';
import { serveWorker } from '../scripts/node-adapter.mjs';

const repoRoot = fileURLToPath(new URL('../..', import.meta.url));
const siteDir = process.env.YSE_SITE_DIR || join(repoRoot, 'site');
const shots = process.argv[2];
if (shots) mkdirSync(shots, { recursive: true });

// ---- статика сайта на :8000
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.png': 'image/png', '.svg': 'image/svg+xml', '.woff2': 'font/woff2', '.jpeg': 'image/jpeg', '.jpg': 'image/jpeg' };
const site = http.createServer((req, res) => {
  let p = join(siteDir, decodeURIComponent(new URL(req.url, 'http://x').pathname));
  if (existsSync(p) && statSync(p).isDirectory()) p = join(p, 'index.html');
  if (!existsSync(p)) {
    res.writeHead(404);
    return res.end('404');
  }
  res.writeHead(200, { 'Content-Type': TYPES[extname(p)] || 'application/octet-stream' });
  res.end(readFileSync(p));
});
await new Promise((r) => site.listen(8000, '127.0.0.1', r));

// ---- фейковый GitHub с содержимым репозитория
const files = { 'mkdocs.yml': readFileSync(join(repoRoot, 'mkdocs.yml'), 'utf8') };
const walk = (d) => {
  for (const n of readdirSync(d)) {
    const p = join(d, n);
    if (statSync(p).isDirectory()) walk(p);
    else if (p.endsWith('.md')) files[relative(repoRoot, p)] = readFileSync(p, 'utf8');
  }
};
walk(join(repoRoot, 'docs'));
const gh = createFakeGitHub({ files });
const ghPort = await gh.listen();
const worker = await serveWorker(
  {
    ALLOWED_ORIGINS: 'http://127.0.0.1:8000',
    SITE_URL: 'https://hackalice.me',
    GITHUB_CLIENT_ID: 'cid',
    GITHUB_CLIENT_SECRET: 'secret',
    SESSION_KEY: 'e2e-session-key-e2e-session-key-0123456789',
    GITHUB_API_BASE: `http://127.0.0.1:${ghPort}`,
    GITHUB_OAUTH_BASE: `http://127.0.0.1:${ghPort}`,
  },
  { port: 8787, opts: { forkWaitMs: 5 } },
);

const browser = await chromium.launch();
const errors = [];
async function newPage(colorScheme = 'light', viewport = { width: 1440, height: 900 }) {
  const ctx = await browser.newContext({ viewport, colorScheme, deviceScaleFactor: 1 });
  const page = await ctx.newPage();
  page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
  // внешние ресурсы (шрифты, статистика GitHub, аватар) в изолированной среде недоступны
  page.on('console', (m) => m.type() === 'error' && !/Failed to load resource/.test(m.text()) && errors.push(`console: ${m.text()}`));
  return { ctx, page };
}
const shot = async (page, name) => shots && page.screenshot({ path: join(shots, `${name}.png`) });
const step = (s) => console.log(`• ${s}`);
/** Окно входа закрывается само — иногда раньше, чем мы начали ждать. */
const popupClosed = (p) => (p.isClosed() ? Promise.resolve() : p.waitForEvent('close', { timeout: 15000 }));

try {
  const { ctx, page } = await newPage();

  step('страница вики: карточка и кнопка-карандаш ведут в редактор');
  await page.goto('http://127.0.0.1:8000/start/ssh/');
  await page.locator('.yse-suggest').scrollIntoViewIfNeeded();
  assert.equal(await page.locator('.yse-suggest a', { hasText: 'Править эту страницу' }).count(), 1);
  const editHref = await page.locator('a.md-content__button[rel=edit]').getAttribute('href');
  assert.match(editHref, /edit\/\?path=docs\/start\/ssh\.md$/);
  await shot(page, '01-page-card');

  step('выделение текста → плашка «Предложить правку»');
  await page.evaluate(() => window.scrollTo(0, 0));
  const para = page.locator('article p').filter({ hasText: 'Делается сразу после' }).first();
  await para.scrollIntoViewIfNeeded();
  const box = await para.boundingBox();
  await page.mouse.move(box.x + 2, box.y + box.height / 2);
  await page.mouse.down();
  await page.mouse.move(box.x + box.width * 0.7, box.y + box.height / 2, { steps: 8 });
  await page.mouse.up();
  await page.locator('.yse-bubble:not([hidden])').waitFor();
  await shot(page, '02-selection-bubble');
  await page.locator('.yse-bubble__edit').click();
  await page.waitForURL(/\/edit\/\?path=docs%2Fstart%2Fssh\.md&quote=/);

  step('окно входа → GitHub (popup) → редактор');
  await page.locator('.yse-dialog', { hasText: 'Войдите, чтобы предложить правку' }).waitFor();
  await shot(page, '03-login');
  const [popup] = await Promise.all([page.waitForEvent('popup'), page.getByRole('button', { name: 'Продолжить через GitHub' }).click()]);
  await popupClosed(popup);
  await page.locator('.cm-editor').waitFor();
  await page.locator('.yse-preview h1').waitFor();
  assert.match(await page.locator('.yse-userbtn').innerText(), /@tester/);
  const selected = await page.evaluate(() => getSelection().toString());
  assert.ok(selected.includes('Делается сразу после'), `фрагмент выделен в исходнике: «${selected}»`);
  // превью рендерит admonition и код как сайт
  assert.ok((await page.locator('.yse-preview .admonition.note').count()) >= 1, 'admonition в превью');
  assert.ok((await page.locator('.yse-preview .highlight pre code').count()) >= 3, 'код в превью');

  step('правка: текст, заметка через тулбар, картинка из буфера');
  await page.locator('.cm-content').click();
  await page.keyboard.press('Control+End');
  await page.keyboard.type('\n\nПосле перезагрузки проверьте, что обновления остались выключенными.');
  await page.locator('.yse-tool', { hasText: 'Заметка' }).click();
  await page.locator('.yse-menu__item', { hasText: 'Совет' }).click();
  await page.keyboard.type('Проверка обновлений');
  const png = readFileSync(join(repoRoot, 'docs/assets/images/favicon.png')).toString('base64');
  await page.evaluate(async (b64) => {
    const bin = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
    const dt = new DataTransfer();
    dt.items.add(new File([bin], 'Скрин 1.png', { type: 'image/png' }));
    document.querySelector('.cm-content').dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }));
  }, png);
  await page.waitForTimeout(600);
  const status = await page.locator('.yse-statusbar').innerText();
  assert.match(status, /\+\d+/);
  assert.match(status, /1 картинка/);
  assert.match(status, /Ключи и MAC-адреса не найдены/);
  assert.equal(await page.locator('.yse-preview .admonition.tip .admonition-title', { hasText: 'Проверка обновлений' }).count(), 1);
  assert.ok((await page.locator('.yse-preview img[src^="blob:"]').count()) === 1, 'картинка в превью из памяти');
  await page.locator('.yse-pane--preview').evaluate((el) => (el.scrollTop = el.scrollHeight));
  await shot(page, '04-editor');

  step('MAC-адрес подсвечивается и блокирует отправку');
  await page.keyboard.type('\n\nwlan0 5c:c3:36:1a:2b:9e');
  await page.waitForTimeout(400);
  assert.match(await page.locator('.yse-statusbar').innerText(), /MAC-адрес в строке \d+/);
  assert.ok((await page.locator('.cm-yse-danger').count()) >= 1);
  await page.locator('.yse-send').click();
  await page.locator('.yse-dialog', { hasText: 'отправка заблокирована' }).waitFor();
  await shot(page, '05-blocked');
  assert.equal(await page.locator('.yse-dialog button[type=submit]').isDisabled(), true);
  await page.getByRole('button', { name: 'Назад к редактору' }).click();
  for (let i = 0; i < 'wlan0 5c:c3:36:1a:2b:9e'.length + 2; i++) await page.keyboard.press('Backspace');
  await page.waitForTimeout(400);
  assert.match(await page.locator('.yse-statusbar').innerText(), /не найдены/);

  step('черновик переживает перезагрузку');
  await page.waitForTimeout(1000);
  await page.reload();
  await page.locator('.yse-msg', { hasText: 'Восстановлен ваш черновик' }).waitFor();
  // картинка из буфера в черновик не попадает — вставим её снова через кнопку
  const [chooser] = await Promise.all([page.waitForEvent('filechooser'), page.locator('.yse-tool', { hasText: 'Картинка' }).click()]);
  await chooser.setFiles({ name: 'scheme.png', mimeType: 'image/png', buffer: Buffer.from(png, 'base64') });
  await page.waitForTimeout(300);

  step('отправка → PR');
  await page.keyboard.press('Control+Enter');
  const dlg = page.locator('.yse-dialog', { hasText: 'Отправить правку мейнтейнерам' });
  await dlg.waitFor();
  assert.match(await dlg.locator('#pr-title').inputValue(), /Шаг 2\. SSH и отключение обновлений: правка/);
  await dlg.locator('#pr-desc').fill('Добавил напоминание проверить обновления после перезагрузки.');
  await dlg.locator('#pr-tested').fill('Мини 2, 1.104');
  assert.equal(await dlg.locator('button[type=submit]').isDisabled(), true, 'без согласия кнопка выключена');
  await dlg.locator('#pr-ok').check();
  await shot(page, '06-submit');
  await dlg.locator('button[type=submit]').click();
  await page.locator('.yse-done h1', { hasText: 'Правка отправлена' }).waitFor();
  await page.locator('.yse-progress__item.is-done', { hasText: 'Автопроверки' }).waitFor({ timeout: 8000 });
  await shot(page, '07-done');
  assert.equal(gh.pulls.length, 1);
  const pr = gh.pulls[0];
  assert.equal(pr.headRepo, 'tester/yandex-station-extended');
  assert.match(pr.title, /SSH и отключение обновлений: правка/);
  const committed = gh.file(pr.headRepo, pr.headRef, 'docs/start/ssh.md').toString();
  assert.ok(committed.includes('остались выключенными'));
  assert.ok(committed.includes('!!! tip "Проверка обновлений"'));
  const imgLine = /!\[[^\]]*\]\((\.\.\/assets\/images\/[^)]+)\)/.exec(committed);
  assert.ok(imgLine, 'ссылка на картинку');
  assert.ok(gh.file(pr.headRepo, pr.headRef, `docs/${imgLine[1].slice(3)}`), 'картинка в коммите');

  step('«Доработать» открывает тот же PR');
  await page.getByRole('link', { name: 'Доработать' }).click();
  await page.locator('.yse-chip', { hasText: `PR #${pr.number}` }).waitFor();
  assert.match(await page.locator('.yse-send').innerText(), new RegExp(`Добавить в PR #${pr.number}`));
  await ctx.close();

  step('новая страница в разделе «Рецепты»');
  {
    const { ctx: c2, page: p2 } = await newPage('dark');
    await p2.goto('http://127.0.0.1:8000/recipes/');
    await p2.locator('.yse-suggest a', { hasText: 'Новая страница' }).click();
    const [pp] = await Promise.all([p2.waitForEvent('popup'), p2.getByRole('button', { name: 'Продолжить через GitHub' }).click()]);
    await popupClosed(pp);
    await p2.locator('#np-title').waitFor();
    assert.equal(await p2.locator('#np-section').inputValue(), 'Рецепты');
    await p2.locator('#np-title').fill('Своя прошивка звуков');
    assert.equal(await p2.locator('#np-slug').inputValue(), 'svoya-proshivka-zvukov');
    await shot(p2, '08-new-page-dark');
    await p2.getByRole('button', { name: 'Создать страницу' }).click();
    await p2.locator('.cm-editor').waitFor();
    await shot(p2, '09-editor-dark');
    await p2.locator('.yse-send').click();
    await p2.locator('#pr-ok').check();
    await p2.locator('.yse-dialog button[type=submit]').click();
    await p2.locator('.yse-done h1').waitFor();
    const np = gh.pulls[1];
    assert.ok(gh.file(np.headRepo, np.headRef, 'mkdocs.yml').toString().includes('      - Своя прошивка звуков: recipes/svoya-proshivka-zvukov.md'));
    await c2.close();
  }

  step('телефон: редактор помещается без горизонтальной прокрутки');
  {
    const { ctx: c3, page: p3 } = await newPage('light', { width: 390, height: 844 });
    await p3.goto('http://127.0.0.1:8000/start/ssh/');
    await p3.locator('a.md-content__button[rel=edit]').click();
    const [pp] = await Promise.all([p3.waitForEvent('popup'), p3.getByRole('button', { name: 'Продолжить через GitHub' }).click()]);
    await popupClosed(pp);
    await p3.locator('.cm-editor').waitFor();
    const overflow = await p3.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    assert.ok(overflow <= 0, `горизонтальный скролл ${overflow}px`);
    await shot(p3, '10-mobile');
    await c3.close();
  }

  assert.deepEqual(errors, []);
  console.log('\nE2E: всё прошло');
} finally {
  await browser.close();
  site.close();
  worker.server.close();
  await gh.close();
}
