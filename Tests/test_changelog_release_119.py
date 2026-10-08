"""Regression: release rendering must never erase the merged 1.1.9 changelog."""
from __future__ import annotations

import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLIENT_FEATURES = (
    "Refresh Guest chat Online status on reconnect",
    "Preserve Guest nicknames in room leave messages",
    "Keep repeated Guest sessions in one Message Center row",
    "Prevent private chats opening for the wrong selected user",
)


class ReleaseNotes119RegressionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="carracho-119-release-test-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.files = [
            "README_1.1.9.md",
            "carrachoclient.html",
            "carrachoserver.html",
            "README.md",
            "docs/index.html",
            "docs/releases/1.1.9.html",
            "docs/releases/Carracho-Client-1.1.9.html",
            "docs/releases/Carracho-Server-1.1.6.html",
        ]
        for name in self.files:
            target = self.base / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((ROOT / name).read_bytes())

    def render(self) -> subprocess.CompletedProcess[str]:
        command = [
            sys.executable, "-B", str(ROOT / "scripts/release/render_release.py"),
            "--release-version", "1.1.9",
            "--client-version", "1.1.9", "--client-build", "20",
            "--server-version", "1.1.6", "--server-build", "17",
            "--notes", str(self.base / "README_1.1.9.md"),
            "--client-changelog", str(self.base / "carrachoclient.html"),
            "--server-changelog", str(self.base / "carrachoserver.html"),
            "--docs-index", str(self.base / "docs/index.html"),
            "--docs-releases", str(self.base / "docs/releases"),
            "--root-readme", str(self.base / "README.md"),
        ]
        return subprocess.run(command, capture_output=True, text=True, check=False)

    def test_publish_rerun_preserves_every_client_change(self) -> None:
        # The current homepage can describe a newer release. Rendering the historical
        # release once may change it; the *second* run must never change anything.
        result = self.render()
        self.assertEqual(result.returncode, 0, result.stderr)
        before = {name: (self.base / name).read_bytes() for name in self.files}
        result = self.render()
        self.assertEqual(result.returncode, 0, result.stderr)
        after = {name: (self.base / name).read_bytes() for name in self.files}
        self.assertEqual(before, after, "Regenerating the release should be idempotent")
        content = (self.base / "carrachoclient.html").read_text()
        current = content.split("New in 1.1.9", 1)[1].split("New in 1.1.8", 1)[0]
        self.assertEqual(len(re.findall(r"<li>", current)), 5)  # build + 4 changes
        for feature in CLIENT_FEATURES:
            self.assertIn(f"<strong>{feature}</strong>", current)
            self.assertIn(feature, (self.base / "docs/releases/Carracho-Client-1.1.9.html").read_text())
        self.assertIn("New in 1.1.8", content)
        previous = content.split("New in 1.1.8", 1)[1].split("New in 1.1.7", 1)[0]
        self.assertEqual(len(re.findall(r"<li>", previous)), 10)
        old = content.split("New in 1.1.7", 1)[1].split("New in 1.1.6", 1)[0]
        self.assertEqual(len(re.findall(r"<li>", old)), 16)

    def test_stray_second_level_heading_fails_before_rewriting_anything(self) -> None:
        notes = self.base / "README_1.1.9.md"
        content = notes.read_text()
        content = content.replace("### Refresh Guest chat Online status on reconnect", "## Refresh Guest chat Online status on reconnect", 1)
        notes.write_text(content)
        old_output = {name: (self.base / name).read_bytes() for name in self.files if name != "README_1.1.9.md"}
        result = self.render()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Use ###", result.stderr)
        self.assertEqual(old_output, {name: (self.base / name).read_bytes() for name in old_output})

    def test_missing_feature_sections_cannot_truncate_existing_changelog(self) -> None:
        notes = self.base / "README_1.1.9.md"
        content = notes.read_text()
        client_start = content.index("## Carracho Client 1.1.9")
        server_start = content.index("## Carracho Server 1.1.6")
        client = content[client_start:server_start].replace("### ", "#### ")
        notes.write_text(content[:client_start] + client + content[server_start:])
        old_output = {name: (self.base / name).read_bytes() for name in self.files if name != "README_1.1.9.md"}
        result = self.render()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to replace", result.stderr)
        self.assertEqual(old_output, {name: (self.base / name).read_bytes() for name in old_output})


if __name__ == "__main__":
    unittest.main()
