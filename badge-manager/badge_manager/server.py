"""JSON API and the phone page for the badge station (PLAN.md section 2).

    python3 -m badge_manager.server [--config PATH] [--port N]
                                    [--fake-badge PATH] [--demo]

Standard library only: ThreadingHTTPServer, one background thread calling
station.poll() once a second, one worker thread per action so a request
returns at once. --demo (or BADGE_STATION_DEMO=1) serves DemoStation, a fake
that honours the status contract in badge_manager/__init__.py; it is also
the fallback when the real Station cannot be imported or constructed.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import re
import shutil
import sys
import tempfile
import threading
import time
import traceback
from email.parser import BytesParser
from email.policy import HTTP as HTTP_POLICY
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit

log = logging.getLogger("badge_manager.server")

WWW = Path(__file__).resolve().parent.parent / "www"
ROM_EXTENSIONS = {".gg", ".sms", ".gb", ".gbc", ".md", ".bin"}
MAX_UPLOAD = 4 * 1024 * 1024
MAX_JSON = 64 * 1024
MAX_WAIT = 30.0
CAPTIVE_PATHS = {
    "/generate_204", "/gen_204", "/hotspot-detect.html", "/connecttest.txt",
    "/ncsi.txt", "/success.txt", "/library/test/success.html",
    "/canonical.html",
}
STATIC_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
LOCAL_HOSTS = re.compile(r"^(localhost|snouty(\.local)?|[0-9.]+|\[[0-9a-fA-F:.]+\])$")


class ApiError(Exception):
    def __init__(self, status: int, error: str):
        super().__init__(error)
        self.status = status
        self.error = error


# ---------------------------------------------------------------- demo station

class DemoBusy(Exception):
    pass


class _DemoLibrary:
    """Just enough of Library for the page: to_json() and add_rom()."""

    def __init__(self, root: Path):
        self.root = root
        self.carts = [
            {"key": "snouty", "title": "Snouty Run", "size": 315392, "mode": "ram"},
            {"key": "snouty-bugs", "title": "Snouty Bughunt", "size": 154624, "mode": "ram"},
            {"key": "snoutenstein", "title": "Snoutenstein 3D", "size": 385024, "mode": "ram"},
            {"key": "snouty-gear", "title": "Snouty Gear", "size": 357376, "mode": "ram"},
        ]
        self.roms = [
            {"key": "sonic", "title": "Sonic GG", "size": 262144, "short": "SONIC.GG"},
        ]

    def add_rom(self, path: Path, title: str | None = None) -> str:
        (self.root / "roms").mkdir(parents=True, exist_ok=True)
        dest = self.root / "roms" / path.name
        shutil.copyfile(path, dest)
        key = re.sub(r"[^a-z0-9]+", "-", path.stem.lower()).strip("-") or "rom"
        self.roms = [r for r in self.roms if r["key"] != key]
        self.roms.append({"key": key, "title": title or path.stem,
                          "size": dest.stat().st_size, "short": ""})
        return key

    def to_json(self) -> dict:
        return {"carts": list(self.carts), "roms": list(self.roms)}


class DemoStation:
    """Fakes the Station contract: the badge plugs in 3 s after start, two
    sets (one does not fit), deploy takes 2 s and ends ejected; unplugging
    is simulated 6 s after the eject and a re-plug 4 s after that."""

    SETS = {
        "demo": ("Demo reel", ["snouty.uf2", "snouty-bugs.uf2", "snoutenstein.uf2"]),
        "gear": ("Game Gear Sonic", ["snouty-gear.uf2", "snouty-bugs.uf2", "snouty.uf2",
                                     "snoutenstein.uf2", "SONIC.GG"]),
    }
    VOLUME = 1280 * 1024 - 8 * 512

    def __init__(self, library_root: Path | None = None):
        self._cond = threading.Condition()
        self._lock = threading.Lock()
        self._seq = 0
        self._log: list[dict] = []
        self._start = time.monotonic()
        self._present = False
        self._ejected_at: float | None = None
        self._unplugged_at: float | None = None
        self._files: list[dict] = []
        self.action: str | None = None
        root = library_root or Path(tempfile.mkdtemp(prefix="badge-demo-lib-"))
        self.library = _DemoLibrary(root)
        self.log("Demo station started. The badge plugs itself in after 3 s.")

    def _sizes(self) -> dict[str, int]:
        sizes = {c["key"] + ".uf2": c["size"] for c in self.library.carts}
        sizes.update({r["short"]: r["size"] for r in self.library.roms if r["short"]})
        return sizes

    def _bump(self) -> None:
        with self._cond:
            self._seq += 1
            self._cond.notify_all()

    def log(self, msg: str) -> None:
        with self._cond:
            self._log.append({"t": time.time(), "msg": msg})
            del self._log[:-200]
        log.info("station: %s", msg)
        self._bump()

    def poll(self) -> None:
        now = time.monotonic()
        if not self._present and self._ejected_at is None and self._unplugged_at is None \
                and now - self._start >= 3:
            self._plug()
        if self._ejected_at is not None and now - self._ejected_at >= 6:
            self._ejected_at = None
            self._unplugged_at = now
            self.log("Badge unplugged.")
        if self._unplugged_at is not None and now - self._unplugged_at >= 4:
            self._unplugged_at = None
            self._plug()

    def _plug(self) -> None:
        self._present = True
        if not self._files:
            self._files = [{"name": "snouty.uf2", "size": 315392}]
        self.log("Badge found on /dev/sda, mounted.")

    def _entries(self, name: str) -> int:
        up = name.upper() == name and re.fullmatch(r"[A-Z0-9_-]{1,8}(\.[A-Z0-9]{1,3})?", name)
        return 1 if up else 1 + -(-len(name) // 13)

    def _set_json(self, key: str) -> dict:
        title, names = self.SETS[key]
        sizes = self._sizes()
        nbytes = sum(-(-sizes.get(n, 0) // 512) * 512 for n in names)
        entries = sum(self._entries(n) for n in names)
        why = []
        if nbytes > self.VOLUME:
            why.append(f"{nbytes // 1024} KB is more than the {self.VOLUME // 1024} KB the drive holds")
        if entries > 31:
            why.append(f"{entries} root entries, the drive has 31")
        return {"name": key, "title": title, "bytes": nbytes, "entries": entries,
                "fits": not why, "why": why}

    def status(self) -> dict:
        present = self._present
        used = sum(-(-f["size"] // 512) * 512 for f in self._files)
        note = ""
        if self._ejected_at is not None:
            note = "Ejected. Unplug the badge."
        elif not present:
            note = "Plug the badge in while it is on its menu."
        with self._cond:
            logs = list(self._log)
            seq = self._seq
        return {
            "seq": seq,
            "badge": {
                "present": present,
                "device": "/dev/sda" if present else None,
                "mounted": present,
                "ejected": self._ejected_at is not None,
                "files": list(self._files) if present else [],
                "free_bytes": self.VOLUME - used if present else None,
                "free_entries": 31 - sum(self._entries(f["name"]) for f in self._files)
                if present else None,
                "note": note,
            },
            "busy": self.action is not None,
            "action": self.action,
            "network": {"mode": "ap", "ssid": "snouty-badge", "address": "10.42.0.1",
                        "internet": False},
            "build": {"local": False, "remote": "exedev@animated-badge.exe.xyz"},
            "sets": [self._set_json(k) for k in self.SETS],
            "library": self.library.to_json(),
            "log": logs,
        }

    def _run(self, action: str, fn) -> None:
        if not self._lock.acquire(blocking=False):
            raise DemoBusy(self.action or "busy")
        try:
            self.action = action
            self._bump()
            fn()
        finally:
            self.action = None
            self._lock.release()
            self._bump()

    def deploy(self, set_key: str) -> None:
        if set_key not in self.SETS:
            raise KeyError(set_key)

        def go():
            if not self._present:
                self.log("No badge plugged in.")
                return
            s = self._set_json(set_key)
            if not s["fits"]:
                self.log(f"Set {set_key} does not fit: " + "; ".join(s["why"]))
                return
            sizes = self._sizes()
            self.log(f"Deploy {s['title']}: wiping the drive.")
            self._files = []
            time.sleep(0.4)
            for name in self.SETS[set_key][1]:
                time.sleep(0.4)
                self._files.append({"name": name, "size": sizes.get(name, 0)})
                self.log(f"Copied {name}.")
            time.sleep(0.2)
            self.log("Synced, unmounted, ejected. Unplug the badge.")
            self._present = False
            self._ejected_at = time.monotonic()
        self._run(f"deploy {set_key}", go)

    def wipe(self) -> None:
        def go():
            if not self._present:
                self.log("No badge plugged in.")
                return
            time.sleep(0.5)
            self._files = []
            self.log("Wiped the drive.")
        self._run("wipe", go)

    def sync(self) -> None:
        def go():
            self.log("Sync: rsync from exedev@animated-badge.exe.xyz (demo, nothing copied).")
            time.sleep(1.0)
            self.log("Sync done, 0 files changed.")
        self._run("sync", go)

    def wait_for_change(self, since: int, timeout: float) -> int:
        with self._cond:
            self._cond.wait_for(lambda: self._seq != since, timeout=max(0.0, timeout))
            return self._seq


# ---------------------------------------------------------------- the server

def _busy_types(station) -> tuple[type, ...]:
    types: list[type] = [DemoBusy]
    try:
        from .station import StationBusy
        types.append(StationBusy)
    except Exception:
        pass
    return tuple(types)


def _expected_errors() -> tuple[type, ...]:
    """Failures the station already explains (no badge, does not fit): no traceback."""
    types: list[type] = [KeyError]
    for mod, name in ((".station", "StationError"), (".device", "DeviceError"),
                      (".library", "LibraryError")):
        try:
            types.append(getattr(__import__(f"badge_manager{mod}", fromlist=[name]), name))
        except Exception:
            pass
    return tuple(types)


def _library_error() -> type:
    try:
        from .library import LibraryError
        return LibraryError
    except Exception:
        return ValueError


def current_seq(station) -> int:
    return station.wait_for_change(-1, 0)


class App:
    """Everything the handler needs, shared across request threads."""

    def __init__(self, station, www: Path = WWW):
        self.station = station
        self.www = www
        self.busy_types = _busy_types(station)
        self.expected_errors = _expected_errors()
        self._action_lock = threading.Lock()
        self._stop = threading.Event()

    # Actions: validated in the request thread, run in a worker thread.
    def start(self, name: str, fn, *args) -> None:
        st = self.station.status()
        if st.get("busy") or not self._action_lock.acquire(blocking=False):
            raise ApiError(409, "busy")

        def work():
            try:
                fn(*args)
            except self.busy_types:
                self.station.log(f"{name}: the station is busy, try again.")
            except self.expected_errors as e:
                log.warning("%s: %s", name, e)
                self.station.log(f"{name} stopped: {e}")
            except Exception as e:
                log.error("%s failed:\n%s", name, traceback.format_exc())
                self.station.log(f"{name} failed: {e}")
            finally:
                self._action_lock.release()

        threading.Thread(target=work, name=f"action-{name}", daemon=True).start()

    def poller(self) -> None:
        failing = False
        while not self._stop.wait(1.0):
            try:
                self.station.poll()
                failing = False
            except Exception:
                if not failing:
                    log.error("poll failed:\n%s", traceback.format_exc())
                failing = True


class Handler(BaseHTTPRequestHandler):
    server_version = "badge-station"
    protocol_version = "HTTP/1.1"
    app: App  # set on the subclass made by make_server()

    def log_message(self, fmt, *args):
        log.info("%s %s", self.address_string(), fmt % args)

    # -------------------------------------------------------- responses

    def _send(self, status: int, body: bytes, ctype: str, extra: dict | None = None):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, status: int, obj) -> None:
        self._send(status, json.dumps(obj).encode(), "application/json")

    def _error(self, status: int, error: str) -> None:
        self._json(status, {"ok": False, "error": error})

    def _redirect_home(self) -> None:
        host, port = self.connection.getsockname()[:2]
        where = f"http://{host}/" if port == 80 else f"http://{host}:{port}/"
        self._send(302, b"", "text/plain", {"Location": where})

    # -------------------------------------------------------- dispatch

    def _dispatch(self, method: str) -> None:
        try:
            url = urlsplit(self.path)
            query = {k: v[-1] for k, v in parse_qs(url.query).items()}
            name = self._route_name(url.path)
            route = getattr(self, f"_{method}_{name}", None) if name else None
            if route is None:
                if name:
                    raise ApiError(405, f"{method.upper()} is not allowed here")
                if url.path in CAPTIVE_PATHS or (method == "get" and self._foreign_host()):
                    return self._redirect_home()
                if url.path.startswith("/static/") and method == "get":
                    return self._static(url.path[len("/static/"):])
                raise ApiError(404, "not found")
            route(query)
        except ApiError as e:
            self._drain()
            self._error(e.status, e.error)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:
            log.error("%s %s failed:\n%s", method.upper(), self.path, traceback.format_exc())
            try:
                self._error(500, f"internal error: {type(e).__name__}: {e}")
            except Exception:
                pass

    @staticmethod
    def _route_name(path: str) -> str | None:
        return {"/": "index", "/index.html": "index", "/api/status": "status",
                "/api/log": "log", "/api/deploy": "deploy", "/api/wipe": "wipe",
                "/api/sync": "sync", "/api/upload": "upload"}.get(path)

    def _foreign_host(self) -> bool:
        host = (self.headers.get("Host") or "").strip().lower()
        if not host.startswith("["):
            host = host.rsplit(":", 1)[0]
        elif "]" in host:
            host = host[:host.index("]") + 1]
        return bool(host) and not LOCAL_HOSTS.match(host)

    def do_GET(self):
        self._dispatch("get")

    def do_HEAD(self):
        self._dispatch("get")

    def do_POST(self):
        self._dispatch("post")

    def do_PUT(self):
        self._dispatch("put")

    def do_DELETE(self):
        self._dispatch("delete")

    # -------------------------------------------------------- body helpers

    def _length(self, limit: int) -> int:
        if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
            self.close_connection = True
            raise ApiError(411, "send a Content-Length, chunked bodies are not supported")
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            raise ApiError(400, "bad Content-Length")
        if n > limit:
            self.close_connection = True
            raise ApiError(413, f"too large, the limit is {min(limit, MAX_UPLOAD) // 1024} KB")
        return n

    def _drain(self) -> None:
        """Read an unread small body so keep-alive stays in sync; big ones close."""
        if getattr(self, "_body_read", False) or self.command not in ("POST", "PUT"):
            return
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = -1
        if 0 < n <= MAX_JSON:
            self.rfile.read(n)
        elif n != 0:
            self.close_connection = True
        self._body_read = True

    def _read_json(self) -> dict:
        n = self._length(MAX_JSON)
        raw = self.rfile.read(n) if n else b""
        self._body_read = True
        if not raw.strip():
            return {}
        try:
            obj = json.loads(raw)
        except (ValueError, UnicodeDecodeError):
            raise ApiError(400, "body is not JSON")
        if not isinstance(obj, dict):
            raise ApiError(400, "body must be a JSON object")
        return obj

    # -------------------------------------------------------- GET routes

    def _get_index(self, query):
        self._static("index.html")

    def _static(self, name: str):
        www = self.app.www
        if not STATIC_NAME.match(name):
            raise ApiError(404, "not found")
        path = www / name
        if not path.is_file() or path.resolve().parent != www.resolve():
            raise ApiError(404, "not found")
        ctype = {".html": "text/html; charset=utf-8", ".css": "text/css",
                 ".js": "text/javascript", ".png": "image/png", ".svg": "image/svg+xml",
                 ".gif": "image/gif", ".ico": "image/x-icon",
                 ".json": "application/json"}.get(path.suffix, "application/octet-stream")
        self._send(200, path.read_bytes(), ctype)

    def _get_status(self, query):
        station = self.app.station
        if "since" in query:
            try:
                since = int(query["since"])
                wait = min(MAX_WAIT, max(0.0, float(query.get("wait", 25))))
            except ValueError:
                raise ApiError(400, "since and wait must be numbers")
            seq = station.wait_for_change(since, wait)
        else:
            seq = current_seq(station)
        st = station.status()
        st["seq"] = st.get("log_seq", seq)
        self._json(200, st)

    def _get_log(self, query):
        try:
            n = max(1, min(200, int(query.get("n", 200))))
        except ValueError:
            raise ApiError(400, "n must be a number")
        self._json(200, {"log": self.app.station.status().get("log", [])[-n:]})

    # -------------------------------------------------------- POST routes

    def _post_deploy(self, query):
        body = self._read_json()
        key = body.get("set")
        if not isinstance(key, str) or not key:
            raise ApiError(400, "missing set")
        names = {s.get("name") for s in self.app.station.status().get("sets", [])}
        if key not in names:
            raise ApiError(400, f"unknown set {key}")
        self.app.start(f"deploy {key}", self.app.station.deploy, key)
        self._json(200, {"ok": True})

    def _post_wipe(self, query):
        self._read_json()
        self.app.start("wipe", self.app.station.wipe)
        self._json(200, {"ok": True})

    def _post_sync(self, query):
        self._read_json()
        self.app.start("sync", self.app.station.sync)
        self._json(200, {"ok": True})

    def _post_upload(self, query):
        ctype = self.headers.get("Content-Type", "")
        n = self._length(MAX_UPLOAD + 64 * 1024)
        if ctype.startswith("multipart/form-data"):
            raw = self.rfile.read(n)
            self._body_read = True
            filename, data = _parse_multipart(ctype, raw)
        else:
            filename = unquote(self.headers.get("X-Filename", ""))
            data = None
        name = _safe_filename(filename)
        if not name:
            raise ApiError(400, "missing file name (multipart field or X-Filename header)")
        ext = Path(name).suffix.lower()
        if ext not in ROM_EXTENSIONS:
            raise ApiError(415, f"{ext or 'no extension'} is not a ROM type the carts read "
                                f"({', '.join(sorted(ROM_EXTENSIONS))})")
        if data is None:
            if n > MAX_UPLOAD:
                self.close_connection = True
                raise ApiError(413, "too large, the limit is 4096 KB")
            data = self.rfile.read(n)
            self._body_read = True
        if len(data) > MAX_UPLOAD:
            raise ApiError(413, "too large, the limit is 4096 KB")
        if not data:
            raise ApiError(400, "empty file")
        library = getattr(self.app.station, "library", None)
        if library is None or not hasattr(library, "add_rom"):
            raise ApiError(503, "the library is not available")
        # Keep the original name: add_rom derives the key and stored file from it.
        with tempfile.TemporaryDirectory(prefix="badge-upload-") as tmp:
            path = Path(tmp) / name
            path.write_bytes(data)
            try:
                rom = library.add_rom(path)
            except (ValueError, OSError, _library_error()) as e:
                raise ApiError(400, str(e))
        key = rom if isinstance(rom, str) else getattr(rom, "key", None)
        self.app.station.log(f"Uploaded {name} ({len(data) // 1024} KB).")
        if hasattr(library, "reload"):
            try:
                library.reload()
            except Exception:
                pass
        self._json(200, {"ok": True, "key": key,
                         "name": name, "size": len(data)})


def _safe_filename(name: str) -> str:
    name = name.replace("\\", "/").rsplit("/", 1)[-1].strip()
    name = re.sub(r"[\x00-\x1f\x7f]", "", name)
    if name in ("", ".", "..") or name.startswith("."):
        return ""
    return name[:128]


def _parse_multipart(ctype: str, raw: bytes) -> tuple[str, bytes]:
    msg = BytesParser(policy=HTTP_POLICY).parsebytes(
        b"Content-Type: " + ctype.encode("latin-1") + b"\r\nMIME-Version: 1.0\r\n\r\n" + raw)
    if not msg.is_multipart():
        raise ApiError(400, "bad multipart body")
    for part in msg.iter_parts():
        fn = part.get_filename()
        if fn:
            return fn, part.get_payload(decode=True) or b""
    raise ApiError(400, "no file in the multipart body")


def make_server(station, bind: str, port: int, www: Path = WWW):
    app = App(station, www)
    handler = type("BoundHandler", (Handler,), {"app": app})
    httpd = ThreadingHTTPServer((bind, port), handler)
    httpd.daemon_threads = True
    httpd.app = app
    return httpd


def serve(station, config) -> None:
    bind = getattr(config, "http_bind", "0.0.0.0")
    port = getattr(config, "http_port", 80)
    httpd = make_server(station, bind, port)
    threading.Thread(target=httpd.app.poller, name="poll", daemon=True).start()
    log.info("serving on http://%s:%d/", bind, port)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.app._stop.set()
        httpd.server_close()


# ---------------------------------------------------------------- entry

def _load_config(path: str | None):
    try:
        from . import config as config_mod
        return config_mod.load(Path(path) if path else None)
    except Exception as e:
        log.warning("config: %s: %s; using defaults", type(e).__name__, e)
        try:
            from .config import Config
            return Config()
        except Exception:
            return argparse.Namespace(http_port=80, http_bind="0.0.0.0", fake_badge=None,
                                      library=Path("/var/lib/badge-station/library"))


def _real_station(config):
    """The real Station, or None when it is not usable yet (skeleton)."""
    try:
        from .station import Station
        station = Station(config)
        if not isinstance(station.status(), dict):
            raise TypeError("Station.status() did not return a dict")
        return station
    except Exception as e:
        log.warning("real Station unavailable (%s: %s); serving the demo station",
                    type(e).__name__, e)
        return None


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python3 -m badge_manager.server",
                                 description="Badge station web server")
    ap.add_argument("--config", help="station.toml (default /etc/badge-station/station.toml)")
    ap.add_argument("--port", type=int, help="HTTP port (overrides http_port)")
    ap.add_argument("--bind", help="address to bind (overrides http_bind)")
    ap.add_argument("--fake-badge", metavar="PATH", help="FAT12 image or directory in place of USB")
    ap.add_argument("--demo", action="store_true", help="serve the fake demo station")
    a = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, stream=sys.stderr,
                        format="%(asctime)s %(levelname)s %(message)s")
    config = _load_config(a.config)
    if a.port is not None:
        config.http_port = a.port
    if a.bind:
        config.http_bind = a.bind
    if a.fake_badge:
        config.fake_badge = a.fake_badge
    station = None
    if not (a.demo or os.environ.get("BADGE_STATION_DEMO") == "1"):
        station = _real_station(config)
    if station is None:
        station = DemoStation()
    serve(station, config)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
