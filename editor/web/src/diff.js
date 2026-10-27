// Сравнение с исходной версией: «+N −M», номера изменённых строк, перенос правки
// на новую версию страницы (когда её успели изменить).

import { diffArrays, structuredPatch, applyPatch } from 'diff';

/** @returns {{ added: number, removed: number, changedLines: Set<number> }} строки с 1 */
export function lineStats(before, after) {
  const a = before.split('\n');
  const b = after.split('\n');
  let added = 0;
  let removed = 0;
  const changedLines = new Set();
  let line = 1;
  for (const part of diffArrays(a, b)) {
    if (part.added) {
      for (let i = 0; i < part.count; i++) changedLines.add(line + i);
      added += part.count;
      line += part.count;
    } else if (part.removed) {
      removed += part.count;
    } else {
      line += part.count;
    }
  }
  return { added, removed, changedLines };
}

/**
 * Трёхстороннее слияние: правка base→mine поверх theirs.
 * @returns {string | null} null — если автоматически не получилось
 */
export function rebase(base, mine, theirs) {
  if (base === theirs) return mine;
  if (base === mine) return theirs;
  const patch = structuredPatch('a', 'b', base, mine, '', '', { context: 3 });
  const out = applyPatch(theirs, patch, { fuzzFactor: 1 });
  return out === false ? null : out;
}
