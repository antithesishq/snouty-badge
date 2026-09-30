"""Shared test fixtures: tiny UF2s, a temporary library, a config."""
from __future__ import annotations
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]          # badge-manager/
REPO = ROOT.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from badge_manager.config import Config  # noqa: E402

MAGIC0, MAGIC1, MAGIC_END = 0x0A324655, 0x9E5D5157, 0x0AB16F30
FAMILY = 0xE48BFF59
RAM_BASE, XIP_BASE = 0x20035100, 0x101C0000


def uf2_bytes(addrs: list[int]) -> bytes:
    out = bytearray()
    for i, a in enumerate(addrs):
        b = bytearray(512)
        struct.pack_into("<8I", b, 0, MAGIC0, MAGIC1, 0x2000, a, 256, i, len(addrs), FAMILY)
        b[32:32 + 256] = bytes([i & 0xFF]) * 256
        struct.pack_into("<I", b, 508, MAGIC_END)
        out += b
    return bytes(out)


def make_uf2(path: Path, kind: str = "ram", blocks: int = 4) -> Path:
    """A valid tiny UF2: kind ram, xip, or mixed (rejected by the loader)."""
    if kind == "ram":
        addrs = [RAM_BASE + 256 * i for i in range(blocks)]
    elif kind == "xip":
        addrs = [XIP_BASE + 256 * i for i in range(blocks)]
    else:
        addrs = [XIP_BASE, RAM_BASE] + [RAM_BASE + 256 * i for i in range(1, blocks - 1)]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(uf2_bytes(addrs))
    return path


MANIFEST = '''
[carts.snouty]
title = "Snouty Run"
mode = "ram"
roms = []
notes = "kept on rewrite"

[carts.snouty-bugs]
title = "Snouty Bughunt"

[carts.snouty-gear]
title = "Snouty Gear"
roms = [".gg"]

[carts.genesis-xip]
title = "Snouty Genesis"
mode = "xip"

[roms.sonic]
file = "roms/Sonic The Hedgehog (World).gg"
title = "Sonic GG"

[roms.sonic2]
file = "roms/Sonic The Hedgehog 2 (World).gg"
title = "Sonic 2"

[sets.demo]
title = "Demo reel"
carts = ["snouty", "snouty-bugs"]

[sets.gear]
title = "Game Gear Sonic"
carts = ["snouty-gear"]
roms = ["sonic", "sonic2"]

[sets.broken]
title = "Broken"
carts = ["snouty", "missing-cart", "genesis-xip"]
roms = ["nope"]
'''


def make_library(root: Path) -> Path:
    """carts: snouty, snouty-bugs, snouty-gear (RAM), genesis-xip (XIP);
    roms: two Sonic files; sets demo, gear, broken (unknown cart and ROM)."""
    make_uf2(root / "carts" / "snouty.uf2", "ram", 6)
    make_uf2(root / "carts" / "snouty-bugs.uf2", "ram", 3)
    make_uf2(root / "carts" / "snouty-gear.uf2", "ram", 5)
    make_uf2(root / "carts" / "genesis-xip.uf2", "xip", 2)
    (root / "roms").mkdir(parents=True, exist_ok=True)
    (root / "roms" / "Sonic The Hedgehog (World).gg").write_bytes(b"S" * 3000)
    (root / "roms" / "Sonic The Hedgehog 2 (World).gg").write_bytes(b"T" * 1500)
    (root / "manifest.toml").write_text(MANIFEST)
    return root


def make_config(tmp: Path, fake: Path | None) -> Config:
    return Config(library=make_library(tmp / "library"), mount_root=tmp / "run",
                  fake_badge=str(fake) if fake else None, log_file=tmp / "station.log",
                  build_host=None, build_repo=str(tmp / "build"))


def write_config(tmp: Path) -> Path:
    make_library(tmp / "library")
    p = tmp / "station.toml"
    p.write_text(f'library = "{tmp / "library"}"\nmount_root = "{tmp / "run"}"\n'
                 f'log_file = "{tmp / "station.log"}"\nbuild_host = "exedev@example"\n')
    return p


def make_romfs():
    """tools/make_romfs.py as a module (read-only use)."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("make_romfs", REPO / "tools" / "make_romfs.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod
