#!/usr/bin/env python3
"""Real DMG packaging/mount checks; no credentials, notarization or user installation."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'script'))
from prepare_dmg import build_image
from release_support import validate_bundle


class DiskImageTests(unittest.TestCase):
    def test_mount_and_copy_preserve_app_and_install_shortcut(self):
        app = ROOT / 'build/debug/Dayreed.app'
        expected = validate_bundle(app)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            image = build_image(app, root / 'Dayreed.dmg')
            mount = root / 'Mounted Dayreed'
            mount.mkdir()
            subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-quiet',
                            '-mountpoint', str(mount), str(image)], check=True)
            try:
                self.assertTrue((mount / 'Dayreed.app').is_dir())
                self.assertTrue((mount / 'Applications').is_symlink())
                self.assertEqual(os.readlink(mount / 'Applications'), '/Applications')
                self.assertIn('拖入', (mount / '安装说明.txt').read_text())
                installed = root / 'Copied Dayreed.app'
                subprocess.run(['ditto', str(mount / 'Dayreed.app'), str(installed)], check=True)
                actual = validate_bundle(installed)
                self.assertEqual(actual['CFBundleShortVersionString'], expected['CFBundleShortVersionString'])
                self.assertEqual(actual['CFBundleVersion'], expected['CFBundleVersion'])
                subprocess.run(['codesign', '--verify', '--deep', '--strict', str(installed)], check=True)
            finally:
                subprocess.run(['hdiutil', 'detach', '-quiet', str(mount)], check=True)

    def test_existing_image_and_app_contents_are_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            image = root / 'previous.dmg'
            image.write_bytes(b'previous successful artifact')
            with self.assertRaises(ValueError): build_image(root / 'missing.app', image)
            self.assertEqual(image.read_bytes(), b'previous successful artifact')
            app = root / 'Dayreed.app'
            app.mkdir()
            with self.assertRaises(ValueError): build_image(app, app / 'new.dmg')
            self.assertEqual(list(app.iterdir()), [])


if __name__ == '__main__': unittest.main()
