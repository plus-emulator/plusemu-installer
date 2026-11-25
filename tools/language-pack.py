#!/usr/bin/env python3
"""Build the language packs that hotels installed with --language <code> use instead of English.

A pack holds the texts one Habbo hotel shows in its own language:
    ExternalTexts.json    Habbo's external_flash_texts as JSON, loaded after the stock texts (Volt and AIR)
    UITexts.jsonc         Volt's own interface texts in that language, when Volt has them
    furni-names.json      furniture name and description per classname, from Habbo's furnidata
    product-names.json    product name and description per product code, from Habbo's productdata

    python3 tools/language-pack.py build --language de --out dist          # download from habbo.de
    python3 tools/language-pack.py build --language de --source <folder> --out dist
    python3 tools/language-pack.py build --all --out dist
    python3 tools/language-pack.py publish dist                             # upload dist to the asset bucket

--source is a folder with Habbo's files saved by hand from a browser:
    external_flash_texts.txt   https://www.habbo.de/gamedata/external_flash_texts/1
    furnidata.json             https://www.habbo.de/gamedata/furnidata_json/1
    productdata.json           https://www.habbo.de/gamedata/productdata_json/1

The published files live under https://assets.plusemu.dev/language/:
    language/<code>.json                              the manifest the installers read
    language/<code>/<version>/language-<code>.tar.gz  the pack

<version> is the start of the pack's SHA-256, so a changed pack gets a new address.

Habbo blocks many data center addresses, so run "build" from a home connection when it fails with
HTTP 403 or 463. "publish" needs a Cloudflare API token with R2 write access in CLOUDFLARE_API_TOKEN,
or in the file named by CLOUDFLARE_API_TOKEN_FILE.
"""
import argparse
import gzip
import hashlib
import io
import json
import os
import pathlib
import sys
import tarfile
import urllib.error
import urllib.request

ACCOUNT = '3fdff0e3dfbd383625477d7bfd7e5b7d'
BUCKET = 'plusemu-assets'
CDN = 'https://assets.plusemu.dev/'
PREFIX = 'language/'
# English is the stock hotel files, so it has no pack. The codes match the website's lang/ folders.
LANGUAGES = {
    'de': 'https://www.habbo.de',
    'nl': 'https://www.habbo.nl',
    'fr': 'https://www.habbo.fr',
    'es': 'https://www.habbo.es',
    'it': 'https://www.habbo.it',
    'fi': 'https://www.habbo.fi',
    'tr': 'https://www.habbo.com.tr',
    'br': 'https://www.habbo.com.br',
}
SOURCES = {
    'external_flash_texts.txt': '/gamedata/external_flash_texts/1',
    'furnidata.json': '/gamedata/furnidata_json/1',
    'productdata.json': '/gamedata/productdata_json/1',
}
UI_TEXTS = 'https://raw.githubusercontent.com/plus-emulator/Volt/main/public/configuration/UITexts_{}.jsonc.example'
# Habbo's edge rejects requests that do not look like a browser.
BROWSER = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'


class PackError(Exception):
    pass


def fetch(url, user_agent='plusemu-language-pack'):
    request = urllib.request.Request(url, headers={'User-Agent': user_agent, 'Accept': '*/*'})
    try:
        with urllib.request.urlopen(request, timeout=300) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        hint = ' Habbo blocks this address; run the build from a home connection.' if error.code in (403, 463) else ''
        raise PackError(f'Downloading {url} failed with HTTP {error.code}.{hint}') from error


def text(data, name):
    content = data.decode('utf-8-sig')
    if not content.strip() or content.lstrip().startswith('<'):
        raise PackError(f'{name} is empty or an HTML page, not the file Habbo serves.')
    return content


def flash_texts(content):
    """external_flash_texts lines are key=value; the value may contain "=" too."""
    texts = {}
    for line in content.splitlines():
        key, separator, value = line.partition('=')
        if separator and key.strip() and not key.startswith('#'):
            texts[key.strip()] = value
    if not texts:
        raise PackError('external_flash_texts.txt has no key=value lines.')
    return texts


def names(entries, key, name):
    found = {}
    for entry in entries:
        # A few of Habbo's product codes are numbers; the installers look them up as text.
        value = entry.get(key) if isinstance(entry, dict) else None
        if isinstance(value, (str, int)) and not isinstance(value, bool) and str(value):
            found[str(value)] = {'name': str(entry.get('name') or ''), 'description': str(entry.get('description') or '')}
    if not found:
        raise PackError(f'{name} has no entries with a {key}.')
    return found


def furni_names(content):
    data = json.loads(content)
    entries = []
    for section in ('roomitemtypes', 'wallitemtypes'):
        entries += ((data.get(section) or {}).get('furnitype') or [])
    return names(entries, 'classname', 'furnidata.json')


def product_names(content):
    data = json.loads(content)
    return names((data.get('productdata') or {}).get('product') or [], 'code', 'productdata.json')


def tar_bytes(files):
    """The same files always give the same bytes, so an unchanged pack keeps its version."""
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w', format=tarfile.PAX_FORMAT) as tar:
        for name in sorted(files):
            info = tarfile.TarInfo(name)
            info.size, info.mode, info.mtime = len(files[name]), 0o644, 0
            tar.addfile(info, io.BytesIO(files[name]))
    raw = buffer.getvalue()
    out = io.BytesIO()
    with gzip.GzipFile(fileobj=out, mode='wb', mtime=0, filename='') as packed:
        packed.write(raw)
    return out.getvalue()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def as_json(value):
    return (json.dumps(value, ensure_ascii=False, indent=1, sort_keys=True) + '\n').encode()


def pack_files(sources, ui_texts):
    """sources maps each SOURCES name to Habbo's file; ui_texts is Volt's UITexts for the language, or None."""
    files = {
        'ExternalTexts.json': as_json(flash_texts(text(sources['external_flash_texts.txt'], 'external_flash_texts.txt'))),
        'furni-names.json': as_json(furni_names(text(sources['furnidata.json'], 'furnidata.json'))),
        'product-names.json': as_json(product_names(text(sources['productdata.json'], 'productdata.json'))),
    }
    if ui_texts is not None:
        files['UITexts.jsonc'] = text(ui_texts, 'UITexts.jsonc').encode()
    return files


def manifest(code, pack):
    version = sha256(pack)[:12]
    return {
        'language': code,
        'hotel': LANGUAGES[code],
        'version': version,
        'url': f'{CDN}{PREFIX}{code}/{version}/language-{code}.tar.gz',
        'sha256': sha256(pack),
    }


def download_sources(code, source_dir):
    if source_dir:
        folder = pathlib.Path(source_dir)
        missing = [name for name in SOURCES if not (folder / name).is_file()]
        if missing:
            raise PackError(f'{folder} lacks {", ".join(missing)}.')
        return {name: (folder / name).read_bytes() for name in SOURCES}
    print(f'Downloading the {code} texts from {LANGUAGES[code]}')
    return {name: fetch(LANGUAGES[code] + path, BROWSER) for name, path in SOURCES.items()}


def download_ui_texts(code, path):
    if path:
        return pathlib.Path(path).read_bytes()
    try:
        return fetch(UI_TEXTS.format(code))
    except PackError:
        print(f'Volt has no {code} interface texts; the pack leaves them English.')
        return None


# ---------------------------------------------------------------------------------------------
# Commands


def build(args):
    codes = sorted(LANGUAGES) if args.all else args.language
    if not codes:
        raise PackError('Name the languages with --language, or use --all.')
    unknown = [code for code in codes if code not in LANGUAGES]
    if unknown:
        raise PackError(f'Unknown language {", ".join(unknown)}. Known: {", ".join(sorted(LANGUAGES))}.')
    if (args.source or args.ui_texts) and len(codes) != 1:
        raise PackError('--source and --ui-texts build one language at a time.')
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    for code in codes:
        pack = tar_bytes(pack_files(download_sources(code, args.source), download_ui_texts(code, args.ui_texts)))
        (out / f'language-{code}.tar.gz').write_bytes(pack)
        info = manifest(code, pack)
        (out / f'{code}.json').write_text(json.dumps(info, indent=2) + '\n')
        print(f'Built the {code} pack {info["version"]} in {out}')


def api_token():
    token = os.environ.get('CLOUDFLARE_API_TOKEN')
    if not token and os.environ.get('CLOUDFLARE_API_TOKEN_FILE'):
        token = pathlib.Path(os.environ['CLOUDFLARE_API_TOKEN_FILE']).read_text().strip()
    if not token:
        raise PackError('Set CLOUDFLARE_API_TOKEN (or CLOUDFLARE_API_TOKEN_FILE) to use the bucket.')
    return token


def put_object(token, key, data, content_type):
    url = f'https://api.cloudflare.com/client/v4/accounts/{ACCOUNT}/r2/buckets/{BUCKET}/objects/{key}'
    request = urllib.request.Request(url, data=data, method='PUT', headers={
        'Authorization': 'Bearer ' + token, 'Content-Type': content_type})
    try:
        with urllib.request.urlopen(request, timeout=300) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        raise PackError(f'Uploading {key} failed with HTTP {error.code}: {error.read()[:300]!r}') from error
    if not result.get('success'):
        raise PackError(f'Uploading {key} failed: {result.get("errors")}')


def publish(args):
    out = pathlib.Path(args.dir)
    manifests = sorted(path for path in out.glob('*.json') if path.stem in LANGUAGES)
    if not manifests:
        raise PackError(f'{out} has no built packs. Run "build" first.')
    token = api_token()
    for path in manifests:
        info = json.loads(path.read_text())
        pack = (out / f'language-{info["language"]}.tar.gz').read_bytes()
        if sha256(pack) != info['sha256']:
            raise PackError(f'language-{info["language"]}.tar.gz does not match {path.name}. Run "build" again.')
        key = info['url'][len(CDN):]
        put_object(token, key, pack, 'application/gzip')
        # The manifest goes last, so installers never see a version whose pack is not there yet.
        put_object(token, PREFIX + path.name, path.read_bytes(), 'application/json')
        print(f'Published the {info["language"]} pack {info["version"]}: {CDN}{PREFIX}{path.name}')


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    commands = parser.add_subparsers(dest='command', required=True)
    p = commands.add_parser('build', help="download a hotel's texts (or use --source) and pack them")
    p.add_argument('--out', required=True)
    p.add_argument('--language', nargs='+', default=[], help=f'one or more of {", ".join(sorted(LANGUAGES))}')
    p.add_argument('--all', action='store_true', help='every language')
    p.add_argument('--source', help="a folder with Habbo's files saved by hand (one language)")
    p.add_argument('--ui-texts', help="a UITexts file to use instead of Volt's (one language)")
    p.set_defaults(run=build)
    p = commands.add_parser('publish', help='upload the built packs to the asset bucket')
    p.add_argument('dir')
    p.set_defaults(run=publish)
    args = parser.parse_args()
    try:
        args.run(args)
    except PackError as error:
        sys.exit(f'Error: {error}')


if __name__ == '__main__':
    main()
