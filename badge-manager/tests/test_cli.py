import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from tests.helpers import ROOT, make_uf2, write_config


class CliCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.cfg = write_config(self.tmp)
        self.badge = self.tmp / "badge"
        self.badge.mkdir()

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def cli_env(self, path: str | None = None, extra: dict | None = None) -> dict:
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("BADGE_STATION", "FAKE_BUILD"))}
        if path is not None:
            env["PATH"] = path
        return {**env, **(extra or {})}

    def cli_cmd(self, *args: str, fake: bool = True) -> list[str]:
        cmd = [sys.executable, "-m", "badge_manager", "--config", str(self.cfg)]
        if fake:
            cmd += ["--fake-badge", str(self.badge)]
        return cmd + list(args)

    def run_cli(self, *args: str, fake: bool = True, path: str | None = None,
                env: dict | None = None) -> subprocess.CompletedProcess:
        return subprocess.run(self.cli_cmd(*args, fake=fake), cwd=ROOT, capture_output=True,
                              text=True, env=self.cli_env(path, env), timeout=60)


class CliTest(CliCase):
    def test_status_json(self):
        r = self.run_cli("status", "--json")
        self.assertEqual(r.returncode, 0, r.stderr)
        s = json.loads(r.stdout)
        self.assertTrue(s["badge"]["present"])
        self.assertEqual({x["name"] for x in s["sets"]}, {"demo", "gear", "gg", "broken"})
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
        self.assertEqual(len(json.loads(r.stdout)), 4)
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

    def test_noninteractive_destructive_commands_require_yes(self):
        (self.badge / "keep.txt").write_text("keep")
        for args in (("deploy", "demo"), ("wipe",)):
            r = self.run_cli(*args)
            self.assertEqual(r.returncode, 1)
            self.assertIn("requires --yes", r.stderr)
            self.assertEqual((self.badge / "keep.txt").read_text(), "keep")

    def test_preconditions(self):
        shutil.rmtree(self.badge)
        r = self.run_cli("deploy", "demo", "--yes")
        self.assertEqual(r.returncode, 2)
        self.assertIn("no badge", r.stderr)
        self.assertEqual(self.run_cli("fit", "broken").returncode, 2)
        self.assertEqual(self.run_cli("fit", "demo").returncode, 0)
        r = self.run_cli("build")
        self.assertEqual(r.returncode, 1)
        self.assertIn("usage: badge build", r.stderr)
        self.assertEqual(self.run_cli("deploy", "nope", "--yes").returncode, 1)

    def test_status_on_it(self):
        self.assertEqual(self.run_cli("deploy", "demo", "--yes").returncode, 0)
        r = self.run_cli("status")
        self.assertRegex(r.stdout, r"on it: Demo reel \((snouty|snouty-bugs)\.uf2, snouty")
        (self.badge / "notes.txt").write_text("x")
        r = self.run_cli("status")
        line = next(x for x in r.stdout.splitlines() if "on it:" in x)
        self.assertEqual(sorted(line.split("on it: ")[1].split(", ")),
                         ["Snouty Bughunt", "Snouty Run", "notes.txt"])

    def test_library_variants(self):
        r = self.run_cli("library")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertRegex(r.stdout, r"snouty\s+ram\*\s+xip\s+3 KB\s+Snouty Run")
        self.assertRegex(r.stdout, r"genesis-xip\s+xip\*\s+1 KB")

    def test_mode(self):
        r = self.run_cli("mode", "snouty", "xip")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("snouty now deploys as XIP", r.stdout)
        r = self.run_cli("library", "--json")
        carts = {c["key"]: c for c in json.loads(r.stdout)["carts"]}
        self.assertEqual((carts["snouty"]["use"], carts["snouty"]["file"]), ("xip", "snouty-xip.uf2"))
        r = self.run_cli("mode", "snouty-bugs", "xip")
        self.assertEqual(r.returncode, 1)
        self.assertIn("no XIP variant", r.stderr)
        r = self.run_cli("mode", "--all", "ram")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("snouty now deploys as RAM", r.stdout)
        self.assertIn("genesis-xip: no RAM variant, left as XIP", r.stdout)
        self.assertEqual(self.run_cli("mode", "snouty").returncode, 1)
        self.assertIn("snouty now deploys as RAM", self.run_cli("log").stdout)

    def test_set_save_rm(self):
        r = self.run_cli("set", "save", "gb", "--title", "Game Boy", "--carts", "snouty,snouty-bugs",
                         "--roms", "*.gb,*.gbc")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("saved set Game Boy (gb): 2 carts, *.gb, *.gbc", r.stdout)
        sets = {x["name"]: x for x in json.loads(self.run_cli("sets", "--json").stdout)}
        self.assertEqual((sets["gb"]["roms"], sets["gb"]["files"]),
                         (["*.gb", "*.gbc"], ["snouty.uf2", "snouty-bugs.uf2"]))
        self.assertEqual(self.run_cli("set", "save", "x", "--carts", "nope").returncode, 1)
        r = self.run_cli("set", "rm", "gb")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("removed set gb", r.stdout)
        self.assertEqual(self.run_cli("set", "rm", "gb").returncode, 1)

    def test_deploy_carts(self):
        r = self.run_cli("deploy", "--carts", "snouty-gear", "--roms", ".gg", "--yes")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Selection (custom): 3 files", r.stdout)
        self.assertEqual(sorted(os.listdir(self.badge)), ["SONIC.GG", "SONIC2.GG", "snouty-gear.uf2"])
        self.assertEqual(self.run_cli("deploy", "demo", "--carts", "snouty", "--yes").returncode, 1)
        self.assertEqual(self.run_cli("deploy", "--yes").returncode, 1)
        self.assertEqual(self.run_cli("fit", "--carts", "snouty,missing").returncode, 2)

    def test_init_sets(self):
        r = self.run_cli("init-sets")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("sets.boy", r.stdout)
        self.assertNotIn("sets.gear", r.stdout)
        r = self.run_cli("init-sets")
        self.assertIn("nothing to add", r.stdout)
        names = {x["name"] for x in json.loads(self.run_cli("sets", "--json").stdout)}
        self.assertEqual(names, {"demo", "gear", "gg", "broken", "boy", "genesis"})

    def test_qr_without_qrencode(self):
        r = self.run_cli("qr", path="/nonexistent")
        self.assertEqual(r.returncode, 2)
        self.assertIn("qrencode", r.stderr)

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
        r = self.run_cli("add-uf2", str(make_uf2(self.tmp / "b.uf2")), "--key", "built",
                         "--build", "20260930-120000-built")
        self.assertEqual(r.returncode, 0, r.stderr)
        cart = next(c for c in json.loads(self.run_cli("library", "--json").stdout)["carts"]
                    if c["key"] == "built")
        self.assertEqual(cart["build"], "20260930-120000-built")


class CliBuildTest(CliCase):
    """badge build / builds against tests/fake_build_job.sh (build_command)."""

    def setUp(self):
        super().setUp()
        from tests.test_build import FAKE_COMMAND
        with open(self.cfg, "a") as fh:
            fh.write(f"build_command = {json.dumps(FAKE_COMMAND)}\n")

    def test_build_builds_status_log(self):
        self.assertIn("no builds yet", self.run_cli("builds").stdout)
        self.assertIn("no builds yet", self.run_cli("build", "--status").stdout)
        shutil.rmtree(self.badge)                       # build never needs the badge
        r = self.run_cli("build", "a cart where it rains", "--no-agent")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("step: template builds (0 s)", r.stdout)
        self.assertNotIn("agent:", r.stdout)
        self.assertRegex(r.stdout, r"done: Fake Rains, 4 KB, 4\.2 ms")
        self.assertRegex(r.stdout, r"Fake Rains is in the library as snouty-rains "
                                   r"\(build \d{8}-\d{6}-rains\)")
        job_id = r.stdout.strip().rsplit("(build ", 1)[1].rstrip(")")
        cart = next(c for c in json.loads(self.run_cli("library", "--json").stdout)["carts"]
                    if c["key"] == "snouty-rains")
        self.assertEqual((cart["build"], cart["title"]), (job_id, "Fake Rains"))
        r = self.run_cli("builds")
        self.assertRegex(r.stdout, rf"{job_id}\s+done\s+\d+ s  Fake Rains")
        rows = json.loads(self.run_cli("builds", "--json").stdout)
        self.assertEqual([x["id"] for x in rows], [job_id])
        r = self.run_cli("build", "--status")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(f"Build:   {job_id} (done", r.stdout)
        self.assertIn("Cart:    snouty-rains, Fake Rains", r.stdout)
        st = json.loads(self.run_cli("build", "--status", "--json").stdout)
        self.assertEqual((st["job"]["id"], st["build"]["ready"]), (job_id, True))
        r = self.run_cli("build", "--log")
        self.assertEqual(r.stdout.splitlines()[0], "build snouty-rains on the station")
        self.assertEqual(self.run_cli("build", "--log", job_id).stdout, r.stdout)
        r = self.run_cli("build", "--log", "20990101-000000-nope")
        self.assertEqual(r.returncode, 1)
        r = self.run_cli("build", "--cancel")
        self.assertEqual(r.returncode, 2)
        self.assertIn("no build is running", r.stderr)
        self.assertIn(f"build snouty-rains done", self.run_cli("log").stdout)

    def test_build_failure_and_bad_name(self):
        r = self.run_cli("build", "rain", env={"FAKE_BUILD_FAIL": "3"})
        self.assertEqual(r.returncode, 1)
        self.assertIn("failed: the cart does not build", r.stdout)
        r = self.run_cli("build", "rain", "--name", "a b")
        self.assertEqual(r.returncode, 1)
        self.assertIn("bad cart name", r.stderr)

    def test_busy_and_cancel_a_queued_job(self):
        from badge_manager import config as config_mod
        from badge_manager.build import Jobs
        cfg = config_mod.load(self.cfg)
        jobs = Jobs(cfg.library, cfg)
        job = jobs.create("rain", "local")              # holds the build lock
        try:
            r = self.run_cli("build", "snow")
            self.assertEqual(r.returncode, 2)
            self.assertIn("a build is running", r.stderr)
            r = self.run_cli("build", "--cancel")
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertTrue((jobs.dir(job.id) / "cancel").exists())
        finally:
            jobs.run(job)
        self.assertEqual(jobs.get(job.id).state, "cancelled")

    def test_ctrl_c_cancels(self):
        p = subprocess.Popen(self.cli_cmd("build", "rain"), cwd=ROOT, text=True,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             env=self.cli_env(extra={"FAKE_BUILD_SLOW": "30"}))
        try:
            for line in p.stdout:
                if "thinking" in line:
                    break
            p.send_signal(signal.SIGINT)
            out, err = p.communicate(timeout=20)
        finally:
            p.kill()
        self.assertEqual(p.returncode, 1, err)
        self.assertIn("cancelling the build", err)
        self.assertRegex(out, r"cancelled after \d+ s")


if __name__ == "__main__":
    unittest.main()
