import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from validate_source import validate, find_package
spec = importlib.util.spec_from_file_location('publish', ROOT / 'scripts/publish_xtapp.py')
publish = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publish)
SOURCE = ROOT / 'source/ybx-studio'
PACKAGE = ROOT / 'package/YBX-1.7.0.xtapp'

class ReleasePipelineTests(unittest.TestCase):
    def test_current_official_export_passes(self):
        self.assertEqual(validate(), [])
        self.assertEqual(publish.source_version(), '1.7.0')
        errors = []
        self.assertEqual(find_package(errors, '1.7.0'), PACKAGE)
        self.assertFalse(errors)

    def test_same_size_source_edit_requires_new_export(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / 'source'
            shutil.copytree(SOURCE, source, ignore=shutil.ignore_patterns('docs'))
            p = source / 'index.lua'
            p.write_bytes(p.read_bytes().replace(b'YBX.app', b'YBX.xyz', 1))
            self.assertTrue(any('source/assets differ' in e for e in validate(source, PACKAGE)))

    def test_modified_ciphertext_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'bad.xtapp'
            data = bytearray(PACKAGE.read_bytes()); data[5000] ^= 1; p.write_bytes(data)
            self.assertTrue(any('SHA-256' in e for e in validate(SOURCE, p)))

    def test_wrong_version_rejected_before_site_mutation(self):
        with tempfile.TemporaryDirectory() as tmp:
            site = Path(tmp) / 'site'
            with self.assertRaises(Exception):
                publish.publish(ROOT / 'package/YBX-1.6.17.xtapp', '1.7.0', '', False, False, site)
            self.assertFalse(site.exists())

    def test_dry_run_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            site = Path(tmp) / 'site'
            before = hashlib.sha256(PACKAGE.read_bytes()).hexdigest()
            publish.publish(PACKAGE, '1.7.0', 'check', False, True, site)
            self.assertFalse(site.exists())
            self.assertEqual(hashlib.sha256(PACKAGE.read_bytes()).hexdigest(), before)

    def test_immutable_version_cannot_be_replaced(self):
        with tempfile.TemporaryDirectory() as tmp:
            site = Path(tmp) / 'site'
            static = site / publish.STATIC_SUBDIR
            static.mkdir(parents=True)
            (static / 'YBX-1.7.0.xtapp').write_bytes(b'previous export')
            with self.assertRaises(SystemExit):
                publish.publish(PACKAGE, '1.7.0', 'check', False, False, site)
            self.assertFalse((static / 'gancao').exists())

    def test_isolated_site_receives_exact_export(self):
        with tempfile.TemporaryDirectory() as tmp:
            site = Path(tmp) / 'site'
            publish.publish(PACKAGE, '1.7.0', 'check', False, False, site)
            static = site / publish.STATIC_SUBDIR
            latest = json.loads((static / 'gancao' / 'latest.json').read_text())
            target = static / 'YBX-1.7.0.xtapp'
            self.assertEqual(target.read_bytes(), PACKAGE.read_bytes())
            self.assertEqual(latest['version'], '1.7.0')
            self.assertEqual(latest['sha256'], hashlib.sha256(target.read_bytes()).hexdigest())

if __name__ == '__main__':
    unittest.main()
