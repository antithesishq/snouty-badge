import shutil
import tempfile
import tomllib
import unittest
from pathlib import Path

from tests.helpers import make_library, make_uf2
from badge_manager.library import Library, LibraryError, UF2Error, validate_uf2


class LibraryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.root = make_library(self.tmp / "library")
        self.lib = Library(self.root)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_parse(self):
        self.assertEqual(set(self.lib.sets), {"demo", "gear", "broken"})
        c = self.lib.carts["snouty"]
        self.assertEqual((c.title, c.mode, c.size, c.error), ("Snouty Run", "ram", 6 * 512, ""))
        self.assertEqual(self.lib.carts["genesis-xip"].mode, "xip")
        self.assertEqual(self.lib.carts["snouty-bugs"].mode, "ram")   # detected, no mode key
        self.assertEqual(self.lib.roms["sonic"].size, 3000)

    def test_plan_order_and_names(self):
        plan = self.lib.plan("gear")
        self.assertEqual([p.name for p in plan], ["snouty-gear.uf2", "SONIC.GG", "SONIC2.GG"])
        self.assertEqual(plan[1].src.name, "Sonic The Hedgehog (World).gg")
        self.assertEqual([p.name for p in self.lib.plan("demo")], ["snouty.uf2", "snouty-bugs.uf2"])

    def test_explicit_short_name_reserved(self):
        text = (self.root / "manifest.toml").read_text().replace(
            'title = "Sonic 2"', 'title = "Sonic 2"\nshort = "SONIC.GG"')
        (self.root / "manifest.toml").write_text(text)
        self.lib.reload()
        self.assertEqual([p.name for p in self.lib.plan("gear")][1:], ["SONIC2.GG", "SONIC.GG"])

    def test_fit(self):
        rep = self.lib.fit("gear")
        self.assertTrue(rep.fits)
        self.assertEqual(rep.entries_used, 3 + 1 + 1)
        self.assertEqual(rep.bytes_used, (5 + 6 + 3) * 512)

    def test_missing_things_do_not_crash(self):
        rep = self.lib.fit("broken")
        self.assertFalse(rep.fits)
        self.assertIn("cart 'missing-cart' is not in the library", rep.why)
        self.assertIn("ROM 'nope' is not in the library", rep.why)
        with self.assertRaises(LibraryError):
            self.lib.plan("broken")
        with self.assertRaises(LibraryError):
            self.lib.plan("no-such-set")
        (self.root / "carts" / "snouty-bugs.uf2").unlink()
        self.lib.reload()
        rep = self.lib.fit("demo")
        self.assertEqual(rep.why, ["snouty-bugs.uf2 is missing from the library"])
        sets = {s["name"]: s for s in self.lib.to_json()["sets"]}
        self.assertFalse(sets["demo"]["fits"])

    def test_mode_mismatch(self):
        make_uf2(self.root / "carts" / "snouty.uf2", "xip", 2)
        self.lib.reload()
        self.assertIn("XIP cart, the manifest says RAM", self.lib.carts["snouty"].error)
        self.assertFalse(self.lib.fit("demo").fits)

    def test_validate_uf2(self):
        d = self.tmp
        self.assertEqual(validate_uf2(make_uf2(d / "r.uf2", "ram")), "ram")
        self.assertEqual(validate_uf2(make_uf2(d / "x.uf2", "xip")), "xip")
        with self.assertRaisesRegex(UF2Error, "mixed"):
            validate_uf2(make_uf2(d / "m.uf2", "mixed"))
        (d / "bad.uf2").write_bytes(b"\0" * 512)
        with self.assertRaisesRegex(UF2Error, "bad magic"):
            validate_uf2(d / "bad.uf2")
        (d / "short.uf2").write_bytes(b"\0" * 100)
        with self.assertRaisesRegex(UF2Error, "multiple of 512"):
            validate_uf2(d / "short.uf2")

    def test_auto_discovery(self):
        make_uf2(self.root / "carts" / "snouty-maze.uf2", "ram", 2)
        (self.root / "roms" / "Tetris (World).gb").write_bytes(b"x" * 10)
        self.lib.reload()
        self.assertTrue(self.lib.carts["snouty-maze"].auto)
        self.assertTrue(self.lib.roms["tetris-world"].auto)
        roms = {r["key"]: r for r in self.lib.to_json()["library"]["roms"]}
        self.assertEqual(roms["tetris-world"]["short"], "TETRIS.GB")

    def test_add_rom_rewrites_manifest(self):
        src = self.tmp / "Tetris (World).gb"
        src.write_bytes(b"t" * 700)
        r = self.lib.add_rom(src, title="Tetris")
        self.assertEqual((r.key, r.size, r.auto), ("tetris", 700, False))
        self.assertTrue((self.root / "roms" / "Tetris (World).gb").exists())
        data = tomllib.loads((self.root / "manifest.toml").read_text())
        self.assertEqual(data["roms"]["tetris"]["file"], "roms/Tetris (World).gb")
        self.assertEqual(data["carts"]["snouty"]["notes"], "kept on rewrite")
        self.assertEqual(data["sets"]["gear"]["roms"], ["sonic", "sonic2"])
        self.assertEqual(Library(self.root).roms["tetris"].title, "Tetris")

    def test_import_uf2(self):
        c = self.lib.import_uf2(make_uf2(self.tmp / "new.uf2", "xip", 3), "snouty-xip", "Snouty XIP")
        self.assertEqual((c.mode, c.size, c.file.name), ("xip", 3 * 512, "snouty-xip.uf2"))
        data = tomllib.loads((self.root / "manifest.toml").read_text())
        self.assertEqual(data["carts"]["snouty-xip"]["mode"], "xip")
        with self.assertRaises(UF2Error):
            self.lib.import_uf2(make_uf2(self.tmp / "m.uf2", "mixed"), "bad")
        with self.assertRaises(UF2Error):
            self.lib.import_uf2(make_uf2(self.tmp / "r.uf2", "ram"), "r", mode="xip")
        self.assertNotIn("bad", self.lib.carts)

    def test_to_json_shape(self):
        j = self.lib.to_json()
        s = j["sets"][0]
        for k in ("name", "title", "bytes", "entries", "fits", "why"):
            self.assertIn(k, s)
        self.assertEqual({"carts", "roms", "error"}, set(j["library"]))

    def test_bad_manifest(self):
        (self.root / "manifest.toml").write_text("[sets\n")
        self.lib.reload()
        self.assertTrue(self.lib.error.startswith("manifest.toml"))
        self.assertEqual(self.lib.sets, {})


if __name__ == "__main__":
    unittest.main()
