#!/usr/bin/env python3
"""Иконки вики для веб-редактора.

Собирает SVG иконок, которые встречаются на страницах (`:material-cog:` и подобные),
в один файл `docs/assets/editor/icons.json`. Превью редактора рисует их так же, как
сайт: сам редактор собирается без темы Material и SVG взять ему больше неоткуда.

Запуск (из корня репозитория, в venv с mkdocs-material):

    python3 contrib/editor-icons.py

Иконки, которых в файле нет, превью покажет серым квадратиком — после добавления
новой иконки на страницу скрипт нужно прогнать снова (в CI он запускается сам).
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
OUT = DOCS / "assets" / "editor" / "icons.json"

# :material-cog:, :fontawesome-brands-telegram:, :octicons-alert-16:, :simple-github:
SHORTCODE = re.compile(r":((?:material|fontawesome|octicons|simple)-[a-z0-9-]+):")


def icons_dir() -> Path:
    try:
        import material
    except ImportError:
        sys.exit("Нужна тема mkdocs-material: pip install -r requirements.txt")
    path = Path(material.__file__).resolve().parent / "templates" / ".icons"
    if not path.is_dir():
        sys.exit(f"Не нашёл иконки темы: {path}")
    return path


def svg_path(base: Path, name: str) -> Path:
    """Имя из шорткода → файл набора: у fontawesome ещё и стиль (brands, solid…)."""
    group, rest = name.split("-", 1)
    if group == "fontawesome":
        style, rest = rest.split("-", 1)
        return base / group / style / f"{rest}.svg"
    return base / group / f"{rest}.svg"


def clean(svg: str) -> str:
    svg = re.sub(r"<\?xml.*?\?>|<!--.*?-->", "", svg, flags=re.S)
    return re.sub(r"\s+", " ", svg).strip()


def main() -> int:
    base = icons_dir()
    used: set[str] = set()
    for page in DOCS.rglob("*.md"):
        used |= set(SHORTCODE.findall(page.read_text(encoding="utf-8")))

    icons: dict[str, str] = {}
    missing: list[str] = []
    for name in sorted(used):
        file = svg_path(base, name)
        if file.is_file():
            icons[name] = clean(file.read_text(encoding="utf-8"))
        else:
            missing.append(name)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(icons, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")

    size = OUT.stat().st_size
    print(f"{OUT.relative_to(ROOT)}: иконок {len(icons)}, {size / 1024:.1f} КБ")
    if missing:
        print("не нашлись в теме: " + ", ".join(missing))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
