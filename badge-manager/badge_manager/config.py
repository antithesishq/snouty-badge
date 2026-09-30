"""station.toml -> Config. See station.example.toml; every key has a default."""
from __future__ import annotations
from dataclasses import dataclass, field
from pathlib import Path


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


def load(path: Path | None = None) -> Config:
    """PATH, else $BADGE_STATION_CONFIG, else /etc/badge-station/station.toml, else defaults."""
    raise NotImplementedError
