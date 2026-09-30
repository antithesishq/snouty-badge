import unittest

from tests.helpers import ROOT  # noqa: F401  (puts badge-manager/ on sys.path)
from badge_manager import fat12

CL = fat12.SECTOR  # one cluster


class GeometryTest(unittest.TestCase):
    def test_os_geometry(self):
        self.assertEqual(fat12.fat_sectors(2560), 8)
        self.assertEqual(fat12.data_clusters(), 2541)
        g = fat12.geometry()
        self.assertEqual((g.cluster_bytes, g.clusters, g.root_entries), (512, 2541, 32))
        self.assertEqual(g.capacity_bytes, 2541 * 512)

    def test_clusters_for(self):
        self.assertEqual([fat12.clusters_for(n) for n in (0, 1, 512, 513, 1024)], [0, 1, 1, 2, 2])


class NamesTest(unittest.TestCase):
    def test_entry_costs(self):
        self.assertEqual(fat12.root_entries_for("snouty-bugs.uf2"), 3)
        self.assertEqual(fat12.root_entries_for("Sonic The Hedgehog (World).gg"), 4)
        self.assertEqual(fat12.root_entries_for("SONIC.GG"), 1)
        self.assertEqual(fat12.root_entries_for("snouty.uf2"), 2)   # lower case needs an LFN
        self.assertEqual(fat12.root_entries_for("SNOUTY-B.UF2"), 1)

    def test_is_short_name(self):
        for n in ("SONIC.GG", "A", "README", "X~1.TXT", "12345678.123"):
            self.assertTrue(fat12.is_short_name(n), n)
        for n in ("sonic.gg", "123456789.GG", "A.GGGG", ".HIDDEN", "A B.GG", "A.B.C", "É.GG", ""):
            self.assertFalse(fat12.is_short_name(n), n)

    def test_short_name_for(self):
        self.assertEqual(fat12.short_name_for("Sonic The Hedgehog (World).gg", set()), "SONIC.GG")
        self.assertEqual(fat12.short_name_for("Sonic GG.gg", {"sonic.gg"}), "SONIC2.GG")
        self.assertEqual(fat12.short_name_for("Dr. Mario (World).gb", set()), "DRMARIO.GB")
        self.assertEqual(fat12.short_name_for("Tetris [!].gbc", set()), "TETRIS.GBC")
        self.assertEqual(fat12.short_name_for("Supercalifragilistic.md", set()), "SUPERCAL.MD")
        self.assertEqual(fat12.short_name_for("((( ))).gg", set()), "ROM.GG")
        for n in ("SONIC.GG", "SONIC2.GG", "DRMARIO.GB", "SUPERCAL.MD"):
            self.assertTrue(fat12.is_short_name(n))


class FitTest(unittest.TestCase):
    def test_just_fits_by_bytes(self):
        rep = fat12.fit([("A.UF2", 2000 * CL), ("B.UF2", 541 * CL)])
        self.assertTrue(rep.fits, rep.why)
        self.assertEqual(rep.bytes_used, rep.bytes_capacity)
        self.assertEqual(rep.entries_used, 2)

    def test_one_byte_over(self):
        rep = fat12.fit([("A.UF2", 2000 * CL), ("B.UF2", 541 * CL + 1)])
        self.assertFalse(rep.fits)
        self.assertEqual(rep.why, ["1,271 KB needed, 1,270 KB free"])

    def test_cluster_rounding(self):
        rep = fat12.fit([(f"F{i}.BIN", 1) for i in range(10)])
        self.assertEqual(rep.bytes_used, 10 * CL)

    def test_just_fits_by_entries(self):
        files = [(f"snouty-cart-{i:02}.uf2", 10) for i in range(10)] + [("SONIC.GG", 10)]
        rep = fat12.fit(files)   # 10 x 3 + 1 = 31
        self.assertEqual(rep.entries_used, 31)
        self.assertTrue(rep.fits, rep.why)

    def test_too_many_entries(self):
        files = [(f"snouty-cart-{i:02}.uf2", 10) for i in range(10)] + [("SONIC.GG", 10), ("X.GG", 1)]
        rep = fat12.fit(files)
        self.assertFalse(rep.fits)
        self.assertEqual(rep.why, ["32 root entries needed, 31 free"])

    def test_both_reasons_and_duplicates(self):
        rep = fat12.fit([("Sonic The Hedgehog (World).gg", 2 * 1024 * 1024)] * 8)
        self.assertEqual(len(rep.why), 3)
        self.assertTrue(rep.why[0].endswith("1,270 KB free"))
        self.assertEqual(rep.why[1], "32 root entries needed, 31 free")
        self.assertTrue(rep.why[2].startswith("duplicate names"))


if __name__ == "__main__":
    unittest.main()
