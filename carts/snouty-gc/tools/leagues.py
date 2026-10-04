# Forked from snouty-zero/tools/leagues.py at f8f6962.
"""Snouty GC league art: the shared tile vocabulary and one painter set per
league (palette, 128-tile set, background painter, horizon painter).

Used by tools/build_tracks.py. A league is one LEAGUES entry; the tile index
layout and attribute values below are shared by every league so the track
rasterizer never depends on the league. Pillow-free: numpy only.

Forked from Snouty Zero with its three leagues (Edge, Spine, Core) taken
out and the tileset cut from 256 to 128 tiles (SPEC 13.2). M0 has the
Dumps (e-waste landfill); the Runoff follows in M3.
"""
import math

import numpy as np

T, MAPN = 8, 128
NTILES = 128        # tiles per league (SPEC 13.2): 128 x 64 bytes = 8 KB

# Tile attributes (attr.bin values; cart/src/track.zig Attr).
# Zero's names in brackets: wall (rail), coolant (throttled), bay (cold
# aisle), vent (hot spot), ramp (hop). 3 (Zero's overclock pad) is reserved.
A_OFF, A_SURF, A_WALL, A_RESERVED, A_COOLANT, A_BAY, A_VENT, A_RAMP, A_START, A_SEC1, A_SEC2 = range(11)
ATTR_NAMES = ["off", "surface", "wall", "reserved", "coolant", "bay", "vent", "ramp", "start", "sector1", "sector2"]
DRIVABLE = {A_SURF, A_COOLANT, A_BAY, A_VENT, A_RAMP, A_START, A_SEC1, A_SEC2}
# Centerline flag bits, also the segment feature names (`wall` is implied:
# a segment without `open` has walls; the bit is set in the centerline).
FLAG_BITS = {"wall": 0, "open": 1, "coolant": 3, "bay": 4, "vent": 5, "ramp": 6, "hill": 7}

# Tile index layout shared by every league (painters fill in the looks).
# 1..15 belong to the league's background painter.
SURF, SURF_DOT, SURF_SEAM_V, SURF_SEAM_H, SURF_SEAM_X = 16, 17, 18, 19, 20
RUT = 21            # + axis (0 travel along x, 1 along y): cable ruts in the surface
EDGE_OPEN = 32      # + 4-neighbour mask: the lip of a pit (attr surface)
WALL = 48           # + 4-neighbour mask: wreckage wall
COOLANT = 68        # coolant puddle
BAY = 69            # + axis: service bay stripes (M2 wires the repair)
VENT = 71           # exhaust vent (the Runoff, M3)
RAMP = 72           # + direction (0 E, 1 S, 2 W, 3 N)
START = 76
SEC1 = 77           # + axis
SEC2 = 79           # + axis
WALL_DIAG = 96      # + corner where the surface is (0 NE, 1 SE, 2 SW, 3 NW)
EDGE_DIAG = 100     # + corner, pit-lip corner (attr surface)
GAP = 104           # + 4-neighbour mask of drivable tiles: the pit past a ramp (attr off)
N_, E_, S_, W_ = 1, 2, 4, 8


def rgb565(c):
    r, g, b = c
    return (r >> 3) << 11 | (g >> 2) << 5 | (b >> 3)


class Palette:
    """Named palette: index 0 is the fog colour, then entries in list order."""

    def __init__(self, entries):
        self.names = [n for n, _ in entries]
        self.rgb = [c for _, c in entries]
        self.ix = {n: i for i, n in enumerate(self.names)}
        assert len(self.rgb) <= 256 and len(set(self.names)) == len(self.names)

    def __getitem__(self, name):
        return self.ix[name]

    def table565(self, size=256):
        vals = [rgb565(c) for c in self.rgb] + [0] * (size - len(self.rgb))
        return np.array(vals, "<u2")

    def rgb_array(self, size=256):
        a = np.zeros((size, 3), np.uint8)
        a[: len(self.rgb)] = self.rgb
        return a


class Tileset:
    def __init__(self, pal):
        self.pal = pal
        self.tiles = np.zeros((NTILES, T, T), np.uint8)
        self.names = [None] * NTILES
        self.attr = np.zeros(NTILES, np.uint8)

    def put(self, i, name, attr, px):
        assert self.names[i] is None, i
        self.tiles[i], self.names[i], self.attr[i] = px, name, attr


def grid(fn):
    """8x8 tile from fn(x, y) -> palette index."""
    return np.array([[fn(x, y) for x in range(T)] for y in range(T)], np.uint8)


def side_dist(mask, x, y):
    """Pixel distance from the tile sides whose 4-neighbour is surface."""
    d = [y if mask & N_ else 99, 7 - x if mask & E_ else 99,
         7 - y if mask & S_ else 99, x if mask & W_ else 99]
    return min(d)


def diag_dist(corner, x, y):
    """Chebyshev distance from the corner where the diagonal surface tile is."""
    return [max(7 - x, y), max(7 - x, 7 - y), max(x, 7 - y), max(x, y)][corner]


def rot(base, k):
    """Rotate an east-pointing tile to direction k (0 E, 1 S, 2 W, 3 N)."""
    return np.rot90(base, [0, -1, 2, 1][k])


def bayer4(x, y):
    return [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]][y & 3][x & 3] / 16 + 1 / 32


def hash01(*v):
    """Deterministic 0..1 noise from integers (no rng state)."""
    h = 2166136261
    for k in v:
        h = ((h ^ (int(k) & 0xFFFFFFFF)) * 16777619) & 0xFFFFFFFF
    h ^= h >> 13
    h = (h * 0x5BD1E995) & 0xFFFFFFFF
    return (h ^ (h >> 15)) / 4294967296.0


def paint_track_pieces(ts, P):
    """Edges, walls, corner posts, feature tiles and pit tiles (21..119), the
    same shapes in every league; the palette names are the roles (wall_*,
    lip*, cool_*, bay_*, vent_*, ramp_*, chk_*, seam_*, void*). Fills the
    unused slots with tile 1."""
    fl = P["floor"]

    # Cable ruts: two dark worn grooves along the travel axis with a strand.
    def rut(x, y):
        if y in (1, 6):
            return P["rut"]
        if y in (2, 5) and (x * 5 + y) % 7 == 0:
            return P["rut_cable"]
        return fl
    r = grid(rut)
    ts.put(RUT, "cable ruts (travel x)", A_SURF, r)
    ts.put(RUT + 1, "cable ruts (travel y)", A_SURF, r.T.copy())

    # Edge pieces by 4-neighbour mask. Open: floor, a crumbling lip, then the pit.
    def open_px(d, x, y):
        if d <= 2:
            return fl
        if d == 3:
            return P["lip"] if (x + y) % 3 else P["lip_dk"]
        if d == 4:
            return P["lip_dk"]
        return P["void_mid"] if (x * 3 + y * 5) % 7 == 0 else P["void"]

    # Wreckage wall: hazard stripe facing the track, then crushed scrap.
    def wall_px(d, x, y):
        if d <= 1:
            return P["wall_a"] if ((x + y) >> 1) & 1 else P["wall_b"]
        h = hash01(x // 2, y // 2, 7)
        if d >= 6:
            return P["wall_base"]
        return P["scrap_hi"] if h < 0.25 else P["scrap"] if h < 0.6 else P["scrap_rust"] if h < 0.85 else P["scrap_dk"]

    for m in range(16):
        ts.put(EDGE_OPEN + m, f"pit lip mask {m:04b}", A_SURF,
               grid(lambda x, y: open_px(side_dist(m, x, y), x, y) if m else P["lip_dk"]))
        ts.put(WALL + m, f"wreckage wall mask {m:04b}", A_WALL,
               grid(lambda x, y: wall_px(side_dist(m, x, y), x, y) if m else P["wall_base"]))
    for c in range(4):
        ts.put(WALL_DIAG + c, f"wreckage corner {'NE SE SW NW'.split()[c]}", A_WALL,
               grid(lambda x, y: wall_px(diag_dist(c, x, y), x, y)))
        ts.put(EDGE_DIAG + c, f"pit lip corner {'NE SE SW NW'.split()[c]}", A_SURF,
               grid(lambda x, y: open_px(diag_dist(c, x, y), x, y)))

    def coolant(x, y):   # a teal puddle with a bright rim and highlights
        rr = math.hypot(x - 3.5, y - 3.5) + 0.6 * math.sin(x * 1.7 + y)
        if rr > 4.4:
            return fl
        if rr > 3.6:
            return P["cool_rim"]
        return P["cool_hi"] if (x, y) in ((2, 2), (3, 2), (5, 4)) else P["cool"]
    ts.put(COOLANT, "coolant puddle", A_COOLANT, grid(coolant))
    bay = grid(lambda x, y: P["bay_hi"] if y == 1 else (P["bay_stripe"] if y in (2, 5) else P["bay_floor"]))
    ts.put(BAY, "service bay stripes (travel x)", A_BAY, bay)
    ts.put(BAY + 1, "service bay stripes (travel y)", A_BAY, bay.T.copy())

    def vent(x, y):
        if x in (0, 7) or y in (0, 7):
            return P["vent_rim"]
        return P["vent_glow"] if y % 2 == 1 else P["vent_dk"]
    ts.put(VENT, "exhaust vent", A_VENT, grid(vent))

    def ramp(x, y):    # east-pointing ramp: scrap plate with a lit arrow
        if y in (0, 7):
            return P["wall_a"] if (x >> 1) & 1 else P["wall_b"]
        head = 3 <= x <= 6 and abs(y - 3.5) <= 6 - x
        shaft = 1 <= x <= 3 and 3 <= y <= 4
        return P["ramp_arrow"] if head or shaft else (P["ramp_hi"] if x % 3 == 0 else P["ramp"])
    for k in range(4):
        ts.put(RAMP + k, f"ramp {'ESWN'[k]}", A_RAMP, rot(grid(ramp), k))
    ts.put(START, "start line checker", A_START,
           grid(lambda x, y: P["chk_w"] if ((x >> 2) + (y >> 2)) & 1 else P["chk_k"]))
    s1 = grid(lambda x, y: P["seam_glow"] if x == 4 else (P["seam_lit"] if x == 3 else fl))
    s2 = grid(lambda x, y: P["seam_glow"] if x in (2, 5) else (P["seam_lit"] if x in (1, 6) else fl))
    ts.put(SEC1, "sector 1 seam (travel x)", A_SEC1, s1)
    ts.put(SEC1 + 1, "sector 1 seam (travel y)", A_SEC1, s1.T.copy())
    ts.put(SEC2, "sector 2 seam (travel x)", A_SEC2, s2)
    ts.put(SEC2 + 1, "sector 2 seam (travel y)", A_SEC2, s2.T.copy())

    # Pit past a ramp: void across the track with a lit lip on the sides
    # that touch drivable floor (4-neighbour mask).
    def gap_px(d, x, y):
        if d == 0:
            return P["lip"]
        if d == 1:
            return P["lip_dk"]
        return P["void_mid"] if (x * 3 + y * 5) % 7 == 0 else P["void"]
    for m in range(16):
        ts.put(GAP + m, f"pit mask {m:04b}", A_OFF, grid(lambda x, y: gap_px(side_dist(m, x, y), x, y)))
    # Unused slots get background tile 1 so no tile anywhere uses index 0.
    for i in range(NTILES):
        if ts.names[i] is None:
            ts.tiles[i] = ts.tiles[1]


# ---------------------------------------------------------------- The Dumps
# An e-waste landfill (SPEC 3.2): CRT-glass sand, monitor piles and scrap
# off the track; the track is a road of flattened circuit boards with
# cable ruts, walled with wreckage; open edges drop into landfill pits.
DUMPS_PAL = Palette([
    ("fog", (168, 140, 118)),
    # CRT-glass sand
    ("sand", (118, 104, 92)), ("sand_lt", (138, 122, 106)), ("sand_dk", (92, 80, 72)),
    ("glass", (150, 196, 186)), ("glass_hi", (220, 246, 236)), ("shard", (64, 92, 88)),
    # cables and keys
    ("cable_r", (196, 56, 44)), ("cable_b", (52, 84, 170)), ("cable_k", (34, 30, 34)),
    ("key", (200, 194, 180)), ("key_sh", (136, 130, 120)),
    # monitors: beige case, dark glass, a green glow
    ("case", (196, 186, 160)), ("case_sh", (140, 130, 110)), ("case_dk", (88, 80, 70)),
    ("screen", (28, 40, 38)), ("screen_glow", (90, 200, 120)), ("screen_hi", (170, 240, 190)),
    # board scrap
    ("board", (40, 110, 60)), ("board_trace", (196, 170, 70)),
    # track surface: flattened circuit boards
    ("floor", (36, 78, 54)), ("floor_seam", (54, 104, 70)), ("lane_dot", (214, 186, 84)),
    ("rut", (24, 50, 36)), ("rut_cable", (176, 60, 48)),
    # wreckage walls
    ("wall_a", (230, 180, 40)), ("wall_b", (30, 28, 30)), ("scrap", (120, 116, 112)),
    ("scrap_hi", (176, 172, 164)), ("scrap_rust", (150, 82, 44)), ("scrap_dk", (70, 64, 62)),
    ("wall_base", (44, 40, 40)),
    # pit lips
    ("lip", (196, 150, 96)), ("lip_dk", (110, 84, 60)),
    # features
    ("cool", (40, 168, 168)), ("cool_hi", (170, 250, 240)), ("cool_rim", (24, 96, 104)),
    ("bay_floor", (48, 56, 76)), ("bay_stripe", (240, 200, 60)), ("bay_hi", (250, 240, 200)),
    ("vent_rim", (90, 86, 80)), ("vent_dk", (30, 26, 24)), ("vent_glow", (230, 110, 40)),
    ("ramp", (120, 110, 96)), ("ramp_hi", (160, 150, 132)), ("ramp_arrow", (250, 232, 120)),
    ("chk_w", (236, 232, 220)), ("chk_k", (20, 20, 22)),
    ("seam_lit", (150, 130, 60)), ("seam_glow", (250, 220, 110)),
    ("void", (14, 10, 10)), ("void_mid", (34, 26, 22)),
])

# Dumps background tile meanings (indices 1..15 are per league).
DU_SAND, DU_SAND_LT, DU_GLINT, DU_SHARDS, DU_CABLE, DU_KEYS, DU_BOARD = 1, 2, 3, 4, 5, 6, 7
DU_MON = 8          # 8..11: 2x2 monitor seen from above-front, TL TR BL BR
DU_HEAP = 12        # 12..15: 2x2 scrap heap TL TR BL BR


def paint_dumps_tiles(P):
    ts = Tileset(P)

    def sand(x, y, salt):
        h = hash01(x, y, salt)
        return P["sand_dk"] if h < 0.18 else (P["sand_lt"] if h < 0.36 else P["sand"])
    ts.put(DU_SAND, "CRT-glass sand", A_OFF, grid(lambda x, y: sand(x, y, 1)))
    ts.put(DU_SAND_LT, "sand ripple", A_OFF, grid(
        lambda x, y: P["sand_lt"] if (x + 2 * y) % 8 in (0, 1) else sand(x, y, 2)))
    ts.put(DU_GLINT, "sand with glass glints", A_OFF, grid(
        lambda x, y: P["glass_hi"] if (x, y) in ((2, 1), (6, 5)) else (P["glass"] if (x, y) in ((1, 1), (5, 5), (3, 6)) else sand(x, y, 3))))
    ts.put(DU_SHARDS, "CRT shards", A_OFF, grid(
        lambda x, y: P["shard"] if abs((x - 2) - (y - 3)) < 1 and 1 <= x <= 5 else (
            P["glass"] if abs((x - 4) + (y - 5)) < 1 and 3 <= x <= 6 else sand(x, y, 4))))

    def cable(x, y):
        a = 3.5 + 2.4 * math.sin(x * 0.8)
        b = 4.0 + 2.0 * math.cos(x * 0.6 + 1)
        if abs(y - a) < 0.7:
            return P["cable_r"]
        if abs(y - b) < 0.7:
            return P["cable_b"]
        return sand(x, y, 5)
    ts.put(DU_CABLE, "tangled cables", A_OFF, grid(cable))
    ts.put(DU_KEYS, "keyboard keys", A_OFF, grid(
        lambda x, y: (P["key"] if (x % 3 < 2 and y % 3 < 1) else P["key_sh"]) if x % 3 < 2 and y % 3 < 2 else sand(x, y, 6)))
    ts.put(DU_BOARD, "circuit board scrap", A_OFF, grid(
        lambda x, y: P["board_trace"] if (y == 2 and x < 6) or (x == 5 and y >= 2) else P["board"] if 0 < x < 7 and 0 < y < 7 else sand(x, y, 7)))
    # 16x16 CRT monitor: beige case, glowing screen, a dark shadow.
    mon = np.zeros((16, 16), np.uint8)
    for y in range(16):
        for x in range(16):
            m = sand(x, y, 8)
            if 1 <= x <= 14 and 1 <= y <= 13:
                m = P["case"] if y < 12 else P["case_sh"]
                if x == 14 or y == 13:
                    m = P["case_dk"]
                if 3 <= x <= 12 and 3 <= y <= 10:
                    m = P["screen"]
                    if y in (5, 7) and 4 <= x <= 9:
                        m = P["screen_glow"]
                    if (x, y) == (4, 4):
                        m = P["screen_hi"]
            elif y == 14 and 2 <= x <= 15:
                m = P["sand_dk"]
            mon[y, x] = m
    for k, (oy, ox) in enumerate(((0, 0), (0, 8), (8, 0), (8, 8))):
        ts.put(DU_MON + k, f"monitor {'TL TR BL BR'.split()[k]}", A_OFF, mon[oy:oy + 8, ox:ox + 8])
    # 16x16 scrap heap: a mound of cases, boards and cable lit from the top-left.
    heap = np.zeros((16, 16), np.uint8)
    for y in range(16):
        for x in range(16):
            r = math.hypot(x - 7.5, (y - 8.5) * 1.2)
            if r > 7.5:
                heap[y, x] = sand(x, y, 9)
                continue
            h = hash01(x // 2, y // 2, 11)
            lit = (x - 7.5) + (y - 8.5) < -3
            base = P["case"] if h < 0.3 else P["scrap"] if h < 0.55 else P["board"] if h < 0.75 else P["scrap_rust"]
            heap[y, x] = P["scrap_hi"] if lit and h < 0.5 else (P["case_dk"] if r > 6.5 else base)
    for k, (oy, ox) in enumerate(((0, 0), (0, 8), (8, 0), (8, 8))):
        ts.put(DU_HEAP + k, f"scrap heap {'TL TR BL BR'.split()[k]}", A_OFF, heap[oy:oy + 8, ox:ox + 8])

    # Track surface: flattened circuit boards with a 16 px trace rhythm.
    fl, fs = P["floor"], P["floor_seam"]
    ts.put(SURF, "board road", A_SURF, grid(lambda x, y: fl))
    ts.put(SURF_DOT, "board road solder pad", A_SURF, grid(
        lambda x, y: P["lane_dot"] if 3 <= x <= 4 and 3 <= y <= 4 else fl))
    ts.put(SURF_SEAM_V, "board road trace left", A_SURF, grid(lambda x, y: fs if x == 0 else fl))
    ts.put(SURF_SEAM_H, "board road trace top", A_SURF, grid(lambda x, y: fs if y == 0 else fl))
    ts.put(SURF_SEAM_X, "board road trace corner", A_SURF, grid(lambda x, y: fs if x == 0 or y == 0 else fl))
    paint_track_pieces(ts, P)
    return ts


def paint_dumps_background(tmap, free, rng):
    """Fill free (off-track, not edge) tiles: sand with ripples and glints,
    scattered shards, keys, cables and board scrap, 2x2 monitors and heaps."""
    for ty in range(MAPN):
        for tx in range(MAPN):
            if free[ty, tx]:
                r = rng.random()
                tmap[ty, tx] = DU_SAND_LT if r < 0.12 else DU_GLINT if r < 0.20 else DU_SAND
    avail = free.copy()

    def fits(x, y, w, h):
        return 0 <= x and 0 <= y and x + w <= MAPN and y + h <= MAPN and avail[y:y + h, x:x + w].all()

    for _ in range(70):  # monitor piles: heaps with monitors on and around them
        for _try in range(200):
            x, y = rng.randrange(MAPN - 2), rng.randrange(MAPN - 2)
            if fits(x, y, 2, 2):
                tmap[y:y + 2, x:x + 2] = np.array([[DU_HEAP, DU_HEAP + 1], [DU_HEAP + 2, DU_HEAP + 3]])
                avail[y:y + 2, x:x + 2] = False
                for dx, dy in ((2, 0), (-2, 1), (1, 2), (0, -2)):
                    if rng.random() < 0.45 and fits(x + dx, y + dy, 2, 2):
                        xx, yy = x + dx, y + dy
                        tmap[yy:yy + 2, xx:xx + 2] = np.array([[DU_MON, DU_MON + 1], [DU_MON + 2, DU_MON + 3]])
                        avail[yy:yy + 2, xx:xx + 2] = False
                break
    for ty in range(MAPN):
        for tx in range(MAPN):
            if avail[ty, tx]:
                r = rng.random()
                if r < 0.03:
                    tmap[ty, tx] = DU_SHARDS
                elif r < 0.05:
                    tmap[ty, tx] = DU_CABLE
                elif r < 0.065:
                    tmap[ty, tx] = DU_KEYS
                elif r < 0.08:
                    tmap[ty, tx] = DU_BOARD


def paint_dumps_horizon(fog, rng):
    """Dumps horizon: front 512x32 (monitor mountains with flickering
    screens), back 256x32 (smog sky, a low sun, smoke columns)."""
    fpal = [fog, fog, (150, 124, 104), (118, 98, 84), (92, 78, 68), (70, 60, 54), (196, 186, 160),
            (150, 140, 118), (100, 92, 80), (40, 52, 48), (60, 74, 66), (130, 116, 100),
            (180, 160, 136), (34, 30, 30), (40, 90, 60), (110, 230, 140)]
    # 0 transparent, 1 fog, 2 haze, 3 far heap, 4 heap, 5 heap shade, 6..8 case lit/mid/shade,
    # 9/10 dark screens, 11/12 heap highlights, 13 dark detail, 14 screen off (blink), 15 screen on
    W, H = 512, 32
    f = np.zeros((H, W), np.uint8)
    ground = 29

    def mound(cx, h, w, c):
        for x in range(int(cx - w), int(cx + w) + 1):
            u = (x - cx) / w
            top = int(round(ground - h * (1 - u * u)))
            if top <= ground:
                col = f[:, x % W]
                for y in range(max(0, top), ground + 1):
                    if col[y] == 0 or c != 3:
                        col[y] = c
    x = 0
    while x < W:                      # far heaps
        w, h = rng.randint(24, 46), rng.randint(14, 24)
        mound(x, h, w, 3)
        x += w + rng.randint(0, 20)
    for k in range(16):               # near monitor mountains
        cx, h, w = k * 32 + rng.randint(0, 20), rng.randint(9, 19), rng.uniform(14, 24)
        mound(cx, h, w, 4)
        for x in range(int(cx), int(cx + w) + 1):
            for y in range(ground - h, ground + 1):
                if f[y, x % W] == 4 and (x - cx) / w > 0.35:
                    f[y, x % W] = 5
        for _ in range(int(w / 3)):   # monitors stuck in the heap, some lit
            mx = int(cx + rng.uniform(-w * 0.7, w * 0.7))
            u = (mx - cx) / w
            top = int(ground - h * (1 - u * u))
            my = rng.randint(top + 1, max(top + 2, ground - 2))
            for yy in range(my - 2, my + 2):
                for xx in range(mx - 2, mx + 3):
                    if 0 <= yy <= ground:
                        edge = yy == my - 2 or xx in (mx - 2, mx + 2) or yy == my + 1
                        f[yy, xx % W] = (6 if yy == my - 2 else 8 if yy == my + 1 else 7) if edge else (
                            15 if rng.random() < 0.25 else 9)
    for x in range(W):                # highlights on heap tops
        col = f[:, x]
        nz = np.nonzero(col)[0]
        if len(nz) and col[nz[0]] in (4, 3):
            col[nz[0]] = 12 if col[nz[0]] == 4 else 11
    f[f > 0] = np.where(np.arange(H)[:, None].repeat(W, 1)[f > 0] >= ground - 1, 2, f[f > 0])
    f[ground + 1:] = 1                # meets the fogged floor without a seam

    bpal = [(110, 84, 80), (126, 96, 86), (142, 108, 92), (156, 120, 98), (168, 132, 106),
            (176, 142, 114), (182, 150, 122), (196, 164, 128), (88, 78, 78), (110, 98, 96),
            (240, 200, 140), (255, 236, 180), (70, 62, 64), (130, 116, 112), fog, fog]
    # 0..6 smog gradient, 7 haze band, 8/9 smoke dark/light, 10/11 sun halo/core,
    # 12/13 far smoke, 14 fog, 15 spare (fog)
    BW = 256
    b = np.zeros((H, BW), np.uint8)
    for y in range(H):
        for x in range(BW):
            b[y, x] = min(6, int(y / 27 * 6 + bayer4(x, y)))
            if y in (19, 24) and bayer4(x + y, y) < 0.5:
                b[y, x] = 7
    sx, sy = 180, 17
    for y in range(H):
        for x in range(BW):
            d = math.hypot(x - sx, y - sy)
            if d <= 3.5:
                b[y, x] = 11
            elif d <= 7 and bayer4(x, y) < 1 - (d - 3.5) / 3.5 * 0.8:
                b[y, x] = 10
    for k in range(5):                # smoke columns leaning with the wind
        cx = k * 51 + rng.randint(0, 30)
        dark = k % 2 == 0
        for y in range(ground, -1, -1):
            t = (ground - y) / ground
            px = cx + t * t * 26
            r = (3.0 + t * 9.0) * (0.85 + 0.15 * math.sin(y * 0.9 + k))   # billows
            for x in range(int(px - r), int(px + r) + 1):
                d = abs(x - px) / r
                if d <= 1 and bayer4(x, y) < 1.25 - d * 0.7 - t * 0.3:
                    b[y, x % BW] = (8 if d < 0.5 else 9) if dark else (12 if d < 0.5 else 13)
    b[ground + 1:] = 14
    return f, b, fpal, bpal


def pack4(img):
    """Pack 4-bit pixels two per byte, low nibble = left pixel."""
    return (img[:, 0::2] | (img[:, 1::2] << 4)).astype(np.uint8).tobytes()


LEAGUES = {
    "dumps": dict(pal=DUMPS_PAL, tiles=paint_dumps_tiles, background=paint_dumps_background,
                  horizon=paint_dumps_horizon),
}
