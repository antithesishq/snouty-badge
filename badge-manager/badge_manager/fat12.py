"""Badge drive geometry and fit accounting.

Mirrors sycl-badge/src/os/loader/storage.zig (formatVolume, fatSectors,
rootDirSectors) and tools/make_romfs.py. All sizes in bytes unless named.
Also a small read-only parser for the raw volume (boot sector, FAT, root
directory) so the station can count free root entries and check that files
are contiguous without trusting the host's view.
"""
from __future__ import annotations
import math
import io
import os
import re
import struct
import time
from dataclasses import dataclass, field
from typing import BinaryIO

SECTOR = 512
VOLUME_BYTES = 1280 * 1024          # OS romfs region
RESERVED_SECTORS = 1
NUM_FATS = 2
ROOT_ENTRIES = 32                    # one is the SYCLBADGE volume label
SECTORS_PER_CLUSTER = 1
LABEL = "SYCLBADGE"
ROOT_SECTORS = (ROOT_ENTRIES * 32 + SECTOR - 1) // SECTOR

# Characters allowed in an 8.3 name (tools/make_romfs.py SFN_OK).
SFN_CHARS = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'()-@^_`{}~")


def validate_filename(name: str) -> None:
    """Require a single portable FAT filename, never a path or special entry."""
    if (not isinstance(name, str) or not name or name in (".", "..")
            or name[-1:] in (".", " ")
            or any(ord(c) < 32 or ord(c) == 127 or c in '\\/:*?"<>|' for c in name)):
        raise ValueError(f"invalid FAT filename: {name!r}")
    try:
        units = len(name.encode("utf-16-le")) // 2
    except UnicodeError as e:
        raise ValueError("invalid filename encoding") from e
    if units > 255:
        raise ValueError("FAT filename exceeds 255 characters")
    if name.split(".")[0].upper() in {"CON", "PRN", "AUX", "NUL", *[f"{p}{n}" for p in ("COM", "LPT") for n in range(1, 10)]}:
        raise ValueError(f"reserved FAT filename: {name!r}")


def fat_sectors(total_sectors: int) -> int:
    """FAT size in sectors, the OS's fixed-point loop (see make_romfs.fat_sectors)."""
    fs = 1
    while True:
        data = total_sectors - RESERVED_SECTORS - ROOT_SECTORS - NUM_FATS * fs
        need = ((data // SECTORS_PER_CLUSTER * 3 + 1) // 2 + SECTOR - 1) // SECTOR
        if need == fs:
            return fs
        fs = need


def data_clusters(volume_bytes: int = VOLUME_BYTES) -> int:
    """Usable clusters after boot sector, FATs and the root directory."""
    total = volume_bytes // SECTOR
    data_start = RESERVED_SECTORS + NUM_FATS * fat_sectors(total) + ROOT_SECTORS
    return (total - data_start) // SECTORS_PER_CLUSTER


def clusters_for(size: int) -> int:
    return max(1, math.ceil(size / (SECTOR * SECTORS_PER_CLUSTER))) if size else 0


def is_short_name(name: str) -> bool:
    """True when a host stores NAME with no LFN entries (upper-case 8.3, allowed chars)."""
    if not name or name.startswith(".") or name.count(".") > 1:
        return False
    base, _, ext = name.partition(".")
    if not 1 <= len(base) <= 8 or len(ext) > 3 or (name.endswith(".") and not ext):
        return False
    return all(c in SFN_CHARS for c in base + ext)


def root_entries_for(name: str) -> int:
    """Directory entries a file called NAME costs: 1 + ceil(len/13) LFN entries, or 1."""
    if is_short_name(name):
        return 1
    units = len(name.encode("utf-16-le")) // 2
    return 1 + math.ceil(units / 13)


def _sfn_part(text: str) -> str:
    """Letters and digits only: station-made names stay plain (SONIC2.GG)."""
    return "".join(c for c in text.upper() if c.isascii() and c.isalnum())


def short_name_for(name: str, taken: set[str]) -> str:
    """An 8.3 name the station uses for ROM files (SONIC.GG), unique among TAKEN.

    The base is the first word of NAME's stem with bracketed tags such as
    "(World)" dropped (whole stem when the first word is under 3 letters);
    the extension is NAME's, up to 3 characters. Clashes get a digit suffix
    (SONIC2.GG). TAKEN is compared case-insensitively.
    """
    stem, dot, ext = name.rpartition(".")
    if not dot or not stem:
        stem, ext = name, ""
    stem = re.sub(r"[\(\[\{][^\)\]\}]*[\)\]\}]", " ", stem)
    words = [w for w in (_sfn_part(w) for w in re.split(r"[\s._,+-]+", stem)) if w]
    base = words[0] if words and len(words[0]) >= 3 else "".join(words)
    base = (base or "ROM")[:8]
    ext = _sfn_part(ext)[:3]
    upper = {t.upper() for t in taken}

    def join(b: str) -> str:
        return b + ("." + ext if ext else "")

    if join(base) not in upper:
        return join(base)
    for n in range(2, 100000):
        tail = str(n)
        cand = join(base[:8 - len(tail)] + tail)
        if cand not in upper:
            return cand
    raise ValueError(f"no free 8.3 name for {name}")


@dataclass
class Geometry:
    """What limits a volume: cluster size, data clusters, root entries (label included)."""
    cluster_bytes: int
    clusters: int
    root_entries: int

    @property
    def capacity_bytes(self) -> int:
        return self.cluster_bytes * self.clusters


def geometry(volume_bytes: int = VOLUME_BYTES) -> Geometry:
    """The badge OS geometry for a volume of VOLUME_BYTES."""
    return Geometry(SECTOR * SECTORS_PER_CLUSTER, data_clusters(volume_bytes), ROOT_ENTRIES)


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

    @property
    def bytes_free(self) -> int:
        return self.bytes_capacity - self.bytes_used

    @property
    def entries_free(self) -> int:
        return self.entries_capacity - self.entries_used


def kb_up(n: int) -> str:
    return f"{math.ceil(n / 1024):,} KB"


def kb_down(n: int) -> str:
    return f"{n // 1024:,} KB"


def fit(files: list[tuple[str, int]], volume_bytes: int = VOLUME_BYTES,
        geom: Geometry | None = None) -> FitReport:
    """FILES = [(name_on_drive, size)]. Cluster-rounded bytes and root entries vs capacity.

    Capacity is an empty volume: GEOM when given (a real drive's boot sector),
    else the OS geometry for VOLUME_BYTES. The label takes one root entry.
    """
    g = geom or geometry(volume_bytes)
    per = g.cluster_bytes
    used = sum(max(1, math.ceil(size / per)) if size else 0 for _, size in files) * per
    entries = sum(root_entries_for(name) for name, _ in files)
    rep = FitReport(used, g.capacity_bytes, entries, g.root_entries - 1)
    if used > rep.bytes_capacity:
        rep.why.append(f"{kb_up(used)} needed, {kb_down(rep.bytes_capacity)} free")
    if entries > rep.entries_capacity:
        rep.why.append(f"{entries} root entries needed, {rep.entries_capacity} free")
    lower = [n for n, _ in files]
    dup = sorted({n for n in lower if [x.upper() for x in lower].count(n.upper()) > 1})
    if dup:
        rep.why.append("duplicate names on the drive: " + ", ".join(dup))
    return rep


# ---------------------------------------------------------------------------
# Raw volume reader (boot sector, FAT, root directory).

@dataclass
class RawFile:
    name: str             # long name when present, else the 8.3 name
    size: int
    is_dir: bool
    first_cluster: int
    runs: int             # 1 = contiguous; 0 = empty file


@dataclass
class VolumeInfo:
    geometry: Geometry
    label: str
    free_clusters: int
    entries_used: int     # root entries in use, LFN entries and the label included
    files: list[RawFile]

    @property
    def free_bytes(self) -> int:
        return self.free_clusters * self.geometry.cluster_bytes

    @property
    def free_entries(self) -> int:
        return self.geometry.root_entries - self.entries_used


def _fat_get(fat: bytes, cluster: int) -> int:
    off = cluster + cluster // 2
    if cluster < 0 or off + 1 >= len(fat):
        raise ValueError("cluster outside FAT table")
    v = fat[off] | (fat[off + 1] << 8)
    return (v >> 4) if cluster & 1 else (v & 0xFFF)


def _lfn_chars(e: bytes) -> list[int]:
    offs = [1 + 2 * i for i in range(5)] + [14 + 2 * i for i in range(6)] + [28, 30]
    return [struct.unpack_from("<H", e, o)[0] for o in offs]


def _sfn_checksum(n11: bytes) -> int:
    s = 0
    for c in n11:
        s = (((s & 1) << 7) + (s >> 1) + c) & 0xFF
    return s


def read_volume(fh: BinaryIO) -> VolumeInfo:
    """Parse a FAT12 volume from FH (image file or block device), read-only."""
    fh.seek(0)
    boot = fh.read(SECTOR)
    if len(boot) < SECTOR or boot[510:512] != b"\x55\xAA":
        raise ValueError("no FAT boot sector")
    bps, spc = struct.unpack_from("<H", boot, 11)[0], boot[13]
    res, nf = struct.unpack_from("<H", boot, 14)[0], boot[16]
    rootn, total = struct.unpack_from("<HH", boot, 17)
    fs = struct.unpack_from("<H", boot, 22)[0]
    if total == 0:
        total = struct.unpack_from("<I", boot, 32)[0]
    if (bps not in (512, 1024, 2048, 4096) or not spc or spc > 128
            or spc & (spc - 1) or not fs or not rootn or not res or nf not in (1, 2)):
        raise ValueError("invalid FAT boot sector geometry")
    root_start = res + nf * fs
    data_start = root_start + (rootn * 32 + bps - 1) // bps
    ncl = (total - data_start) // spc
    if not 0 < ncl < 4085:
        raise ValueError("not a FAT12 volume")
    if (ncl + 1) + (ncl + 1) // 2 + 2 > fs * bps:
        raise ValueError("FAT table too small for declared clusters")
    fh.seek(total * bps - 1)
    if len(fh.read(1)) != 1:
        raise ValueError("truncated FAT volume")
    fh.seek(res * bps)
    fat = fh.read(fs * bps)
    if len(fat) != fs * bps:
        raise ValueError("truncated FAT table")
    free = sum(1 for c in range(2, ncl + 2) if _fat_get(fat, c) == 0)
    fh.seek(root_start * bps)
    root = fh.read(rootn * 32)
    if len(root) != rootn * 32:
        raise ValueError("truncated root directory")
    geom = Geometry(bps * spc, ncl, rootn)
    label = boot[43:54].decode("latin-1").strip()
    used, files, lfn = 0, [], []
    for i in range(rootn):
        e = root[i * 32:(i + 1) * 32]
        if len(e) < 32 or e[0] == 0:
            break
        if e[0] == 0xE5:
            lfn = []
            continue
        used += 1
        attr = e[11]
        if attr == 0x0F:
            if e[0] & 0x40:
                lfn = []
            lfn.append(e)
            continue
        if attr & 0x08:
            label = e[0:11].decode("latin-1").strip() or label
            lfn = []
            continue
        rf = _raw_file(e, lfn, fat, ncl)
        chain = _chain(fat, rf.first_cluster, ncl)
        if not rf.is_dir and len(chain) != math.ceil(rf.size / geom.cluster_bytes):
            raise ValueError(f"invalid cluster chain length for {rf.name}")
        files.append(rf)
        lfn = []
    return VolumeInfo(geom, label, free, used, files)


def _chain(fat: bytes, first: int, ncl: int) -> list[int]:
    chain, seen = [], set()
    c = first
    if c == 0:
        return chain
    while c < 0xFF8:
        if not 2 <= c < min(ncl + 2, 0xFF0) or c in seen:
            raise ValueError("invalid or cyclic FAT cluster chain")
        seen.add(c)
        chain.append(c)
        c = _fat_get(fat, c)
    return chain


def _raw_file(e: bytes, lfn: list[bytes], fat: bytes, ncl: int) -> RawFile:
    name = e[0:8].decode("latin-1").rstrip()
    if e[8:11].strip():
        name += "." + e[8:11].decode("latin-1").rstrip()
    if lfn and all(x[13] == _sfn_checksum(e[0:11]) for x in lfn):
        cs: list[int] = []
        for x in reversed(lfn):
            cs += _lfn_chars(x)
        cs = cs[:cs.index(0)] if 0 in cs else [c for c in cs if c != 0xFFFF]
        name = "".join(chr(c) for c in cs)
    cl0 = struct.unpack_from("<H", e, 26)[0]
    size = struct.unpack_from("<I", e, 28)[0]
    runs, prev = 0, None
    for c in _chain(fat, cl0, ncl):
        if prev is None or c != prev + 1:
            runs += 1
        prev = c
    return RawFile(name, size, bool(e[11] & 0x10), cl0, runs)


# ---------------------------------------------------------------------------
# Writer for FAT12 images: the station's own FAT code, used for --fake-badge
# images when the kernel has no vfat (or no root). The alias, LFN and entry
# layout follow tools/make_romfs.py (short_name, lfn_entries, sfn_entry),
# which in turn follows what Windows, macOS and Linux shortname=mixed write.

EOC = 0xFFF


def _fat_set(fat: bytearray, cluster: int, value: int) -> None:
    off = cluster + cluster // 2
    value &= 0xFFF
    if cluster & 1:
        fat[off] = (fat[off] & 0x0F) | ((value << 4) & 0xF0)
        fat[off + 1] = (value >> 4) & 0xFF
    else:
        fat[off] = value & 0xFF
        fat[off + 1] = (fat[off + 1] & 0xF0) | (value >> 8)


def alias_for(name: str, taken: set[bytes]) -> tuple[bytes, bool]:
    """(11-byte 8.3 name, needs LFN) as a host derives it (make_romfs.short_name)."""
    if is_short_name(name):
        base, _, ext = name.partition(".")
        return base.ljust(8).encode() + ext.ljust(3).encode(), False
    base, dot, ext = name.rpartition(".")
    if not dot or not base:
        base, ext = name, ""

    def clean(s: str) -> bytes:
        return "".join(c if c in SFN_CHARS else "_" for c in s.upper()
                       if c not in " .").encode("ascii", "replace")
    b, e = clean(base.lstrip(".")) or b"_", clean(ext)[:3]
    if is_short_name(name.upper()) and not name.startswith("."):
        n11 = name.upper().partition(".")[0].ljust(8).encode() + e.ljust(3)
        if n11 not in taken:
            return n11, True           # lower-case 8.3: same alias, plus an LFN
    for i in range(1, 1000000):
        tail = b"~%d" % i
        n11 = (b[:8 - len(tail)] + tail).ljust(8) + e.ljust(3)
        if n11 not in taken:
            return n11, True
    raise ValueError("out of 8.3 aliases")


def _lfn_group(name: str, checksum: int) -> list[bytearray]:
    units = name.encode("utf-16-le")
    chars = [units[i] | (units[i + 1] << 8) for i in range(0, len(units), 2)]
    if len(chars) > 255:
        raise ValueError(f"name longer than 255 characters: {name}")
    if len(chars) % 13:
        chars.append(0)
    while len(chars) % 13:
        chars.append(0xFFFF)
    n = len(chars) // 13
    out = []
    for k in range(n, 0, -1):
        e = bytearray(32)
        e[0] = k | (0x40 if k == n else 0)
        for i, c in enumerate(chars[(k - 1) * 13:k * 13]):
            off = (1 + 2 * i) if i < 5 else (14 + 2 * (i - 5)) if i < 11 else (28 + 2 * (i - 11))
            struct.pack_into("<H", e, off, c)
        e[11], e[13] = 0x0F, checksum
        out.append(e)
    return out


def _fat_now() -> tuple[int, int]:
    t = time.localtime()
    return (((t.tm_year - 1980) << 9) | (t.tm_mon << 5) | t.tm_mday,
            (t.tm_hour << 11) | (t.tm_min << 5) | (t.tm_sec // 2))


class Fat12Image:
    """Read-modify-write access to a FAT12 image file (whole volume in memory)."""

    def __init__(self, path: str):
        self.path = path
        with open(path, "rb") as fh:
            self.img = bytearray(fh.read())
        b = self.img
        read_volume(io.BytesIO(b))  # the writer accepts the same bounded media as the reader
        if len(b) < SECTOR or b[510:512] != b"\x55\xAA":
            raise ValueError("no FAT boot sector")
        self.bps, self.spc = struct.unpack_from("<H", b, 11)[0], b[13]
        self.res, self.nf = struct.unpack_from("<H", b, 14)[0], b[16]
        self.rootn, total = struct.unpack_from("<HH", b, 17)
        if total == 0:
            total = struct.unpack_from("<I", b, 32)[0]
        self.fs = struct.unpack_from("<H", b, 22)[0]
        self.root_off = (self.res + self.nf * self.fs) * self.bps
        self.data_sector = self.res + self.nf * self.fs + (self.rootn * 32 + self.bps - 1) // self.bps
        self.ncl = (total - self.data_sector) // self.spc
        self.cluster_bytes = self.bps * self.spc
        self.fat = bytearray(b[self.res * self.bps:(self.res + self.fs) * self.bps])

    def save(self) -> None:
        for k in range(self.nf):
            o = (self.res + k * self.fs) * self.bps
            self.img[o:o + len(self.fat)] = self.fat
        with open(self.path, "r+b") as fh:
            fh.write(self.img)
            fh.flush()
            os.fsync(fh.fileno())

    def read_file(self, name: str) -> bytes:
        volume = read_volume(io.BytesIO(self.img))
        file = next((f for f in volume.files if f.name.casefold() == name.casefold()), None)
        if file is None or file.is_dir:
            raise ValueError(f"file not found: {name}")
        chunks = []
        for c in _chain(self.fat, file.first_cluster, self.ncl):
            offset = (self.data_sector + (c - 2) * self.spc) * self.bps
            chunks.append(self.img[offset:offset + self.cluster_bytes])
        return b"".join(chunks)[:file.size]

    def _entry(self, i: int) -> bytearray:
        o = self.root_off + i * 32
        return self.img[o:o + 32]

    def _put(self, i: int, e: bytes) -> None:
        o = self.root_off + i * 32
        self.img[o:o + 32] = e

    def wipe(self) -> int:
        """Drop every root entry but the label and free every cluster. Returns files removed."""
        keep, removed = [], 0
        for i in range(self.rootn):
            e = self._entry(i)
            if e[0] == 0:
                break
            if e[0] == 0xE5:
                continue
            if e[11] == 0x0F:
                continue
            if e[11] & 0x08:
                keep.append(bytes(e))
            else:
                removed += 1
        for i in range(self.rootn):
            self._put(i, keep[i] if i < len(keep) else bytes(32))
        for c in range(2, self.ncl + 2):
            _fat_set(self.fat, c, 0)
        return removed

    def _free_run(self, n: int) -> list[int]:
        """First-fit contiguous run of N free clusters, else the first N free ones."""
        free = [c for c in range(2, self.ncl + 2) if _fat_get(self.fat, c) == 0]
        if len(free) < n:
            raise OSError(28, "No space left on device")
        for i in range(len(free) - n + 1):
            if free[i + n - 1] - free[i] == n - 1:
                return free[i:i + n]
        return free[:n]

    def _slots(self, n: int) -> int:
        """Index of the first run of N free root slots."""
        run = 0
        for i in range(self.rootn):
            e = self._entry(i)
            run = run + 1 if e[0] in (0, 0xE5) else 0
            if run == n:
                return i - n + 1
        raise OSError(28, "root directory full")

    def delete(self, name: str) -> None:
        start = None
        for i in range(self.rootn):
            e = self._entry(i)
            if e[0] == 0:
                break
            if e[0] == 0xE5:
                start = None
                continue
            if e[11] == 0x0F:
                start = i if (e[0] & 0x40 or start is None) else start
                continue
            if e[11] & 0x08:
                start = None
                continue
            first = start if start is not None else i
            rf = _raw_file(bytes(e), [self._entry(j) for j in range(first, i)],
                           self.fat, self.ncl)
            if rf.name.lower() == name.lower():
                c, seen = rf.first_cluster, set()
                while 2 <= c < self.ncl + 2 and c not in seen:
                    seen.add(c)
                    nxt = _fat_get(self.fat, c)
                    _fat_set(self.fat, c, 0)
                    c = nxt
                for j in range(first, i + 1):
                    self.img[self.root_off + j * 32] = 0xE5
                return
            start = None

    def add(self, name: str, data: bytes) -> None:
        validate_filename(name)
        self.delete(name)
        taken = set()
        for i in range(self.rootn):
            e = self._entry(i)
            if e[0] not in (0, 0xE5) and e[11] != 0x0F:
                taken.add(bytes(e[0:11]))
        n11, need_lfn = alias_for(name, taken)
        group = _lfn_group(name, _sfn_checksum(n11)) if need_lfn else []
        per = self.cluster_bytes
        clusters = self._free_run(-(-len(data) // per)) if data else []
        for i, c in enumerate(clusters):
            _fat_set(self.fat, c, clusters[i + 1] if i + 1 < len(clusters) else EOC)
            o = (self.data_sector + (c - 2) * self.spc) * self.bps
            chunk = data[i * per:(i + 1) * per]
            self.img[o:o + per] = chunk.ljust(per, b"\0")
        d, t = _fat_now()
        e = bytearray(32)
        e[0:11], e[11] = n11, 0x20
        struct.pack_into("<HHH", e, 14, t, d, d)
        struct.pack_into("<HH", e, 22, t, d)
        struct.pack_into("<HI", e, 26, clusters[0] if clusters else 0, len(data))
        group.append(e)
        at = self._slots(len(group))
        for k, g in enumerate(group):
            self._put(at + k, g)
