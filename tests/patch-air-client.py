#!/usr/bin/env python3
"""Exercise tools/patch-air-client.py against small SWF files built here, shaped like the AIR client."""
import importlib.util
import io
import pathlib
import struct
import sys
import unittest
import zipfile
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('patch_air_client', ROOT / 'tools' / 'patch-air-client.py')
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)


def u30(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        out.append(byte | (0x80 if value else 0))
        if not value:
            return bytes(out)


def suffix_append(text, pool, shift=0, last=tool.OP_ADD, sizes=(5, 3, 2)):
    """The client's bytecode for "host + getKeyValue([[...],[...],[...]], shift)", adding values to pool."""
    code, groups, index = bytearray(), [], 0
    values = [65290 - ord(char) + shift - position for position, char in enumerate(text)]
    for size in sizes:
        groups.append(values[index:index + size])
        index += size
    for group in groups:
        for value in group:
            pool.append(value)
            code += bytes([tool.OP_PUSHINT]) + u30(len(pool))  # pool index 0 is the implicit zero
        code += bytes([tool.OP_NEWARRAY]) + u30(len(group))
    code += bytes([tool.OP_NEWARRAY]) + u30(len(groups))
    code += bytes([tool.OP_PUSHBYTE, shift & 0xFF, tool.OP_CALLPROPERTY]) + u30(7) + u30(2) + bytes([last])
    return bytes(code)


def s32(value):
    return u30(value & 0xFFFFFFFF if value < 0 else value)


def swf(*appends, compressed=True):
    """A SWF with one DoABC tag holding the given suffix appends (each a (text, last opcode) pair)."""
    pool, code = [], bytearray(b'\x02\x03\x2d')  # unrelated bytes, including a stray pushint
    for text, last in appends:
        code += suffix_append(text, pool, last=last) + b'\x47'
    abc = struct.pack('<HH', 16, 46) + u30(len(pool) + 1) + b''.join(s32(v) for v in pool) + bytes(code)
    do_abc = struct.pack('<I', 1) + b'frame1\x00' + abc
    header = b'\x08\x00' + b'\x00\x18\x01\x00'  # 1-bit-wide empty rectangle, frame rate, frame count
    body = header + struct.pack('<HI', (82 << 6) | 0x3F, len(do_abc)) + do_abc + b'\x00\x00'
    payload = zlib.compress(body) if compressed else body
    return (b'CWS' if compressed else b'FWS') + bytes([30]) + struct.pack('<I', len(body) + 8) + payload


def last_opcodes(raw):
    _, _, _, tags = tool.read_swf(raw)
    data = tags[0][2]
    abc = data[data.index(0, 4) + 1:]
    return [abc[offset] for offset in tool.find_suffix_appends(abc)]


class PatchSwf(unittest.TestCase):
    def test_turns_the_suffix_add_into_pop(self):
        patched, state = tool.patch_swf(swf(('.habbo.com', tool.OP_ADD)))
        self.assertEqual(state, 'patched')
        self.assertEqual(last_opcodes(patched), [tool.OP_POP])

    def test_keeps_an_uncompressed_swf_uncompressed(self):
        patched, _ = tool.patch_swf(swf(('.habbo.com', tool.OP_ADD), compressed=False))
        self.assertEqual(patched[:3], b'FWS')
        self.assertEqual(last_opcodes(patched), [tool.OP_POP])

    def test_leaves_an_already_patched_client_unchanged(self):
        original = swf(('.habbo.com', tool.OP_POP))
        patched, state = tool.patch_swf(original)
        self.assertEqual(state, 'already patched')
        self.assertEqual(patched, original)

    def test_ignores_other_obfuscated_strings(self):
        patched, _ = tool.patch_swf(swf(('.sulake.fi', tool.OP_ADD), ('.habbo.com', tool.OP_ADD)))
        _, _, _, tags = tool.read_swf(patched)
        self.assertIn(bytes([tool.OP_ADD]), bytes(tags[0][2]))
        self.assertEqual(last_opcodes(patched), [tool.OP_POP])

    def test_refuses_a_client_without_the_suffix(self):
        with self.assertRaisesRegex(tool.PatchError, 'found 0'):
            tool.patch_swf(swf(('.sulake.fi', tool.OP_ADD)))

    def test_refuses_a_client_with_two_suffixes(self):
        with self.assertRaisesRegex(tool.PatchError, 'found 2'):
            tool.patch_swf(swf(('.habbo.com', tool.OP_ADD), ('.habbo.com', tool.OP_ADD)))

    def test_refuses_an_encrypted_swf(self):
        with self.assertRaisesRegex(tool.PatchError, 'Unsupported SWF type'):
            tool.patch_swf(b'cWS' + swf(('.habbo.com', tool.OP_ADD))[3:])


class PatchZip(unittest.TestCase):
    def test_patches_only_habboair_swf(self):
        source = io.BytesIO()
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('HabboAir.swf', swf(('.habbo.com', tool.OP_ADD)))
            archive.writestr('META-INF/AIR/application.xml', '<application/>', compress_type=zipfile.ZIP_DEFLATED)
        target = io.BytesIO()
        self.assertEqual(tool.patch_zip(io.BytesIO(source.getvalue()), target), 'patched')
        with zipfile.ZipFile(target) as archive:
            self.assertEqual(archive.namelist(), ['HabboAir.swf', 'META-INF/AIR/application.xml'])
            self.assertEqual(last_opcodes(archive.read('HabboAir.swf')), [tool.OP_POP])
            self.assertEqual(archive.read('META-INF/AIR/application.xml'), b'<application/>')
            self.assertEqual(archive.getinfo('META-INF/AIR/application.xml').compress_type, zipfile.ZIP_DEFLATED)

    def test_refuses_a_zip_without_the_client(self):
        source = io.BytesIO()
        with zipfile.ZipFile(source, 'w') as archive:
            archive.writestr('readme.txt', 'no client')
        with self.assertRaisesRegex(tool.PatchError, 'HabboAir.swf is not in the client zip'):
            tool.patch_zip(io.BytesIO(source.getvalue()), io.BytesIO())


if __name__ == '__main__':
    sys.exit(unittest.main())
