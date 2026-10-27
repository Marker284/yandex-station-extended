// Сборка редактора в docs/assets/editor/ (editor.js + editor.css).
// MkDocs копирует эту папку на сайт как есть.
import * as esbuild from 'esbuild';
import { fileURLToPath } from 'node:url';

const out = fileURLToPath(new URL('../../docs/assets/editor/', import.meta.url));
const watch = process.argv.includes('--watch');

const options = {
  entryPoints: { editor: fileURLToPath(new URL('../web/src/main.js', import.meta.url)) },
  outdir: out,
  bundle: true,
  format: 'esm',
  target: ['es2022', 'chrome110', 'firefox115', 'safari16'],
  minify: !watch,
  sourcemap: watch ? 'inline' : false,
  legalComments: 'linked',
  logLevel: 'info',
};

if (watch) {
  const ctx = await esbuild.context(options);
  await ctx.watch();
} else {
  await esbuild.build(options);
}
