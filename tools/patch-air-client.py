#!/usr/bin/env python3
"""Build the patched Habbo AIR client that hotels installed with --with-air hand to their players.

The official AIR client only connects to Habbo's own game servers: HabboCommunicationManager cuts
10 characters off connection.info.host and appends an obfuscated ".habbo.com" before it opens the
socket. This tool turns the instruction that appends it ("add") into "pop", so the client keeps the
host it was given. The launcher (HabboCustomLauncher) then writes the hotel's host, ports and RSA
key into the client, and appends ".habbo.com" to the host so the cut leaves the real host.

    python3 tools/patch-air-client.py build --out dist             # download Habbo's client and patch it
    python3 tools/patch-air-client.py build --zip HabboWin.zip --out dist
    python3 tools/patch-air-client.py publish dist                 # upload dist to the asset bucket
    python3 tools/patch-air-client.py patch HabboAir.swf           # patch one SWF in place
    python3 tools/patch-air-client.py check                        # is the published client Habbo's newest?

The published files live under https://assets.plusemu.dev/air/:
    air/latest.json                          the manifest the installers read
    air/client/<version>/HabboWin.zip        the patched client (the launcher downloads it)
    air/client/<version>/external_variables.txt, external_flash_texts.txt
                                             Habbo's AIR texts, served by the emulator

<version> is Habbo's client version plus this tool's PATCH_REVISION, for example 38-1. Raise
PATCH_REVISION when the patch changes, so launchers download the client again.

Habbo blocks many data center addresses, so run "build" from a home connection when it fails with
HTTP 403 or 463. "publish" and "check" need a Cloudflare API token with R2 write (publish) or read
(check) access in CLOUDFLARE_API_TOKEN, or in the file named by CLOUDFLARE_API_TOKEN_FILE.
"""
import argparse
import hashlib
import io
import json
import os
import pathlib
import struct
import sys
import urllib.error
import urllib.request
import zipfile
import zlib

PATCH_REVISION = 1
ACCOUNT = '3fdff0e3dfbd383625477d7bfd7e5b7d'
BUCKET = 'plusemu-assets'
CDN = 'https://assets.plusemu.dev/'
PREFIX = 'air/'
HABBO = 'https://www.habbo.com'
TEXT_FILES = {
    'external_variables.txt': HABBO + '/gamedata/external_variables/1',
    'external_flash_texts.txt': HABBO + '/gamedata/external_flash_texts/1',
}
# Habbo's edge rejects requests that do not look like a browser.
BROWSER = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'

SUFFIX = '.habbo.com'
DO_ABC = 82
OP_PUSHINT, OP_PUSHBYTE, OP_NEWARRAY, OP_CALLPROPERTY = 0x2D, 0x24, 0x56, 0x46
OP_ADD, OP_POP = 0xA0, 0x29


class PatchError(Exception):
    pass


# ---------------------------------------------------------------------------------------------
# SWF and ABC reading


def u30(data, offset):
    """An ABC variable-length integer: (value, offset after it)."""
    result = shift = 0
    while True:
        byte = data[offset]
        offset += 1
        result |= (byte & 0x7F) << shift
        shift += 7
        if not byte & 0x80 or shift >= 35:
            return result, offset


def s32(data, offset):
    """An ABC signed integer, sign-extended from the width it was written with."""
    value, end = u30(data, offset)
    bits = 7 * (end - offset)
    if bits < 32:
        if value & (1 << (bits - 1)):
            value -= 1 << bits
    else:
        value &= 0xFFFFFFFF
        if value > 0x7FFFFFFF:
            value -= 1 << 32
    return value, end


def read_swf(raw):
    """(signature, version, header bytes, tags). Each tag is [code, long header, bytearray]."""
    signature, version = raw[:3], raw[3]
    if signature == b'CWS':
        body = zlib.decompress(raw[8:])
    elif signature == b'FWS':
        body = raw[8:]
    else:
        raise PatchError(f'Unsupported SWF type {signature!r}. Only plain (FWS) and zlib (CWS) SWF files work.')
    header_end = (5 + 4 * (body[0] >> 3) + 7) // 8 + 4  # frame rectangle, frame rate, frame count
    tags, offset = [], header_end
    while offset + 2 <= len(body):
        code_and_length = struct.unpack_from('<H', body, offset)[0]
        offset += 2
        code, length, is_long = code_and_length >> 6, code_and_length & 0x3F, False
        if length == 0x3F:
            length = struct.unpack_from('<I', body, offset)[0]
            offset += 4
            is_long = True
        tags.append([code, is_long, bytearray(body[offset:offset + length])])
        offset += length
        if code == 0:
            break
    return signature, version, body[:header_end], tags


def write_swf(signature, version, header, tags):
    parts = [header]
    for code, is_long, data in tags:
        if len(data) < 0x3F and not is_long:
            parts.append(struct.pack('<H', (code << 6) | len(data)) + bytes(data))
        else:
            parts.append(struct.pack('<HI', (code << 6) | 0x3F, len(data)) + bytes(data))
    body = b''.join(parts)
    payload = zlib.compress(body, 9) if signature == b'CWS' else body
    return signature + bytes([version]) + struct.pack('<I', len(body) + 8) + payload


def int_pool(abc):
    """The ABC integer constant pool. Index 0 is the implicit zero."""
    count, offset = u30(abc, 4)  # after minor and major version
    pool = [0]
    for _ in range(count - 1):
        value, offset = s32(abc, offset)
        pool.append(value)
    return pool


def decode_suffix_append(abc, start, pool):
    """Read "(pushint+ newarray n)+ newarray g, pushbyte s, callproperty x 2, add|pop" at start.

    Returns (decoded text, offset of the add or pop byte), or None when the bytes there are
    something else. getKeyValue decodes each pushed value as chr(65290 - value + shift), with
    shift starting at the pushbyte value and counting down by one per character.
    """
    try:
        offset, groups = start, []
        while abc[offset] == OP_PUSHINT:
            group = []
            while abc[offset] == OP_PUSHINT:
                index, offset = u30(abc, offset + 1)
                if not 0 < index < len(pool):
                    return None
                group.append(pool[index])
            if abc[offset] != OP_NEWARRAY:
                return None
            size, offset = u30(abc, offset + 1)
            if size != len(group):
                return None
            groups.append(group)
        if not groups or abc[offset] != OP_NEWARRAY:
            return None
        size, offset = u30(abc, offset + 1)
        if size != len(groups) or abc[offset] != OP_PUSHBYTE:
            return None
        shift = abc[offset + 1] - 256 if abc[offset + 1] > 127 else abc[offset + 1]
        offset += 2
        if abc[offset] != OP_CALLPROPERTY:
            return None
        _, offset = u30(abc, offset + 1)
        argc, offset = u30(abc, offset)
        if argc != 2 or abc[offset] not in (OP_ADD, OP_POP):
            return None
        text = ''
        for group in groups:
            for value in group:
                code = 65290 - value + shift
                if not 32 <= code <= 126:
                    return None
                text += chr(code)
                shift -= 1
        return text, offset
    except IndexError:
        return None


def find_suffix_appends(abc):
    """Offsets of every add or pop byte that follows a decoded ".habbo.com"."""
    pool = int_pool(abc)
    hits = []
    for start in range(len(abc)):
        if abc[start] == OP_PUSHINT:
            found = decode_suffix_append(abc, start, pool)
            if found and found[0] == SUFFIX:
                hits.append(found[1])
    return hits


# ---------------------------------------------------------------------------------------------
# Patching


def patch_swf(raw):
    """(patched SWF bytes, state). state is "patched", or "already patched" when nothing changed.

    Raises PatchError unless the client has exactly one forced suffix, so a client that Habbo
    changed is never published half patched.
    """
    signature, version, header, tags = read_swf(raw)
    hits = []
    for tag in tags:
        if tag[0] != DO_ABC:
            continue
        data = tag[2]
        abc_start = data.index(0, 4) + 1  # flags (4 bytes), then a null-terminated name
        abc = data[abc_start:]
        hits.extend((tag, abc_start + offset) for offset in find_suffix_appends(abc))
    if len(hits) != 1:
        raise PatchError(f'Expected one forced "{SUFFIX}" in the client, found {len(hits)}. '
                         'Habbo changed the client; update this tool before publishing it.')
    tag, offset = hits[0]
    if tag[2][offset] == OP_POP:
        return raw, 'already patched'
    tag[2][offset] = OP_POP
    return write_swf(signature, version, header, tags), 'patched'


def patch_zip(source, target):
    """Copy the client zip with HabboAir.swf patched; every other entry stays as it was."""
    with zipfile.ZipFile(source) as original, zipfile.ZipFile(target, 'w') as patched:
        names = original.namelist()
        if 'HabboAir.swf' not in names:
            raise PatchError('HabboAir.swf is not in the client zip.')
        for info in original.infolist():
            data = original.read(info)
            if info.filename == 'HabboAir.swf':
                data, state = patch_swf(data)
            patched.writestr(info, data, compress_type=info.compress_type)
    return state


# ---------------------------------------------------------------------------------------------
# Downloads and the bucket


def fetch(url, user_agent='plusemu-air-client'):
    request = urllib.request.Request(url, headers={'User-Agent': user_agent, 'Accept': '*/*'})
    try:
        with urllib.request.urlopen(request, timeout=300) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        hint = ' Habbo blocks this address; run the build from a home connection.' if error.code in (403, 463) else ''
        raise PatchError(f'Downloading {url} failed with HTTP {error.code}.{hint}') from error


def api_token():
    token = os.environ.get('CLOUDFLARE_API_TOKEN')
    if not token and os.environ.get('CLOUDFLARE_API_TOKEN_FILE'):
        token = pathlib.Path(os.environ['CLOUDFLARE_API_TOKEN_FILE']).read_text().strip()
    if not token:
        raise PatchError('Set CLOUDFLARE_API_TOKEN (or CLOUDFLARE_API_TOKEN_FILE) to use the bucket.')
    return token


def put_object(token, key, data, content_type):
    url = f'https://api.cloudflare.com/client/v4/accounts/{ACCOUNT}/r2/buckets/{BUCKET}/objects/{key}'
    request = urllib.request.Request(url, data=data, method='PUT', headers={
        'Authorization': 'Bearer ' + token, 'Content-Type': content_type})
    try:
        with urllib.request.urlopen(request, timeout=300) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        raise PatchError(f'Uploading {key} failed with HTTP {error.code}: {error.read()[:300]!r}') from error
    if not result.get('success'):
        raise PatchError(f'Uploading {key} failed: {result.get("errors")}')


def published_manifest():
    try:
        return json.loads(fetch(CDN + PREFIX + 'latest.json'))
    except PatchError:
        return None


def sha256(data):
    return hashlib.sha256(data).hexdigest()


# ---------------------------------------------------------------------------------------------
# Commands


def build(args):
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    if args.zip:
        if not args.habbo_version:
            raise PatchError('--zip needs --habbo-version (the "flash-windows-version" of that client).')
        habbo_version, source = args.habbo_version, pathlib.Path(args.zip).read_bytes()
    else:
        urls = json.loads(fetch(HABBO + '/gamedata/clienturls', BROWSER))
        habbo_version = str(urls['flash-windows-version'])
        print(f'Downloading Habbo AIR client {habbo_version}')
        source = fetch(urls['flash-windows'], BROWSER)

    zip_path = out / 'HabboWin.zip'
    state = patch_zip(io.BytesIO(source), zip_path)
    print(f'HabboAir.swf: {state}')

    version = f'{habbo_version}-{PATCH_REVISION}'
    files = {'HabboWin.zip': zip_path.read_bytes()}
    for name, url in TEXT_FILES.items():
        text_path = pathlib.Path(args.texts) / name if args.texts else None
        files[name] = text_path.read_bytes() if text_path else fetch(url, BROWSER)
        if not files[name].strip() or files[name].lstrip().startswith(b'<'):
            raise PatchError(f'{name} is empty or an HTML page, not the texts file.')
        (out / name).write_bytes(files[name])

    base = f'{CDN}{PREFIX}client/{version}/'
    manifest = {
        'version': version,
        'habboVersion': habbo_version,
        'client': {'url': base + 'HabboWin.zip', 'sha256': sha256(files['HabboWin.zip'])},
        'externalVariables': {'url': base + 'external_variables.txt', 'sha256': sha256(files['external_variables.txt'])},
        'externalFlashTexts': {'url': base + 'external_flash_texts.txt', 'sha256': sha256(files['external_flash_texts.txt'])},
    }
    (out / 'latest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Built AIR client {version} in {out}')


def publish(args):
    out = pathlib.Path(args.dir)
    manifest = json.loads((out / 'latest.json').read_text())
    token = api_token()
    version = manifest['version']
    for name, content_type in (('HabboWin.zip', 'application/zip'),
                               ('external_variables.txt', 'text/plain; charset=utf-8'),
                               ('external_flash_texts.txt', 'text/plain; charset=utf-8')):
        data = (out / name).read_bytes()
        expected = {'HabboWin.zip': manifest['client'], 'external_variables.txt': manifest['externalVariables'],
                    'external_flash_texts.txt': manifest['externalFlashTexts']}[name]['sha256']
        if sha256(data) != expected:
            raise PatchError(f'{name} does not match latest.json. Run "build" again.')
        put_object(token, f'{PREFIX}client/{version}/{name}', data, content_type)
        print(f'Uploaded {PREFIX}client/{version}/{name}')
    # The manifest goes last, so installers never see a version whose files are not there yet.
    put_object(token, PREFIX + 'latest.json', (out / 'latest.json').read_bytes(), 'application/json')
    print(f'Published AIR client {version}: {CDN}{PREFIX}latest.json')


def patch(args):
    path = pathlib.Path(args.swf)
    data, state = patch_swf(path.read_bytes())
    if state == 'patched':
        pathlib.Path(args.out or path).write_bytes(data)
    print(f'{path}: {state}')


def check(_args):
    published = published_manifest()
    habbo_version = str(json.loads(fetch(HABBO + '/gamedata/clienturls', BROWSER))['flash-windows-version'])
    if published and published.get('habboVersion') == habbo_version:
        print(f'Up to date: the published client {published["version"]} is Habbo\'s client {habbo_version}.')
        return
    print(f'Habbo released client {habbo_version}; published: {published["version"] if published else "none"}.')
    sys.exit(3)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    commands = parser.add_subparsers(dest='command', required=True)
    p = commands.add_parser('build', help="download Habbo's client (or use --zip) and patch it")
    p.add_argument('--out', required=True)
    p.add_argument('--zip', help='a HabboWin.zip you downloaded yourself')
    p.add_argument('--habbo-version', help='the client version of --zip, for example 38')
    p.add_argument('--texts', help='a folder with external_variables.txt and external_flash_texts.txt')
    p.set_defaults(run=build)
    p = commands.add_parser('publish', help='upload a build to the asset bucket')
    p.add_argument('dir')
    p.set_defaults(run=publish)
    p = commands.add_parser('patch', help='patch one HabboAir.swf')
    p.add_argument('swf')
    p.add_argument('--out', help='write the result here instead of changing the file')
    p.set_defaults(run=patch)
    p = commands.add_parser('check', help="exit 3 when Habbo has a newer client than the published one")
    p.set_defaults(run=check)
    args = parser.parse_args()
    try:
        args.run(args)
    except PatchError as error:
        sys.exit(f'Error: {error}')


if __name__ == '__main__':
    main()
