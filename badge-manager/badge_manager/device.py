"""The badge drive: find it, mount it, wipe it, fill it, eject it.

Real badge: USB mass storage, VID:PID 04d2:04d2, FAT12 label SYCLBADGE
(/dev/disk/by-label/SYCLBADGE). The station runs as root and mounts with
`mount -t vfat -o sync,flush,utf8,shortname=mixed`. Eject = umount +
`udisksctl power-off -b DEV` (fallback: echo 1 > /sys/block/X/device/delete).
"""
from __future__ import annotations
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol


@dataclass
class Entry:
    name: str
    size: int


class Badge(Protocol):
    """One plugged-in badge drive. Methods raise DeviceError on failure."""
    device: str                       # /dev/sdX, image path, or directory
    def mount(self) -> Path: ...      # idempotent, returns the mount point
    def unmount(self) -> None: ...
    def eject(self) -> None: ...      # unmount + power off; badge must be re-plugged after
    def listdir(self) -> list[Entry]: ...   # root files, hidden/host junk included
    def free_bytes(self) -> int: ...
    def free_entries(self) -> int: ...      # root directory entries left (read the FAT, not statvfs)
    def wipe(self) -> None: ...             # delete every root entry except the volume label
    def copy(self, src: Path, name: str) -> None: ...  # write + fsync; name is the drive name


class DeviceError(Exception):
    pass


def find_badge(fake: str | None = None) -> Badge | None:
    """FAKE = image path (LoopBadge) or directory (DirBadge); else scan
    /dev/disk/by-label/SYCLBADGE and /sys/bus/usb for 04d2:04d2 -> BlockBadge."""
    raise NotImplementedError


class BlockBadge:
    def __init__(self, devnode: str, mount_root: Path = Path("/run/badge-station")): ...


class LoopBadge:
    """A tools/make_romfs.py image loop-mounted (needs root/sudo). VM end-to-end tests."""
    def __init__(self, image: Path, mount_root: Path): ...


class DirBadge:
    """A plain directory standing in for the mounted drive; fit limits simulated
    from fat12 constants. Unit tests and the web page's demo mode (no root)."""
    def __init__(self, directory: Path, volume_bytes: int | None = None): ...
