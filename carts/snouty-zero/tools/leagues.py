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
FLAG_BITS = {"rail": 0, "open": 1, "pad": 2, "throttled": 3, "cold": 4, "hot": 5, "hop": 6}

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
    ("haz_red", (214, 38, 38)), ("haz_white", (242, 242, 242)), ("metal_hi", (204, 210, 218)),
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

    # Edge pieces by 4-neighbour mask. Open: floor, then the glow strip.
    def open_px(d):
        return [fl, fl, fl, fl, P["glow_mid"], P["glow"], P["glow"], P["glow_dim"]][min(d, 7)]

    def rail_px(d, x, y):
        if d <= 1:   # hazard chevrons facing the track, period 4 diagonal
            return P["haz_red"] if ((x + y) >> 1) & 1 else P["haz_white"]
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
    ts.put(START, "start line checker", A_START, grid(lambda x, y: P["haz_white"] if ((x >> 2) + (y >> 2)) & 1 else P["chk_k"]))
    s1 = grid(lambda x, y: P["seam_glow"] if x == 4 else (P["seam_lit"] if x == 3 else fl))
    s2 = grid(lambda x, y: P["seam_glow"] if x in (2, 5) else (P["seam_lit"] if x in (1, 6) else fl))
    ts.put(SEC1, "sector 1 seam (travel x)", A_SEC1, s1)
    ts.put(SEC1 + 1, "sector 1 seam (travel y)", A_SEC1, s1.T.copy())
    ts.put(SEC2, "sector 2 seam (travel x)", A_SEC2, s2)
    ts.put(SEC2 + 1, "sector 2 seam (travel y)", A_SEC2, s2.T.copy())
    # Unused slots get the plain rack panel so no tile anywhere uses index 0.
    for i in range(256):
        if ts.names[i] is None:
            ts.tiles[i] = ts.tiles[BG_PLAIN]
    return ts


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


def pack4(img):
    """Pack 4-bit pixels two per byte, low nibble = left pixel."""
    return (img[:, 0::2] | (img[:, 1::2] << 4)).astype(np.uint8).tobytes()


LEAGUES = {
    "edge": dict(pal=EDGE_PAL, tiles=paint_edge_tiles, background=paint_edge_background,
                 horizon=paint_edge_horizon),
    # "spine": dict(pal=SPINE_PAL, tiles=paint_spine_tiles, ...),   M3
    # "core":  dict(pal=CORE_PAL, tiles=paint_core_tiles, ...),     M5
}
