#!/usr/bin/env python3
"""One-time migration of existing signed Server ZIPs to the Server-only GitHub repo.

No mutation without --publish. The original ZIP bytes (and EdDSA signatures) are
preserved. GitHub Releases are created oldest-first so newest is marked latest.
The existing Sparkle appcast and historical download URLs remain unchanged.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

from server_release_notes import RELEASES_REPO, release_body, versions_and_notes

NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def artifacts(source: Path) -> list[tuple[str, str, Path, str]]:
    feed = ET.parse(source / 'docs/server/appcast.xml').getroot()
    signed = {}
    for item in feed.findall('./channel/item'):
        version = (item.findtext('title') or '').strip()
        build = item.findtext(f'{NS}version')
        enclosure = item.find('enclosure')
        if build and enclosure is not None:
            signed[version] = (build, enclosure.attrib)
    output = []
    for version, body, build in sorted(versions_and_notes(source, '1.1.7', '18'),
                                        key=lambda row: tuple(map(int, row[0].split('.')))):
        zip_path = source / '.build' / 'publish-server' / version / f'Carracho-Server-{version}.zip'
        if not zip_path.is_file():
            raise ValueError(f'Missing existing signed Server ZIP for {version}: {zip_path}')
        old_build, info = signed[version]
        if old_build != build:
            raise ValueError(f'Server {version}: build {old_build} != expected {build}')
        if int(info['length']) != zip_path.stat().st_size:
            raise ValueError(f'Server {version}: local archive size differs from signed appcast')
        if not info.get(f'{NS}edSignature'):
            raise ValueError(f'Server {version}: missing published EdDSA signature')
        output.append((version, build, zip_path, body))
    return output


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[2])
    p.add_argument('--publish', action='store_true', help='Create/update independent GitHub Releases')
    args = p.parse_args()
    manifest = artifacts(args.source)
    for version, build, zip_path, _ in manifest:
        print(f'{version} (Build {build}): {zip_path.name}, {zip_path.stat().st_size} bytes, '
              f'SHA-256 {hashlib.sha256(zip_path.read_bytes()).hexdigest()[:16]}…')
    if not args.publish:
        print(f'DRY RUN: {len(manifest)} existing Server ZIPs are ready for {RELEASES_REPO}; no uploads performed')
        return
    if not os.environ.get('GITHUB_TOKEN'):
        raise SystemExit('GITHUB_TOKEN is required for --publish (load securely from login Keychain)')
    helper = args.source / 'scripts/release/github_release.py'
    with tempfile.TemporaryDirectory(prefix='carracho-server-migration-') as scratch:
        for version, build, zip_path, notes in manifest:
            body_path = Path(scratch) / f'release-{version}.md'
            body_path.write_text(release_body(version, build, notes))
            subprocess.run([sys.executable, str(helper), '--repo', RELEASES_REPO,
                            '--tag', f'v{version}', '--title', f'Carracho Server {version}',
                            '--notes', str(body_path), '--asset', str(zip_path), '--target', 'main'],
                           env=os.environ, check=True)
    print('Published Server ZIPs to the independent repository; original legacy appcast unchanged')


if __name__ == '__main__':
    main()
