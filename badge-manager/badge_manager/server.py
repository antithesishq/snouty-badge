"""JSON API and the phone page for the badge station (PLAN.md sections 2 and 8).

    python3 -m badge_manager.server [--config PATH] [--port N]
                                    [--fake-badge PATH] [--demo]

Standard library only: ThreadingHTTPServer, one background thread calling
station.poll() once a second, one worker thread per action so a request
returns at once. --demo (or BADGE_STATION_DEMO=1) serves DemoStation, a fake
that honours the status contract in badge_manager/__init__.py; it is also
selected only by explicit opt-in.

Routes:
  GET  /, /index.html, /static/<name>      the page (www/)
  GET  /api/status[?since=N&wait=S]        Station.status() + "seq" + "qr" (bool)
  GET  /api/log?n=N                        {"log": [...]}
  POST /api/deploy  {"set": key} | {"carts": [...], "roms": [...]}   action
  POST /api/wipe, /api/sync                action
  POST /api/upload  multipart, or the raw file with X-Filename       edit
  POST /api/fit     {"carts": [...], "roms": [...]}
                    -> {bytes, entries, bytes_capacity, entries_capacity,
                        fits, why, files}
  POST /api/sets    {"key"?, "title", "carts", "roms"}
                    -> {"ok": true, "key": key, "set": <status set JSON>}  edit
  DELETE /api/sets/<key>                   -> {"ok": true}                  edit
  POST /api/cart-mode {"cart": key, "mode": "ram"|"xip"}
                    -> {"ok": true, "cart": <status cart JSON>}           edit
  GET  /qr/page.svg, /qr/wifi.svg          QR codes from qrencode (404 without it)
  POST /api/build   {"prompt", "where"?: "auto"|"local"|"remote", "name"?, "no_agent"?}
                    -> {"ok": true, "id"}; 400 bad prompt/name, 409 a build runs,
                       503 builds not ready (status build.why)
  GET  /api/build                          {"job": the running or last job, full log | null}
  GET  /api/build/<id>                     {"job": that job, full log}; 404 unknown
  POST /api/build/cancel                   {"ok": true}; 404 when no build runs
  GET  /builds/<id>/<file>                 preview.gif, preview.png, bench.txt, summary.json
  captive-portal probes and foreign Host headers redirect to the page.

Actions return {"ok": true} at once and run in a worker thread. Actions and
edits answer 409 while another action runs (a deploy must never race a
manifest rewrite), 400 with {"ok": false, "error"} on bad input. Builds run
in the station's own thread under their own lock, never the action lock, so
a deploy can run while a cart builds.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import logging
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import uuid
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
MAX_PROMPT = 2000
BUILD_WHERE = ("auto", "local", "remote")
BUILD_FILE_TYPES = {".gif": "image/gif", ".png": "image/png",
                    ".txt": "text/plain; charset=utf-8", ".json": "application/json"}
CAPTIVE_PATHS = {
    "/generate_204", "/gen_204", "/hotspot-detect.html", "/connecttest.txt",
    "/ncsi.txt", "/success.txt", "/library/test/success.html",
    "/canonical.html",
}
BUILD_ID = re.compile(r"^[0-9]{8}-[0-9]{6}-[a-z0-9][a-z0-9-]{0,30}$")
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


class _DemoSet:
    """Stands in for library.CartSet: key, title, carts, roms."""

    def __init__(self, key: str, title: str, carts: list[str], roms: list[str]):
        self.key, self.title, self.carts, self.roms = key, title, list(carts), list(roms)


def _demo_entries(name: str) -> int:
    up = name.upper() == name and re.fullmatch(r"[A-Z0-9_-]{1,8}(\.[A-Z0-9]{1,3})?", name)
    return 1 if up else 1 + -(-len(name) // 13)


def _demo_short(name: str, taken: set[str]) -> str:
    stem, ext = os.path.splitext(name)
    base = re.sub(r"[^A-Z0-9]", "", stem.upper())[:8] or "ROM"
    ext = re.sub(r"[^A-Z0-9]", "", ext.upper())[:3]
    short, n = base + ("." + ext if ext else ""), 1
    while short in taken:
        tail = f"~{n}"
        short = base[:8 - len(tail)] + tail + ("." + ext if ext else "")
        n += 1
    return short


class _DemoLibrary:
    """Enough of Library for the page: to_json(), selection(), fit_json(), add_rom(),
    save_set(), delete_set(), set_cart_mode(), with the M1 cart variants and ROM globs."""

    VOLUME = 1280 * 1024 - 8 * 512
    ENTRIES = 31

    def __init__(self, root: Path):
        self.root = root
        self.lock = threading.RLock()

        def v(file, size):
            return {"file": file, "size": size, "ok": True, "error": ""}
        self.carts = {
            "snouty": {"title": "Snouty Run", "use": "ram", "roms": [],
                       "variants": {"ram": v("snouty.uf2", 315392),
                                    "xip": v("snouty-xip.uf2", 331776)}},
            "snouty-bugs": {"title": "Snouty Bughunt", "use": "ram", "roms": [],
                            "variants": {"ram": v("snouty-bugs.uf2", 154624)}},
            "snoutenstein": {"title": "Snoutenstein 3D", "use": "ram", "roms": [],
                             "variants": {"ram": v("snoutenstein.uf2", 385024)}},
            "snouty-gear": {"title": "Snouty Gear", "use": "ram", "roms": [".gg", ".sms"],
                            "variants": {"ram": v("snouty-gear.uf2", 357376),
                                         "xip": v("snouty-gear-xip.uf2", 372736)}},
            "snouty-genesis": {"title": "Snouty Genesis", "use": "xip", "roms": [".md", ".bin"],
                               "variants": {"xip": v("snouty-genesis-xip.uf2", 290816)}},
        }
        self.roms = {
            "sonic": {"title": "Sonic GG", "file": "Sonic The Hedgehog (World).gg",
                      "size": 262144, "short": "SONIC.GG"},
        }
        self.sets = {
            "demo": {"title": "Demo reel", "carts": ["snouty", "snouty-bugs", "snoutenstein"],
                     "roms": []},
            "gear": {"title": "Game Gear", "carts": ["snouty-gear", "snouty-bugs", "snouty",
                                                     "snoutenstein"], "roms": ["*.gg"]},
            "genesis": {"title": "Genesis (XIP)", "carts": ["snouty-genesis", "snouty-bugs"],
                        "roms": ["*.md"]},
        }

    # -- lookups

    def _cart_json(self, key: str) -> dict:
        c = self.carts[key]
        var = c["variants"][c["use"]]
        return {"key": key, "title": c["title"], "use": c["use"], "mode": c["use"],
                "file": var["file"], "size": var["size"],
                "variants": {k: dict(x) for k, x in c["variants"].items()},
                "roms": list(c["roms"]), "ok": True, "error": "", "auto": False,
                "build": c.get("build"), "preview": c.get("preview")}

    def _rom_keys(self, pattern: str) -> list[str]:
        if pattern in self.roms:
            return [pattern]
        pat = pattern.lower()
        return [k for k, r in self.roms.items()
                if fnmatch.fnmatchcase(r["file"].lower(), pat) or fnmatch.fnmatchcase(k, pat)]

    def selection(self, carts: list[str], roms: list[str]) -> _DemoSet:
        bad = [k for k in carts if k not in self.carts]
        bad += [k for k in roms if not self._rom_keys(k) and not any(ch in k for ch in "*?[")]
        if bad:
            raise ValueError("not in the library: " + ", ".join(bad))
        return _DemoSet("selection", "Selection", carts, roms)

    def _target(self, target) -> _DemoSet:
        if isinstance(target, str):
            if target not in self.sets:
                raise KeyError(f"no set called {target!r}")
            s = self.sets[target]
            return _DemoSet(target, s["title"], s["carts"], s["roms"])
        return target

    def plan(self, target) -> list[tuple[str, int]]:
        s = self._target(target)
        items = []
        for k in s.carts:
            c = self.carts.get(k)
            if c:
                var = c["variants"][c["use"]]
                items.append((var["file"], var["size"]))
        seen: set[str] = set()
        for pat in s.roms:
            for k in self._rom_keys(pat):
                if k not in seen:
                    seen.add(k)
                    items.append((self.roms[k]["short"], self.roms[k]["size"]))
        return items

    def fit_json(self, target, geom=None) -> dict:
        s = self._target(target)
        items = self.plan(s)
        nbytes = sum(-(-size // 512) * 512 for _, size in items)
        entries = sum(_demo_entries(n) for n, _ in items)
        why = [f"cart {k!r} is not in the library" for k in s.carts if k not in self.carts]
        if nbytes > self.VOLUME:
            why.append(f"{nbytes // 1024} KB is more than the {self.VOLUME // 1024} KB "
                       "the drive holds")
        if entries > self.ENTRIES:
            why.append(f"{entries} root entries, the drive has {self.ENTRIES}")
        return {"bytes": nbytes, "entries": entries, "bytes_capacity": self.VOLUME,
                "entries_capacity": self.ENTRIES, "fits": not why, "why": why,
                "files": [n for n, _ in items]}

    def fit(self, target, geom=None) -> dict:
        return self.fit_json(target, geom)

    # -- edits

    def add_rom(self, path: Path, title: str | None = None) -> str:
        (self.root / "roms").mkdir(parents=True, exist_ok=True)
        dest = self.root / "roms" / path.name
        shutil.copyfile(path, dest)
        key = re.sub(r"[^a-z0-9]+", "-", path.stem.lower()).strip("-") or "rom"
        with self.lock:
            self.roms.pop(key, None)
            taken = {r["short"] for r in self.roms.values()}
            self.roms[key] = {"title": title or path.stem, "file": path.name,
                              "size": dest.stat().st_size, "short": _demo_short(path.name, taken)}
        return key

    def save_set(self, title: str, carts: list[str], roms: list[str],
                 key: str | None = None, *, replace: bool = False) -> _DemoSet:
        title = (title or "").strip()
        if not title:
            raise ValueError("a set needs a title")
        if not carts and not roms:
            raise ValueError("a set needs at least one cart or ROM")
        self.selection(carts, roms)          # validates the keys
        key = key or re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-") or "set"
        with self.lock:
            if key in self.sets and not replace:
                raise ValueError(f"set {key!r} already exists")
            title_slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
            same_title = next((k for k, value in self.sets.items()
                               if k != key and re.sub(r"[^a-z0-9]+", "-", value["title"].lower()).strip("-") == title_slug), None)
            if same_title is not None:
                raise ValueError(f"set {same_title!r} already exists as {self.sets[same_title]['title']!r}")
            if replace and key not in self.sets:
                raise ValueError(f"set {key!r} does not exist")
            self.sets[key] = {"title": title, "carts": list(carts), "roms": list(roms)}
        return _DemoSet(key, title, carts, roms)

    def delete_set(self, key: str) -> None:
        with self.lock:
            if key not in self.sets:
                raise KeyError(f"no set called {key!r}")
            del self.sets[key]

    def set_cart_mode(self, key: str, mode: str) -> dict:
        c = self.carts.get(key)
        if c is None:
            raise KeyError(f"no cart called {key!r}")
        if mode not in c["variants"]:
            raise ValueError(f"{c['title']} has no {mode.upper()} variant")
        c["use"] = mode
        return self._cart_json(key)

    # -- JSON

    def sets_json(self) -> list[dict]:
        out = []
        for k, s in list(self.sets.items()):
            f = self.fit_json(k)
            out.append({"name": k, "title": s["title"], "bytes": f["bytes"],
                        "entries": f["entries"], "bytes_capacity": f["bytes_capacity"],
                        "entries_capacity": f["entries_capacity"], "fits": f["fits"],
                        "why": f["why"], "carts": list(s["carts"]), "roms": list(s["roms"]),
                        "files": f["files"]})
        return out

    def to_json(self) -> dict:
        carts = [self._cart_json(k) for k in self.carts]
        roms = [{"key": k, "title": r["title"], "file": r["file"], "short": r["short"],
                 "size": r["size"], "ok": True, "error": "", "auto": False}
                for k, r in self.roms.items()]
        return {"carts": carts, "roms": roms, "error": ""}


# The demo's build job: a scripted fake of build.py's Jobs (PLAN 9.2, 9.5).

BUILD_FILES = ("preview.gif", "preview.png", "bench.txt", "summary.json")
BUILD_ID = re.compile(r"^[0-9]{8}-[0-9]{6}-[a-z0-9-]{1,40}$")
CART_NAME = re.compile(r"^[a-z][a-z0-9-]{2,23}$")
MAX_PROMPT = 2000
_BUILD_STOP = {"a", "an", "the", "snouty", "cart", "game", "where", "with", "and", "of",
               "that", "in", "on", "to", "for", "is", "it", "you", "your"}


def _prompt_words(prompt: str) -> list[str]:
    words = re.findall(r"[a-z0-9]+", prompt.lower())
    return [w for w in words if w not in _BUILD_STOP] or ["cart"]


def _demo_cart_name(prompt: str, taken) -> str:
    """snouty- + a slug from the prompt's first words, unique among `taken`."""
    slug = ""
    for w in _prompt_words(prompt)[:3]:
        if len("snouty-" + slug + w) > 21:
            slug = slug or w[:14]
            break
        slug = f"{slug}-{w}" if slug else w
    base = "snouty-" + (slug or "cart")[:14]
    name, n = base, 2
    while name in taken:
        name, n = f"{base[:21]}-{n}", n + 1
    return name


def _demo_title(prompt: str) -> str:
    title = ""
    for w in _prompt_words(prompt)[:3]:
        if len(title) + len(w) + 1 > 20:
            title = title or w.capitalize()[:20]
            break
        title = f"{title} {w.capitalize()}".strip()
    return title or "New Cart"


def _gif_lzw(pixels: bytes, min_size: int) -> bytes:
    """GIF's variable-width LZW. Frames here are small, so the table never fills."""
    clear, eoi = 1 << min_size, (1 << min_size) + 1
    table = {bytes([i]): i for i in range(clear)}
    size, nxt = min_size + 1, eoi + 1
    out, acc, bits = bytearray(), 0, 0

    def emit(code):
        nonlocal acc, bits, size
        acc |= code << bits
        bits += size
        while bits >= 8:
            out.append(acc & 0xFF)
            acc >>= 8
            bits -= 8
        if nxt > (1 << size) - 1 and size < 12:
            size += 1

    emit(clear)
    w = pixels[:1]
    for p in pixels[1:]:
        wc = w + bytes([p])
        if wc in table:
            w = wc
            continue
        emit(table[w])
        table[wc] = nxt
        nxt += 1
        w = bytes([p])
    emit(table[w])
    emit(eoi)
    if bits:
        out.append(acc & 0xFF)
    blocks = bytearray()
    for i in range(0, len(out), 255):
        chunk = out[i:i + 255]
        blocks += bytes([len(chunk)]) + chunk
    return bytes(blocks) + b"\x00"


def _demo_frames(seed: int, n: int = 2, side: int = 32) -> list[bytes]:
    """Palette-index frames: a square hopping across a two-tone floor."""
    frames = []
    for f in range(n):
        px = bytearray(side * side)
        for y in range(side):
            for x in range(side):
                px[y * side + x] = 1 if y >= side * 3 // 4 else 0
        x0 = 4 + f * (side - 16) // max(1, n - 1)
        y0 = side * 3 // 4 - 10 - (4 if f % 2 else 0)
        for y in range(y0, y0 + 10):
            for x in range(x0, x0 + 8):
                px[y * side + x] = 2
        px[(y0 + 3) * side + x0 + 5] = 3                  # an eye
        frames.append(bytes(px))
    return frames


def _demo_palette(seed: int) -> list[tuple[int, int, int]]:
    hue = [(236, 112, 160), (90, 170, 240), (120, 210, 120), (240, 180, 60)][seed % 4]
    return [(24, 24, 32), (70, 60, 90), hue, (255, 255, 255)]


def demo_gif(seed: int = 0, side: int = 32) -> bytes:
    """A real, tiny, looping 2-frame GIF89a (4 colours)."""
    pal = _demo_palette(seed)
    out = bytearray(b"GIF89a")
    out += side.to_bytes(2, "little") * 2 + bytes([0xF1, 0, 0])        # 4-entry global table
    out += b"".join(bytes(c) for c in pal)
    out += b"\x21\xFF\x0BNETSCAPE2.0\x03\x01\x00\x00\x00"                  # loop forever
    for px in _demo_frames(seed, 2, side):
        out += b"\x21\xF9\x04\x04" + (40).to_bytes(2, "little") + b"\x00\x00"   # 0.4 s
        out += b"\x2C" + b"\x00\x00\x00\x00" + side.to_bytes(2, "little") * 2 + b"\x00"
        out += b"\x02" + _gif_lzw(px, 2)
    out += b"\x3B"
    return bytes(out)


def demo_png(seed: int = 0, side: int = 32) -> bytes:
    """The GIF's first frame as an RGB PNG."""
    import struct
    import zlib
    pal = _demo_palette(seed)
    px = _demo_frames(seed, 2, side)[0]
    raw = b"".join(b"\x00" + b"".join(bytes(pal[i]) for i in px[y * side:(y + 1) * side])
                   for y in range(side))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


class _DemoCancelled(Exception):
    pass


class DemoStation:
    """Fakes the Station contract: the badge plugs in 3 s after start, three
    sets (one does not fit), deploy takes about 2 s and ends ejected; unplugging
    is simulated 6 s after the eject and a re-plug 4 s after that. start_build()
    runs a scripted job of `build_seconds` (step and agent lines, a generated
    GIF) that ends with a new cart in the library."""

    def __init__(self, library_root: Path | None = None, step: float = 0.4,
                 build_seconds: float = 20.0):
        self._cond = threading.Condition()
        self._build_lock = threading.RLock()
        self._build_seconds = build_seconds
        self._jobs: list[dict] = []              # oldest first
        self._job_thread: threading.Thread | None = None
        self._build_cancel = threading.Event()
        self._lock = threading.Lock()
        self._seq = 0
        self._log: list[dict] = []
        self._start = time.monotonic()
        self._step = step
        self._present = False
        self._ejected_at: float | None = None
        self._unplugged_at: float | None = None
        self._files: list[dict] = []
        self.action: str | None = None
        root = library_root or Path(tempfile.mkdtemp(prefix="badge-demo-lib-"))
        self.library = _DemoLibrary(root)
        self.log("Demo station started. The badge plugs itself in after 3 s.")

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

    def _file_json(self, f: dict) -> dict:
        lib = self.library
        name = f["name"].lower()
        for k, c in lib.carts.items():
            if any(v["file"].lower() == name for v in c["variants"].values()):
                return {**f, "title": c["title"], "kind": "cart"}
        for r in lib.roms.values():
            if r["short"].lower() == name or r["file"].lower() == name:
                return {**f, "title": r["title"], "kind": "rom"}
        return {**f, "title": f["name"], "kind": "other"}

    def share(self) -> dict:
        return {"url": "http://10.42.0.1/", "ssid": "snouty-badge", "password": "snoutysnouty"}

    def status(self) -> dict:
        present = self._present
        on_drive = self._files if present or self._ejected_at is not None else []
        used = sum(-(-f["size"] // 512) * 512 for f in self._files)
        note = ""
        if self._ejected_at is not None:
            note = "Ejected. Unplug the badge."
        elif not present:
            note = "Plug the badge in while it is on its menu."
        with self._cond:
            logs = list(self._log)
            seq = self._seq
        with self.library.lock:
            sets = self.library.sets_json()
            library = self.library.to_json()
        job, builds = self._builds_json()
        names = sorted(f["name"].lower() for f in on_drive)
        badge_set = next((s["name"] for s in sets
                          if names and sorted(n.lower() for n in s["files"]) == names), None)
        return {
            "seq": seq,
            "log_seq": seq,
            "badge": {
                "present": present,
                "device": "/dev/sda" if present else None,
                "mounted": present,
                "ejected": self._ejected_at is not None,
                "files": [self._file_json(f) for f in on_drive],
                "set": badge_set,
                "free_bytes": _DemoLibrary.VOLUME - used if present else None,
                "free_entries": 31 - sum(_demo_entries(f["name"]) for f in self._files)
                if present else None,
                "note": note,
            },
            "busy": self.action is not None,
            "action": self.action,
            "network": {"mode": "ap", "ssid": "snouty-badge", "address": "10.42.0.1",
                        "internet": False},
            "share": self.share(),
            "build": self.build_status(),
            "job": job,
            "builds": builds,
            "sets": sets,
            "library": library,
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

    def _edit(self, fn, *args):
        if not self._lock.acquire(blocking=False):
            raise DemoBusy(self.action or "busy")
        try:
            out = fn(*args)
        finally:
            self._lock.release()
        self._bump()
        return out

    def deploy(self, target) -> None:
        lib = self.library
        if isinstance(target, dict):
            target = lib.selection(target.get("carts", []), target.get("roms", []))
        cs = lib._target(target)
        label = cs.key if isinstance(target, str) else "selection"

        def go():
            if not self._present:
                self.log("No badge plugged in.")
                return
            f = lib.fit_json(cs)
            if not f["fits"]:
                self.log(f"{cs.title} does not fit: " + "; ".join(f["why"]))
                return
            self.log(f"Deploy {cs.title}: wiping the drive.")
            self._files = []
            time.sleep(self._step)
            for name, size in lib.plan(cs):
                time.sleep(self._step)
                self._files.append({"name": name, "size": size})
                self.log(f"Copied {name}.")
            time.sleep(self._step / 2)
            self.log("Synced, unmounted, ejected. Unplug the badge.")
            self._present = False
            self._ejected_at = time.monotonic()
        self._run(f"deploy {label}", go)

    def wipe(self) -> None:
        def go():
            if not self._present:
                self.log("No badge plugged in.")
                return
            time.sleep(self._step)
            self._files = []
            self.log("Wiped the drive.")
        self._run("wipe", go)

    def sync(self) -> None:
        def go():
            self.log("Sync: rsync from exedev@animated-badge.exe.xyz (demo, nothing copied).")
            time.sleep(self._step * 2)
            self.log("Sync done, 0 files changed.")
        self._run("sync", go)

    def save_set(self, title: str, carts: list[str], roms: list[str], key: str | None = None,
                 *, replace: bool = False):
        cs = self._edit(lambda: self.library.save_set(title, carts, roms, key, replace=replace))
        self.log(f"Saved set {cs.title} ({cs.key}).")
        return cs

    def delete_set(self, key: str) -> None:
        self._edit(self.library.delete_set, key)
        self.log(f"Removed set {key}.")

    def set_cart_mode(self, key: str, mode: str) -> dict:
        cart = self._edit(self.library.set_cart_mode, key, mode)
        self.log(f"{cart['title']} deploys its {mode.upper()} variant now.")
        return cart

    # -- the fake build job (PLAN 9.5): same methods Track A's Station exposes

    BUILD_HOST = "exedev@animated-badge.exe.xyz"

    def build_status(self) -> dict:
        return {"local": False, "remote": self.BUILD_HOST, "ready": True, "why": "",
                "where": "remote"}

    def start_build(self, prompt: str, where: str = "auto", name: str | None = None,
                    no_agent: bool = False) -> str:
        """Start the scripted ~20 s job in a thread; returns its id. Prompts that
        contain the word "fail" fail at the second build, like a broken agent edit."""
        prompt = (prompt or "").strip()
        if not prompt:
            raise ValueError("the prompt is empty")
        if len(prompt) > MAX_PROMPT:
            raise ValueError(f"the prompt is longer than {MAX_PROMPT} characters")
        if where not in ("auto", "remote", "local"):
            raise ValueError("where must be auto, local or remote")
        if where == "local":
            raise ValueError("this station cannot build locally")
        if name is not None and not CART_NAME.match(name):
            raise ValueError("a cart name is 3-24 characters: a-z, 0-9 and -, starting "
                             "with a letter")
        with self._build_lock:
            if self._job_thread is not None:
                raise DemoBusy("a build is already running")
            taken = set(self.library.carts) | {j["name"] for j in self._jobs}
            if name is not None and name in taken:
                raise ValueError(f"there is already a cart called {name}")
            name = name or _demo_cart_name(prompt, taken)
            now = time.time()
            base = time.strftime("%Y%m%d-%H%M%S", time.localtime(now)) + "-" + \
                name.removeprefix("snouty-")
            jid, n = base, 2
            while any(j["id"] == jid for j in self._jobs):
                jid, n = f"{base}-{n}", n + 1
            job = {"id": jid, "prompt": prompt, "name": name, "title": _demo_title(prompt),
                   "where": "remote", "host": self.BUILD_HOST, "state": "queued",
                   "started": now, "finished": None, "seconds": 0.0, "exit": None,
                   "error": "", "result": None, "no_agent": bool(no_agent), "log": []}
            self._jobs.append(job)
            self._build_cancel = threading.Event()
            self._job_thread = threading.Thread(target=self._build_run, args=(job,),
                                                name=f"demo-build-{jid}", daemon=True)
            self._job_thread.start()
        self.log(f"Build {jid} queued: {prompt[:60]}")
        return jid

    def _build_line(self, job: dict, line: str) -> None:
        with self._build_lock:
            job["log"].append(line)
        self._bump()

    def _build_script(self, job: dict) -> list[tuple[float, str]]:
        """(seconds before the line, line) summing to about 20 s at build_seconds=20."""
        n, jid = job["name"], job["id"]
        src = f"carts/{n}/cart/src/main.zig"
        words = " ".join(_prompt_words(job["prompt"])[:6])
        lines = [
            (0.6, f"step: git fetch origin main (0.6 s)"),
            (1.0, f"step: worktree build-jobs/{jid}/src at origin/main (1.0 s)"),
            (1.2, "step: submodule sycl-badge with --reference (1.2 s)"),
            (0.4, f"step: name {n}"),
            (0.6, f"step: template copied to carts/{n}, registered in build.zig"),
            (2.4, f"step: template builds (2.4 s)"),
        ]
        if not job["no_agent"]:
            lines += [
                (1.0, f"agent: Read carts/{n}/CLAUDE.md"),
                (0.8, f"agent: Read {src}"),
                (1.4, f"agent: I'll keep the template's loop and add {words}."),
                (1.6, f"agent: Edit {src}"),
                (1.8, f"agent: Bash zig build -Dcart={n}"),
                (1.2, f"agent: Bash node tools/preview.mjs zig-out/bin/{n}.wasm --frames 90 "
                      "--every 30"),
                (0.8, f"agent: Write carts/{n}/summary.json"),
                (0.4, "step: agent done (7 turns, $0.41, 9.0 s)"),
            ]
        lines += [(1.4, f"step: {n} builds (1.4 s)")]
        if re.search(r"\bfail", job["prompt"], re.I):
            return lines + [
                (0.2, f"{src}:88:17: error: use of undeclared identifier 'snout_x'"),
                (0.1, "        w4.rect(snout_x, 40, 8, 8);"),
                (0.1, "                ^~~~~~~"),
                (0.0, "FAIL 3 the cart does not build"),
            ]
        return lines + [
            (1.2, "step: preview.gif, 60 frames (1.2 s)"),
            (1.3, "step: bench 300 frames: worst 9.8 ms busy of 16.7 (1.3 s)"),
            (0.4, f"step: uf2 gate ok, {n}.uf2 ({self._build_size(job) // 1024} KB)"),
            (0.3, f"step: committed to build/{jid}, worktree removed"),
        ]

    @staticmethod
    def _build_size(job: dict) -> int:
        return (96 * 1024 + 37 * len(job["prompt"])) // 512 * 512

    def _build_run(self, job: dict) -> None:
        scale = self._build_seconds / 20.0
        cancel = self._build_cancel
        out = self.library.root / "builds" / job["id"] / "out"
        exit_code, error = 0, ""
        try:
            if cancel.wait(0.5 * scale):
                raise _DemoCancelled()
            with self._build_lock:
                job["state"] = "running"
            self._build_line(job, f"step: job {job['id']} on {self.BUILD_HOST}")
            for delay, line in self._build_script(job):
                if cancel.wait(delay * scale):
                    raise _DemoCancelled()
                if line.startswith("FAIL "):
                    exit_code, error = int(line.split()[1]), line.split(" ", 2)[2]
                    break
                self._build_line(job, line)
            if not exit_code:
                self._build_finish(job, out)
        except _DemoCancelled:
            exit_code, error = 130, "cancelled"
            self._build_line(job, "step: cancelled, worktree removed")
        except Exception as e:                  # a bug in the demo: show it like a failure
            log.error("demo build failed:\n%s", traceback.format_exc())
            exit_code, error = 1, f"{type(e).__name__}: {e}"
        with self._build_lock:
            job["finished"] = time.time()
            job["seconds"] = round(job["finished"] - job["started"], 1)
            job["exit"] = exit_code
            job["error"] = error
            job["state"] = ("done" if exit_code == 0 else
                            "cancelled" if exit_code == 130 else "failed")
            self._job_thread = None
        tail = {"done": f"done, {job['title']} is in the library",
                "cancelled": "cancelled", "failed": f"failed: {error}"}[job["state"]]
        self.log(f"Build {job['id']} {tail}.")

    def _build_finish(self, job: dict, out: Path) -> None:
        """Write out/ like build-job.sh and register the cart like build.py."""
        seed = sum(job["prompt"].encode()) % 4
        size = self._build_size(job)
        out.mkdir(parents=True, exist_ok=True)
        (out / "preview.gif").write_bytes(demo_gif(seed))
        (out / "preview.png").write_bytes(demo_png(seed))
        (out / "bench.txt").write_text(
            f"{job['name']}: 300 frames, busy mean 7.4 ms, worst 9.8 ms of 16.7 ms\n"
            "fits the 60 fps budget with 41% headroom (demo numbers)\n")
        seconds = round(time.time() - job["started"], 1)
        summary = {"name": job["name"], "title": job["title"],
                   "description": job["prompt"][:200], "prompt": job["prompt"],
                   "where": "remote", "seconds": seconds, "agent_turns": 7,
                   "agent_usd": 0.41, "bench_ms": 9.8, "size": size,
                   "files": [f"carts/{job['name']}/cart/src/main.zig",
                             f"carts/{job['name']}/summary.json"],
                   "branch": f"build/{job['id']}"}
        (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        preview = f"/builds/{job['id']}/preview.gif"
        with self.library.lock, self._build_lock:
            self.library.carts[job["name"]] = {
                "title": job["title"], "use": "ram", "roms": [],
                "variants": {"ram": {"file": job["name"] + ".uf2", "size": size,
                                     "ok": True, "error": ""}},
                "build": job["id"], "preview": preview}
            job["result"] = {"cart": job["name"], "uf2": job["name"] + ".uf2", "size": size,
                             "preview": preview, "bench_ms": 9.8,
                             "branch": f"build/{job['id']}"}
        self._build_line(job, f"step: {job['name']}.uf2 added to the library")

    def cancel_build(self) -> bool:
        with self._build_lock:
            if self._job_thread is None:
                return False
            self._build_cancel.set()
        return True

    @staticmethod
    def _job_seconds(job: dict) -> float:
        if job["finished"] is None:
            return round(time.time() - job["started"], 1)
        return job["seconds"]

    def _job_json(self, job: dict, lines: int | None) -> dict:
        seconds = self._job_seconds(job)
        res = job["result"]
        return {"id": job["id"], "prompt": job["prompt"], "name": job["name"],
                "title": job["title"], "where": job["where"], "state": job["state"],
                "started": job["started"], "seconds": seconds, "exit": job["exit"],
                "error": job["error"],
                "log": list(job["log"] if lines is None else job["log"][-lines:]),
                "result": None if res is None else
                {"cart": res["cart"], "preview": res["preview"],
                 "bench_ms": res["bench_ms"], "size": res["size"]}}

    def build_job(self, id: str | None = None) -> dict | None:
        """The current or last job (or job `id`) with its whole log."""
        with self._build_lock:
            if id is None:
                job = self._jobs[-1] if self._jobs else None
            else:
                job = next((j for j in self._jobs if j["id"] == id), None)
            return None if job is None else self._job_json(job, None)

    def build_file(self, id: str, name: str) -> Path | None:
        if name not in BUILD_FILES or not BUILD_ID.match(id or ""):
            return None
        with self._build_lock:
            if not any(j["id"] == id for j in self._jobs):
                return None
        path = self.library.root / "builds" / id / "out" / name
        return path if path.is_file() else None

    def _builds_json(self) -> tuple[dict | None, list[dict]]:
        with self._build_lock:
            job = self._job_json(self._jobs[-1], 40) if self._jobs else None
            rows = [{"id": j["id"], "name": j["name"], "title": j["title"],
                     "state": j["state"], "started": j["started"],
                     "seconds": self._job_seconds(j),
                     "preview": j["result"]["preview"] if j["result"] else None,
                     "bench_ms": j["result"]["bench_ms"] if j["result"] else None,
                     "error": j["error"]}
                    for j in reversed(self._jobs[-10:])]
        return job, rows

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


def _edit_errors() -> tuple[type, ...]:
    """Bad input to an edit (unknown key, empty title): a 400."""
    types: list[type] = [ValueError, KeyError]
    for mod, name in ((".library", "LibraryError"), (".station", "StationError")):
        try:
            types.append(getattr(__import__(f"badge_manager{mod}", fromlist=[name]), name))
        except Exception:
            pass
    return tuple(types)


def _message(e: Exception) -> str:
    if isinstance(e, KeyError) and e.args:
        return str(e.args[0])
    return str(e) or type(e).__name__


def badge_geometry(station):
    """The plugged badge's geometry, else None (the library then uses the badge default)."""
    badge = getattr(station, "_badge", None)
    if badge is None:
        return None
    try:
        return badge.geometry()
    except Exception:
        return None


def wifi_qr_text(ssid: str, password: str) -> str:
    """The Wi-Fi QR payload both camera apps read (WPA, special characters escaped)."""
    def esc(v: str) -> str:
        return re.sub(r'([\\;,:"])', r"\\\1", v)
    return f"WIFI:T:WPA;S:{esc(ssid)};P:{esc(password)};;"


def qr_svg(text: str) -> bytes | None:
    """TEXT as an SVG QR code from qrencode, None when qrencode is missing or fails."""
    exe = shutil.which("qrencode")
    if not exe:
        return None
    try:
        r = subprocess.run([exe, "-t", "SVG", "-o", "-", "-m", "1", text],
                           capture_output=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout if r.returncode == 0 and r.stdout else None


class App:
    """Everything the handler needs, shared across request threads."""

    def __init__(self, station, www: Path = WWW):
        self.station = station
        self.www = www
        self.busy_types = _busy_types(station)
        self.expected_errors = _expected_errors()
        self.edit_errors = _edit_errors()
        self.qr = shutil.which("qrencode") is not None
        self._action_lock = threading.Lock()
        self._stop = threading.Event()
        self._operation_lock = threading.Lock()
        self.operation = None
        library_root = getattr(getattr(station, "config", None), "library", None)
        self._operation_file = Path(library_root) / ".last-operation.json" if library_root else None
        if self._operation_file:
            try:
                saved = json.loads(self._operation_file.read_text())
                if isinstance(saved, dict):
                    if saved.get("state") in ("accepted", "running"):
                        saved.update(state="failed", finished=time.time(),
                                     error="Station restarted before this action finished. Check the badge and log before retrying.")
                    self.operation = saved
            except (OSError, ValueError):
                pass

    def _save_operation(self):
        if not self._operation_file:
            return
        try:
            path = self._operation_file
            path.parent.mkdir(parents=True, exist_ok=True)
            tmp = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
            try:
                tmp.write_text(json.dumps(self.operation))
                tmp.replace(path)
            finally:
                tmp.unlink(missing_ok=True)
        except OSError:
            log.warning("could not persist last operation", exc_info=True)

    def operation_status(self):
        with self._operation_lock:
            return dict(self.operation) if self.operation else None

    def edit(self, fn, *args, **kwargs):
        """Run a manifest edit in the request thread, never while an action runs."""
        if self.station.status().get("busy") or not self._action_lock.acquire(blocking=False):
            raise ApiError(409, "busy")
        try:
            return fn(*args, **kwargs)
        except self.busy_types:
            raise ApiError(409, "busy")
        except self.edit_errors as e:
            raise ApiError(400, _message(e))
        finally:
            self._action_lock.release()

    def share(self) -> dict:
        fn = getattr(self.station, "share", None)
        if callable(fn):
            return fn() or {}
        return self.station.status().get("share") or {}

    @property
    def library(self):
        lib = getattr(self.station, "library", None)
        if lib is None:
            raise ApiError(503, "the library is not available")
        return lib

    def selection(self, body: dict):
        """{"carts", "roms"} -> a CartSet from library.selection(); 400 on bad keys."""
        carts, roms = body.get("carts", []), body.get("roms", [])
        for name, v in (("carts", carts), ("roms", roms)):
            if not isinstance(v, list) or not all(isinstance(x, str) and x for x in v):
                raise ApiError(400, f"{name} must be a list of keys")
        lib = self.status_library()
        known_carts = {c.get("key") for c in lib.get("carts", [])}
        known_roms = {r.get("key") for r in lib.get("roms", [])}
        bad = [k for k in carts if k not in known_carts]
        bad += [k for k in roms if k not in known_roms and not any(ch in k for ch in "*?[")]
        if bad:
            raise ApiError(400, "not in the library: " + ", ".join(bad))
        try:
            return self.library.selection(carts, roms)
        except self.edit_errors as e:
            raise ApiError(400, _message(e))

    def status_library(self) -> dict:
        return self.station.status().get("library") or {}

    # Actions: validated in the request thread, run in a worker thread.
    def start(self, name: str, fn, *args) -> dict:
        st = self.station.status()
        if st.get("busy") or not self._action_lock.acquire(blocking=False):
            raise ApiError(409, "busy")
        with self._operation_lock:
            self.operation = {"id": uuid.uuid4().hex, "name": name, "state": "accepted",
                              "error": None, "started": time.time(), "finished": None}
            accepted = dict(self.operation)
            self._save_operation()

        def work():
            failure = None
            try:
                with self._operation_lock:
                    self.operation["state"] = "running"
                    self._save_operation()
                result = fn(*args)
                if name == "sync" and result is False:
                    failure = "Sync failed. Check the station log and retry after fixing the source."
            except self.busy_types:
                failure = "The station is busy. Try again."
            except self.expected_errors as e:
                failure = str(e)
                log.warning("%s: %s", name, e)
            except Exception as e:
                failure = str(e)
                log.error("%s failed:\n%s", name, traceback.format_exc())
            finally:
                if failure:
                    try:
                        self.station.log(f"{name} failed: {failure}")
                    except Exception:
                        pass
                with self._operation_lock:
                    self.operation.update(state="failed" if failure else "done",
                                          error=failure, finished=time.time())
                    self._save_operation()
                try:
                    self.station.log(f"{name} " + ("failed." if failure else "completed."))
                except Exception:
                    pass
                self._action_lock.release()

        threading.Thread(target=work, name=f"action-{name}", daemon=True).start()
        return accepted

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
            if method in ("post", "put", "delete"):
                self._check_mutation_origin()
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
        if path.startswith("/api/sets/") and len(path) > len("/api/sets/"):
            return "set_item"
        if path == "/api/build/cancel":
            return "build_cancel"
        if path == "/api/build/retry-fetch":
            return "build_retry_fetch"
        if path.startswith("/api/build/") and len(path) > len("/api/build/"):
            return "build_item"
        if path.startswith("/builds/"):
            return "build_file"
        return {"/": "index", "/index.html": "index", "/api/status": "status",
                "/api/log": "log", "/api/deploy": "deploy", "/api/wipe": "wipe",
                "/api/sync": "sync", "/api/upload": "upload", "/api/fit": "fit",
                "/api/sets": "sets", "/api/cart-mode": "cart_mode", "/api/build": "build",
                "/api/builds": "builds",
                "/qr/page.svg": "qr_page", "/qr/wifi.svg": "qr_wifi"}.get(path)

    def _foreign_host(self) -> bool:
        host = (self.headers.get("Host") or "").strip().lower()
        if not host.startswith("["):
            host = host.rsplit(":", 1)[0]
        elif "]" in host:
            host = host[:host.index("]") + 1]
        return bool(host) and not LOCAL_HOSTS.match(host)

    def _check_mutation_origin(self):
        origin = self.headers.get("Origin")
        if origin is None:
            return  # intentional non-browser API callers
        parsed = urlsplit(origin)
        host = self.headers.get("Host", "")
        expected = f"{parsed.scheme}://{host}"
        if self._foreign_host() or parsed.scheme not in ("http", "https") or origin != expected:
            raise ApiError(403, "request origin does not match this station")

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
        if self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() != "application/json" and self.headers.get("Content-Length", "0") != "0":
            raise ApiError(415, "send JSON with Content-Type: application/json")
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
        st["qr"] = self.app.qr
        st["demo"] = isinstance(station, DemoStation)
        st["operation"] = self.app.operation_status()
        self._json(200, st)

    def _get_log(self, query):
        try:
            n = max(1, min(200, int(query.get("n", 200))))
        except ValueError:
            raise ApiError(400, "n must be a number")
        self._json(200, {"log": self.app.station.status().get("log", [])[-n:]})

    def _get_qr_page(self, query):
        self._qr(self.app.share().get("url"))

    def _get_qr_wifi(self, query):
        share = self.app.share()
        ssid, password = share.get("ssid"), share.get("password")
        self._qr(wifi_qr_text(ssid, password or "") if ssid else None)

    def _qr(self, text: str | None):
        if not self.app.qr:
            raise ApiError(404, "qrencode is not installed")
        if not text:
            raise ApiError(404, "nothing to share")
        svg = qr_svg(text)
        if svg is None:
            raise ApiError(404, "qrencode failed")
        self._send(200, svg, "image/svg+xml")

    def _build_method(self, name: str):
        fn = getattr(self.app.station, name, None)
        if not callable(fn):
            raise ApiError(503, "builds are not available on this station")
        return fn

    def _get_build(self, query):
        self._json(200, {"job": self._build_method("build_job")()})

    def _get_build_item(self, query):
        job_id = unquote(urlsplit(self.path).path[len("/api/build/"):])
        job = self._build_method("build_job")(job_id) if BUILD_ID.match(job_id) else None
        if job is None:
            raise ApiError(404, "no such build")
        self._json(200, {"job": job})

    def _get_builds(self, query):
        try:
            n = max(1, min(100, int(query.get("n", 10))))
        except ValueError:
            raise ApiError(400, "n must be a number")
        rows = (self.app.station.builds(n) if hasattr(self.app.station, "builds") else
                self.app.station.status().get("builds", [])[:n])
        self._json(200, {"builds": rows})

    def _get_build_file(self, query):
        parts = unquote(urlsplit(self.path).path[len("/builds/"):]).split("/")
        if len(parts) != 2 or not BUILD_ID.match(parts[0]):
            raise ApiError(404, "not found")
        path = self._build_method("build_file")(parts[0], parts[1])
        if path is None:
            raise ApiError(404, "not found")
        path = Path(path)
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
            with os.fdopen(fd, "rb") as fh:
                info = os.fstat(fh.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_size > 20 * 1024 * 1024:
                    raise ApiError(404, "not found")
                data = fh.read()
        except OSError as e:
            raise ApiError(404, "not found") from e
        self._send(200, data, BUILD_FILE_TYPES.get(path.suffix, "application/octet-stream"))

    # -------------------------------------------------------- POST routes

    def _post_build(self, query):
        body = self._read_json()
        prompt, where = body.get("prompt"), body.get("where", "auto")
        name, no_agent = body.get("name"), body.get("no_agent", False)
        if not isinstance(prompt, str) or not prompt.strip():
            raise ApiError(400, "say what the cart should be")
        if len(prompt.strip()) > MAX_PROMPT:
            raise ApiError(400, f"the prompt is too long (at most {MAX_PROMPT} characters)")
        if where not in BUILD_WHERE:
            raise ApiError(400, "where must be auto, local or remote")
        if name is not None and (not isinstance(name, str) or not name.strip()):
            raise ApiError(400, "name must be a cart name")
        if not isinstance(no_agent, bool):
            raise ApiError(400, "no_agent must be true or false")
        start = self._build_method("start_build")
        try:
            job_id = start(prompt.strip(), where=where, name=name or None, no_agent=no_agent)
        except self.app.busy_types as e:
            raise ApiError(409, _message(e))
        except Exception as e:
            if type(e).__name__ == "BuildNotReady":
                raise ApiError(503, _message(e))
            if isinstance(e, self.app.edit_errors):
                raise ApiError(400, _message(e))
            raise
        self._json(200, {"ok": True, "id": job_id})

    def _post_build_cancel(self, query):
        self._read_json()
        if not self._build_method("cancel_build")():
            raise ApiError(404, "no build is running")
        self._json(200, {"ok": True})

    def _post_build_retry_fetch(self, query):
        body = self._read_json()
        job_id = body.get("id")
        if not isinstance(job_id, str) or not BUILD_ID.fullmatch(job_id):
            raise ApiError(400, "give a valid build ID")
        jobs = getattr(self.app.station, "jobs", None)
        if jobs is None:
            raise ApiError(503, "remote build recovery is unavailable")
        from .build import BuildBusy, BuildError
        try:
            job = jobs.retry_fetch(job_id)
        except BuildBusy as e:
            raise ApiError(409, str(e)) from e
        except BuildError as e:
            raise ApiError(400, str(e)) from e
        self._json(200, {"ok": True, "id": job.id})


    def _post_deploy(self, query):
        body = self._read_json()
        if "set" in body:
            key = body.get("set")
            if not isinstance(key, str) or not key:
                raise ApiError(400, "set must be a set key")
            names = {s.get("name") for s in self.app.station.status().get("sets", [])}
            if key not in names:
                raise ApiError(400, f"unknown set {key}")
            operation = self.app.start(f"deploy {key}", self.app.station.deploy, key)
        elif "carts" in body or "roms" in body:
            cart_set = self.app.selection(body)
            if not cart_set.carts and not cart_set.roms:
                raise ApiError(400, "nothing selected")
            operation = self.app.start("deploy selection", self.app.station.deploy, cart_set)
        else:
            raise ApiError(400, "missing set (or carts and roms)")
        self._json(200, {"ok": True, "operation": operation})

    def _post_fit(self, query):
        body = self._read_json()
        cart_set = self.app.selection(body)
        try:
            rep = self.app.library.fit_json(cart_set, badge_geometry(self.app.station))
        except self.app.edit_errors as e:
            raise ApiError(400, _message(e))
        self._json(200, rep)

    def _post_sets(self, query):
        body = self._read_json()
        title, key = body.get("title"), body.get("key")
        replace = body.get("replace", False)
        if not isinstance(replace, bool):
            raise ApiError(400, "replace must be true or false")
        if replace and not key:
            raise ApiError(400, "replace needs an existing set key")
        carts, roms = body.get("carts", []), body.get("roms", [])
        if not isinstance(title, str) or not title.strip():
            raise ApiError(400, "a set needs a title")
        if key is not None and (not isinstance(key, str) or not key):
            raise ApiError(400, "key must be a string")
        for name, v in (("carts", carts), ("roms", roms)):
            if not isinstance(v, list) or not all(isinstance(x, str) and x for x in v):
                raise ApiError(400, f"{name} must be a list of keys")
        try:
            cs = self.app.edit(self.app.station.save_set, title.strip(), carts, roms, key,
                               replace=replace)
        except ApiError as e:
            if not replace and "already exists" in e.error:
                existing_key = key or re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-") or "set"
                title_slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
                existing = next((s for s in self.app.station.status().get("sets", [])
                                 if s.get("name") == existing_key or
                                 re.sub(r"[^a-z0-9]+", "-", str(s.get("title", "")).lower()).strip("-") == title_slug), None)
                self._json(409, {"ok": False, "error": e.error, "existing": existing})
                return
            raise
        key = getattr(cs, "key", None) or key
        sets = self.app.station.status().get("sets", [])
        self._json(200, {"ok": True, "key": key,
                         "set": next((s for s in sets if s.get("name") == key), None)})

    def _delete_set_item(self, query):
        self._drain()
        key = unquote(urlsplit(self.path).path[len("/api/sets/"):])
        if not key or "/" in key:
            raise ApiError(400, "bad set key")
        self.app.edit(self.app.station.delete_set, key)
        self._json(200, {"ok": True})

    def _post_cart_mode(self, query):
        body = self._read_json()
        cart, mode = body.get("cart"), body.get("mode")
        if not isinstance(cart, str) or not cart:
            raise ApiError(400, "missing cart")
        if mode not in ("ram", "xip"):
            raise ApiError(400, "mode must be ram or xip")
        self.app.edit(self.app.station.set_cart_mode, cart, mode)
        carts = self.app.status_library().get("carts", [])
        self._json(200, {"ok": True,
                         "cart": next((c for c in carts if c.get("key") == cart), None)})

    def _post_wipe(self, query):
        self._read_json()
        operation = self.app.start("wipe", self.app.station.wipe)
        self._json(200, {"ok": True, "operation": operation})

    def _post_sync(self, query):
        self._read_json()
        operation = self.app.start("sync", self.app.station.sync)
        self._json(200, {"ok": True, "operation": operation})

    def _post_upload(self, query):
        if self.app.station.status().get("busy") or self.app._action_lock.locked():
            raise ApiError(409, "busy")
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
                rom = self.app.edit(library.add_rom, path)
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
    from . import config as config_mod
    return config_mod.load(Path(path) if path else None)


def _real_station(config):
    from .station import Station
    station = Station(config)
    if not isinstance(station.status(), dict):
        raise TypeError("Station.status() did not return a dict")
    return station


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
    try:
        config = _load_config(a.config)
    except Exception as e:
        log.error("station configuration failed: %s: %s", type(e).__name__, e)
        return 1
    if a.port is not None:
        config.http_port = a.port
    if a.bind:
        config.http_bind = a.bind
    if a.fake_badge:
        config.fake_badge = a.fake_badge
    if a.demo or os.environ.get("BADGE_STATION_DEMO") == "1":
        station = DemoStation()
    else:
        try:
            station = _real_station(config)
        except Exception as e:
            log.error("station initialization failed: %s: %s", type(e).__name__, e)
            return 1
    serve(station, config)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
