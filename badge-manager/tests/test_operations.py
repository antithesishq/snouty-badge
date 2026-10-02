"""Operational safety checks without root or NetworkManager."""
import os
import io
import json
import contextlib
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest
from types import SimpleNamespace
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

from badge_manager.build import Jobs
from badge_manager.config import Config
from badge_manager import config as config_mod
from badge_manager import cli

ROOT = Path(__file__).resolve().parents[1]


class OperationsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def test_bad_hotspot_config_never_mutates_profiles(self):
        cfg = self.tmp / "station.toml"
        cfg.write_text('[[hotspots]]\nssid = "incomplete\n')
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        calls = self.tmp / "calls"
        nmcli = bin_dir / "nmcli"
        nmcli.write_text(f'#!/bin/sh\necho "$*" >> "{calls}"\nexit 0\n')
        nmcli.chmod(0o755)
        env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}")
        run = subprocess.run(["bash", str(ROOT / "net/nm-profiles.sh"), str(cfg)],
                             capture_output=True, text=True, env=env)
        self.assertNotEqual(run.returncode, 0)
        self.assertFalse(calls.exists())

    def test_documented_ssh_values_survive_remote_shell(self):
        commands = [line for line in (ROOT / "README.md").read_text().splitlines()
                    if line.startswith("ssh ") and ("Game Gear" in line or "rains frogs" in line)]
        self.assertEqual(len(commands), 2)
        parsed = [shlex.split(shlex.split(line)[-1]) for line in commands]
        self.assertIn(["badge", "build", "a Snouty cart where it rains frogs"], parsed)
        self.assertIn(["badge", "set", "save", "gg", "--title", "Game Gear",
                       "--carts", "snouty-gear", "--roms", "*.gg"], parsed)

    def test_operator_wipe_uses_service_and_rejects_config_override(self):
        requests = []

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                requests.append((self.path, self.rfile.read(int(self.headers["Content-Length"]))))
                body = b'{"ok": true}'
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        from threading import Thread
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        cfg = self.tmp / "station.toml"
        cfg.write_text(f"http_port = {server.server_port}\n")
        cfg.chmod(0o600)
        endpoint = self.tmp / "operator.json"
        config_mod.publish_operator_endpoint(cfg, endpoint)
        self.assertEqual(endpoint.stat().st_mode & 0o777, 0o644)
        self.assertEqual(json.loads(endpoint.read_text()), {"http_port": server.server_port})
        self.assertEqual(config_mod.operator_port(endpoint), server.server_port)
        self.assertIn(r"BADGE_STATION_OPERATOR=\${BADGE_STATION_OPERATOR:-1}",
                      (ROOT / "setup.sh").read_text())
        with mock.patch.dict(os.environ, {"BADGE_STATION_OPERATOR": "1"}), \
                mock.patch("badge_manager.config.OPERATOR_ENDPOINT", endpoint):
            self.assertEqual(cli.main(["wipe"]), 1)
            self.assertFalse(requests)
            self.assertEqual(cli.main(["--config", str(cfg), "wipe", "--yes"]), 1)
            self.assertFalse(requests)
            self.assertEqual(cli.main(["wipe", "--yes"]), 0)
        self.assertEqual(requests, [("/api/wipe", b"{}")])

    def test_operator_build_runs_via_service(self):
        calls = []

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                calls.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
                body = b'{"ok": true, "id": "20261001-120000-rain"}'
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                job = {"state": "done", "title": "Rain", "result": {"cart": "snouty-rain"},
                       "log": ["step: built"]}
                body = json.dumps({"job": job}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        from threading import Thread
        Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        cfg = self.tmp / "station.toml"
        cfg.write_text(f"http_port = {server.server_port}\n")
        endpoint = self.tmp / "operator.json"
        config_mod.publish_operator_endpoint(cfg, endpoint)
        output = io.StringIO()
        with mock.patch.dict(os.environ, {"BADGE_STATION_OPERATOR": "1"}), \
                mock.patch("badge_manager.config.OPERATOR_ENDPOINT", endpoint), \
                contextlib.redirect_stdout(output):
            rc = cli.main(["build", "a cart where it rains", "--no-agent"])
        self.assertEqual(rc, 0)
        self.assertEqual(calls, [{"prompt": "a cart where it rains", "where": "auto",
                                  "name": None, "no_agent": True}])
        self.assertIn("step: built", output.getvalue())

    def test_timeout_kills_descendant_after_shell_exits(self):
        child_pid = self.tmp / "child.pid"
        script = self.tmp / "stubborn.sh"
        script.write_text(f'''#!/bin/bash
python3 -c 'import os,signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); open("{child_pid}", "w").write(str(os.getpid())); time.sleep(30)' &
wait
''')
        script.chmod(0o755)
        cfg = Config(library=self.tmp / "library", build_command=f"bash {script}",
                     build_max_minutes=0.005)
        jobs = Jobs(cfg.library, cfg)
        try:
            with mock.patch("badge_manager.build.KILL_GRACE_S", 0.2):
                started = time.monotonic()
                job = jobs.start("stubborn child", "local")
            self.assertLess(time.monotonic() - started, 3)
            self.assertEqual(job.state, "failed")
            self.assertEqual(job.exit, 124)
            self.assertFalse(jobs.locked())
        finally:
            if child_pid.exists():
                try:
                    os.kill(int(child_pid.read_text()), 9)
                except ProcessLookupError:
                    pass

    def test_root_service_local_build_selects_unprivileged_account(self):
        cfg = Config(library=self.tmp / "library", build_user="builder",
                     build_home=self.tmp / "home")
        jobs = Jobs(cfg.library, cfg)
        account = SimpleNamespace(pw_uid=1234, pw_gid=1235, pw_name="builder",
                                  pw_dir="/home/builder")
        with mock.patch("badge_manager.build.os.geteuid", return_value=0), \
                mock.patch("badge_manager.build.pwd.getpwnam", return_value=account), \
                mock.patch("badge_manager.build.os.chown") as chown:
            job = jobs.create("rain", "local")
            options = jobs._builder_options(job)
        self.addCleanup(jobs._release, job.id)
        chown.assert_called_once_with(jobs.dir(job.id) / "out", 1234, 1235)
        self.assertEqual((jobs.dir(job.id) / "out").stat().st_mode & 0o777, 0o700)
        self.assertEqual((options["user"], options["group"], options["extra_groups"]),
                         (1234, 1235, []))
        self.assertEqual(options["env"]["HOME"], str(cfg.build_home))

    def test_callback_failure_kills_build_descendant(self):
        child_pid = self.tmp / "callback-child.pid"
        script = self.tmp / "callback.sh"
        script.write_text(f'''#!/bin/bash
python3 -u -c 'import os,signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); open("{child_pid}", "w").write(str(os.getpid())); print("ready", flush=True); time.sleep(30)' &
wait
''')
        script.chmod(0o755)
        jobs = Jobs(self.tmp / "library", Config(library=self.tmp / "library",
                                                  build_command=f"bash {script}"))
        raised = False

        def callback(line):
            nonlocal raised
            if line == "ready" and not raised:
                raised = True
                raise RuntimeError("callback failed")

        try:
            with mock.patch("badge_manager.build.KILL_GRACE_S", 0.2):
                job = jobs.start("rain", "local", on_line=callback)
            self.assertEqual(job.state, "failed")
            self.assertFalse(jobs.locked())
            pid = int(child_pid.read_text())
            stat = Path(f"/proc/{pid}/stat")
            self.assertTrue(not stat.exists() or stat.read_text().split()[2] == "Z")
        finally:
            if child_pid.exists():
                try:
                    os.kill(int(child_pid.read_text()), 9)
                except ProcessLookupError:
                    pass
