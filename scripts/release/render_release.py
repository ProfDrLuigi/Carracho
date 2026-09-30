#!/usr/bin/env python3
from __future__ import annotations

import argparse
import html
import re
from pathlib import Path


def inline(text: str) -> str:
    placeholders: list[str] = []

    def stash(value: str) -> str:
        placeholders.append(value)
        return f"@@HTML{len(placeholders)-1}@@"

    text = re.sub(
        r"\[([^\]]+)\]\(([^)]+)\)",
        lambda m: stash(f'<a href="{html.escape(m.group(2), quote=True)}">{html.escape(m.group(1))}</a>'),
        text,
    )
    text = re.sub(
        r"`([^`]+)`",
        lambda m: stash(f"<code>{html.escape(m.group(1))}</code>"),
        text,
    )
    text = re.sub(
        r"\*\*([^*]+)\*\*",
        lambda m: stash(f"<strong>{html.escape(m.group(1))}</strong>"),
        text,
    )
    escaped = html.escape(text)
    for index, value in enumerate(placeholders):
        escaped = escaped.replace(f"@@HTML{index}@@", value)
    return escaped


def markdown_to_body(markdown: str) -> str:
    lines = markdown.splitlines()
    out: list[str] = []
    paragraph: list[str] = []
    in_list = False
    in_code = False
    code_lines: list[str] = []

    def flush_paragraph() -> None:
        nonlocal paragraph
        if paragraph:
            out.append(f"<p>{inline(' '.join(x.strip() for x in paragraph))}</p>")
            paragraph = []

    def close_list() -> None:
        nonlocal in_list
        if in_list:
            out.append("</ul>")
            in_list = False

    for line in lines:
        if line.startswith("```"):
            flush_paragraph()
            close_list()
            if in_code:
                out.append("<pre><code>" + html.escape("\n".join(code_lines)) + "</code></pre>")
                code_lines = []
                in_code = False
            else:
                in_code = True
            continue
        if in_code:
            code_lines.append(line)
            continue
        if not line.strip():
            flush_paragraph()
            close_list()
            continue
        heading = re.match(r"^(#{1,3})\s+(.+)$", line)
        if heading:
            flush_paragraph()
            close_list()
            level = len(heading.group(1))
            out.append(f"<h{level}>{inline(heading.group(2))}</h{level}>")
            continue
        bullet = re.match(r"^-\s+(.+)$", line)
        if bullet:
            flush_paragraph()
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{inline(bullet.group(1))}</li>")
            continue
        paragraph.append(line)

    flush_paragraph()
    close_list()
    if in_code:
        out.append("<pre><code>" + html.escape("\n".join(code_lines)) + "</code></pre>")
    return "\n".join(out)


def standalone_html(title: str, markdown: str) -> str:
    body = markdown_to_body(markdown)
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="dark">
  <title>{html.escape(title)}</title>
  <link rel="stylesheet" href="../styles.css">
  <style>
    .release-page {{ width:min(calc(100% - 40px), 900px); margin:0 auto; padding:72px 0 110px; }}
    .release-page h1 {{ font-size:clamp(2.8rem,7vw,5rem); margin-bottom:28px; }}
    .release-page h2 {{ margin-top:54px; font-size:2rem; }}
    .release-page h3 {{ margin-top:34px; }}
    .release-page p, .release-page li {{ color:var(--muted-strong); }}
    .release-page code {{ padding:.12em .38em; border-radius:6px; background:rgba(255,255,255,.07); }}
    .release-page pre {{ margin:22px 0; border:1px solid var(--line); border-radius:16px; background:#070b12; }}
    .release-back {{ display:inline-flex; margin-bottom:34px; color:var(--orange-2); text-decoration:none; font-weight:700; }}
  </style>
</head>
<body>
  <main class="release-page">
    <a class="release-back" href="../">← Carracho</a>
{body}
  </main>
</body>
</html>
"""



def highlights(markdown: str) -> list[str]:
    highlights_md = section(markdown, "Highlights")
    return [line[2:].strip() for line in highlights_md.splitlines() if line.startswith("- ")]

def intro_summary(markdown: str) -> str:
    lines = markdown.splitlines()
    paragraph: list[str] = []
    started = False
    for line in lines:
        if line.startswith("# "):
            started = True
            continue
        if not started:
            continue
        if line.startswith("#"):
            break
        if not line.strip():
            if paragraph:
                break
            continue
        paragraph.append(line.strip())
    text = " ".join(paragraph)
    text = re.sub(r"\*\*([^*]+)\*\*", r"\1", text)
    text = re.sub(r"`([^`]+)`", r"\1", text)
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    return text


def section(markdown: str, heading: str) -> str:
    pattern = re.compile(rf"^##\s+{re.escape(heading)}\s*$", re.M)
    match = pattern.search(markdown)
    if not match:
        raise SystemExit(f"Missing release-notes section: ## {heading}")
    start = match.start()
    next_heading = re.search(r"^##\s+", markdown[match.end():], re.M)
    end = match.end() + next_heading.start() if next_heading else len(markdown)
    return markdown[start:end].strip() + "\n"


def first_paragraph_after(lines: list[str], start: int) -> str:
    paragraph: list[str] = []
    for line in lines[start:]:
        if line.startswith("### ") or line.startswith("## "):
            break
        if not line.strip():
            if paragraph:
                break
            continue
        if line.startswith("- "):
            continue
        paragraph.append(line.strip())
    return " ".join(paragraph)



def ensure_client_changelog(path: Path, version: str, build: str, client_markdown: str) -> None:
    content = path.read_text()
    marker = f"New in {version}"
    if marker in content:
        return

    lines = client_markdown.splitlines()
    items: list[str] = [
        f'                <li>Updated the macOS client to version {html.escape(version)} (build {html.escape(build)}).</li>'
    ]
    for index, line in enumerate(lines):
        if not line.startswith("### "):
            continue
        title = line[4:].strip()
        paragraph = first_paragraph_after(lines, index + 1)
        if not paragraph:
            continue
        cleaned = re.sub(r"\*\*([^*]+)\*\*", r"\1", paragraph)
        cleaned = re.sub(r"`([^`]+)`", r"\1", cleaned)
        items.append(
            "                <li><strong>"
            + html.escape(title)
            + "</strong> — "
            + html.escape(cleaned)
            + "</li>"
        )

    block = (
        f'        <p><span class="header" lang="en">New in {html.escape(version)}</span></p>\n'
        "        <ul>\n"
        '            <span class="newstext">\n'
        + "\n".join(items)
        + "\n"
        "        </ul></span>\n\n"
    )
    anchor = re.search(r'\s*<p><span class="header" lang="en">New in [^<]+</span></p>', content)
    if not anchor:
        raise SystemExit(f"Could not find release block anchor in {path}")
    content = content[:anchor.start()] + "\n" + block + content[anchor.start():]
    path.write_text(content)


def ensure_server_changelog(path: Path, version: str, server_markdown: str) -> None:
    content = path.read_text()
    marker = f"New in {version}"
    if marker in content:
        return

    lines = server_markdown.splitlines()
    items: list[str] = [
        f'                <li>Updated Carracho Server for macOS to version {html.escape(version)}.</li>'
    ]
    for index, line in enumerate(lines):
        if not line.startswith("### "):
            continue
        title = line[4:].strip()
        paragraph = first_paragraph_after(lines, index + 1)
        if not paragraph:
            continue
        cleaned = re.sub(r"\*\*([^*]+)\*\*", r"\1", paragraph)
        cleaned = re.sub(r"`([^`]+)`", r"\1", cleaned)
        items.append(
            "                <li><strong>"
            + html.escape(title)
            + "</strong> — "
            + html.escape(cleaned)
            + "</li>"
        )

    block = (
        f'        <p><span class="header" lang="en">New in {html.escape(version)}</span></p>\n'
        "        <ul>\n"
        '            <span class="newstext">\n'
        + "\n".join(items)
        + "\n"
        "        </ul></span>\n\n"
    )
    anchor = re.search(r'\s*<p><span class="header" lang="en">New in [^<]+</span></p>', content)
    if not anchor:
        raise SystemExit(f"Could not find release block anchor in {path}")
    content = content[:anchor.start()] + "\n" + block + content[anchor.start():]
    path.write_text(content)


def update_homepage(path: Path, version: str, build: str, summary: str, release_highlights: list[str]) -> None:
    content = path.read_text()
    content = re.sub(
        r"Carracho\s+\d+\.\d+\.\d+\s+·\s+macOS 10\.15\+",
        f"Carracho {version} · macOS 10.15+",
        content,
        count=1,
    )
    content = re.sub(
        r"<strong>\d+\.\d+\.\d+</strong><span>Current release</span>",
        f"<strong>{version}</strong><span>Current release</span>",
        content,
        count=1,
    )
    content = re.sub(
        r"<strong>\d+</strong><span>Current build</span>",
        f"<strong>{build}</strong><span>Current build</span>",
        content,
        count=1,
    )
    content = re.sub(
        r"(<section id=\"whats-new\".*?<div class=\"eyebrow\">What's new in )[^<]+",
        lambda m: m.group(1) + version,
        content,
        count=1,
        flags=re.S,
    )
    start_marker = "<!-- RELEASE_HIGHLIGHTS_START -->"
    end_marker = "<!-- RELEASE_HIGHLIGHTS_END -->"
    if start_marker not in content or end_marker not in content:
        raise SystemExit(f"Could not find release highlight markers in {path}")
    rendered_highlights = "\n".join(
        f"          <li>{inline(item)}</li>" for item in release_highlights
    )
    start = content.index(start_marker) + len(start_marker)
    end = content.index(end_marker, start)
    content = content[:start] + "\n" + rendered_highlights + "\n          " + content[end:]

    release_match = re.search(
        r'(<section id="release".*?<h2>)Carracho\s+[^<]+(</h2>\s*<p>)(.*?)(</p>)(.*?<a class="button button-primary"[^>]*>)Get\s+[^<]+(</a>)(.*?<a class="text-link" href=")[^"]+(")',
        content,
        re.S,
    )
    if not release_match:
        raise SystemExit(f"Could not update release card in {path}")

    replacement = (
        release_match.group(1)
        + f"Carracho {version}"
        + release_match.group(2)
        + "\n            "
        + html.escape(summary)
        + "\n          "
        + release_match.group(4)
        + release_match.group(5)
        + f"Get {version}"
        + release_match.group(6)
        + release_match.group(7)
        + f"releases/{version}.html"
        + release_match.group(8)
    )
    content = content[: release_match.start()] + replacement + content[release_match.end() :]
    path.write_text(content)



def update_root_readme(path: Path, version: str, build: str, summary: str) -> None:
    content = path.read_text()
    start = content.find("### Current release:")
    if start < 0:
        raise SystemExit(f"Could not find current release block in {path}")
    end = content.find("\n## At a glance", start)
    if end < 0:
        raise SystemExit(f"Could not find end of current release block in {path}")
    replacement = (
        f"### Current release: {version}\n\n"
        + summary
        + "\n\n"
        + f"The full release notes are available in [`README_{version}.md`](README_{version}.md).\n"
    )
    path.write_text(content[:start] + replacement + content[end:])

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--notes", type=Path, required=True)
    parser.add_argument("--client-changelog", type=Path, required=True)
    parser.add_argument("--server-changelog", type=Path, required=True)
    parser.add_argument("--docs-index", type=Path, required=True)
    parser.add_argument("--docs-releases", type=Path, required=True)
    parser.add_argument("--root-readme", type=Path, required=True)
    args = parser.parse_args()

    markdown = args.notes.read_text()
    expected_title = f"# Carracho {args.version}"
    if expected_title not in markdown:
        raise SystemExit(f"{args.notes} does not describe Carracho {args.version}")

    client_md = section(markdown, f"Carracho Client {args.version}")
    server_md = section(markdown, f"Carracho Server {args.version}")
    args.docs_releases.mkdir(parents=True, exist_ok=True)
    (args.docs_releases / f"{args.version}.html").write_text(
        standalone_html(f"Carracho {args.version}", markdown)
    )
    (args.docs_releases / f"Carracho-Client-{args.version}.html").write_text(
        standalone_html(f"Carracho Client {args.version}", client_md)
    )
    (args.docs_releases / f"Carracho-Server-{args.version}.html").write_text(
        standalone_html(f"Carracho Server {args.version}", server_md)
    )

    summary = intro_summary(markdown)
    ensure_client_changelog(args.client_changelog, args.version, args.build, client_md)
    ensure_server_changelog(args.server_changelog, args.version, server_md)
    update_homepage(args.docs_index, args.version, args.build, summary, highlights(markdown))
    update_root_readme(args.root_readme, args.version, args.build, summary)


if __name__ == "__main__":
    main()
