"""Failures uploading a Server ZIP must never appear as a successful publication."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import urllib.error
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]

spec = importlib.util.spec_from_file_location('carracho_github_release', ROOT / 'scripts/release/github_release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class GitHubReleaseUploadSafetyTests(unittest.TestCase):
    def fake_404(self, request, timeout=None):
        raise urllib.error.HTTPError(request.full_url, 404, 'not found', {}, io.BytesIO(b'not found'))

    def test_missing_release_tag_is_expected(self):
        with patch.object(release.urllib.request, 'urlopen', side_effect=self.fake_404):
            self.assertEqual(
                release.request('hidden-token', 'GET',
                                'https://api.github.com/repos/ProfDrLuigi/Carracho-Server/releases/tags/v1.1.7'),
                (404, None))

    def test_missing_archive_upload_endpoint_is_fatal(self):
        with patch.object(release.urllib.request, 'urlopen', side_effect=self.fake_404):
            with self.assertRaises(SystemExit):
                release.request('hidden-token', 'POST',
                                'https://uploads.github.com/repos/ProfDrLuigi/Carracho-Server/releases/12/assets?name=Carracho-Server-1.1.7.zip',
                                b'zip-data', 'application/zip')

    def test_missing_release_creation_is_fatal(self):
        with patch.object(release.urllib.request, 'urlopen', side_effect=self.fake_404):
            with self.assertRaises(SystemExit):
                release.request('hidden-token', 'POST',
                                'https://api.github.com/repos/ProfDrLuigi/Carracho-Server/releases',
                                b'{}')


if __name__ == '__main__':
    unittest.main()
