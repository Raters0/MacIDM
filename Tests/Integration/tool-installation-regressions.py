#!/usr/bin/env python3
"""Offline fault injection for production downloader/installer scripts.
No user HOME override, network, installed app, or credentials are used.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def executable(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    path.chmod(0o755)


class ToolInstallationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="macidm-tool-tests-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.tools = self.directory / "tools"
        self.tools.mkdir()
        self.env = {**os.environ, "PATH": f"{self.tools}:{os.environ['PATH']}", "FIXTURE_DIR": str(self.directory)}
        self.env.pop("MACIDM_YTDLP_PATH", None)
        self.cache = self.directory / "cache"
        self.env["MACIDM_YTDLP_CACHE"] = str(self.cache)
        self.marker = self.directory / "executed"
        self.binary = b'#!/bin/bash\necho executed >> "$FIXTURE_DIR/executed"\necho 2026.09.01\n'
        (self.directory / "binary").write_bytes(self.binary)
        self.digest = hashlib.sha256(self.binary).hexdigest()
        self.release(digest="sha256:" + self.digest)
        executable(self.tools / "curl", '''#!/usr/bin/env python3
import os, pathlib, sys
p = pathlib.Path(os.environ['FIXTURE_DIR'])
a = sys.argv[1:]
url = a[-1]
if 'api.github.com/' in url:
    data = (p / 'release.json').read_bytes()
elif url.endswith('/SHA2-256SUMS'):
    data = (p / 'sums').read_bytes() if (p / 'sums').exists() else b''
else:
    data = (p / 'binary').read_bytes()
with (p / 'urls').open('a') as log: log.write(url + '\\n')
if '-o' in a: pathlib.Path(a[a.index('-o')+1]).write_bytes(data)
else: sys.stdout.buffer.write(data)
''')

    def release(self, digest=None, tag="2026.09.01"):
        (self.directory / "release.json").write_text(json.dumps({
            "tag_name": tag, "assets": [{"name": "yt-dlp_macos", "digest": digest}],
        }))

    def fetch(self, *args):
        return subprocess.run(["bash", str(ROOT / "scripts/fetch-ytdlp.sh"), *args], env=self.env, capture_output=True, text=True)

    def test_missing_metadata_never_executes_download_or_old_cache(self):
        self.cache.mkdir()
        old = self.cache / "yt-dlp"
        executable(old, self.binary.decode())
        (self.directory / "release.json").write_text("{}")
        result = self.fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists())
        self.assertEqual(old.read_bytes(), self.binary)

    def test_hash_mismatch_keeps_old_binary_without_execution(self):
        self.cache.mkdir()
        old = self.cache / "yt-dlp"
        old.write_bytes(b"original")
        self.release(digest="sha256:" + "0" * 64)
        self.assertNotEqual(self.fetch("--force").returncode, 0)
        self.assertFalse(self.marker.exists())
        self.assertEqual(old.read_bytes(), b"original")

    def test_pinned_checksum_fallback_and_cache_revalidation(self):
        self.release()
        (self.directory / "sums").write_text(self.digest + "  yt-dlp_macos\n")
        result = self.fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(self.cache / "yt-dlp"))
        urls = (self.directory / "urls").read_text()
        self.assertIn("/download/2026.09.01/SHA2-256SUMS", urls)
        self.assertIn("/download/2026.09.01/yt-dlp_macos", urls)
        (self.directory / "urls").unlink()
        self.assertEqual(self.fetch().returncode, 0)
        self.assertFalse((self.directory / "urls").exists())
        executable(self.cache / "yt-dlp", '#!/bin/bash\necho unsafe >> "$FIXTURE_DIR/unsafe"\n')
        (self.directory / "release.json").write_text("{}")
        self.assertNotEqual(self.fetch().returncode, 0)
        self.assertFalse((self.directory / "unsafe").exists())

    def test_version_mismatch_preserves_original(self):
        self.cache.mkdir()
        (self.cache / "yt-dlp").write_bytes(b"original")
        self.release(digest="sha256:" + self.digest, tag="2026.09.02")
        result = self.fetch("--force")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.cache / "yt-dlp").read_bytes(), b"original")

    def test_gate_locator_uses_cache_override_and_stable_bundle(self):
        source = (ROOT / "Tests/Integration/youtube-ytdlp-integration.sh").read_text()
        start = source.index("locate_ytdlp() {")
        end = source.index("\n}\n", start) + 3
        # Scope home paths to a fixture without overriding the process HOME.
        function = source[start:end].replace("$HOME", "$FIXTURE_DIR/user")
        executable(self.cache / "yt-dlp", "#!/bin/bash\nexit 0\n")
        result = subprocess.run(["bash", "-c", function + "\nlocate_ytdlp"], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.stdout.strip(), str(self.cache / "yt-dlp"))
        installed = self.directory / "user/Applications/MacIDM.app/Contents/Resources/yt-dlp"
        executable(installed, "#!/bin/bash\nexit 0\n")
        result = subprocess.run(["bash", "-c", function + "\nlocate_ytdlp"], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.stdout.strip(), str(installed))
        self.assertNotIn(".build/vendor", function)
        self.assertNotIn(".build/debug/MacIDM.app", function)

    def install_fixture(self, failure):
        repo = self.directory / "repo"
        script = repo / "scripts/install-debug-app.sh"
        script.parent.mkdir(parents=True)
        text = (ROOT / "scripts/install-debug-app.sh").read_text()
        # Redirect only OS integration endpoints in the fixture copy. All
        # build, copy, validation, replacement, and rollback logic is original.
        text = text.replace('lock_parent="$HOME/Library/Caches/MacidM"', 'lock_parent="$FIXTURE_DIR/lock"')
        text = text.replace('legacy_default_destination="$HOME/Applications/MacIDM Debug.app"', 'legacy_default_destination="$FIXTURE_DIR/legacy/MacIDM Debug.app"')
        text = text.replace('launch_services_register="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"', 'launch_services_register="/usr/bin/true"')
        script.write_text(text)
        bundle = repo / ".build/debug/MacIDM.app"
        executable(bundle / "Contents/MacOS/MacIDM", "#!/bin/bash\nexit 0\n")
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.macidm.app", "CFBundleExecutable": "MacIDM",
            "CFBundleDisplayName": "MacIDM", "MacIDMBuildDate": "fixture-build",
        }))
        executable(repo / "scripts/build-debug-app.sh", '#!/bin/bash\necho "$(cd "$(dirname "$0")/.." && pwd)/.build/debug/MacIDM.app"\n')
        executable(self.tools / "pgrep", "#!/bin/bash\nexit 1\n")
        executable(self.tools / "ditto", "#!/bin/bash\n" + ("exit 73\n" if failure == "copy" else 'exec /usr/bin/ditto "$@"\n'))
        if failure == "swap":
            executable(self.tools / "mv", '#!/bin/bash\nif [[ "$1" == */bundle ]]; then exit 73; fi\nexec /bin/mv "$@"\n')
        if failure == "metadata":
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "wrong"}))
        installed = self.directory / "installed/MacIDM.app"
        installed.mkdir(parents=True)
        (installed / "old-marker").write_text("old app remains usable")
        self.env["MACIDM_DEBUG_INSTALL_DIRECTORY"] = str(installed.parent)
        result = subprocess.run(["bash", str(script)], env=self.env, capture_output=True, text=True)
        return result, installed, bundle

    def test_copy_failure_preserves_old_install(self):
        result, installed, _ = self.install_fixture("copy")
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertTrue((installed / "old-marker").exists())

    def test_swap_failure_rolls_back_old_install(self):
        result, installed, _ = self.install_fixture("swap")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((installed / "old-marker").exists())

    def test_bad_metadata_preserves_old_install(self):
        result, installed, _ = self.install_fixture("metadata")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((installed / "old-marker").exists())

    def test_success_replaces_without_obsolete_files(self):
        result, installed, source = self.install_fixture(None)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((installed / "old-marker").exists())
        self.assertTrue((installed / "Contents/MacOS/MacIDM").exists())
        self.assertFalse(source.exists())
        self.assertFalse(list(installed.parent.glob(".macidm-install.*")))


if __name__ == "__main__":
    unittest.main()
