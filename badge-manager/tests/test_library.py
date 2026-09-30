import shutil
import tempfile
import tomllib
import unittest
from pathlib import Path

from tests.helpers import ROOT, make_library, make_uf2
from badge_manager.library import CartSet, Library, LibraryError, UF2Error, validate_uf2


class LibraryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.root = make_library(self.tmp / "library")
        self.lib = Library(self.root)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_parse(self):
        self.assertEqual(set(self.lib.sets), {"demo", "gear", "gg", "broken"})
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
        c = self.lib.import_uf2(make_uf2(self.tmp / "new.uf2", "xip", 3), "new-xip", "New XIP")
        self.assertEqual((c.mode, c.size, c.file.name), ("xip", 3 * 512, "new-xip.uf2"))
        data = tomllib.loads((self.root / "manifest.toml").read_text())
        self.assertEqual(data["carts"]["new-xip"]["mode"], "xip")
        # <family>-xip for an existing family becomes its XIP variant, not a second cart
        c = self.lib.import_uf2(make_uf2(self.tmp / "sx.uf2", "xip", 5), "snouty-xip", "Snouty XIP")
        self.assertEqual((c.key, c.title, c.variants["xip"].size), ("snouty", "Snouty Run", 5 * 512))
        self.assertNotIn("snouty-xip", self.lib.carts)
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

    # -- M1: variants ---------------------------------------------------------

    def test_variants_fold_and_use(self):
        c = self.lib.carts["snouty"]
        self.assertEqual(set(c.variants), {"ram", "xip"})
        self.assertEqual((c.use, c.mode, c.file.name, c.size), ("ram", "ram", "snouty.uf2", 6 * 512))
        self.assertNotIn("snouty-xip", self.lib.carts)
        self.assertEqual(self.lib.fit("demo").bytes_used, (6 + 3) * 512)
        c = self.lib.set_cart_mode("snouty", "xip")
        self.assertEqual((c.use, c.mode, c.file.name, c.size), ("xip", "xip", "snouty-xip.uf2", 4 * 512))
        self.assertEqual(self.lib.fit("demo").bytes_used, (4 + 3) * 512)
        self.assertEqual([p.name for p in self.lib.plan("demo")], ["snouty-xip.uf2", "snouty-bugs.uf2"])
        data = tomllib.loads((self.root / "manifest.toml").read_text())
        self.assertEqual(data["carts"]["snouty"]["use"], "xip")
        self.assertEqual(data["carts"]["snouty"]["notes"], "kept on rewrite")
        self.assertEqual(Library(self.root).carts["snouty"].use, "xip")
        with self.assertRaisesRegex(LibraryError, "no RAM variant"):
            self.lib.set_cart_mode("genesis-xip", "ram")
        with self.assertRaises(LibraryError):
            self.lib.set_cart_mode("nope", "ram")
        j = {c["key"]: c for c in self.lib.to_json()["library"]["carts"]}
        self.assertEqual(j["snouty"]["use"], "xip")
        self.assertEqual(j["snouty"]["variants"]["xip"],
                         {"file": "snouty-xip.uf2", "size": 4 * 512, "ok": True, "error": ""})
        self.assertEqual(set(j["genesis-xip"]["variants"]), {"xip"})

    def test_xip_only_family_and_auto_fold(self):
        make_uf2(self.root / "carts" / "snouty-genesis-xip.uf2", "xip", 2)
        make_uf2(self.root / "carts" / "snouty-maze.uf2", "ram", 2)
        make_uf2(self.root / "carts" / "snouty-maze-xip.uf2", "xip", 3)
        self.lib.reload()
        g = self.lib.carts["snouty-genesis"]
        self.assertEqual((set(g.variants), g.use, g.error, g.auto), ({"xip"}, "xip", "", True))
        m = self.lib.carts["snouty-maze"]
        self.assertEqual((set(m.variants), m.use), ({"ram", "xip"}, "ram"))
        self.assertNotIn("snouty-maze-xip", self.lib.carts)
        self.assertNotIn("snouty-genesis-xip", self.lib.carts)
        m = self.lib.set_cart_mode("snouty-maze", "xip")       # an auto cart gets a table
        self.assertEqual((m.use, m.auto, m.title), ("xip", False, "snouty-maze"))

    def test_ram_uf2_in_xip_slot(self):
        make_uf2(self.root / "carts" / "snouty-xip.uf2", "ram", 2)
        self.lib.reload()
        c = self.lib.carts["snouty"]
        self.assertEqual(c.error, "")                          # RAM still in use and fine
        self.assertIn("RAM cart, not XIP", c.variants["xip"].error)
        c = self.lib.set_cart_mode("snouty", "xip")
        self.assertIn("RAM cart, not XIP", c.error)
        self.assertFalse(self.lib.fit("demo").fits)

    def test_family_without_variants_listed(self):
        text = (self.root / "manifest.toml").read_text() + '\n[carts.ghost]\ntitle = "Ghost"\n'
        (self.root / "manifest.toml").write_text(text)
        self.lib.reload()
        self.assertEqual(self.lib.carts["ghost"].error, "ghost.uf2 is missing from the library")

    # -- M1: patterns, selections, saved sets ------------------------------------

    def test_rom_patterns(self):
        # library order (by title): "Sonic 2" before "Sonic GG"; drive names are per ROM
        self.assertEqual([(p.name, p.title) for p in self.lib.plan("gg")],
                         [("snouty-gear.uf2", "Snouty Gear"), ("SONIC2.GG", "Sonic 2"),
                          ("SONIC.GG", "Sonic GG")])
        roms = {r["key"]: r["short"] for r in self.lib.to_json()["library"]["roms"]}
        self.assertEqual(roms, {"sonic": "SONIC.GG", "sonic2": "SONIC2.GG"})
        (self.root / "roms" / "Tetris (World).gb").write_bytes(b"x" * 10)
        self.lib.reload()
        for roms in (["*.GG"], [".gg"], ["sonic", ".gg"], ["Sonic*", "*.gg"]):
            names = [p.name for p in self.lib.plan(self.lib.selection([], roms))]
            self.assertEqual(sorted(names), ["SONIC.GG", "SONIC2.GG"], roms)
        self.assertEqual([p.name for p in self.lib.plan(self.lib.selection(["snouty"], ["*.nes"]))],
                         ["snouty.uf2"])
        rep = self.lib.fit(self.lib.selection([], ["*.nes"]))
        self.assertEqual(rep.why, ["nothing to deploy"])

    def test_adhoc_selection(self):
        sel = self.lib.selection(["snouty", "snouty", "snouty-gear"], ["sonic"])
        self.assertEqual((sel.key, sel.title, sel.carts, sel.roms),
                         ("custom", "Selection", ["snouty", "snouty-gear"], ["sonic"]))
        self.assertEqual([p.name for p in self.lib.plan(sel)], ["snouty.uf2", "snouty-gear.uf2", "SONIC.GG"])
        j = self.lib.fit_json(sel)
        self.assertEqual(set(j), {"bytes", "entries", "bytes_capacity", "entries_capacity",
                                  "fits", "why", "files"})
        self.assertEqual((j["bytes"], j["files"], j["fits"]),
                         ((6 + 5) * 512 + 3072, ["snouty.uf2", "snouty-gear.uf2", "SONIC.GG"], True))
        j = self.lib.fit_json(self.lib.selection(["nope"], []))
        self.assertEqual((j["fits"], j["why"]), (False, ["cart 'nope' is not in the library"]))
        with self.assertRaises(LibraryError):
            self.lib.selection("snouty", [])
        with self.assertRaises(LibraryError):
            self.lib.selection([1], [])

    def test_save_and_delete_set(self):
        s = self.lib.save_set("Game Gear!", ["snouty-gear", "snouty-bugs"], ["*.gg"])
        self.assertEqual((s.key, s.title), ("game-gear", "Game Gear!"))
        lib = Library(self.root)
        self.assertEqual((lib.sets["game-gear"].carts, lib.sets["game-gear"].roms),
                         (["snouty-gear", "snouty-bugs"], ["*.gg"]))
        data = tomllib.loads((self.root / "manifest.toml").read_text())
        self.assertEqual(data["carts"]["snouty"]["notes"], "kept on rewrite")
        self.assertEqual(data["sets"]["gear"]["roms"], ["sonic", "sonic2"])
        s = self.lib.save_set("Demo two", ["snouty"], [], key="demo")    # replace
        self.assertEqual(self.lib.sets["demo"].title, "Demo two")
        j = {x["name"]: x for x in self.lib.to_json()["sets"]}
        self.assertEqual(j["game-gear"]["roms"], ["*.gg"])
        self.assertEqual(j["game-gear"]["files"], ["snouty-gear.uf2", "snouty-bugs.uf2",
                                                   "SONIC2.GG", "SONIC.GG"])
        for args in (("", ["snouty"], []), ("X", [], []), ("X", ["nope"], []),
                     ("X", [], ["nope"])):
            with self.assertRaises(LibraryError):
                self.lib.save_set(*args)
        self.lib.delete_set("game-gear")
        self.assertNotIn("game-gear", Library(self.root).sets)
        with self.assertRaises(LibraryError):
            self.lib.delete_set("game-gear")

    def test_identify(self):
        files = [{"name": "snouty-gear.uf2", "size": 1}, {"name": "SONIC.GG", "size": 1},
                 {"name": "sonic2.gg", "size": 1}, {"name": ".fseventsd", "size": 0},
                 {"name": "System Volume Information", "size": 0}]
        out, on = self.lib.identify(files)
        self.assertEqual(on, "gear")               # gg has the same names; manifest order wins
        self.assertEqual([(f["title"], f["kind"]) for f in out[:3]],
                         [("Snouty Gear", "cart"), ("Sonic GG", "rom"), ("Sonic 2", "rom")])
        self.assertEqual(out[3]["kind"], "other")
        out, on = self.lib.identify(files[:2])
        self.assertIsNone(on)
        out, on = self.lib.identify([{"name": "SNOUTY.UF2", "size": 1}, {"name": "snouty-bugs.uf2", "size": 1}])
        self.assertEqual(on, "demo")
        self.lib.set_cart_mode("snouty", "xip")
        out, on = self.lib.identify([{"name": "snouty-xip.uf2", "size": 1}, {"name": "junk.txt", "size": 1}])
        self.assertEqual((out[0]["title"], out[1]["title"], out[1]["kind"], on),
                         ("Snouty Run", "junk.txt", "other", None))
        self.assertEqual(self.lib.identify([]), ([], None))
        self.lib.delete_set("gear")                # now only gg, same drive names
        out, on = self.lib.identify(files[:3])
        self.assertEqual((on, out[1]["title"], out[2]["title"]), ("gg", "Sonic GG", "Sonic 2"))

    def test_init_defaults(self):
        defaults = ROOT / "sets.default.toml"
        before = (self.root / "manifest.toml").read_text()
        added = self.lib.init_defaults(defaults)
        self.assertIn("sets.boy", added)
        self.assertIn("carts.snoutenstein", added)
        self.assertNotIn("sets.gear", added)          # exists, left alone
        self.assertNotIn("carts.snouty", added)
        self.assertEqual(self.lib.sets["gear"].title, "Game Gear Sonic")
        self.assertEqual(self.lib.carts["snouty"].title, "Snouty Run")
        data = tomllib.loads((self.root / "manifest.toml").read_text())
        self.assertEqual(data["carts"]["snouty"]["notes"], "kept on rewrite")
        self.assertEqual(self.lib.init_defaults(defaults), [])
        self.assertNotEqual(before, (self.root / "manifest.toml").read_text())
        # a fresh library: every default, and no file/mode pins
        fresh = Library(self.tmp / "fresh")
        added = fresh.init_defaults(defaults)
        self.assertEqual(set(fresh.sets), {"demo", "gear", "boy", "genesis"})
        raw = tomllib.loads(defaults.read_text())
        for t in raw["carts"].values():
            self.assertLessEqual(set(t), {"title", "roms", "use"})
        self.assertEqual(len(added), len(raw["carts"]) + len(raw["sets"]))
        # a cart that sync auto-registered (title = key) gets the default title and roms,
        # a cart with a real title keeps it
        (self.root / "manifest.toml").write_text(
            '[carts.snouty-gear]\ntitle = "snouty-gear"\n[carts.snouty]\ntitle = "My Snouty"\n')
        self.lib.reload()
        added = self.lib.init_defaults(defaults)
        self.assertIn("carts.snouty-gear.title.roms", added)
        self.assertEqual(self.lib.carts["snouty-gear"].title, "Snouty Gear")
        self.assertEqual(self.lib.carts["snouty-gear"].roms, [".gg", ".sms"])
        self.assertEqual(self.lib.carts["snouty"].title, "My Snouty")
        self.assertEqual(self.lib.init_defaults(defaults), [])

    def test_bad_manifest(self):
        (self.root / "manifest.toml").write_text("[sets\n")
        self.lib.reload()
        self.assertTrue(self.lib.error.startswith("manifest.toml"))
        self.assertEqual(self.lib.sets, {})


if __name__ == "__main__":
    unittest.main()
