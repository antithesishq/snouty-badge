"""Station: the one object the CLI and the server share.

- poll(): called ~1/s by a background thread (server) or once (CLI);
  detects plug/unplug, mounts on plug, reads contents, updates status.
- deploy(set_key): fit check -> wipe -> copy UF2s then ROMs -> sync ->
  eject. Serialized by a lock; raises StationBusy if another action runs.
- wipe(), sync() likewise. Every step appends to the log ring (200 lines);
  subscribers (the server's long-poll) are notified via a Condition.
- status(): the dict in badge_manager/__init__.py.
- network(): mode/ssid/address/internet from `nmcli -t` when available.
"""
from __future__ import annotations
from .config import Config


class StationBusy(Exception):
    pass


class Station:
    def __init__(self, config: Config): ...
    def poll(self) -> None: ...
    def status(self) -> dict: ...
    def deploy(self, set_key: str) -> None: ...
    def wipe(self) -> None: ...
    def sync(self) -> None: ...            # runs config.sync_command (rsync from the build host)
    def log(self, msg: str) -> None: ...
    def wait_for_change(self, since: int, timeout: float) -> int: ...  # log length based
