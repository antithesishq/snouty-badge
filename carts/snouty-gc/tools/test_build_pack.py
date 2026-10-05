#!/usr/bin/env python3
"""tools/build_pack.py's checks (check.sh `tracks` step runs this):

    python3 tools/test_build_pack.py        (from the cart directory)

The test pack builds; the slot budget counts a mover's sprite cell with the
props' cells (a track just over budget only through its mover's cell is
refused, the same cell among its props is fine); crust tiles without a
record, a turret and a bad name are refused.
"""
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "test_pack"))
import build_pack  # noqa: E402
import make  # noqa: E402


class BuildPack(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name)
        make.stage(self.d)

    def tearDown(self):
        self.tmp.cleanup()

    def edit_toml(self, old, new):
        p = self.d / "pack.toml"
        s = p.read_text()
        self.assertIn(old, s)
        p.write_text(s.replace(old, new))

    def sprite(self, path, cell):
        f = bytearray((self.d / path).read_bytes())
        f[0] = (f[0] & 15) | ((cell + 1) << 4)
        (self.d / path).write_bytes(bytes(f))

    def test_test_pack_builds(self):
        file, data, _ = build_pack.build(self.d)
        self.assertEqual(file, "TEST")
        self.assertEqual(data, (HERE.parent / "cart/src/gen/packs/TEST.GCP").read_bytes())

    def test_mover_cell_counts_toward_the_budget(self):
        # The arena: a 3,616 B blob leaves 2,176 B, two 768 B cells. Its
        # props use cells 1 and 3; a Sweeper drawn with cell 0 makes three.
        self.sprite("sandbox_feat.bin", 0)
        with self.assertRaisesRegex(build_pack.PackError, "over the slot"):
            build_pack.build(self.d)
        # Drawn with cell 3, one its props use already: two cells, fits.
        self.sprite("sandbox_feat.bin", 3)
        build_pack.build(self.d)

    def test_crust_tiles_need_a_record(self):
        f = (self.d / "crust_feat.bin").read_bytes()
        (self.d / "crust_feat.bin").write_bytes(f[:20])
        with self.assertRaisesRegex(build_pack.PackError, "no crust record"):
            build_pack.build(self.d)

    def test_turret_refused(self):
        f = bytearray((self.d / "landfill_feat.bin").read_bytes())
        f[0] = 3
        (self.d / "landfill_feat.bin").write_bytes(bytes(f))
        with self.assertRaisesRegex(build_pack.PackError, "turret"):
            build_pack.build(self.d)

    def test_bad_name_refused(self):
        self.edit_toml('name = "TEST PACK"', 'name = "A NAME FAR TOO LONG FOR IT"')
        with self.assertRaisesRegex(build_pack.PackError, "name"):
            build_pack.build(self.d)


if __name__ == "__main__":
    unittest.main(verbosity=1)
