"""station.toml -> Config. See station.example.toml; every key has a default."""
from __future__ import annotations
import dataclasses
import os
import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_PATH = Path("/etc/badge-station/station.toml")


@dataclass
class Config:
    library: Path = Path("/var/lib/badge-station/library")
    mount_root: Path = Path("/run/badge-station")
    fake_badge: str | None = None            # image or directory; None = real USB
    http_port: int = 80
    http_bind: str = "0.0.0.0"
    hotspots: list[dict] = field(default_factory=list)   # [{ssid, password}]
    ap_ssid: str = "snouty-badge"
    ap_password: str = "snoutysnouty"
    build_host: str | None = "exedev@animated-badge.exe.xyz"
    build_repo: str = "/home/exedev/snouty-badge"
    sync_command: str | None = None          # default derived from build_host/build_repo
    build_command: str | None = None         # overrides build-job.sh; {id} {out} {prompt_file}
                                             # {name} {flags} are filled in shell-quoted
    build_max_minutes: float = 20            # wall clock per build job, then it is killed
    build_max_usd: float = 5.0               # passed to the agent (build-job.sh --max-usd)
    build_max_turns: int = 40                # passed to the agent (build-job.sh --max-turns)
    log_file: Path | None = None             # default: <library>/../station.log; "" = no file
    source: Path | None = None               # the file this was loaded from, if any

    def default_sync_command(self) -> str:
        src = f"{self.build_repo}/zig-out/firmware/"
        if self.build_host:
            src = f"{self.build_host}:{src}"
        return (f"rsync -a --include='*.uf2' --exclude='*' {src} "
                f"{self.library}/carts/")

    def resolved_log_file(self) -> Path | None:
        if self.log_file is None:
            return Path(self.library).parent / "station.log"
        return None if str(self.log_file) == os.devnull else self.log_file


_PATHS = {"library", "mount_root", "log_file"}


def load(path: Path | None = None) -> Config:
    """PATH, else $BADGE_STATION_CONFIG, else /etc/badge-station/station.toml, else defaults.
    $BADGE_STATION_LIBRARY, when set, overrides `library` (sync.sh passes it on)."""
    cfg = _load(path)
    if os.environ.get("BADGE_STATION_LIBRARY"):
        cfg.library = Path(os.environ["BADGE_STATION_LIBRARY"])
    return cfg


def _load(path: Path | None) -> Config:
    if path is None and os.environ.get("BADGE_STATION_CONFIG"):
        path = Path(os.environ["BADGE_STATION_CONFIG"])
    if path is None and DEFAULT_PATH.exists():
        path = DEFAULT_PATH
    cfg = Config()
    if path is None:
        return cfg
    path = Path(path)
    with open(path, "rb") as fh:
        data = tomllib.load(fh)
    known = {f.name for f in dataclasses.fields(Config)} - {"source"}
    for key, value in data.items():
        if key not in known:
            print(f"badge-station: {path}: unknown key {key!r} ignored", file=sys.stderr)
            continue
        if key in _PATHS and value is not None:
            value = Path(value) if str(value) else Path(os.devnull)
            if not value.is_absolute():
                value = (path.parent / value).resolve()
        if key == "hotspots":
            value = [h for h in value if isinstance(h, dict)]
        setattr(cfg, key, value)
    cfg.source = path
    return cfg
