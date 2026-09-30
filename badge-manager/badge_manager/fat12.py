"""Badge drive geometry and fit accounting.

Mirrors sycl-badge/src/os/loader/storage.zig (formatVolume, fatSectors,
rootDirSectors) and tools/make_romfs.py. All sizes in bytes unless named.
"""
from __future__ import annotations
import math
from dataclasses import dataclass, field

SECTOR = 512
VOLUME_BYTES = 1280 * 1024          # OS romfs region
RESERVED_SECTORS = 1
NUM_FATS = 2
ROOT_ENTRIES = 32                    # one is the SYCLBADGE volume label
SECTORS_PER_CLUSTER = 1
LABEL = "SYCLBADGE"


def fat_sectors(total_sectors: int) -> int:
    """FAT size in sectors, the OS's fixed-point loop (see make_romfs.fat_sectors)."""
    raise NotImplementedError


def data_clusters(volume_bytes: int = VOLUME_BYTES) -> int:
    """Usable clusters after boot sector, FATs and the root directory."""
    raise NotImplementedError


def clusters_for(size: int) -> int:
    return max(1, math.ceil(size / (SECTOR * SECTORS_PER_CLUSTER))) if size else 0


def is_short_name(name: str) -> bool:
    """True when a host stores NAME with no LFN entries (upper-case 8.3, allowed chars)."""
    raise NotImplementedError


def root_entries_for(name: str) -> int:
    """Directory entries a file called NAME costs: 1 + ceil(len/13) LFN entries, or 1."""
    raise NotImplementedError


def short_name_for(name: str, taken: set[str]) -> str:
    """An 8.3 name the station uses for ROM files (SONIC.GG), unique among TAKEN."""
    raise NotImplementedError


@dataclass
class FitReport:
    bytes_used: int
    bytes_capacity: int
    entries_used: int
    entries_capacity: int = ROOT_ENTRIES - 1
    why: list[str] = field(default_factory=list)   # human reasons when not fits

    @property
    def fits(self) -> bool:
        return not self.why


def fit(files: list[tuple[str, int]], volume_bytes: int = VOLUME_BYTES) -> FitReport:
    """FILES = [(name_on_drive, size)]. Cluster-rounded bytes and root entries vs capacity."""
    raise NotImplementedError
