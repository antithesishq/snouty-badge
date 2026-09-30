"""The HTTP API (server.py) against DemoStation, plus one class against the real Station."""
import http.client
import json
import shutil
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from tests.helpers import make_config
from badge_manager import server
from badge_manager.library import Library
from badge_manager.server import DemoStation, make_server, wifi_qr_text

HAVE_QRENCODE = shutil.which("qrencode") is not None


class ServerCase(unittest.TestCase):
    """Starts make_server(self.station) on a free port; subclasses build the station."""

    def make_station(self):
        raise NotImplementedError

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.station = self.make_station()
        self.httpd = make_server(self.station, "127.0.0.1", 0)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, kwargs={"poll_interval": 0.02},
                                       daemon=True)
        self.thread.start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def call(self, method: str, path: str, body=None, headers=None, raw: bytes | None = None):
        """(status, parsed JSON or raw bytes, headers)."""
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", data=data,
                                     method=method, headers=headers or {})
        if data is not None and raw is None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                status, payload, hdrs = r.status, r.read(), r.headers
        except urllib.error.HTTPError as e:
            status, payload, hdrs = e.code, e.read(), e.headers
        if (hdrs.get("Content-Type") or "").startswith("application/json"):
            payload = json.loads(payload)
        return status, payload, hdrs

    def status(self) -> dict:
        code, st, _ = self.call("GET", "/api/status")
        self.assertEqual(code, 200)
        return st

    def wait_idle(self, timeout: float = 10.0) -> dict:
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            st = self.status()
            if not st["busy"] and not self.httpd.app._action_lock.locked():
                return st
            time.sleep(0.02)
        self.fail("the station stayed busy")


class DemoServerTest(ServerCase):
    def make_station(self):
        st = DemoStation(library_root=self.tmp / "lib", step=0.01)
        st._start -= 10          # the demo badge plugs in on the next poll
        st.poll()
        return st

    def test_status_has_m1_keys(self):
        st = self.status()
        for k in ("badge", "busy", "network", "share", "sets", "library", "log", "seq", "qr"):
            self.assertIn(k, st)
        self.assertEqual(st["qr"], HAVE_QRENCODE)
        self.assertEqual(set(st["share"]), {"url", "ssid", "password"})
        self.assertIn("set", st["badge"])
        for f in st["badge"]["files"]:
            self.assertIn(f["kind"], ("cart", "rom", "other"))
            self.assertIn("title", f)
        for s in st["sets"]:
            self.assertIsInstance(s["files"], list)
            self.assertIn("entries_capacity", s)
        carts = {c["key"]: c for c in st["library"]["carts"]}
        self.assertEqual(set(carts["snouty"]["variants"]), {"ram", "xip"})
        self.assertEqual(carts["snouty"]["use"], "ram")

    def test_fit(self):
        code, rep, _ = self.call("POST", "/api/fit", {"carts": ["snouty", "snouty-bugs"],
                                                      "roms": ["sonic"]})
        self.assertEqual(code, 200)
        self.assertEqual(set(rep), {"bytes", "entries", "bytes_capacity", "entries_capacity",
                                    "fits", "why", "files"})
        self.assertTrue(rep["fits"])
        self.assertEqual(rep["files"], ["snouty.uf2", "snouty-bugs.uf2", "SONIC.GG"])
        code, rep, _ = self.call("POST", "/api/fit", {"carts": [c["key"] for c in
                                                                self.status()["library"]["carts"]]})
        self.assertEqual(code, 200)
        self.assertFalse(rep["fits"])
        self.assertTrue(rep["why"])

    def test_bad_bodies(self):
        for path, body in (("/api/fit", {"carts": ["nope"]}),
                           ("/api/fit", {"carts": "snouty"}),
                           ("/api/deploy", {}),
                           ("/api/deploy", {"set": "nope"}),
                           ("/api/deploy", {"carts": ["nope"]}),
                           ("/api/deploy", {"carts": [], "roms": []}),
                           ("/api/sets", {"carts": ["snouty"]}),
                           ("/api/sets", {"title": "x", "carts": [], "roms": []}),
                           ("/api/sets", {"title": "x", "carts": "snouty"}),
                           ("/api/cart-mode", {"cart": "snouty", "mode": "flash"}),
                           ("/api/cart-mode", {"cart": "snouty-bugs", "mode": "xip"}),
                           ("/api/cart-mode", {"cart": "nope", "mode": "ram"})):
            code, data, _ = self.call("POST", path, body)
            self.assertEqual(code, 400, (path, body, data))
            self.assertFalse(data["ok"])
            self.assertTrue(data["error"])
        code, data, _ = self.call("POST", "/api/fit", raw=b"not json",
                                  headers={"Content-Type": "application/json"})
        self.assertEqual(code, 400)
        code, _, _ = self.call("DELETE", "/api/sets/nope")
        self.assertEqual(code, 400)
        code, _, _ = self.call("POST", "/api/sets/demo", {})
        self.assertEqual(code, 405)

    def test_save_and_delete_set(self):
        code, data, _ = self.call("POST", "/api/sets", {"title": "Phone Pick",
                                                        "carts": ["snouty"], "roms": ["*.gg"]})
        self.assertEqual(code, 200, data)
        self.assertEqual(data["key"], "phone-pick")
        self.assertEqual(data["set"]["title"], "Phone Pick")
        self.assertEqual(data["set"]["files"], ["snouty.uf2", "SONIC.GG"])
        self.assertIn("phone-pick", {s["name"] for s in self.status()["sets"]})
        code, data, _ = self.call("DELETE", "/api/sets/phone-pick")
        self.assertEqual((code, data), (200, {"ok": True}))
        self.assertNotIn("phone-pick", {s["name"] for s in self.status()["sets"]})

    def test_cart_mode(self):
        code, data, _ = self.call("POST", "/api/cart-mode", {"cart": "snouty", "mode": "xip"})
        self.assertEqual(code, 200, data)
        self.assertEqual(data["cart"]["use"], "xip")
        self.assertEqual(data["cart"]["file"], "snouty-xip.uf2")
        demo = next(s for s in self.status()["sets"] if s["name"] == "demo")
        self.assertIn("snouty-xip.uf2", demo["files"])

    def test_deploy_selection(self):
        code, data, _ = self.call("POST", "/api/deploy", {"carts": ["snouty-bugs"],
                                                          "roms": ["sonic"]})
        self.assertEqual((code, data), (200, {"ok": True}))
        st = self.wait_idle()
        msgs = [x["msg"] for x in st["log"]]
        self.assertIn("Copied snouty-bugs.uf2.", msgs)
        self.assertTrue(any("ejected" in m for m in msgs))
        self.assertEqual([f["name"] for f in st["badge"]["files"]], ["snouty-bugs.uf2", "SONIC.GG"])
        self.assertEqual(st["badge"]["files"][1]["kind"], "rom")

    def test_deploy_set_names_it(self):
        code, _, _ = self.call("POST", "/api/deploy", {"set": "demo"})
        self.assertEqual(code, 200)
        self.assertEqual(self.wait_idle()["badge"]["set"], "demo")

    def test_busy_is_409(self):
        self.station._step = 0.2
        code, _, _ = self.call("POST", "/api/deploy", {"set": "demo"})
        self.assertEqual(code, 200)
        for path, body in (("/api/deploy", {"set": "demo"}),
                           ("/api/deploy", {"carts": ["snouty"]}),
                           ("/api/wipe", {}),
                           ("/api/sets", {"title": "x", "carts": ["snouty"]}),
                           ("/api/cart-mode", {"cart": "snouty", "mode": "xip"})):
            code, data, _ = self.call("POST", path, body)
            self.assertEqual(code, 409, (path, data))
        code, _, _ = self.call("DELETE", "/api/sets/demo")
        self.assertEqual(code, 409)
        code, _, _ = self.call("POST", "/api/upload", raw=b"x" * 10,
                               headers={"X-Filename": "a.gg"})
        self.assertEqual(code, 409)
        self.wait_idle()
        self.assertIn("demo", {s["name"] for s in self.status()["sets"]})

    @unittest.skipUnless(HAVE_QRENCODE, "qrencode is not installed")
    def test_qr_svg(self):
        for path in ("/qr/page.svg", "/qr/wifi.svg"):
            code, body, hdrs = self.call("GET", path)
            self.assertEqual(code, 200, path)
            self.assertEqual(hdrs["Content-Type"], "image/svg+xml")
            self.assertEqual(hdrs["Cache-Control"], "no-store")
            self.assertIn(b"<svg", body)

    def test_qr_without_qrencode(self):
        self.httpd.app.qr = False
        code, data, _ = self.call("GET", "/qr/page.svg")
        self.assertEqual(code, 404)
        self.assertFalse(data["ok"])
        self.assertFalse(self.status()["qr"])

    def test_qr_wifi_404_off_ap(self):
        self.httpd.app.qr = True
        self.station.share = lambda: {"url": "http://192.168.1.5/", "ssid": None, "password": None}
        code, _, _ = self.call("GET", "/qr/wifi.svg")
        self.assertEqual(code, 404)

    def test_wifi_text_escapes(self):
        self.assertEqual(wifi_qr_text("snouty-badge", "snoutysnouty"),
                         "WIFI:T:WPA;S:snouty-badge;P:snoutysnouty;;")
        self.assertEqual(wifi_qr_text('a;b,c:d"e\\f', "p;w"),
                         'WIFI:T:WPA;S:a\\;b\\,c\\:d\\"e\\\\f;P:p\\;w;;')

    def test_captive_redirect(self):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        c.request("GET", "/generate_204")
        r = c.getresponse()
        r.read()
        self.assertEqual(r.status, 302)
        self.assertEqual(r.getheader("Location"), f"http://127.0.0.1:{self.port}/")
        c.close()

    def test_upload_rom(self):
        code, data, _ = self.call("POST", "/api/upload", raw=b"G" * 2048,
                                  headers={"X-Filename": "Columns%20(World).gg",
                                           "Content-Type": "application/octet-stream"})
        self.assertEqual(code, 200, data)
        roms = {r["key"]: r for r in self.status()["library"]["roms"]}
        self.assertIn(data["key"], roms)
        self.assertEqual(roms[data["key"]]["size"], 2048)
        self.assertTrue((self.tmp / "lib" / "roms" / "Columns (World).gg").is_file())
        code, _, _ = self.call("POST", "/api/upload", raw=b"x", headers={"X-Filename": "a.txt"})
        self.assertEqual(code, 415)

    def test_page_served(self):
        code, body, hdrs = self.call("GET", "/")
        self.assertEqual(code, 200)
        self.assertIn(b"Deploy selection", body)
        self.assertNotIn(b"accept=", body)


@unittest.skipUnless(hasattr(Library, "save_set"), "needs the M1 Library (Track A)")
class RealStationServerTest(ServerCase):
    def make_station(self):
        from badge_manager.station import Station
        self.badge = self.tmp / "badge"
        self.badge.mkdir()
        st = Station(make_config(self.tmp, self.badge))
        st._net = (time.monotonic() + 1e9, {"mode": "none", "ssid": None, "address": None,
                                            "internet": False})
        st.poll()
        return st

    def test_status(self):
        st = self.status()
        self.assertTrue(st["badge"]["present"])
        self.assertIn("share", st)
        self.assertIn("qr", st)
        self.assertIn("set", st["badge"])
        for s in st["sets"]:
            self.assertIsInstance(s["files"], list)
        for c in st["library"]["carts"]:
            self.assertIn("variants", c)
            self.assertIn(c["use"], ("ram", "xip"))

    def test_fit_and_deploy_selection(self):
        code, rep, _ = self.call("POST", "/api/fit", {"carts": ["snouty-bugs"], "roms": ["sonic"]})
        self.assertEqual(code, 200, rep)
        self.assertTrue(rep["fits"], rep)
        self.assertIn("snouty-bugs.uf2", rep["files"])
        code, data, _ = self.call("POST", "/api/fit", {"carts": ["nope"]})
        self.assertEqual(code, 400)
        code, data, _ = self.call("POST", "/api/deploy", {"carts": ["snouty-bugs"], "roms": ["sonic"]})
        self.assertEqual((code, data), (200, {"ok": True}))
        self.wait_idle()
        names = sorted(p.name for p in self.badge.iterdir())
        self.assertEqual(names, sorted(rep["files"]))

    def test_sets_round_trip(self):
        code, data, _ = self.call("POST", "/api/sets", {"title": "Phone Pick",
                                                        "carts": ["snouty-bugs"], "roms": ["*.gg"]})
        self.assertEqual(code, 200, data)
        self.assertEqual(data["key"], "phone-pick")
        self.assertEqual(data["set"]["roms"], ["*.gg"])
        self.assertIn("phone-pick", Library(self.station.config.library).sets)
        code, data, _ = self.call("DELETE", "/api/sets/phone-pick")
        self.assertEqual((code, data), (200, {"ok": True}))
        self.assertNotIn("phone-pick", Library(self.station.config.library).sets)
        code, _, _ = self.call("DELETE", "/api/sets/phone-pick")
        self.assertEqual(code, 400)

    def test_cart_mode(self):
        carts = {c["key"]: c for c in self.status()["library"]["carts"]}
        both = [k for k, c in carts.items() if {"ram", "xip"} <= set(c["variants"])]
        if not both:
            self.skipTest("no cart with both variants in the test library")
        key = both[0]
        other = "xip" if carts[key]["use"] == "ram" else "ram"
        code, data, _ = self.call("POST", "/api/cart-mode", {"cart": key, "mode": other})
        self.assertEqual(code, 200, data)
        self.assertEqual(data["cart"]["use"], other)

    def test_qr_page_needs_an_address(self):
        self.httpd.app.qr = True
        code, _, _ = self.call("GET", "/qr/page.svg")
        self.assertEqual(code, 404)          # network "none": nothing to share


if __name__ == "__main__":
    unittest.main()
