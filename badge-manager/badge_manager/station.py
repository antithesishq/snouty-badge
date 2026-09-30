"""Station: the one object the CLI and the server share.

- poll(): called ~1/s by a background thread (server) or once (CLI);
  detects plug/unplug, mounts on plug, reads contents, updates status.
- deploy(target): a set key or an ad-hoc CartSet; fit check -> wipe ->
  copy UF2s then ROMs -> sync -> eject. Serialized by a lock; raises StationBusy if another action runs.
- wipe(), sync() likewise. Every step appends to the log ring (200 lines);
  subscribers (the server's long-poll) are notified via a Condition.
- set_cart_mode(), save_set(), delete_set(): manifest edits, one log line each.
- status(): the dict in badge_manager/__init__.py; share() is its "share" part.
- network(): mode/ssid/address/internet from `nmcli -t` when available.

Actions are serialized in-process by a Lock and across processes (server
and an ssh `badge` command) by flock on <mount_root>/station.lock. The log
is also appended to config.resolved_log_file() so `badge log` and a
restarted server see the history.
"""
from __future__ import annotations
import contextlib
import fcntl
import os
import re
import shlex
import shutil
import socket
import subprocess
import tempfile
import threading
import time
from collections import deque
from pathlib import Path
from typing import Callable, Iterator

from . import fat12
from .config import Config
from .device import Badge, DeviceError, find_badge
from .library import CUSTOM, CartSet, Library, LibraryError

LOG_LINES = 200
FAKE_REPLUG_S = 3.0          # a fake badge "comes back" this long after an eject
NET_CACHE_S = 5.0
INTERNET_CACHE_S = 30.0
SYNC_TIMEOUT_S = 600
SYNC_SH = Path(__file__).resolve().parents[1] / "sync.sh"   # Track B's script


class StationError(Exception):
    pass


class StationBusy(StationError):
    pass


class NoBadge(StationError):
    pass


class DoesNotFit(StationError):
    pass


def kb(n: int) -> str:
    return f"{-(-n // 1024):,} KB"


def _nmcli_fields(line: str) -> list[str]:
    return [f.replace("\\:", ":").replace("\\\\", "\\") for f in re.split(r"(?<!\\):", line)]


class Station:
    def __init__(self, config: Config, on_log: Callable[[str], None] | None = None,
                 persist_log: bool = True):
        """ON_LOG gets every new log line; PERSIST_LOG=False keeps new lines out of
        the log file (the CLI's read-only commands, so their poll adds no noise)."""
        self.config = config
        self.persist_log = persist_log
        self.on_log = on_log
        self.library = Library(config.library)
        self._action = threading.Lock()
        self._state = threading.Condition(threading.RLock())
        self._log: deque[dict] = deque(maxlen=LOG_LINES)
        self._seq = 0
        self._busy_action: str | None = None
        self._badge: Badge | None = None
        self._info = self._no_badge_info()
        self._ejected: tuple[str, float] | None = None
        self._mount_error: tuple[str, str] | None = None
        self._net: tuple[float, dict] | None = None
        self._inet: tuple[float, bool] | None = None
        self._build: dict | None = None
        self._log_file = config.resolved_log_file()
        self._load_log_tail()

    # -- log --------------------------------------------------------------

    def log(self, msg: str) -> None:
        entry = {"t": time.time(), "msg": msg}
        with self._state:
            self._log.append(entry)
            self._seq += 1
            self._state.notify_all()
        if self._log_file and self.persist_log:
            try:
                with open(self._log_file, "a") as fh:
                    fh.write(f"{entry['t']:.3f}\t{msg}\n")
            except OSError:
                pass
        if self.on_log:
            self.on_log(msg)

    def _load_log_tail(self) -> None:
        if not self._log_file:
            return
        try:
            lines = self._log_file.read_text().splitlines()[-LOG_LINES:]
        except OSError:
            return
        for line in lines:
            t, _, msg = line.partition("\t")
            try:
                self._log.append({"t": float(t), "msg": msg})
            except ValueError:
                continue
        self._seq = len(self._log)

    def log_lines(self, n: int = LOG_LINES) -> list[dict]:
        with self._state:
            return list(self._log)[-n:]

    def _changed(self) -> None:
        """Bump the change counter (status()["log_seq"]) and wake wait_for_change()."""
        with self._state:
            self._seq += 1
            self._state.notify_all()

    def wait_for_change(self, since: int, timeout: float) -> int:
        """Block until the change counter passes SINCE (or TIMEOUT); return it.

        The counter is monotonic: it counts log lines and every other status
        change (busy flips, plug/unplug/eject, network mode)."""
        with self._state:
            self._state.wait_for(lambda: self._seq > since, timeout)
            return self._seq

    # -- badge state --------------------------------------------------------

    @staticmethod
    def _no_badge_info(note: str = "no badge plugged in") -> dict:
        return {"present": False, "device": None, "mounted": False, "files": [], "set": None,
                "free_bytes": None, "free_entries": None, "note": note, "ejected": False}

    def poll(self) -> None:
        """Detect plug/unplug; mount and read a newly plugged badge. Skipped while an action runs."""
        if self._action.locked():
            return
        self._poll()

    def _poll(self) -> None:
        try:
            b = find_badge(self.config.fake_badge, self.config.mount_root)
        except OSError:
            b = None
        with self._state:
            if self._ejected and not self._ejected_gone(b):
                return
            cur = self._badge
            if cur is not None and (b is None or b.device != cur.device):
                self._unplugged(cur)
                cur = None
            if b is None and self._info["present"] and cur is None:
                self._info = self._no_badge_info()   # a badge that never mounted went away
                self._mount_error = None
                self._changed()
            if b is not None and cur is None:
                self._plugged(b)

    def _ejected_gone(self, b: Badge | None) -> bool:
        """True once an ejected badge has left (real) or FAKE_REPLUG_S passed (fake)."""
        dev, t = self._ejected
        if b is not None and b.device == dev and not (
                b.fake and time.monotonic() - t >= FAKE_REPLUG_S):
            return False
        self._ejected = None
        self._info = self._no_badge_info()
        self._changed()
        if b is None or b.device != dev:
            self.log("badge unplugged")
        return True

    def _unplugged(self, b: Badge) -> None:
        with contextlib.suppress(DeviceError, OSError):
            b.unmount()
        self._badge = None
        self._info = self._no_badge_info()
        self.log("badge unplugged")

    def _plugged(self, b: Badge) -> None:
        try:
            b.mount()
            self._badge = b
            self._mount_error = None
            self._refresh()
        except DeviceError as e:
            self._badge = None
            self._info = {**self._no_badge_info(f"found but not mounted: {e}"),
                          "present": True, "device": b.device}
            if self._mount_error != (b.device, str(e)):
                self._mount_error = (b.device, str(e))
                self._changed()
                self.log(f"badge found on {b.device} but it could not be mounted: {e}")
            return
        n, free = len(self._info["files"]), self._info["free_bytes"] or 0
        self.log(f"badge plugged in: {n} file{'s' if n != 1 else ''}, {fat12.kb_down(free)} free")

    def _refresh(self) -> None:
        """Re-read the plugged badge's files and free space into the status."""
        b = self._badge
        if b is None:
            return
        files, on = self.library.identify([{"name": e.name, "size": e.size} for e in b.listdir()])
        self._info = {"present": True, "device": b.device, "mounted": True, "files": files,
                      "set": on, "free_bytes": b.free_bytes(), "free_entries": b.free_entries(),
                      "note": "ready", "ejected": False}
        self._changed()

    def _require_badge(self) -> Badge:
        self._poll()
        with self._state:
            if self._badge is None:
                raise NoBadge("no badge: " + self._info["note"])
            return self._badge

    def _mark_ejected(self, b: Badge, files: list[dict]) -> None:
        with self._state:
            self._badge = None
            self._ejected = (b.device, time.monotonic())
            files, on = self.library.identify(files)
            self._info = {"present": False, "device": b.device, "mounted": False,
                          "files": files, "set": on, "free_bytes": None, "free_entries": None,
                          "note": "ejected, unplug the badge", "ejected": True}
            self._changed()

    # -- actions ------------------------------------------------------------

    def _lock_path(self) -> Path:
        root = Path(self.config.mount_root)
        try:
            root.mkdir(parents=True, exist_ok=True)
            if os.access(root, os.W_OK):
                return root / "station.lock"
        except OSError:
            pass
        return Path(tempfile.gettempdir()) / "badge-station.lock"

    def _flock(self) -> int | None:
        """An flock'd fd, None when no lock file can be opened; raises StationBusy if held."""
        p = self._lock_path()
        fd = None
        for flags in (os.O_RDWR | os.O_CREAT, os.O_RDONLY):
            try:
                fd = os.open(p, flags, 0o666)
                break
            except OSError:
                continue
        if fd is None:
            return None
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(fd)
            raise StationBusy("another badge command is running")
        return fd

    @contextlib.contextmanager
    def _busy(self, action: str) -> Iterator[None]:
        if not self._action.acquire(blocking=False):
            raise StationBusy(f"busy: {self._busy_action or 'another action'}")
        try:
            fd = self._flock()
        except StationBusy:
            self._action.release()
            raise
        with self._state:
            self._busy_action = action
            self._changed()
        try:
            yield
        finally:
            with self._state:
                self._busy_action = None
                self._changed()
            if fd is not None:
                os.close(fd)
            self._action.release()

    def deploy(self, target: str | CartSet) -> None:
        """Wipe the badge, copy TARGET's (set key or ad-hoc CartSet) UF2s then ROMs, sync, eject."""
        adhoc = isinstance(target, CartSet)
        label = ("selection" if target.key == CUSTOM else target.key) if adhoc else target
        with self._busy(f"deploy {label}"):
            t0 = time.monotonic()
            s = target if adhoc else self.library.sets.get(target)
            if s is None:
                raise StationError(f"no set called {target!r}")
            b = self._require_badge()
            try:
                items = self.library.plan(s)
            except LibraryError as e:
                self.log(f"cannot deploy {s.title}: {e}")
                raise DoesNotFit(str(e)) from e
            rep = fat12.fit([(i.name, i.size) for i in items], geom=self._geometry(b))
            self.log(f"deploying {s.title}: {len(items)} files, {kb(rep.bytes_used)}, "
                     f"{rep.entries_used} of {rep.entries_capacity} root entries")
            if not rep.fits:
                self.log(f"{s.title} does not fit: {'; '.join(rep.why)}")
                raise DoesNotFit("; ".join(rep.why))
            try:
                self._wipe(b)
                for it in items:
                    self.log(f"copying {it.name} ({kb(it.size)})")
                    b.copy(it.src, it.name)
                os.sync()
                files = self._verify(b, [i.name for i in items])
                self.log("ejecting the badge")
                b.eject()
            except DeviceError as e:
                self._fail("deploy", e)
            self._mark_ejected(b, files)
            self.log(f"done in {time.monotonic() - t0:.1f} s, unplug the badge")

    def _geometry(self, b: Badge) -> fat12.Geometry:
        try:
            return b.geometry()
        except DeviceError:
            return fat12.geometry()

    def _wipe(self, b: Badge) -> None:
        self.log("wiping the badge")
        n = b.wipe()
        self.log(f"wiped, {n} old file{'s' if n != 1 else ''} removed")

    def _verify(self, b: Badge, names: list[str]) -> list[dict]:
        files = b.listdir()
        have = {e.name.lower() for e in files}
        missing = [n for n in names if n.lower() not in have]
        if missing:
            raise DeviceError("missing after copy: " + ", ".join(missing))
        frag = b.fragmented()
        if frag:
            self.log("warning: not contiguous on the drive: " + ", ".join(frag))
        self.log(f"all {len(names)} files on the badge, {fat12.kb_down(b.free_bytes())} free, "
                 f"{b.free_entries()} root entries free")
        return [{"name": e.name, "size": e.size} for e in files]

    def _fail(self, what: str, e: Exception) -> None:
        self.log(f"{what} failed: {e}")
        with self._state, contextlib.suppress(DeviceError, OSError):
            self._refresh()
        raise StationError(f"{what} failed: {e}") from e

    def wipe(self) -> None:
        """Delete every file on the badge, then eject."""
        with self._busy("wipe"):
            t0 = time.monotonic()
            b = self._require_badge()
            try:
                self._wipe(b)
                os.sync()
                self.log("ejecting the badge")
                b.eject()
            except DeviceError as e:
                self._fail("wipe", e)
            self._mark_ejected(b, [])
            self.log(f"done in {time.monotonic() - t0:.1f} s, unplug the badge")

    def sync(self) -> bool:
        """Run config.sync_command (rsync from the build host), stream it to the log, reload."""
        with self._busy("sync"):
            cmd, env = self._sync_command()
            (Path(self.config.library) / "carts").mkdir(parents=True, exist_ok=True)
            self.log(f"syncing the library: {cmd}")
            rc = self._run_streamed(cmd, env)
            if rc != 0:
                self.log(f"sync failed (exit {rc})")
            with self._state:
                self.library.reload()
            lib = self.library
            self.log(f"library: {len(lib.carts)} carts, {len(lib.roms)} ROMs, {len(lib.sets)} sets")
            return rc == 0

    def _sync_command(self) -> tuple[str, dict]:
        """config.sync_command, else badge-manager/sync.sh HOST REPO, else a bare rsync."""
        env = dict(os.environ, BADGE_STATION_LIBRARY=str(self.config.library))
        if self.config.source:
            env["BADGE_STATION_CONFIG"] = str(self.config.source)
        if self.config.sync_command:
            return self.config.sync_command, env
        if SYNC_SH.exists():
            host = self.config.build_host or "local"
            return (f"bash {shlex.quote(str(SYNC_SH))} {shlex.quote(host)} "
                    f"{shlex.quote(self.config.build_repo)}"), env
        return self.config.default_sync_command(), env

    def _run_streamed(self, cmd: str, env: dict | None = None) -> int:
        try:
            p = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, env=env,
                                 stderr=subprocess.STDOUT, text=True, errors="replace")
        except OSError as e:
            self.log(f"could not start: {e}")
            return 127
        timer = threading.Timer(SYNC_TIMEOUT_S, p.kill)
        timer.start()
        try:
            for line in p.stdout:
                if line.strip():
                    self.log(line.rstrip()[:300])
            return p.wait()
        finally:
            timer.cancel()

    def reload_library(self) -> None:
        with self._state:
            self.library.reload()

    # -- library edits (manifest only, the drive is not touched) ----------------

    def set_cart_mode(self, key: str, mode: str):
        """Make sets deploy cart KEY as MODE ("ram" | "xip"); returns the Cart."""
        with self._state:
            c = self.library.set_cart_mode(key, mode)
            self._changed()
        self.log(f"{key} now deploys as {mode.upper()}")
        return c

    def save_set(self, title: str, carts: list[str], roms: list[str],
                 key: str | None = None) -> CartSet:
        """Create or replace a set in the manifest; returns it."""
        with self._state:
            s = self.library.save_set(title, carts, roms, key)
            self._changed()
        n = len(s.carts)
        self.log(f"saved set {s.title} ({s.key}): {n} cart{'s' if n != 1 else ''}"
                 + "".join(f", {r}" for r in s.roms))
        return s

    def delete_set(self, key: str) -> None:
        with self._state:
            self.library.delete_set(key)
            self._changed()
        self.log(f"removed set {key}")

    # -- network and build probes ---------------------------------------------

    def network(self) -> dict:
        now = time.monotonic()
        if self._net and now - self._net[0] < NET_CACHE_S:
            return dict(self._net[1])
        net = self._nmcli_network() if shutil.which("nmcli") else None
        if net is None:
            net = {"mode": "none", "ssid": None, "address": self._local_address()}
        net["internet"] = self._internet()
        old = self._net[1] if self._net else None
        self._net = (now, net)
        if old is not None and (old["mode"], old["internet"]) != (net["mode"], net["internet"]):
            self._changed()
        return dict(net)

    def _nmcli(self, *args: str) -> str:
        r = subprocess.run(["nmcli", "-t", *args], capture_output=True, text=True, timeout=5)
        return r.stdout if r.returncode == 0 else ""

    def _nmcli_network(self) -> dict | None:
        try:
            active = self._nmcli("-f", "NAME,TYPE,DEVICE", "connection", "show", "--active")
        except (OSError, subprocess.SubprocessError):
            return None
        wifi = wired = None
        for line in active.splitlines():
            f = _nmcli_fields(line)
            if len(f) < 3:
                continue
            name, typ, dev = f[0], f[1], f[2]
            if "wireless" in typ or typ == "wifi":
                wifi = wifi or (name, dev)
            elif "ethernet" in typ:
                wired = wired or (name, dev)
        if wifi:
            name, dev = wifi
            ap = name in ("snouty-badge", self.config.ap_ssid)
            return {"mode": "ap" if ap else "hotspot",
                    "ssid": self.config.ap_ssid if ap else name, "address": self._dev_address(dev)}
        if wired:
            return {"mode": "wired", "ssid": None, "address": self._dev_address(wired[1])}
        return {"mode": "none", "ssid": None, "address": None}

    def _dev_address(self, dev: str) -> str | None:
        try:
            out = self._nmcli("-f", "IP4.ADDRESS", "device", "show", dev)
        except (OSError, subprocess.SubprocessError):
            return None
        for line in out.splitlines():
            _, _, val = line.partition(":")
            if val:
                return val.split("/")[0]
        return None

    @staticmethod
    def _local_address() -> str | None:
        """The address of the default route's interface (no packet is sent)."""
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.connect(("1.1.1.1", 443))
                return s.getsockname()[0]
        except OSError:
            return None

    def _internet(self) -> bool:
        now = time.monotonic()
        if self._inet and now - self._inet[0] < INTERNET_CACHE_S:
            return self._inet[1]
        try:
            socket.create_connection(("1.1.1.1", 443), timeout=1).close()
            ok = True
        except OSError:
            ok = False
        self._inet = (now, ok)
        return ok

    def build_info(self) -> dict:
        if self._build is None:
            self._build = {"local": self._local_build_ok(), "remote": self.config.build_host}
        return dict(self._build)

    @staticmethod
    def _local_build_ok() -> bool:
        """>= 6 GB RAM and a Zig under ~/.local (section 6 of PLAN.md)."""
        try:
            mem = Path("/proc/meminfo").read_text()
            kb_total = int(re.search(r"MemTotal:\s+(\d+)", mem).group(1))
        except (OSError, AttributeError, ValueError):
            return False
        home = Path.home() / ".local"
        zig = (home / "zig" / "zig").exists() or (home / "bin" / "zig").exists()
        return kb_total >= 6 * 1024 * 1024 * 0.95 and zig

    def share(self, net: dict | None = None) -> dict:
        """{"url", "ssid", "password"}: how a second phone reaches the page."""
        net = net or self.network()
        if net["mode"] == "ap":
            return {"url": self._url(net.get("address") or "10.42.0.1"),
                    "ssid": self.config.ap_ssid, "password": self.config.ap_password}
        addr = net.get("address")
        return {"url": self._url(addr) if addr else None, "ssid": None, "password": None}

    def _url(self, addr: str) -> str:
        port = getattr(self.config, "http_port", 80)
        return f"http://{addr}/" if port == 80 else f"http://{addr}:{port}/"

    # -- status ---------------------------------------------------------------

    def status(self) -> dict:
        net, build = self.network(), self.build_info()
        with self._state:
            geom = None
            if self._badge is not None:
                with contextlib.suppress(DeviceError, OSError):
                    geom = self._badge.geometry()
            lib = self.library.to_json(geom)
            return {"badge": dict(self._info), "busy": self._busy_action is not None,
                    "action": self._busy_action, "network": net,
                    "share": self.share(net), "build": build,
                    "sets": lib["sets"], "library": lib["library"],
                    "log": list(self._log), "log_seq": self._seq}
