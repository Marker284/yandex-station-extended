import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { scanText, scanChange, hasBlocking, isExampleMac } from '../shared/scan.js';
import {
  addToNav,
  imageFileName,
  isValidImagePath,
  isValidPagePath,
  navSections,
  pageUrlPath,
  pathFromUrl,
  relativeLink,
  resolveRelative,
  slugify,
} from '../shared/paths.js';

const mkdocs = readFileSync(new URL('../../mkdocs.yml', import.meta.url), 'utf8');

describe('scan', () => {
  it('находит ключи и токены', () => {
    const text = [
      '"server_private_key": "MIIEvQIBADANBgkqhkiG9w0BAQEFAASC"',
      'token y0_AgAAAABkZWFkYmVlZmNhZmViYWJlZGVhZGJlZWZjYWZl',
      '-----BEGIN RSA PRIVATE KEY-----',
      'ghp_abcdefghijklmnopqrstuvwxyz0123456789',
    ].join('\n');
    const rules = scanText(text).map((f) => f.rule);
    expect(rules).toEqual(['devices-json', 'yandex-oauth', 'private-key', 'github-token']);
  });

  it('пропускает плейсхолдеры и примеры MAC', () => {
    const text = [
      '"secret": "<ваш secret>"',
      'MAC 00:11:22:33:44:55 и aa:bb:cc:dd:ee:ff, ff:ff:ff:ff:ff:ff',
      'device_id: XXXXXXXXXXXXXXXX',
    ].join('\n');
    expect(scanText(text)).toEqual([]);
    expect(isExampleMac('AA-AA-AA-AA-AA-AA')).toBe(true);
  });

  it('находит настоящий MAC', () => {
    const f = scanText('wlan0 ether 5c:c3:36:1a:2b:9e');
    expect(f).toHaveLength(1);
    expect(f[0]).toMatchObject({ rule: 'mac', line: 1, severity: 'block' });
  });

  it('отпечаток сертификата и образец Broadcom — не MAC', () => {
    expect(scanText('SHA-256 `D7:A7:A0:FB:5D:7E:27:31:D7:71:E9:48:4E:BC:DE:F7`')).toEqual([]);
    expect(scanText('образцовый адрес `00:90:4c:1a:10:01`')).toEqual([]);
    expect(scanText('a 5c:c3:36:1a:2b:9e, b 5C-C3-36-1A-2B-9F')).toHaveLength(2);
  });

  it('device_id — предупреждение, не блок', () => {
    const f = scanText('device_id = "FF98F0A1B2C3D4E5F6A7"');
    expect(f[0].severity).toBe('warn');
    expect(hasBlocking(f)).toBe(false);
  });

  it('проверяет только добавленные строки', () => {
    const before = 'старое\nMAC 5c:c3:36:1a:2b:9e\nконец';
    const after = 'новое\nстарое\nMAC 5c:c3:36:1a:2b:9e\nконец\nеще 5c:c3:36:1a:2b:9f';
    const f = scanChange(before, after);
    expect(f.map((x) => x.line)).toEqual([5]);
  });
});

describe('paths', () => {
  it('валидирует пути страниц', () => {
    expect(isValidPagePath('docs/start/ssh.md')).toBe(true);
    expect(isValidPagePath('docs/index.md')).toBe(true);
    expect(isValidPagePath('docs/../mkdocs.yml')).toBe(false);
    expect(isValidPagePath('docs/start/../../x.md')).toBe(false);
    expect(isValidPagePath('mkdocs.yml')).toBe(false);
    expect(isValidPagePath('docs/Start/SSH.md')).toBe(false);
    expect(isValidPagePath('docs/start/ssh.html')).toBe(false);
    expect(isValidImagePath('docs/assets/images/led-1.png')).toBe(true);
    expect(isValidImagePath('docs/assets/images/x.svg')).toBe(false);
    expect(isValidImagePath('docs/assets/images/../x.png')).toBe(false);
  });

  it('адреса страниц', () => {
    expect(pageUrlPath('docs/start/ssh.md')).toBe('start/ssh/');
    expect(pageUrlPath('docs/index.md')).toBe('');
    expect(pageUrlPath('docs/recipes/index.md')).toBe('recipes/');
    expect(pathFromUrl('/start/ssh/')).toBe('docs/start/ssh.md');
    expect(pathFromUrl('/')).toBe('docs/index.md');
  });

  it('относительные ссылки', () => {
    expect(relativeLink('docs/start/ssh.md', 'docs/assets/images/a.png')).toBe('../assets/images/a.png');
    expect(relativeLink('docs/index.md', 'docs/assets/images/a.png')).toBe('assets/images/a.png');
    expect(resolveRelative('docs/start/ssh.md', '../assets/images/a.png')).toBe('docs/assets/images/a.png');
    expect(resolveRelative('docs/start/ssh.md', 'root.md')).toBe('docs/start/root.md');
  });

  it('транслит', () => {
    expect(slugify('Своя LLM вместо Алисы')).toBe('svoya-llm-vmesto-alisy');
    expect(slugify('  Станция Мини 3 Про!  ')).toBe('stantsiya-mini-3-pro');
    expect(imageFileName('Скрин 1.PNG')).toBe('skrin-1.png');
    expect(imageFileName('photo')).toBe('photo.png');
  });

  it('разделы nav из настоящего mkdocs.yml', () => {
    const s = navSections(mkdocs);
    expect(s.map((x) => x.title)).toEqual(['Начало работы', 'Рецепты', 'Бэкенд', 'Устройства', 'Как это устроено']);
    expect(s.map((x) => x.dir)).toEqual(['start', 'recipes', 'recipes', 'devices', 'internals']);
  });

  it('вставка страницы в конец раздела', () => {
    const out = addToNav(mkdocs, 'Рецепты', 'Моя: страница', 'docs/recipes/moya.md');
    const lines = out.split('\n');
    const i = lines.indexOf('      - "Моя: страница": recipes/moya.md');
    expect(i).toBeGreaterThan(0);
    // структурно, без привязки к тому, какая страница сейчас последняя в разделе
    expect(lines[i - 1]).toMatch(/^ {6}- .+: recipes\/[a-z0-9._/-]+\.md$/);
    expect(lines[i + 1]).toMatch(/^ {2}- .+:$/);
    expect(out.split('\n').length).toBe(mkdocs.split('\n').length + 1);
    // повтор не дублирует
    expect(addToNav(out, 'Рецепты', 'Моя: страница', 'docs/recipes/moya.md')).toBe(out);
    expect(addToNav(mkdocs, 'Нет такого', 'x', 'docs/x/y.md')).toBeNull();
  });

  it('заголовок с переводом строки не подделывает пункты nav', () => {
    const out = addToNav(mkdocs, 'Рецепты', 'Строка\n      - Подделка', 'docs/recipes/x.md');
    expect(out.split('\n').length).toBe(mkdocs.split('\n').length + 1);
    expect(out).toContain('"Строка\\n      - Подделка": recipes/x.md');
    expect(out).not.toContain('- Подделка: recipes/x.md');
  });

  it('вставка в раздел с вложенными группами', () => {
    const out = addToNav(mkdocs, 'Начало работы', 'Новый шаг', 'docs/start/new.md');
    const lines = out.split('\n');
    const i = lines.indexOf('      - Новый шаг: start/new.md');
    expect(i).toBeGreaterThan(0);
    expect(lines[i - 1]).toMatch(/^ {6}- .+: start\/[a-z0-9._/-]+\.md$/);
    expect(lines[i + 1]).toMatch(/^ {2}- .+:$/);
  });
});
