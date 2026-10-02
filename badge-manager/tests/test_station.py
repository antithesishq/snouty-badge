import shutil
import tempfile
import threading
import time
import unittest
from pathlib import Path

from tests.helpers import make_config, make_uf2, write_config
from badge_manager import config as config_mod
from badge_manager import station as station_mod
from badge_manager.library import LibraryError
from badge_manager.station import DoesNotFit, NoBadge, Station, StationBusy


def quiet_net(st: Station) -> None:
    """Pre-seed the network cache so tests do not probe the network."""
    st._net = (time.monotonic() + 1e9, {"mode": "none", "ssid": None, "address": None,
                                        "internet": False})


class StationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.badge = self.tmp / "badge"
        self.badge.mkdir()
        (self.badge / "old.uf2").write_bytes(b"x" * 100)
        (self.badge / ".fseventsd").mkdir()
        self.cfg = make_config(self.tmp, self.badge)
        self.st = Station(self.cfg)
        quiet_net(self.st)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def msgs(self) -> list[str]:
        return [e["msg"] for e in self.st.log_lines()]

    def test_plug_and_unplug(self):
        self.st.poll()
        s = self.st.status()["badge"]
        self.assertTrue(s["present"] and s["mounted"])
        self.assertEqual({f["name"] for f in s["files"]}, {"old.uf2", ".fseventsd"})
        self.assertEqual(s["free_entries"], 31 - 2 - 2)
        self.assertIn("badge plugged in: 2 files, ", self.msgs()[-1])
        self.st.poll()
        self.assertEqual(len(self.msgs()), 1)            # no repeat while plugged
        self.badge.rename(self.tmp / "away")
        self.st.poll()
        self.assertEqual(self.msgs()[-1], "badge unplugged")
        self.assertFalse(self.st.status()["badge"]["present"])

    def test_deploy(self):
        self.st.poll()
        seq = self.st.status()["log_seq"]
        self.st.deploy("gear")
        self.assertEqual(sorted(p.name for p in self.badge.iterdir()),
                         ["SONIC.GG", "SONIC2.GG", "snouty-gear.uf2"])
        m = self.msgs()
        copies = [x for x in m if x.startswith("copying ")]
        self.assertEqual([c.split()[1] for c in copies], ["snouty-gear.uf2", "SONIC.GG", "SONIC2.GG"])
        self.assertIn("wiping the badge", m)
        self.assertIn("wiped, 2 old files removed", m)
        self.assertIn("ejecting the badge", m)
        self.assertRegex(m[-1], r"^done in \d+\.\d s, unplug the badge$")
        s = self.st.status()
        self.assertFalse(s["badge"]["present"])
        self.assertTrue(s["badge"]["ejected"])
        self.assertEqual(s["badge"]["note"], "ejected, unplug the badge")
        self.assertGreater(s["log_seq"], seq)
        self.assertFalse(s["busy"])
        # still ejected on the next poll; a fake badge comes back after FAKE_REPLUG_S
        self.st.poll()
        self.assertFalse(self.st.status()["badge"]["present"])
        dev, t = self.st._ejected
        self.st._ejected = (dev, t - station_mod.FAKE_REPLUG_S - 1)
        self.st.poll()
        s = self.st.status()["badge"]
        self.assertTrue(s["present"])
        self.assertFalse(s["ejected"])
        self.assertIn("badge plugged in: 3 files", self.msgs()[-1])
        # log file shared with other processes
        self.assertIn("unplug the badge", (self.tmp / "station.log").read_text())

    def test_deploy_needs_badge(self):
        shutil.rmtree(self.badge)
        with self.assertRaises(NoBadge):
            self.st.deploy("demo")

    def test_deploy_refuses_what_does_not_fit(self):
        self.st.poll()
        with self.assertRaises(DoesNotFit):
            self.st.deploy("broken")
        self.assertTrue((self.badge / "old.uf2").exists())   # not wiped
        self.assertTrue(self.msgs()[-1].startswith("cannot deploy Broken:"))

    def test_deploy_by_entries_refused(self):
        self.st.poll()
        text = self.cfg.library / "manifest.toml"
        roms = self.cfg.library / "roms"
        keys = []
        for i in range(12):
            (roms / f"Long ROM name number {i:02}.gg").write_bytes(b"r")
            keys.append(f'"r{i}"')
            text.write_text(text.read_text() + f'\n[roms.r{i}]\nfile = "roms/Long ROM name number {i:02}.gg"\nshort = "Long ROM name number {i:02}.gg"\n')
        text.write_text(text.read_text() + f'\n[sets.many]\ntitle = "Many"\nroms = [{", ".join(keys)}]\n')
        self.st.library.reload()
        with self.assertRaises(DoesNotFit) as cm:
            self.st.deploy("many")
        self.assertIn("36 root entries needed, 31 free", str(cm.exception))

    def test_busy(self):
        self.st.poll()
        gate, started = threading.Event(), threading.Event()
        real_copy = self.st._badge.copy

        def slow_copy(src, name):
            started.set()
            gate.wait(5)
            real_copy(src, name)

        self.st._badge.copy = slow_copy
        t = threading.Thread(target=self.st.deploy, args=("demo",))
        t.start()
        self.assertTrue(started.wait(5))
        s = self.st.status()
        self.assertTrue(s["busy"])
        self.assertEqual(s["action"], "deploy demo")
        with self.assertRaises(StationBusy):
            self.st.deploy("gear")
        with self.assertRaises(StationBusy):
            self.st.wipe()
        self.st.poll()          # skipped while busy, must not raise
        gate.set()
        t.join(5)
        self.assertFalse(self.st.status()["busy"])
        self.assertEqual(sorted(p.name for p in self.badge.iterdir()),
                         ["snouty-bugs.uf2", "snouty.uf2"])

    def test_wipe(self):
        self.st.poll()
        self.st.wipe()
        self.assertEqual(list(self.badge.iterdir()), [])
        self.assertTrue(self.st.status()["badge"]["ejected"])

    def test_wait_for_change(self):
        n = self.st.wait_for_change(-1, 0)
        t0 = time.monotonic()
        self.assertEqual(self.st.wait_for_change(n, 0.2), n)
        self.assertGreaterEqual(time.monotonic() - t0, 0.15)
        timer = threading.Timer(0.05, self.st.log, args=("hello",))
        timer.start()
        self.assertGreater(self.st.wait_for_change(n, 5), n)
        timer.join(5)                  # its log-file write must finish before tearDown

    def test_sync_streams_and_reloads(self):
        self.cfg.sync_command = "echo fetched one; echo second line; exit 3"
        self.assertFalse(self.st.sync())
        m = self.msgs()
        self.assertIn("fetched one", m)
        self.assertIn("sync failed (exit 3)", m)
        self.assertTrue(m[-1].startswith("library: 4 carts"))

    def test_sync_default_uses_sync_sh(self):
        cmd, env = self.st._sync_command()
        if station_mod.SYNC_SH.exists():
            self.assertIn("sync.sh", cmd)
            self.assertIn(" local ", cmd + " ")
        else:
            self.assertIn("rsync", cmd)
        self.assertEqual(env["BADGE_STATION_LIBRARY"], str(self.cfg.library))

    @unittest.skipUnless(station_mod.SYNC_SH.exists() and shutil.which("rsync"), "needs sync.sh + rsync")
    def test_sync_via_sync_sh_local(self):
        cfg_path = write_config(self.tmp / "s")
        cfg = config_mod.load(cfg_path)
        cfg.build_host, cfg.build_repo = None, str(self.tmp / "repo")
        make_uf2(self.tmp / "repo" / "zig-out" / "firmware" / "snouty-new.uf2", "xip", 3)
        st = Station(cfg)
        self.assertTrue(st.sync(), "\n".join(e["msg"] for e in st.log_lines()))
        c = st.library.carts["snouty-new"]
        self.assertEqual((c.mode, c.auto), ("xip", False))
        self.assertTrue(any("updated snouty-new" in e["msg"] for e in st.log_lines()))

    def test_status_contract(self):
        self.st.poll()
        s = self.st.status()
        self.assertEqual(set(s) - {"log_seq"},
                         {"badge", "busy", "action", "network", "share", "build", "job",
                          "builds", "sets", "library", "log"})
        self.assertEqual(set(s["badge"]) - {"ejected"},
                         {"present", "device", "mounted", "files", "set", "free_bytes",
                          "free_entries", "note"})
        self.assertEqual(set(s["share"]), {"url", "ssid", "password"})
        for f in s["badge"]["files"]:
            self.assertEqual(set(f), {"name", "size", "title", "kind"})
        for x in s["sets"]:
            self.assertEqual(set(x), {"name", "title", "bytes", "entries", "bytes_capacity",
                                      "entries_capacity", "fits", "why", "carts", "roms", "files"})
        for c in s["library"]["carts"]:
            self.assertEqual(set(c), {"key", "title", "use", "mode", "file", "size", "variants",
                                      "roms", "ok", "error", "auto", "build", "preview"})
            for v in c["variants"].values():
                self.assertEqual(set(v), {"file", "size", "ok", "error"})
        self.assertEqual(set(s["network"]), {"mode", "ssid", "address", "internet"})
        self.assertEqual(set(s["build"]), {"local", "remote", "ready", "why", "where"})
        self.assertEqual((s["job"], s["builds"]), (None, []))
        for x in s["sets"]:
            self.assertLessEqual({"name", "title", "bytes", "entries", "fits", "why",
                                  "entries_capacity"}, set(x))
            self.assertEqual(x["entries_capacity"], 31)
        self.assertEqual(set(s["log"][0]), {"t", "msg"})

    # -- M1 -------------------------------------------------------------------

    def test_badge_set_and_titles(self):
        self.assertEqual(self.st.status()["badge"]["set"], None)      # no badge yet
        self.st.poll()
        b = self.st.status()["badge"]
        self.assertIsNone(b["set"])
        self.assertEqual({f["name"]: f["kind"] for f in b["files"]},
                         {"old.uf2": "other", ".fseventsd": "other"})
        self.st.deploy("demo")
        b = self.st.status()["badge"]                 # ejected: files still shown, set known
        self.assertEqual(b["set"], "demo")
        self.assertEqual(sorted((f["title"], f["kind"]) for f in b["files"]),
                         [("Snouty Bughunt", "cart"), ("Snouty Run", "cart")])
        dev, t = self.st._ejected
        self.st._ejected = (dev, t - station_mod.FAKE_REPLUG_S - 1)
        (self.badge / ".Trashes").mkdir()
        self.st.poll()
        b = self.st.status()["badge"]
        self.assertTrue(b["present"])
        self.assertEqual(b["set"], "demo")            # hidden junk is ignored

    def test_deploy_selection(self):
        self.st.poll()
        self.st.deploy(self.st.library.selection(["snouty-bugs"], [".gg"]))
        self.assertEqual(sorted(p.name for p in self.badge.iterdir()),
                         ["SONIC.GG", "SONIC2.GG", "snouty-bugs.uf2"])
        self.assertTrue(any(m.startswith("deploying Selection: 3 files") for m in self.msgs()))
        self.assertIsNone(self.st.status()["badge"]["set"])

    def test_library_edits(self):
        seq = self.st.status()["log_seq"]
        c = self.st.set_cart_mode("snouty", "xip")
        self.assertEqual(c.use, "xip")
        self.assertEqual(self.msgs()[-1], "snouty now deploys as XIP")
        sets = {x["name"]: x for x in self.st.status()["sets"]}
        self.assertEqual(sets["demo"]["files"], ["snouty-xip.uf2", "snouty-bugs.uf2"])
        s = self.st.save_set("Game Gear", ["snouty-gear", "snouty-bugs"], ["*.gg"], key="gear", replace=True)
        self.assertEqual(s.key, "gear")
        self.assertEqual(self.msgs()[-1], "saved set Game Gear (gear): 2 carts, *.gg")
        self.st.delete_set("gear")
        self.assertEqual(self.msgs()[-1], "removed set gear")
        self.assertNotIn("gear", {x["name"] for x in self.st.status()["sets"]})
        self.assertGreater(self.st.status()["log_seq"], seq + 3)
        with self.assertRaises(LibraryError):
            self.st.delete_set("gear")
        with self.assertRaises(LibraryError):
            self.st.set_cart_mode("snouty-bugs", "xip")

    def test_share(self):
        st = self.st
        net = {"mode": "none", "ssid": None, "address": None, "internet": False}
        self.assertEqual(st.share(net), {"url": None, "ssid": None, "password": None})
        self.assertEqual(st.share(dict(net, mode="hotspot", ssid="phone", address="172.20.10.3")),
                         {"url": "http://172.20.10.3/", "ssid": None, "password": None})
        self.assertEqual(st.share(dict(net, mode="ap", ssid="snouty-badge")),
                         {"url": "http://10.42.0.1/", "ssid": self.cfg.ap_ssid,
                          "password": self.cfg.ap_password})
        self.assertEqual(st.share(dict(net, mode="ap", address="10.42.0.7"))["url"],
                         "http://10.42.0.7/")
        self.assertEqual(st.status()["share"]["url"], None)
        self.cfg.http_port = 8080          # not port 80: the URL and QR must say so
        self.assertEqual(st.share(dict(net, mode="ap"))["url"], "http://10.42.0.1:8080/")

    def test_nmcli_parsing(self):
        st = self.st
        out = {("-f", "NAME,TYPE,DEVICE", "connection", "show", "--active"):
               "lo:loopback:lo\nAdrian\\:s phone:802-11-wireless:wlan0\nWired:802-3-ethernet:eth0\n",
               ("-f", "IP4.ADDRESS", "device", "show", "wlan0"): "IP4.ADDRESS[1]:172.20.10.3/28\n"}
        st._nmcli = lambda *a: out.get(a, "")
        self.assertEqual(st._nmcli_network(),
                         {"mode": "hotspot", "ssid": "Adrian:s phone", "address": "172.20.10.3"})
        out[("-f", "NAME,TYPE,DEVICE", "connection", "show", "--active")] = \
            "snouty-badge:802-11-wireless:wlan0\n"
        self.assertEqual(st._nmcli_network()["mode"], "ap")
        out[("-f", "NAME,TYPE,DEVICE", "connection", "show", "--active")] = "Wired:802-3-ethernet:eth0\n"
        self.assertEqual(st._nmcli_network()["mode"], "wired")


if __name__ == "__main__":
    unittest.main()
