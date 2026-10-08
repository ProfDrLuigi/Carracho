"""Server ZIP publishing must stay separate from Client source and releases."""
from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class ServerReleaseSeparationTests(unittest.TestCase):
    def test_prepared_metadata_is_server_only_and_idempotent(self):
        with tempfile.TemporaryDirectory(prefix='carracho-server-releases-') as scratch:
            destination = Path(scratch)
            cmd = [
                'python3','-B',str(ROOT/'scripts/release/server_release_notes.py'),
                '--source', str(ROOT), '--output', str(destination),
                '--version', '1.1.7', '--build', '18',
            ]
            subprocess.run(cmd, check=True, capture_output=True, text=True)
            before = {f.name:f.read_bytes() for f in destination.iterdir()}
            subprocess.run(cmd, check=True, capture_output=True, text=True)
            self.assertEqual(before,{f.name:f.read_bytes() for f in destination.iterdir()})
            self.assertEqual(set(before),{'README.md','CHANGELOG.md','RELEASE_NOTES_1.1.7.md'})
            changelog = (destination/'CHANGELOG.md').read_text()
            for ver in ('1.1.7','1.1.6','1.1.5','1.1.4','1.1.3'):
                self.assertIn('## '+ver+' (Build ',changelog)
            self.assertNotIn('## Carracho Client',changelog)
            latest = (destination/'RELEASE_NOTES_1.1.7.md').read_text()
            self.assertIn('prevent account loss',latest)
            self.assertNotIn('Guest chat Online status',latest)
            self.assertIn('Source code:',latest)

    def test_server_publisher_targets_only_separate_github_release(self):
        script = (ROOT/'scripts/release/publish_server.sh').read_text()
        self.assertIn('GITHUB_REPO="ProfDrLuigi/Carracho-Server"', script)
        self.assertIn('TAG="v${SERVER_VERSION}"',script)
        self.assertIn('scripts/release/server_release_notes.py',script)
        self.assertIn('git_push_with_token -C "$SERVER_REPO_WORKDIR" push origin main',script)
        self.assertIn('--repo "$GITHUB_REPO"',script)
        self.assertIn('--notes "$RELEASE_NOTES"',script)
        self.assertIn('DOCS_SERVER="$ROOT/docs/server"',script)
        self.assertNotIn('git_push_with_token push origin "refs/tags/',script)
        self.assertNotIn('Creating/verifying shared release tag',script)
        # A signed appcast must never announce a Server ZIP before GitHub accepted it.
        self.assertLess(script.index('python3 "$ROOT/scripts/release/github_release.py"'),
                        script.index('git_push_with_token -C "$SERVER_REPO_WORKDIR" push origin main'))
        self.assertLess(script.index('scripts/release/github_release.py'),
                        script.index('cp "$FEED_DIR/appcast.xml" "$DOCS_SERVER/appcast.xml"'))
        self.assertIn('https://github.com/$GITHUB_REPO/releases/download/$TAG/', script)

    def test_signed_existing_server_zips_are_migration_ready(self):
        from importlib.util import spec_from_file_location, module_from_spec
        spec = spec_from_file_location('migrate_server_releases',
                                       ROOT/'scripts/release/migrate_server_releases.py')
        # The script imports a sibling module; add its directory only during loading.
        import sys
        sys.path.insert(0, str(ROOT/'scripts/release'))
        try:
            module = module_from_spec(spec)
            spec.loader.exec_module(module)
            archives = module.artifacts(ROOT)
        finally:
            sys.path.remove(str(ROOT/'scripts/release'))
        self.assertEqual([item[0] for item in archives],
                         ['1.1.3','1.1.4','1.1.5','1.1.6','1.1.7'])
        self.assertTrue(all(item[2].stat().st_size > 10_000_000 for item in archives))

    def test_client_publisher_unchanged(self):
        script=(ROOT/'scripts/release/publish_client.sh').read_text()
        self.assertIn('GITHUB_REPO="ProfDrLuigi/Carracho"',script)


if __name__=='__main__':
    unittest.main()
