"""build.py (PLAN.md 9.2) against tests/fake_build_job.sh, and the Station build glue."""
import json
import os
import shlex
import shutil
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

from tests.helpers import ROOT, make_config
from badge_manager import build as build_mod
from badge_manager.build import BuildBusy, BuildError, Jobs, cart_name
from badge_manager.library import Library
from badge_manager.station import BuildNotReady, Station, StationBusy, StationError

FAKE = ROOT / "tests" / "fake_build_job.sh"
FAKE_COMMAND = (f"bash {shlex.quote(str(FAKE))} --id {{id}} --out {{out}} "
                "--prompt-file {prompt_file} {flags}")
NO_NET = {"mode": "none", "ssid": None, "address": None, "internet": False}


def fake_config(tmp: Path, **kw):
    cfg = make_config(tmp, None)
    cfg.build_command = FAKE_COMMAND
    for k, v in kw.items():
        setattr(cfg, k, v)
    return cfg


def wait_for(pred, timeout: float = 10.0) -> None:
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if pred():
            return
        time.sleep(0.02)
    raise AssertionError("timed out waiting")


class Env(unittest.TestCase):
    """A temporary library and a clean FAKE_BUILD_* environment."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        env = {k: v for k, v in os.environ.items() if not k.startswith("FAKE_BUILD")}
        p = mock.patch.dict(os.environ, env, clear=True)
        p.start()
        self.addCleanup(p.stop)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


class NameTest(unittest.TestCase):
    def test_from_prompt(self):
        self.assertEqual(cart_name("a Snouty cart where it rains frogs"), "snouty-rains-frogs")
        self.assertEqual(cart_name("A cart where the moon is made of cheese"),
                         "snouty-moon-made")
        self.assertEqual(cart_name("!!!"), "snouty-cart")
        self.assertEqual(cart_name("the cart"), "snouty-cart")
        long = cart_name("supercalifragilisticexpialidocious everywhere")
        self.assertRegex(long, build_mod.NAME_RE)
        self.assertLessEqual(len(long), 24)

    def test_avoids_taken(self):
        taken = {"snouty-maze", "snouty-maze-2"}
        self.assertEqual(cart_name("maze", taken=taken), "snouty-maze-3")

    def test_explicit(self):
        self.assertEqual(cart_name("x", "rain"), "snouty-rain")
        self.assertEqual(cart_name("x", "Snouty-Rain"), "snouty-rain")
        self.assertEqual(cart_name("x", "snouty-maze", taken={"snouty-maze"}), "snouty-maze")
        self.assertEqual(cart_name("x", "9lives"), "snouty-9lives")
        for bad in ("a b", "Rain!", "x" * 30, "snouty-", "rain-", "ra--in", "../etc"):
            with self.assertRaises(BuildError, msg=bad):
                cart_name("x", bad)


class JobsTest(Env):
    def jobs(self, **kw) -> Jobs:
        self.cfg = fake_config(self.tmp, **kw)
        self.changes = 0

        def bump():
            self.changes += 1
        return Jobs(self.cfg.library, self.cfg, on_change=bump)

    def test_lifecycle(self):
        jobs = self.jobs()
        lines = []
        job = jobs.start("a snouty cart where it rains", "local", on_line=lines.append)
        self.assertEqual(job.state, "done", jobs.log(job.id))
        self.assertRegex(job.id, r"^\d{8}-\d{6}-rains$")
        self.assertEqual(job.name, "snouty-rains")
        d = jobs.dir(job.id)
        data = json.loads((d / "job.json").read_text())
        self.assertLessEqual({"id", "prompt", "name", "title", "where", "host", "state",
                              "started", "finished", "seconds", "exit", "error", "result"},
                             set(data))
        self.assertEqual((data["state"], data["exit"], data["error"], data["where"]),
                         ("done", 0, None, "local"))
        self.assertEqual(data["title"], "Fake Rains")
        self.assertEqual(data["result"]["cart"], "snouty-rains")
        self.assertEqual(data["result"]["uf2"], "carts/snouty-rains.uf2")
        self.assertEqual(data["result"]["preview"], f"/builds/{job.id}/preview.gif")
        self.assertEqual(data["result"]["bench_ms"], 4.2)
        self.assertEqual(data["result"]["branch"], f"build/{job.id}")
        self.assertEqual((d / "prompt.txt").read_text(), "a snouty cart where it rains\n")
        log = jobs.log(job.id)
        self.assertEqual(log[0], "build snouty-rains on the station")
        self.assertIn("step: template builds (0 s)", log)
        self.assertTrue(any(x.startswith("agent: ") for x in log))
        self.assertRegex(log[-1], r"^done: Fake Rains, 4 KB, 4\.2 ms, in \d+ s$")
        self.assertEqual(lines, log)
        self.assertGreaterEqual(self.changes, len(log))
        # registered in the library with its build and preview
        lib = Library(self.cfg.library)
        c = lib.carts["snouty-rains"]
        self.assertEqual((c.title, c.build, c.error), ("Fake Rains", job.id, ""))
        cart = next(x for x in lib.to_json()["library"]["carts"] if x["key"] == "snouty-rains")
        self.assertEqual(cart["preview"], f"/builds/{job.id}/preview.gif")
        self.assertIsNone(jobs.current())
        self.assertEqual([j.id for j in jobs.list()], [job.id])
        self.assertFalse(jobs.locked())

    def test_no_agent_and_prompt_by_file(self):
        jobs = self.jobs()
        job = jobs.start("rain", "local", name="drops", no_agent=True)
        self.assertEqual((job.state, job.name), ("done", "snouty-drops"))
        self.assertFalse(any(x.startswith("agent:") for x in jobs.log(job.id)))

    def test_one_at_a_time(self):
        jobs = self.jobs()
        job = jobs.create("rain", "local")
        self.assertTrue(jobs.locked())
        self.assertEqual(jobs.current().id, job.id)
        with self.assertRaises(BuildBusy):
            jobs.create("snow", "local")
        with self.assertRaises(BuildBusy):     # another process's view: same lock file
            Jobs(self.cfg.library, self.cfg).create("snow", "local")
        jobs.run(job)
        self.assertFalse(jobs.locked())
        self.assertEqual(jobs.start("snow", "local").state, "done")

    def test_bad_requests(self):
        jobs = self.jobs()
        for prompt in ("", "   ", "x" * 2001):
            with self.assertRaises(BuildError):
                jobs.create(prompt, "local")
        with self.assertRaises(BuildError):
            jobs.create("rain", "moon")
        with self.assertRaises(BuildError):
            jobs.create("rain", "local", name="a b")
        self.assertFalse(jobs.locked())
        self.assertEqual(jobs.ids(), [])

    def test_failure_exit_codes(self):
        jobs = self.jobs()
        for code, text in ((3, "the cart does not build"),
                           (4, "the agent failed or ran out of turns or budget"),
                           (2, "bad request or cart name"), (9, "the build failed (exit 9)")):
            with mock.patch.dict(os.environ, {"FAKE_BUILD_FAIL": str(code)}):
                job = jobs.start(f"rain {code}", "local")
            self.assertEqual((job.state, job.exit, job.error), ("failed", code, text))
            self.assertEqual(jobs.log(job.id)[-1], f"failed: {text}")
            self.assertIn("error: fake failure", jobs.log(job.id))
        self.assertEqual(Library(self.cfg.library).carts.get("snouty-rain-3"), None)

    def test_missing_script(self):
        jobs = self.jobs(build_command="bash /nonexistent/build-job.sh {flags}")
        job = jobs.start("rain", "local")
        self.assertEqual((job.state, job.exit), ("failed", 127))

    def test_wall_clock(self):
        jobs = self.jobs(build_max_minutes=0.01)          # 0.6 s
        with mock.patch.dict(os.environ, {"FAKE_BUILD_SLOW": "30"}):
            t0 = time.monotonic()
            job = jobs.start("rain", "local")
        self.assertLess(time.monotonic() - t0, 10)
        self.assertEqual((job.state, job.exit), ("failed", 124))
        self.assertEqual(job.error, "stopped after 0.01 minutes")

    def test_cancel(self):
        jobs = self.jobs()
        self.assertFalse(jobs.cancel())
        with mock.patch.dict(os.environ, {"FAKE_BUILD_SLOW": "30"}):
            job = jobs.create("rain", "local")
            t = threading.Thread(target=jobs.run, args=(job,))
            t.start()
            wait_for(lambda: any("thinking" in x for x in jobs.log(job.id)))
            self.assertEqual(jobs.get(job.id).state, "running")
            self.assertTrue(jobs.get(job.id).pid)
            t0 = time.monotonic()
            self.assertTrue(jobs.cancel())
            t.join(10)
        self.assertLess(time.monotonic() - t0, 8)
        got = jobs.get(job.id)
        self.assertEqual((got.state, got.exit, got.error, got.pid),
                         ("cancelled", 130, "cancelled", None))
        self.assertRegex(jobs.log(job.id)[-1], r"^cancelled after \d+ s$")
        self.assertFalse(jobs.cancel())

    def test_cancel_from_another_process(self):
        jobs = self.jobs()
        with mock.patch.dict(os.environ, {"FAKE_BUILD_SLOW": "30"}):
            job = jobs.create("rain", "local")
            t = threading.Thread(target=jobs.run, args=(job,))
            t.start()
            wait_for(lambda: any("thinking" in x for x in jobs.log(job.id)))
            other = Jobs(self.cfg.library, self.cfg)        # no Popen handle: pid + marker
            self.assertTrue(other.cancel())
            t.join(10)
        self.assertEqual(jobs.get(job.id).state, "cancelled")

    def test_uf2_gate(self):
        jobs = self.jobs()
        with mock.patch.dict(os.environ, {"FAKE_BUILD_BAD_UF2": "1"}):
            job = jobs.start("rain", "local")
        self.assertEqual((job.state, job.exit), ("failed", 0))
        self.assertIn("snouty-rain.uf2 failed the UF2 check", job.error)
        self.assertNotIn("snouty-rain", Library(self.cfg.library).carts)
        # without tools/uf2_info.py the library's own check still refuses it
        with mock.patch.object(build_mod, "UF2_INFO", self.tmp / "missing.py"), \
                mock.patch.dict(os.environ, {"FAKE_BUILD_BAD_UF2": "1"}):
            job = jobs.start("rain", "local")
        self.assertEqual(job.state, "failed")
        self.assertIn("could not add the cart to the library", job.error)

    def test_missing_uf2_and_summary(self):
        jobs = self.jobs(build_command="true {flags}")
        job = jobs.start("rain", "local")
        self.assertEqual((job.state, job.error), ("failed", "the build made no snouty-rain.uf2"))

    def test_stale_job(self):
        jobs = self.jobs()
        job = jobs.create("rain", "local")
        jobs._release(job.id)                  # the process died without finishing
        got = jobs.get(job.id)
        self.assertEqual((got.state, got.error),
                         ("failed", "the station stopped during this build"))
        self.assertIsNone(jobs.current())

    def test_file(self):
        jobs = self.jobs()
        job = jobs.start("rain", "local")
        self.assertEqual(jobs.file(job.id, "preview.gif").read_bytes()[:6], b"GIF89a")
        self.assertIsNotNone(jobs.file(job.id, "bench.txt"))
        self.assertIsNotNone(jobs.file(job.id, "summary.json"))
        self.assertIsNone(jobs.file(job.id, "preview.png"))           # not made
        self.assertIsNone(jobs.file(job.id, "snouty-rain.uf2"))       # not served
        self.assertIsNone(jobs.file(job.id, "../job.json"))
        self.assertIsNone(jobs.file("..", "preview.gif"))
        self.assertIsNone(jobs.file(f"{job.id}/../{job.id}", "preview.gif"))
        self.assertIsNone(jobs.file("../../etc", "passwd"))


class CommandTest(Env):
    def setUp(self):
        super().setUp()
        self.cfg = make_config(self.tmp, None)
        self.cfg.build_host, self.cfg.build_repo = "exedev@vm.example", "/home/exedev/repo"
        self.jobs = Jobs(self.cfg.library, self.cfg)
        p = mock.patch.object(build_mod, "SSH_KEY", self.tmp / "no-key")
        p.start()
        self.addCleanup(p.stop)

    def tearDown(self):
        for i in self.jobs.ids():
            self.jobs._release(i)
        super().tearDown()

    def test_flags(self):
        job = self.jobs.create("rain", "local", name="rain", no_agent=True)
        self.assertEqual(self.jobs.flags(job), ["--name", "snouty-rain", "--no-agent",
                                                "--max-turns", "40", "--max-usd", "5",
                                                "--minutes", "19"])

    def test_local(self):
        job = self.jobs.create("it's raining", "local")
        d = self.jobs.dir(job.id)
        [cmd] = self.jobs.commands(job)
        self.assertEqual(cmd, f"bash /home/exedev/repo/badge-manager/build-job.sh --id {job.id} "
                              f"--out {d}/out --prompt-file {d}/prompt.txt --name snouty-raining "
                              "--max-turns 40 --max-usd 5 --minutes 19")
        self.assertNotIn("raining'", cmd.split("--name")[0])     # the prompt is never in argv
        self.assertIsNone(self.jobs.cancel_command(job))

    def test_remote(self):
        job = self.jobs.create("rain; rm -rf /", "remote", name="rain")
        self.assertEqual(job.host, "exedev@vm.example")
        d = self.jobs.dir(job.id)
        run, fetch, clean = self.jobs.commands(job)
        work = f"/home/exedev/repo/build-jobs/{job.id}"
        ssh = "ssh -o BatchMode=yes -o ConnectTimeout=15 exedev@vm.example"
        self.assertEqual(run, f"{ssh} 'bash /home/exedev/repo/badge-manager/build-job.sh "
                              f"--id {job.id} --out {work}/out --prompt-file - "
                              "--name snouty-rain --max-turns 40 --max-usd 5 --minutes 19' "
                              f"< {d}/prompt.txt")
        self.assertNotIn("rm -rf /", run)
        self.assertEqual(fetch, f"{ssh} 'tar -C {work} -cf - out' | tar -x -C {d}")
        self.assertEqual(clean, f"{ssh} 'rm -rf {work}'")
        self.assertEqual(self.jobs.cancel_command(job),
                         f"{ssh} 'bash /home/exedev/repo/badge-manager/build-job.sh "
                         f"--cancel {job.id}'")

    def test_remote_uses_the_station_key(self):
        key = self.tmp / "id_ed25519"
        key.write_text("key")
        job = self.jobs.create("rain", "remote")
        with mock.patch.object(build_mod, "SSH_KEY", key):
            clean = self.jobs.commands(job)[2]
        self.assertTrue(clean.startswith(f"ssh -o BatchMode=yes -o ConnectTimeout=15 -i {key} "
                                         "exedev@vm.example "), clean)

    def test_remote_quoting(self):
        self.cfg.build_repo = "/home/x/my repo"
        job = self.jobs.create("rain", "remote")
        run = self.jobs.commands(job)[0]
        # the remote command is one argument, quoted again inside for the remote shell
        argv = shlex.split(run.split(" < ")[0])
        self.assertEqual(argv[:6], ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                                    "exedev@vm.example"])
        self.assertEqual(len(argv), 7)
        self.assertEqual(shlex.split(argv[6])[:2],
                         ["bash", "/home/x/my repo/badge-manager/build-job.sh"])

    def test_template(self):
        self.cfg.build_command = "run {id} {out} {prompt_file} {name} :: {flags}"
        self.cfg.library = self.tmp / "lib with space"
        jobs = Jobs(self.cfg.library, self.cfg)
        job = jobs.create("rain", "remote")
        [cmd] = jobs.commands(job)
        d = jobs.dir(job.id)
        self.assertEqual(cmd, f"run {job.id} '{d}/out' '{d}/prompt.txt' snouty-rain :: "
                              "--name snouty-rain --max-turns 40 --max-usd 5 --minutes 19")
        self.assertIsNone(jobs.cancel_command(job))
        jobs._release(job.id)

    def test_remote_run_through_fake_ssh(self):
        """The three-step remote sequence against an `ssh` on PATH that runs locally."""
        bin_ = self.tmp / "bin"
        bin_.mkdir()
        calls = self.tmp / "ssh.log"
        (bin_ / "ssh").write_text(
            "#!/bin/bash\n"
            "while [ \"${1:-}\" = -o ]; do shift 2; done\n"
            f"shift; echo \"$1\" >> {calls}\n"
            f"exec bash -c \"$1\"\n")
        (bin_ / "ssh").chmod(0o755)
        repo = self.tmp / "repo"
        (repo / "badge-manager").mkdir(parents=True)
        shutil.copy(FAKE, repo / "badge-manager" / "build-job.sh")
        self.cfg.build_repo = str(repo)
        with mock.patch.dict(os.environ, {"PATH": f"{bin_}:{os.environ['PATH']}"}):
            job = self.jobs.start("rain", "remote")
        self.assertEqual(job.state, "done", self.jobs.log(job.id))
        self.assertIn("step: fetching the results", self.jobs.log(job.id))
        ran = calls.read_text().splitlines()
        self.assertEqual(len(ran), 3)
        self.assertTrue(ran[0].startswith("bash ") and "--prompt-file -" in ran[0])
        self.assertTrue(ran[1].startswith("tar -C "))
        self.assertTrue(ran[2].startswith("rm -rf "))
        self.assertFalse((repo / "build-jobs" / job.id).exists())
        self.assertTrue((self.jobs.dir(job.id) / "out" / "preview.gif").is_file())
        self.assertIn("snouty-rain", Library(self.cfg.library).carts)


class StationBuildTest(Env):
    def station(self, **kw) -> Station:
        st = Station(fake_config(self.tmp, **kw))
        st._net = (time.monotonic() + 1e9, dict(NO_NET))
        return st

    def test_build_info(self):
        st = self.station(build_command=None, build_host=None)
        b = st.status()["build"]
        self.assertEqual(b, {"local": False, "remote": None, "ready": False, "where": None,
                             "why": "no build VM is set and this station cannot build carts "
                                    "itself"})
        with self.assertRaises(BuildNotReady):
            st.start_build("rain")
        st.config.build_host = "exedev@vm"
        b = st.build_info()
        self.assertEqual((b["remote"], b["where"], b["ready"]), ("exedev@vm", "remote", False))
        self.assertEqual(b["why"], "no internet: builds need the network")
        with self.assertRaises(BuildNotReady):
            st.start_build("rain", "remote")
        with self.assertRaises(BuildNotReady):
            st.start_build("rain", "local")
        st._net[1]["internet"] = True
        self.assertTrue(st.build_info()["ready"])
        with self.assertRaises(StationError):
            st.start_build("rain", "moon")

    def test_local_probe_needs_the_repo(self):
        st = self.station()
        with mock.patch("pathlib.Path.read_text", return_value="MemTotal: 8000000 kB\n"), \
                mock.patch("pathlib.Path.exists", return_value=True):
            self.assertFalse(st._local_build_ok())      # build_repo is not a directory
            Path(st.config.build_repo).mkdir()
            self.assertTrue(st._local_build_ok())

    def test_start_status_and_registration(self):
        st = self.station()
        self.assertTrue(st.build_info()["ready"])       # build_command skips the probes
        seq = st.status()["log_seq"]
        job_id = st.start_build("a snouty cart where it rains")
        with self.assertRaises(StationBusy):
            st.start_build("snow")
        self.assertTrue(st.wait_build(20))
        s = st.status()
        self.assertGreater(s["log_seq"], seq + 5)
        self.assertEqual(set(s["job"]), {"id", "prompt", "name", "title", "where", "state",
                                         "started", "seconds", "exit", "error", "log",
                                         "result"})
        self.assertEqual((s["job"]["id"], s["job"]["state"], s["job"]["title"]),
                         (job_id, "done", "Fake Rains"))
        self.assertEqual(s["job"]["result"], {"cart": "snouty-rains", "size": 4096,
                                              "bench_ms": 4.2,
                                              "preview": f"/builds/{job_id}/preview.gif"})
        self.assertLessEqual(len(s["job"]["log"]), 40)
        self.assertEqual(len(s["builds"]), 1)
        self.assertEqual(set(s["builds"][0]), {"id", "name", "title", "state", "started",
                                               "seconds", "preview", "bench_ms", "error"})
        cart = next(c for c in s["library"]["carts"] if c["key"] == "snouty-rains")
        self.assertEqual((cart["build"], cart["preview"]),
                         (job_id, f"/builds/{job_id}/preview.gif"))
        msgs = [e["msg"] for e in st.log_lines()]
        self.assertIn("build snouty-rains started on the station", msgs)
        self.assertIn("build snouty-rains done: Fake Rains is in the library", msgs)
        full = st.build_job(job_id)
        self.assertEqual(full["log"], st.jobs.log(job_id))
        self.assertEqual(st.build_job()["id"], job_id)
        self.assertIsNone(st.build_job("20990101-000000-nope"))
        self.assertIsNotNone(st.build_file(job_id, "preview.gif"))
        self.assertIsNone(st.build_file(job_id, "job.json"))
        # the next build named after a prompt does not reuse the cart name
        st.start_build("it rains")
        st.wait_build(20)
        self.assertEqual(st.build_job()["name"], "snouty-rains-2")

    def test_deploy_lock_is_separate(self):
        st = self.station()
        with mock.patch.dict(os.environ, {"FAKE_BUILD_SLOW": "30"}):
            st.start_build("rain")
            wait_for(lambda: (st.status()["job"] or {}).get("state") == "running")
            self.assertFalse(st.status()["busy"])
            self.assertTrue(st._action.acquire(blocking=False))   # a deploy could start
            st._action.release()
            self.assertTrue(st.cancel_build())
            self.assertTrue(st.wait_build(10))
        self.assertEqual(st.status()["job"]["state"], "cancelled")
        self.assertFalse(st.cancel_build())

    def test_bad_input(self):
        st = self.station()
        for prompt in ("", "x" * 2001):
            with self.assertRaises(StationError):
                st.start_build(prompt)
        with self.assertRaises(StationError):
            st.start_build("rain", name="a b")

    def test_other_process_wakes_the_poll(self):
        st = self.station()
        st.poll()
        seq = st.status()["log_seq"]
        other = Jobs(st.config.library, st.config)
        other.start("rain", "local")
        st.poll()
        self.assertGreater(st.status()["log_seq"], seq)


if __name__ == "__main__":
    unittest.main()
