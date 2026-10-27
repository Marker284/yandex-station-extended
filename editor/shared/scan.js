// Поиск персональных данных в правке: ключи, токены, MAC-адреса, серийники.
// Один и тот же код работает в браузере (подсказка в редакторе), в Worker
// (блокирует отправку) и в CI (проверка любого PR).

/** @typedef {{ rule: string, label: string, line: number, excerpt: string, severity: 'block' | 'warn' }} Finding */

const RULES = [
  {
    rule: 'private-key',
    label: 'Приватный ключ (PEM)',
    severity: 'block',
    re: /-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----/,
  },
  {
    rule: 'devices-json',
    label: 'Ключ из devices.json',
    severity: 'block',
    // "server_private_key": "…" / "secret": "…" со значением, а не плейсхолдером
    re: /"(?:server_private_key|private_key|secret)"\s*:\s*"(?!<|\.\.\.|…|x{3,}|X{3,})[^"]{8,}"/,
  },
  {
    rule: 'yandex-oauth',
    label: 'OAuth-токен Яндекса',
    severity: 'block',
    re: /\b(?:y[0-3]_[A-Za-z0-9_-]{30,}|AQAAAA[A-Za-z0-9_-]{30,})/,
  },
  {
    rule: 'github-token',
    label: 'Токен GitHub',
    severity: 'block',
    re: /\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})/,
  },
  {
    rule: 'jwt',
    label: 'JWT-токен',
    severity: 'block',
    re: /\beyJ[A-Za-z0-9_-]{15,}\.eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}/,
  },
  {
    rule: 'mac',
    label: 'MAC-адрес',
    severity: 'block',
    // ровно 6 байт: не кусок отпечатка сертификата AA:BB:…:FF
    re: /(?<![0-9A-Fa-f][:-]?)[0-9A-Fa-f]{2}(?:[:-][0-9A-Fa-f]{2}){5}(?![:-]?[0-9A-Fa-f])/g,
    // Явные примеры не считаются: 00:11:22:33:44:55, aa:bb:cc:dd:ee:ff,
    // широковещательный, нулевой и одинаковые байты.
    allow: (m) => isExampleMac(m),
  },
  {
    rule: 'device-id',
    label: 'device_id / серийный номер',
    severity: 'warn',
    re: /\b(?:device_?id|serial(?:_?number)?|deviceId)\b["']?\s*[:=]\s*["']?(?![<{]|XXXX|xxxx|\.\.\.|…)[A-Za-z0-9]{12,}/i,
  },
];

const EXAMPLE_MACS = new Set([
  '001122334455',
  'aabbccddeeff',
  '112233445566',
  '123456789abc',
  'deadbeefcafe',
  'ffffffffffff',
  '000000000000',
]);

// Заводские адреса-образцы, которые прошивки пишут по умолчанию (не адрес конкретной колонки)
const DEFAULT_OUIS = ['00904c']; // Broadcom: образец из NVRAM

export function isExampleMac(mac) {
  const hex = mac.toLowerCase().replace(/[:-]/g, '');
  if (EXAMPLE_MACS.has(hex) || DEFAULT_OUIS.some((o) => hex.startsWith(o))) return true;
  const bytes = hex.match(/../g);
  return bytes.every((b) => b === bytes[0]);
}

function excerpt(line, index, len) {
  const start = Math.max(0, index - 20);
  const end = Math.min(line.length, index + len + 20);
  return (start > 0 ? '…' : '') + line.slice(start, end).trim() + (end < line.length ? '…' : '');
}

/**
 * Ищет данные в строках текста.
 * @param {string} text
 * @param {{ onlyLines?: Set<number> }} [opts] номера строк (с 1), которые проверять
 * @returns {Finding[]}
 */
export function scanText(text, opts = {}) {
  const findings = [];
  const lines = text.split('\n');
  lines.forEach((line, i) => {
    const n = i + 1;
    if (opts.onlyLines && !opts.onlyLines.has(n)) return;
    for (const r of RULES) {
      if (r.re.global) {
        r.re.lastIndex = 0;
        let m;
        while ((m = r.re.exec(line))) {
          if (r.allow && r.allow(m[0])) continue;
          findings.push({ rule: r.rule, label: r.label, severity: r.severity, line: n, excerpt: excerpt(line, m.index, m[0].length) });
        }
      } else {
        const m = r.re.exec(line);
        if (m) findings.push({ rule: r.rule, label: r.label, severity: r.severity, line: n, excerpt: excerpt(line, m.index, m[0].length) });
      }
    }
  });
  return findings;
}

/**
 * Номера строк (с 1) в `after`, которых не было в `before`.
 * Сравнение по содержимому строк: старые строки, которые просто сдвинулись, не проверяются.
 */
export function addedLineNumbers(before, after) {
  const counts = new Map();
  for (const l of (before ?? '').split('\n')) counts.set(l, (counts.get(l) ?? 0) + 1);
  const added = new Set();
  after.split('\n').forEach((l, i) => {
    const c = counts.get(l) ?? 0;
    if (c > 0) counts.set(l, c - 1);
    else added.add(i + 1);
  });
  return added;
}

/** Проверяет только то, что правка добавила. */
export function scanChange(before, after) {
  return scanText(after, { onlyLines: addedLineNumbers(before, after) });
}

export const hasBlocking = (findings) => findings.some((f) => f.severity === 'block');
