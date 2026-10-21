#!/usr/bin/env python3
"""Build the hotel files pack (hotel-files.tar.gz + SHA256SUMS) from the plusemu-assets bucket.

The pack holds every file the installed client can load from /hotel-files/: furniture, clothing,
effects and pets (.hab), catalogue and badge images, gamedata texts, sounds and icons. It leaves out
the client build itself (shipped by the Volt release), the CMS screenshots, the .nitro copies of the
libraries (the client loads .hab) and stray editor files.

    python3 tools/hotel-files.py build --out dist      # list, download and pack
    python3 tools/hotel-files.py list objects.json      # only the bucket listing
    python3 tools/hotel-files.py check                  # compare the bucket with the published pack

Listing the bucket needs a Cloudflare API token with R2 read access in CLOUDFLARE_API_TOKEN (or
in the file named by CLOUDFLARE_API_TOKEN_FILE). Downloads use the public CDN and need no token.
"""
import argparse
import concurrent.futures
import gzip
import hashlib
import io
import json
import os
import pathlib
import posixpath
import sys
import tarfile
import time
import urllib.error
import urllib.parse
import urllib.request

ACCOUNT = '3fdff0e3dfbd383625477d7bfd7e5b7d'
BUCKET = 'plusemu-assets'
CDN = 'https://assets.plusemu.dev/'
PUBLISHED = 'https://github.com/plus-emulator/plusemu-installer/releases/download/hotel-files/'
PACK = 'hotel-files.tar.gz'

# What the pack keeps, as path rules. Every key must match an include and no exclude.
INCLUDE_PREFIXES = ('assets/', 'c_images/', 'gamedata/', 'images/', 'sounds/', 'habbicons/')
EXCLUDE_SUFFIXES = ('.nitro', '.pdn', '.rar', '.zip', '.sql')
EXCLUDE_NAMES = ('Thumbs.db', 'desktop.ini')


def wanted(key):
    if not key.startswith(INCLUDE_PREFIXES):
        return False
    # Files directly under assets/ are the client's own hashed bundles, not hotel files.
    if key.startswith('assets/') and key.count('/') == 1:
        return False
    name = posixpath.basename(key)
    return not key.endswith(EXCLUDE_SUFFIXES) and name not in EXCLUDE_NAMES


def api_token():
    token = os.environ.get('CLOUDFLARE_API_TOKEN')
    if not token and os.environ.get('CLOUDFLARE_API_TOKEN_FILE'):
        token = pathlib.Path(os.environ['CLOUDFLARE_API_TOKEN_FILE']).read_text().strip()
    if not token:
        sys.exit('Set CLOUDFLARE_API_TOKEN (or CLOUDFLARE_API_TOKEN_FILE) to list the bucket.')
    return token


def list_bucket():
    """Every object in the bucket: key, size, etag, last_modified."""
    token = api_token()
    base = f'https://api.cloudflare.com/client/v4/accounts/{ACCOUNT}/r2/buckets/{BUCKET}/objects'
    objects, cursor = [], None
    while True:
        query = {'per_page': 1000}
        if cursor:
            query['cursor'] = cursor
        request = urllib.request.Request(base + '?' + urllib.parse.urlencode(query),
                                         headers={'Authorization': 'Bearer ' + token})
        with urllib.request.urlopen(request, timeout=60) as response:
            data = json.load(response)
        if not data.get('success'):
            sys.exit(f'Listing the bucket failed: {data.get("errors")}')
        objects.extend(data['result'])
        cursor = (data.get('result_info') or {}).get('cursor')
        if not cursor or not data['result']:
            break
    return objects


def fetch(url, attempts=5):
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'plusemu-hotel-files'}), timeout=120) as r:
                return r.read()
        except (urllib.error.URLError, TimeoutError, ConnectionError) as error:
            if attempt == attempts - 1:
                raise
            time.sleep(2 ** attempt)
            last = error
    raise last


def download(obj, root):
    """Download one object to root/<key>, unless the local copy already matches."""
    key, size, etag = obj['key'], obj['size'], obj['etag'].strip('"')
    target = root / key
    if target.exists() and target.stat().st_size == size and ('-' in etag or hashlib.md5(target.read_bytes()).hexdigest() == etag):
        return False
    data = fetch(CDN + urllib.parse.quote(key))
    if len(data) != size:
        raise RuntimeError(f'{key}: got {len(data)} bytes, the bucket says {size}')
    # Single-part uploads carry their md5 as the etag; multipart etags end in "-<parts>" and are not checked.
    if '-' not in etag and hashlib.md5(data).hexdigest() != etag:
        raise RuntimeError(f'{key}: content does not match the bucket etag')
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    return True


def download_all(objects, root, threads):
    done = fresh = 0
    with concurrent.futures.ThreadPoolExecutor(threads) as pool:
        for was_new in pool.map(lambda o: download(o, root), objects):
            done += 1
            fresh += was_new
            if done % 2000 == 0:
                print(f'  {done}/{len(objects)} files ({fresh} downloaded)', file=sys.stderr)
    return fresh


def pack(objects, root, out_dir):
    """A reproducible tar.gz: sorted entries, owner root, times from the bucket, gzip without a timestamp."""
    out_dir.mkdir(parents=True, exist_ok=True)
    pack_path = out_dir / PACK
    with open(pack_path, 'wb') as raw, gzip.GzipFile(filename='', mode='wb', fileobj=raw, compresslevel=6, mtime=0) as gz, \
            tarfile.open(fileobj=gz, mode='w', format=tarfile.PAX_FORMAT) as tar:
        for obj in sorted(objects, key=lambda o: o['key']):
            key = obj['key']
            info = tarfile.TarInfo(key)
            info.size = obj['size']
            info.mtime = 0  # a fixed time, so the pack's checksum changes only when the content changes
            info.mode = 0o644
            info.uid = info.gid = 0
            info.uname = info.gname = 'root'
            with open(root / key, 'rb') as f:
                tar.addfile(info, f)
    digest = hashlib.sha256(pack_path.read_bytes()).hexdigest()
    (out_dir / 'SHA256SUMS').write_text(f'{digest}  {PACK}\n')
    return digest


def published_digest():
    try:
        sums = fetch(PUBLISHED + 'SHA256SUMS').decode()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise
    for line in sums.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].lstrip('*') == PACK:
            return parts[0]
    return None


def published_keys():
    """The paths inside the published pack, read from its tar index (the whole archive is downloaded)."""
    data = fetch(PUBLISHED + PACK)
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as tar:
        return {m.name for m in tar.getmembers() if m.isfile()}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    listing = commands.add_parser('list', help='write the bucket listing as JSON')
    listing.add_argument('output')
    build = commands.add_parser('build', help='list, download and pack')
    build.add_argument('--out', default='dist', help='where hotel-files.tar.gz and SHA256SUMS are written')
    build.add_argument('--cache', default='hotel-files-cache', help='download folder, reused between builds')
    build.add_argument('--objects', help='reuse a listing written by "list" instead of listing again')
    build.add_argument('--threads', type=int, default=32)
    commands.add_parser('check', help='compare the bucket with the published pack')
    args = parser.parse_args()

    if args.command == 'list':
        objects = list_bucket()
        pathlib.Path(args.output).write_text(json.dumps(objects))
        print(f'{len(objects)} objects')
        return

    if args.command == 'check':
        objects = [o for o in list_bucket() if wanted(o['key'])]
        keys = {o['key'] for o in objects}
        published = published_keys()
        missing = sorted(keys - published)
        gone = sorted(published - keys)
        print(f'bucket: {len(keys)} hotel files, published pack: {len(published)} files')
        print(f'missing from the pack: {len(missing)}')
        for key in missing[:50]:
            print('  ' + key)
        if len(missing) > 50:
            print(f'  ... and {len(missing) - 50} more')
        print(f'in the pack but no longer in the bucket: {len(gone)}')
        for key in gone[:20]:
            print('  ' + key)
        sys.exit(1 if missing else 0)

    if args.objects:
        objects = json.loads(pathlib.Path(args.objects).read_text())
    else:
        objects = list_bucket()
    objects = [o for o in objects if wanted(o['key'])]
    total = sum(o['size'] for o in objects)
    print(f'{len(objects)} hotel files, {total / 1e6:.0f} MB', file=sys.stderr)
    cache = pathlib.Path(args.cache)
    fresh = download_all(objects, cache, args.threads)
    print(f'downloaded {fresh} new or changed files', file=sys.stderr)
    digest = pack(objects, cache, pathlib.Path(args.out))
    published = published_digest()
    print(f'{PACK} sha256 {digest} ({"same as published" if digest == published else "new content"})')
    pathlib.Path(args.out, 'changed').write_text('false\n' if digest == published else 'true\n')


if __name__ == '__main__':
    main()
