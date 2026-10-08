#!/usr/bin/env python3
"""Prepare Server-only GitHub Release notes/changelog from the shared source checkout.

The development repository remains unchanged in structure; the public Server repository
contains only README, CHANGELOG, and ZIP assets attached to GitHub Releases.
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path


RELEASES_REPO = "ProfDrLuigi/Carracho-Server"
SOURCE_REPO = "ProfDrLuigi/Carracho"


def server_section(notes: str, version: str) -> str:
    heading = re.search(rf"^## Carracho Server {re.escape(version)}\s*$", notes, re.M)
    if not heading:
        raise ValueError(f"Missing ## Carracho Server {version} section")
    tail = notes[heading.end():]
    next_heading = re.search(r"^## ", tail, re.M)
    section = tail[:next_heading.start() if next_heading else len(tail)].strip()
    if not section.startswith("### "):
        raise ValueError(f"Server {version} release notes have no detailed features")
    return section


def versions_and_notes(source: Path, current_version: str, build: str) -> list[tuple[str, str, str]]:
    result: dict[str, tuple[str, str]] = {}
    # Preserve the first appearance and prefer the original version-specific notes.
    # Later shared releases that merely restate an older Server version are ignored.
    for file in sorted(source.glob('README_*.md')):
        if not re.fullmatch(r'README_\d+\.\d+\.\d+\.md', file.name):
            continue
        text = file.read_text()
        for match in re.finditer(r'^## Carracho Server (\d+\.\d+\.\d+)\s*$', text, re.M):
            version = match.group(1)
            if version not in result or file.name == f'README_{version}.md':
                section = server_section(text, version)
                # Release build comes from historical changelog text for older releases.
                result[version] = (section, '')
    if current_version not in result:
        raise ValueError(f"No release notes for Server {current_version}")
    # The current Server version may first appear in a newer shared release train,
    # e.g. Server 1.1.7 inside README_1.1.9.md. The loop above already selects it.
    result[current_version] = (result[current_version][0], build)
    historical_builds = {'1.1.3': '14', '1.1.4': '15', '1.1.5': '16', '1.1.6': '17'}
    versions = sorted((v for v in result if (1, 1, 3) <= tuple(map(int, v.split('.'))) <= tuple(map(int, current_version.split('.')))),
                      key=lambda v: tuple(map(int, v.split('.'))), reverse=True)
    return [(v, result[v][0], result[v][1] or historical_builds.get(v, '')) for v in versions]


def release_body(version: str, build: str, contents: str) -> str:
    return (f"# Carracho Server {version}" + (f" (Build {build})" if build else "") +
            "\n\n" + contents + "\n\n"
            "**Installationshinweis:** Bei macOS müssen Server-App und installierter Hintergrunddienst aktualisiert werden. "
            "Vor dem Update den Datenbankordner einschließlich vorhandener WAL-/SHM-Dateien sichern.\n\n"
            f"Source code: https://github.com/{SOURCE_REPO}\n")


def write_public_metadata(source: Path, dest: Path, version: str, build: str) -> None:
    histories = versions_and_notes(source, version, build)
    dest.mkdir(parents=True, exist_ok=True)
    readme = (f"# Carracho Server\n\n"
              f"Offizielle Downloads und Versionshinweise für **Carracho Server**. "
              f"Die Server-GUI, der System-Daemon und die Linux-Builds werden im gemeinsamen "
              f"[Carracho-Quellcodeprojekt](https://github.com/{SOURCE_REPO}) entwickelt.\n\n"
              f"- **[Server-ZIP-Dateien](https://github.com/{RELEASES_REPO}/releases)** "
              f"liegen ausschließlich bei den GitHub-Releases, nicht im Git-Verlauf.\n"
              f"- **[Server-Changelog](CHANGELOG.md)** enthält nur Server-Änderungen.\n"
              f"- Aktuelle Server-Version: **{version} (Build {build})**.\n\n"
              "Der Client hat [eigene Releases](https://github.com/ProfDrLuigi/Carracho/releases). "
              "Beide Programme bleiben im selben Xcode-Projekt und werden unabhängig veröffentlicht.\n")
    changelog = ("# Carracho Server: Changelog\n\n"
                 "Versionsnummern und Veröffentlichungen des Servers sind vom Client unabhängig.\n\n" +
                 "\n\n".join(f"## {v}" + (f" (Build {b})" if b else "") + "\n\n" + body
                              for v, body, b in histories) + "\n")
    (dest / 'README.md').write_text(readme)
    (dest / 'CHANGELOG.md').write_text(changelog)
    (dest / f'RELEASE_NOTES_{version}.md').write_text(release_body(version, build, histories[0][1]))


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument('--source', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--version', required=True)
    p.add_argument('--build', required=True)
    args = p.parse_args()
    write_public_metadata(args.source, args.output, args.version, args.build)


if __name__ == '__main__':
    main()
