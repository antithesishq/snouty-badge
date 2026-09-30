import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from tests.helpers import ROOT, make_uf2, write_config


class CliTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.cfg = write_config(self.tmp)
        self.badge = self.tmp / "badge"
        self.badge.mkdir()

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_cli(self, *args: str, fake: bool = True) -> subprocess.CompletedProcess:
        cmd = [sys.executable, "-m", "badge_manager", "--config", str(self.cfg)]
        if fake:
            cmd += ["--fake-badge", str(self.badge)]
        env = {k: v for k, v in os.environ.items() if not k.startswith("BADGE_STATION")}
        return subprocess.run(cmd + list(args), cwd=ROOT, capture_output=True, text=True,
                              env=env, timeout=60)

    def test_status_json(self):
        r = self.run_cli("status", "--json")
        self.assertEqual(r.returncode, 0, r.stderr)
        s = json.loads(r.stdout)
        self.assertTrue(s["badge"]["present"])
        self.assertEqual({x["name"] for x in s["sets"]}, {"demo", "gear", "broken"})
        self.assertEqual(s["build"]["remote"], "exedev@example")

    def test_status_human(self):
        r = self.run_cli("status")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Badge:   connected", r.stdout)
        self.assertRegex(r.stdout, r"ok\s+demo")
        self.assertRegex(r.stdout, r"NO\s+broken")

    def test_sets_and_library_json(self):
        r = self.run_cli("--json", "sets")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(json.loads(r.stdout)), 3)
        r = self.run_cli("library", "--json")
        self.assertEqual({c["key"] for c in json.loads(r.stdout)["carts"]},
                         {"snouty", "snouty-bugs", "snouty-gear", "genesis-xip"})

    def test_deploy(self):
        (self.badge / "junk.txt").write_text("x")
        r = self.run_cli("deploy", "demo", "--yes")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Demo reel (demo): 2 files", r.stdout)
        self.assertIn("done in", r.stdout)
        self.assertEqual(sorted(os.listdir(self.badge)), ["snouty-bugs.uf2", "snouty.uf2"])
        r = self.run_cli("log", "-n", "3")
        self.assertIn("unplug the badge", r.stdout)

    def test_preconditions(self):
        shutil.rmtree(self.badge)
        r = self.run_cli("deploy", "demo", "--yes")
        self.assertEqual(r.returncode, 2)
        self.assertIn("no badge", r.stderr)
        self.assertEqual(self.run_cli("fit", "broken").returncode, 2)
        self.assertEqual(self.run_cli("fit", "demo").returncode, 0)
        r = self.run_cli("build", "a snouty cart where it rains")
        self.assertEqual(r.returncode, 2)
        self.assertIn("not yet available in M0", r.stderr)
        self.assertEqual(self.run_cli("deploy", "nope", "--yes").returncode, 1)

    def test_add_rom_and_uf2(self):
        rom = self.tmp / "Tetris (World).gb"
        rom.write_bytes(b"t" * 100)
        r = self.run_cli("add-rom", str(rom), "--title", "Tetris")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("drive name TETRIS.GB", r.stdout)
        r = self.run_cli("add-uf2", str(make_uf2(self.tmp / "n.uf2", "xip")), "--key", "new-xip")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("XIP", r.stdout)
        r = self.run_cli("add-uf2", str(make_uf2(self.tmp / "m.uf2", "mixed")), "--key", "bad")
        self.assertEqual(r.returncode, 1)
        self.assertIn("mixed", r.stderr)


if __name__ == "__main__":
    unittest.main()
