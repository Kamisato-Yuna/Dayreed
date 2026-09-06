#!/usr/bin/env python3
"""Shared local packaging helpers. No shell evaluation or credential export."""
import base64
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = 'https://github.com/Kamisato-Yuna/Dayreed'
FEED = REPOSITORY + '/releases/latest/download/appcast.xml'
ACCOUNT = 'YunaBuild.Dayreed.Sparkle'
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
TOOLS = ROOT / '.build/artifacts/sparkle/Sparkle/bin'


def read_config(path):
    """Read only two named, non-secret fields; never execute release.env."""
    path = Path(path)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return {}
    with os.fdopen(fd) as stream:
        mode = os.fstat(stream.fileno())
        if not stat.S_ISREG(mode.st_mode) or mode.st_uid != os.getuid() or mode.st_mode & 0o077:
            raise ValueError('release.env must be an owner-only regular file (chmod 600).')
        text = stream.read(8193)
    if len(text) > 8192:
        raise ValueError('release.env is too large.')
    values = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        key, separator, value = line.partition('=')
        if not separator or key not in ('SIGN_ID', 'NOTARY_PROFILE') or key in values:
            raise ValueError('release.env accepts unique SIGN_ID and NOTARY_PROFILE fields only.')
        if len(value) >= 2 and value[0] == value[-1] and value[0] in '\"\'':
            value = value[1:-1]
        if not value or any(c in value for c in '\n\r`$\\'):
            raise ValueError('release.env contains unsupported value syntax.')
        values[key] = value
    return values


def release_config(path, environment):
    values = read_config(path)
    for key in ('SIGN_ID', 'NOTARY_PROFILE'):
        if key in environment:
            values[key] = environment[key]
    if not re.fullmatch(r'Developer ID Application: [^\r\n]+ \([A-Z0-9]{10}\)', values.get('SIGN_ID', '')):
        raise ValueError('Set SIGN_ID to the existing Developer ID Application identity.')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+', values.get('NOTARY_PROFILE', '')):
        raise ValueError('Set NOTARY_PROFILE to an explicit existing notarytool profile name.')
    return values


def app_metadata(app):
    with (Path(app) / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('CFBundleIdentifier') != 'YunaBuild.Dayreed':
        raise ValueError('Expected Dayreed bundle identifier.')
    for key in ('CFBundleShortVersionString', 'CFBundleVersion', 'LSMinimumSystemVersion'):
        if not isinstance(info.get(key), str) or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', info[key]):
            raise ValueError('Invalid app version metadata: ' + key)
    if int(info['LSMinimumSystemVersion'].split('.')[0]) < 26:
        raise ValueError('Dayreed requires macOS 26 or later.')
    with (ROOT / 'Resources/Updates/UpdateConfig.plist').open('rb') as stream:
        expected = plistlib.load(stream)
    if any(info.get(key) != value for key, value in expected.items()):
        raise ValueError('App must contain the repository\'s Dayreed update configuration.')
    if len(base64.b64decode(info['SUPublicEDKey'], validate=True)) != 32:
        raise ValueError('Missing EdDSA public key.')
    return info


def validate_bundle(app):
    app = Path(app)
    info = app_metadata(app)
    required = ['Contents/MacOS/Dayreed', 'Contents/Helpers/dayreed',
                'Contents/Resources/LICENSE', 'Contents/Resources/Sparkle-LICENSE',
                'Contents/Resources/Assets.car', 'Contents/Resources/install_cli.sh']
    framework = 'Contents/Frameworks/Sparkle.framework'
    required += [framework + '/Versions/B/' + name for name in [
        'Sparkle', 'Autoupdate', 'Updater.app/Contents/MacOS/Updater',
        'XPCServices/Installer.xpc/Contents/MacOS/Installer',
        'XPCServices/Downloader.xpc/Contents/MacOS/Downloader']]
    for relative in required:
        if not (app / relative).is_file():
            raise ValueError('Incomplete bundle: ' + relative)
    for path in app.rglob('*'):
        if path.is_symlink() and (not path.exists() or not path.resolve().is_relative_to(app.resolve())):
            raise ValueError('Broken or escaping bundle symlink.')
    for name in ('Sparkle', 'Versions/Current', 'Resources', 'Updater.app', 'Autoupdate', 'XPCServices'):
        if not (app / framework / name).is_symlink():
            raise ValueError('Framework symlink not preserved: ' + name)
    helper = subprocess.run([str(app / 'Contents/Helpers/dayreed'), 'version', '--json'],
                            check=True, capture_output=True, text=True)
    version = json.loads(helper.stdout)
    for app_key, cli_key in [('CFBundleIdentifier', 'bundleIdentifier'), ('CFBundleShortVersionString', 'version'),
                             ('CFBundleVersion', 'build'), ('LSMinimumSystemVersion', 'minimumSystemVersion')]:
        if str(info[app_key]) != str(version.get(cli_key)):
            raise ValueError('App and embedded CLI metadata differ: ' + cli_key)
    load = subprocess.run(['otool', '-l', str(app / 'Contents/MacOS/Dayreed')],
                          check=True, capture_output=True, text=True).stdout
    if '@executable_path/../Frameworks' not in load:
        raise ValueError('App is missing its embedded framework runpath.')
    return info


def replace_bundle(staged, destination):
    staged, destination = Path(staged), Path(destination)
    if destination.is_symlink():
        raise ValueError('Refusing a symlinked bundle destination.')
    backup = staged.parent / 'previous.app'
    if backup.exists():
        raise ValueError('Staging backup already exists.')
    if destination.exists():
        destination.rename(backup)
    try:
        staged.rename(destination)
    except BaseException:
        if backup.exists():
            backup.rename(destination)
        raise


def validate_appcast(path, app, archive):
    info = app_metadata(app)
    root = ET.parse(path).getroot()
    items = root.findall('./channel/item')
    if len(items) != 1:
        raise ValueError('Expected one release item in the new appcast.')
    item = items[0]
    enc = item.find('enclosure')
    if enc is None:
        raise ValueError('Missing update enclosure.')
    expected_url = REPOSITORY + '/releases/download/v' + info['CFBundleShortVersionString'] + '/' + Path(archive).name
    if enc.get('url') != expected_url or enc.get('length') != str(Path(archive).stat().st_size):
        raise ValueError('Appcast archive source or length differs from the final ZIP.')
    for xml_key, app_key in [('version', 'CFBundleVersion'), ('shortVersionString', 'CFBundleShortVersionString'),
                             ('minimumSystemVersion', 'LSMinimumSystemVersion')]:
        value = item.findtext('{' + SPARKLE + '}' + xml_key) or enc.get('{' + SPARKLE + '}' + xml_key)
        if value != info[app_key]:
            raise ValueError('Appcast metadata differs from its App: ' + xml_key)
    signature = enc.get('{' + SPARKLE + '}edSignature', '')
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError('Missing EdDSA archive signature.')
    return signature


if __name__ == '__main__':
    try:
        if sys.argv[1] == 'validate':
            validate_bundle(sys.argv[2])
        elif sys.argv[1] == 'replace':
            replace_bundle(sys.argv[2], sys.argv[3])
        else:
            raise ValueError('Unknown command.')
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
