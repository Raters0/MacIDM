#!/usr/bin/env python3
"""Render bilingual release notes as Sparkle appcast <description> elements.

Usage: render-release-notes.py <notes.md>

The notes file holds the English text, a line with only ---, then the
Chinese text (the GitHub Release format). Each half becomes HTML in a CDATA
description: English is the default, Chinese is tagged xml:lang zh-Hans/zh,
so Sparkle's update window shows the notes in the app's language without
loading the GitHub page. Supports the subset the notes use: ## headings,
- bullets, paragraphs, **bold** and `code`.
"""
import html
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
halves = re.split(r"^---\s*$", text, maxsplit=1, flags=re.M)
english, chinese = halves[0], (halves[1] if len(halves) > 1 else "")


def inline(value):
    value = html.escape(value, quote=False)
    value = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", value)
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", value)


def render(markdown):
    out, items, paragraph = [], [], []

    def flush():
        if items:
            out.append("<ul>" + "".join(f"<li>{i}</li>" for i in items) + "</ul>")
            items.clear()
        if paragraph:
            out.append("<p>" + inline(" ".join(paragraph)) + "</p>")
            paragraph.clear()

    for line in markdown.strip().splitlines():
        stripped = line.strip()
        if not stripped:
            flush()
        elif stripped.startswith("## "):
            flush()
            out.append(f"<h3>{inline(stripped[3:])}</h3>")
        elif stripped.startswith("- "):
            if paragraph:
                flush()
            items.append(inline(stripped[2:]))
        else:
            paragraph.append(stripped)
    flush()
    style = "<style>body{font:13px -apple-system,sans-serif;line-height:1.45}h3{font-size:13px;margin:12px 0 4px}ul{padding-left:18px}code{font:12px ui-monospace,monospace}</style>"
    return (style + "".join(out)).replace("]]>", "]]&gt;")


blocks = [f"<description><![CDATA[{render(english)}]]></description>"]
if chinese.strip():
    for lang in ("zh-Hans", "zh"):
        blocks.append(f'<description xml:lang="{lang}"><![CDATA[{render(chinese)}]]></description>')
print("\n            ".join(blocks))
