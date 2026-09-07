#!/usr/bin/env python3
"""Prepare a new local release directory from a signed, stapled App. Never upload."""
import sys
sys.dont_write_bytecode = True
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from release_support import ACCOUNT, REPOSITORY, TOOLS, app_metadata, validate_appcast


def generate(app, destination, *, key_input=None, tools=TOOLS):
    """key_input is only for synthetic tests. Production uses the dedicated Keychain account."""
    app, destination = Path(app).resolve(), Path(destination).absolute()
    if destination.exists() or destination.is_symlink():
        raise ValueError('Release destination already exists; existing assets will not be replaced.')
    if destination.resolve().is_relative_to(app):
        raise ValueError('Release output must be outside the App being archived.')
    info = app_metadata(app)
    if key_input is None:
        public_key = subprocess.run([str(tools / 'generate_keys'), '--account', ACCOUNT, '-p'],
                                    capture_output=True, text=True, check=True).stdout.strip()
        if public_key != info['SUPublicEDKey']:
            raise ValueError('Dedicated Sparkle account does not match App public key.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.prepare-', dir=destination.parent) as staging:
        stage = Path(staging)
        output = stage / 'assets'
        output.mkdir()
        tool_environment = dict(os.environ)
        # Foundation cache isolation, without changing HOME or Keychain search lists.
        cache_home = stage / 'tool-cache'
        (cache_home / 'Library/Caches').mkdir(parents=True)
        tool_environment['CFFIXED_USER_HOME'] = str(cache_home)
        archive = output / ('Dayreed-' + info['CFBundleShortVersionString'] + '.zip')
        subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive)], check=True)
        key_args = ['--ed-key-file', '-'] if key_input is not None else ['--account', ACCOUNT]
        # Always start in a new directory: generate_appcast cannot mutate old releases or cached feeds.
        subprocess.run([str(tools / 'generate_appcast'), *key_args, '--maximum-deltas', '0',
                        '--download-url-prefix', REPOSITORY + '/releases/download/v' + info['CFBundleShortVersionString'] + '/',
                        '--link', REPOSITORY, str(output)], input=key_input, check=True, env=tool_environment,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        feed = output / 'appcast.xml'
        signature = validate_appcast(feed, app, archive)
        for filename, sig in [(archive, [signature]), (feed, [])]:
            subprocess.run([str(tools / 'sign_update'), *key_args, '--verify', str(filename), *sig],
                           input=key_input, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # mkdir is exclusive, even if another release preparation completed while this one ran.
        destination.mkdir()
        try:
            for source in output.iterdir():
                shutil.move(str(source), destination / source.name)
        except BaseException:
            shutil.rmtree(destination)
            raise
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    # This public entry point only accepts notarized, stapled Apps.
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(args.app)], check=True)
    subprocess.run(['xcrun', 'stapler', 'validate', str(args.app)], check=True)
    subprocess.run(['spctl', '--assess', '--type', 'execute', str(args.app)], check=True)
    print(generate(args.app, args.output))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError):
        raise SystemExit('Release preparation failed; no existing release assets were modified.')
