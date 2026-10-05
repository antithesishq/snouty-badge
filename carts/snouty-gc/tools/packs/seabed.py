"""The Seabed (SPEC 19.6): they used the ocean as a heat sink until it was
gone. A dried ocean floor of salt crust and grey sand: rust-red ships on
their sides, a container ship's stacks spilled into a maze, whale
skeletons with their ribs standing like arches, a submarine on its keel, a
toppled oil rig, and the ruptured trunk of a transatlantic data cable.

The league in the shared tile layout (tools/leagues.py) plus the pack's
slots (packs/common.py): three road floors (grey sand, the salt pan, the
trench's silt), the cable surfacing along the trench floor (the
centerline dashes), dead coral and sand drifts, the wrecks' and the ribs'
shadows, and the salt crust (tiles 121..123) over brine. Cooler and
greyer than The Boneyard's sun-baked concrete and sand, rust as the
accent. M9 Track S; the arena The Drain is `DrainArena` below.
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

NAME = "seabed"
TITLE = "THE SEABED"
FILE = "SEABED"

PAL = Palette([
    ("fog", (210, 218, 222)),
    # grey sand: the default road (SURF..RUT) and the shared pieces' floor
    ("floor", (150, 151, 147)), ("floor_seam", (136, 137, 134)), ("lane_dot", (214, 214, 206)),
    ("sand_lt", (162, 163, 158)), ("sand_dk", (138, 139, 136)), ("ripple", (172, 173, 168)),
    ("rut", (112, 113, 112)), ("rut_cable", (78, 84, 82)),
    # the salt pan
    ("salt", (226, 228, 223)), ("salt_lt", (240, 242, 238)), ("salt_dk", (206, 210, 206)),
    ("salt_crack", (192, 198, 198)), ("salt_crack_dk", (160, 166, 168)),
    # trench silt
    ("silt", (98, 105, 112)), ("silt_lt", (110, 117, 124)), ("silt_dk", (86, 92, 99)), ("pebble", (140, 146, 148)),
    # the off-road flats: pale grey sand
    ("flat", (186, 187, 182)), ("flat_lt", (198, 199, 194)), ("flat_dk", (172, 173, 169)),
    # dead coral and bone
    ("coral", (226, 214, 206)), ("coral_sh", (192, 176, 170)), ("coral_dk", (150, 134, 130)),
    ("bone", (234, 228, 210)), ("bone_sh", (198, 190, 170)), ("bone_dk", (146, 140, 124)),
    # rust: hulls, containers, the walls
    ("rust", (158, 72, 44)), ("rust_lt", (190, 100, 62)), ("rust_dk", (112, 50, 34)), ("rust_deep", (72, 38, 30)),
    ("paint", (200, 202, 196)), ("paint_dk", (160, 164, 162)),
    ("cont", (172, 64, 46)), ("cont_lt", (200, 90, 60)), ("cont_dk", (112, 42, 32)),
    ("cont_b", (64, 92, 120)), ("cont_b_dk", (42, 62, 84)),
    ("barnacle", (124, 146, 138)), ("barnacle_hi", (180, 196, 188)),
    # the cable
    ("cable", (40, 44, 46)), ("cable_hi", (84, 92, 90)), ("cable_wire", (150, 128, 76)),
    # shadows on the road
    ("shadow_sand", (118, 120, 120)), ("shadow_salt", (178, 184, 188)),
    # walls (the shared pieces' roles; the walls are repainted below)
    ("wall_a", (230, 232, 226)), ("wall_b", (158, 72, 44)), ("scrap", (120, 62, 42)),
    ("scrap_hi", (176, 96, 62)), ("scrap_rust", (96, 46, 34)), ("scrap_dk", (70, 40, 34)),
    ("wall_base", (58, 40, 36)),
    # the pit: the trench's dark, brine at the bottom
    ("lip", (178, 176, 166)), ("lip_dk", (112, 112, 108)),
    ("void", (26, 32, 42)), ("void_mid", (50, 70, 84)),
    # features
    ("cool", (92, 150, 148)), ("cool_hi", (196, 236, 226)), ("cool_rim", (232, 236, 228)), ("cool_dk", (70, 120, 122)),
    ("bay_floor", (46, 60, 82)), ("bay_stripe", (236, 196, 60)), ("bay_hi", (250, 240, 200)),
    ("vent_rim", (96, 100, 104)), ("vent_dk", (38, 42, 48)), ("vent_glow", (120, 226, 236)), ("vent_hot", (230, 250, 250)),
    ("ramp", (122, 130, 136)), ("ramp_hi", (160, 168, 172)), ("ramp_arrow", (238, 198, 58)), ("ramp_dk", (82, 88, 94)),
    ("chk_w", (240, 240, 236)), ("chk_k", (26, 28, 32)),
    ("seam_lit", (96, 160, 170)), ("seam_glow", (150, 236, 244)),
    # crust: a salt crust over brine
    ("crust", (188, 210, 226)), ("crust_hi", (226, 240, 248)), ("crust_sh", (146, 172, 190)),
    ("crust_crack", (60, 74, 86)), ("brine", (36, 52, 62)), ("brine_hi", (84, 120, 130)),
])

# Background tiles (1..15, attribute off).
SB_FLAT, SB_CRACKED, SB_SAND, SB_RIPPLE, SB_CORAL, SB_SHELLS, SB_CABLE = 1, 2, 3, 4, 5, 6, 7
SB_CONT_N, SB_CONT_S, SB_CONT_W, SB_CONT_E = 8, 9, 10, 11   # a container's halves: lying along x (N, S), along y (W, E)
SB_HULL, SB_HULL_SEAM, SB_DECK, SB_BONE = 12, 13, 14, 15
# Road slots (attribute surface).
SALT_TL, SALT_TR, SALT_BL, SALT_BR = 28, 29, 30, 125   # the salt pan: one 16 px crack network in 4 tiles
SILT_A, SILT_B = 31, 89                        # the trench floor
CABLE_X, CABLE_Y = 90, 91                      # the cable surfacing along the trench floor (travel x, y)
DRIFT = DRIFT_HEAVY = 124                      # dead coral rubble over the road (the `drift` word)
SHADOW_SAND, SHADOW_SALT = 126, 127            # a wreck's or a rib arch's shadow

ROAD_VARIANTS = {
    "sand": {},
    # the rasterizer's 2x2 rhythm: SEAM_X at (even, even), SEAM_H (odd, even), SEAM_V (even, odd), SURF (odd, odd)
    "salt": {SURF_SEAM_X: SALT_TL, SURF_SEAM_H: SALT_TR, SURF_SEAM_V: SALT_BL, SURF: SALT_BR,
             SURF_DOT: SALT_BR, RUT: SALT_BR, RUT + 1: SALT_BR},
    "silt": {SURF: SILT_A, SURF_SEAM_V: SILT_A, SURF_SEAM_H: SILT_A, SURF_SEAM_X: SILT_B,
             SURF_DOT: SILT_A, RUT: SILT_B, RUT + 1: SILT_B},
}
SHADOW_TILES = {"sand": SHADOW_SAND, "salt": SHADOW_SALT}
STRIPE_TILES = (CABLE_X, CABLE_Y)
CENTER_LINES = {"silt": (CABLE_X, CABLE_Y)}


def noise3(P, a, b, c, x, y, salt, lo=0.14, hi=0.28):
    h = hash01(x // 2, y // 2, salt)
    return P[c] if h < lo else (P[b] if h < hi else P[a])


def periodic_cracks(nodes, edges, size=8):
    """A crack network that tiles: lines between nodes (and their copies a
    tile over), plotted modulo the tile."""
    m = np.zeros((size, size), bool)
    for (ax, ay), (bx, by) in edges:
        n = int(max(abs(bx - ax), abs(by - ay)) * 2) + 1
        for k in range(n + 1):
            t = k / n
            m[int(round(ay + (by - ay) * t)) % size, int(round(ax + (bx - ax) * t)) % size] = True
    return m


# Polygon cracks: an 8 px network (each tile seamless with itself) for the
# crust and the shadows, and a 16 px one (a hexagonal lattice with jittered
# edges) the salt pan's four tiles share.
CRACK_A = periodic_cracks(None, [((1, 2), (5, 5)), ((5, 5), (9, 2)), ((5, 5), (4, 9))])
CRACK_B = periodic_cracks(None, [((2, 5), (6, 2)), ((6, 2), (10, 5)), ((2, 5), (3, -1))])
CRACK_16 = periodic_cracks(None, [((4, 4), (8, 8)), ((8, 8), (12, 10)), ((12, 10), (16, 6)), ((16, 6), (20, 4)),
                                  ((12, 10), (9, 15)), ((9, 15), (4, 20))], size=16)


def grid16(fn):
    return np.array([[fn(x, y) for x in range(16)] for y in range(16)], np.uint8)


def paint_tiles(P):
    ts = Tileset(P)
    fl = lambda x, y, k: noise3(P, "flat", "flat_lt", "flat_dk", x, y, k)  # noqa: E731
    sd = lambda x, y, k: noise3(P, "floor", "sand_lt", "sand_dk", x, y, k, 0.12, 0.24)  # noqa: E731
    # --- background ---
    ts.put(SB_FLAT, "pale grey flats", A_OFF, grid(lambda x, y: fl(x, y, 1)))
    ts.put(SB_CRACKED, "salt flats, polygon cracks", A_OFF, grid(
        lambda x, y: P["salt_dk"] if CRACK_A[y, x] else (P["salt_dk"] if hash01(x, y, 2) < 0.08 else P["salt"])))
    ts.put(SB_SAND, "grey sand", A_OFF, grid(lambda x, y: sd(x, y, 3)))
    ts.put(SB_RIPPLE, "sand ripples", A_OFF, grid(
        lambda x, y: P["ripple"] if (x + 2 * y) % 8 in (0, 1) else (P["sand_dk"] if (x + 2 * y) % 8 == 2 else sd(x, y, 4))))

    def coral(x, y):
        r = math.hypot(x - 3.5, y - 3.5)
        a = math.atan2(y - 3.5, x - 3.5)
        arm = r < 3.4 and (abs(math.sin(a * 2.5 + 0.6)) > 0.55 or r < 1.4)
        if arm:
            return P["coral"] if (x + y) % 3 else P["coral_sh"]
        if r < 3.8 and hash01(x, y, 5) < 0.5:
            return P["coral_dk"]
        return fl(x, y, 5)
    ts.put(SB_CORAL, "dead coral clump", A_OFF, grid(coral))

    def shells(x, y):
        if (x, y) in ((1, 1), (2, 1), (5, 4), (5, 5), (2, 6)):
            return P["bone"]
        if (x, y) in ((1, 2), (6, 5), (3, 6)):
            return P["bone_dk"]
        return fl(x, y, 6)
    ts.put(SB_SHELLS, "shells and bone chips", A_OFF, grid(shells))

    def cable_bg(x, y):    # a whole tile of the cable's armour: a spiral wrap of wires
        if (x + y) % 4 == 0:
            return P["cable_wire"]
        return P["cable_hi"] if (x + y) % 4 == 1 else P["cable"]
    ts.put(SB_CABLE, "the cable's armour", A_OFF, grid(cable_bg))

    def cont(x, y, edge):   # a container half: corrugated across the length, dark on its long edge
        if edge:
            return P["cont_dk"]
        return P["cont_lt"] if x % 3 == 0 else (P["cont_dk"] if x % 3 == 2 and hash01(x, y, 9) < 0.2 else P["cont"])
    cn = grid(lambda x, y: cont(x, y, y == 0))
    cs = grid(lambda x, y: cont(x, y, y == 7))
    ts.put(SB_CONT_N, "container, north half (lying along x)", A_OFF, cn)
    ts.put(SB_CONT_S, "container, south half (lying along x)", A_OFF, cs)
    ts.put(SB_CONT_W, "container, west half (lying along y)", A_OFF, cn.T.copy())
    ts.put(SB_CONT_E, "container, east half (lying along y)", A_OFF, cs.T.copy())

    def hull(x, y, seam):
        if seam and y == 3:
            return P["rust_dk"]
        if seam and y == 4 and x % 3 == 1:
            return P["rust_lt"]        # rivets
        h = hash01(x // 2, y // 2, 12)
        return P["rust_lt"] if h < 0.12 else (P["rust_dk"] if h < 0.3 else (P["barnacle"] if h < 0.34 else P["rust"]))
    ts.put(SB_HULL, "a hull's rust plating", A_OFF, grid(lambda x, y: hull(x, y, False)))
    ts.put(SB_HULL_SEAM, "hull plating, a riveted seam", A_OFF, grid(lambda x, y: hull(x, y, True)))
    ts.put(SB_DECK, "a deck's flaking paint", A_OFF, grid(
        lambda x, y: P["rust"] if hash01(x // 2, y, 13) < 0.18 else (P["paint_dk"] if x % 4 == 0 else P["paint"])))
    ts.put(SB_BONE, "whale bone", A_OFF, grid(
        lambda x, y: P["bone_dk"] if hash01(x, y, 14) < 0.08 else (P["bone_sh"] if (x + y) % 5 == 0 else P["bone"])))

    # --- the default road: grey sand, ripples every 16 px ---
    rip = lambda x, y, k: P["ripple"] if (x + 2 * y + k) % 16 in (0, 1) else sd(x, y, 20 + k)  # noqa: E731
    ts.put(SURF, "grey sand road", A_SURF, grid(lambda x, y: rip(x, y, 0)))
    ts.put(SURF_DOT, "grey sand, a shell", A_SURF, grid(
        lambda x, y: P["lane_dot"] if (x, y) in ((3, 3), (4, 3), (3, 4)) else rip(x, y, 0)))
    ts.put(SURF_SEAM_V, "grey sand ripple", A_SURF, grid(lambda x, y: rip(x, y, 4)))
    ts.put(SURF_SEAM_H, "grey sand ripple", A_SURF, grid(lambda x, y: rip(x, y, 8)))
    ts.put(SURF_SEAM_X, "grey sand ripple", A_SURF, grid(lambda x, y: rip(x, y, 12)))

    L.paint_track_pieces(ts, P)
    L.paint_arena_pieces(ts, P)

    # Ruts: the cable dragged through the sand.
    def rut(x, y):
        if y in (2, 5):
            return P["rut"]
        if y in (3, 4) and hash01(x, y, 26) < 0.2:
            return P["rut_cable"]
        return sd(x, y, 26)
    r = grid(rut)
    reput(ts, RUT, "cable drag rut (travel x)", A_SURF, r)
    reput(ts, RUT + 1, "cable drag rut (travel y)", A_SURF, r.T.copy())

    # Walls: rusted hull plates with a salt-crusted rim facing the road,
    # barnacles further back.
    def wall_px(d, x, y):
        if d == 0:
            return P["salt_lt"] if hash01(x, y, 30) < 0.8 else P["salt_crack"]
        if d <= 2:
            if (x + y) % 6 == 0:
                return P["rust_deep"]      # the plate joints
            return P["rust_lt"] if d == 1 else P["rust"]
        if d >= 6:
            return P["wall_base"]
        h = hash01(x // 2, y // 2, 31)
        return P["barnacle"] if h < 0.15 else P["rust_dk"] if h < 0.6 else P["rust"] if h < 0.85 else P["rust_deep"]
    for m in range(16):
        reput(ts, WALL + m, f"hull wall mask {m:04b}", A_WALL,
              grid(lambda x, y: wall_px(side_dist(m, x, y), x, y) if m else P["wall_base"]))
    for cc in range(4):
        reput(ts, WALL_DIAG + cc, f"hull wall corner {'NE SE SW NW'.split()[cc]}", A_WALL,
              grid(lambda x, y: wall_px(diag_dist(cc, x, y), x, y)))

    # Ramps, jumps, kickers: hatch covers off the wrecks, yellow chevrons.
    def plate(x, y, kind):
        if y in (0, 7):
            return P["ramp_arrow"] if (x >> 1) & 1 else P["ramp_dk"]
        if kind == "kicker" and 1 <= x <= 6 and (abs(y - 3.5) + x) % 4 < 1.2:
            return P["ramp_arrow"]
        if kind != "kicker" and 2 <= x <= 6 and abs(abs(y - 3.5) - (6 - x)) < 0.8:
            return P["ramp_arrow"]
        if x == 0:
            return P["ramp_dk"]
        return P["ramp_hi"] if x % 3 == 1 else P["ramp"]
    for k in range(4):
        reput(ts, RAMP + k, f"hatch-cover ramp {'ESWN'[k]}", A_RAMP, rot(grid(lambda x, y: plate(x, y, "ramp")), k))
        reput(ts, KICKER + k, f"hatch-cover kicker {'ESWN'[k]}", A_KICKER, rot(grid(lambda x, y: plate(x, y, "kicker")), k))
        reput(ts, JUMP + k, f"hatch-cover jump {'ESWN'[k]}", A_JUMP, rot(grid(lambda x, y: plate(x, y, "jump")), k))

    # Tide pool: a whole tile of brine, a white salt rim at its corners.
    def tide(x, y):
        rr = math.hypot(x - 3.5, y - 3.5)
        if rr > 4.6 and hash01(x, y, 32) < 0.7:
            return P["cool_rim"]
        if (x, y) in ((2, 2), (3, 2), (5, 5)):
            return P["cool_hi"]
        return P["cool_dk"] if hash01(x // 2, y // 2, 33) < 0.2 else P["cool"]
    reput(ts, COOLANT, "tide pool", A_COOLANT, grid(tide))
    # Steam vent: fissures across the road from a ruptured repeater, the
    # repeater's housing in the wall.
    lane = grid(lambda x, y: P["vent_rim"] if y in (0, 7) else (
        P["vent_glow"] if (y == 3 or y == 4) and (x + y) % 3 else (P["vent_dk"] if y in (2, 5) else P["silt_dk"])))
    reput(ts, VENT_LANE, "steam fissure (travel x)", A_VENT, lane)
    reput(ts, VENT_LANE + 1, "steam fissure (travel y)", A_VENT, lane.T.copy())

    def repeater(x, y):
        if x in (0, 7):
            return P["cable"]
        if y in (0, 7):
            return P["cable_wire"]
        if 2 <= x <= 5 and 2 <= y <= 5:
            return P["vent_hot"] if (x + y) % 2 else P["vent_glow"]
        return P["vent_rim"]
    t = grid(repeater)
    reput(ts, VENT_MOUTH, "ruptured repeater (travel x)", A_WALL, t)
    reput(ts, VENT_MOUTH + 1, "ruptured repeater (travel y)", A_WALL, t.T.copy())
    # The container slide: drag marks across the road; its gap in the wall.
    sk = grid(lambda x, y: P["rust_dk"] if x in (1, 6) and hash01(x, y, 34) < 0.7 else (
        P["rut"] if x in (2, 5) else sd(x, y, 35)))
    reput(ts, SWEEP_LANE, "container drag marks (travel x)", A_SURF, sk)
    reput(ts, SWEEP_LANE + 1, "container drag marks (travel y)", A_SURF, sk.T.copy())
    gate = grid(lambda x, y: P["ramp_arrow"] if ((x + y) >> 1) & 1 else P["chk_k"])
    reput(ts, SWEEP_GATE, "slide gap, hazard stripes (travel x)", A_WALL, gate)
    reput(ts, SWEEP_GATE + 1, "slide gap, hazard stripes (travel y)", A_WALL, gate.T.copy())
    reput(ts, PIT, "the trench's dark", A_OFF, grid(
        lambda x, y: P["void_mid"] if hash01(x // 2, y // 2, 41) < 0.10 else P["void"]))

    # --- pack slots ---
    def salt(x, y, crack, salt_):
        if crack[y, x]:
            return P["salt_crack"] if hash01(x, y, salt_) < 0.75 else P["salt_crack_dk"]
        h = hash01(x // 2, y // 2, salt_ + 1)
        return P["salt_lt"] if h < 0.10 else (P["salt_dk"] if h < 0.26 else P["salt"])
    def pan(x, y):    # 16x16: the crack (a low ridge: shadowed, lit on its top-left)
        if CRACK_16[y, x]:
            return P["salt_crack"]
        if CRACK_16[(y + 1) % 16, (x + 1) % 16]:
            return P["salt_lt"]
        return P["salt_dk"] if hash01(x // 2, y // 2, 50) < 0.08 else P["salt"]
    big = grid16(pan)
    for t, (oy, ox) in zip((SALT_TL, SALT_TR, SALT_BL, SALT_BR), ((0, 0), (0, 8), (8, 0), (8, 8))):
        ts.put(t, f"salt pan, polygon cracks {'TL TR BL BR'.split()[(oy // 8) * 2 + ox // 8]}", A_SURF, big[oy:oy + 8, ox:ox + 8])
    si = lambda x, y, k: noise3(P, "silt", "silt_lt", "silt_dk", x, y, k, 0.12, 0.24)  # noqa: E731
    ts.put(SILT_A, "trench silt", A_SURF, grid(lambda x, y: si(x, y, 56)))
    ts.put(SILT_B, "trench silt, a pebble", A_SURF, grid(
        lambda x, y: P["pebble"] if (x, y) in ((4, 4), (5, 4), (4, 5)) else si(x, y, 57)))

    def cable_dash(x, y):   # travel x: the cable along the travel, its wrap across it
        if y in (1, 6):
            return P["silt_dk"]
        if y in (2, 5):
            return P["cable"]
        return P["cable_wire"] if (x + y) % 3 == 0 else (P["cable_hi"] if y == 3 else P["cable"])
    c = grid(cable_dash)
    ts.put(CABLE_X, "the cable surfacing (travel x)", A_SURF, c)
    ts.put(CABLE_Y, "the cable surfacing (travel y)", A_SURF, c.T.copy())

    def rubble(x, y):
        h = hash01(x, y, 60)
        if h < 0.25:
            return P["coral"]
        if h < 0.38:
            return P["coral_sh"]
        if h < 0.44:
            return P["coral_dk"]
        return salt(x, y, np.zeros((8, 8), bool), 60)
    ts.put(DRIFT, "dead coral rubble", A_SURF, grid(rubble))
    ts.put(SHADOW_SAND, "a wreck's shadow on sand", A_SURF, grid(
        lambda x, y: P["shadow_sand"] if (x + 2 * y) % 16 not in (0, 1) else P["floor_seam"]))
    ts.put(SHADOW_SALT, "a rib arch's shadow on salt", A_SURF, grid(
        lambda x, y: P["salt_crack"] if CRACK_A[y, x] else P["shadow_salt"]))

    # Crust: a salt crust grown over a brine pool, then cracking, then gone.
    def crust(x, y, state):
        if state == 2:
            if (x, y) in ((2, 2), (5, 5), (6, 1)):
                return P["brine_hi"]
            return P["brine"] if hash01(x // 2, y // 2, 63) < 0.85 else P["void_mid"]
        if state == 1 and (abs(x - y) < 0.8 or abs(x + y - 8) < 0.8 or (y == 4 and x < 3)):
            return P["crust_crack"]
        if CRACK_B[y, x]:
            return P["crust_sh"]
        if (x, y) in ((1, 6), (6, 3)):
            return P["brine_hi"]       # pinholes: the brine showing through
        h = hash01(x, y, 61)
        return P["crust_hi"] if h < 0.22 else P["crust"]
    ts.put(CRUST, "salt crust over brine", A_CRUST, grid(lambda x, y: crust(x, y, 0)))
    ts.put(CRUST_CRACK, "salt crust cracking", A_CRUST, grid(lambda x, y: crust(x, y, 1)))
    ts.put(CRUST_HOLE, "salt crust gone: the brine", A_CRUST, grid(lambda x, y: crust(x, y, 2)))
    for i in range(NTILES):
        if ts.names[i] is None:
            ts.tiles[i] = ts.tiles[1]
    return ts


# ------------------------------------------------------------ background
def scatter(block, rng, base, mix):
    """block: base tiles with `mix` [(tile, p), ...] scattered over it."""
    n = block.shape[0]
    for ty in range(n):
        for tx in range(n):
            r = rng.random()
            block[ty, tx] = base
            acc = 0.0
            for t, p in mix:
                acc += p
                if r < acc:
                    block[ty, tx] = t
                    break


def containers(block, rng, count, avail=None, horiz=None):
    """Containers lying in the block: 2 tiles wide, 5 to 7 long, with a
    tile of sand around each."""
    n = block.shape[0]
    if avail is None:
        avail = np.ones_like(block, bool)
    for _ in range(count):
        for _try in range(200):
            along_x = rng.random() < 0.5 if horiz is None else horiz
            ln = rng.randint(5, 7)
            w, h = (ln, 2) if along_x else (2, ln)
            x, y = rng.randrange(n - w), rng.randrange(n - h)
            if avail[max(0, y - 1):y + h + 1, max(0, x - 1):x + w + 1].all():
                if along_x:
                    block[y, x:x + w], block[y + 1, x:x + w] = SB_CONT_N, SB_CONT_S
                else:
                    block[y:y + h, x], block[y:y + h, x + 1] = SB_CONT_W, SB_CONT_E
                avail[max(0, y - 1):y + h + 1, max(0, x - 1):x + w + 1] = False
                break
    return avail


def skeleton(block, x0, y0, length, along_x, ribs_every=2, rib=3):
    """A whale skeleton seen from above: the spine and its ribs, bone tiles."""
    n = block.shape[0]
    for k in range(length):
        x, y = (x0 + k, y0) if along_x else (x0, y0 + k)
        block[y % n, x % n] = SB_BONE
        if 2 <= k < length - 3 and k % ribs_every == 0:
            reach = rib if k < length * 0.6 else rib - 1
            for s in (-1, 1):
                for d in range(1, reach + 1):
                    bend = 1 if d == reach else 0       # the rib curls back toward the tail
                    xx, yy = (x + bend, y + s * d) if along_x else (x + s * d, y + bend)
                    block[yy % n, xx % n] = SB_BONE
    # the skull: a wider block at the head end
    for a in range(-1, 2):
        for b in range(-2, 0):
            xx, yy = (x0 + b, y0 + a) if along_x else (x0 + a, y0 + b)
            block[yy % n, xx % n] = SB_BONE


def block_shoals(block, rng):
    """Salt flats round the wrecks: polygon-cracked salt, container stacks
    spilled off the ship, a few shells."""
    scatter(block, rng, SB_CRACKED, [(SB_FLAT, 0.08), (SB_SHELLS, 0.02), (SB_CORAL, 0.01)])
    containers(block, rng, 2)


def block_flats(block, rng):
    """The whalefall plain: grey sand with ripples, dead coral fields, bone
    chips and one skeleton a block."""
    scatter(block, rng, SB_SAND, [(SB_RIPPLE, 0.14), (SB_CORAL, 0.05), (SB_SHELLS, 0.03), (SB_FLAT, 0.08)])
    skeleton(block, rng.randrange(4, 12), rng.randrange(8, 24), rng.randint(14, 18), True)


def block_trench(block, rng):
    """The trench walls' sand: ripples, coral, shells."""
    scatter(block, rng, SB_SAND, [(SB_RIPPLE, 0.18), (SB_CORAL, 0.03), (SB_SHELLS, 0.02)])


def block_drain(block, rng):
    """Round the Drain: salt flats with containers and shells."""
    scatter(block, rng, SB_CRACKED, [(SB_FLAT, 0.1), (SB_SHELLS, 0.03)])
    containers(block, rng, 4)


# Per-kind overlays in world px: what the generic wallpaper cannot place.
# Shoals: the container maze (dense stacks round the south chicanes) and
# two hulls lying on their sides in the infield. Trench: the cable's run
# from the west along the deep's north lip until it goes down into it (it
# passes under the road where the two cross).
SHOALS_MAZE = (380, 480, 980, 990)          # x0, y0, x1, y1
SHOALS_HULLS = [((560, 320), 150, 54, 0.3), ((310, 700), 90, 36, 1.3)]   # centre, half length, half beam, angle
TRENCH_CABLE = [(20, 240), (200, 250), (340, 270), (480, 310), (600, 345), (720, 370), (790, 410)]


def paint_hull(tmap, free, cx, cy, hl, hb, ang):
    """A ship on its side from above: an elongated hull of rust plating,
    seams along it, the deck's flaking paint along one side."""
    c, s = math.cos(ang), math.sin(ang)
    for ty in range(128):
        for tx in range(128):
            if not free[ty, tx]:
                continue
            dx, dy = tx * 8 + 4 - cx, ty * 8 + 4 - cy
            u, v = dx * c + dy * s, -dx * s + dy * c
            if abs(u) > hl:
                continue
            taper = 1 - max(0.0, (u - hl * 0.55) / (hl * 0.45)) ** 2 if u > 0 else 1 - (max(0.0, -u - hl * 0.8) / (hl * 0.2)) ** 2
            half = hb * max(0.0, taper)
            if abs(v) > half:
                continue
            if v > half - 10:
                tmap[ty, tx] = SB_DECK
            elif int(v + 1000) // 16 % 2 == 0 and int(v + 1000) % 16 < 8:
                tmap[ty, tx] = SB_HULL_SEAM
            else:
                tmap[ty, tx] = SB_HULL


def seg_dist(px, py, a, b):
    (ax, ay), (bx, by) = a, b
    dx, dy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / max(dx * dx + dy * dy, 1e-9)))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def paint_polyline(tmap, free, pts, half, tile):
    for ty in range(128):
        for tx in range(128):
            if free[ty, tx]:
                px, py = tx * 8 + 4, ty * 8 + 4
                if min(seg_dist(px, py, a, b) for a, b in zip(pts, pts[1:])) <= half:
                    tmap[ty, tx] = tile


def background(kind="flats"):
    blocks = {"shoals": block_shoals, "flats": block_flats, "trench": block_trench, "drain": block_drain}

    def paint(tmap, free, rng):
        L.wallpaper(tmap, free, rng, blocks[kind], (), SB_FLAT)
        if kind == "shoals":
            x0, y0, x1, y1 = SHOALS_MAZE
            avail = np.ones((128, 128), bool)
            avail[:y0 // 8] = False
            avail[y1 // 8:] = False
            avail[:, :x0 // 8] = False
            avail[:, x1 // 8:] = False
            avail &= free
            # stacks of containers lying along x, two deep, an alley of salt
            # between each pair of rows (the maze the spill made)
            for ty0 in range(y0 // 8, y1 // 8, 5):
                for ty in (ty0, ty0 + 2):
                    tx = x0 // 8 + rng.randrange(3)
                    while tx + 5 < x1 // 8:
                        ln = rng.randint(5, 7)
                        if avail[ty:ty + 2, tx:tx + ln].all() and rng.random() < 0.9:
                            tmap[ty, tx:tx + ln], tmap[ty + 1, tx:tx + ln] = SB_CONT_N, SB_CONT_S
                        tx += ln + rng.randrange(2)
            for (cx, cy), hl, hb, ang in SHOALS_HULLS:
                paint_hull(tmap, free, cx, cy, hl, hb, ang)
        elif kind == "trench":
            paint_polyline(tmap, free, TRENCH_CABLE, 8, SB_CABLE)
    return paint


# ------------------------------------------------------------ horizon
def paint_horizon(fog, rng):
    """Front 512x32: ships on their sides in rust, the container ship's
    spilled stacks, the toppled oil rig on its legs with a red beacon still
    blinking, far wrecks in the haze, salt glare at the ground. Back 256x32:
    a pale washed-out sky and the long dry shelf where the coast used to
    be, a dead city along its top."""
    fpal = [fog, fog, (222, 228, 228), (176, 184, 190), (160, 76, 48), (124, 58, 40), (84, 44, 36),
            (208, 208, 202), (130, 136, 140), (70, 74, 80), (214, 176, 70), (232, 226, 208),
            (72, 98, 124), (30, 30, 34), (96, 40, 36), (255, 70, 50)]
    # 0 transparent, 1 fog, 2 salt glare, 3 far wreck haze, 4 rust, 5 rust shade, 6 rust dark,
    # 7 hull paint, 8 steel, 9 steel dark, 10 rig yellow, 11 bone, 12 container blue, 13 black,
    # 14 beacon off, 15 beacon on
    W, H = 512, 32
    f = np.zeros((H, W), np.uint8)
    ground = 29

    def put(x, y, c):
        if 0 <= y < H:
            f[y, x % W] = c

    def ship_on_side(x0, ln, hgt, far=False, lean=0.6):
        """A wreck heeled over on the salt: the hull's side (rust over a
        dark boot-top), the deck edge rising to a raked bow, the
        superstructure and funnel aft, leaning with her."""
        for x in range(x0, x0 + ln):
            t = (x - x0) / ln
            deck = hgt * (0.62 + 0.38 * t ** 2.5)
            if t > 0.93:
                deck *= 1 - (t - 0.93) / 0.07 * 0.7      # the stem's rake
            top = ground - int(round(deck))
            for y in range(top, ground + 1):
                if far:
                    c = 3
                elif y == top:
                    c = 7                                 # the rail and deck edge
                elif y >= ground - 1:
                    c = 6
                else:
                    c = 4 if y < top + (ground - top) * 0.5 else 5
                    if (x - x0) % 11 == 0:
                        c = 6                             # plate seams
                put(x, y, c)
        # superstructure and funnel aft, leaning with the list
        sx, sw, sh = x0 + int(ln * 0.08), max(4, ln // 6), max(3, int(hgt * 0.8))
        base = ground - int(round(hgt * 0.62))
        for k in range(sh):
            off = int(k * lean)
            for x in range(sx + off, sx + sw + off):
                c = 3 if far else (7 if k % 3 else 13)
                put(x, base - k, c)
        fx = sx + sw + 2
        for k in range(sh + 2):
            off = int(k * lean)
            for x in range(fx + off, fx + 3 + off):
                put(x, base - k, 3 if far else (13 if k >= sh else 4))

    x = 0
    while x < W:                                          # far wrecks in the haze
        ship_on_side(x, rng.randint(26, 40), rng.randint(4, 7), far=True, lean=rng.choice((0.5, -0.5, 0.8)))
        x += rng.randint(30, 60)
    # Near wrecks.
    for x0, ln, hgt, lean in ((20, 70, 14, 0.7), (210, 56, 11, -0.6), (330, 84, 16, 0.9)):
        ship_on_side(x0, ln, hgt, lean=lean)
    # The container ship's spilled stacks.
    cx = 120
    for k, (h, col) in enumerate(((3, 4), (4, 12), (2, 5), (5, 4), (3, 12), (4, 7), (2, 4))):
        for y in range(ground - h * 2, ground + 1):
            for x in range(cx + k * 6, cx + k * 6 + 6):
                put(x, y, 13 if (x - cx) % 6 == 5 or (ground - y) % 2 == 1 and (x - cx) % 6 == 0 else col)
    # The toppled oil rig: its legs on the ground, the deck canted, the
    # derrick leaning with the beacon at its top.
    rx = 448
    for leg in range(4):                                  # legs lying toward the left
        lx = rx - 4 + leg * 9
        for k in range(36):
            x, y = lx - k, ground - 1 - leg % 2 - k // 12
            put(x, y, 10 if k % 4 else 9)
            if k % 6 == 0:
                put(x, y - 1, 9)
    for y in range(ground - 10, ground - 2):              # the deck block
        for x in range(rx, rx + 30):
            put(x, y, 8 if y < ground - 6 else 9)
            if (x - rx) % 7 == 0:
                put(x, y, 13)
    for k in range(18):                                   # the derrick
        dx0 = rx + 18 + k // 3
        y = ground - 11 - k
        put(dx0, y, 10)
        put(dx0 + max(1, 5 - k // 4), y, 10)
        if k % 3 == 0:
            for x in range(dx0, dx0 + max(1, 5 - k // 4) + 1):
                put(x, y, 9)
    put(rx + 24, 0, 15)
    put(rx + 25, 0, 15)
    put(rx + 24, 1, 14)
    # Salt glare at the ground.
    for y in (ground - 1, ground):
        for x in range(W):
            if f[y, x] == 0 and bayer4(x + y * 3, y) < 0.5:
                f[y, x] = 2
    f[ground + 1:] = 1

    bpal = [(170, 196, 214), (178, 202, 218), (188, 208, 222), (198, 214, 224), (206, 218, 224),
            (212, 222, 226), (218, 224, 226), (224, 228, 228), (164, 172, 176), (146, 154, 160),
            (236, 240, 238), (250, 252, 250), (186, 190, 190), (128, 136, 142), fog, fog]
    # 0..7 a pale sky down to the haze, 8/9 the shelf lit/shade, 10/11 the sun's halo/core,
    # 12 the shelf's far face, 13 the dead city on its top
    BW = 256
    b = np.zeros((H, BW), np.uint8)
    for y in range(H):
        for xx in range(BW):
            b[y, xx] = min(7, int(y / 24 * 7 + bayer4(xx, y)))
    sxn, syn = 200, 6
    for y in range(H):
        for xx in range(BW):
            d = math.hypot(xx - sxn, y - syn)
            if d <= 3.0:
                b[y, xx] = 11
            elif d <= 7.0 and bayer4(xx, y) < 1 - (d - 3.0) / 4 * 0.85:
                b[y, xx] = 10
    # The dry shelf: a long flat-topped escarpment, striped by old tide lines.
    top = 22
    for xx in range(BW):
        t = top + int(round(1.2 * math.sin(xx * 0.05) + 0.8 * math.sin(xx * 0.13 + 1)))
        for y in range(t, ground + 1):
            b[y, xx] = 12 if y < t + 1 else (8 if (y - t) % 3 else 9)
        if hash01(xx // 3, 7, 70) < 0.3 and xx % 3:
            h = 1 + int(hash01(xx // 3, 8, 71) * 4)
            for y in range(t - h, t):
                b[y, xx] = 13                             # the dead city on the old coast
    b[ground + 1:] = 14
    return f, b, fpal, bpal


LEAGUE = dict(pal=PAL, tiles=paint_tiles, background=background("flats"), horizon=paint_horizon)


# ------------------------------------------------------------ props
PK = {
    "o": hx(0x1E1A1A), "W": hx(0xECE6D4), "w": hx(0xC8C0AA), "l": hx(0x969080), "R": hx(0xA0462A),
    "r": hx(0x682C1E), "n": hx(0xCC6838), "m": hx(0x7A7E80), "k": hx(0x404448), "s": hx(0xE2E4DE),
    "S": hx(0xB2B6B4), "g": hx(0x7A968C), "t": hx(0x161618), "y": hx(0xE8BE3C), "c": hx(0x6EDCE6),
}
PROP_LABELS = ["whale rib (left)", "whale rib (right)", "ship bow", "anchor", "periscope (submarine)",
               "container (also the slide)", "barnacled buoy", "the cable's broken end"]


def _cell():
    return Canvas(32, 48)


def salt_base(c, x0=4, x1=27):
    for x in range(x0, x1 + 1):
        h = 1 + int(1.5 * (1 - abs((x - (x0 + x1) / 2) / ((x1 - x0) / 2)) ** 2))
        c.vline(x, 47 - h, 47, PK["s"] if x % 4 else PK["S"])


def prop_rib(flip=False):
    """A rib standing up out of the salt, curving in over the road at its
    top (the left one curves right): with its mirror across the road the
    pair reads as an arch."""
    c = _cell()
    pts = []
    for k in range(41):
        t = k / 40
        x = 8 + 17 * t ** 1.8          # rises near-vertical, then bends over
        y = 45 - 40 * math.sin(t * math.pi / 2 * 1.05)
        pts.append((x, y, 4.4 - 2.6 * t))
    for x, y, r in pts:
        c.ellipse(x, y, r, r, PK["W"])
    for x, y, r in pts:                # the shaded underside
        c.ellipse(x + r * 0.45, y + r * 0.45, r * 0.55, r * 0.55, PK["w"],
                  clip=lambda xx, yy: c.get(xx, yy) is not None)
    for k in range(4, 30, 7):
        x, y, r = pts[k]
        c.set(x, y, PK["l"])
    salt_base(c, 2, 14)
    c.outline(PK["o"])
    if flip:
        m = _cell()
        m.paste(c, 0, 0, flip=True)
        return m
    return c


def prop_bow():
    c = _cell()
    # a ship's bow standing up out of the salt where she went down by the
    # head: the raked stem, black topsides over the red antifouling, the
    # white boot-top line between, draft marks, the anchor in its hawse
    hull = [(3, 46), (27, 46), (26, 26), (28, 4), (23, 4), (8, 22), (4, 32)]
    inside = lambda x, y: c.get(x, y) is not None  # noqa: E731
    c.poly(hull, PK["k"])
    c.poly([(3, 46), (27, 46), (26, 30), (4, 38)], PK["R"], clip=inside)        # antifouling below the line
    c.line(4, 37, 26, 29, PK["W"], clip=inside)                                  # the boot-top line
    c.line(4, 38, 26, 30, PK["W"], clip=inside)
    c.poly([(20, 46), (27, 46), (26, 26), (28, 4), (25, 4), (22, 26)], PK["r"], clip=lambda x, y: inside(x, y) and c.get(x, y) == PK["R"])
    c.poly([(22, 26), (25, 4), (28, 4), (26, 26)], PK["t"], clip=lambda x, y: inside(x, y) and c.get(x, y) == PK["k"])
    c.line(23, 4, 8, 22, PK["m"])                                                # the stem's edge catching light
    c.line(23, 5, 9, 22, PK["m"])
    for k, y in enumerate(range(12, 44, 5)):                                    # draft marks along the stem
        x = 21 - (y - 4) * 15 // 40 + 2
        c.rect(x, y, x + 1, y + 1, PK["W"])
    c.ellipse(17, 14, 2, 1.6, PK["t"])                                           # hawse pipe
    c.rect(16, 15, 18, 19, PK["m"])                                              # the anchor's shank in it
    c.vline(17, 16, 28, PK["R"])                                                 # a rust streak
    for x, y in ((6, 42), (9, 40), (13, 44), (19, 41), (24, 43)):
        c.set(x, y, PK["g"])
    salt_base(c, 2, 29)
    c.outline(PK["o"])
    return c


def prop_anchor():
    c = _cell()
    # a stockless anchor stuck crown-down in the salt, its chain trailing
    c.rect(14, 8, 17, 38, PK["m"])          # shank
    c.rect(16, 8, 17, 38, PK["k"])
    c.ellipse(15.5, 6, 4, 4, PK["k"])       # the ring
    c.ellipse(15.5, 6, 2, 2, None) if False else None
    for y in range(4, 9):
        for x in range(14, 18):
            if (x - 15.5) ** 2 + (y - 6) ** 2 < 3:
                c.px[y][x] = None
    c.poly([(5, 30), (15, 40), (26, 30), (27, 36), (16, 46), (4, 36)], PK["m"])   # crown and flukes
    c.poly([(16, 40), (26, 30), (27, 36), (16, 46)], PK["k"])
    c.poly([(3, 26), (8, 30), (4, 34)], PK["m"])
    c.poly([(28, 26), (23, 30), (27, 34)], PK["k"])
    for x, y in ((14, 20), (16, 28), (8, 34), (22, 33), (15, 13)):
        c.rect(x, y, x + 1, y + 1, PK["R"])  # rust
    for k in range(5):                      # chain links to the ground
        x, y = 19 + k * 2, 8 + k * 7
        c.ellipse(x + 0.5, y + 2, 1.5, 2.5, PK["k"])
        c.set(x, y + 2, PK["R"])
    salt_base(c, 3, 29)
    c.outline(PK["o"])
    return c


def prop_periscope():
    c = _cell()
    # the submarine on its keel: the sail with its fairwater planes, the
    # periscope still up, barnacles over the hull's curve
    c.ellipse(16, 50, 14, 9, PK["k"])       # the hull's back, mostly buried
    c.poly([(9, 44), (23, 44), (22, 18), (19, 15), (11, 15), (9, 18)], PK["k"])   # the sail
    c.poly([(17, 44), (23, 44), (22, 18), (19, 15), (17, 15)], PK["t"], clip=lambda x, y: c.get(x, y) is not None)
    c.rect(3, 25, 28, 27, PK["m"])          # fairwater planes
    c.rect(3, 27, 28, 27, PK["k"])
    c.rect(14, 3, 15, 15, PK["m"])          # periscope
    c.rect(12, 2, 16, 4, PK["k"])
    c.set(12, 3, PK["c"])                   # its lens catches the light
    c.rect(18, 8, 19, 15, PK["m"])          # a mast
    for x, y in ((10, 38), (12, 41), (20, 36), (11, 32), (21, 41), (6, 45), (25, 45), (14, 43)):
        c.rect(x, y, x + 1, y, PK["g"])
    c.rect(11, 20, 13, 21, PK["S"])         # salt streaks
    for x in range(2, 30):
        c.set(x, 47, PK["s"] if x % 4 else PK["S"])
    c.outline(PK["o"])
    return c


def prop_container():
    """A shipping container tipped off a stack, door end toward you, the
    side going away (also the container slide's sprite)."""
    c = _cell()
    c.poly([(3, 46), (25, 46), (25, 20), (3, 20)], PK["R"])        # the door end
    c.poly([(25, 46), (29, 42), (29, 17), (25, 20)], PK["r"])      # the side, in perspective
    c.poly([(3, 20), (25, 20), (29, 17), (7, 17)], PK["n"])        # the roof
    for x in range(26, 29, 2):
        c.line(x, 19, x, 44, PK["n"])        # the side's corrugation
    c.rect(3, 20, 25, 21, PK["r"])           # door header and sill
    c.rect(3, 44, 25, 46, PK["r"])
    c.vline(14, 21, 44, PK["r"])             # the two doors
    for x in (8, 11, 17, 20):                # locking bars
        c.vline(x, 22, 43, PK["m"])
        c.rect(x - 1, 31, x + 1, 33, PK["k"])
    for x, y in ((4, 26), (5, 34), (22, 40), (23, 25)):
        c.set(x, y, PK["W"])                 # salt bloom
    c.rect(5, 23, 7, 24, PK["W"])            # a stencil
    c.outline(PK["o"])
    return c


def prop_buoy():
    c = _cell()
    # a navigation buoy lying tilted: the float, its cage and lamp, a crust
    # of barnacles on the half that was under water
    c.ellipse(15, 36, 12, 9.5, PK["n"])
    c.ellipse(17, 38, 10, 7.5, PK["R"], clip=lambda x, y: x + y > 50)
    c.ellipse(15, 36, 12, 9.5, PK["W"], clip=lambda x, y: 31 <= y <= 33)      # the white band
    for x, y in ((6, 40), (8, 43), (10, 41), (12, 44), (5, 37), (14, 42), (17, 44), (9, 38)):
        c.rect(x, y, x + 1, y, PK["g"])
        c.set(x, y - 1, PK["S"])
    for x0 in (8, 14, 20):                   # the cage, leaning right
        c.line(x0, 28, x0 + 4, 12, PK["k"])
    c.line(10, 21, 23, 21, PK["k"])
    c.line(12, 14, 25, 14, PK["k"])
    c.rect(19, 8, 23, 12, PK["y"])           # the lamp
    c.rect(20, 7, 22, 7, PK["k"])
    for k in range(4):                       # chain into the salt
        c.ellipse(26 + (k % 2), 41 + k * 2, 1.2, 1.2, PK["k"])
    salt_base(c, 2, 29)
    c.outline(PK["o"])
    return c


def prop_cable_end():
    c = _cell()
    # the transatlantic cable's broken end: the trunk out of the salt,
    # curving up, the cut face's armour, insulation, copper and the fibre
    # core still lit, loose armour wires splayed
    pts = [(8 + 11 * t, 42 - 24 * math.sin(t * math.pi / 2)) for t in (k / 20 for k in range(21))]
    for x, y in pts:
        c.ellipse(x, y, 5.5, 5.5, PK["k"])
    for k, (x, y) in enumerate(pts):
        if k % 3 == 0:
            c.ellipse(x - 1, y - 1, 3, 3, PK["m"], clip=lambda xx, yy: c.get(xx, yy) is not None)
    fx, fy = pts[-1]
    c.ellipse(fx + 3, fy - 2, 6, 6.5, PK["y"])    # armour wires' ring
    c.ellipse(fx + 3, fy - 2, 4.5, 5, PK["t"])    # insulation
    c.ellipse(fx + 3, fy - 2, 3, 3.3, PK["n"])    # copper sheath
    c.ellipse(fx + 3, fy - 2, 1.5, 1.6, PK["c"])  # the fibre core
    for k, a in enumerate((-60, -20, 15, 50, 85)):  # loose wires, splayed
        r0 = 6.5
        x0, y0 = fx + 3 + math.cos(math.radians(a)) * r0, fy - 2 + math.sin(math.radians(a)) * r0
        x1, y1 = x0 + math.cos(math.radians(a - 20)) * 6, y0 + math.sin(math.radians(a - 20)) * 6
        x1, y1 = min(x1, 29), max(y1, 1)
        c.line(x0, y0, x1, y1, PK["y"])
        c.set(x1, y1, PK["c"] if k % 2 else PK["y"])
    for x, y in ((4, 40), (8, 34), (6, 44)):
        c.set(x, y, PK["g"])
    salt_base(c, 2, 18)
    c.outline(PK["o"])
    return c


PROPS = [prop_rib, lambda: prop_rib(True), prop_bow, prop_anchor, prop_periscope, prop_container,
         prop_buoy, prop_cable_end]
PROP = {n: i for i, n in enumerate(["rib_l", "rib_r", "bow", "anchor", "periscope", "container", "buoy", "cable_end"])}
MOVER_CELL = PROP["container"]


def draw_props():
    return [fn() for fn in PROPS]


# ------------------------------------------------------------ the arena
import pack_arena as PA  # noqa: E402


class DrainArena(PA.PackArena):
    """The Drain (SPEC 19.9): the plughole the ocean went down. A huge
    funnel bowl, drawn as rings of floor going from the rim's salt through
    grey sand to the dark silt round the pit at its heart (the drain, with
    four hatch-cover kickers over it); four islands of wreckage at the
    diagonals with whale ribs standing on their corners, so every way into
    the bowl is a rib-arch gate; a listing trawler lies across each side
    lane, its deck a gap jump over the scour pit it dug; containers slide
    off the stacks down the north lane and across the SW corner. 18 nav
    nodes (the Food Court's graph)."""
    name, stem, background = "THE DRAIN", "the_drain", "drain"

    def __init__(self):
        n = PA.ARENA
        k = np.full((n, n), PA.FLOOR, np.uint8)
        for x0 in (14, 60):            # the trawlers' wreckage islands
            for y0 in (14, 60):
                k[y0:y0 + 14, x0:x0 + 14] = PA.SOLID
        for y in range(n):             # the drain
            for x in range(n):
                if math.hypot(x - 43.5, y - 43.5) <= 8.6:
                    k[y, x] = PA.PIT
        # The trawlers across the side lanes: their decks ramp over the
        # scour pits (rows 41..45) they dug when they settled.
        self.ramps = []
        for x0, x1 in ((0, 13), (74, 87)):
            k[41:46, x0:x1 + 1] = PA.PIT
            self.ramps.append((x0, 39, x1, 40, 1))
            self.ramps.append((x0, 46, x1, 47, 3))
        self.kind = k
        self.kickers = [(41, 34, 46, 35, 1), (41, 52, 46, 53, 3), (34, 41, 35, 46, 0), (52, 41, 53, 46, 2)]
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
        # A second container slides across the SW corner, wall to wall.
        self.mover = dict(a=(-3, 63), b=(25, 91), period=900, warn=60, phase=600, damage=50, push=64,
                          size=16, speed=40)
        w = PA.rel_world
        # Ribs on the islands' corners that face the bowl's gates (a left
        # and a right rib either side of each gate), the trawlers' gear and
        # the drain's junk round the rim.
        self.props = [("rib_r", *w(25, 18)), ("rib_l", *w(62, 18)), ("rib_r", *w(25, 69)), ("rib_l", *w(62, 69)),
                      ("rib_l", *w(18, 25)), ("rib_r", *w(18, 62)), ("rib_r", *w(69, 25)), ("rib_l", *w(69, 62)),
                      ("anchor", *w(20, 20)), ("buoy", *w(67, 67)), ("periscope", *w(67, 20)), ("cable_end", *w(20, 67)),
                      ("bow", *w(-4, 43)), ("bow", *w(91, 44)), ("container", *w(30, -4)), ("container", *w(58, -4)),
                      ("buoy", *w(43, 92))]

    def floor(self, tmap, big, rng):
        """The funnel: salt on the rim, grey sand on the slope, silt in the
        throat round the drain; flow streaks of cable ruts toward it."""
        O = PA.O
        road = (SURF, SURF_SEAM_V, SURF_SEAM_H, SURF_SEAM_X, SURF_DOT, RUT, RUT + 1)
        for ty in range(128):
            for tx in range(128):
                v = tmap[ty, tx]
                if v not in road:
                    continue
                r = math.hypot(tx - O - 43.5, ty - O - 43.5)
                wob = 1.2 * math.sin(math.atan2(ty - O - 43.5, tx - O - 43.5) * 5 + r * 0.2)
                if r + wob < 17:
                    tmap[ty, tx] = ROAD_VARIANTS["silt"][v]
                elif r + wob > 34:
                    tmap[ty, tx] = ROAD_VARIANTS["salt"][v]
        (ax, ay), (bx, by) = self.mover["a"], self.mover["b"]
        for i in range(200):           # the second slide's drag marks
            t = i / 199
            x, y = ax + (bx - ax) * t, ay + (by - ay) * t
            for d in (-1, 0, 1):
                tx, ty = O + int(round(x)) + d, O + int(round(y))
                if 0 <= tx < 128 and 0 <= ty < 128 and tmap[ty, tx] in road + tuple(ROAD_VARIANTS["salt"].values()):
                    tmap[ty, tx] = SWEEP_LANE

    def post(self, tmap):
        """The islands: a trawler's hull plating and deck on each; the
        second slide's hazard-striped gaps where its route meets the rim."""
        O = PA.O
        (ax, ay), (bx, by) = self.mover["a"], self.mover["b"]
        for i in range(300):
            t = i / 299
            tx, ty = O + int(round(ax + (bx - ax) * t)), O + int(round(ay + (by - ay) * t))
            for yy, xx in ((ty, tx), (ty, tx + 1), (ty + 1, tx)):
                if 48 <= tmap[yy, xx] < 64 or 96 <= tmap[yy, xx] < 100:
                    tmap[yy, xx] = SWEEP_GATE
        for x0 in (14, 60):
            for y0 in (14, 60):
                for ty in range(O + y0, O + y0 + 14):
                    for tx in range(O + x0, O + x0 + 14):
                        if 1 <= tmap[ty, tx] <= 15:
                            u = (tx - O - x0) + (ty - O - y0)
                            tmap[ty, tx] = SB_DECK if 11 <= u <= 14 else (SB_HULL_SEAM if u % 4 == 0 else SB_HULL)


ARENA = DrainArena
