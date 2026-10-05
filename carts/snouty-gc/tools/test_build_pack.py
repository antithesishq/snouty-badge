#!/usr/bin/env python3
"""tools/build_pack.py's checks (check.sh `tracks` step runs this):

    python3 tools/test_build_pack.py        (from the cart directory)

The test pack builds; a mover's sprite cell must be inside the sheet;
crust tiles without a record, a turret and a bad name are refused.
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

    def test_mover_sprite_cell_inside_the_sheet(self):
        # The test pack has 4 cells: a Sweeper drawn with cell 3 builds,
        # with cell 4 it is refused; a sprite on a blast is refused too.
        self.sprite("sandbox_feat.bin", 3)
        build_pack.build(self.d)
        self.sprite("sandbox_feat.bin", 4)
        with self.assertRaisesRegex(build_pack.PackError, "sprite cell"):
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
