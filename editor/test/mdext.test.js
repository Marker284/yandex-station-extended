import { describe, expect, it } from 'vitest';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import MarkdownIt from 'markdown-it';
import { wikiMarkdown } from '../web/src/mdext.js';

const md = wikiMarkdown(new MarkdownIt({ html: true }));
const docs = new URL('../../docs/', import.meta.url).pathname;

describe('markdown вики', () => {
  it('admonition с заголовком и вложенным кодом', () => {
    const out = md.render('!!! warning "Только свои"\n    Текст **жирный**.\n\n    ```sh\n    ls\n    ```\n\nПосле.');
    expect(out).toContain('<div class="admonition warning"><p class="admonition-title">Только свои</p>');
    expect(out).toContain('<strong>жирный</strong>');
    expect(out).toContain('<div class="language-sh highlight"');
    expect(out).toMatch(/<\/div>\n<p data-line="7">После.<\/p>/);
  });

  it('admonition без заголовка и details', () => {
    expect(md.render('!!! note ""\n    x')).toContain('<div class="admonition note">\n<p data-line="1">x</p>');
    expect(md.render('!!! tip\n    x')).toContain('admonition-title">Tip<');
    const d = md.render('???+ failure "Сломалось"\n    x');
    expect(d).toContain('<details class="failure" open><summary>Сломалось</summary>');
  });

  it('вкладки', () => {
    const out = md.render('=== "Linux"\n\n    a\n\n=== "Windows"\n\n    b\n\nконец');
    expect(out).toMatch(/<div class="tabbed-set tabbed-alternate" data-tabs="\d+:2">/);
    expect(out.match(/<div class="tabbed-block">/g)).toHaveLength(2);
    expect(out).toContain('<label for="__tabbed_');
    expect(out).toContain('<p data-line="6">b</p>');
    expect(out).toContain('конец');
  });

  it('attr_list, клавиши, иконки', () => {
    expect(md.render('## Шаг { #root }')).toContain('<h2 id="root" data-line="0">Шаг</h2>');
    expect(md.render('[Скачать](x.zip){ .md-button .md-button--primary }')).toContain('<a href="x.zip" class="md-button md-button--primary">Скачать</a>');
    expect(md.render('![a](a.png){ width="300" }')).toContain('width="300"');
    expect(md.render('++ctrl+c++')).toContain('<kbd class="key-ctrl">Ctrl</kbd><span>+</span><kbd class="key-c">C</kbd>');
    expect(md.render(':material-cog: x')).toContain('yse-icon-shortcode');
  });

  it('все страницы вики рендерятся без исключений и без сырых !!!/===', () => {
    const files = [];
    const walk = (d) => {
      for (const n of readdirSync(d)) {
        const p = join(d, n);
        if (statSync(p).isDirectory()) walk(p);
        else if (p.endsWith('.md')) files.push(p);
      }
    };
    walk(docs);
    expect(files.length).toBeGreaterThan(30);
    for (const f of files) {
      const out = md.render(readFileSync(f, 'utf8'));
      const leftovers = out.split('\n').filter((l) => /^<p[^>]*>(!!!|\?\?\?|===) /.test(l));
      expect(leftovers, f).toEqual([]);
    }
  });
});
