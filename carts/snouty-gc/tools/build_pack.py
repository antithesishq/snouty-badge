#!/usr/bin/env python3
"""Build a Snouty GCP track pack (.GCP, docs/PACKS.md) from a pack directory.

    python3 tools/build_pack.py DIR [--out FILE.GCP]     (from the cart directory)
    python3 tools/build_pack.py --info FILE.GCP

DIR holds pack.toml and the built-in-format .bin files that
tools/build_tracks.py / tools/build_arena.py write for a league, its tracks
and an arena (pal, tiles, horizon, attr; <id>_map, <id>_center, <id>_feat,
<id>_arena), plus an optional props.png. Any file can be pointed elsewhere
from pack.toml (`pal = "path"` at the top, `map = "path"` etc. in a track
table; paths relative to DIR). The default output is DIR/<file>.GCP.

The script checks every section the way the cart does (cart/src/
pack_format.zig and pack.zig: sizes, the packed streams, tile indices, the
centerline, feat kinds, the arena blob, the props, each track's RAM slot
budget), derives the header's hazard mask from the feat records and the
maps' attributes, lays the sections out 4-byte aligned, writes the CRC and
exits non-zero on any failure. Deterministic: the same inputs give the same
bytes. Python 3.11+ (tomllib), numpy, Pillow.
"""
from __future__ import annotations

import argparse
import struct
import sys
import tomllib
import zlib
from pathlib import Path

import numpy as np
from PIL import Image

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from leagues import (  # noqa: E402
    A_OFF, A_COOLANT, A_RAMP, A_START, A_CRUST, A_WALL, ATTR_NAMES, DRIVABLE, NTILES, CRUST,
)
import build_tracks as bt  # noqa: E402  (unpack_map, pack_map)

# pack_format.zig, version 1.
MAGIC, VERSION = b"GCPK", 1
HEADER, LEAGUE, RECORD = 64, 64, 64
TRACK_MAX, ARENA_MAX = 4, 1
FILE_MAX = 128 * 1024
NAME_LEN = 16
PAL, TILES, HORIZON, ATTR, MAP, CENTER = 512, NTILES * 64, 12352, NTILES, 128 * 128, 256 * 6
FEAT_RECORD, FEAT_MAX, PROP_RECORD, PROP_MAX = 20, 4, 6, 24
CELL_W_MAX, CELL_H_MAX, CELL_MAX = 32, 48, 16
SLOT_BYTES = 8192
SLOT_FIXED = PAL + ATTR + CENTER + FEAT_MAX * FEAT_RECORD + PROP_MAX * PROP_RECORD
SLOT_FREE = SLOT_BYTES - SLOT_FIXED
# Hazard kinds (world.zig HazardKind) and the mask bits (pack_format.zig).
K_BLAST, K_MOVER, K_TURRET, K_CRUST = 1, 2, 3, 4
HAS_SLICK, HAS_PIT = 1 << 5, 1 << 6
RUNS = (1 << K_BLAST) | (1 << K_MOVER) | (1 << K_CRUST) | HAS_SLICK | HAS_PIT
FLAG_RAMP = 1 << 6
KEY = (255, 0, 255)


class PackError(Exception):
    pass


def name16(s, what):
    s = str(s).upper()
    if not 1 <= len(s) <= NAME_LEN or any(not 0x20 <= ord(c) < 0x7F for c in s):
        raise PackError(f"{what} {s!r}: 1..{NAME_LEN} printable ASCII characters")
    return s.encode().ljust(NAME_LEN, b" ")


def unpacked(data, size, what):
    """The packed stream decoded with the cart's bounds: exactly `size`
    bytes out, never reading past the stream; and every byte consumed."""
    out = bytearray(size)
    i = o = 0
    try:
        while o < size:
            c = data[i]
            i += 1
            if c < 0x80:
                n = c + 1
                if o + n > size or i + n > len(data):
                    raise PackError(f"{what}: literal run past the end")
                out[o:o + n] = data[i:i + n]
                i += n
                o += n
            else:
                d = data[i]
                i += 1
                if d >= 0x80:
                    d = (d & 0x7F) << 8 | data[i]
                    i += 1
                d += 1
                n = (c & 0x7F) + 3
                if d > o or o + n > size:
                    raise PackError(f"{what}: back-reference out of range")
                for _ in range(n):
                    out[o] = out[o - d]
                    o += 1
    except IndexError:
        raise PackError(f"{what}: packed stream ends early") from None
    if i != len(data):
        raise PackError(f"{what}: {len(data) - i} bytes after the stream's end")
    return bytes(out)


def samples(center):
    v = np.frombuffer(center, np.uint8).reshape(256, 6)
    w = v[:, :4].copy().view("<u4")[:, 0]
    return (w & 1023).astype(int), ((w >> 10) & 1023).astype(int), v[:, 4].astype(int), v[:, 5].astype(int)


def check_center(center, tmap, attr, arena, what):
    """The cart's centerline sanity check (pack.zig `center_ok`)."""
    xs, ys, half, flags = samples(center)
    for k in range(256):
        if not 8 <= half[k] <= 120:
            raise PackError(f"{what}: sample {k} half width {half[k]} outside 8..120")
        j = (k + 1) % 256
        dx = ((xs[j] - xs[k] + 512) & 1023) - 512
        dy = ((ys[j] - ys[k] + 512) & 1023) - 512
        if dx * dx + dy * dy >= 48 * 48:
            raise PackError(f"{what}: samples {k} and {j} are {int((dx * dx + dy * dy) ** 0.5)} px apart (closed loop, < 48)")
        if arena:
            continue
        a = attr[tmap[ys[k] >> 3, xs[k] >> 3]]
        if a == A_OFF and flags[k] & FLAG_RAMP:
            continue
        if a not in DRIVABLE:
            raise PackError(f"{what}: sample {k} at ({xs[k]},{ys[k]}) on {ATTR_NAMES[a] if a < len(ATTR_NAMES) else a}")
    if not arena and attr[tmap[ys[0] >> 3, xs[0] >> 3]] != A_START:
        raise PackError(f"{what}: sample 0 is not on the start line")


def check_feat(feat, tmap, attr, what):
    """Feat records: known kinds; a crust region holds crust tiles. Returns
    the kinds' mask bits."""
    mask = 0
    for r in range(len(feat) // FEAT_RECORD):
        b = feat[r * FEAT_RECORD:(r + 1) * FEAT_RECORD]
        kind, sprite = b[0] & 15, b[0] >> 4
        if kind not in (K_BLAST, K_MOVER, K_TURRET, K_CRUST):
            raise PackError(f"{what}: feat record {r} kind {kind}")
        if sprite and kind != K_MOVER:
            raise PackError(f"{what}: feat record {r}: only a mover takes a sprite cell")
        x0, y0, x1, y1, period = struct.unpack_from("<5H", b, 4)
        if period == 0:
            raise PackError(f"{what}: feat record {r} period 0")
        if kind == K_CRUST:
            if not (x0 < x1 <= 1024 and y0 < y1 <= 1024 and x0 % 8 == 0 == y0 % 8 == x1 % 8 == y1 % 8):
                raise PackError(f"{what}: crust record {r} rectangle ({x0},{y0})-({x1},{y1}) not whole tiles")
            region = tmap[y0 >> 3:y1 >> 3, x0 >> 3:x1 >> 3]
            if not (region == CRUST).any():
                raise PackError(f"{what}: crust record {r} has no crust tile ({CRUST}) in its rectangle")
        mask |= 1 << kind
    return mask


def check_arena(blob, what):
    """track.zig parse_arena's checks, plus the next-hop and cell values."""
    if len(blob) < 8:
        raise PackError(f"{what}: arena blob under 8 bytes")
    sn, pn, nn, shift, grid, gnd = blob[0], blob[1], blob[2], blob[3], blob[4], blob[5]
    if sn > 8 or pn > 16 or nn > 48 or gnd != 1 or not 1 <= sn or shift > 10 or grid > 32:
        raise PackError(f"{what}: arena header {list(blob[:8])}")
    need = 8 + sn * 6 + pn * 4 + nn * 6 + 2 * nn * nn + grid * grid
    if len(blob) != need:
        raise PackError(f"{what}: arena blob {len(blob)} bytes, its header says {need}")
    at = 8 + sn * 6 + pn * 4
    for k in range(nn):
        j = blob[at + k * 6 + 4]
        if j != 0xFF and j >= nn:
            raise PackError(f"{what}: node {k} jumps to {j}")
    for v in blob[at + nn * 6:]:
        if v != 0xFF and v >= nn:
            raise PackError(f"{what}: arena table names node {v} of {nn}")


def load_props(dirp, cfg):
    """props.png -> (cell w, h, count, cells bytes, palette bytes)."""
    if "props" not in cfg:
        return 0, 0, 0, b"", b""
    p = cfg["props"]
    w, h = p["cell"]
    n = int(p["count"])
    if w % 2 or not 2 <= w <= CELL_W_MAX or not 1 <= h <= CELL_H_MAX or not 1 <= n <= CELL_MAX:
        raise PackError(f"props: cell {w}x{h} (even width <= {CELL_W_MAX}, height <= {CELL_H_MAX}), count {n} (1..{CELL_MAX})")
    img = Image.open(dirp / p.get("sheet", "props.png"))
    cols = img.width // w
    if cols == 0 or (n + cols - 1) // cols * h > img.height:
        raise PackError(f"props: {img.width}x{img.height} sheet holds fewer than {n} cells of {w}x{h}")
    if img.mode == "P":
        idx = np.array(img)
        pal = img.getpalette()[:48]
        rgb = [tuple(pal[i * 3:i * 3 + 3]) for i in range(16)]
        if idx.max() > 15:
            raise PackError("props: an indexed sheet must use indices 0..15 (0 transparent)")
    else:
        a = np.array(img.convert("RGBA"))
        key = (a[..., 3] < 128) | ((a[..., 0] == 255) & (a[..., 1] == 0) & (a[..., 2] == 255))
        idx = np.zeros(a.shape[:2], np.uint8)
        rgb = [KEY]
        order = {}
        for c in range(n):
            y0, x0 = (c // cols) * h, (c % cols) * w
            for y in range(y0, y0 + h):
                for x in range(x0, x0 + w):
                    if key[y, x]:
                        continue
                    col = tuple(int(v) for v in a[y, x, :3])
                    if col not in order:
                        order[col] = len(rgb)
                        rgb.append(col)
                    idx[y, x] = order[col]
        if len(rgb) > 16:
            raise PackError(f"props: {len(rgb) - 1} colours, at most 15 plus the #FF00FF key")
        rgb += [(0, 0, 0)] * (16 - len(rgb))
    cells = bytearray()
    for c in range(n):
        y0, x0 = (c // cols) * h, (c % cols) * w
        cell = idx[y0:y0 + h, x0:x0 + w].astype(np.uint8)
        cells += (cell[:, 0::2] | (cell[:, 1::2] << 4)).astype(np.uint8).tobytes()
    palb = np.array([bt.rgb565(c) for c in rgb], "<u2").tobytes()
    return w, h, n, bytes(cells), palb


def cells_used(props, feat):
    """The props cells a track loads into the slot (pack.zig, pack_format
    `budget`): its props' cells and its movers' sprite cells, each once."""
    used = {int(p[0]) for p in props}
    for r in range(len(feat) // FEAT_RECORD):
        sp = feat[r * FEAT_RECORD] >> 4
        if sp and feat[r * FEAT_RECORD] & 15 == K_MOVER:
            used.add(sp - 1)
    return used


def props_bytes(entries, cell_n, what):
    out = bytearray()
    if len(entries) > PROP_MAX:
        raise PackError(f"{what}: {len(entries)} props, at most {PROP_MAX}")
    for e in entries:
        c, x, y, r = (int(v) for v in e)
        if not 0 <= c < cell_n or not 0 <= x < 1024 or not 0 <= y < 1024 or not 0 <= r <= 64:
            raise PackError(f"{what}: prop {e} (cell < {cell_n}, x and y < 1024, radius 0..64)")
        out += struct.pack("<BBHH", c, r, x, y)
    return bytes(out)


def build(dirp: Path):
    cfg = tomllib.loads((dirp / "pack.toml").read_text())

    def rd(key, table, default, size=None, what=None):
        p = dirp / table.get(key, default)
        data = p.read_bytes()
        if size is not None and len(data) != size:
            raise PackError(f"{what or p.name}: {len(data)} bytes, expected {size}")
        return data

    file = str(cfg["file"]).upper()
    if not 1 <= len(file) <= 8 or any(c not in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" for c in file):
        raise PackError(f"file {file!r}: an 8.3 base name, 1..8 of A-Z 0-9 _ -")
    name = name16(cfg["name"], "name")
    league = name16(cfg.get("league", cfg["name"]), "league")
    pal = rd("pal", cfg, "pal.bin", PAL)
    tiles = rd("tiles", cfg, "tiles.bin")
    horizon = rd("horizon", cfg, "horizon.bin")
    attr_b = rd("attr", cfg, "attr.bin", ATTR)
    attr = np.frombuffer(attr_b, np.uint8)
    if attr.max() > A_CRUST:
        raise PackError(f"attr.bin: attribute {attr.max()} unknown")
    crust = attr == A_CRUST
    if crust.any() and not (crust[CRUST:CRUST + 3].all() and crust.sum() == 3):
        raise PackError(f"attr.bin: crust ({A_CRUST}) is tiles {CRUST}..{CRUST + 2}, all three and no others")
    raw_tiles = unpacked(tiles, TILES, "tiles.bin")
    unpacked(horizon, HORIZON, "horizon.bin")
    if 0 in raw_tiles:
        raise PackError("tiles.bin: a tile uses palette index 0 (the fog colour)")
    cw, ch, cn, cells, cell_pal = load_props(dirp, cfg)
    cell_bytes = cw * ch // 2
    races, arenas = cfg.get("track", []), cfg.get("arena", [])
    if not 1 <= len(races) <= TRACK_MAX or len(arenas) > ARENA_MAX:
        raise PackError(f"{len(races)} tracks (1..{TRACK_MAX}) and {len(arenas)} arenas (0..{ARENA_MAX})")
    mask = 0
    recs, report = [], []
    for t, kind in [(t, 0) for t in races] + [(a, 1) for a in arenas]:
        tid = t["id"]
        what = f"{tid}"
        mp = rd("map", t, f"{tid}_map.bin")
        tmap = np.frombuffer(unpacked(mp, MAP, f"{tid} map"), np.uint8).reshape(128, 128)
        if tmap.max() >= NTILES:
            raise PackError(f"{what}: map uses tile {tmap.max()}")
        center = rd("center", t, f"{tid}_center.bin", CENTER)
        check_center(center, tmap, attr, kind == 1, what)
        fp = dirp / t.get("feat", f"{tid}_feat.bin")
        feat = fp.read_bytes() if fp.exists() else b""
        if len(feat) % FEAT_RECORD or len(feat) > FEAT_MAX * FEAT_RECORD:
            raise PackError(f"{what}: feat {len(feat)} bytes (whole {FEAT_RECORD}-byte records, <= {FEAT_MAX})")
        mask |= check_feat(feat, tmap, attr, what)
        for r in range(len(feat) // FEAT_RECORD):
            sp = feat[r * FEAT_RECORD] >> 4
            if sp and sp - 1 >= cn:
                raise PackError(f"{what}: mover {r} sprite cell {sp - 1} of {cn}")
        used = set(int(v) for v in np.unique(attr[tmap]))
        if A_COOLANT in used:
            mask |= HAS_SLICK
        if A_OFF in used:
            mask |= HAS_PIT
        if (tmap == CRUST).any() and not crust.any():
            raise PackError(f"{what}: the map places crust tiles but attr.bin has no crust")
        if (tmap == CRUST).any() and not any(feat[r * FEAT_RECORD] & 15 == K_CRUST for r in range(len(feat) // FEAT_RECORD)):
            raise PackError(f"{what}: crust tiles with no crust record")
        blob = rd("arena", t, f"{tid}_arena.bin") if kind == 1 else b""
        if kind == 1:
            check_arena(blob, what)
        props = props_bytes(t.get("props", []), cn, what)
        need = len(blob) + len(cells_used(t.get("props", []), feat)) * cell_bytes
        if need > SLOT_FREE:
            raise PackError(f"{what}: arena blob {len(blob)} + props cells {need - len(blob)} = {need} bytes, over the slot's {SLOT_FREE}")
        laps = 0 if kind == 1 else int(t.get("laps", 3))
        if kind == 0 and not 1 <= laps <= 9:
            raise PackError(f"{what}: laps {laps} (1..9)")
        recs.append(dict(name=name16(t["name"], f"{tid} name"), laps=laps, kind=kind,
                         secs=[mp, center, feat, blob, props]))
        report.append(f"  {'arena' if kind else 'track'} {t['name']}: map {len(mp)}, feat {len(feat) // FEAT_RECORD}, "
                      f"arena {len(blob)}, props {len(props) // PROP_RECORD}, slot {need} of {SLOT_FREE} B")
    if mask & ~RUNS:
        raise PackError("a turret: this cart does not run turrets (pack_format.zig `runs`)")
    # Layout: directory, then the sections 4-byte aligned.
    dir_len = HEADER + LEAGUE + RECORD * len(recs)
    body = bytearray()

    def place(data):
        if not data:
            return (0, 0)
        while (dir_len + len(body)) % 4:
            body.append(0)
        off = dir_len + len(body)
        body.extend(data)
        return (off, len(data))

    league_secs = [place(d) for d in (pal, tiles, horizon, attr_b, cells, cell_pal)]
    rec_secs = [[place(d) for d in r["secs"]] for r in recs]
    while (dir_len + len(body)) % 4:
        body.append(0)
    size = dir_len + len(body)
    if size > FILE_MAX:
        raise PackError(f"pack is {size} bytes, over the {FILE_MAX} cap")
    lg = b"".join(struct.pack("<II", *s) for s in league_secs) + bytes(16)
    rb = b""
    for r, secs in zip(recs, rec_secs):
        rb += r["name"] + bytes([r["laps"], r["kind"], 0, 0]) + b"".join(struct.pack("<II", *s) for s in secs) + bytes(4)
    rest = lg + rb + bytes(body)
    assert len(rest) == size - HEADER
    crc = zlib.crc32(rest)
    head = MAGIC + bytes([VERSION, HEADER, len(races), len(arenas), mask, cw, ch, cn]) + name + league
    head += struct.pack("<II", size, crc) + bytes(12)
    assert len(head) == HEADER
    out = head + rest
    report.insert(0, f"pack {file}.GCP {name.decode().strip()!r} ({league.decode().strip()}): {size} bytes, "
                     f"crc {crc:08x}, hazards {mask:#04x}, props {cn} cells of {cw}x{ch}")
    return file, out, report


def info(path):
    b = Path(path).read_bytes()
    if b[:4] != MAGIC:
        raise PackError("not a pack")
    tn, an, mask, cw, ch, cn = b[6:12]
    size, crc = struct.unpack_from("<II", b, 44)
    print(f"{path}: version {b[4]}, {tn} tracks, {an} arenas, hazards {mask:#04x}, props {cn} of {cw}x{ch}")
    print(f"  name {b[12:28].decode()!r} league {b[28:44].decode()!r} size {size} (file {len(b)}) crc {crc:08x} "
          f"({'ok' if zlib.crc32(b[64:size]) == crc else 'BAD'})")
    names = ["pal", "tiles", "horizon", "attr", "cells", "cell pal"]
    for k, n in enumerate(names):
        print(f"  {n}: {struct.unpack_from('<II', b, 64 + 8 * k)}")
    for k in range(tn + an):
        r = b[128 + 64 * k:192 + 64 * k]
        secs = [struct.unpack_from("<II", r, 20 + 8 * j) for j in range(5)]
        print(f"  {'arena' if r[17] else 'track'} {r[:16].decode()!r} laps {r[16]}: map {secs[0]} center {secs[1]} "
              f"feat {secs[2]} arena {secs[3]} props {secs[4]}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("dir", nargs="?")
    ap.add_argument("--out", help="output file (default DIR/<file>.GCP)")
    ap.add_argument("--info", metavar="FILE", help="print a pack's directory")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()
    try:
        if a.info:
            info(a.info)
            return 0
        if not a.dir:
            ap.error("DIR or --info")
        dirp = Path(a.dir)
        file, data, report = build(dirp)
        out = Path(a.out) if a.out else dirp / f"{file}.GCP"
        out.write_bytes(data)
        if not a.quiet:
            print("\n".join(report))
            print(f"  wrote {out}")
    except (PackError, OSError, KeyError, ValueError, tomllib.TOMLDecodeError) as e:
        print(f"build_pack: ERROR: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
