#!/usr/bin/env python3
"""Synthetic release tests. Never access the user's records or real signing keys."""
import base64
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'script'))
import release_support as support
from prepare_appcast import generate

# Public RFC 8032 Ed25519 test vector, not a distribution credential.
SEED = base64.b64encode(bytes.fromhex('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'))
PUBLIC = base64.b64encode(bytes.fromhex('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a')).decode()


class ReleaseTests(unittest.TestCase):
    def test_config_never_executes_shell_and_preserves_mode(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'release.env'
            path.write_text('SIGN_ID="Developer ID Application: Synthetic Person (1234567890)"\nNOTARY_PROFILE=fixture\n')
            path.chmod(0o600)
            self.assertEqual(support.release_config(path, {})['NOTARY_PROFILE'], 'fixture')
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            path.chmod(0o644)
            with self.assertRaises(ValueError): support.read_config(path)
            path.chmod(0o600)
            marker = Path(temporary) / 'executed'
            path.write_text('SIGN_ID=$(touch ' + str(marker) + ')\n')
            with self.assertRaises(ValueError): support.read_config(path)
            self.assertFalse(marker.exists())
            link = Path(temporary) / 'link'
            link.symlink_to(path)
            with self.assertRaises(OSError): support.read_config(link)
            path.write_text('NOTARY_PROFILE=fixture\nNOTARY_PROFILE=duplicate\n')
            with self.assertRaises(ValueError): support.read_config(path)

    def test_build_failure_preserves_existing_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'script').mkdir()
            script = root / 'script/build_app.sh'
            script.write_bytes((ROOT / 'script/build_app.sh').read_bytes())
            script.chmod(0o755)
            tools = root / 'tools'
            tools.mkdir()
            for name, content in [('swift', '#!/bin/sh\nexit 0\n'), ('xcrun', '#!/bin/sh\nexit 17\n')]:
                tool = tools / name
                tool.write_text(content)
                tool.chmod(0o755)
            previous = root / 'build/debug/Dayreed.app'
            previous.mkdir(parents=True)
            (previous / 'existing').write_text('preserve successful bundle')
            environment = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'])
            result = subprocess.run([str(script), 'debug'], env=environment, capture_output=True)
            self.assertEqual(result.returncode, 17)
            self.assertEqual((previous / 'existing').read_text(), 'preserve successful bundle')
            self.assertEqual(list(previous.parent.glob('.bundle.*')), [])

    def test_failed_bundle_replace_restores_previous_app(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage = root / 'stage'
            stage.mkdir()
            destination = root / 'Dayreed.app'
            destination.mkdir()
            (destination / 'previous').write_text('preserve')
            with self.assertRaises(FileNotFoundError): support.replace_bundle(stage / 'missing.app', destination)
            self.assertEqual((destination / 'previous').read_text(), 'preserve')

    def test_packaged_framework_and_cli_are_complete(self):
        app = ROOT / 'build/debug/Dayreed.app'
        support.validate_bundle(app)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        self.assertEqual((app / 'Contents/Resources/install_cli.sh').read_bytes(), (ROOT / 'script/install_cli.sh').read_bytes())

    def test_appcast_signatures_versions_and_failure_preservation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / 'Dayreed.app'
            subprocess.run(['ditto', str(ROOT / 'build/debug/Dayreed.app'), str(app)], check=True)
            plist = app / 'Contents/Info.plist'
            info = plistlib.loads(plist.read_bytes())
            info['SUPublicEDKey'] = PUBLIC
            # Distinct synthetic versions prove feed values come from the given App.
            info['CFBundleShortVersionString'] = '0.0.7'
            info['CFBundleVersion'] = '73'
            info['LSMinimumSystemVersion'] = '26.1'
            plist.write_bytes(plistlib.dumps(info))
            subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, stderr=subprocess.DEVNULL)
            config_dir = root / 'Resources/Updates'
            config_dir.mkdir(parents=True)
            config = plistlib.loads((ROOT / 'Resources/Updates/UpdateConfig.plist').read_bytes())
            config['SUPublicEDKey'] = PUBLIC
            (config_dir / 'UpdateConfig.plist').write_bytes(plistlib.dumps(config))
            with patch.object(support, 'ROOT', root):
                with self.assertRaises(ValueError): generate(app, app / 'Contents/assets', key_input=SEED)
                output = root / 'assets'
                generate(app, output, key_input=SEED)
                archive, feed = output / 'Dayreed-0.0.7.zip', output / 'appcast.xml'
                signature = support.validate_appcast(feed, app, archive)
                saved = feed.read_bytes()
                with self.assertRaises(ValueError): generate(app, output, key_input=SEED)
                self.assertEqual(feed.read_bytes(), saved)
                with self.assertRaises(subprocess.CalledProcessError):
                    generate(app, root / 'failed', key_input=b'not a key')
                self.assertFalse((root / 'failed').exists())
                self.assertEqual(feed.read_bytes(), saved)
                # Actual Sparkle verifier rejects changed bytes and a different signing key.
                def verify(path, sig=(), key=SEED):
                    return subprocess.run([str(support.TOOLS / 'sign_update'), '--ed-key-file', '-', '--verify', str(path), *sig],
                                          input=key, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
                self.assertEqual(verify(feed), 0)
                self.assertEqual(verify(archive, [signature]), 0)
                self.assertNotEqual(verify(feed, key=base64.b64encode(bytes(range(32)))), 0)
                with archive.open('ab') as stream: stream.write(b'synthetic corruption')
                self.assertNotEqual(verify(archive, [signature]), 0)
                feed.write_bytes(saved.replace(b'Dayreed', b'Changed', 1))
                self.assertNotEqual(verify(feed), 0)
                feed.write_bytes(saved.replace(b'Kamisato-Yuna/Dayreed/releases/download', b'Kamisato-Yuna/Dayflow-Yuna/releases/download'))
                with self.assertRaises(ValueError): support.validate_appcast(feed, app, archive)

    def test_missing_profile_stops_before_build_or_asset_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root / 'release.env'
            config.write_text('SIGN_ID="Developer ID Application: Synthetic Person (1234567890)"\n')
            config.chmod(0o600)
            environment = {k: v for k, v in os.environ.items() if k not in ('SIGN_ID', 'NOTARY_PROFILE')}
            result = subprocess.run([str(ROOT / 'script/notarize.sh'), '--config', str(config), '--output', str(root / 'assets')],
                                    env=environment, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('NOTARY_PROFILE', result.stderr)
            self.assertFalse((root / 'assets').exists())


if __name__ == '__main__': unittest.main()
