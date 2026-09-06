#!/usr/bin/env python3
"""Build, sign, notarize, staple, and prepare local Dayreed ZIP + signed appcast."""
import sys
sys.dont_write_bytecode = True
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from prepare_appcast import generate
from release_support import ROOT, TOOLS, ACCOUNT, release_config, validate_bundle


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT / 'script/release.env')
    parser.add_argument('--output', type=Path, required=True, help='New local asset directory; must not exist')
    args = parser.parse_args()
    if args.output.exists() or args.output.is_symlink():
        raise ValueError('Output already exists; refusing to replace release assets.')
    config = release_config(args.config, os.environ)
    subprocess.run(['swift', 'package', 'resolve'], cwd=ROOT, check=True)
    # Resolve the explicit account only. Never use Sparkle's global default account.
    public_key = subprocess.run([str(TOOLS / 'generate_keys'), '--account', ACCOUNT, '-p'],
                                capture_output=True, text=True, check=True).stdout.strip()
    subprocess.run([str(ROOT / 'script/build_app.sh'), 'release'], check=True)
    source = ROOT / 'build/release/Dayreed.app'
    info = validate_bundle(source)
    if public_key != info['SUPublicEDKey']:
        raise ValueError('The dedicated Sparkle account does not match the App public key.')
    records = ROOT / 'docs/local/releases'
    records.mkdir(parents=True, exist_ok=True)
    # Preserve the successful development build. Sign and notarize a private copy.
    run = Path(tempfile.mkdtemp(prefix='notary-', dir=records))
    run.chmod(0o700)
    app = run / 'Dayreed.app'
    subprocess.run(['ditto', str(source), str(app)], check=True)
    subprocess.run([str(ROOT / 'script/sign_app.sh'), str(app), config['SIGN_ID']], check=True)
    expected_team = re.search(r'\(([A-Z0-9]{10})\)$', config['SIGN_ID']).group(1)
    for code in [app, app / 'Contents/Helpers/dayreed', app / 'Contents/Frameworks/Sparkle.framework',
                 *list((app / 'Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices').glob('*.xpc')),
                 app / 'Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate',
                 app / 'Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app']:
        details = subprocess.run(['codesign', '-dvv', str(code)], capture_output=True, text=True, check=True).stderr
        if 'TeamIdentifier=' + expected_team not in details or 'Authority=' + config['SIGN_ID'] not in details or 'runtime' not in details:
            raise ValueError('Nested code identity or hardened runtime does not match the release identity.')
    submission = run / 'submission.zip'
    subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(submission)], check=True)
    with (run / 'notary-result.json').open('w') as result:
        subprocess.run(['xcrun', 'notarytool', 'submit', str(submission), '--keychain-profile', config['NOTARY_PROFILE'],
                        '--wait', '--output-format', 'json'], stdout=result, check=True)
    result = json.loads((run / 'notary-result.json').read_text())
    if result.get('status') != 'Accepted':
        raise ValueError('Notarization was not Accepted. See the local notary result.')
    for command in [['xcrun', 'stapler', 'staple'], ['xcrun', 'stapler', 'validate'],
                    ['codesign', '--verify', '--deep', '--strict'], ['spctl', '--assess', '--type', 'execute']]:
        subprocess.run([*command, str(app)], check=True)
    validate_bundle(app)
    print('Prepared local assets:', generate(app, args.output))
    print('Notarization record:', run / 'notary-result.json')
    print('No tag or GitHub Release was created.')


if __name__ == '__main__':
    try:
        main()
    except ValueError as error:
        raise SystemExit(str(error))
    except (OSError, subprocess.SubprocessError):
        raise SystemExit('Release preparation failed; inspect the local operation result. No release was published.')
