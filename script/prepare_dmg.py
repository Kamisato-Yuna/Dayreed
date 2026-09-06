#!/usr/bin/env python3
"""Create a signed, notarized drag-to-Applications DMG from an existing stapled App."""
import sys
sys.dont_write_bytecode = True
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from release_support import ROOT, release_config, validate_bundle


def build_image(app, destination):
    """Package only; the public entry point below supplies distribution trust checks."""
    app, destination = Path(app).resolve(), Path(destination).absolute()
    if destination.exists() or destination.is_symlink():
        raise ValueError('DMG already exists; existing artifacts will not be replaced.')
    if destination.resolve().is_relative_to(app):
        raise ValueError('DMG output must be outside its App.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.dmg-', dir=destination.parent) as temporary:
        stage = Path(temporary)
        contents = stage / 'contents'
        contents.mkdir()
        subprocess.run(['ditto', str(app), str(contents / 'Dayreed.app')], check=True)
        (contents / 'Applications').symlink_to('/Applications', target_is_directory=True)
        (contents / '安装说明.txt').write_text(
            '安装 Dayreed\n\n'
            '需要 macOS 26 或更高版本。\n'
            '1. 如有旧版 Dayreed 正在运行，请先退出。\n'
            '2. 将 Dayreed.app 拖入旁边的 Applications（应用程序）文件夹。\n'
            '3. 从“应用程序”打开 Dayreed，然后推出此磁盘映像。\n', encoding='utf-8')
        image = stage / 'Dayreed.dmg'
        subprocess.run(['hdiutil', 'create', '-quiet', '-volname', 'Dayreed', '-fs', 'HFS+',
                        '-srcfolder', str(contents), '-format', 'UDZO', str(image)], check=True)
        subprocess.run(['hdiutil', 'verify', '-quiet', str(image)], check=True)
        # Same-filesystem exclusive publication; a concurrent artifact is never overwritten.
        os.link(image, destination)
    return destination


def prepare(app, destination, config, record_directory):
    app, destination = Path(app).resolve(), Path(destination).absolute()
    if destination.exists() or destination.is_symlink():
        raise ValueError('DMG already exists; existing artifacts will not be replaced.')
    if destination.resolve().is_relative_to(app):
        raise ValueError('DMG output must be outside its App.')
    validate_bundle(app)
    for command in [['codesign', '--verify', '--deep', '--strict'], ['xcrun', 'stapler', 'validate'],
                    ['spctl', '--assess', '--type', 'execute']]:
        subprocess.run([*command, str(app)], check=True)
    record_directory = Path(record_directory)
    record_directory.mkdir(parents=True, exist_ok=True)
    record_directory.chmod(0o700)
    image = build_image(app, record_directory / destination.name)
    # Disk images use Developer ID Application, but do not have executable runtime options.
    subprocess.run(['codesign', '--sign', config['SIGN_ID'], '--timestamp',
                    '--identifier', 'YunaBuild.Dayreed.DiskImage', str(image)], check=True)
    with (record_directory / 'notary-result.json').open('w') as result:
        subprocess.run(['xcrun', 'notarytool', 'submit', str(image), '--keychain-profile',
                        config['NOTARY_PROFILE'], '--wait', '--output-format', 'json'], stdout=result, check=True)
    if json.loads((record_directory / 'notary-result.json').read_text()).get('status') != 'Accepted':
        raise ValueError('DMG notarization was not Accepted. Inspect the local record.')
    for command in [['xcrun', 'stapler', 'staple'], ['xcrun', 'stapler', 'validate'],
                    ['codesign', '--verify', '--strict'],
                    ['spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature']]:
        subprocess.run([*command, str(image)], check=True)
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Publish a complete copy exclusively, including when output is on another filesystem.
    with tempfile.TemporaryDirectory(prefix='.dmg-final-', dir=destination.parent) as temporary:
        staged = Path(temporary) / destination.name
        shutil.copy2(image, staged)
        os.link(staged, destination)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('output', type=Path, help='New .dmg file; must not exist')
    parser.add_argument('--config', type=Path, default=ROOT / 'script/release.env')
    args = parser.parse_args()
    if args.output.suffix.lower() != '.dmg':
        raise ValueError('Output must be a .dmg file.')
    config = release_config(args.config, os.environ)
    records = ROOT / 'docs/local/releases'
    records.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix='dmg-', dir=records))
    print('Prepared local DMG:', prepare(args.app, args.output, config, run))
    print('Notarization record:', run / 'notary-result.json')
    print('No tag or GitHub Release was created.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
