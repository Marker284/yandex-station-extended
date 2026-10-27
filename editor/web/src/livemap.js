// Перенос правки, набранной в превью, обратно в Markdown-исходник блока.
//
// Превью — это HTML, и обратная конвертация HTML → Markdown ломает разметку вики
// (`!!! note`, `=== "Вкладки"`, якоря `{ #id }`, иконки). Поэтому конвертации нет:
// текст блока в превью — подпоследовательность его исходника (разметка добавляет
// символы, но не убирает текст), так что правку достаточно сопоставить по символам
// и внести в исходник ровно её. Всё остальное в строке остаётся нетронутым.

/** Что именно изменилось в тексте: общий префикс и суффикс отбрасываются. */
export function diffText(before, after) {
  const max = Math.min(before.length, after.length);
  let at = 0;
  while (at < max && before[at] === after[at]) at++;
  let tail = 0;
  while (tail < max - at && before[before.length - 1 - tail] === after[after.length - 1 - tail]) tail++;
  return {
    at,
    removed: before.slice(at, before.length - tail),
    inserted: after.slice(at, after.length - tail),
  };
}

/**
 * Позиции символов текста в исходнике: `pos[i]` — индекс `text[i]` в `src`.
 * `pos[text.length]` — индекс сразу за последним совпавшим символом.
 * `null`, если текст не является подпоследовательностью исходника (значит, рендер
 * изменил символы — например `++ctrl+c++` → `Ctrl+C`, — и править блок можно только слева).
 */
export function alignToSource(text, src) {
  const pos = new Array(text.length + 1);
  let j = 0;
  for (let i = 0; i < text.length; i++) {
    while (j < src.length && src[j] !== text[i]) j++;
    if (j >= src.length) return null;
    pos[i] = j;
    j++;
  }
  pos[text.length] = j;
  return pos;
}

/**
 * Правка исходника блока по правке его текста в превью.
 * Возвращает `{ from, to, insert }` в координатах `src` или `null`, если сопоставить
 * не удалось (тогда блок возвращается к прежнему виду, а править его можно слева).
 */
export function sourceEdit(before, after, src) {
  if (before === after) return null;
  const { at, removed, inserted } = diffText(before, after);
  const pos = alignToSource(before, src);
  if (!pos) return null;

  // Набранное прилипает к символу слева от каретки — как в любом редакторе. Поэтому
  // вставка идёт сразу за предыдущим совпавшим символом, а не перед следующим: иначе
  // текст, набранный в конце ячейки или перед жирным словом, оказался бы внутри
  // чужой разметки. Удаление ограничено ровно удалёнными символами, чтобы `](ссылка)`
  // и `**` за ними остались на месте.
  const from = at >= before.length ? src.length : removed ? pos[at] : at > 0 ? pos[at - 1] + 1 : pos[0];
  const to = removed ? pos[at + removed.length - 1] + 1 : from;
  if (from > to || to > src.length) return null;
  return { from, to, insert: inserted };
}

/** Позиция каретки (смещение в тексте блока) в координатах исходника блока. */
export function caretToSource(text, src, offset) {
  const pos = alignToSource(text, src);
  if (!pos) return null;
  if (offset >= text.length) return src.length;
  return offset > 0 ? pos[offset - 1] + 1 : pos[0];
}
