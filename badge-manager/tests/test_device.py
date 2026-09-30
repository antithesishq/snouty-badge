import contextlib
import io
import os
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tests.helpers import make_romfs, make_uf2
from badge_manager import device, fat12


class DirBadgeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.dir = self.tmp / "badge"
        self.dir.mkdir()

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_find_badge(self):
        self.assertIsInstance(device.find_badge(str(self.dir)), device.DirBadge)
        self.assertIsNone(device.find_badge(str(self.tmp / "gone")))
        img = self.tmp / "x.img"
        img.write_bytes(b"")
        with mock.patch.dict(os.environ, {"BADGE_STATION_IMAGE": "builtin"}):
            self.assertIsInstance(device.find_badge(str(img)), device.ImageBadge)
        with mock.patch.dict(os.environ, {"BADGE_STATION_IMAGE": "loop"}):
            self.assertIsInstance(device.find_badge(str(img), self.tmp), device.LoopBadge)

    def test_accounting_and_wipe(self):
        b = device.DirBadge(self.dir)
        self.assertEqual(b.free_entries(), 31)
        self.assertEqual(b.free_bytes(), 2541 * 512)
        (self.dir / "snouty-bugs.uf2").write_bytes(b"x" * 1000)
        (self.dir / "._snouty-bugs.uf2").write_bytes(b"x" * 10)
        (self.dir / ".fseventsd").mkdir()
        (self.dir / ".fseventsd" / "fseventsd-uuid").write_text("x")
        (self.dir / "System Volume Information").mkdir()
        self.assertEqual(b.free_entries(), 31 - 3 - 3 - 2 - 3)
        self.assertEqual(b.free_bytes(), (2541 - 2 - 1 - 1 - 1) * 512)
        self.assertEqual(b.wipe(), 4)
        self.assertEqual(os.listdir(self.dir), [])
        src = make_uf2(self.tmp / "a.uf2")
        b.copy(src, "A.UF2")
        self.assertEqual([(e.name, e.size) for e in b.listdir()], [("A.UF2", 2048)])


class ImageBadgeTest(unittest.TestCase):
    """The station's own FAT writer, checked against tools/make_romfs.py images."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.img = self.tmp / "badge.img"
        junk = self.tmp / "junk"
        junk.write_bytes(b"j" * 700)
        self.romfs = make_romfs()
        with contextlib.redirect_stdout(io.StringIO()):
            self.romfs.main([str(self.img), "--dir", ".fseventsd",
                             f"{junk}=._snouty.uf2", f"{junk}=SONIC.GG",
                             f"{junk}=Sonic The Hedgehog (World).gg"])

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def _list(self) -> str:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.romfs.list_image(str(self.img))
        return out.getvalue()

    def test_reads_make_romfs_image(self):
        b = device.ImageBadge(self.img)
        names = [e.name for e in b.listdir()]
        self.assertEqual(sorted(names, key=str.lower),
                         sorted([".fseventsd", "._snouty.uf2", "SONIC.GG",
                                 "Sonic The Hedgehog (World).gg"], key=str.lower))
        # label 1 + .fseventsd 2 + ._snouty.uf2 2 + SONIC.GG 1 + Sonic... 4
        self.assertEqual(b.free_entries(), 32 - 10)
        self.assertEqual(b.free_bytes(), (2541 - 1 - 2 - 2 - 2) * 512)
        self.assertEqual(b.geometry(), fat12.geometry())

    def test_wipe_and_copy_contiguous(self):
        b = device.ImageBadge(self.img)
        self.assertEqual(b.wipe(), 4)
        self.assertEqual(b.listdir(), [])
        self.assertEqual((b.free_entries(), b.free_bytes()), (31, 2541 * 512))
        a = make_uf2(self.tmp / "a.uf2", "ram", 9)
        rom = self.tmp / "rom.gg"
        rom.write_bytes(os.urandom(5000))
        b.copy(a, "snouty-bugs.uf2")
        b.copy(rom, "SONIC.GG")
        b.copy(a, "snouty.uf2")
        self.assertEqual(b.fragmented(), [])
        self.assertEqual(b.free_entries(), 31 - 3 - 1 - 2)
        listing = self._list()
        self.assertIn("label", listing.splitlines()[2])
        self.assertIn("long 'snouty-bugs.uf2'", listing)
        self.assertIn("'SONIC.GG' attr 0x20 size 5000 first cluster 11", listing)
        self.assertNotIn("fragmented", listing)
        self.assertEqual(listing.count("contiguous"), 3)
        # data round-trips through the FAT chain
        vol = fat12.Fat12Image(str(self.img))
        with open(self.img, "rb") as fh:
            f = next(x for x in fat12.read_volume(fh).files if x.name == "SONIC.GG")
        o = (vol.data_sector + f.first_cluster - 2) * 512
        self.assertEqual(bytes(vol.img[o:o + 5000]), rom.read_bytes())

    def test_copy_replaces_same_name(self):
        b = device.ImageBadge(self.img)
        a = make_uf2(self.tmp / "a.uf2", "ram", 2)
        b.copy(a, "sonic.gg")        # same file as SONIC.GG, case-insensitive
        names = [e.name for e in b.listdir()]
        self.assertEqual([n for n in names if n.lower() == "sonic.gg"], ["sonic.gg"])


class UsbScanTest(unittest.TestCase):
    def test_no_usb_device(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertIsNone(device._by_usb_id(d))


if __name__ == "__main__":
    unittest.main()
