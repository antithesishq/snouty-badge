"""The Boneyard (SPEC 19.5): an aircraft boneyard under hard sun, rows of
mothballed airliners, then the future: drones, scramjets, a crashed
orbital shuttle, rocket boosters standing nose-down in the sand.

The league in the shared tile layout (tools/leagues.py) plus the pack's
slots (packs/common.py): runway centerline dashes, taxiway asphalt and its
yellow line, sand drifts, wing shadows, the scorched reentry furrow, and
its crust of fused sand.
"""
from __future__ import annotations

import math

import numpy as np

from common import (  # noqa: F401
    A_OFF, A_SURF, A_WALL, A_KICKER, A_COOLANT, A_BAY, A_RAMP, A_JUMP, A_VENT, A_CRUST,
    SURF, SURF_DOT, SURF_SEAM_V, SURF_SEAM_H, SURF_SEAM_X, RUT, EDGE_OPEN, WALL, COOLANT, BAY,
    RAMP, WALL_DIAG, EDGE_DIAG, GAP, VENT_LANE, VENT_MOUTH, SWEEP_LANE, SWEEP_GATE, PIT,
    PAD_SPAWN, PAD_CRATE, KICKER, JUMP, CRUST, CRUST_CRACK, CRUST_HOLE, NTILES,
    L, Palette, Tileset, grid, side_dist, diag_dist, rot, bayer4, hash01, reput, Canvas,
)
from art.raster import hx  # noqa: E402

NAME = "boneyard"
TITLE = "THE BONEYARD"
FILE = "BONEYARD"

PAL = Palette([
    ("fog", (226, 214, 190)),
    # runway concrete
    ("floor", (178, 174, 166)), ("floor_seam", (150, 146, 140)), ("lane_dot", (240, 240, 234)),
    ("conc_lt", (188, 184, 176)), ("conc_dk", (164, 160, 152)),
    ("rut", (132, 128, 122)), ("rut_cable", (150, 154, 104)),
    ("mark", (238, 238, 232)), ("mark_yel", (232, 192, 66)),
    ("asph", (110, 108, 110)), ("asph_lt", (122, 120, 122)), ("asph_seam", (94, 92, 96)),
    ("shadow", (124, 120, 120)), ("shadow_asph", (80, 78, 82)),
    ("scorch", (70, 60, 56)), ("scorch_hi", (110, 92, 80)),
    # desert
    ("sand", (214, 186, 138)), ("sand_lt", (224, 198, 152)), ("sand_dk", (196, 168, 122)),
    ("scrub", (128, 132, 84)), ("scrub_dk", (90, 96, 64)), ("tyre", (40, 38, 40)),
    ("alu", (190, 194, 198)), ("alu_hi", (228, 230, 232)), ("alu_dk", (128, 132, 138)),
    ("bag", (240, 238, 230)), ("bag_sh", (196, 194, 188)), ("roundel_r", (196, 64, 52)), ("roundel_b", (60, 100, 170)),
    # barriers: red and white checks, aluminium scrap behind
    ("wall_a", (214, 64, 52)), ("wall_b", (242, 238, 230)),
    ("scrap", (168, 172, 176)), ("scrap_hi", (212, 216, 218)), ("scrap_rust", (156, 112, 80)), ("scrap_dk", (104, 106, 110)),
    ("wall_base", (122, 110, 96)),
    # the reentry furrow: a burnt lip over a charred trench with embers
    ("lip", (150, 120, 92)), ("lip_dk", (96, 76, 60)),
    ("void", (30, 22, 20)), ("void_mid", (120, 52, 28)),
    # features
    ("cool", (84, 72, 112)), ("cool_hi", (184, 164, 224)), ("cool_rim", (112, 98, 132)),
    ("bay_floor", (62, 72, 92)), ("bay_stripe", (240, 200, 60)), ("bay_hi", (250, 240, 200)),
    ("vent_rim", (122, 118, 112)), ("vent_dk", (48, 42, 40)), ("vent_glow", (255, 152, 60)),
    ("ramp", (170, 174, 180)), ("ramp_hi", (214, 218, 222)), ("ramp_arrow", (240, 196, 50)),
    ("chk_w", (240, 238, 232)), ("chk_k", (24, 24, 26)),
    ("seam_lit", (180, 150, 70)), ("seam_glow", (250, 222, 110)),
    # crust: fused sand over the furrow
    ("glassed", (196, 176, 146)), ("glassed_hi", (232, 240, 228)), ("glassed_dk", (150, 128, 104)),
])

# Background tiles (1..15, attribute off).
BY_SAND, BY_RIPPLE, BY_SAND_DK, BY_SCRUB, BY_TYRE, BY_PANEL, BY_RIDGE = 1, 2, 3, 4, 5, 6, 7
FURROW_LIP = 7      # the furrow's scorched lip reuses the ridge slot (see paint_tiles)
BY_ENGINE = 8       # 8..11 2x2 bagged engine lying in the sand, top-down
BY_WING = 12        # 12..15 2x2 wing panel with a roundel
# Road slots (attribute surface).
STRIPE, STRIPE_Y = 28, 29            # white centerline dash (travel x, y)
TAXI_LINE, TAXI_LINE_Y = 30, 31      # yellow taxiway line (travel x, y)
ASPH, ASPH_SEAM = 89, 90             # taxiway asphalt
DRIFT, DRIFT_HEAVY = 91, 124         # sand drifts over the road
WING_SHADOW, SCORCH, SHADOW_ASPH = 125, 126, 127

ROAD_VARIANTS = {
    "runway": {},
    "taxiway": {SURF: ASPH, SURF_SEAM_V: ASPH, SURF_SEAM_H: ASPH, SURF_SEAM_X: ASPH_SEAM,
                SURF_DOT: ASPH, RUT: ASPH_SEAM, RUT + 1: ASPH_SEAM},
}
SHADOW_TILES = {"runway": WING_SHADOW, "taxiway": SHADOW_ASPH}
STRIPE_TILES = (STRIPE, STRIPE_Y, TAXI_LINE, TAXI_LINE_Y)
# Centerline dashes per variant: (x tile, y tile).
CENTER_LINES = {"runway": (STRIPE, STRIPE_Y), "taxiway": (TAXI_LINE, TAXI_LINE_Y)}


def conc(P, x, y, salt):
    h = hash01(x // 2, y // 2, salt)
    return P["conc_dk"] if h < 0.12 else (P["conc_lt"] if h < 0.22 else P["floor"])


def sand(P, x, y, salt):
    h = hash01(x // 2, y // 2, salt)
    return P["sand_dk"] if h < 0.15 else (P["sand_lt"] if h < 0.3 else P["sand"])


def paint_tiles(P):
    ts = Tileset(P)
    s = lambda x, y, k: sand(P, x, y, k)  # noqa: E731
    ts.put(BY_SAND, "desert sand", A_OFF, grid(lambda x, y: s(x, y, 1)))
    ts.put(BY_RIPPLE, "sand ripples", A_OFF, grid(lambda x, y: P["sand_lt"] if (x + 2 * y) % 8 in (0, 1) else s(x, y, 2)))
    ts.put(BY_SAND_DK, "sand, darker", A_OFF, grid(lambda x, y: P["sand_dk"] if hash01(x // 2, y // 2, 3) < 0.6 else P["sand"]))
    ts.put(BY_SCRUB, "creosote scrub", A_OFF, grid(
        lambda x, y: (P["scrub_dk"] if (x + y) % 3 == 0 else P["scrub"]) if math.hypot(x - 3.5, y - 3.5) < 2.6 + 0.8 * math.sin(3 * x + y) else s(x, y, 4)))
    ts.put(BY_TYRE, "half-buried tyre", A_OFF, grid(
        lambda x, y: P["tyre"] if 1.6 < math.hypot(x - 3.5, y - 3.5) < 3.3 else s(x, y, 5)))
    ts.put(BY_PANEL, "rivet panel debris", A_OFF, grid(
        lambda x, y: (P["alu_dk"] if (x + y) % 3 == 0 and y in (1, 5) else P["alu"]) if 1 <= x <= 6 and 1 <= y <= 5 else s(x, y, 6)))
    ts.put(BY_RIDGE, "scorched sand (the furrow's lip)", A_OFF, grid(
        lambda x, y: P["scorch"] if hash01(x // 2, y // 2, 7) < 0.45 else (P["scorch_hi"] if hash01(x, y, 8) < 0.5 else P["lip_dk"])))
    eng = np.zeros((16, 16), np.uint8)
    for y in range(16):
        for x in range(16):
            v = s(x, y, 8)
            if 2 <= y <= 12 and 1 <= x <= 13:
                v = P["bag"] if y < 9 else P["bag_sh"]
                if x in (1, 13) or y == 12:
                    v = P["bag_sh"]
                if x % 4 == 2 and 3 <= y <= 11:
                    v = P["bag_sh"]         # the wrap's tape bands
            elif y == 13 and 2 <= x <= 14:
                v = P["sand_dk"]
            elif 14 <= x <= 15 and 5 <= y <= 9:
                v = P["alu_dk"]             # the exhaust cone
            eng[y, x] = v
    for k, (oy, ox) in enumerate(((0, 0), (0, 8), (8, 0), (8, 8))):
        ts.put(BY_ENGINE + k, f"bagged engine {'TL TR BL BR'.split()[k]}", A_OFF, eng[oy:oy + 8, ox:ox + 8])
    wing = np.zeros((16, 16), np.uint8)
    for y in range(16):
        for x in range(16):
            v = s(x, y, 9)
            if y >= x * 0.5 + 1 and y <= 14 and x <= 14:
                v = P["alu"] if (x + y) % 5 else P["alu_dk"]
                r = math.hypot(x - 7, y - 10)
                if r < 3.2:
                    v = P["roundel_b"] if r > 1.8 else (P["wall_b"] if r > 0.9 else P["roundel_r"])
            wing[y, x] = v
    for k, (oy, ox) in enumerate(((0, 0), (0, 8), (8, 0), (8, 8))):
        ts.put(BY_WING + k, f"wing panel {'TL TR BL BR'.split()[k]}", A_OFF, wing[oy:oy + 8, ox:ox + 8])

    # Road: runway concrete slabs, the joints every 16 px.
    c = lambda x, y, k: conc(P, x, y, k)  # noqa: E731
    ts.put(SURF, "runway concrete", A_SURF, grid(lambda x, y: c(x, y, 21)))
    ts.put(SURF_DOT, "runway touchdown mark", A_SURF, grid(
        lambda x, y: P["mark"] if 2 <= x <= 5 and 3 <= y <= 4 else c(x, y, 22)))
    ts.put(SURF_SEAM_V, "runway joint left", A_SURF, grid(lambda x, y: P["floor_seam"] if x == 0 else c(x, y, 23)))
    ts.put(SURF_SEAM_H, "runway joint top", A_SURF, grid(lambda x, y: P["floor_seam"] if y == 0 else c(x, y, 24)))
    ts.put(SURF_SEAM_X, "runway joint corner", A_SURF, grid(lambda x, y: P["floor_seam"] if x == 0 or y == 0 else c(x, y, 25)))

    L.paint_track_pieces(ts, P)
    L.paint_arena_pieces(ts, P)

    # Ruts: cracks with dry weeds.
    def crack(x, y):
        yy = 3.5 + 1.5 * math.sin(x * 0.9)
        if abs(y - yy) < 0.6:
            return P["rut"]
        if abs(y - yy) < 1.6 and hash01(x, y, 26) < 0.25:
            return P["rut_cable"]
        return c(x, y, 26)
    r = grid(crack)
    reput(ts, RUT, "runway crack (travel x)", A_SURF, r)
    reput(ts, RUT + 1, "runway crack (travel y)", A_SURF, r.T.copy())

    # Barriers: red/white checks facing the road, aluminium scrap behind.
    def wall_px(d, x, y):
        if d <= 1:
            return P["wall_a"] if ((x >> 1) + (y >> 1)) & 1 else P["wall_b"]
        if d >= 6:
            return P["wall_base"]
        h = hash01(x // 2, y // 2, 7)
        return P["scrap_hi"] if h < 0.25 else P["scrap"] if h < 0.65 else P["scrap_rust"] if h < 0.8 else P["scrap_dk"]
    for m in range(16):
        reput(ts, WALL + m, f"barrier mask {m:04b}", A_WALL,
              grid(lambda x, y: wall_px(side_dist(m, x, y), x, y) if m else P["wall_base"]))
    for cc in range(4):
        reput(ts, WALL_DIAG + cc, f"barrier corner {'NE SE SW NW'.split()[cc]}", A_WALL,
              grid(lambda x, y: wall_px(diag_dist(cc, x, y), x, y)))

    # Ramps, jumps, kickers: riveted wing plates with yellow chevrons.
    def plate(x, y, kind):
        if y in (0, 7):
            return P["alu_dk"] if x % 2 else P["ramp_arrow"]
        if kind == "kicker" and 1 <= x <= 6 and (abs(y - 3.5) + x) % 4 < 1.2:
            return P["ramp_arrow"]
        if kind != "kicker" and 2 <= x <= 6 and abs(abs(y - 3.5) - (6 - x)) < 0.8:
            return P["ramp_arrow"]
        if (x, y) in ((1, 1), (1, 6), (6, 1), (6, 6)):
            return P["alu_dk"]
        return P["ramp_hi"] if x % 3 == 0 else P["ramp"]
    for k in range(4):
        reput(ts, RAMP + k, f"wing ramp {'ESWN'[k]}", A_RAMP, rot(grid(lambda x, y: plate(x, y, "ramp")), k))
        reput(ts, KICKER + k, f"wing kicker {'ESWN'[k]}", A_KICKER, rot(grid(lambda x, y: plate(x, y, "kicker")), k))
        reput(ts, JUMP + k, f"wing jump {'ESWN'[k]}", A_JUMP, rot(grid(lambda x, y: plate(x, y, "jump")), k))

    # Hydraulic fluid slick.
    def slick(x, y):
        rr = math.hypot(x - 3.5, y - 3.5) + 0.6 * math.sin(x * 1.7 + y)
        if rr > 4.4:
            return c(x, y, 27)
        if rr > 3.6:
            return P["cool_rim"]
        return P["cool_hi"] if (x, y) in ((2, 2), (3, 2), (5, 4)) else P["cool"]
    reput(ts, COOLANT, "hydraulic slick", A_COOLANT, grid(slick))
    # Jet blast lane: scorched blast-deflector grating, a turbine in the wall.
    lane = grid(lambda x, y: P["vent_rim"] if y in (0, 7) else (
        P["scorch_hi"] if x % 2 == 0 else P["vent_dk"]))
    reput(ts, VENT_LANE, "jet blast lane (travel x)", A_VENT, lane)
    reput(ts, VENT_LANE + 1, "jet blast lane (travel y)", A_VENT, lane.T.copy())

    def turbine(x, y):
        r = math.hypot(x - 3.5, y - 3.5)
        if r > 3.7:
            return P["alu_dk"]
        if r < 1.2:
            return P["vent_glow"]
        return P["vent_dk"] if int(math.atan2(y - 3.5, x - 3.5) * 2.5) % 2 else P["alu"]
    t = grid(turbine)
    reput(ts, VENT_MOUTH, "running turbine (travel x)", A_WALL, t)
    reput(ts, VENT_MOUTH + 1, "running turbine (travel y)", A_WALL, t.T.copy())
    # The cowling's roll: tyre-skid streaks; its gap in the barrier.
    sk = grid(lambda x, y: P["rut"] if x in (2, 5) and hash01(x, y, 29) < 0.8 else c(x, y, 28))
    reput(ts, SWEEP_LANE, "cowling roll marks (travel x)", A_SURF, sk)
    reput(ts, SWEEP_LANE + 1, "cowling roll marks (travel y)", A_SURF, sk.T.copy())
    gate = grid(lambda x, y: P["wall_a"] if ((x + y) >> 1) & 1 else P["scrap_dk"])
    reput(ts, SWEEP_GATE, "barrier gap (travel x)", A_WALL, gate)
    reput(ts, SWEEP_GATE + 1, "barrier gap (travel y)", A_WALL, gate.T.copy())

    # --- pack slots ---
    def glassed(x, y, cracked):
        if cracked and (abs(x - 1.2 * y + 1) < 0.7 or (y == 5 and x > 3)):
            return P["void"]
        h = hash01(x, y, 61)
        return P["glassed_hi"] if h < 0.08 else (P["glassed_dk"] if h < 0.3 else P["glassed"])
    ts.put(CRUST, "fused sand crust", A_CRUST, grid(lambda x, y: glassed(x, y, False)))
    ts.put(CRUST_CRACK, "fused sand cracking", A_CRUST, grid(lambda x, y: glassed(x, y, True)))
    ts.put(CRUST_HOLE, "crust fallen into the furrow", A_CRUST, grid(
        lambda x, y: P["void_mid"] if hash01(x // 2, y // 2, 63) < 0.15 else P["void"]))
    dash = grid(lambda x, y: P["mark"] if 2 <= y <= 5 else c(x, y, 30))
    ts.put(STRIPE, "runway centerline dash (travel x)", A_SURF, dash)
    ts.put(STRIPE_Y, "runway centerline dash (travel y)", A_SURF, dash.T.copy())
    a = lambda x, y, k: P["asph_lt"] if hash01(x // 2, y // 2, k) < 0.15 else P["asph"]  # noqa: E731
    tl = grid(lambda x, y: P["mark_yel"] if 3 <= y <= 4 else a(x, y, 31))
    ts.put(TAXI_LINE, "taxiway yellow line (travel x)", A_SURF, tl)
    ts.put(TAXI_LINE_Y, "taxiway yellow line (travel y)", A_SURF, tl.T.copy())
    ts.put(ASPH, "taxiway asphalt", A_SURF, grid(lambda x, y: a(x, y, 32)))
    ts.put(ASPH_SEAM, "taxiway asphalt patch", A_SURF, grid(lambda x, y: P["asph_seam"] if x == 0 or y == 0 else a(x, y, 33)))
    ts.put(DRIFT, "sand drift on the road", A_SURF, grid(
        lambda x, y: sand(P, x, y, 34) if hash01(x // 2, y // 2, 35) < 0.45 else c(x, y, 34)))
    ts.put(DRIFT_HEAVY, "heavy sand drift", A_SURF, grid(
        lambda x, y: sand(P, x, y, 36) if hash01(x // 2, y // 2, 37) < 0.85 else c(x, y, 36)))
    ts.put(WING_SHADOW, "wing shadow on concrete", A_SURF, grid(lambda x, y: P["shadow"]))
    ts.put(SCORCH, "scorched concrete", A_SURF, grid(
        lambda x, y: P["scorch_hi"] if hash01(x // 2, y // 2, 38) < 0.3 else P["scorch"]))
    ts.put(SHADOW_ASPH, "wing shadow on asphalt", A_SURF, grid(lambda x, y: P["shadow_asph"]))
    for i in range(NTILES):
        if ts.names[i] is None:
            ts.tiles[i] = ts.tiles[1]
    return ts


def block_desert(block, rng):
    n = block.shape[0]
    for ty in range(n):
        for tx in range(n):
            r = rng.random()
            block[ty, tx] = BY_RIPPLE if r < 0.1 else BY_SAND_DK if r < 0.16 else BY_SAND
    avail = np.ones_like(block, bool)
    for base, count in ((BY_ENGINE, 4), (BY_WING, 3)):
        for _ in range(count):
            for _try in range(200):
                x, y = rng.randrange(n - 2), rng.randrange(n - 2)
                if avail[max(0, y - 1):y + 3, max(0, x - 1):x + 3].all():
                    block[y:y + 2, x:x + 2] = np.array([[base, base + 1], [base + 2, base + 3]])
                    avail[max(0, y - 1):y + 3, max(0, x - 1):x + 3] = False
                    break
    for ty in range(n):
        for tx in range(n):
            if avail[ty, tx]:
                r = rng.random()
                block[ty, tx] = BY_SCRUB if r < 0.03 else BY_TYRE if r < 0.04 else BY_PANEL if r < 0.055 else block[ty, tx]


def background(kind="desert"):
    def paint(tmap, free, rng):
        L.wallpaper(tmap, free, rng, block_desert, (BY_ENGINE, BY_WING), BY_SAND)
    return paint


# ------------------------------------------------------------ horizon
def paint_horizon(fog, rng):
    """Front 512x32: rows of tail fins over fuselages, one vertical booster
    with a red beacon, the shuttle's tail, heat shimmer at the ground. Back
    256x32: a hard pale sky, the white sun, far mesas."""
    fpal = [fog, fog, (214, 204, 184), (206, 202, 196), (242, 240, 234), (186, 184, 182), (152, 152, 154),
            (64, 62, 64), (198, 72, 58), (62, 102, 172), (224, 182, 62), (236, 232, 222),
            (176, 170, 160), (30, 30, 34), (96, 40, 36), (255, 64, 44)]
    # 0 transparent, 1 fog, 2 haze/shimmer, 3 far fin, 4 fin white, 5 fin shade, 6 fuselage grey,
    # 7 dark, 8 livery red, 9 livery blue, 10 livery yellow, 11 booster white, 12 booster shade,
    # 13 black, 14 beacon off (blink), 15 beacon on
    W, H = 512, 32
    f = np.zeros((H, W), np.uint8)
    ground = 29

    def fin(x0, h, w, body, stripe, far=False):
        """A swept tail fin standing on a fuselage hump at x0."""
        top = ground - 4 - h
        for y in range(top, ground - 3):
            t = (y - top) / max(h, 1)
            xl = x0 + int((1 - t) * w * 0.9)
            xr = x0 + int(w * 0.35 + (1 - t) * w * 0.9) + int(t * w * 0.65)
            for x in range(xl, xr + 1):
                c = body if not far else 3
                if not far and x >= xr - 1:
                    c = 5
                if not far and stripe and abs(t - 0.45) < 0.12:
                    c = stripe
                f[y, x % W] = c
        for y in range(ground - 4, ground + 1):           # fuselage
            for x in range(x0 - w, x0 + 2 * w + 6):
                if f[y, x % W] in (0, 3):
                    f[y, x % W] = 3 if far else (6 if y > ground - 2 else 5)
    x = 0
    while x < W:                                          # far rows, pale
        fin(x, rng.randint(4, 7), rng.randint(4, 6), 3, 0, far=True)
        x += rng.randint(12, 22)
    x = rng.randint(0, 10)
    while x < W:                                          # near rows, liveries
        fin(x, rng.randint(9, 14), rng.randint(6, 9), 4, rng.choice((8, 9, 10, 0, 9)))
        x += rng.randint(28, 46)
    # The vertical booster, nose up, with a red beacon.
    bx = 150
    for y in range(1, ground + 1):
        hw = 4 if y > 6 else max(1, int((y - 1) * 0.8))
        for xx in range(bx - hw, bx + hw + 1):
            c = 11 if xx < bx + 2 else 12
            if y in (12, 13, 22, 23):
                c = 13
            f[y, xx] = c
    f[0, bx] = 15
    f[0, bx + 1] = 15
    # The shuttle's tail: white with a black leading edge, rising off its belly.
    sx = 384
    for y in range(6, ground - 2):
        t = (y - 6) / (ground - 8)
        xl = sx + int((1 - t) * 10)
        xr = sx + 14
        for xx in range(xl, xr + 1):
            f[y, xx] = 13 if xx <= xl + 1 else (5 if xx > xr - 2 else 4)
    for y in range(ground - 6, ground + 1):              # the orbiter's back
        for xx in range(sx - 30, sx + 22):
            f[y, xx] = 4 if y < ground - 3 else 13
    f[6, sx + 13] = 15
    # Heat shimmer: broken haze rows at the ground.
    for y in (ground - 1, ground):
        for xx in range(W):
            if bayer4(xx + y * 3, y) < 0.4:
                f[y, xx] = 2
    f[ground + 1:] = 1

    bpal = [(112, 164, 214), (124, 172, 216), (138, 182, 218), (152, 190, 218), (168, 198, 216),
            (184, 206, 214), (200, 212, 210), (214, 214, 204), (190, 160, 128), (172, 140, 112),
            (252, 250, 236), (255, 255, 250), (206, 180, 146), (232, 226, 212), fog, fog]
    # 0..6 sky gradient, 7 haze, 8/9 mesa lit/shade, 10/11 sun halo/core, 12 far dunes, 13 cloud
    BW = 256
    b = np.zeros((H, BW), np.uint8)
    for y in range(H):
        for xx in range(BW):
            b[y, xx] = min(6, int(y / 26 * 6 + bayer4(xx, y)))
            if y == 23 and bayer4(xx + y, y) < 0.5:
                b[y, xx] = 7
    sxn, syn = 90, 7
    for y in range(H):
        for xx in range(BW):
            d = math.hypot(xx - sxn, y - syn)
            if d <= 3.5:
                b[y, xx] = 11
            elif d <= 7.5 and bayer4(xx, y) < 1 - (d - 3.5) / 4 * 0.8:
                b[y, xx] = 10
    xx = 0
    while xx < BW:                                        # flat-topped mesas
        w, h = rng.randint(14, 34), rng.randint(3, 7)
        for x2 in range(xx, xx + w):
            slope = min(x2 - xx, xx + w - 1 - x2)
            top = ground - min(h, slope + 1)
            for y in range(top, ground + 1):
                b[y, x2 % BW] = 8 if x2 - xx < w * 0.6 else 9
        xx += w + rng.randint(10, 40)
    b[ground - 1:ground + 1][b[ground - 1:ground + 1] < 7] = 12
    b[ground + 1:] = 14
    return f, b, fpal, bpal


LEAGUE = dict(pal=PAL, tiles=paint_tiles, background=background(), horizon=paint_horizon)


# ------------------------------------------------------------ props
PK = {
    "o": hx(0x1E1A18), "W": hx(0xF4F2EC), "w": hx(0xD2D2CE), "l": hx(0xAAACAE), "m": hx(0x787A7E),
    "k": hx(0x404044), "r": hx(0xC84034), "b": hx(0x3C64AA), "y": hx(0xE8BE3C), "t": hx(0x222022),
    "s": hx(0xD6BA8A), "S": hx(0xAA8C64), "g": hx(0x78B4C8), "n": hx(0xDC7832), "R": hx(0x965A3C),
}
PROP_LABELS = ["tail fin", "bagged engine", "landing gear", "booster (nose down)", "wing tip",
               "satellite dish", "shuttle nose", "loose cowling (mover)"]


def _cell():
    return Canvas(32, 48)


def sand_base(c, x0=4, x1=27):
    for x in range(x0, x1 + 1):
        h = 1 + int(1.5 * (1 - abs((x - (x0 + x1) / 2) / ((x1 - x0) / 2)) ** 2))
        c.vline(x, 47 - h, 47, PK["s"] if x % 5 else PK["S"])


def prop_tail():
    c = _cell()
    # an airliner's swept tail fin standing on a stub of fuselage, the
    # rudder hinge, a faded livery: a red cap and a blue disc logo
    inside = lambda x, y: c.get(x, y) is not None  # noqa: E731
    c.poly([(4, 46), (27, 46), (27, 8), (22, 4), (18, 4)], PK["W"])
    c.poly([(22, 46), (27, 46), (27, 8), (24, 6)], PK["w"], clip=inside)
    c.line(21, 10, 21, 40, PK["l"], clip=inside)
    c.poly([(16, 4), (28, 4), (28, 13), (13, 13)], PK["r"], clip=inside)
    c.ellipse(18, 24, 4, 4, PK["b"], clip=inside)
    c.ellipse(18, 24, 2, 2, PK["W"], clip=inside)
    c.rect(3, 40, 28, 46, PK["l"])           # the fuselage stub
    c.rect(3, 40, 28, 41, PK["w"])
    for x in range(5, 28, 4):
        c.rect(x, 43, x + 1, 44, PK["k"])    # taped-up windows
    sand_base(c, 2, 29)
    c.outline(PK["o"])
    return c


def prop_engine():
    c = _cell()
    # a turbofan wrapped in white, on a cradle
    c.ellipse(16, 28, 13, 11, PK["W"])
    c.ellipse(19, 30, 10, 9, PK["w"], clip=lambda x, y: x > 17 and y > 27)
    for x in range(6, 28, 5):                # tape bands round the wrap
        c.vline(x, 18, 38, PK["l"], clip=lambda xx, yy: c.get(xx, yy) is not None) if False else None
        for y in range(17, 40):
            if c.get(x, y) is not None:
                c.set(x, y, PK["l"])
    c.ellipse(16, 28, 5, 5, PK["w"])         # the intake under the cover
    c.ellipse(16, 28, 3, 3, PK["l"])
    c.rect(6, 39, 9, 45, PK["y"])            # cradle legs
    c.rect(23, 39, 26, 45, PK["y"])
    c.rect(4, 44, 28, 45, PK["k"])
    sand_base(c, 3, 28)
    c.outline(PK["o"])
    return c


def prop_gear():
    c = _cell()
    c.rect(14, 4, 18, 30, PK["l"])           # strut
    c.rect(17, 4, 18, 30, PK["m"])
    c.rect(13, 14, 19, 17, PK["k"])          # oleo collar
    c.line(18, 10, 26, 22, PK["m"])          # drag brace
    c.line(19, 10, 27, 22, PK["l"])
    c.rect(10, 29, 22, 31, PK["m"])          # axle
    for x0 in (4, 18):                       # two tyres
        c.ellipse(x0 + 5, 38, 5.5, 8, PK["t"])
        c.ellipse(x0 + 5, 38, 2.5, 3.5, PK["m"])
        c.set(x0 + 5, 38, PK["l"])
    sand_base(c, 2, 29)
    c.outline(PK["o"])
    return c


def prop_booster():
    c = _cell()
    # a solid rocket booster standing nose-down like a fence post
    c.rect(10, 4, 21, 40, PK["W"])
    c.rect(18, 4, 21, 40, PK["w"])
    c.rect(10, 4, 11, 40, PK["l"])
    for y in (10, 11, 24, 25):
        c.rect(10, y, 21, y, PK["k"])
    c.poly([(8, 2), (23, 2), (21, 8), (10, 8)], PK["m"])   # the nozzle, up in the air
    c.ellipse(15.5, 3, 6, 2, PK["k"])
    c.poly([(10, 40), (21, 40), (18, 46), (13, 46)], PK["w"])   # nose cone in the sand
    c.rect(12, 30, 19, 33, PK["n"])          # an orange tag
    sand_base(c, 3, 28)
    c.outline(PK["o"])
    return c


def prop_wingtip():
    c = _cell()
    # a broken wing tip stuck up out of the sand, a winglet and a nav light
    c.poly([(4, 46), (22, 46), (26, 22), (28, 6), (24, 6), (16, 30)], PK["w"])
    c.poly([(4, 46), (14, 46), (16, 30), (24, 6), (22, 6), (12, 30)], PK["W"])
    c.poly([(4, 46), (9, 38), (12, 46)], PK["m"])   # torn edge
    for y in range(36, 46, 3):
        c.set(10 + (y % 5), y, PK["k"])
    c.rect(25, 7, 27, 9, PK["r"])            # nav light
    c.line(14, 40, 22, 20, PK["l"])
    sand_base(c, 2, 26)
    c.outline(PK["o"])
    return c


def prop_dish():
    c = _cell()
    c.rect(15, 26, 17, 44, PK["m"])          # mast
    c.poly([(8, 44), (24, 44), (20, 38), (12, 38)], PK["l"])   # base
    c.ellipse(15, 18, 12, 12, PK["W"])       # dish, tilted up-left
    c.ellipse(17, 20, 9, 9, PK["w"], clip=lambda x, y: x + y > 36)
    c.ellipse(15, 18, 12, 12, PK["l"], clip=lambda x, y: math.hypot(x + 0.5 - 15, y + 0.5 - 18) > 10.8)
    c.line(15, 18, 7, 9, PK["m"])            # feed arm
    c.rect(5, 7, 7, 9, PK["k"])
    c.ellipse(15, 18, 2, 2, PK["g"])
    sand_base(c, 4, 28)
    c.outline(PK["o"])
    return c


def prop_shuttle_nose():
    c = _cell()
    # the orbiter's nose, upright, white with the black heat-shield chin
    c.poly([(5, 46), (27, 46), (27, 24), (22, 12), (16, 6), (10, 12), (5, 24)], PK["W"])
    c.poly([(19, 46), (27, 46), (27, 24), (22, 12), (17, 7)], PK["w"])
    c.poly([(5, 46), (11, 46), (9, 26), (14, 8), (10, 12), (5, 24)], PK["k"])   # the black side
    c.poly([(12, 18), (21, 18), (22, 22), (11, 22)], PK["o"])   # cockpit windows
    for x in (13, 16, 19):
        c.rect(x, 19, x + 1, 21, PK["g"])
    c.rect(14, 30, 24, 31, PK["b"])
    c.rect(14, 33, 24, 33, PK["r"])
    sand_base(c, 2, 29)
    c.outline(PK["o"])
    return c


def prop_cowling():
    """The loose cowling (the crossing mover): an engine cowl half rolled
    over, dented, a rusted inside."""
    c = _cell()
    c.ellipse(16, 34, 14, 13.5, PK["l"])
    c.ellipse(16, 34, 10, 9.5, PK["R"])      # the open inside
    c.ellipse(16, 34, 7, 6.5, PK["k"])
    c.ellipse(16, 34, 14, 13.5, PK["w"], clip=lambda x, y: math.hypot(x + 0.5 - 16, y + 0.5 - 34) > 11.5 and x < 16)
    for a in range(0, 360, 45):              # rivets
        x = 16 + math.cos(math.radians(a)) * 12.5
        y = 34 + math.sin(math.radians(a)) * 11.5
        c.set(x, y, PK["m"])
    c.rect(7, 24, 11, 26, PK["y"])           # a warning label
    c.outline(PK["o"])
    return c


PROPS = [prop_tail, prop_engine, prop_gear, prop_booster, prop_wingtip, prop_dish, prop_shuttle_nose, prop_cowling]
PROP = {n: i for i, n in enumerate(["tail", "engine", "gear", "booster", "wingtip", "dish", "nose", "cowling"])}
MOVER_CELL = PROP["cowling"]


def draw_props():
    return [fn() for fn in PROPS]


# ------------------------------------------------------------ the arena
import pack_arena as PA  # noqa: E402


class Hangar18Arena(PA.PackArena):
    """Hangar 18 (SPEC 19.9): a collapsed hangar round a crashed saucer
    nobody ever explained. The saucer lies sunk in its crater in the
    middle (the pit); its rim is a ring ramp, kickers along all four faces;
    the fallen roof and wreckage make the corner islands; broken wings lie
    across the east and west lanes as ramps over the gaps they tore in the
    floor (gap jumps); the loose cowling rolls along the north lane. 18 nav
    nodes (a 1.9 KB blob)."""
    name, stem, background = "HANGAR 18", "hangar_18", "desert"
    GAP_ROWS = (41, 46)    # the wing gaps across the side lanes: rows 41..45

    def __init__(self):
        n = PA.ARENA
        k = np.full((n, n), PA.FLOOR, np.uint8)
        for x0 in (14, 60):            # fallen roof and wreckage
            for y0 in (14, 60):
                k[y0:y0 + 14, x0:x0 + 14] = PA.SOLID
        k[36:52, 36:52] = PA.PIT       # the saucer's crater
        g0, g1 = self.GAP_ROWS
        self.ramps = []
        for x0, x1 in ((0, 13), (74, 87)):
            k[g0:g1, x0:x1 + 1] = PA.PIT
            self.ramps.append((x0, g0 - 2, x1, g0 - 1, 1))   # a wing, facing S, north of the gap
            self.ramps.append((x0, g1, x1, g1 + 1, 3))       # facing N, south of it
        self.kind = k
        # The saucer's rim: kickers along the whole of each crater face.
        self.kickers = [(36, 34, 51, 35, 1), (36, 52, 51, 53, 3), (34, 36, 35, 51, 0), (52, 36, 53, 51, 2)]
        self.bays = [(0, 0), (82, 82)]
        self.spawns = [(30, 80, 3), (56, 80, 3), (5, 20, 0), (5, 64, 0), (81, 20, 2), (81, 64, 2)]
        self.pads = [(44, 4), (43, 83), (4, 30), (83, 57), (44, 24), (43, 63), (24, 43), (63, 44)]
        J, B = 2, 1
        self.set_nodes([
            ("bay_nw", 3, 3, B), ("c_ne", 80, 7, 0), ("c_sw", 7, 80, 0), ("bay_se", 84, 84, B),
            ("n", 44, 7, 0), ("s", 43, 80, 0),
            ("w_a", 7, 29, J), ("w_b", 7, 58, J), ("e_a", 80, 29, J), ("e_b", 80, 58, J),
            ("i_nw", 31, 31, 0), ("i_ne", 56, 31, 0), ("i_sw", 31, 56, 0), ("i_se", 56, 56, 0),
            ("pn", 44, 24, J), ("ps", 43, 63, J), ("pw", 24, 43, J), ("pe", 63, 44, J),
        ], [("pn", "ps"), ("ps", "pn"), ("pw", "pe"), ("pe", "pw"),
            ("w_a", "w_b"), ("w_b", "w_a"), ("e_a", "e_b"), ("e_b", "e_a")])
        self.sweep_row = 7
        self.sweeper = dict(period=1200, warn=60, phase=300, damage=50, push=64, size=16, speed=56)
        w = PA.rel_world
        self.props = [("dish", *w(20, 20)), ("engine", *w(66, 18)), ("wingtip", *w(68, 70)), ("engine", *w(19, 68)),
                      ("dish", *w(-4, 44)), ("wingtip", *w(92, 40)), ("engine", *w(30, -4)), ("dish", *w(60, 92)),
                      ("wingtip", *w(24, 24)), ("engine", *w(63, 63))]

    def post(self, tmap):
        """The saucer in its crater: hull panels over the pit's middle
        (attribute off either way); the fallen roof's sheets on the corner
        islands (wing panels, rivet plates)."""
        O = PA.O
        for ty in range(O + 36, O + 52):
            for tx in range(O + 36, O + 52):
                r = math.hypot(tx - O - 43.5, ty - O - 43.5)
                if GAP <= tmap[ty, tx] < GAP + 16 and r < 6.6:
                    tmap[ty, tx] = BY_PANEL
        for x0 in (14, 60):
            for y0 in (14, 60):
                for ty in range(O + y0 + 1, O + y0 + 13, 2):
                    for tx in range(O + x0 + 1, O + x0 + 13, 2):
                        if (tx // 2 * 7 + ty // 2 * 3) % 5 == 0:
                            tmap[ty:ty + 2, tx:tx + 2] = np.array([[BY_WING, BY_WING + 1], [BY_WING + 2, BY_WING + 3]])
                        else:
                            tmap[ty:ty + 2, tx:tx + 2] = BY_PANEL


ARENA = Hangar18Arena
