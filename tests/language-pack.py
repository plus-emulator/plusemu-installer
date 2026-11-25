#!/usr/bin/env python3
"""Exercise tools/language-pack.py against small files shaped like Habbo's gamedata."""
import argparse
import importlib.util
import io
import json
import pathlib
import tarfile
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('language_pack', ROOT / 'tools' / 'language-pack.py')
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)

TEXTS = '﻿widget.chatbubble.say=Sagen\r\nsimple=a=b\n\nnot a pair\nempty=\n'
FURNIDATA = json.dumps({
    'roomitemtypes': {'furnitype': [{'id': 13, 'classname': 'shelves_norja', 'name': 'Beiges Regal', 'description': 'Für Bücher.'}]},
    'wallitemtypes': {'furnitype': [{'id': 4001, 'classname': 'poster', 'name': 'Poster', 'description': None}]},
})
PRODUCTDATA = json.dumps({'productdata': {'product': [{'code': 'shelves_norja', 'name': 'Beiges Regal', 'description': 'Für Bücher.'},
                                                     {'code': 25, 'name': 'Schulset', 'description': ''}]}})


def write_source(folder):
    (folder / 'external_flash_texts.txt').write_text(TEXTS, encoding='utf-8')
    (folder / 'furnidata.json').write_text(FURNIDATA, encoding='utf-8')
    (folder / 'productdata.json').write_text(PRODUCTDATA, encoding='utf-8')


def build(out, source, ui_texts=None):
    tool.build(argparse.Namespace(out=str(out), language=['de'], all=False, source=str(source), ui_texts=ui_texts))


def unpack(path):
    with tarfile.open(path) as tar:
        return {member.name: tar.extractfile(member).read() for member in tar.getmembers()}


class LanguagePackTest(unittest.TestCase):
    def setUp(self):
        self.folder = pathlib.Path(tempfile.mkdtemp())
        self.source = self.folder / 'source'
        self.source.mkdir()
        write_source(self.source)
        self.fetch = tool.fetch

    def tearDown(self):
        tool.fetch = self.fetch

    def without_volt_texts(self):
        def missing(url, *_args):
            raise tool.PackError(f'{url} answered 404')
        tool.fetch = missing

    def test_flash_texts_keep_every_equals_sign_in_values(self):
        texts = tool.flash_texts(TEXTS.lstrip('﻿'))
        self.assertEqual(texts, {'widget.chatbubble.say': 'Sagen', 'simple': 'a=b', 'empty': ''})

    def test_an_html_block_page_is_refused(self):
        with self.assertRaisesRegex(tool.PackError, 'HTML page'):
            tool.text(b'<!DOCTYPE html><title>463 Restricted Client</title>', 'external_flash_texts.txt')

    def test_furni_names_come_from_floor_and_wall_items(self):
        self.assertEqual(tool.furni_names(FURNIDATA), {
            'shelves_norja': {'name': 'Beiges Regal', 'description': 'Für Bücher.'},
            'poster': {'name': 'Poster', 'description': ''},
        })

    def test_numeric_product_codes_are_kept_as_text(self):
        self.assertEqual(tool.product_names(PRODUCTDATA)['25'], {'name': 'Schulset', 'description': ''})

    def test_the_pack_holds_the_texts_and_the_names(self):
        self.without_volt_texts()
        build(self.folder / 'dist', self.source)
        files = unpack(self.folder / 'dist' / 'language-de.tar.gz')
        self.assertEqual(sorted(files), ['ExternalTexts.json', 'furni-names.json', 'product-names.json'])
        self.assertEqual(json.loads(files['ExternalTexts.json'])['widget.chatbubble.say'], 'Sagen')
        self.assertEqual(json.loads(files['product-names.json'])['shelves_norja']['name'], 'Beiges Regal')

    def test_the_manifest_names_the_pack_by_its_checksum(self):
        self.without_volt_texts()
        build(self.folder / 'dist', self.source)
        pack = (self.folder / 'dist' / 'language-de.tar.gz').read_bytes()
        info = json.loads((self.folder / 'dist' / 'de.json').read_text())
        self.assertEqual(info['sha256'], tool.sha256(pack))
        self.assertEqual(info['url'], f'https://assets.plusemu.dev/language/de/{info["version"]}/language-de.tar.gz')
        self.assertEqual(info['hotel'], 'https://www.habbo.de')

    def test_the_same_files_give_the_same_pack(self):
        self.without_volt_texts()
        build(self.folder / 'one', self.source)
        build(self.folder / 'two', self.source)
        self.assertEqual((self.folder / 'one' / 'de.json').read_text(), (self.folder / 'two' / 'de.json').read_text())

    def test_volt_interface_texts_are_added_when_given(self):
        ui = self.folder / 'UITexts_de.jsonc'
        ui.write_text('{\n    // Deutsch\n    "connection.login.name": "Name"\n}\n', encoding='utf-8')
        build(self.folder / 'dist', self.source, str(ui))
        files = unpack(self.folder / 'dist' / 'language-de.tar.gz')
        self.assertIn('// Deutsch', files['UITexts.jsonc'].decode())

    def test_a_missing_source_file_is_named(self):
        (self.source / 'productdata.json').unlink()
        with self.assertRaisesRegex(tool.PackError, 'productdata.json'):
            build(self.folder / 'dist', self.source)

    def test_an_unknown_language_is_refused(self):
        with self.assertRaisesRegex(tool.PackError, 'Unknown language xx'):
            tool.build(argparse.Namespace(out=str(self.folder), language=['xx'], all=False, source=None, ui_texts=None))


if __name__ == '__main__':
    unittest.main()
