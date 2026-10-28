#!/usr/bin/env python3
"""Проверка оформления страниц вики по правилам STYLE.md.

Запуск из корня репозитория:

    python3 contrib/wikilint.py                # все страницы в docs/
    python3 contrib/wikilint.py docs/start     # только часть
    python3 contrib/wikilint.py --stats        # сводка по страницам без замечаний

Код возврата 1, если есть замечания уровня error. Предупреждения (warning) код не меняют:
это места, где правило можно нарушить осознанно.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"

MAX_LINE = 100
MAX_ADMONITIONS = 3
MAX_INLINE_CODE_PER_LINE = 0.34  # примерно одно вкрапление на три строки текста

# Обороты, которые ничего не сообщают читателю (STYLE.md → «Фразы»).
FILLER = [
    r"стоит отметить",
    r"важно (?:понимать|отметить|помнить)",
    r"следует (?:иметь в виду|учитывать|отметить)",
    r"необходимо отметить",
    r"как (?:уже )?было сказано выше",
    r"в данной (?:статье|инструкции)",
    r"в этой статье мы",
    r"мы рассмотрим",
    r"рекомендуется (?:выполнить|использовать|сделать)",
    r"не гарантирует",
    r"зависит от выбранного",
    r"на (?:данный|текущий) момент",
    r"в настоящее время",
    r"обратите внимание,",
    r"\bпросто (?:запустите|выполните|скачайте|откройте)",
    r"достаточно (?:выполнить|запустить|открыть)",
]

# Жаргон без расшифровки (STYLE.md → «Термины»).
JARGON = {
    r"\b(?:локальн\w+|св\w+) стенд\w*": "свой сервер обновлений на компьютере",
    r"речев\w+ тракт\w*": "путь звука от микрофона до ответа",
    r"голосов\w+ цикл\w*": "путь звука от микрофона до ответа",
    r"\bмок\w*\b": "заглушка",
}

VAGUE_LINK = re.compile(r"\[(?:здесь|тут|по ссылке|сюда|подробнее)\]\(", re.I)
BARE_URL = re.compile(r"(?<![(<\[/\w])https?://\S+")
FENCE = re.compile(r"^\s*(```|~~~)(.*)$")
ADMONITION = re.compile(r"^\s*(!!!|\?\?\?)\+? *([a-z-]+) *(\"[^\"]*\")?")
HEADING = re.compile(r"^(#{1,6}) +(.*?)\s*(\{ *#([^}]+) *\})?\s*$")
INLINE_CODE = re.compile(r"`[^`\n]+`")
CYRILLIC = re.compile(r"[а-яё]", re.I)


@dataclass
class Note:
    line: int
    level: str
    rule: str
    text: str


class Page:
    """Разбор одной страницы: что код, что текст, что внутри блоков."""

    def __init__(self, path: Path):
        self.path = path
        self.lines = path.read_text(encoding="utf-8").splitlines()
        self.notes: list[Note] = []
        self.in_code: list[bool] = []
        fence: str | None = None
        for line in self.lines:
            m = FENCE.match(line)
            if m and fence is None:
                fence = m.group(1)
                self.in_code.append(True)
            elif m and fence and line.strip().startswith(fence):
                fence = None
                self.in_code.append(True)
            else:
                self.in_code.append(fence is not None)

    def add(self, line: int, level: str, rule: str, text: str) -> None:
        self.notes.append(Note(line, level, rule, text))

    def prose(self):
        """Строки обычного текста: без кода, таблиц, html и ссылок-сносок."""
        for i, line in enumerate(self.lines, 1):
            if self.in_code[i - 1]:
                continue
            s = line.strip()
            if not s or s.startswith(("|", "<", ">", "[")) or s.startswith("---"):
                continue
            yield i, line


def check_lines(page: Page) -> None:
    for i, line in enumerate(page.lines, 1):
        if len(line) <= MAX_LINE:
            continue
        s = line.strip()
        # у длинных ссылок, таблиц и команд переносить нечего
        if page.in_code[i - 1] or s.startswith(("|", "[", "<")) or "](" in s and len(s) - len(
            re.sub(r"\]\([^)]*\)", "", s)
        ) > 40:
            continue
        page.add(i, "error", "line-length", f"строка {len(line)} символов, предел {MAX_LINE}")

    for i, line in page.prose():
        if re.match(r"^\s*\* ", line):
            page.add(i, "error", "list-marker", "список через `*`, нужен `-`")

    # отдельно от prose(): там строки с «---» отсеиваются как разделители таблиц
    for i, line in enumerate(page.lines, 1):
        if page.in_code[i - 1] or i <= 5:
            continue
        if re.match(r"^---+\s*$", line) and (i < 2 or not page.lines[i - 2].strip()):
            page.add(i, "warning", "hr", "горизонтальная линия вместо заголовка")


def check_phrases(page: Page) -> None:
    for i, raw in page.prose():
        line = INLINE_CODE.sub("`код`", raw)  # внутри `…` правила про текст не действуют
        low = line.lower()
        for pat in FILLER:
            m = re.search(pat, low)
            if m:
                page.add(i, "warning", "filler", f"пустой оборот: «{m.group(0)}»")
        for pat, hint in JARGON.items():
            m = re.search(pat, low)
            if m:
                page.add(i, "warning", "jargon", f"«{m.group(0)}» → {hint}")
        if VAGUE_LINK.search(line):
            page.add(i, "error", "link-text", "ссылка «здесь/подробнее»: в тексте ссылки должно быть видно, куда она ведёт")
        if BARE_URL.search(line):
            page.add(i, "warning", "bare-url", "голый URL в тексте")
        if line.count("(") > 1 and re.search(r"\([^)]*\([^)]*\)", line):
            page.add(i, "warning", "nested-parens", "скобки внутри скобок")
        if re.match(r"^\s*\*[^*]+\*\s*$", line.strip()):
            page.add(i, "warning", "all-italic", "абзац целиком курсивом")
        if "!" in line and re.search(r"\w!(?:\s|$)", line) and not line.strip().startswith("!!!"):
            page.add(i, "warning", "exclamation", "восклицательный знак")


def check_code(page: Page) -> None:
    opened: list[tuple[int, str]] = []
    fence: str | None = None
    for i, line in enumerate(page.lines, 1):
        m = FENCE.match(line)
        if not m:
            continue
        if fence is None:
            fence = m.group(1)
            info = m.group(2).strip()
            opened.append((i, info))
            if not info:
                page.add(i, "error", "code-lang", "у блока кода не указан язык")
        elif line.strip().startswith(fence):
            fence = None

    text_blocks = [i for i, info in opened if info.startswith("text")]
    for i in text_blocks:
        body = []
        for j in range(i, min(i + 30, len(page.lines))):
            if j > i and FENCE.match(page.lines[j]):
                break
            body.append(page.lines[j])
        joined = "\n".join(body)
        # дерево каталогов или вывод программы — законный текст; схема — та, где есть стрелки
        art = [ln for ln in body if re.search(r"[▶◄►◀←→⟶]|[-=]{2,}>|<[-=]{2,}", ln)]
        if len(art) >= 3:
            page.add(i, "warning", "ascii-art", "псевдографика в блоке кода: нужна схема Mermaid")


def check_density(page: Page) -> None:
    prose = list(page.prose())
    if len(prose) < 20:
        return
    hits = sum(len(INLINE_CODE.findall(line)) for _, line in prose)
    density = hits / len(prose)
    if density > MAX_INLINE_CODE_PER_LINE:
        page.add(
            1,
            "warning",
            "code-density",
            f"инлайн-кода {hits} на {len(prose)} строк текста "
            f"({density:.2f} на строку, предел {MAX_INLINE_CODE_PER_LINE})",
        )


def check_admonitions(page: Page) -> None:
    found = []
    for i, line in enumerate(page.lines, 1):
        if page.in_code[i - 1]:
            continue
        m = ADMONITION.match(line)
        if not m:
            continue
        found.append((i, m.group(2), m.group(3), m.group(1) == "???"))
        if not m.group(3):
            page.add(i, "error", "admonition-title", f"блок `{m.group(2)}` без заголовка")
    for i, _, title, _collapsed in found:
        if not title:
            continue
        words = [w for w in re.findall(r"\w+", title.lower()) if len(w) > 3]
        first = page.lines[i].strip().lower() if i < len(page.lines) else ""
        # эхо — когда первая же строка повторяет почти все слова заголовка и немногим длиннее
        if words and len(first) < len(title) * 2.2 and all(w in first for w in words):
            page.add(i + 1, "warning", "admonition-echo",
                     "первая строка повторяет заголовок блока")

    # лимит — на видимые блоки; свёрнутые «???» для того и нужны, чтобы прятать частности
    visible = [
        f for f in found
        if f[1] and not f[1].startswith(("abstract", "example")) and not f[3]
    ]
    if len(visible) > MAX_ADMONITIONS:
        page.add(
            visible[MAX_ADMONITIONS][0],
            "warning",
            "admonition-count",
            f"выделенных блоков {len(visible)}, предел {MAX_ADMONITIONS}",
        )
    for (i, _, _, _), (j, _, _, _) in zip(found, found[1:]):
        if j - i <= 4:
            page.add(j, "warning", "admonition-stack", "два блока подряд: объединить в один")


def check_headings(page: Page) -> None:
    seen: dict[str, tuple[int, bool]] = {}
    levels: list[int] = []
    no_anchor: list[str] = []
    for i, line in enumerate(page.lines, 1):
        if page.in_code[i - 1]:
            continue
        m = HEADING.match(line)
        if not m:
            continue
        level, title, _, anchor = len(m.group(1)), m.group(2), m.group(3), m.group(4)
        key = title.strip().lower()
        if key in seen:
            # повтор допустим у параллельных подразделов, если якоря заданы явно
            level_ok = anchor and seen[key][1]
            page.add(
                i,
                "warning" if level_ok else "error",
                "heading-dup",
                f"заголовок «{title}» уже был (строка {seen[key][0]})",
            )
        seen[key] = (i, bool(anchor))
        if levels and level > levels[-1] + 1:
            page.add(i, "error", "heading-skip", f"уровень h{level} после h{levels[-1]}")
        levels.append(level)
        if level > 1 and CYRILLIC.search(title) and not anchor:
            no_anchor.append(title)
        if "](" in title:
            page.add(i, "warning", "heading-link", "ссылка в заголовке")
    if no_anchor:
        page.add(
            1,
            "warning",
            "heading-anchor",
            f"заголовков по-русски без явного якоря: {len(no_anchor)} "
            f"(первый — «{no_anchor[0]}»)",
        )
    if levels.count(1) > 1:
        page.add(1, "error", "heading-h1", f"заголовков первого уровня {levels.count(1)}, нужен один")


CHECKS = [check_lines, check_phrases, check_code, check_density, check_admonitions, check_headings]


def lint(path: Path) -> Page:
    page = Page(path)
    for check in CHECKS:
        check(page)
    page.notes.sort(key=lambda n: (n.line, n.rule))
    return page


def main() -> int:
    parser = argparse.ArgumentParser(description="Проверка оформления страниц вики")
    parser.add_argument("paths", nargs="*", default=[], help="файлы или каталоги (по умолчанию docs/)")
    parser.add_argument("--stats", action="store_true", help="сводка по страницам")
    parser.add_argument("--errors", action="store_true", help="только ошибки, без предупреждений")
    args = parser.parse_args()

    targets: list[Path] = []
    for raw in args.paths or [DOCS]:
        p = Path(raw)
        if not p.exists():
            sys.exit(f"не найдено: {p}")
        targets.extend(sorted(p.rglob("*.md")) if p.is_dir() else [p])

    errors = warnings = 0
    rows = []
    for path in targets:
        page = lint(path)
        notes = [n for n in page.notes if not (args.errors and n.level == "warning")]
        errors += sum(1 for n in page.notes if n.level == "error")
        warnings += sum(1 for n in page.notes if n.level == "warning")
        try:
            rel = path.resolve().relative_to(ROOT)
        except ValueError:
            rel = path
        rows.append((len(page.notes), str(rel)))
        if notes:
            print(f"\n{rel}")
            for n in notes:
                mark = "E" if n.level == "error" else "w"
                print(f"  {mark} {n.line:>4}  {n.rule:<18} {n.text}")

    if args.stats:
        print("\nЗамечаний по страницам:")
        for count, rel in sorted(rows, reverse=True)[:20]:
            print(f"  {count:>4}  {rel}")

    print(f"\nСтраниц: {len(targets)}; ошибок: {errors}, предупреждений: {warnings}")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
