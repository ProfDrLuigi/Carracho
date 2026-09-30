#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
VERSION_TAG = f"{{{SPARKLE_NS}}}version"
HARDWARE_TAG = f"{{{SPARKLE_NS}}}hardwareRequirements"


def parse(path: Path) -> ET.Element:
    try:
        return ET.parse(path).getroot()
    except (OSError, ET.ParseError) as exc:
        raise SystemExit(f"{path}: invalid appcast XML: {exc}") from exc


def matching_items(root: ET.Element, build: str) -> list[ET.Element]:
    matches: list[ET.Element] = []
    for item in root.findall("./channel/item"):
        version = item.find(VERSION_TAG)
        if version is not None and (version.text or "").strip() == build:
            matches.append(item)
    return matches


def drop_version(path: Path, build: str) -> None:
    root = parse(path)
    matches = matching_items(root, build)
    if not matches:
        return
    if len(matches) != 1:
        raise SystemExit(f"{path}: expected at most one item for build {build}, found {len(matches)}")

    text = path.read_text(encoding="utf-8")
    item_pattern = re.compile(
        r"(?ms)^[ \t]*<item(?:\s[^>]*)?>\s*.*?^[ \t]*</item>\s*\n?"
    )
    version_pattern = re.compile(
        rf"<sparkle:version>\s*{re.escape(build)}\s*</sparkle:version>"
    )

    spans = [
        match.span()
        for match in item_pattern.finditer(text)
        if version_pattern.search(match.group(0))
    ]
    if len(spans) != 1:
        raise SystemExit(
            f"{path}: could not uniquely locate XML text for build {build} "
            f"(found {len(spans)} matching item blocks)"
        )

    start, end = spans[0]
    updated = text[:start] + text[end:]

    try:
        ET.fromstring(updated)
    except ET.ParseError as exc:
        raise SystemExit(f"{path}: removing build {build} would create invalid XML: {exc}") from exc

    path.write_text(updated, encoding="utf-8")


def verify_universal(path: Path, build: str) -> None:
    root = parse(path)
    matches = matching_items(root, build)
    if len(matches) != 1:
        raise SystemExit(f"{path}: expected exactly one item for build {build}, found {len(matches)}")

    requirement = matches[0].find(HARDWARE_TAG)
    if requirement is None:
        return

    tokens = {
        token.strip().lower()
        for token in (requirement.text or "").split(",")
        if token.strip()
    }
    if "arm64" in tokens:
        raise SystemExit(
            f"{path}: build {build} is Universal 2 but appcast still requires arm64"
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    drop = subparsers.add_parser(
        "drop-version",
        help="Remove an existing item so Sparkle can re-infer metadata for a republished build.",
    )
    drop.add_argument("appcast", type=Path)
    drop.add_argument("build")

    verify = subparsers.add_parser(
        "verify-universal",
        help="Fail if the selected appcast item incorrectly requires arm64.",
    )
    verify.add_argument("appcast", type=Path)
    verify.add_argument("build")

    args = parser.parse_args()
    if args.command == "drop-version":
        drop_version(args.appcast, args.build)
    elif args.command == "verify-universal":
        verify_universal(args.appcast, args.build)
    else:
        raise AssertionError(args.command)


if __name__ == "__main__":
    main()
