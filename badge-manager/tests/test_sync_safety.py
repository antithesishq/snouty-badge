import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from tests.helpers import ROOT, make_library, make_uf2
from badge_manager.library import Library


class SyncSafetyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.library = make_library(self.base / 'library')
        self.firmware = self.base / 'repo' / 'zig-out' / 'firmware'
        self.firmware.mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def sync(self):
        return subprocess.run(['bash', str(ROOT / 'sync.sh'), 'local', str(self.base / 'repo')],
                              env={**os.environ, 'BADGE_STATION_LIBRARY': str(self.library)},
                              cwd=ROOT, text=True, capture_output=True)

    def test_bad_update_preserves_existing_cart_and_manifest(self):
        source = self.library / 'carts' / 'snouty.uf2'
        before = source.read_bytes()
        manifest = (self.library / 'manifest.toml').read_bytes()
        (self.firmware / 'snouty.uf2').write_bytes(b'INVALID')
        result = self.sync()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('size', result.stderr)
        self.assertEqual(source.read_bytes(), before)
        self.assertEqual((self.library / 'manifest.toml').read_bytes(), manifest)

    def test_complete_batch_validation_before_promotion(self):
        make_uf2(self.firmware / 'new.uf2', 'ram')
        (self.firmware / 'snouty.uf2').write_bytes(b'INVALID')
        result = self.sync()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.library / 'carts' / 'new.uf2').exists())
        self.assertNotIn('new', Library(self.library).carts)
        (self.firmware / 'snouty.uf2').unlink()
        result = self.sync()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('new', Library(self.library).carts)

    def test_manifest_failure_preserves_artifact(self):
        make_uf2(self.firmware / 'snouty.uf2', 'ram', 2)
        old = (self.library / 'carts' / 'snouty.uf2').read_bytes()
        manifest = self.library / 'manifest.toml'
        broken = manifest.read_bytes() + b'\n[broken\n'
        manifest.write_bytes(broken)
        result = self.sync()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.library / 'carts' / 'snouty.uf2').read_bytes(), old)
        self.assertEqual(manifest.read_bytes(), broken)

    def test_existing_unnamed_artifact_is_registered(self):
        existing = make_uf2(self.library / 'carts' / 'orphan.uf2', 'ram')
        (self.firmware / existing.name).write_bytes(existing.read_bytes())
        self.assertTrue(Library(self.library).carts['orphan'].auto)
        result = self.sync()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(Library(self.library).carts['orphan'].auto)
