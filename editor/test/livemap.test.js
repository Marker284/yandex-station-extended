import { describe, expect, it } from 'vitest';
import MarkdownIt from 'markdown-it';
import { wikiMarkdown } from '../web/src/mdext.js';
import { alignToSource, caretToSource, diffText, sourceEdit } from '../web/src/livemap.js';

const md = wikiMarkdown(new MarkdownIt({ html: true, linkify: true, typographer: false }));

/** Правка текста блока → новый исходник блока (как это делает live.js). */
function edit(src, before, after) {
  const e = sourceEdit(before, after, src);
  return e === null ? null : src.slice(0, e.from) + e.insert + src.slice(e.to);
}

describe('diffText', () => {
  it('находит изменённую середину', () => {
    expect(diffText('порт 2222 открыт', 'порт 22 открыт')).toEqual({ at: 7, removed: '22', inserted: '' });
    expect(diffText('abc', 'abXc')).toEqual({ at: 2, removed: '', inserted: 'X' });
    expect(diffText('abc', 'abc')).toEqual({ at: 3, removed: '', inserted: '' });
  });
});

describe('alignToSource', () => {
  it('текст превью — подпоследовательность исходника', () => {
    const pos = alignToSource('жирный текст', '**жирный** текст');
    expect(pos[0]).toBe(2);
    expect(pos[6]).toBe(10); // пробел после **
  });

  it('отказывается, если рендер изменил символы', () => {
    expect(alignToSource('Ctrl+C', '++ctrl+c++')).toBeNull();
  });
});

describe('sourceEdit', () => {
  it('правка внутри жирного не трогает звёздочки', () => {
    // набранное перед жирным словом жирным не становится — как в обычном редакторе
    expect(edit('Это **важный** шаг', 'Это важный шаг', 'Это очень важный шаг')).toBe('Это очень **важный** шаг');
    expect(edit('Это **важный** шаг', 'Это важный шаг', 'Это важный этап')).toBe('Это **важный** этап');
  });

  it('ссылка остаётся ссылкой, адрес не трогается', () => {
    const src = 'Делается сразу после [шага 1](root.md), пока работает ADB.';
    const text = 'Делается сразу после шага 1, пока работает ADB.';
    expect(edit(src, text, 'Делается сразу после шага 1, пока работает adb.')).toBe(
      'Делается сразу после [шага 1](root.md), пока работает adb.',
    );
    // правка внутри подписи ссылки
    expect(edit(src, text, 'Делается сразу после шага 2, пока работает ADB.')).toBe(
      'Делается сразу после [шага 2](root.md), пока работает ADB.',
    );
  });

  it('якорь заголовка переживает переименование', () => {
    expect(edit('## 1. Закрепите сетевой ADB { #perm-adb }', '1. Закрепите сетевой ADB', '1. Закрепите ADB')).toBe(
      '## 1. Закрепите ADB { #perm-adb }',
    );
  });

  it('дописывание в конец идёт за разметку, а не внутрь неё', () => {
    expect(edit('Это **важно**', 'Это важно', 'Это важно!')).toBe('Это **важно**!');
  });

  it('пункт списка правится без маркера', () => {
    expect(edit('- SSH на порту **2222**', 'SSH на порту 2222', 'SSH на порту 2223')).toBe('- SSH на порту **2223**');
  });

  it('строка таблицы: правится только ячейка', () => {
    const src = '| Мини | да |';
    const text = 'Минида'; // textContent строки таблицы — ячейки подряд
    expect(edit(src, text, 'Мини 2да')).toBe('| Мини 2 | да |');
  });

  it('код внутри фенса совпадает с исходником символ в символ', () => {
    const src = 'adb connect 192.168.1.120:5555\nadb devices\n';
    expect(edit(src, src, 'adb connect 10.0.0.5:5555\nadb devices\n')).toBe('adb connect 10.0.0.5:5555\nadb devices\n');
  });

  it('ничего не меняем — нет правки', () => {
    expect(sourceEdit('одно и то же', 'одно и то же', 'одно и то же')).toBeNull();
  });

  it('если текст не сопоставляется — отказ, а не порча исходника', () => {
    expect(sourceEdit('Ctrl+C', 'Ctrl+D', '++ctrl+c++')).toBeNull();
  });
});

describe('caretToSource', () => {
  it('каретка в конце блока — за всей разметкой', () => {
    expect(caretToSource('Это важно', 'Это **важно**', 9)).toBe(13);
  });

  it('каретка в начале пункта — после маркера списка', () => {
    expect(caretToSource('первый пункт', '- первый пункт', 0)).toBe(2);
  });
});

// Проверка сквозная: текст блока в настоящем превью действительно сопоставляется
// с его строками исходника, иначе правка справа была бы невозможна.
describe('превью и исходник сходятся', () => {
  const page = `# Заголовок

Обычный **абзац** со [ссылкой](root.md) и \`кодом\`.

- первый пункт
- второй **пункт**

!!! note "Заметка"
    Абзац внутри admonition с [ссылкой](../internals/architecture.md).

=== "Linux"
    Текст вкладки.

\`\`\`sh
adb connect 192.168.1.120:5555
\`\`\`

| Модель | Root |
|---|---|
| Мини | да |
`;

  it('каждый блок превью ложится на свои строки', () => {
    const lines = page.split('\n');
    const html = md.render(page);
    const blocks = [...html.matchAll(/<([a-z0-9]+)([^>]*?)data-line="(\d+)"([^>]*?)>/g)];
    expect(blocks.length).toBeGreaterThan(8);

    // грубая проверка: у каждого блока есть data-end больше data-line
    for (const b of blocks) {
      const attrs = b[2] + b[4];
      const end = /data-end="(\d+)"/.exec(attrs);
      expect(end).not.toBeNull();
      expect(Number(end[1])).toBeGreaterThan(Number(b[3]));
      expect(Number(end[1])).toBeLessThanOrEqual(lines.length);
    }
  });

  it('текст абзаца сопоставляется со своей строкой', () => {
    const lines = page.split('\n');
    const src = lines[2];
    const text = 'Обычный абзац со ссылкой и кодом.';
    expect(alignToSource(text, src)).not.toBeNull();
    expect(edit(src, text, 'Обычный абзац со ссылкой и кодом!')).toBe('Обычный **абзац** со [ссылкой](root.md) и `кодом`!');
  });
});
