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

    def test_migration_checks_published_zip_before_reusing_it(self):
        # An aborted republish can overwrite the local ZIP with different bytes.
        # Tests must use a disposable fixture, not assume the live build directory
        # still contains the originally published EdDSA-signed archive.
        from importlib.util import spec_from_file_location, module_from_spec
        from unittest.mock import patch
        import sys
        repo_scripts = str(ROOT/'scripts/release')
        spec = spec_from_file_location('migrate_server_releases',
                                       ROOT/'scripts/release/migrate_server_releases.py')
        sys.path.insert(0, repo_scripts)
        try:
            module = module_from_spec(spec)
            spec.loader.exec_module(module)
        finally:
            sys.path.remove(repo_scripts)

        with tempfile.TemporaryDirectory(prefix='carracho-server-signed-zip-') as scratch:
            source = Path(scratch)
            package = source/'.build/publish-server/1.1.7/Carracho-Server-1.1.7.zip'
            package.parent.mkdir(parents=True)
            package.write_bytes(b'test-archive')
            feed = source/'docs/server/appcast.xml'
            feed.parent.mkdir(parents=True)
            feed.write_text('''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
                <channel><item><title>1.1.7</title><sparkle:version>18</sparkle:version>
                <enclosure length="12" sparkle:edSignature="base64-signature" /></item></channel>
                </rss>''' )
            with patch.object(module, 'versions_and_notes', return_value=[('1.1.7','fix notes','18')]):
                entries = module.artifacts(source)
                self.assertEqual([entry[0] for entry in entries], ['1.1.7'])
                package.write_bytes(b'different-length')
                with self.assertRaisesRegex(ValueError, 'local archive size differs'):
                    module.artifacts(source)

    def test_token_preflight_rejects_missing_repository_push_permission(self):
        script = (ROOT/'scripts/release/publish_server.sh').read_text()
        self.assertIn('permissions.get("push") is not True', script)
        self.assertIn('include BOTH Carracho and Carracho-Server', script)
        self.assertLess(script.index('metadata = json.load(response)'),
                        script.index('with urllib.request.urlopen(request):'))

    def test_client_publisher_unchanged(self):
        script=(ROOT/'scripts/release/publish_client.sh').read_text()
        self.assertIn('GITHUB_REPO="ProfDrLuigi/Carracho"',script)


if __name__=='__main__':
    unittest.main()
