#!/usr/bin/env python3
"""Build the public Pages directory and read the latest non-prerelease from GitHub."""
import json
import os
from pathlib import Path
import shutil
import urllib.error
import urllib.request
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / 'build' / 'site'
REPO = 'Kamisato-Yuna/Dayreed'


def latest_release():
    headers = {'Accept': 'application/vnd.github+json', 'User-Agent': 'Dayreed-Pages'}
    if os.environ.get('GH_TOKEN'):
        headers['Authorization'] = 'Bearer ' + os.environ['GH_TOKEN']
    request = urllib.request.Request(f'https://api.github.com/repos/{REPO}/releases/latest', headers=headers)
    snapshot = {'checked': datetime.now(timezone.utc).isoformat()}
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            release = json.load(response)
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        return {**snapshot, 'state': 'unreleased'}
    return {**snapshot, 'state': 'published', 'tag': release['tag_name'],
            'name': release['name'], 'url': release['html_url'], 'published': release['published_at']}


if __name__ == '__main__':
    snapshot = latest_release()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    shutil.copytree(ROOT / 'site', OUTPUT, dirs_exist_ok=True)
    (OUTPUT / 'release.json').write_text(json.dumps(snapshot, ensure_ascii=False) + '\n')
    print(f'Pages ready: {OUTPUT}; release state: {snapshot["state"]}')
