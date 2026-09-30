"""The station's collection: library/manifest.toml, library/carts/*.uf2, library/roms/*.

manifest.toml:
  [carts.snouty]            # key = drive file stem; file defaults to carts/<key>.uf2
  title = "Snouty Run"
  mode = "ram"              # or "xip"; informational + validated with uf2 block addresses
  roms = []                 # extensions this cart reads from the drive, e.g. [".gg", ".sms"]

  [roms.sonic]
  file = "roms/Sonic The Hedgehog (World).gg"
  title = "Sonic GG"
  short = "SONIC.GG"        # optional; else fat12.short_name_for

  [sets.demo]
  title = "Demo reel"
  carts = ["snouty", "snouty-bugs", "snoutenstein", "snouty-maze"]
  roms = []
"""
from __future__ import annotations
from dataclasses import dataclass, field
from pathlib import Path
from .fat12 import FitReport


@dataclass
class Cart:
    key: str
    title: str
    file: Path
    mode: str = "ram"
    roms: list[str] = field(default_factory=list)
    size: int = 0


@dataclass
class Rom:
    key: str
    title: str
    file: Path
    short: str = ""
    size: int = 0


@dataclass
class CartSet:
    key: str
    title: str
    carts: list[str]
    roms: list[str]


@dataclass
class PlanItem:
    src: Path
    name: str            # name on the drive
    size: int


class Library:
    def __init__(self, root: Path): ...
    def reload(self) -> None: ...            # re-read manifest and file sizes
    carts: dict[str, Cart]
    roms: dict[str, Rom]
    sets: dict[str, CartSet]
    def plan(self, set_key: str) -> list[PlanItem]: ...   # UF2s first, then ROMs
    def fit(self, set_key: str) -> FitReport: ...
    def validate_uf2(self, path: Path) -> str: ...        # "ram" | "xip", raises on mixed/malformed (tools/uf2_info.py logic)
    def to_json(self) -> dict: ...                         # the "sets"/"library" parts of Station.status()
