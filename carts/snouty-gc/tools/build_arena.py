#!/usr/bin/env python3
"""Build The Sandbox, the BATTLE arena (SPEC 8.3, M6), into cart/src/gen/tracks/.

    python3 tools/build_arena.py                 (from the cart directory)
    python3 tools/build_arena.py --out /tmp/x --docs /tmp/x

tools/build_tracks.py runs this too (so check.sh's `tracks` step covers the
arena). The arena is drawn on a grid, not along a centerline: a walled
square of floor in the Dumps tileset with

  * the bit bucket: a 128 px pit in the middle with a kicker (tile
    attribute `kicker`, `tuning.kicker_ticks` airborne) on each side;
  * four scrap islands at the diagonals (wall-ringed, scrap inside: a
    landing on one is a fall);
  * fences: a one-tile wall between the outer ring and each plaza, with a
    wall kicker (a 40-tick `ramp`) on the ring that jumps it;
  * gap jumps: ramp pairs over 40 px pits across the west and east
    straights near the corners;
  * 8 RMA crate pads (one per lane: the four ring straights, the four
    plazas), 2 service bays (NW and SE corners), 6 spawn pads on the rim
    facing in, the Sweeper along the north straight;
  * the navigation field the hunter AI steers by.

Files (track.zig `Track` fields):

  sandbox_map.bin     128x128 tile indices, packed like a track's map
  sandbox_center.bin  256 samples x 6 bytes (track.zig `Track.sample`): a
                      ring round the outer lanes, for the race code that
                      reads a centerline (battle never ranks or respawns by it)
  sandbox_feat.bin    hazard records (the Sweeper; build_tracks.py format)
  sandbox_arena.bin   the arena blob (track.zig `parse_arena`), little endian:
      header 8 bytes: spawn_n, pad_n, node_n, cell_shift (5: 32 px cells),
                      grid (32 cells a side), 3 reserved zero bytes
      spawn_n x 6:    x u16, y u16 (world px, the pad's centre), heading u16
                      (turn units, facing into the arena)
      pad_n x 4:      x u16, y u16: an RMA crate pad's centre
      node_n x 6:     x u16, y u16, jump u8 (the node this one jumps to over a
                      kicker or ramp, 0xFF none), flags u8 (bit 0 a service
                      bay, bit 1 a jump approach)
      node_n^2:       next hop: next[from * node_n + to] is the node after
                      `from` on the shortest path to `to` (`to` itself when
                      adjacent, 0xFF when `from == to`)
      grid^2:         cells[cy * grid + cx]: the node to head for from that
                      32 px cell (the nearest with a clear ground line), 0xFF
                      outside the arena

plus docs/sandbox_preview.png (the map with the nodes, edges, pads) and
docs/m6_sandbox.png (the same at 1:1, for the plan).

The ground edges of the navigation graph join nodes with a clear line for
a car (three parallel rays 8 px apart over drivable floor that is not a
ramp or kicker); jump edges are declared (approach node -> landing node,
straight over the ramp). The script validates the graph (every node
reaches every node), the jumps (each clears its pit at the speeds in
JUMP_SPEEDS and falls short below them), pads and spawns on plain floor,
and exits non-zero on any failure. Everything is deterministic.
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

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from leagues import (  # noqa: E402
    A_OFF, A_SURF, A_WALL, A_KICKER, A_JUMP, A_RAMP, A_BAY, ATTR_NAMES, DRIVABLE, LEAGUES,
    SURF, SURF_DOT, SURF_SEAM_V, SURF_SEAM_H, SURF_SEAM_X, RUT, WALL, WALL_DIAG, BAY, GAP,
    KICKER, JUMP, PAD_SPAWN, PAD_CRATE, SWEEP_LANE, SWEEP_GATE, N_, E_, S_, W_,
)
import build_tracks as bt  # noqa: E402  (pack_map, unpack_map, write_league)

CART = Path(__file__).resolve().parent.parent
OUT = CART / "cart" / "src" / "gen" / "tracks"
T, MAPN, WORLD = 8, 128, 1024
NAME, LEAGUE = "sandbox", "dumps"

# The play area: ARENA tiles a side from tile O (so the fences fall on 32 px
# cell edges: (O + 14) * 8 is a multiple of 32).
O, ARENA = 22, 88
# Car footprint and jumps (tuning.zig half_len, ramp_ticks, kicker_ticks).
HALF_LEN, HALF_WID = 12, 6
RAMP_TICKS, KICKER_TICKS = 40, 64
NAV_MAX, CELL_SHIFT, GRID = 48, 5, 32
# The corner gap jumps' pits, tiles across the lane's travel.
GAP_W = 7
SPAWN_MAX, PAD_MAX = 8, 16
FLAG_BAY, FLAG_JUMP = 1, 2
# The Sweeper (build_tracks.py's record): along the north straight.
SWEEPER = dict(period=1200, warn=60, phase=300, damage=60, push=64, size=18, speed=64)

# Cell kinds of the design grid (rel tile coordinates, 0..ARENA-1).
FLOOR, SOLID, PIT, FENCE = 0, 1, 2, 3


def rel_px(x, y):
    """World px of the centre of rel tile (x, y)."""
    return ((O + x) * T + T / 2, (O + y) * T + T / 2)


def corner_px(x, y):
    """World px of the top-left corner of rel tile (x, y)."""
    return ((O + x) * T, (O + y) * T)


class Arena:
    def __init__(self):
        n = ARENA
        k = np.full((n, n), FLOOR, np.uint8)
        # Scrap islands at the diagonals (14 tiles: 112 px).
        for x0 in (14, 60):
            for y0 in (14, 60):
                k[y0:y0 + 14, x0:x0 + 14] = SOLID
        # Fences between the ring and the plazas, one tile, 20 tiles long
        # (gaps of 6 tiles at each end, by the islands).
        k[14, 34:54] = FENCE
        k[73, 34:54] = FENCE
        k[34:54, 14] = FENCE
        k[34:54, 73] = FENCE
        # The bit bucket: 16 tiles (128 px).
        k[36:52, 36:52] = PIT
        # Gap jumps across the west and east straights near the corners:
        # GAP-tile pits with a 2-tile ramp each side facing the pit.
        self.ramps = []      # (x0, y0, x1, y1, direction): rel tiles inclusive
        self.kickers = []
        for x0, x1 in ((0, 13), (74, 87)):
            for gy0, rn, rs in ((16, 14, 16 + GAP_W), (72 - GAP_W, 70 - GAP_W, 72)):
                k[gy0:gy0 + GAP_W, x0:x1 + 1] = PIT
                self.ramps.append((x0, rn, x1, rn + 1, 1))      # facing S, north of the pit
                self.ramps.append((x0, rs, x1, rs + 1, 3))      # facing N, south of it
        # Wall kickers on the ring straights, facing in over the fences.
        self.ramps += [(41, 10, 46, 11, 1), (41, 76, 46, 77, 3), (10, 41, 11, 46, 0), (76, 41, 77, 46, 2)]
        # The bit bucket's kickers, one per side, facing the pit.
        self.kickers = [(41, 34, 46, 35, 1), (41, 52, 46, 53, 3), (34, 41, 35, 46, 0), (52, 41, 53, 46, 2)]
        self.kind = k
        # Service bays (6x6 tiles) in the NW and SE corners.
        self.bays = [(2, 2), (80, 80)]
        # Spawn pads (2x2 tiles, top-left rel tile, direction facing in):
        # two on the south straight, two each on the west and east
        # straights, each facing a gap into a plaza; none on the north
        # straight (the Sweeper's).
        self.spawns = [(30, 80, 3), (56, 80, 3), (5, 30, 0), (5, 56, 0), (81, 30, 2), (81, 56, 2)]
        # RMA crate pads (rel tile), one per lane.
        self.pads = [(44, 4), (43, 83), (4, 43), (83, 44), (44, 24), (43, 63), (24, 43), (63, 44)]
        self.build_nav_nodes()

    def build_nav_nodes(self):
        """Waypoints (rel tile, flags) and the declared jump edges."""
        nodes = {}

        def add(name, x, y, flags=0):
            nodes[name] = (x, y, flags)
        # Outer ring: corners, straights.
        add("nw", 7, 7)
        add("ne", 80, 7)
        add("se", 80, 80)
        add("sw", 7, 80)
        add("n1", 31, 7)
        add("n2", 56, 7)
        add("s1", 31, 80)
        add("s2", 56, 80)
        # Gap jumps: approach nodes either side (each jumps to the other).
        add("wn_a", 7, 9, FLAG_JUMP)
        add("wn_b", 7, 30, FLAG_JUMP)
        add("ws_a", 7, 57, FLAG_JUMP)
        add("ws_b", 7, 78, FLAG_JUMP)
        add("en_a", 80, 9, FLAG_JUMP)
        add("en_b", 80, 30, FLAG_JUMP)
        add("es_a", 80, 57, FLAG_JUMP)
        add("es_b", 80, 78, FLAG_JUMP)
        # Wall kicker approaches on the ring (jump into the plazas).
        add("nk", 44, 3, FLAG_JUMP)
        add("sk", 43, 84, FLAG_JUMP)
        add("wk", 3, 43, FLAG_JUMP)
        add("ek", 84, 44, FLAG_JUMP)
        # Fence gaps.
        add("gn1", 31, 14)
        add("gn2", 56, 14)
        add("gs1", 31, 73)
        add("gs2", 56, 73)
        add("gw1", 14, 31)
        add("gw2", 14, 56)
        add("ge1", 73, 31)
        add("ge2", 73, 56)
        # Inner ring corners round the bit bucket.
        add("i_nw", 31, 31)
        add("i_ne", 56, 31)
        add("i_sw", 31, 56)
        add("i_se", 56, 56)
        # Plazas: the bit bucket's approaches (each jumps to the opposite).
        add("pn", 44, 24, FLAG_JUMP)
        add("ps", 43, 63, FLAG_JUMP)
        add("pw", 24, 43, FLAG_JUMP)
        add("pe", 63, 44, FLAG_JUMP)
        # Service bays.
        add("bay_nw", 5, 5, FLAG_BAY)
        add("bay_se", 82, 82, FLAG_BAY)
        self.node_names = list(nodes)
        self.nodes = [nodes[n] for n in self.node_names]
        ix = {n: i for i, n in enumerate(self.node_names)}
        # Jump edges: (from, to). A node jumps to at most one other.
        jumps = [("wn_a", "wn_b"), ("wn_b", "wn_a"), ("ws_a", "ws_b"), ("ws_b", "ws_a"),
                 ("en_a", "en_b"), ("en_b", "en_a"), ("es_a", "es_b"), ("es_b", "es_a"),
                 ("nk", "pn"), ("sk", "ps"), ("wk", "pw"), ("ek", "pe"),
                 ("pn", "ps"), ("ps", "pn"), ("pw", "pe"), ("pe", "pw")]
        self.jumps = {ix[a]: ix[b] for a, b in jumps}
        assert len(self.jumps) == len(jumps)
        assert len(self.nodes) <= NAV_MAX


def tiles_of(ar):
    """The 128x128 tile map and its attribute map."""
    ts = LEAGUES[LEAGUE]["tiles"](LEAGUES[LEAGUE]["pal"])
    k = ar.kind
    n = ARENA
    # Map-sized kind grid: everything outside the play area is solid.
    big = np.full((MAPN, MAPN), SOLID, np.uint8)
    big[O:O + n, O:O + n] = k
    floor = big == FLOOR
    tmap = np.zeros((MAPN, MAPN), np.uint8)
    # Floor: the board road with its 16 px seam rhythm, solder dots every
    # 32 px, a few cable ruts.
    rng = random.Random(zlib.crc32(NAME.encode()))
    for ty, tx in np.argwhere(floor):
        v, h = tx % 2 == 0, ty % 2 == 0
        tmap[ty, tx] = SURF_SEAM_X if v and h else SURF_SEAM_V if v else SURF_SEAM_H if h else SURF
        if tx % 4 == 2 and ty % 4 == 2:
            tmap[ty, tx] = SURF_DOT
        elif rng.random() < 0.03:
            tmap[ty, tx] = RUT + rng.randrange(2)
    # Bays, ramps, kickers, pads (rel tiles).
    for bx, by in ar.bays:
        for y in range(by, by + 6):
            for x in range(bx, bx + 6):
                tmap[O + y, O + x] = BAY + (y % 2)
    for x0, y0, x1, y1, d in ar.ramps:
        tmap[O + y0:O + y1 + 1, O + x0:O + x1 + 1] = JUMP + d
    for x0, y0, x1, y1, d in ar.kickers:
        tmap[O + y0:O + y1 + 1, O + x0:O + x1 + 1] = KICKER + d
    for x, y, d in ar.spawns:
        tmap[O + y:O + y + 2, O + x:O + x + 2] = PAD_SPAWN + d
    for x, y in ar.pads:
        tmap[O + y, O + x] = PAD_CRATE
    # The Sweeper's lane: the striped crossing along the north straight
    # (cosmetic, attribute surface), and its gates in the rim.
    sy = ar.sweep_row
    for x in range(0, n):
        if tmap[O + sy, O + x] in (SURF, SURF_SEAM_V, SURF_SEAM_H, SURF_SEAM_X, SURF_DOT, RUT, RUT + 1):
            tmap[O + sy, O + x] = SWEEP_LANE
    # Walls (rim, island edges, fences) by the 4-neighbour drivable mask;
    # pits by theirs (GAP + mask of drivable neighbours).
    drivable = np.isin(ts.attr[tmap], list(DRIVABLE)) & (big != SOLID) & (big != PIT) & (big != FENCE)
    pad = np.pad(drivable, 1)
    m4 = (pad[:-2, 1:-1] * N_ | pad[1:-1, 2:] * E_ | pad[2:, 1:-1] * S_ | pad[1:-1, :-2] * W_).astype(int)
    diag = [pad[:-2, 2:], pad[2:, 2:], pad[2:, :-2], pad[:-2, :-2]]
    wall = np.zeros((MAPN, MAPN), bool)
    for ty, tx in np.argwhere((big == SOLID) | (big == FENCE)):
        if big[ty, tx] == FENCE:
            tmap[ty, tx] = WALL + (m4[ty, tx] or 15)
            wall[ty, tx] = True
        elif m4[ty, tx]:
            tmap[ty, tx] = WALL + m4[ty, tx]
            wall[ty, tx] = True
        else:
            for c in range(4):
                if diag[c][ty, tx]:
                    tmap[ty, tx] = WALL_DIAG + c
                    wall[ty, tx] = True
                    break
    for ty, tx in np.argwhere(big == PIT):
        tmap[ty, tx] = GAP + m4[ty, tx]
    # Sweeper gates in the rim at both ends of its lane.
    for x in (O - 1, O + n):
        tmap[O + sy, x] = SWEEP_GATE
    # Everything else: the Dumps wallpaper (scrap islands and beyond).
    free = (big == SOLID) & ~wall
    for x in (O - 1, O + n):
        free[O + sy, x] = False
    LEAGUES[LEAGUE]["background"](tmap, free, rng)
    return ts, tmap


def los(attr, a, b, clearance=8, allow=None):
    """A clear line for a car from a to b (world px): three rays (the line
    and `clearance` px either side) over drivable floor that is not a ramp
    or kicker (`allow`: extra attributes allowed, e.g. a jump's)."""
    ok = set(DRIVABLE) - {A_RAMP, A_KICKER, A_JUMP} | (allow or set())
    dx, dy = b[0] - a[0], b[1] - a[1]
    ln = math.hypot(dx, dy)
    if ln < 1:
        return True
    ux, uy = dx / ln, dy / ln
    for off in ((0,) if clearance == 0 else (-clearance, 0, clearance)):
        ox, oy = -uy * off, ux * off
        for s in np.arange(0, ln + 0.01, 2.0):
            x, y = a[0] + ux * s + ox, a[1] + uy * s + oy
            if attr[int(y) // T % MAPN, int(x) // T % MAPN] not in ok:
                return False
    return True


def node_px(ar, i):
    x, y, _ = ar.nodes[i]
    return rel_px(x, y)


def build_graph(ar, attr, errs):
    """Edge weights (dict (i, j) -> px), the all-pairs next hop and distances."""
    n = len(ar.nodes)
    w = {}
    for i in range(n):
        for j in range(n):
            if i != j and los(attr, node_px(ar, i), node_px(ar, j)):
                w[i, j] = math.dist(node_px(ar, i), node_px(ar, j))
    for a, b in ar.jumps.items():
        w[a, b] = math.dist(node_px(ar, a), node_px(ar, b))
    INF = 1e18
    dist = np.full((n, n), INF)
    nxt = np.full((n, n), 0xFF, np.int64)
    for i in range(n):
        dist[i, i] = 0
    for (i, j), d in w.items():
        dist[i, j] = d
        nxt[i, j] = j
    for k in range(n):
        for i in range(n):
            for j in range(n):
                if dist[i, k] + dist[k, j] < dist[i, j] - 1e-9:
                    dist[i, j] = dist[i, k] + dist[k, j]
                    nxt[i, j] = nxt[i, k]
    for i in range(n):
        for j in range(n):
            if i != j and dist[i, j] >= INF:
                errs.append(f"nav: node {ar.node_names[i]} cannot reach {ar.node_names[j]}")
                return w, nxt, dist
    return w, nxt, dist


def build_cells(ar, attr, errs):
    """cells[cy][cx]: the nearest node with a clear ground line from the
    cell (its centre, or failing that its floor tiles nearest the centre)."""
    cells = np.full((GRID, GRID), 0xFF, np.uint8)
    size = 1 << CELL_SHIFT
    pts = [node_px(ar, i) for i in range(len(ar.nodes))]
    lo, hi = O * T, (O + ARENA) * T
    for cy in range(GRID):
        for cx in range(GRID):
            x0, y0 = cx * size, cy * size
            if x0 + size <= lo or y0 + size <= lo or x0 >= hi or y0 >= hi:
                continue
            c = (x0 + size / 2, y0 + size / 2)
            # Candidate starting points: the centre, then floor tile centres
            # of the cell by distance to it.
            cand = [c] + sorted(((tx * T + 4, ty * T + 4) for ty in range(y0 // T, (y0 + size) // T)
                                 for tx in range(x0 // T, (x0 + size) // T)
                                 if attr[ty, tx] in DRIVABLE), key=lambda p: math.dist(p, c))
            best = None
            for p in cand[:6]:
                order = sorted(range(len(pts)), key=lambda i: math.dist(p, pts[i]))
                for i in order:
                    if los(attr, p, pts[i], clearance=0):
                        best = i
                        break
                if best is not None:
                    break
            if best is None:
                best = min(range(len(pts)), key=lambda i: math.dist(c, pts[i]))
            cells[cy, cx] = best
    return cells


FACING = ((1, 0), (0, 1), (-1, 0), (0, -1))   # tile direction 0 E, 1 S, 2 W, 3 N


def check_jumps(ar, attr, tmap, errs):
    """Each declared jump, flown straight from its approach node toward its
    landing node at the cart's rules (sim.zig step_car: the hop starts when
    a footprint corner touches a ramp or kicker, then `ticks` of flight at
    the run-up speed), lands with a corner on the floor at full speed and
    falls in at half speed. Returns the minimum safe speed per jump."""
    out = {}

    def over_pit(a, b):
        pa, pb = node_px(ar, a), node_px(ar, b)
        return any(attr[int(pa[1] + (pb[1] - pa[1]) * t) // T, int(pa[0] + (pb[0] - pa[0]) * t) // T] == A_OFF
                   for t in np.linspace(0, 1, 200))
    for a, b in ar.jumps.items():
        pa, pb = node_px(ar, a), node_px(ar, b)
        dx, dy = pb[0] - pa[0], pb[1] - pa[1]
        ln = math.hypot(dx, dy)
        ux, uy = dx / ln, dy / ln

        def corners(cx, cy):
            return [(cx + ux * al - uy * ac, cy + uy * al + ux * ac) for al in (-HALF_LEN, HALF_LEN) for ac in (-HALF_WID, HALF_WID)]

        def fly(v):
            x, y = pa
            hop = 0
            ticks = 0
            launched = False
            while ticks < 400:
                ticks += 1
                in_air = hop > 0
                if in_air:
                    hop -= 1
                x, y = x + ux * v, y + uy * v
                if in_air:
                    continue
                ts_ = [(int(cy) // T, int(cx) // T) for cx, cy in corners(x, y)]
                cs = [attr[q] for q in ts_]
                if all(c == A_OFF for c in cs):
                    return False
                if any(c == A_WALL for c in cs):
                    return launched
                for q, c in zip(ts_, cs):
                    # One-way: only a car moving the way the tile faces.
                    if c in (A_KICKER, A_JUMP):
                        f = FACING[(int(tmap[q]) - (KICKER if c == A_KICKER else JUMP)) & 3]
                        if f[0] * ux + f[1] * uy > 0:
                            hop, launched = (KICKER_TICKS if c == A_KICKER else RAMP_TICKS), True
                            break
                if launched and hop == 0 and math.hypot(x - pa[0], y - pa[1]) >= ln:
                    return True
            return launched
        # The lowest speed from which every faster run-up clears (a slow car
        # can be relaunched by the ramp under its rear wheels, so a lucky
        # crawl may clear too).
        lo = None
        for v10 in range(40, 4, -1):
            if not fly(v10 / 10):
                break
            lo = v10 / 10
        if lo is None or not fly(3.0) or not fly(2.7):
            errs.append(f"jump {ar.node_names[a]} -> {ar.node_names[b]}: not clean at full speed")
        if over_pit(a, b) and fly(0.6):
            errs.append(f"jump {ar.node_names[a]} -> {ar.node_names[b]}: a crawl clears the pit too")
        out[(a, b)] = lo
    return out


def center_bytes():
    """A ring through the outer lanes (256 samples), flags 0, half 40."""
    out = bytearray()
    cx, cy = rel_px(43.5, 43.5)
    r = 37 * T
    for k in range(256):
        # A rounded square (superellipse) so it stays in the ring lanes.
        a = 2 * math.pi * k / 256
        c, s = math.cos(a), math.sin(a)
        p = 6
        d = (abs(c) ** p + abs(s) ** p) ** (-1 / p)
        x, y = int(round(cx + r * d * c)), int(round(cy + r * d * s))
        tangent = int(round((a + math.pi / 2) / (2 * math.pi) * 65536)) % 65536
        t12 = ((tangent + 8) >> 4) & 4095
        out += np.array([(x & 1023) | (y & 1023) << 10 | t12 << 20], "<u4").tobytes() + bytes([40, 0])
    return bytes(out)


def sweeper_record(ar):
    """The Sweeper along the north straight, gate to gate (parked outside)."""
    y = rel_px(0, ar.sweep_row)[1]
    x0 = corner_px(-3, 0)[0]
    x1 = corner_px(ARENA + 3, 0)[0]
    o = SWEEPER
    rec = bytes([bt.K_MOVER, o["warn"], o["size"], o["damage"]])
    rec += np.array([int(x0), int(y), int(x1), int(y), o["period"], 0, o["phase"] % o["period"]], "<u2").tobytes()
    rec += bytes([o["push"], o["speed"]])
    travel = math.ceil(int(x1 - x0) * 32 / o["speed"])
    return rec, travel


def arena_blob(ar, nxt, cells):
    n = len(ar.nodes)
    out = bytearray([len(ar.spawns), len(ar.pads), n, CELL_SHIFT, GRID, 0, 0, 0])
    for x, y, d in ar.spawns:
        px, py = corner_px(x + 1, y + 1)
        out += np.array([px, py, d * 16384], "<u2").tobytes()
    for x, y in ar.pads:
        px, py = rel_px(x, y)
        out += np.array([int(px), int(py)], "<u2").tobytes()
    for i, (x, y, f) in enumerate(ar.nodes):
        px, py = rel_px(x, y)
        out += np.array([int(px), int(py)], "<u2").tobytes() + bytes([ar.jumps.get(i, 0xFF), f])
    out += bytes(int(v) & 0xFF for v in nxt.ravel())
    out += cells.tobytes()
    return bytes(out)


def write_preview(ar, tmap, ts, w, cells, path, path1):
    rgb = bt.render_map(tmap, ts)
    Image.fromarray(rgb).save(path1, optimize=False)
    img = Image.fromarray(rgb)
    dr = ImageDraw.Draw(img)
    for (i, j) in w:
        a, b = node_px(ar, i), node_px(ar, j)
        jump = ar.jumps.get(i) == j
        dr.line([a, b], fill=(255, 80, 200) if jump else (90, 140, 255), width=2 if jump else 1)
    for i, (x, y, f) in enumerate(ar.nodes):
        px, py = rel_px(x, y)
        col = (80, 255, 120) if f & FLAG_BAY else (255, 240, 60) if f & FLAG_JUMP else (255, 255, 255)
        dr.ellipse([px - 4, py - 4, px + 4, py + 4], outline=col, width=2)
        dr.text((px + 5, py - 5), ar.node_names[i], fill=col)
    for x, y, d in ar.spawns:
        px, py = corner_px(x + 1, y + 1)
        a = d * math.pi / 2
        dr.line([(px, py), (px + 18 * math.cos(a), py + 18 * math.sin(a))], fill=(255, 255, 255), width=2)
    for x, y in ar.pads:
        px, py = rel_px(x, y)
        dr.rectangle([px - 5, py - 5, px + 5, py + 5], outline=(255, 255, 255))
    img.save(path, optimize=False)


def build(out: Path, docs: Path, errs: list, quiet=False):
    """Write the arena's files into `out` (and its previews into `docs`);
    append any validation failure to `errs`. Returns {path: size}."""
    ar = Arena()
    ar.sweep_row = 7
    ts, tmap = tiles_of(ar)
    attr = ts.attr[tmap]
    # Validation: spawns, pads and nodes on plain floor; the play area closed.
    for x, y, d in ar.spawns:
        for yy in (y, y + 1):
            for xx in (x, x + 1):
                if attr[O + yy, O + xx] != A_SURF:
                    errs.append(f"spawn pad at rel ({x},{y}) not on floor")
    for x, y in ar.pads:
        for oy in (-1, 0, 1):
            for ox in (-1, 0, 1):
                if attr[O + y + oy, O + x + ox] not in (A_SURF,):
                    errs.append(f"crate pad at rel ({x},{y}) not on plain floor ({ATTR_NAMES[attr[O + y + oy, O + x + ox]]} at {ox:+d},{oy:+d})")
    for i, (x, y, f) in enumerate(ar.nodes):
        a = attr[O + y, O + x]
        if a not in DRIVABLE or a in (A_RAMP, A_KICKER, A_JUMP):
            errs.append(f"nav node {ar.node_names[i]} at rel ({x},{y}) on {ATTR_NAMES[a]}")
        if f & FLAG_BAY and a != A_BAY:
            errs.append(f"nav node {ar.node_names[i]} is a bay node off the bay")
    ring = np.ones((MAPN, MAPN), bool)
    ring[O:O + ARENA, O:O + ARENA] = False
    if np.isin(attr[ring], list(DRIVABLE)).any():
        errs.append("drivable floor outside the play area")
    w, nxt, dist = build_graph(ar, attr, errs)
    cells = build_cells(ar, attr, errs)
    speeds = check_jumps(ar, attr, tmap, errs)
    feat, travel = sweeper_record(ar)
    if travel + SWEEPER["warn"] >= SWEEPER["period"] // 2:
        errs.append(f"sweeper: crossing {travel} + warn must be under half the period")
    packed = bt.pack_map(tmap.tobytes())
    if bt.unpack_map(packed) != tmap.tobytes():
        errs.append("arena map does not round-trip")
    if len(packed) >= 8192:
        errs.append(f"arena map packed to {len(packed)} bytes, budget under 8192")
    blob = arena_blob(ar, nxt, cells)
    files = {out / f"{NAME}_map.bin": packed, out / f"{NAME}_center.bin": center_bytes(),
             out / f"{NAME}_feat.bin": feat, out / f"{NAME}_arena.bin": blob}
    for p, d in files.items():
        p.write_bytes(d)
    write_preview(ar, tmap, ts, w, cells, docs / f"{NAME}_preview.png", docs / "m6_sandbox.png")
    if not quiet:
        ground = sum(1 for e in w if ar.jumps.get(e[0]) != e[1])
        print(f"arena {NAME}: {ARENA * T} px square at tile {O}, {len(ar.nodes)} nav nodes, "
              f"{ground} ground edges, {len(ar.jumps)} jumps, {len(ar.spawns)} spawn pads, {len(ar.pads)} crate pads")
        print("  jump minimum speeds (px/tick): " + ", ".join(
            f"{ar.node_names[a]}>{ar.node_names[b]} {v}" for (a, b), v in sorted(speeds.items())))
        print(f"  sweeper crossing {travel} ticks of a {SWEEPER['period']}-tick period")
        print(f"  arena blob {len(blob)} bytes (nav {len(ar.nodes) * 6 + len(ar.nodes) ** 2 + GRID * GRID})")
    return {p: len(d) for p, d in files.items()}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=str(OUT))
    ap.add_argument("--docs", default=str(CART / "docs"))
    args = ap.parse_args()
    out, docs = Path(args.out), Path(args.docs)
    out.mkdir(parents=True, exist_ok=True)
    docs.mkdir(parents=True, exist_ok=True)
    errs = []
    sizes = build(out, docs, errs)
    for p, n in sizes.items():
        print(f"  {p.name}: {n} bytes")
    for e in errs:
        print("ERROR:", e, file=sys.stderr)
    sys.exit(1 if errs else 0)


if __name__ == "__main__":
    main()
