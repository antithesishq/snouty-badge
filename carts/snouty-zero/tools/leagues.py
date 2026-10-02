"""Snouty Zero league art: the shared tile vocabulary and one painter set per
league (palette, 256-tile set, background painter, horizon painter).

Used by tools/build_tracks.py. A league is one LEAGUES entry; the tile index
layout and attribute values below are shared by every league so the track
rasterizer never depends on the league. Pillow-free: numpy only.
"""
import math

import numpy as np

T, MAPN = 8, 128

# Tile attributes (attr.bin values).
A_OFF, A_SURF, A_RAIL, A_PAD, A_THROT, A_COLD, A_HOT, A_HOP, A_START, A_SEC1, A_SEC2 = range(11)
ATTR_NAMES = ["off", "surface", "rail", "pad", "throttled", "cold", "hot", "hop", "start", "sector1", "sector2"]
DRIVABLE = {A_SURF, A_PAD, A_THROT, A_COLD, A_HOT, A_HOP, A_START, A_SEC1, A_SEC2}
# Centerline flag bits, also the segment feature names.
FLAG_BITS = {"rail": 0, "open": 1, "pad": 2, "throttled": 3, "cold": 4, "hot": 5, "hop": 6, "hill": 7}

# Tile index layout shared by every league (painters fill in the looks).
BG_PLAIN, BG_SEAM_V, BG_SEAM_H, BG_SEAM_X, BG_VENT, BG_LED = 1, 2, 3, 4, 5, 6
BG_FAN = 7          # 7..10: 2x2 fan grille TL, TR, BL, BR
BG_SOLAR = 11
BG_PLUME = 12       # 12..15: 2x2 plume TL, TR, BL, BR
SURF, SURF_DOT, SURF_SEAM_V, SURF_SEAM_H, SURF_SEAM_X = 16, 17, 18, 19, 20
EDGE_OPEN = 32      # + 4-neighbour mask
RAIL = 48           # + 4-neighbour mask
PAD = 64            # + direction (0 E, 1 S, 2 W, 3 N)
THROT = 68
COLD = 69           # + axis (0 travel along x, 1 along y)
HOT = 71
HOP = 72            # + direction
START = 76
SEC1 = 77           # + axis
SEC2 = 79           # + axis
RAIL_DIAG = 96      # + corner where the surface is (0 NE, 1 SE, 2 SW, 3 NW)
EDGE_DIAG = 100     # + corner, open-edge glow corner (attr 1)
GAP = 104           # + 4-neighbour mask of drivable tiles: the hop gap (attr 0)
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


# ---------------------------------------------------------------- Edge league
EDGE_PAL = Palette([
    ("fog", (196, 210, 222)),
    # rack-top background
    ("rack", (84, 89, 98)), ("rack_hi", (106, 112, 122)), ("rack_seam", (138, 145, 156)),
    ("rack_dark", (62, 66, 74)), ("vent", (40, 43, 50)),
    ("led_on", (70, 236, 100)), ("led_off", (26, 74, 40)),
    # fan grilles (cooling-tower tops)
    ("fan_rim", (160, 166, 176)), ("fan_blade", (112, 118, 128)), ("fan_dark", (30, 32, 38)),
    ("fan_hub", (206, 210, 216)),
    # solar fields
    ("solar", (34, 62, 138)), ("solar_deep", (22, 40, 98)), ("solar_seam", (222, 230, 242)),
    ("solar_hi", (70, 104, 182)),
    # plumes
    ("plume", (246, 248, 252)), ("plume_lt", (222, 228, 236)), ("plume_sh", (180, 188, 202)),
    # track surface
    ("floor", (38, 40, 52)), ("floor_seam", (47, 50, 64)), ("lane_dot", (150, 160, 180)),
    # rails
    ("cap_a", (214, 38, 38)), ("cap_b", (242, 242, 242)), ("metal_hi", (204, 210, 218)),
    ("metal", (146, 152, 164)), ("metal_dark", (88, 92, 104)), ("rail_base", (30, 31, 38)),
    # open edge glow
    ("glow", (136, 252, 255)), ("glow_mid", (40, 200, 232)), ("glow_dim", (24, 112, 142)),
    # features
    ("pad_bg", (72, 36, 120)), ("pad_chev", (255, 222, 60)), ("pad_chev_lo", (236, 140, 30)),
    ("thr_y", (214, 176, 40)), ("thr_k", (44, 40, 34)),
    ("cold_floor", (30, 54, 96)), ("cold_stripe", (84, 168, 240)), ("cold_hi", (176, 224, 255)),
    ("hot_core", (255, 242, 170)), ("hot_orange", (255, 140, 30)), ("hot_red", (196, 40, 20)),
    ("hot_dark", (84, 22, 12)),
    ("hop_bg", (20, 84, 74)), ("hop_arrow", (130, 255, 214)),
    ("chk_k", (18, 18, 22)),
    ("seam_lit", (70, 112, 140)), ("seam_glow", (130, 196, 230)),
    # hop gap (M3)
    ("void", (8, 9, 14)), ("void_mid", (20, 22, 30)),
])


class Tileset:
    def __init__(self, pal):
        self.pal = pal
        self.tiles = np.zeros((256, T, T), np.uint8)
        self.names = [None] * 256
        self.attr = np.zeros(256, np.uint8)

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


def paint_edge_tiles(P):
    ts = Tileset(P)
    rack = P["rack"]
    seam = lambda x, y, v, h: P["rack_seam"] if (v and x == 7) or (h and y == 7) else (
        P["rack_hi"] if (v and x == 6) or (h and y == 6) else rack)
    ts.put(BG_PLAIN, "rack panel", A_OFF, grid(lambda x, y: rack))
    ts.put(BG_SEAM_V, "rack seam vertical", A_OFF, grid(lambda x, y: seam(x, y, 1, 0)))
    ts.put(BG_SEAM_H, "rack seam horizontal", A_OFF, grid(lambda x, y: seam(x, y, 0, 1)))
    ts.put(BG_SEAM_X, "rack seam cross", A_OFF, grid(lambda x, y: seam(x, y, 1, 1)))
    ts.put(BG_VENT, "rack vent slots", A_OFF, grid(
        lambda x, y: P["vent"] if y in (2, 4) and 1 <= x <= 6 else (P["rack_dark"] if y in (3, 5) and 1 <= x <= 6 else rack)))
    ts.put(BG_LED, "rack status LEDs", A_OFF, grid(
        lambda x, y: (P["led_on"] if x in (2, 5) else P["vent"]) if y == 4 and 1 <= x <= 6 else
        (P["rack_dark"] if y == 5 and 1 <= x <= 6 else rack)))
    # 16x16 fan grille: rim, four swept blades, hub.
    fan = np.full((16, 16), rack, np.uint8)
    for y in range(16):
        for x in range(16):
            dx, dy = x - 7.5, y - 7.5
            r = math.hypot(dx, dy)
            if r > 7.6:
                continue
            if r > 6.4:
                fan[y, x] = P["fan_rim"]
            elif r < 1.8:
                fan[y, x] = P["fan_hub"]
            else:
                a = (math.atan2(dy, dx) / (2 * math.pi) * 4 + r * 0.09) % 1
                fan[y, x] = P["fan_blade"] if a < 0.45 else P["fan_dark"]
    for k, (oy, ox) in enumerate(((0, 0), (0, 8), (8, 0), (8, 8))):
        ts.put(BG_FAN + k, f"fan grille {'TL TR BL BR'.split()[k]}", A_OFF, fan[oy:oy + 8, ox:ox + 8])
    ts.put(BG_SOLAR, "solar panel", A_OFF, grid(
        lambda x, y: P["solar_seam"] if x == 7 or y == 7 else (
            P["solar_deep"] if x == 3 or y == 3 else (P["solar_hi"] if x + y == 1 else P["solar"]))))
    # 16x16 plume: three overlapping puffs lit from the top-left.
    plume = np.full((16, 16), rack, np.uint8)
    puffs = ((6.0, 6.5, 5.2), (10.5, 9.0, 4.6), (5.5, 11.0, 3.6))
    for y in range(16):
        for x in range(16):
            best = None
            for cx, cy, r in puffs:
                d = math.hypot(x + .5 - cx, y + .5 - cy)
                if d <= r:
                    shade = ((x + .5 - cx) + (y + .5 - cy)) / r
                    best = shade if best is None else min(best, shade)
            if best is not None:
                plume[y, x] = P["plume"] if best < 0.1 else (P["plume_lt"] if best < 0.75 else P["plume_sh"])
    for k, (oy, ox) in enumerate(((0, 0), (0, 8), (8, 0), (8, 8))):
        ts.put(BG_PLUME + k, f"plume {'TL TR BL BR'.split()[k]}", A_OFF, plume[oy:oy + 8, ox:ox + 8])

    # Track surface: dark aisle floor with a faint 16 px seam grid.
    fl, fs = P["floor"], P["floor_seam"]
    ts.put(SURF, "floor", A_SURF, grid(lambda x, y: fl))
    ts.put(SURF_DOT, "floor lane dot", A_SURF, grid(lambda x, y: P["lane_dot"] if 3 <= x <= 4 and 3 <= y <= 4 else fl))
    ts.put(SURF_SEAM_V, "floor seam left", A_SURF, grid(lambda x, y: fs if x == 0 else fl))
    ts.put(SURF_SEAM_H, "floor seam top", A_SURF, grid(lambda x, y: fs if y == 0 else fl))
    ts.put(SURF_SEAM_X, "floor seam corner", A_SURF, grid(lambda x, y: fs if x == 0 or y == 0 else fl))
    paint_track_pieces(ts, P)
    return ts


def paint_track_pieces(ts, P):
    """Edges, rails, corner posts, feature tiles and hop-gap tiles (32..119),
    the same shapes in every league; the palette names are the roles (cap_a /
    cap_b rail caps, glow*, pad_*, thr_*, cold_*, hot_*, hop_*, chk_k,
    seam_*, void*). Fills the unused slots with tile 1."""
    fl = P["floor"]

    # Edge pieces by 4-neighbour mask. Open: floor, then the glow strip.
    def open_px(d):
        return [fl, fl, fl, fl, P["glow_mid"], P["glow"], P["glow"], P["glow_dim"]][min(d, 7)]

    def rail_px(d, x, y):
        if d <= 1:   # hazard chevrons facing the track, period 4 diagonal
            return P["cap_a"] if ((x + y) >> 1) & 1 else P["cap_b"]
        return [0, 0, P["metal_hi"], P["metal"], P["metal"], P["metal_dark"], P["rail_base"], P["rail_base"]][min(d, 7)]

    for m in range(16):
        ts.put(EDGE_OPEN + m, f"open edge mask {m:04b}", A_SURF,
               grid(lambda x, y: open_px(side_dist(m, x, y)) if m else P["glow_dim"]))
        ts.put(RAIL + m, f"rail mask {m:04b}", A_RAIL,
               grid(lambda x, y: rail_px(side_dist(m, x, y), x, y) if m else P["rail_base"]))
    for c in range(4):
        ts.put(RAIL_DIAG + c, f"rail corner post {'NE SE SW NW'.split()[c]}", A_RAIL,
               grid(lambda x, y: rail_px(diag_dist(c, x, y), x, y)))
        ts.put(EDGE_DIAG + c, f"open edge corner {'NE SE SW NW'.split()[c]}", A_SURF,
               grid(lambda x, y: open_px(diag_dist(c, x, y))))

    # Feature tiles.
    def chev(x, y):   # east-pointing chevrons, repeating every 8 px
        c = (x + int(abs(y - 3.5))) % 8
        return P["pad_chev"] if c in (2, 3) else (P["pad_chev_lo"] if c == 4 else P["pad_bg"])
    for k in range(4):
        ts.put(PAD + k, f"overclock pad {'ESWN'[k]}", A_PAD, rot(grid(chev), k))
    ts.put(THROT, "throttled hatch", A_THROT, grid(lambda x, y: P["thr_y"] if ((x - y) >> 1) & 1 else P["thr_k"]))
    cold = grid(lambda x, y: P["cold_hi"] if y == 1 else (P["cold_stripe"] if y in (2, 5) else P["cold_floor"]))
    ts.put(COLD, "cold aisle stripes (travel x)", A_COLD, cold)
    ts.put(COLD + 1, "cold aisle stripes (travel y)", A_COLD, cold.T.copy())

    def hot(x, y):
        r = math.hypot(x - 3.5, y - 3.5)
        if r < 1.6:
            return P["hot_core"]
        if r < 2.6:
            return P["hot_orange"] if (x + y) % 2 else P["hot_red"]
        if r < 3.6:
            return P["hot_red"] if x not in (3, 4) and y not in (3, 4) else P["hot_dark"]
        return P["hot_dark"] if r < 4.3 else fl
    ts.put(HOT, "hot spot", A_HOT, grid(hot))

    def hop(x, y):    # east-pointing arrow on a framed plate
        if x in (0, 7) or y in (0, 7):
            return P["hop_arrow"] if (x + y) % 2 else P["hop_bg"]
        head = 3 <= x <= 6 and abs(y - 3.5) <= 6 - x
        shaft = 1 <= x <= 3 and 3 <= y <= 4
        return P["hop_arrow"] if head or shaft else P["hop_bg"]
    for k in range(4):
        ts.put(HOP + k, f"hop plate {'ESWN'[k]}", A_HOP, rot(grid(hop), k))
    ts.put(START, "start line checker", A_START, grid(lambda x, y: P["cap_b"] if ((x >> 2) + (y >> 2)) & 1 else P["chk_k"]))
    s1 = grid(lambda x, y: P["seam_glow"] if x == 4 else (P["seam_lit"] if x == 3 else fl))
    s2 = grid(lambda x, y: P["seam_glow"] if x in (2, 5) else (P["seam_lit"] if x in (1, 6) else fl))
    ts.put(SEC1, "sector 1 seam (travel x)", A_SEC1, s1)
    ts.put(SEC1 + 1, "sector 1 seam (travel y)", A_SEC1, s1.T.copy())
    ts.put(SEC2, "sector 2 seam (travel x)", A_SEC2, s2)
    ts.put(SEC2 + 1, "sector 2 seam (travel y)", A_SEC2, s2.T.copy())

    # Hop gap: a void across the track just past a hop plate, with glowing
    # lips on the sides that touch drivable floor (4-neighbour mask).
    def gap_px(d, x, y):
        if d == 0:
            return P["glow"]
        if d == 1:
            return P["glow_dim"]
        return P["void_mid"] if (x * 3 + y * 5) % 7 == 0 else P["void"]
    for m in range(16):
        ts.put(GAP + m, f"hop gap mask {m:04b}", A_OFF, grid(lambda x, y: gap_px(side_dist(m, x, y), x, y)))
    # Unused slots get background tile 1 so no tile anywhere uses index 0.
    for i in range(256):
        if ts.names[i] is None:
            ts.tiles[i] = ts.tiles[BG_PLAIN]


def paint_edge_background(tmap, free, rng):
    """Fill free (off-track, not edge) tiles: rack grid on an 8-tile rhythm,
    solar fields, 2x2 fan grilles, plumes, scattered vents and LEDs."""
    for ty in range(MAPN):
        for tx in range(MAPN):
            if free[ty, tx]:
                v, h = tx % 8 == 7, ty % 8 == 7
                tmap[ty, tx] = BG_SEAM_X if v and h else BG_SEAM_V if v else BG_SEAM_H if h else BG_PLAIN
    avail = free.copy()

    def fits(x, y, w, h):
        return 0 <= x and 0 <= y and x + w <= MAPN and y + h <= MAPN and avail[y:y + h, x:x + w].all()

    for _ in range(9):   # solar fields: whole rectangles in free space
        for _try in range(200):
            w, h = rng.randint(5, 13), rng.randint(3, 8)
            x, y = rng.randrange(MAPN - w), rng.randrange(MAPN - h)
            if fits(x - 1, y - 1, w + 2, h + 2):
                tmap[y:y + h, x:x + w] = BG_SOLAR
                avail[y - 1:y + h + 1, x - 1:x + w + 1] = False
                break
    fans = []
    for _ in range(40):  # fan grilles inside a rack panel (not on its seams)
        for _try in range(200):
            x, y = rng.randrange(MAPN - 2), rng.randrange(MAPN - 2)
            if x % 8 < 6 and y % 8 < 6 and fits(x, y, 2, 2):
                tmap[y:y + 2, x:x + 2] = np.array([[BG_FAN, BG_FAN + 1], [BG_FAN + 2, BG_FAN + 3]])
                avail[max(0, y - 1):y + 3, max(0, x - 1):x + 3] = False
                fans.append((x, y))
                break
    for fx, fy in fans[:14]:  # plumes drift downwind (east) of some fans
        for dx, dy in ((2, -1), (3, 0), (2, 1), (-2, -1)):
            x, y = fx + dx, fy + dy
            if fits(x, y, 2, 2):
                tmap[y:y + 2, x:x + 2] = np.array([[BG_PLUME, BG_PLUME + 1], [BG_PLUME + 2, BG_PLUME + 3]])
                avail[y:y + 2, x:x + 2] = False
                break
    for ty in range(MAPN):
        for tx in range(MAPN):
            if avail[ty, tx] and tmap[ty, tx] == BG_PLAIN:
                r = rng.random()
                if r < 0.06:
                    tmap[ty, tx] = BG_VENT
                elif r < 0.085:
                    tmap[ty, tx] = BG_LED


def bayer4(x, y):
    return [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]][y & 3][x & 3] / 16 + 1 / 32


def paint_edge_horizon(fog, rng):
    """Edge horizon: front 512x32 (towers, rack skyline, LEDs), back 256x32
    (sky gradient, haze bands, distant mega skyline, two suns)."""
    fpal = [fog, fog, (178, 192, 206), (128, 140, 158), (96, 104, 120), (70, 76, 90), (150, 160, 176),
            (214, 220, 228), (176, 184, 196), (132, 140, 154), (250, 251, 253), (226, 231, 238),
            (196, 204, 216), (52, 56, 68), (26, 74, 40), (70, 236, 100)]
    # 0 transparent, 1 fog, 2 haze, 3 far block, 4 block, 5 block shade, 6 block top,
    # 7..9 tower lit/mid/shade, 10..12 plume, 13 dark detail, 14 led_off (unused, blink), 15 led_on
    W, H = 512, 32
    f = np.zeros((H, W), np.uint8)
    ground = 29                       # last skyline row; rows 30-31 are fog

    def rect(x0, w, top, c):
        for x in range(x0, x0 + w):
            f[top:ground + 1, x % W] = c

    x = 0
    while x < W:                      # far substation blocks
        w, h = rng.randint(14, 30), rng.randint(8, 13)
        rect(x, w, ground - h, 3)
        x += w + rng.randint(10, 40)
    x = 0
    while x < W:                      # near rack rows with LEDs
        w, h = rng.randint(10, 36), rng.randint(3, 8)
        top = ground - h
        rect(x, w, top, 4)
        for xx in range(x, x + w):
            f[top, xx % W] = 6
            f[top + 1:ground + 1, (x + w - 1) % W] = 5
            if (xx - x) % 5 == 2 and h >= 4 and rng.random() < 0.7:
                f[top + 2, xx % W] = 15 if rng.random() < 0.6 else 13
        x += w + rng.randint(0, 6)
    for k in range(7):                # cooling towers with plumes
        cx = k * 73 + rng.randint(0, 40)
        h, base, waist = rng.randint(14, 20), rng.uniform(6.5, 8.5), rng.uniform(4.0, 5.0)
        top = ground - h
        for y in range(top, ground + 1):
            t = (y - top) / h
            hw = waist + (base - waist) * ((t - 0.35) / 0.65) ** 2 if t > 0.35 else waist + (5.6 - waist) * ((0.35 - t) / 0.35) ** 2
            for xx in range(int(cx - hw), int(cx + hw) + 1):
                u = (xx - cx) / hw
                f[y, xx % W] = 6 if y == top else (7 if u < -0.3 else 8 if u < 0.35 else 9)
        if k % 2 == 0 or rng.random() < 0.5:   # plume puffs drifting right
            for j in range(4):
                px, py, r = cx + 2 + j * 4.5, top - 3 - j * 2.2, 3.2 + j * 0.9
                for y in range(max(0, int(py - r)), min(ground, int(py + r) + 1)):
                    for xx in range(int(px - r), int(px + r) + 1):
                        d = math.hypot(xx - px, y - py)
                        if d <= r:
                            s = ((xx - px) + (y - py)) / r
                            f[y, xx % W] = 10 if s < -0.2 else (11 if s < 0.6 else 12)
    f[f > 0] = np.where(np.arange(H)[:, None].repeat(W, 1)[f > 0] >= ground - 1, 2, f[f > 0])
    f[ground + 1:] = 1                # meets the fogged floor without a seam

    bpal = [(140, 172, 212), (150, 180, 216), (160, 188, 219), (170, 195, 221), (180, 201, 222),
            (188, 206, 223), (194, 209, 223), (208, 220, 230), (172, 188, 208), (156, 172, 194),
            (232, 236, 228), (255, 252, 236), (238, 214, 190), (255, 238, 214), fog, fog]
    # 0..6 sky gradient, 7 haze band, 8/9 distant skyline, 10/11 sun halo/core,
    # 12/13 second sun halo/core, 14 fog, 15 spare (fog)
    BW = 256
    b = np.zeros((H, BW), np.uint8)
    for y in range(H):
        for x in range(BW):
            g = y / 27 * 6
            b[y, x] = min(6, int(g + bayer4(x, y)))
            if y in (17, 22, 25) and bayer4(x + y, y) < 0.5:
                b[y, x] = 7
    x = 0
    while x < BW:                     # very distant, larger skyline silhouette
        w, h = rng.randint(6, 20), rng.randint(6, 18)
        for xx in range(x, x + w):
            b[ground + 1 - h:, xx % BW] = 9 if xx == x + w - 1 else 8
        x += w + rng.randint(0, 14)
    for (sx, sy, r_core, r_halo, ch, cc) in ((68, 9, 4.5, 8.0, 10, 11), (176, 5, 1.8, 3.6, 12, 13)):
        for y in range(H):
            for xx in range(BW):
                d = math.hypot(xx - sx, y - sy)
                if d <= r_core:
                    b[y, xx] = cc
                elif d <= r_halo and bayer4(xx, y) < 1 - (d - r_core) / (r_halo - r_core) * 0.8:
                    if b[y, xx] <= 7:
                        b[y, xx] = ch
    b[ground + 1:] = 14
    return f, b, fpal, bpal


# ---------------------------------------------------------------- Spine league
# Inside the city: switch cabinets with LED rows, patch panels, fiber bundles
# in cable trays, aisle grating with light shafts from far above; the track is
# a dark floor with lit seams. No sky: palette 0 is the blue-grey haze.
SPINE_PAL = Palette([
    ("fog", (38, 46, 62)),
    # switch cabinets
    ("cab", (36, 40, 54)), ("cab_hi", (54, 60, 78)), ("cab_seam", (78, 86, 108)),
    ("cab_dark", (24, 27, 37)), ("vent", (12, 14, 20)),
    ("led_on", (70, 236, 100)), ("led_off", (26, 74, 40)), ("led_amber", (246, 176, 46)),
    ("led_blue", (84, 168, 255)),
    # patch panels and fiber (jacket colours: yellow single-mode, aqua OM3, magenta OM4, orange OM1)
    ("port", (8, 9, 13)), ("port_rim", (112, 120, 134)),
    ("fib_y", (236, 206, 58)), ("fib_a", (52, 214, 214)), ("fib_m", (216, 70, 196)), ("fib_o", (248, 128, 40)),
    # cable trays
    ("tray", (104, 112, 130)), ("tray_dark", (60, 66, 82)),
    # aisle grating and light shafts
    ("grate", (22, 26, 35)), ("grate_hi", (34, 39, 52)),
    ("shaft", (64, 82, 112)), ("shaft_hi", (98, 124, 162)), ("shaft_core", (150, 176, 210)),
    # track surface: near-black floor, lit seams
    ("floor", (16, 18, 28)), ("floor_seam", (28, 68, 100)), ("seam_node", (96, 206, 246)),
    ("lane_dot", (120, 196, 255)),
    # rails: steel with blue-white caps
    ("cap_a", (60, 124, 255)), ("cap_b", (226, 238, 255)), ("metal_hi", (196, 206, 222)),
    ("metal", (134, 144, 162)), ("metal_dark", (76, 82, 98)), ("rail_base", (14, 16, 24)),
    # open edge glow (electric blue)
    ("glow", (176, 226, 255)), ("glow_mid", (64, 150, 255)), ("glow_dim", (30, 66, 150)),
    # features
    ("pad_bg", (34, 26, 104)), ("pad_chev", (130, 250, 255)), ("pad_chev_lo", (56, 150, 255)),
    ("thr_y", (238, 128, 40)), ("thr_k", (36, 26, 28)),
    ("cold_floor", (14, 44, 70)), ("cold_stripe", (56, 198, 222)), ("cold_hi", (180, 250, 255)),
    ("hot_core", (255, 238, 204)), ("hot_orange", (255, 118, 64)), ("hot_red", (212, 30, 92)),
    ("hot_dark", (70, 14, 42)),
    ("hop_bg", (52, 18, 78)), ("hop_arrow", (240, 124, 255)),
    ("chk_k", (10, 10, 14)),
    ("seam_lit", (36, 128, 66)), ("seam_glow", (110, 250, 150)),
    ("void", (5, 6, 9)), ("void_mid", (16, 18, 28)),
])

# Spine background tile meanings (indices 1..15 are per league).
SP_CAB, SP_CAB_LED, SP_CAB_LED2, SP_CAB_DOOR, SP_CAB_VENT, SP_PATCH = 1, 2, 3, 4, 5, 6
SP_GRATE, SP_SHAFT, SP_SHAFT_CORE = 7, 8, 9
SP_TRAY_H, SP_TRAY_V, SP_TRAY_X = 10, 11, 12
SP_BLANK, SP_FIBER_H, SP_FIBER_V = 13, 14, 15


def paint_spine_tiles(P):
    ts = Tileset(P)
    cab = P["cab"]

    def cab_px(x, y):   # cabinet face: lit top lip, dark bottom shadow
        return P["cab_hi"] if y == 0 else (P["cab_dark"] if y == 7 else cab)
    ts.put(SP_CAB, "cabinet face", A_OFF, grid(cab_px))

    def leds(colors):
        def f(x, y):
            if y in (3, 4) and 1 <= x <= 6:
                if y == 3 and x % 2 == 1:
                    return P[colors[(x // 2) % len(colors)]]
                return P["vent"]
            return cab_px(x, y)
        return f
    ts.put(SP_CAB_LED, "cabinet LED row (green)", A_OFF, grid(leds(["led_on", "led_on", "led_off"])))
    ts.put(SP_CAB_LED2, "cabinet LED row (mixed)", A_OFF, grid(leds(["led_on", "led_amber", "led_blue"])))
    ts.put(SP_CAB_DOOR, "cabinet door seam + handle", A_OFF, grid(
        lambda x, y: P["cab_seam"] if x == 7 else (P["port_rim"] if x == 5 and 2 <= y <= 5 else cab_px(x, y))))
    ts.put(SP_CAB_VENT, "cabinet vent perforation", A_OFF, grid(
        lambda x, y: P["vent"] if 1 <= y <= 6 and (x + y) % 2 == 0 and 1 <= x <= 6 else cab_px(x, y)))
    fib = ["fib_y", "fib_a", "fib_m", "fib_o"]

    def patch(x, y):   # two rows of ports with fiber stubs dropping out
        if y in (1, 4) and 1 <= x <= 6:
            return P["port"] if x % 2 else P["port_rim"]
        if y in (2, 5) and x % 2 == 1:
            return P[fib[(x // 2 + y) % 4]]
        return cab_px(x, y)
    ts.put(SP_PATCH, "patch panel with fiber stubs", A_OFF, grid(patch))
    ts.put(SP_GRATE, "aisle grating", A_OFF, grid(
        lambda x, y: P["grate_hi"] if x % 4 == 0 or y % 4 == 0 else P["grate"]))

    def shaft(lvl):     # light falling on the grating, ordered dither
        def f(x, y):
            g = x % 4 == 0 or y % 4 == 0
            t = bayer4(x, y)
            if lvl == 0:
                return (P["shaft_hi"] if g else P["shaft"]) if t < 0.5 else (P["grate_hi"] if g else P["grate"])
            return P["shaft_core"] if g else (P["shaft_hi"] if t < 0.75 else P["shaft"])
        return f
    ts.put(SP_SHAFT, "light shaft rim", A_OFF, grid(shaft(0)))
    ts.put(SP_SHAFT_CORE, "light shaft core", A_OFF, grid(shaft(1)))

    def tray(x, y):     # horizontal cable tray: side rails, rungs, two fiber runs
        if y in (0, 7):
            return P["tray"]
        if y == 3:
            return P["fib_y"]
        if y == 4:
            return P["fib_a"]
        return P["tray"] if x % 4 == 3 else P["tray_dark"]
    th = grid(tray)
    ts.put(SP_TRAY_H, "cable tray horizontal", A_OFF, th)
    ts.put(SP_TRAY_V, "cable tray vertical", A_OFF, th.T.copy())

    def cross(x, y):
        if y == 3 or x == 3:
            return P["fib_y"]
        if y == 4 or x == 4:
            return P["fib_a"]
        return P["tray"] if (x in (0, 7)) != (y in (0, 7)) else P["tray_dark"]
    ts.put(SP_TRAY_X, "cable tray crossing", A_OFF, grid(cross))
    ts.put(SP_BLANK, "cabinet blanking plate", A_OFF, grid(
        lambda x, y: P["cab_seam"] if (x, y) in ((1, 1), (6, 1), (1, 6), (6, 6)) else P["cab_dark"]))

    def loose(x, y):    # a loose fiber bundle across the grating
        if 2 <= y <= 5:
            return P[fib[(y - 2 + (x // 3)) % 4]] if (x + y) % 3 else P["tray_dark"]
        return P["grate_hi"] if x % 4 == 0 or y % 4 == 0 else P["grate"]
    lb = grid(loose)
    ts.put(SP_FIBER_H, "fiber bundle on grating (x)", A_OFF, lb)
    ts.put(SP_FIBER_V, "fiber bundle on grating (y)", A_OFF, lb.T.copy())

    # Track surface: near-black floor, lit seams every 16 px, a node light
    # where seams cross.
    fl, fs = P["floor"], P["floor_seam"]
    ts.put(SURF, "floor", A_SURF, grid(lambda x, y: fl))
    ts.put(SURF_DOT, "floor lane dot", A_SURF, grid(lambda x, y: P["lane_dot"] if 3 <= x <= 4 and 3 <= y <= 4 else fl))
    ts.put(SURF_SEAM_V, "floor lit seam left", A_SURF, grid(lambda x, y: fs if x == 0 else fl))
    ts.put(SURF_SEAM_H, "floor lit seam top", A_SURF, grid(lambda x, y: fs if y == 0 else fl))
    ts.put(SURF_SEAM_X, "floor lit seam node", A_SURF, grid(
        lambda x, y: P["seam_node"] if x == 0 and y == 0 else (fs if x == 0 or y == 0 else fl)))
    paint_track_pieces(ts, P)
    return ts


def paint_spine_background(tmap, free, rng):
    """Fill free tiles with the city floor: cabinet rows three tiles deep
    on a six-tile rhythm (LED row on top, patch panels and vents, door seams
    every four tiles), aisle grating between, cross aisles every ~24 tiles,
    cable trays with fiber along aisles, loose bundles, light shafts."""
    period, ox = 6, rng.randrange(6)
    cross_x = set()
    x = rng.randrange(8, 20)
    while x < MAPN:
        cross_x.update((x, x + 1))
        x += rng.randrange(18, 30)
    for ty in range(MAPN):
        k = (ty - ox) % period
        for tx in range(MAPN):
            if not free[ty, tx]:
                continue
            if tx in cross_x:
                tmap[ty, tx] = SP_GRATE
            elif k < 3:
                if k == 0:
                    tmap[ty, tx] = SP_CAB_LED if rng.random() < 0.75 else SP_CAB_LED2
                elif (tx + 1) % 4 == 0:
                    tmap[ty, tx] = SP_CAB_DOOR
                else:
                    r = rng.random()
                    tmap[ty, tx] = SP_PATCH if r < 0.22 else SP_CAB_VENT if r < 0.42 else SP_BLANK if r < 0.5 else SP_CAB
            else:
                tmap[ty, tx] = SP_GRATE
    # Cable trays: spans down cross aisles and along aisles (a crossing tile
    # where they meet).
    cols = sorted(c for c in cross_x if c - 1 not in cross_x)
    for c in cols:
        if rng.random() < 0.6:
            y0 = rng.randrange(MAPN)
            for ty in range(y0, min(MAPN, y0 + rng.randint(16, 48))):
                if free[ty, c]:
                    tmap[ty, c] = SP_TRAY_V
    for r0 in range(0, MAPN, period):
        ty = r0 + ox + 4
        if ty < MAPN and rng.random() < 0.45:
            x0 = rng.randrange(MAPN)
            for tx in range(x0, min(MAPN, x0 + rng.randint(12, 40))):
                if free[ty, tx]:
                    tmap[ty, tx] = SP_TRAY_X if tmap[ty, tx] == SP_TRAY_V else SP_TRAY_H
    # Loose fiber bundles strung along the aisles, short runs.
    for _ in range(60):
        ty, tx = rng.randrange(MAPN), rng.randrange(MAPN - 6)
        if (ty - ox) % period == 3 and all(free[ty, tx + i] and tmap[ty, tx + i] == SP_GRATE for i in range(6)):
            tmap[ty, tx:tx + rng.randint(3, 6)] = SP_FIBER_H
    # Light shafts: round pools on everything (they light cabinets too).
    for _ in range(26):
        cy, cx, r = rng.uniform(0, MAPN), rng.uniform(0, MAPN), rng.uniform(1.6, 3.4)
        for ty in range(int(cy - r) - 1, int(cy + r) + 2):
            for tx in range(int(cx - r) - 1, int(cx + r) + 2):
                if 0 <= ty < MAPN and 0 <= tx < MAPN and free[ty, tx]:
                    d = math.hypot(tx + .5 - cx, ty + .5 - cy)
                    if d < r * 0.55:
                        tmap[ty, tx] = SP_SHAFT_CORE
                    elif d < r:
                        tmap[ty, tx] = SP_SHAFT


def paint_spine_horizon(fog, rng):
    """Spine horizon: front 512x32 (near cabinet silhouettes with green LED
    dots), back 256x32 (city walls rising into darkness, light shafts)."""
    fpal = [fog, fog, (46, 56, 76), (30, 34, 46), (22, 25, 34), (14, 16, 22), (62, 72, 94),
            (90, 150, 230), (52, 214, 214), (246, 176, 46), (84, 92, 110), (52, 58, 72),
            (120, 130, 150), (10, 11, 15), (26, 74, 40), (70, 236, 100)]
    # 0 transparent, 1 fog, 2 haze, 3 far cabinet, 4 cabinet, 5 cabinet shade, 6 cabinet top lip,
    # 7 blue rim light, 8 aqua fiber, 9 amber LED, 10..12 cable tray / pipe, 13 dark detail,
    # 14 led_off (unused, blink), 15 led_on
    W, H = 512, 32
    f = np.zeros((H, W), np.uint8)
    ground = 29

    def col(x, top, c):
        f[top:ground + 1, x % W] = c

    x = 0
    while x < W:                      # far cabinet rows, tall and flat
        w, h = rng.randint(20, 48), rng.randint(9, 15)
        for xx in range(x, x + w):
            col(xx, ground - h, 3)
        x += w + rng.randint(2, 12)
    for k in range(9):                # structural pillars of the city, into the dark
        cx, w = k * 57 + rng.randint(0, 30), rng.randint(5, 9)
        for xx in range(cx, cx + w):
            col(xx, 0, 5 if xx > cx else 6)
        for yy in range(rng.randint(2, 6), ground - 6, rng.randint(5, 8)):   # catwalk brackets
            for xx in range(cx - 2, cx + w + 2):
                f[yy, xx % W] = 10
    x = 0
    while x < W:                      # near cabinets with LED columns and rim light
        w, h = rng.randint(8, 22), rng.randint(7, 17)
        top = ground - h
        for xx in range(x, x + w):
            col(xx, top, 4)
            f[top, xx % W] = 6
        f[top:ground + 1, x % W] = 7                 # rim light on the left edge
        f[top + 1:ground + 1, (x + w - 1) % W] = 5   # shade on the right
        for xx in range(x + 2, x + w - 2, 3):        # LED columns
            for yy in range(top + 2, ground - 1, 2):
                if rng.random() < 0.55:
                    f[yy, xx % W] = 15 if rng.random() < 0.8 else (9 if rng.random() < 0.5 else 13)
        x += w + rng.randint(0, 5)
    for k in range(5):                # cable trays bridging between pillars, fiber hanging below
        x0, length, y0 = rng.randrange(W), rng.randint(30, 70), rng.randint(5, 10)
        for i in range(length):
            xx = (x0 + i) % W
            f[y0, xx] = 10
            if f[y0 + 1, xx] == 0:
                f[y0 + 1, xx] = 8 if i % 3 else 11
    f[f > 0] = np.where(np.arange(H)[:, None].repeat(W, 1)[f > 0] >= ground - 1, 2, f[f > 0])
    f[ground + 1:] = 1

    bpal = [(4, 5, 8), (8, 10, 15), (12, 15, 22), (17, 21, 30), (23, 28, 40), (30, 36, 51),
            (14, 16, 24), (40, 46, 62), (44, 70, 110), (60, 170, 110), (46, 60, 86), (70, 92, 128),
            (112, 140, 182), fog, fog, fog]
    # 0..5 darkness to haze gradient, 6 wall slab, 7 wall edge, 8 window blue, 9 window green,
    # 10..12 light shaft dim / mid / bright, 13..15 fog
    BW = 256
    b = np.zeros((H, BW), np.uint8)
    for y in range(H):
        for x in range(BW):
            b[y, x] = min(5, int(y / 26 * 5 + bayer4(x, y)))
    x = 0
    while x < BW:                     # city walls: slabs that leave the top of the strip
        w = rng.randint(10, 30)
        top = rng.randint(0, 10) if rng.random() < 0.6 else rng.randint(10, 18)
        for xx in range(x, x + w):
            for yy in range(top, ground + 1):
                b[yy, xx % BW] = 7 if xx == x else 6
        for yy in range(top + 2, ground - 1, 3):     # sparse windows
            for xx in range(x + 2, x + w - 1, 3):
                r = rng.random()
                if r < 0.10:
                    b[yy, xx % BW] = 9
                elif r < 0.22:
                    b[yy, xx % BW] = 8
        x += w + rng.randint(1, 8)
    for _ in range(5):                # light shafts falling from far above, slanted
        sx, width, slope = rng.uniform(0, BW), rng.uniform(4, 9), rng.uniform(0.15, 0.35)
        for y in range(ground + 1):
            c = sx + slope * y
            for xx in range(int(c - width), int(c + width) + 1):
                d = abs(xx - c) / width
                lvl = 1 - d
                v = lvl * (0.5 + 0.5 * y / ground)
                if v > 0.55:
                    b[y, xx % BW] = 12 if v > 0.8 and bayer4(xx, y) < 0.6 else 11
                elif v > 0.25 and bayer4(xx, y) < v * 1.6:
                    b[y, xx % BW] = 10
    b[ground + 1:] = 13
    return f, b, fpal, bpal


def pack4(img):
    """Pack 4-bit pixels two per byte, low nibble = left pixel."""
    return (img[:, 0::2] | (img[:, 1::2] << 4)).astype(np.uint8).tobytes()


LEAGUES = {
    "edge": dict(pal=EDGE_PAL, tiles=paint_edge_tiles, background=paint_edge_background,
                 horizon=paint_edge_horizon),
    "spine": dict(pal=SPINE_PAL, tiles=paint_spine_tiles, background=paint_spine_background,
                  horizon=paint_spine_horizon),
    # "core":  dict(pal=CORE_PAL, tiles=paint_core_tiles, ...),     M5
}
