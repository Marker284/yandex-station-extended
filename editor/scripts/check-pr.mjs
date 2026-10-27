// Проверка PR на личные данные: только строки, которые PR добавляет в docs/**/*.md.
//
//   node scripts/check-pr.mjs <base-ref> [head-ref]
//
// Ошибки печатаются как аннотации GitHub Actions. Код выхода 1 — если есть ключи,
// токены или MAC-адреса.

import { execFileSync } from 'node:child_process';
import { scanChange } from '../shared/scan.js';

const [base = 'origin/main', head = 'HEAD'] = process.argv.slice(2);
// пути docs/… — от корня репозитория, откуда бы ни запустили скрипт
const top = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim();
const git = (...args) => execFileSync('git', args, { cwd: top, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
const show = (ref, path) => {
  try {
    // файла может не быть в базовой ветке (новая страница) — это не ошибка
    return execFileSync('git', ['show', `${ref}:${path}`], { cwd: top, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 64 * 1024 * 1024 });
  } catch {
    return '';
  }
};

const mergeBase = git('merge-base', base, head).trim();
const files = git('diff', '--name-only', '--diff-filter=AM', mergeBase, head, '--', 'docs/')
  .split('\n')
  .filter((f) => f.endsWith('.md'));

let blocking = 0;
let warnings = 0;
for (const file of files) {
  const findings = scanChange(show(mergeBase, file), show(head, file));
  for (const f of findings) {
    const level = f.severity === 'block' ? 'error' : 'warning';
    if (f.severity === 'block') blocking++;
    else warnings++;
    console.log(`::${level} file=${file},line=${f.line},title=${f.label}::${f.label} в добавленной строке. Замените на плейсхолдер, например <MAC-колонки> или <device_id>.`);
  }
}

console.log(`Проверено файлов: ${files.length}. Ошибок: ${blocking}, предупреждений: ${warnings}.`);
process.exit(blocking ? 1 : 0);
