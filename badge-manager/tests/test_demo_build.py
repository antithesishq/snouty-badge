"""DemoStation's fake build job (PLAN 9.5): the contract the page is developed against."""
from __future__ import annotations

import shutil
import tempfile
import time
import unittest
from pathlib import Path

from tests import helpers  # noqa: F401  (puts badge-manager/ on sys.path)
from badge_manager.server import BUILD_FILES, DemoBusy, DemoStation

PROMPT = "a Snouty cart where the snout catches falling stars"


class DemoBuildTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="badge-demo-build-"))
        # 0.6 s for the whole script instead of 20
        self.st = DemoStation(library_root=self.tmp / "lib", step=0.01, build_seconds=0.6)

    def tearDown(self):
        self.st.cancel_build()
        self.wait_state(("done", "failed", "cancelled"), allow_none=True)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def wait_state(self, states, timeout=5.0, allow_none=False):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            job = self.st.status()["job"]
            if job is None and allow_none:
                return None
            if job and job["state"] in states:
                return job
            time.sleep(0.02)
        self.fail(f"job never reached {states}: {self.st.status()['job']}")

    def test_build_status_is_ready_remote(self):
        b = self.st.status()["build"]
        self.assertEqual(b, {"local": False, "remote": "exedev@animated-badge.exe.xyz",
                             "ready": True, "why": "", "where": "remote"})
        self.assertIsNone(self.st.status()["job"])
        self.assertEqual(self.st.status()["builds"], [])
        self.assertIsNone(self.st.build_job())

    def test_job_fields_and_log_grows(self):
        jid = self.st.start_build(PROMPT)
        self.assertIsInstance(jid, str)
        self.assertRegex(jid, r"^\d{8}-\d{6}-snout-catches$")
        job = self.st.status()["job"]
        for key, typ in (("id", str), ("prompt", str), ("name", str), ("title", str),
                         ("where", str), ("state", str), ("started", float),
                         ("seconds", float), ("error", str), ("log", list)):
            self.assertIsInstance(job[key], typ, key)
        self.assertEqual(job["id"], jid)
        self.assertEqual(job["name"], "snouty-snout-catches")
        self.assertEqual(job["where"], "remote")
        self.assertIn(job["state"], ("queued", "running"))
        self.assertIsNone(job["exit"])
        self.assertIsNone(job["result"])
        self.wait_state(("running",))
        first = len(self.st.build_job()["log"])
        time.sleep(0.15)
        mid = self.st.build_job()
        self.assertGreater(len(mid["log"]), first)
        self.assertTrue(any(line.startswith("step: ") for line in mid["log"]))
        done = self.wait_state(("done",))
        full = self.st.build_job(jid)["log"]
        self.assertTrue(any(line.startswith("agent: ") for line in full))
        self.assertLessEqual(len(done["log"]), 40)
        self.assertEqual(done["log"], full[-40:])

    def test_done_registers_cart_with_preview(self):
        jid = self.st.start_build(PROMPT)
        job = self.wait_state(("done",))
        self.assertEqual(job["exit"], 0)
        res = job["result"]
        self.assertEqual(set(res), {"cart", "preview", "bench_ms", "size"})
        self.assertEqual(res["cart"], "snouty-snout-catches")
        self.assertEqual(res["preview"], f"/builds/{jid}/preview.gif")
        self.assertAlmostEqual(res["bench_ms"], 9.8)
        self.assertGreater(res["size"], 32 * 1024)
        carts = {c["key"]: c for c in self.st.status()["library"]["carts"]}
        cart = carts["snouty-snout-catches"]
        self.assertEqual(cart["title"], job["title"])
        self.assertEqual(cart["build"], jid)
        self.assertEqual(cart["preview"], res["preview"])
        self.assertIsNone(carts["snouty"]["build"])
        self.assertIsNone(carts["snouty"]["preview"])
        rows = self.st.status()["builds"]
        self.assertEqual([r["id"] for r in rows], [jid])
        self.assertEqual(set(rows[0]), {"id", "name", "title", "state", "started", "seconds",
                                        "preview", "bench_ms", "error"})
        self.assertEqual(rows[0]["preview"], res["preview"])
        # the new cart deploys like any other
        fit = self.st.library.fit_json(self.st.library.selection(["snouty-snout-catches"], []))
        self.assertTrue(fit["fits"])
        self.assertEqual(fit["files"], ["snouty-snout-catches.uf2"])

    def test_build_file_serves_only_allowed_names(self):
        jid = self.st.start_build(PROMPT)
        self.wait_state(("done",))
        for name in BUILD_FILES:
            p = self.st.build_file(jid, name)
            self.assertIsNotNone(p, name)
            self.assertTrue(p.is_file())
        gif = self.st.build_file(jid, "preview.gif").read_bytes()
        self.assertTrue(gif.startswith(b"GIF89a"))
        self.assertTrue(gif.endswith(b"\x3b"))
        self.assertEqual(gif.count(b"\x21\xf9\x04"), 2)            # two frames
        self.assertTrue(self.st.build_file(jid, "preview.png").read_bytes()
                        .startswith(b"\x89PNG\r\n\x1a\n"))
        for name in ("job.json", "job.log", "prompt.txt", "../out/preview.gif",
                     "snouty-snout-catches.uf2", ""):
            self.assertIsNone(self.st.build_file(jid, name), name)
        for bad in ("../lib", "20260101-000000-nope", "", "x/../" + jid):
            self.assertIsNone(self.st.build_file(bad, "preview.gif"), bad)

    def test_cancel_mid_run(self):
        self.assertFalse(self.st.cancel_build())
        jid = self.st.start_build(PROMPT)
        self.wait_state(("running",))
        self.assertTrue(self.st.cancel_build())
        job = self.wait_state(("cancelled",))
        self.assertEqual(job["id"], jid)
        self.assertEqual(job["exit"], 130)
        self.assertIsNone(job["result"])
        self.assertFalse(self.st.cancel_build())
        keys = {c["key"] for c in self.st.status()["library"]["carts"]}
        self.assertNotIn("snouty-snout-catches", keys)
        # a new job starts after a cancel
        self.st.start_build(PROMPT)
        self.assertEqual(self.wait_state(("done",))["state"], "done")
        self.assertEqual([r["state"] for r in self.st.status()["builds"]], ["done", "cancelled"])

    def test_busy_on_double_start(self):
        self.st.start_build(PROMPT)
        with self.assertRaises(DemoBusy):
            self.st.start_build("another one")
        self.wait_state(("done",))
        second = self.st.start_build(PROMPT)             # same prompt: a fresh name
        job = self.wait_state(("done",))
        self.assertEqual(job["id"], second)
        self.assertEqual(job["name"], "snouty-snout-catches-2")

    def test_failed_job(self):
        self.st.start_build("a cart that will fail to build")
        job = self.wait_state(("failed",))
        self.assertEqual(job["exit"], 3)
        self.assertTrue(job["error"])
        self.assertIn("error:", "\n".join(job["log"]))
        self.assertIsNone(job["result"])
        self.assertIsNone(self.st.status()["builds"][0]["preview"])

    def test_bad_input(self):
        for prompt in ("", "   ", "x" * 2001):
            with self.assertRaises(ValueError):
                self.st.start_build(prompt)
        with self.assertRaises(ValueError):
            self.st.start_build(PROMPT, name="Bad Name")
        with self.assertRaises(ValueError):
            self.st.start_build(PROMPT, name="snouty")              # already in the library
        with self.assertRaises(ValueError):
            self.st.start_build(PROMPT, where="local")
        self.assertIsNone(self.st.status()["job"])
        jid = self.st.start_build(PROMPT, where="remote", name="snouty-stars", no_agent=True)
        job = self.wait_state(("done",))
        self.assertEqual(job["name"], "snouty-stars")
        self.assertFalse(any(line.startswith("agent: ") for line in self.st.build_job(jid)["log"]))

    def test_seq_bumps_while_running(self):
        seq = self.st.wait_for_change(-1, 0)
        self.st.start_build(PROMPT)
        self.assertNotEqual(self.st.wait_for_change(seq, 2.0), seq)


if __name__ == "__main__":
    unittest.main()
