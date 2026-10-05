#!/usr/bin/env python3
# Forked from snouty-zero/tools/build_tracks.py at f8f6962.
"""Build the Snouty GC league art and track tables into assets/gen/.

    python3 tools/build_tracks.py                 (from the cart directory)
    python3 tools/build_tracks.py --track landfill_loop --out /tmp/x

Reads cart/src/tracks/*.track (SPEC section 7) and writes the files of
PLAN.md "Generated data formats" into cart/src/gen/tracks/ (M3: embedded
by track.zig with @embedFile, so a new track needs no build.zig entry):

  <league>_tiles.bin   128 tiles x 8x8 palette indices (8192 bytes)
  <league>_pal.bin     256 x u16 RGB565, entry 0 = fog/horizon colour
  <league>_horizon.bin front 512x32 4bpp, back 256x32 4bpp, 2 x 16 x u16
  <league>_attr.bin    128 attributes, one per tile index
  <track>_map.bin      128x128 tile indices, map[y][x], packed (below)
  <track>_center.bin   256 samples x (x u16, y u16, tangent u16, half u8, flags u8)
                       flags: bit 0 wall, 1 open, 3 coolant, 4 bay, 5 vent,
                       6 ramp, 7 hill (of the sample's segment); bit 2 crates
                       (on one sample only: an RMA crate row there)
  <track>_feat.bin     hazard records (track.zig HazardSpec, SPEC 19.4), 20
                       bytes each, little endian: kind u8 (1 blast, 2 mover),
                       warn u8, size u8, damage u8, x0 y0 x1 y1 u16, period
                       u16, on u16, phase u16, push u8, speed u8 (1/32
                       px/tick); empty when the track has none

plus docs/<track>_preview.png (1:1 map with the centerline), and
docs/<league>_tiles.png / docs/<league>_tiles.txt (contact sheet, index list).

Rasterizer rules:
  * The closed centerline is a centripetal Catmull-Rom spline through the
    control points, resampled every ~1 world px (the "dense" line). Half
    width is smoothstep-interpolated between control points.
  * A 1024x1024 surface mask is the union of discs of the local half width
    at every dense point. A tile is surface when at least 32 of its 64
    texels are in the mask (majority rule).
  * Every surface/near-surface tile is tagged with its nearest dense point:
    arc position, segment (control point i to i+1) and lateral distance.
    Features on point i apply to segment i. bay paints the whole segment
    (bay:left / bay:right only the driver's left or right lane of it).
  * Bands are straight cuts: the drivable tiles whose centre lies within
    (lo, hi] px along the tangent of a centerline point (snapped to 45
    degrees so bands are clean rows, columns or diagonals) and within the
    half width (+10) across it. coolant/ramp: (-12, 12] at the
    segment middle (3 tiles, surface only). Start line: (-8, 8] at
    sample 0 (2 tiles, checker). Sector 1/2: (-4, 4] at samples 85/170
    (1 tile). A cut at least 8 px wide always stops a 4-connected path;
    the validator checks that the three marks split the loop in three.
  * ramp also leaves a gap of off-track void tiles (GAP + 4-neighbour mask,
    attribute 0) across the whole width (open-edge glow included) just past
    the plate, (12, 44] px plus a shift of up to 8 px chosen so that no
    centerline sample is a spot where a stopped car sits wholly in the
    gap (a pit). Ramps must sit on straight runs along x or y.
  * hill paints nothing: it only sets centerline flag bit 7 on every sample
    of the segment (the cart bends the floor into a smooth rise and dip over
    a run of hill samples: the Dumps' dunes). A run must be at least HILL_MIN
    samples (20..40 reads well) and must not touch a ramp segment or come within
    SEAM_CLEAR samples of the start line or a sector seam (0, 85, 170).
  * crates (M2) paints nothing: it sets centerline flag bit 2 on the one
    sample nearest the middle of the segment, where the cart puts a row of
    RMA crates across the track (track.find_crates: 4 crates CRATE_GAP px
    apart where the half width is >= CRATE_ROW4_HALF, else 3). The
    validator checks every crate sits on plain road, at most CRATE_MAX.
  * Hazards (M3, SPEC 3.3, 19.4) sit at the segment middle, across the
    track on the 45-degree-snapped tangent, clear of other bands:
    `vent[:left|right][,period=N,on=N,warn=N,phase=N,damage=N,push=N,size=N]`
    is a timed blast (an exhaust vent): its mouth is a grille in the wall on
    that side (default left) and its lane, painted as a scorched grate band
    (attribute vent), crosses the whole width. `sweeper[,period=..,warn=..,
    phase=..,damage=..,push=..,size=..,speed=..]` is a crossing mover (the
    Sweeper): it shuttles across between two parking spots beyond the
    walls, through hazard-striped gates in them, over a chevron band
    (attribute surface). Both need walls (no `open`) on their segment.
    `pipe` paints the segment's floor as the inside of an outflow pipe
    (ribbed steel; attribute surface; the Runoff's tunnels).
  * Off-track tiles within `pit_band` tiles (a header line, default 4) of an
    open edge's lip are pit (void), so a drop reads as one.
  * `open` opens both sides of a segment; `open:left` / `open:right` only the
    driver's left or right side (the other side keeps its rail).
  * Off-track tiles 4-adjacent to surface become edge pieces chosen by the
    4-neighbour surface mask (N=1, E=2, S=4, W=8): open-edge glow (attr 1)
    if the nearest sample's segment is `open` (a pit lip), else wall (attr 2). Tiles
    touching surface only diagonally get a corner piece of the same kind.
  * Everything else is the league background painter (seeded per track).

Packed maps (<track>_map.bin): a byte stream that unpacks to the 16384
tile indices in order, map[y][x]. Ops, read until the 16384 bytes are out:
  c = 0x00..0x7F   literal run: the next c + 1 bytes are copied out.
  c = 0x80..0xFF   back-reference of (c & 0x7F) + 3 bytes (3..130), then a
                   distance: one byte b < 0x80 is distance b + 1 (1..128,
                   so 128 = "the row above"), or b >= 0x80 and one more byte
                   b2 give distance ((b & 0x7F) << 8 | b2) + 1 (up to 32768).
                   The copy runs forward byte by byte, so it may overlap
                   what it writes (distance 1 = a run of one tile).
The packer is a greedy LZ77 with one step of lazy matching; it verifies its
own output with an independent decoder (unpack_map) before writing.

Everything is seeded from crc32 of the track or league name, so reruns are
byte-identical. The script validates its output and exits non-zero on any
failure. The tile vocabulary and the league painters live in
tools/leagues.py (the Dumps in M0); a league is one LEAGUES entry
there (palette + tile painter + background + horizon).
"""
from __future__ import annotations

import argparse
import math
import random
import sys
import zlib
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

sys.dont_write_bytecode = True   # keep tools/ free of __pycache__
sys.path.insert(0, str(Path(__file__).resolve().parent))
from leagues import (  # noqa: E402  (tools/leagues.py: tile vocabulary + league painters)
    A_SURF, A_START, A_SEC1, A_SEC2, ATTR_NAMES, DRIVABLE, FLAG_BITS, SURF,
    SURF_DOT, SURF_SEAM_V, SURF_SEAM_H, SURF_SEAM_X, RUT, EDGE_OPEN, WALL, COOLANT,
    BAY, VENT, RAMP, START, SEC1, SEC2, WALL_DIAG, EDGE_DIAG, GAP, A_OFF, NTILES,
    VENT_LANE, VENT_MOUTH, SWEEP_LANE, SWEEP_GATE, PIPE, PIPE_RIB, PIT, A_WALL,
    N_, E_, S_, W_, rgb565, pack4, LEAGUES
)

CART = Path(__file__).resolve().parent.parent
OUT = CART / "cart" / "src" / "gen" / "tracks"
T, MAPN, WORLD, NSAMP = 8, 128, 1024, 256
MARGIN = 100   # px between the centerline and the map's wrap edges
# Ramp pit: off-track tiles across the whole width, (GAP_LO, GAP_HI] px past
# the middle of the ramp band (which is (-12, 12]). 32 px > the 24 px
# footprint, so a car that does not jump falls in; a jump (40 ticks) from the
# ramp at 1.5 px/tick already lands past the pit. Ramp and pit move together
# by whole tiles (HOP_SHIFTS px from the segment middle) until no centerline
# sample is a spot where a stopped car would sit wholly in the pit.
GAP_LO, GAP_HI = 12, 44
HOP_SHIFTS = (0, 8, -8, 16, -16, 24, -24)
HALF_LEN, HALF_WID = 12, 6   # tuning.zig car footprint
# Hill runs (flag bit 7): at least HILL_MIN consecutive samples, clear of
# ramp segments and of the start line / sector seams by SEAM_CLEAR samples.
HILL_MIN, SEAM_CLEAR = 12, 3
SEAMS = (0, 85, 170)
# RMA crate rows (tuning.zig crate_gap, crate_row4_half; world.crate_max).
CRATE_GAP, CRATE_ROW4_HALF, CRATE_MAX, CRATE_BIT = 20, 56, 16, 2
# Hazards (world.hazard_max; track.zig HazardSpec, hazard_record). Defaults
# are SPEC 3.3's: a vent fires on a 240-tick timer for 30 ticks (20 damage
# and a sideways push); the Sweeper deals 60 and a shove. Speeds and pushes
# in 1/32 px/tick. Kinds: world.HazardKind.
HAZARD_MAX, HAZARD_RECORD = 4, 20
K_BLAST, K_MOVER = 1, 2
VENT_DEFAULTS = dict(period=240, on=30, warn=40, phase=0, damage=20, push=56, size=10)
SWEEPER_DEFAULTS = dict(period=600, warn=60, phase=0, damage=60, push=64, size=18, speed=40)
# The Sweeper parks this far beyond the road's edge (centre), the vent mouth
# sits this far out (in the wall row).
SWEEP_PARK, VENT_OUT = 34, 4
HAZARD_WORDS = {"vent": VENT_DEFAULTS, "sweeper": SWEEPER_DEFAULTS}


# ---------------------------------------------------------------- map packing
LZ_MIN, LZ_MAXLEN, LZ_MAXLIT, LZ_MAXD = 3, 130, 128, 32768


def pack_map(src):
    """Greedy LZ77 (format in the module docstring), one step of lazy matching."""
    src, out, lit, chains = bytes(src), bytearray(), bytearray(), {}
    n = len(src)

    def flush():
        while lit:
            k = min(len(lit), LZ_MAXLIT)
            out.append(k - 1)
            out.extend(lit[:k])
            del lit[:k]

    def cost(d):
        return 2 if d <= 128 else 3

    def best(i):
        bl, bd = 0, 0
        for j in reversed(chains.get(src[i:i + 3], [])[-256:]):
            d = i - j
            if d > LZ_MAXD:
                break
            ln = 0
            while ln < LZ_MAXLEN and i + ln < n and src[j + ln] == src[i + ln]:
                ln += 1
            if ln >= LZ_MIN and (bl == 0 or ln - cost(d) > bl - cost(bd)):
                bl, bd = ln, d
        return bl, bd

    def add(i):
        if i + 3 <= n:
            chains.setdefault(src[i:i + 3], []).append(i)

    i = 0
    while i < n:
        ln, d = best(i) if i + LZ_MIN <= n else (0, 0)
        if ln and i + 1 + LZ_MIN <= n and best(i + 1)[0] > ln + 1:
            ln = 0                        # lazy: a literal now buys a longer match next
        if not ln:
            lit.append(src[i])
            add(i)
            i += 1
            continue
        flush()
        out.append(0x80 | (ln - LZ_MIN))
        out += bytes([d - 1]) if d <= 128 else bytes([0x80 | (d - 1) >> 8, (d - 1) & 0xFF])
        for k in range(ln):
            add(i + k)
        i += ln
    flush()
    return bytes(out)


def unpack_map(p, size=16384):
    """Independent decoder (the cart's track.unpack_map does the same)."""
    o, i = bytearray(), 0
    while len(o) < size:
        c = p[i]
        i += 1
        if c < 0x80:
            o += p[i:i + c + 1]
            i += c + 1
        else:
            b = p[i]
            i += 1
            d = b + 1
            if b >= 0x80:
                d = ((b & 0x7F) << 8 | p[i]) + 1
                i += 1
            if d > len(o):
                raise ValueError("back-reference before the start")
            for _ in range((c & 0x7F) + LZ_MIN):
                o.append(o[-d])
    if len(o) != size or i != len(p):
        raise ValueError(f"unpacked {len(o)} bytes from {i} of {len(p)}")
    return bytes(o)


# ---------------------------------------------------------------- tracks
def parse_track(path):
    league, width, pts, pit_band = None, 64, [], 4
    for ln, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.split("#", 1)[0].split()
        if not line:
            continue
        if line[0] == "league":
            league = line[1]
        elif line[0] == "width":
            width = int(line[1])
        elif line[0] == "pit_band":
            pit_band = int(line[1])
        else:
            x, y = float(line[0]), float(line[1])
            half = float(line[2]) if len(line) > 2 else float(width)
            feats, opts, side = set(), {}, None
            for f in line[3:]:
                name, _, rest = f.partition(":")
                name, _, kv = name.partition(",")
                args = [a for a in (rest.split(",") if rest else []) + (kv.split(",") if kv else []) if a]
                if name not in FLAG_BITS and name not in ("crates", "sweeper", "pipe"):
                    raise SystemExit(f"{path}:{ln}: unknown feature {f!r}")
                feats.add(name)
                if name == "open":
                    side = args[0] if args else "both"
                    if side not in ("both", "left", "right"):
                        raise SystemExit(f"{path}:{ln}: open takes :left or :right (driver's side), got {f!r}")
                elif name in ("bay", "vent"):
                    pos = [a for a in args if "=" not in a]
                    opts.setdefault(name, {})["side"] = pos[0] if pos else ("both" if name == "bay" else "left")
                    if opts[name]["side"] not in ("both", "left", "right"):
                        raise SystemExit(f"{path}:{ln}: {name} takes :left or :right, got {f!r}")
                if name in HAZARD_WORDS:
                    o = dict(HAZARD_WORDS[name])
                    for a in args:
                        if "=" in a:
                            k, _, v = a.partition("=")
                            if k not in o:
                                raise SystemExit(f"{path}:{ln}: {name} has no option {k!r}")
                            o[k] = int(v)
                    o.update(opts.get(name, {}))
                    opts[name] = o
            pts.append((x, y, half, feats, 0, side, opts))
    if league not in LEAGUES or len(pts) < 4:
        raise SystemExit(f"{path}: needs a known league and at least 4 control points")
    return league, pts, pit_band


def catmull_rom(pts, per_seg=600):
    """Centripetal Catmull-Rom through the closed point list. Returns fine
    samples (x, y, u) with u = segment index + t."""
    P = np.array([(p[0], p[1]) for p in pts])
    n = len(P)
    xs, us = [], []
    for i in range(n):
        p0, p1, p2, p3 = P[(i - 1) % n], P[i], P[(i + 1) % n], P[(i + 2) % n]
        t0 = 0.0
        t1 = t0 + np.linalg.norm(p1 - p0) ** 0.5
        t2 = t1 + np.linalg.norm(p2 - p1) ** 0.5
        t3 = t2 + np.linalg.norm(p3 - p2) ** 0.5
        tt = np.linspace(0, 1, per_seg, endpoint=False)
        t = (t1 + (t2 - t1) * tt)[:, None]
        a1 = (t1 - t) / (t1 - t0) * p0 + (t - t0) / (t1 - t0) * p1
        a2 = (t2 - t) / (t2 - t1) * p1 + (t - t1) / (t2 - t1) * p2
        a3 = (t3 - t) / (t3 - t2) * p2 + (t - t2) / (t3 - t2) * p3
        b1 = (t2 - t) / (t2 - t0) * a1 + (t - t0) / (t2 - t0) * a2
        b2 = (t3 - t) / (t3 - t1) * a2 + (t - t1) / (t3 - t1) * a3
        xs.append((t2 - t) / (t2 - t1) * b1 + (t - t1) / (t2 - t1) * b2)
        us.append(i + tt)
    xy = np.concatenate(xs + [xs[0][:1]])
    u = np.concatenate(us + [[float(n)]])
    return xy, u


class Track:
    def __init__(self, path):
        self.name = path.stem
        self.league, self.pts, self.pit_band = parse_track(path)
        n = len(self.pts)
        fine, u = catmull_rom(self.pts)
        seglen = np.hypot(*np.diff(fine, axis=0).T)
        cum = np.concatenate([[0], np.cumsum(seglen)])
        self.length = L = cum[-1]
        nd = int(round(L))                       # dense points ~1 px apart
        s = np.arange(nd) * (L / nd)
        self.ds = L / nd
        self.dx = np.interp(s, cum, fine[:, 0])
        self.dy = np.interp(s, cum, fine[:, 1])
        du = np.interp(s, cum, u)
        self.seg = np.minimum(du.astype(int), n - 1)
        t = du - self.seg
        sm = t * t * (3 - 2 * t)
        h0 = np.array([p[2] for p in self.pts])
        self.dhalf = h0[self.seg] + (h0[(self.seg + 1) % n] - h0[self.seg]) * sm
        self.seg_start = np.interp(np.arange(n + 1), u, cum)   # arc of each control point
        self.flags = []
        for p in self.pts:
            f = 0 if p[5] == "both" else 1 << FLAG_BITS["wall"]   # one-sided open keeps a wall
            for name in p[3]:
                if name in FLAG_BITS and name != "wall":
                    f |= 1 << FLAG_BITS[name]
            self.flags.append(f)
        self.dflags = np.array(self.flags)[self.seg]
        # 256 equally spaced samples, sample 0 at control point 0.
        k = (np.arange(NSAMP) * nd) // NSAMP
        self.sidx = k
        nxt, prv = (k + 2) % nd, (k - 2) % nd
        ang = np.arctan2(self.dy[nxt] - self.dy[prv], self.dx[nxt] - self.dx[prv])
        self.turn = np.round(ang / (2 * np.pi) * 65536).astype(np.int64) % 65536
        # Crate rows: the sample nearest the middle of each `crates` segment.
        self.crate_rows = []
        for i, p in enumerate(self.pts):
            if "crates" in p[3]:
                mid = (self.seg_start[i] + self.seg_start[i + 1]) / 2
                self.crate_rows.append(int(np.argmin(np.abs(self.arc_dist(self.sidx * self.ds, mid)))))

    def crates(self):
        """Crate positions (x, y, sample) as track.find_crates places them."""
        out = []
        for k in sorted(self.crate_rows):
            j = self.sidx[k]
            x, y, h = int(round(self.dx[j])), int(round(self.dy[j])), int(round(self.dhalf[j]))
            a = self.turn[k] / 65536 * 2 * math.pi
            n = 4 if h >= CRATE_ROW4_HALF else 3
            for c in range(n):
                lat = (2 * c - (n - 1)) * CRATE_GAP // 2
                out.append((x - math.sin(a) * lat, y + math.cos(a) * lat, k))
        return out

    def arc_dist(self, a, b):
        """Signed wrapped arc distance a - b."""
        L = self.length
        return (a - b + L / 2) % L - L / 2


def nearest_dense(trk, tiles_yx):
    """For tile coords (N,2) return the nearest dense index and distance from tile centres."""
    cy = tiles_yx[:, 0] * T + 4.0
    cx = tiles_yx[:, 1] * T + 4.0
    best = np.zeros(len(cx), int)
    bestd = np.full(len(cx), np.inf)
    for j0 in range(0, len(trk.dx), 512):
        ddx = cx[:, None] - trk.dx[None, j0:j0 + 512]
        ddy = cy[:, None] - trk.dy[None, j0:j0 + 512]
        d2 = ddx * ddx + ddy * ddy
        j = d2.argmin(1)
        dj = d2[np.arange(len(cx)), j]
        better = dj < bestd
        best[better], bestd[better] = j[better] + j0, dj[better]
    return best, np.sqrt(bestd)


def axis_of(turn):
    """0 when travel is mostly along x, 1 when mostly along y."""
    q = ((turn + 8192) // 16384) % 4
    return int(q % 2)


def build_track(trk, ts, lg, rng):
    nd = len(trk.dx)
    # 1. Surface mask by stamping discs, then majority-rule tiles.
    mask = np.zeros((WORLD, WORLD), bool)
    discs = {}
    for j in range(nd):
        r = int(round(trk.dhalf[j]))
        if r not in discs:
            yy, xx = np.mgrid[-r:r + 1, -r:r + 1]
            discs[r] = xx * xx + yy * yy <= r * r
        x, y = int(round(trk.dx[j])), int(round(trk.dy[j]))
        mask[y - r:y + r + 1, x - r:x + r + 1] |= discs[r]
    surf = mask.reshape(MAPN, T, MAPN, T).sum((1, 3)) >= 32
    # 2. Nearest centerline point for every tile near the track.
    near = surf.copy()
    for _ in range(2):
        g = near.copy()
        g[1:] |= near[:-1]; g[:-1] |= near[1:]; g[:, 1:] |= near[:, :-1]; g[:, :-1] |= near[:, 1:]
        g[1:, 1:] |= near[:-1, :-1]; g[:-1, :-1] |= near[1:, 1:]; g[1:, :-1] |= near[:-1, 1:]; g[:-1, 1:] |= near[1:, :-1]
        near = g
    nyx = np.argwhere(near)
    nj, _ = nearest_dense(trk, nyx)
    jmap = np.full((MAPN, MAPN), -1, int)
    jmap[nyx[:, 0], nyx[:, 1]] = nj
    arc = lambda ty, tx: jmap[ty, tx] * trk.ds
    turn_at = lambda j: math.atan2(trk.dy[(j + 2) % nd] - trk.dy[j - 2], trk.dx[(j + 2) % nd] - trk.dx[j - 2])
    tturn = lambda j: int(round(turn_at(j) / (2 * math.pi) * 65536)) % 65536
    dir4 = lambda j: ((tturn(j) + 8192) // 16384) % 4

    tmap = np.zeros((MAPN, MAPN), np.uint8)
    # 3. Plain surface with a faint 16 px seam rhythm.
    for ty, tx in np.argwhere(surf):
        v, h = tx % 2 == 0, ty % 2 == 0
        tmap[ty, tx] = SURF_SEAM_X if v and h else SURF_SEAM_V if v else SURF_SEAM_H if h else SURF
    plain = lambda ty, tx: tmap[ty, tx] in (SURF, SURF_SEAM_V, SURF_SEAM_H, SURF_SEAM_X)
    # Lane-centre dots every 32 px of arc.
    for j in range(0, nd, int(32 / trk.ds)):
        ty, tx = int(trk.dy[j]) // T, int(trk.dx[j]) // T
        if surf[ty, tx]:
            tmap[ty, tx] = SURF_DOT
    # Cable ruts: short runs of worn grooves along the travel axis, scattered
    # over the plain surface (the league's RUT tiles; purely visual).
    for ty, tx in np.argwhere(surf):
        if plain(ty, tx) and tmap[ty, tx] != SURF_DOT and rng.random() < 0.07:
            tmap[ty, tx] = RUT + axis_of(tturn(jmap[ty, tx]))
    surf_list = [tuple(p) for p in np.argwhere(surf)]

    def band(j, lo, hi, tiles):
        """Tiles cut by a straight band across the track at dense point j."""
        a = round(turn_at(j) / (math.pi / 4)) * (math.pi / 4)
        ux, uy = math.cos(a), math.sin(a)
        res = []
        for ty, tx in tiles:
            rx, ry = tx * T + 4 - trk.dx[j], ty * T + 4 - trk.dy[j]
            along, across = rx * ux + ry * uy, -rx * uy + ry * ux
            if lo < along <= hi and abs(across) <= trk.dhalf[j] + 10 \
                    and abs(trk.arc_dist(arc(ty, tx), j * trk.ds)) < 64:
                res.append((ty, tx))
        return res
    def lateral(ty, tx):
        """Driver's-right offset of a tile centre from its nearest line point."""
        j = jmap[ty, tx]
        ox, oy = tx * T + 4 - trk.dx[j], ty * T + 4 - trk.dy[j]
        tdx, tdy = trk.dx[(j + 2) % nd] - trk.dx[j - 2], trk.dy[(j + 2) % nd] - trk.dy[j - 2]
        return (tdx * oy - tdy * ox) / math.hypot(tdx, tdy)   # y down: > 0 is the driver's right

    def across_axes(j):
        """Snapped unit tangent (ux, uy) and driver's right (rx, ry) at dense point j."""
        a = round(turn_at(j) / (math.pi / 4)) * (math.pi / 4)
        ux, uy = math.cos(a), math.sin(a)
        return ux, uy, -uy, ux
    # 4. Segment features.
    bands = []   # band centre arcs, kept clear of hot spots
    hops = []    # dense index of each ramp's centre
    trk.hazards = []   # (kind, dense index, options, (x0, y0), (x1, y1)) in control point order
    for i, p in enumerate(trk.pts):
        feats, opts = p[3], p[6]
        a, b = trk.seg_start[i], trk.seg_start[i + 1]
        mid = (a + b) / 2
        if "bay" in feats:
            side = opts["bay"]["side"]
            for ty, tx in surf_list:
                if trk.seg[jmap[ty, tx]] == i and (side == "both" or (lateral(ty, tx) > 2) == (side == "right")
                                                   and abs(lateral(ty, tx)) > 2):
                    tmap[ty, tx] = BAY + axis_of(tturn(jmap[ty, tx]))
        if "pipe" in feats:
            # Ribs every 24 px, straight across on the segment's snapped
            # axis (a pipe segment should be a straight run).
            jm = int(round(mid / trk.ds)) % nd
            ux, uy, _, _ = across_axes(jm)
            for ty, tx in surf_list:
                if trk.seg[jmap[ty, tx]] == i and (plain(ty, tx) or tmap[ty, tx] in (SURF_DOT, RUT, RUT + 1)):
                    along = (tx * T + 4 - trk.dx[jm]) * ux + (ty * T + 4 - trk.dy[jm]) * uy
                    tmap[ty, tx] = PIPE_RIB + axis_of(tturn(jm)) if math.floor(along / 8) % 3 == 0 else PIPE
        for name, base in (("coolant", COOLANT), ("ramp", RAMP)):
            if name in feats:
                bands.append(mid)
                jm = int(round(mid / trk.ds)) % nd
                if name == "ramp":
                    if round(turn_at(jm) / (math.pi / 4)) % 2:
                        raise SystemExit(f"{trk.name}: ramp on segment {i} must sit on a straight run along x or y")
                    for sh in HOP_SHIFTS:
                        j2 = (jm + int(round(sh / trk.ds))) % nd
                        if gap_ok(trk, j2, band(j2, GAP_LO, GAP_HI, surf_list)):
                            jm = j2
                            break
                    else:
                        raise SystemExit(f"{trk.name}: no clean place for the ramp pit near ({trk.dx[jm]:.0f},{trk.dy[jm]:.0f})")
                    hops.append(jm)
                for ty, tx in band(jm, -12, 12, surf_list):
                    tmap[ty, tx] = base + (dir4(jm) if base != COOLANT else 0)
        for name in ("vent", "sweeper"):
            if name not in feats:
                continue
            if p[5] is not None:
                raise SystemExit(f"{trk.name}: {name} on segment {i} needs walls on both sides (no open)")
            o = opts[name]
            bands.append(mid)
            jm = int(round(mid / trk.ds)) % nd
            ux, uy, rx, ry = across_axes(jm)
            h = trk.dhalf[jm]
            cx, cy = trk.dx[jm], trk.dy[jm]
            if name == "vent":
                out = h + VENT_OUT
                sgn = -1 if o["side"] == "left" else 1
                e0 = (cx + sgn * rx * out, cy + sgn * ry * out)
                e1 = (cx - sgn * rx * out, cy - sgn * ry * out)
                for ty, tx in band(jm, -o["size"], o["size"], surf_list):
                    if plain(ty, tx) or tmap[ty, tx] in (SURF_DOT, RUT, RUT + 1):
                        tmap[ty, tx] = VENT_LANE + axis_of(tturn(jm))
                trk.hazards.append((K_BLAST, jm, o, e0, e1))
            else:
                out = h + SWEEP_PARK
                e0 = (cx - rx * out, cy - ry * out)
                e1 = (cx + rx * out, cy + ry * out)
                for ty, tx in band(jm, -o["size"], o["size"], surf_list):
                    if plain(ty, tx) or tmap[ty, tx] in (SURF_DOT, RUT, RUT + 1):
                        tmap[ty, tx] = SWEEP_LANE + axis_of(tturn(jm))
                trk.hazards.append((K_MOVER, jm, o, e0, e1))
    # 5. Edges and walls from the 4-neighbour surface mask.
    pad = np.pad(surf, 1)
    m4 = (pad[:-2, 1:-1] * N_ | pad[1:-1, 2:] * E_ | pad[2:, 1:-1] * S_ | pad[1:-1, :-2] * W_).astype(int)
    diag = [pad[:-2, 2:], pad[2:, 2:], pad[2:, :-2], pad[:-2, :-2]]     # NE SE SW NW
    edge = np.zeros_like(surf)
    for ty, tx in np.argwhere(~surf & near):
        j = jmap[ty, tx]
        side = trk.pts[trk.seg[j]][5]
        if side in ("left", "right"):
            ox, oy = tx * T + 4 - trk.dx[j], ty * T + 4 - trk.dy[j]
            tdx, tdy = trk.dx[(j + 2) % nd] - trk.dx[j - 2], trk.dy[(j + 2) % nd] - trk.dy[j - 2]
            is_open = (tdx * oy - tdy * ox > 0) == (side == "right")   # y down: cross > 0 is the driver's right
        else:
            is_open = side == "both"
        if m4[ty, tx]:
            tmap[ty, tx] = (EDGE_OPEN if is_open else WALL) + m4[ty, tx]
            edge[ty, tx] = True
        else:
            for c in range(4):
                if diag[c][ty, tx]:
                    tmap[ty, tx] = (EDGE_DIAG if is_open else WALL_DIAG) + c
                    edge[ty, tx] = True
                    break
    open_edges = [tuple(q) for q in np.argwhere(edge & (ts.attr[tmap] == A_SURF))]
    # 5b. Hazard fittings in the walls: the vent's grille on its mouth side,
    #     the Sweeper's hazard-striped gates on both sides.
    walls = [tuple(q) for q in np.argwhere(edge & (ts.attr[tmap] == A_WALL))]
    for kind, jm, o, e0, e1 in trk.hazards:
        if kind == K_BLAST:
            sgn = -1 if o["side"] == "left" else 1
            for ty, tx in band(jm, -o["size"], o["size"], walls):
                if lateral(ty, tx) * sgn > 0:
                    tmap[ty, tx] = VENT_MOUTH + axis_of(tturn(jm))
        else:
            for ty, tx in band(jm, -o["size"] - 4, o["size"] + 4, walls):
                tmap[ty, tx] = SWEEP_GATE + axis_of(tturn(jm))
    # 6. Start line and sector seams (last, so they always win; they also
    #    cross open-edge tiles so the drivable strip is cut completely).
    for k, lo, hi, base in ((0, -8, 8, START), (85, -4, 4, SEC1), (170, -4, 4, SEC2)):
        j = trk.sidx[k]
        for ty, tx in band(j, lo, hi, surf_list + open_edges):
            tmap[ty, tx] = base if base == START else base + axis_of(tturn(j))
    # 7. Hop gaps: off-track void across the whole drivable width (open-edge
    #    glow included) just past each hop plate.
    for jm in hops:
        gap = band(jm, GAP_LO, GAP_HI, surf_list + open_edges)
        gset = set(gap)
        for ty, tx in gap:
            tmap[ty, tx] = GAP
        for ty, tx in gap:
            m = 0
            for bit, (yy, xx) in ((N_, (ty - 1, tx)), (E_, (ty, tx + 1)), (S_, (ty + 1, tx)), (W_, (ty, tx - 1))):
                if (yy, xx) not in gset and ts.attr[tmap[yy, xx]] in DRIVABLE:
                    m |= bit
            tmap[ty, tx] = GAP + m
    trk.hops = hops
    # 8. Pits beyond the open edges, so a drop reads as one (a band
    #    `pit_band` tiles deep); then the league background on the rest.
    free = ~surf & ~edge
    pit = pit_mask(free, edge & (ts.attr[tmap] == A_SURF), trk.pit_band)
    tmap[pit] = PIT
    lg["background"](tmap, free & ~pit, rng)
    return tmap, surf


def pit_mask(free, lips, depth):
    """Free tiles within `depth` tiles (Chebyshev) of an open lip: the pit a
    car drops into reads as one (the track's `pit_band`, default 4)."""
    near = lips.copy()
    for _ in range(depth):
        g = near.copy()
        g[1:] |= near[:-1]; g[:-1] |= near[1:]; g[:, 1:] |= near[:, :-1]; g[:, :-1] |= near[:, 1:]
        g[1:, 1:] |= near[:-1, :-1]; g[:-1, :-1] |= near[1:, 1:]; g[1:, :-1] |= near[:-1, 1:]; g[:-1, 1:] |= near[1:, :-1]
        near = g
    return near & free


def gap_ok(trk, jm, gap):
    """No centerline sample is a spot where a stopped car (24x12 on the
    line heading) sits wholly inside the pit."""
    gs = set(gap)
    nd = len(trk.dx)
    for k, j in enumerate(trk.sidx):
        a = trk.turn[k] / 65536 * 2 * math.pi
        hx, hy = math.cos(a), math.sin(a)
        inside = all((int(trk.dy[j] + al * hy + ac * hx) // T, int(trk.dx[j] + al * hx - ac * hy) // T) in gs
                     for al in (-HALF_LEN, HALF_LEN) for ac in (-HALF_WID, HALF_WID))
        if inside:
            return False
    return True


def center_bytes(trk):
    out = bytearray()
    for k, j in enumerate(trk.sidx):
        x, y = int(round(trk.dx[j])), int(round(trk.dy[j]))
        h = int(round(trk.dhalf[j]))
        f = int(trk.dflags[j]) | ((1 << CRATE_BIT) if k in trk.crate_rows else 0)
        out += np.array([x, y, trk.turn[k]], "<u2").tobytes() + bytes([h, f])
    return bytes(out)


def hazard_bytes(trk):
    """The track's hazard records (track.zig hazard_record)."""
    out = bytearray()
    for kind, jm, o, e0, e1 in trk.hazards:
        x0, y0, x1, y1 = (int(round(v)) & 1023 for v in (*e0, *e1))
        on = o["on"] if kind == K_BLAST else 0
        speed = o["speed"] if kind == K_MOVER else 0
        out += bytes([kind, o["warn"], o["size"], o["damage"]])
        out += np.array([x0, y0, x1, y1, o["period"], on, o["phase"] % o["period"]], "<u2").tobytes()
        out += bytes([o["push"], speed])
    assert len(out) == HAZARD_RECORD * len(trk.hazards)
    return bytes(out)


def validate_hazards(trk, tmap, ts, surf, errs):
    """At most HAZARD_MAX; each cycle fits its period; clear of the start
    line and sector seams; a Sweeper's path off the road never comes near
    another part of the track."""
    if len(trk.hazards) > HAZARD_MAX:
        errs.append(f"{trk.name}: {len(trk.hazards)} hazards, over the {HAZARD_MAX} the World holds")
    for kind, jm, o, e0, e1 in trk.hazards:
        where = f"{trk.name}: {'vent' if kind == K_BLAST else 'sweeper'} at ({trk.dx[jm]:.0f},{trk.dy[jm]:.0f})"
        if min(abs(trk.arc_dist(jm * trk.ds, trk.sidx[k] * trk.ds)) for k in SEAMS) < 40:
            errs.append(f"{where}: within 40 px of the start line or a sector seam")
        ln = math.hypot(e1[0] - e0[0], e1[1] - e0[1])
        if kind == K_BLAST:
            if o["on"] + o["warn"] >= o["period"]:
                errs.append(f"{where}: on + warn must be under the period")
            continue
        travel = math.ceil(int(ln) * 32 / o["speed"])
        if travel + o["warn"] >= o["period"] // 2:
            errs.append(f"{where}: crossing {travel} + warn {o['warn']} ticks must be under half the period {o['period']}")
        reach = o["size"] + 12
        h = trk.dhalf[jm]
        for t in np.linspace(0, 1, int(ln // 4) + 1):
            x, y = e0[0] + (e1[0] - e0[0]) * t, e0[1] + (e1[1] - e0[1]) * t
            if abs(t - 0.5) * ln <= h:
                continue
            ys, xs = np.mgrid[int(y - reach) // T:int(y + reach) // T + 1, int(x - reach) // T:int(x + reach) // T + 1]
            for ty, tx in zip(ys.ravel(), xs.ravel()):
                if 0 <= ty < MAPN and 0 <= tx < MAPN and surf[ty, tx] \
                        and math.hypot(tx * T + 4 - x, ty * T + 4 - y) < reach:
                    near, _ = nearest_dense(trk, np.array([[ty, tx]]))
                    if abs(trk.arc_dist(near[0] * trk.ds, jm * trk.ds)) > 4 * h:
                        errs.append(f"{where}: its path off the road passes another part of the track at ({x:.0f},{y:.0f})")
                        return


def validate_crates(trk, tmap, ts, errs):
    """Every crate on plain road (surface, no feature tile within 8 px), at
    most CRATE_MAX in all, rows clear of the start line and sector seams."""
    crates = trk.crates()
    if len(crates) > CRATE_MAX:
        errs.append(f"{trk.name}: {len(crates)} crates, over the {CRATE_MAX} the World holds")
    a = ts.attr[tmap]
    for x, y, k in crates:
        for ox in (-8, 0, 8):
            for oy in (-8, 0, 8):
                tx, ty = int(x + ox) // T % MAPN, int(y + oy) // T % MAPN
                if a[ty, tx] != A_SURF:
                    errs.append(f"{trk.name}: crate at ({x:.0f},{y:.0f}) (sample {k}) not on plain road "
                                f"(attribute {ATTR_NAMES[a[ty, tx]]} at {ox:+d},{oy:+d})")
                    return crates
    for k in trk.crate_rows:
        if any(min((k - s) % NSAMP, (s - k) % NSAMP) < SEAM_CLEAR for s in SEAMS):
            errs.append(f"{trk.name}: crate row at sample {k} too close to the start line or a sector seam")
    return crates


def validate(trk, tmap, ts, errs):
    attr = ts.attr
    a = attr[tmap]
    in_gap = (tmap >= GAP) & (tmap < GAP + 16)
    for j in range(len(trk.dx)):
        ty, tx = int(trk.dy[j]) // T, int(trk.dx[j]) // T
        v = a[ty, tx]
        if in_gap[ty, tx] and trk.dflags[j] & (1 << FLAG_BITS["ramp"]):
            continue
        if v not in DRIVABLE:
            errs.append(f"{trk.name}: centerline point {j} at ({trk.dx[j]:.0f},{trk.dy[j]:.0f}) on attribute {v}")
            break
    for name in set(ts.names[i] for i in np.unique(tmap)):
        if name is None:
            errs.append(f"{trk.name}: map uses an undefined tile")
    lo, hi = MARGIN, WORLD - MARGIN
    if not (trk.dx.min() >= lo and trk.dx.max() <= hi and trk.dy.min() >= lo and trk.dy.max() <= hi):
        errs.append(f"{trk.name}: centerline leaves the {MARGIN} px margin")
    if (a[0] | a[-1]).any() or (a[:, 0] | a[:, -1]).any():
        errs.append(f"{trk.name}: track touches the map border")
    # Clearance: parts of the line far apart in arc must be far apart in space.
    step = 4
    P = np.stack([trk.dx[::step], trk.dy[::step]], 1)
    H = trk.dhalf[::step]
    d = np.hypot(*(P[:, None] - P[None]).transpose(2, 0, 1))
    ia = np.arange(len(P)) * step * trk.ds
    darc = np.abs(trk.arc_dist(ia[:, None], ia[None]))
    need = H[:, None] + H[None] + 3 * T
    far = darc > need * 2
    gap = np.where(far, d - need, 1e9)
    i0, i1 = np.unravel_index(gap.argmin(), gap.shape)
    clear = gap[i0, i1]
    if clear < 0:
        errs.append(f"{trk.name}: track parts too close (clearance {clear:.0f} px) between "
                    f"({P[i0, 0]:.0f},{P[i0, 1]:.0f}) and ({P[i1, 0]:.0f},{P[i1, 1]:.0f})")
    # Start + sector bands must cut the drivable loop into three pieces.
    driv = np.isin(a, list(DRIVABLE - {A_START, A_SEC1, A_SEC2}))
    lab = label4(driv)
    probes = [trk.sidx[k] for k in (42, 128, 213)]
    ids = [lab[int(trk.dy[j]) // T, int(trk.dx[j]) // T] for j in probes]
    if len(set(ids)) != 3 or 0 in ids:
        errs.append(f"{trk.name}: start/sector bands do not cut the track into 3 regions {ids}")
    # Each ramp pit cuts the loop once more: drivable minus the start line is
    # one piece without hops, 1 + hops pieces with them.
    pieces = label4(np.isin(a, list(DRIVABLE - {A_START}))).max()
    if pieces != 1 + len(trk.hops):
        errs.append(f"{trk.name}: drivable floor minus the start line is {pieces} pieces, expected {1 + len(trk.hops)} (ramp pits must cut the whole width)")
    return clear


def hill_runs(trk):
    """Circular runs of hill-flagged samples as (first, last, length)."""
    hb = 1 << FLAG_BITS["hill"]
    on = [bool(int(trk.dflags[j]) & hb) for j in trk.sidx]
    if all(on):
        return [(0, NSAMP - 1, NSAMP)]
    runs, k0 = [], next(k for k in range(NSAMP) if not on[k])   # start just after an off sample
    k, n = (k0 + 1) % NSAMP, 0
    while n < NSAMP:
        if on[k]:
            a, ln = k, 0
            while on[k] and n < NSAMP:
                ln, k, n = ln + 1, (k + 1) % NSAMP, n + 1
            runs.append((a, (a + ln - 1) % NSAMP, ln))
        else:
            k, n = (k + 1) % NSAMP, n + 1
    return sorted(runs)


def validate_hills(trk, errs):
    pb = 1 << FLAG_BITS["ramp"]
    runs = hill_runs(trk)
    for a, b, ln in runs:
        ks = [(a + i) % NSAMP for i in range(ln)]
        if ln < HILL_MIN:
            errs.append(f"{trk.name}: hill run {a}..{b} is {ln} samples, under {HILL_MIN} (reads as a bump)")
        if any(int(trk.dflags[trk.sidx[k]]) & pb for k in ks):
            errs.append(f"{trk.name}: hill run {a}..{b} overlaps a ramp segment")
        for s in SEAMS:
            if any(min((k - s) % NSAMP, (s - k) % NSAMP) <= SEAM_CLEAR for k in ks):
                errs.append(f"{trk.name}: hill run {a}..{b} within {SEAM_CLEAR} samples of seam sample {s}")
    return runs


def min_radius(trk, step=12):
    """Smallest circumradius of (j - step, j, j + step) along the dense line."""
    nd = len(trk.dx)
    j = np.arange(nd)
    ax, ay = trk.dx[j - step], trk.dy[j - step]
    bx, by = trk.dx, trk.dy
    cx, cy = trk.dx[(j + step) % nd], trk.dy[(j + step) % nd]
    ab, bc, ca = np.hypot(ax - bx, ay - by), np.hypot(bx - cx, by - cy), np.hypot(cx - ax, cy - ay)
    cross = np.abs((bx - ax) * (cy - ay) - (by - ay) * (cx - ax))
    r = np.where(cross > 1e-9, ab * bc * ca / (2 * np.maximum(cross, 1e-9)), 1e9)
    k = int(r.argmin())
    return r[k], trk.dx[k], trk.dy[k], int(trk.seg[k])


def label4(m):
    """Connected-component labels (4-connectivity), 0 = background."""
    lab = np.zeros(m.shape, int)
    n = 0
    for sy, sx in np.argwhere(m):
        if lab[sy, sx]:
            continue
        n += 1
        stack = [(sy, sx)]
        lab[sy, sx] = n
        while stack:
            y, x = stack.pop()
            for yy, xx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                if 0 <= yy < m.shape[0] and 0 <= xx < m.shape[1] and m[yy, xx] and not lab[yy, xx]:
                    lab[yy, xx] = n
                    stack.append((yy, xx))
    return lab


def render_map(tmap, ts):
    idx = ts.tiles[tmap].transpose(0, 2, 1, 3).reshape(WORLD, WORLD)
    return ts.pal.rgb_array()[idx]


def write_preview(trk, tmap, ts, path):
    img = Image.fromarray(render_map(tmap, ts))
    dr = ImageDraw.Draw(img)
    pts = list(zip(trk.dx[::2], trk.dy[::2]))
    dr.line(pts + [pts[0]], fill=(255, 64, 200), width=1)
    x0, y0 = trk.dx[0], trk.dy[0]
    dr.ellipse([x0 - 5, y0 - 5, x0 + 5, y0 + 5], outline=(255, 255, 0), width=2)
    a = trk.turn[0] / 65536 * 2 * math.pi       # driving direction arrow at sample 0
    dr.line([(x0, y0), (x0 + 24 * math.cos(a), y0 + 24 * math.sin(a))], fill=(255, 255, 0), width=2)
    for k in (85, 170):
        j = trk.sidx[k]
        dr.ellipse([trk.dx[j] - 3, trk.dy[j] - 3, trk.dx[j] + 3, trk.dy[j] + 3], outline=(255, 255, 0))
    for x, y, _ in trk.crates():
        dr.rectangle([x - 4, y - 4, x + 4, y + 4], outline=(255, 255, 255))
    for kind, jm, o, e0, e1 in trk.hazards:   # vent lanes orange from the mouth, Sweeper paths yellow
        if kind == K_BLAST:
            dr.line([e0, e1], fill=(255, 120, 30), width=3)
            dr.ellipse([e0[0] - 5, e0[1] - 5, e0[0] + 5, e0[1] + 5], fill=(255, 60, 20))
        else:
            dr.line([e0, e1], fill=(255, 230, 40), width=1)
            for x, y in (e0, e1):
                r = o["size"]
                dr.ellipse([x - r, y - r, x + r, y + r], outline=(255, 230, 40), width=2)
    img.save(path, optimize=False)


def write_league(name, lg, out, docs):
    ts = lg["tiles"](lg["pal"])
    rng = random.Random(zlib.crc32(name.encode()))
    f, b, fpal, bpal = lg["horizon"](lg["pal"].rgb[0], rng)
    files = {
        out / f"{name}_tiles.bin": ts.tiles.tobytes(),
        out / f"{name}_pal.bin": lg["pal"].table565().tobytes(),
        out / f"{name}_horizon.bin": pack4(f) + pack4(b)
        + np.array([rgb565(c) for c in fpal], "<u2").tobytes() + np.array([rgb565(c) for c in bpal], "<u2").tobytes(),
        out / f"{name}_attr.bin": ts.attr.tobytes(),
    }
    for p, data in files.items():
        p.write_bytes(data)
    # Docs: contact sheet (4x, 1 px gaps), index list, horizon preview.
    rgb = lg["pal"].rgb_array()
    sheet = np.full((NTILES // 16 * 33 + 1, 16 * 33 + 1, 3), 255, np.uint8)
    for i in range(NTILES):
        y, x = divmod(i, 16)
        sheet[1 + y * 33:1 + y * 33 + 32, 1 + x * 33:1 + x * 33 + 32] = rgb[ts.tiles[i]].repeat(4, 0).repeat(4, 1)
    Image.fromarray(sheet).save(docs / f"{name}_tiles.png")
    lines = [f"# {name} tileset: index, name, attribute (generated by tools/build_tracks.py)"]
    lines += [f"{i:3d}  {n:34s} {ts.attr[i]} {ATTR_NAMES[ts.attr[i]]}" for i, n in enumerate(ts.names) if n]
    lines += [f"# unnamed indices (of {NTILES}) hold a copy of tile 1, attribute 0"]
    (docs / f"{name}_tiles.txt").write_text("\n".join(lines) + "\n")
    hz = np.zeros((64, 512, 3), np.uint8)
    back = np.array(bpal, np.uint8)[np.tile(b, 2)]
    front = np.array(fpal, np.uint8)[f]
    hz[:32] = np.where(f[..., None] > 0, front, back)
    hz[32:] = back
    Image.fromarray(hz.repeat(2, 0).repeat(2, 1)).save(docs / f"{name}_horizon.png")
    return ts, files, (f, b, fpal, bpal)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--track", help="build only this track (file stem)")
    ap.add_argument("--out", default=str(OUT))
    ap.add_argument("--docs", default=str(CART / "docs"), help="where the previews and tile sheets go")
    args = ap.parse_args()
    out, docs = Path(args.out), Path(args.docs)
    out.mkdir(parents=True, exist_ok=True)
    docs.mkdir(parents=True, exist_ok=True)
    paths = sorted((CART / "cart" / "src" / "tracks").glob("*.track"))
    if args.track:
        paths = [p for p in paths if p.stem == args.track]
        if not paths:
            raise SystemExit(f"no track named {args.track}")
    errs, sizes, leagues = [], {}, {}
    tracks = [Track(p) for p in paths]
    for trk in tracks:
        if trk.league not in leagues:
            ts, files, (f, b, fpal, bpal) = write_league(trk.league, LEAGUES[trk.league], out, docs)
            leagues[trk.league] = ts
            sizes.update({p: len(d) for p, d in files.items()})
            fog = ts.pal.rgb[0]
            if not ((f[-1] == 1).all() and fpal[1] == fog and (f == 15).any()):
                errs.append(f"{trk.league}: front horizon must end in a fog row (entry 1) and use LED entry 15")
            if f.max() > 15 or b.max() > 15:
                errs.append(f"{trk.league}: horizon pixel out of 4-bit range")
            if (ts.tiles == 0).any():
                errs.append(f"{trk.league}: a tile uses palette index 0")
            print(f"league {trk.league}: {len(ts.pal.rgb)} palette entries, "
                  f"{sum(n is not None for n in ts.names)} named tiles")
        ts = leagues[trk.league]
        rng = random.Random(zlib.crc32(trk.name.encode()))
        tmap, surf = build_track(trk, ts, LEAGUES[trk.league], rng)
        packed = pack_map(tmap.tobytes())
        if unpack_map(packed) != tmap.tobytes():
            errs.append(f"{trk.name}: packed map does not round-trip")
        files = {out / f"{trk.name}_map.bin": packed,
                 out / f"{trk.name}_center.bin": center_bytes(trk),
                 out / f"{trk.name}_feat.bin": hazard_bytes(trk)}
        for p, d in files.items():
            p.write_bytes(d)
            sizes[p] = len(d)
        write_preview(trk, tmap, ts, docs / f"{trk.name}_preview.png")
        clear = validate(trk, tmap, ts, errs)
        hills = validate_hills(trk, errs)
        crates = validate_crates(trk, tmap, ts, errs)
        validate_hazards(trk, tmap, ts, surf, errs)
        counts = np.bincount(ts.attr[tmap].ravel(), minlength=11)
        r, rx, ry, rseg = min_radius(trk)
        print(f"track {trk.name}: lap {trk.length:.0f} px, {len(trk.pts)} control points, "
              f"min clearance {clear:.0f} px, min radius {r:.0f} px at ({rx:.0f},{ry:.0f}) segment {rseg}, "
              f"{len(trk.hops)} ramp pit(s)")
        if hills:
            print("  hill samples (flag bit 7): " + ", ".join(f"{a}..{b} ({n})" for a, b, n in hills))
        if crates:
            rows = sorted(trk.crate_rows)
            print(f"  crate rows (flag bit 2) at samples {', '.join(map(str, rows))}: {len(crates)} crates")
        for kind, jm, o, e0, e1 in trk.hazards:
            print(f"  {'vent' if kind == K_BLAST else 'sweeper'} at sample ~{int(jm * NSAMP // len(trk.dx))}: "
                  f"({e0[0]:.0f},{e0[1]:.0f}) -> ({e1[0]:.0f},{e1[1]:.0f}), " + ", ".join(f"{k} {v}" for k, v in o.items()))
        print("  segment lengths: " + " ".join(f"{b - a:.0f}" for a, b in zip(trk.seg_start, trk.seg_start[1:])))
        print("  tiles per attribute: " + ", ".join(f"{ATTR_NAMES[i]} {c}" for i, c in enumerate(counts) if c))
        print(f"  start ({trk.dx[0]:.0f},{trk.dy[0]:.0f}) heading {trk.turn[0]}; sector1 sample 85 at "
              f"({trk.dx[trk.sidx[85]]:.0f},{trk.dy[trk.sidx[85]]:.0f}); sector2 sample 170 at "
              f"({trk.dx[trk.sidx[170]]:.0f},{trk.dy[trk.sidx[170]]:.0f})")
        if not 3500 <= trk.length <= 4500:
            errs.append(f"{trk.name}: lap length {trk.length:.0f} outside 3500..4500 (SPEC 5.2)")
        if tmap.max() >= NTILES:
            errs.append(f"{trk.name}: map uses tile {tmap.max()}, over the {NTILES}-tile set")
        if r < 30:
            errs.append(f"{trk.name}: corner radius {r:.0f} px at ({rx:.0f},{ry:.0f}) under 30 px (the autopilot needs ~30)")
    expect = {"tiles": NTILES * 64, "pal": 512, "horizon": 12352, "attr": NTILES, "center": 2048}
    packed_total = 0
    for p, n in sorted(sizes.items()):
        kind = p.stem.rsplit("_", 1)[1]
        if kind == "map":
            packed_total += n
            if n >= 8192:
                errs.append(f"{p.name}: packed map is {n} bytes, budget under 8192")
        elif kind == "feat":
            if n % HAZARD_RECORD:
                errs.append(f"{p.name}: {n} bytes, not whole {HAZARD_RECORD}-byte records")
        elif expect[kind] != n:
            errs.append(f"{p.name}: {n} bytes, expected {expect[kind]}")
        print(f"  {p.relative_to(CART) if p.is_relative_to(CART) else p}: {n} bytes")
    print(f"  packed maps: {packed_total} bytes")
    for e in errs:
        print("ERROR:", e, file=sys.stderr)
    sys.exit(1 if errs else 0)


if __name__ == "__main__":
    main()
