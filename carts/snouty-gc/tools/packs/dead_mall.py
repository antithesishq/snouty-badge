"""Dead Mall (SPEC 19.7): a two-storey megamall turned datacenter, then
abandoned as both. Indoors, at night: pastel terrazzo (teal, salmon,
cream) with brass inlay, half-lit magenta and cyan neon, green exit signs,
blue and amber rack LEDs, a dim purple night sky through the skylight
dome. No brown anywhere.

The league in the shared tile layout (tools/leagues.py) plus the pack's
slots (packs/common.py): per-track road floors (carpet, food-court tile,
parking deck), the ceiling-tile crust, and the props sheet.
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

NAME = "dead_mall"
TITLE = "DEAD MALL"
FILE = "DEADMALL"

PAL = Palette([
    ("fog", (66, 52, 92)),
    # road: teal terrazzo, cream and salmon chips, brass inlay
    ("floor", (148, 196, 186)), ("floor_seam", (214, 184, 92)), ("lane_dot", (248, 224, 140)),
    ("chip_c", (180, 218, 208)), ("chip_s", (204, 172, 166)), ("chip_d", (126, 176, 166)),
    ("rut", (122, 168, 160)), ("rut_cable", (80, 206, 226)),
    # off-track: dark terrazzo, grilles, cable trays, racks, tables, carpet, deck
    ("dk_floor", (82, 92, 116)), ("dk_chip", (98, 110, 134)), ("dk_chip2", (90, 84, 120)),
    ("grille_f", (70, 74, 100)), ("grille_f_dk", (40, 42, 62)),
    ("tray", (132, 138, 160)), ("tray_dk", (76, 80, 104)),
    ("cable_c", (70, 200, 220)), ("cable_m", (222, 82, 182)), ("cable_y", (232, 206, 84)),
    ("rack", (38, 40, 62)), ("rack_hi", (86, 90, 120)), ("led_b", (84, 152, 255)), ("led_a", (255, 178, 44)),
    ("table", (236, 226, 206)), ("table_sh", (178, 170, 176)), ("chair_s", (232, 138, 128)), ("chair_t", (98, 194, 184)),
    ("carpet", (76, 50, 94)), ("carpet_hi", (96, 64, 114)), ("carpet_dk", (60, 40, 76)),
    ("deck", (94, 98, 116)), ("deck_hi", (108, 112, 130)), ("deck_dk", (74, 76, 94)),
    ("deck_line", (226, 226, 222)), ("deck_yel", (240, 204, 72)), ("oil", (60, 62, 80)),
    # road variants: department-store carpet, food-court tile
    ("rcarpet", (150, 108, 156)), ("rcarpet_m", (188, 142, 186)), ("rcarpet_w", (132, 92, 140)),
    ("food_a", (226, 216, 198)), ("food_b", (220, 172, 160)), ("food_grout", (196, 186, 176)),
    ("stain", (190, 150, 168)),
    # walls: chrome rail, neon strip, roll-down grille
    ("rail_hi", (236, 236, 246)), ("rail", (166, 172, 196)), ("neon_m", (250, 92, 212)), ("neon_c", (96, 232, 252)),
    ("grille", (88, 92, 122)), ("grille_dk", (52, 54, 80)), ("wall_base", (36, 34, 56)),
    ("wall_a", (240, 202, 64)), ("wall_b", (30, 28, 46)),
    ("scrap", (88, 92, 122)), ("scrap_hi", (130, 136, 164)), ("scrap_rust", (110, 70, 130)), ("scrap_dk", (52, 54, 80)),
    # mezzanine edge (glass balustrade) over the dark lower floor
    ("lip", (190, 232, 244)), ("lip_dk", (104, 150, 182)),
    ("void", (22, 18, 38)), ("void_mid", (56, 42, 88)),
    # features
    ("cool", (176, 220, 240)), ("cool_hi", (244, 252, 255)), ("cool_rim", (124, 182, 212)),
    ("bay_floor", (36, 48, 84)), ("bay_stripe", (255, 176, 40)), ("bay_hi", (250, 240, 200)),
    ("vent_rim", (122, 126, 150)), ("vent_dk", (28, 28, 48)), ("vent_glow", (150, 232, 255)),
    ("ramp", (140, 146, 170)), ("ramp_hi", (196, 202, 222)), ("ramp_arrow", (250, 214, 72)),
    ("step_dk", (88, 92, 116)), ("handrail", (26, 24, 40)),
    ("chk_w", (240, 236, 232)), ("chk_k", (28, 26, 42)),
    ("seam_lit", (140, 104, 196)), ("seam_glow", (130, 240, 255)),
    # crust: the ceiling tiles of the level below
    ("ceil", (210, 212, 226)), ("ceil_dk", (172, 174, 192)), ("ceil_grid", (132, 134, 154)), ("crack", (58, 52, 80)),
    # planters (arena islands)
    ("leaf", (72, 182, 122)), ("leaf_dk", (34, 116, 88)), ("pot", (222, 142, 132)),
])

# Background tiles (1..15, attribute off).
DM_DARK, DM_GRILLE, DM_TRAY_X, DM_TRAY_Y = 1, 2, 3, 4
DM_RACK = 5         # 5..8 2x2 rack row top-down TL TR BL BR
DM_TABLE = 9        # 9..12 2x2 food-court table with chairs
DM_CARPET, DM_DECK_LINE, DM_DECK = 13, 14, 15
# Road variants (attribute surface) in the pack slots.
CARPET, CARPET_MOTIF, CARPET_WORN = 28, 29, 30
FOOD_A, FOOD_B, FOOD_STAIN = 31, 89, 90
DECK, DECK_JOINT, DECK_DASH, DECK_DASH_Y, DECK_OIL = 91, 124, 125, 126, 127

SHADOW_TILES, STRIPE_TILES = {}, (DECK_DASH, DECK_DASH_Y)
# Centerline dashes per floor (the generator's `centerline yes`).
CENTER_LINES = {"deck": (DECK_DASH, DECK_DASH_Y)}
ROAD_VARIANTS = {
    "terrazzo": {},
    "carpet": {SURF: CARPET, SURF_SEAM_V: CARPET, SURF_SEAM_H: CARPET, SURF_SEAM_X: CARPET_MOTIF,
               SURF_DOT: CARPET_MOTIF, RUT: CARPET_WORN, RUT + 1: CARPET_WORN},
    "food": {SURF: FOOD_A, SURF_SEAM_X: FOOD_A, SURF_SEAM_V: FOOD_B, SURF_SEAM_H: FOOD_B,
             SURF_DOT: FOOD_A, RUT: FOOD_STAIN, RUT + 1: FOOD_STAIN},
    "deck": {SURF: DECK, SURF_SEAM_V: DECK, SURF_SEAM_H: DECK, SURF_SEAM_X: DECK_JOINT,
             SURF_DOT: DECK, RUT: DECK_OIL, RUT + 1: DECK_OIL},
}


def terrazzo(P, base, chips, x, y, salt, density=0.16):
    """Chips at 1 px, sparse and low contrast so the floor stays calm at speed."""
    h = hash01(x, y, salt)
    if h < density:
        return P[chips[int(hash01(x, y, salt + 1) * len(chips)) % len(chips)]]
    return P[base]


def paint_tiles(P):
    ts = Tileset(P)
    # --- background (off-track) ---
    ts.put(DM_DARK, "dark terrazzo", A_OFF, grid(lambda x, y: terrazzo(P, "dk_floor", ("dk_chip", "dk_chip2"), x, y, 3, 0.12)))
    ts.put(DM_GRILLE, "floor grille", A_OFF, grid(
        lambda x, y: P["grille_f_dk"] if (0 < x < 7 and 0 < y < 7 and y % 2 == 1) else P["grille_f"]))

    def tray(x, y):   # cable tray along x: rails, a bundle of cables
        if y in (1, 6):
            return P["tray"]
        if y in (0, 7):
            return P["tray_dk"]
        return P[("cable_c", "cable_m", "cable_y", "cable_c")[y - 2]] if (x + y) % 5 else P["tray_dk"]
    t = grid(tray)
    ts.put(DM_TRAY_X, "cable tray (x)", A_OFF, t)
    ts.put(DM_TRAY_Y, "cable tray (y)", A_OFF, t.T.copy())
    rack = np.zeros((16, 16), np.uint8)
    for y in range(16):
        for x in range(16):
            v = P["dk_floor"]
            if 1 <= x <= 14 and 1 <= y <= 13:
                v = P["rack"]
                if y in (1, 13) or x in (1, 14):
                    v = P["rack_hi"]
                elif x % 3 == 0 and 3 <= y <= 11:
                    v = P["led_b"] if hash01(x, y, 5) < 0.5 else (P["led_a"] if hash01(x, y, 6) < 0.3 else P["rack"])
            elif y == 14 and 2 <= x <= 15:
                v = P["grille_f_dk"]
            rack[y, x] = v
    for k, (oy, ox) in enumerate(((0, 0), (0, 8), (8, 0), (8, 8))):
        ts.put(DM_RACK + k, f"server rack {'TL TR BL BR'.split()[k]}", A_OFF, rack[oy:oy + 8, ox:ox + 8])
    table = np.zeros((16, 16), np.uint8)
    for y in range(16):
        for x in range(16):
            v = terrazzo(P, "dk_floor", ("dk_chip",), x, y, 9, 0.1)
            r = math.hypot(x - 7.5, y - 7.5)
            for cx, cy, col in ((7.5, 1.5, "chair_s"), (7.5, 13.5, "chair_t"), (1.5, 7.5, "chair_t"), (13.5, 7.5, "chair_s")):
                if abs(x - cx) <= 1.6 and abs(y - cy) <= 1.6:
                    v = P[col]
            if r <= 4.6:
                v = P["table"] if r <= 3.8 else P["table_sh"]
            table[y, x] = v
    for k, (oy, ox) in enumerate(((0, 0), (0, 8), (8, 0), (8, 8))):
        ts.put(DM_TABLE + k, f"food-court table {'TL TR BL BR'.split()[k]}", A_OFF, table[oy:oy + 8, ox:ox + 8])
    ts.put(DM_CARPET, "store carpet", A_OFF, grid(
        lambda x, y: P["carpet_hi"] if (x + y) % 8 == 0 or (x - y) % 8 == 4 else P["carpet"]))
    ts.put(DM_DECK_LINE, "deck with bay line", A_OFF, grid(
        lambda x, y: P["deck_line"] if x == 3 else (P["deck_dk"] if hash01(x, y, 14) < 0.1 else P["deck"])))
    ts.put(DM_DECK, "deck", A_OFF, grid(lambda x, y: P["deck_dk"] if hash01(x, y, 15) < 0.1 else P["deck"]))

    # --- road: terrazzo with brass inlay every 16 px ---
    tz = lambda x, y, s: terrazzo(P, "floor", ("chip_c", "chip_s", "chip_d"), x, y, s)  # noqa: E731
    ts.put(SURF, "terrazzo", A_SURF, grid(lambda x, y: tz(x, y, 21)))
    ts.put(SURF_DOT, "terrazzo brass medallion", A_SURF, grid(
        lambda x, y: P["lane_dot"] if abs(x - 3.5) + abs(y - 3.5) <= 2 else (
            P["floor_seam"] if abs(x - 3.5) + abs(y - 3.5) <= 3 else tz(x, y, 22))))
    ts.put(SURF_SEAM_V, "terrazzo brass inlay left", A_SURF, grid(lambda x, y: P["floor_seam"] if x == 0 else tz(x, y, 23)))
    ts.put(SURF_SEAM_H, "terrazzo brass inlay top", A_SURF, grid(lambda x, y: P["floor_seam"] if y == 0 else tz(x, y, 24)))
    ts.put(SURF_SEAM_X, "terrazzo brass inlay corner", A_SURF, grid(
        lambda x, y: P["floor_seam"] if x == 0 or y == 0 else tz(x, y, 25)))

    L.paint_track_pieces(ts, P)
    L.paint_arena_pieces(ts, P)

    # --- re-skins over the shared pieces ---
    # Ruts: scuffed tracks where the racks were wheeled in.
    def rut(x, y):
        if y in (2, 5) and hash01(x, y, 26) < 0.7:
            return P["rut"]
        return tz(x, y, 26)
    r = grid(rut)
    reput(ts, RUT, "rack wheel scuffs (travel x)", A_SURF, r)
    reput(ts, RUT + 1, "rack wheel scuffs (travel y)", A_SURF, r.T.copy())

    # Walls: a chrome rail with a neon strip facing the road, a shopfront's
    # roll-down grille behind it.
    def wall_px(d, x, y, mask=0):
        if d == 0:
            return P["rail_hi"]
        if d == 1:
            return P["neon_m"] if ((x + y) >> 2) % 3 else P["rail"]
        if d >= 6:
            return P["wall_base"]
        return P["grille_dk"] if d % 2 == 0 else P["grille"]
    for m in range(16):
        reput(ts, WALL + m, f"shopfront wall mask {m:04b}", A_WALL,
              grid(lambda x, y: wall_px(side_dist(m, x, y), x, y) if m else P["wall_base"]))
    for c in range(4):
        reput(ts, WALL_DIAG + c, f"shopfront corner {'NE SE SW NW'.split()[c]}", A_WALL,
              grid(lambda x, y: wall_px(diag_dist(c, x, y), x, y)))

    # Escalators: ramps, jumps and kickers are stalled escalator steps
    # (grooved treads across the travel, a black handrail each side, a
    # yellow step nose; the kicker's long run has two brass chevrons).
    def esc(x, y, kind):
        if y in (0, 7):
            return P["handrail"] if x % 4 else P["rail"]
        if kind == "kicker" and 1 <= x <= 6 and (abs(y - 3.5) + x) % 4 < 1.2:
            return P["ramp_arrow"]
        if kind == "jump" and 2 <= x <= 6 and abs(abs(y - 3.5) - (6 - x)) < 0.8:
            return P["ramp_arrow"]
        if x % 4 == 3:
            return P["wall_a"]          # the step nose
        return P["ramp_hi"] if x % 2 == 0 else P["step_dk"]
    for k in range(4):
        reput(ts, RAMP + k, f"stalled escalator {'ESWN'[k]}", A_RAMP, rot(grid(lambda x, y: esc(x, y, "ramp")), k))
        reput(ts, KICKER + k, f"escalator kicker {'ESWN'[k]}", A_KICKER, rot(grid(lambda x, y: esc(x, y, "kicker")), k))
        reput(ts, JUMP + k, f"escalator jump {'ESWN'[k]}", A_JUMP, rot(grid(lambda x, y: esc(x, y, "jump")), k))

    # Wet floor (slick): a pale sheen with streaks on the terrazzo.
    def wet(x, y):
        rr = math.hypot(x - 3.5, (y - 3.5) * 1.3) + 0.5 * math.sin(x * 1.3 + y * 0.7)
        if rr > 4.6:
            return tz(x, y, 27)
        if rr > 3.8:
            return P["cool_rim"]
        return P["cool_hi"] if (x - y) in (0, 1) and 1 <= x <= 5 else P["cool"]
    reput(ts, COOLANT, "wet floor", A_COOLANT, grid(wet))

    # Sparking panel (timed blast lane): a floor plate with blue-white arcs.
    def panel(x, y):
        if y in (0, 7):
            return P["vent_rim"]
        if abs(y - 3.5 - 2 * math.sin(x * 1.4)) < 0.6:
            return P["vent_glow"]
        return P["vent_dk"]
    p = grid(panel)
    reput(ts, VENT_LANE, "sparking panel lane (travel x)", A_VENT, p)
    reput(ts, VENT_LANE + 1, "sparking panel lane (travel y)", A_VENT, p.T.copy())

    def breaker(x, y):
        if x in (0, 7) or y in (0, 7):
            return P["vent_rim"]
        if y == 2 and 2 <= x <= 5:
            return P["led_a"]
        return P["vent_glow"] if (x in (2, 5) and 3 <= y <= 5) else P["vent_dk"]
    b = grid(breaker)
    reput(ts, VENT_MOUTH, "overloaded breaker (travel x)", A_WALL, b)
    reput(ts, VENT_MOUTH + 1, "overloaded breaker (travel y)", A_WALL, b.T.copy())
    # The scrubber's route: a polished streak, wet chevrons.
    sw = grid(lambda x, y: P["cool"] if (x + y) & 7 in (0, 1) else (P["chip_c"] if x in (2, 5) else tz(x, y, 28)))
    reput(ts, SWEEP_LANE, "scrubber route (travel x)", A_SURF, sw)
    reput(ts, SWEEP_LANE + 1, "scrubber route (travel y)", A_SURF, sw.T.copy())
    door = grid(lambda x, y: P["wall_a"] if (x in (0, 7) and y % 2) else (P["rail"] if y % 2 else P["grille"]))
    reput(ts, SWEEP_GATE, "service door (travel x)", A_WALL, door)
    reput(ts, SWEEP_GATE + 1, "service door (travel y)", A_WALL, door.T.copy())

    # --- pack slots ---
    # Crust: the floor here is the ceiling tiles of the level below.
    def ceil(x, y, cracked):
        if x == 0 or y == 0:
            return P["ceil_grid"]
        if cracked and (abs(x - y - 0.5) < 0.6 or (x == 5 and y >= 4)):
            return P["crack"]
        return P["ceil_dk"] if hash01(x, y, 31) < 0.18 else P["ceil"]
    ts.put(CRUST, "ceiling tile (crust)", A_CRUST, grid(lambda x, y: ceil(x, y, False)))
    ts.put(CRUST_CRACK, "ceiling tile cracking", A_CRUST, grid(lambda x, y: ceil(x, y, True)))
    ts.put(CRUST_HOLE, "ceiling tile fallen through", A_CRUST, grid(
        lambda x, y: P["ceil_grid"] if (x == 0 or y == 0) else (P["void_mid"] if hash01(x, y, 33) < 0.1 else P["void"])))
    # Road variants.
    ts.put(CARPET, "store carpet road", A_SURF, grid(lambda x, y: P["rcarpet"]))
    ts.put(CARPET_MOTIF, "store carpet motif", A_SURF, grid(
        lambda x, y: P["rcarpet_m"] if abs(x - 3.5) + abs(y - 3.5) in (2.0, 3.0) else P["rcarpet"]))
    ts.put(CARPET_WORN, "store carpet worn", A_SURF, grid(
        lambda x, y: P["rcarpet_w"] if 2 <= y <= 5 and hash01(x, y, 34) < 0.6 else P["rcarpet"]))
    ts.put(FOOD_A, "food-court tile cream", A_SURF, grid(lambda x, y: P["food_grout"] if x == 0 or y == 0 else P["food_a"]))
    ts.put(FOOD_B, "food-court tile salmon", A_SURF, grid(lambda x, y: P["food_grout"] if x == 0 or y == 0 else P["food_b"]))
    ts.put(FOOD_STAIN, "food-court tile soda stain", A_SURF, grid(
        lambda x, y: P["food_grout"] if x == 0 or y == 0 else (
            P["stain"] if math.hypot(x - 4, y - 4) < 2.4 + 0.6 * math.sin(x + 2 * y) else P["food_a"])))
    dk = lambda x, y, s: P["deck_dk"] if hash01(x, y, s) < 0.08 else P["deck_hi"]  # noqa: E731
    ts.put(DECK, "parking deck", A_SURF, grid(lambda x, y: dk(x, y, 41)))
    ts.put(DECK_JOINT, "parking deck slab joint", A_SURF, grid(
        lambda x, y: P["deck_dk"] if (x == 0 or y == 0) else dk(x, y, 42)))
    dash = grid(lambda x, y: P["deck_yel"] if 3 <= y <= 4 else dk(x, y, 43))
    ts.put(DECK_DASH, "parking deck lane dash (travel x)", A_SURF, dash)
    ts.put(DECK_DASH_Y, "parking deck lane dash (travel y)", A_SURF, dash.T.copy())
    ts.put(DECK_OIL, "parking deck oil stain", A_SURF, grid(
        lambda x, y: P["oil"] if math.hypot(x - 3.5, y - 4) < 2.6 + 0.7 * math.sin(x * 1.7) else dk(x, y, 45)))
    for i in range(NTILES):
        if ts.names[i] is None:
            ts.tiles[i] = ts.tiles[1]
    return ts


# ------------------------------------------------------------ background
def block_food(block, rng):
    n = block.shape[0]
    block[:] = DM_DARK
    avail = np.ones_like(block, bool)
    for _ in range(14):
        for _try in range(100):
            x, y = rng.randrange(n - 2), rng.randrange(n - 2)
            if avail[max(0, y - 1):y + 3, max(0, x - 1):x + 3].all():
                block[y:y + 2, x:x + 2] = np.array([[DM_TABLE, DM_TABLE + 1], [DM_TABLE + 2, DM_TABLE + 3]])
                avail[max(0, y - 1):y + 3, max(0, x - 1):x + 3] = False
                break
    for ty in range(n):
        for tx in range(n):
            if avail[ty, tx] and rng.random() < 0.04:
                block[ty, tx] = DM_GRILLE


def block_racks(block, rng, base=DM_DARK):
    """Rows of racks rolled into the shopfronts, cable trays between."""
    n = block.shape[0]
    block[:] = base
    for y in range(0, n, 6):
        x = rng.randrange(3)
        while x + 2 <= n:
            if rng.random() < 0.8:
                block[y:y + 2, x:x + 2] = np.array([[DM_RACK, DM_RACK + 1], [DM_RACK + 2, DM_RACK + 3]])
            x += 2
        if y + 3 < n:
            block[y + 3, :] = DM_TRAY_X
    for ty in range(n):
        for tx in range(n):
            if block[ty, tx] == base and rng.random() < 0.03:
                block[ty, tx] = DM_GRILLE


def block_store(block, rng):
    """The anchor store: carpet with rack rows (the racks the AIs left)."""
    block_racks(block, rng, DM_CARPET)
    for ty in range(block.shape[0]):
        if ty % 12 == 9:
            block[ty, :] = np.where(block[ty, :] == DM_TRAY_X, DM_CARPET, block[ty, :])


def block_deck(block, rng):
    """The roof deck: parking bays (a white line every 3 tiles)."""
    n = block.shape[0]
    for ty in range(n):
        for tx in range(n):
            block[ty, tx] = DM_DECK_LINE if tx % 3 == 0 and (ty // 6) % 2 == 0 else DM_DECK


def background(kind):
    blocks = {"food": block_food, "racks": block_racks, "store": block_store, "deck": block_deck}

    def paint(tmap, free, rng):
        L.wallpaper(tmap, free, rng, blocks[kind], (DM_RACK, DM_TABLE), DM_CARPET if kind == "store" else (
            DM_DECK if kind == "deck" else DM_DARK))
    return paint


# ------------------------------------------------------------ horizon
def paint_horizon(fog, rng):
    """Front 512x32: the atrium's two floors of shopfronts behind balconies,
    pillars, half-lit neon, exit signs, rack LEDs behind the grilles, and the
    giant dead pretzel sign. Back 256x32: the skylight dome's ribs and panes
    over a dim purple night sky."""
    fpal = [fog, fog, (84, 70, 112), (128, 116, 162), (92, 82, 128), (150, 188, 214), (34, 30, 56),
            (72, 70, 104), (244, 92, 212), (96, 232, 252), (70, 236, 130), (176, 140, 172),
            (166, 158, 200), (84, 150, 255), (44, 40, 70), (255, 180, 52)]
    # 0 transparent, 1 fog, 2 haze, 3 slab lit, 4 slab shade, 5 rail glass, 6 shop dark,
    # 7 grille, 8 neon magenta, 9 neon cyan, 10 exit green, 11 dead tube, 12 pillar,
    # 13 rack LED blue, 14 LED off (blink), 15 LED amber on
    W, H = 512, 32
    f = np.zeros((H, W), np.uint8)
    ground = 29
    up0, slab0, slab1 = 9, 18, 19        # upper floor shops from up0, the balcony slab rows
    # Shop rows: dark interiors with grilles; upper floor and lower floor.
    for x in range(W):
        for y in range(up0, ground + 1):
            f[y, x] = 6
    for y in range(slab0, slab1 + 1):
        f[y, :] = 3 if y == slab0 else 4
    for y in range(slab0 - 4, slab0):    # the upper balcony's glass rail
        for x in range(W):
            if y == slab0 - 4:
                f[y, x] = 12
            elif x % 6 == 0:
                f[y, x] = 12
            elif bayer4(x, y) < 0.35:
                f[y, x] = 5
    # Pillars every 64 px (both floors), with a soffit.
    for k in range(8):
        px = k * 64 + 2
        for y in range(up0, ground + 1):
            for x in range(px, px + 5):
                f[y, x % W] = 12 if x - px < 3 else 4
    # Shopfronts between the pillars: a sign band, a grille, racks behind.
    signs = ["SALE", "PRETZ", "SHOES", "RADIO", "TOYS", "GAMES", "LOTS", "CANDY",
             "MUSIC", "TEA", "LUXE", "TECH", "FOOD", "OPEN", "HAIR", "BOOKS"]
    from art.raster import F3
    for k in range(8):
        for floor, (sy, gy0, gy1) in enumerate(((up0 + 1, up0 + 6, slab0 - 1), (slab1 + 1, slab1 + 7, ground))):
            x0 = k * 64 + 8
            x1 = x0 + 54
            # rack LEDs behind the grille
            for y in range(gy0, gy1 + 1):
                for x in range(x0, x1):
                    if (x - x0) % 7 in (2, 3) and y % 2 == 0 and rng.random() < 0.55:
                        f[y, x % W] = 15 if rng.random() < 0.3 else 13
                    elif y % 2 == 1 and rng.random() < 0.08:
                        f[y, x % W] = 7
            # roll-down grille over part of the front
            gw = rng.randint(10, 40)
            gx = x0 + rng.randint(0, x1 - x0 - gw)
            for y in range(gy0, gy1 + 1 - rng.randint(0, 4)):
                for x in range(gx, gx + gw):
                    f[y, x % W] = 7 if y % 2 else 4
            # neon sign, half lit: some letters dead
            word = signs[(k * 2 + floor + rng.randint(0, 3)) % len(signs)]
            cx = x0 + (x1 - x0) // 2 - (len(word) * 4 - 1) // 2
            col = 8 if (k + floor) % 2 else 9
            for i, ch in enumerate(word):
                lit = rng.random() < 0.65
                g = F3.get(ch, F3[" "])
                for j, row in enumerate(g):
                    for ii, bit in enumerate(row):
                        if bit == "1":
                            f[sy + j, (cx + i * 4 + ii) % W] = col if lit else 11
            # an EXIT sign now and then
            if rng.random() < 0.4:
                ex = x0 + rng.randint(2, 48)
                ey = gy0 - 1 if floor else slab1 + 1
                for x in range(ex, ex + 5):
                    for y in range(ey, ey + 2):
                        f[y, x % W] = 10
    # The giant dead pretzel sign hanging in the atrium (one loop still lit),
    # on a dark backing so it reads in front of the upper floor.
    pcx, pcy = 300, 8
    shape = np.zeros((H, W), bool)
    lit = np.zeros((H, W), bool)
    for y in range(0, slab0):
        for x in range(pcx - 18, pcx + 19):
            dx, dy = x - pcx, y - pcy
            outer = abs(math.hypot(dx / 15.0, dy / 7.0) - 1) < 0.09 and dy > -4
            lobe_l = abs(math.hypot(dx + 6, dy + 1) - 4.5) < 0.75
            lobe_r = abs(math.hypot(dx - 6, dy + 1) - 4.5) < 0.75
            cross = (abs(dy - 3 - 0.9 * dx) < 0.8 or abs(dy - 3 + 0.9 * dx) < 0.8) and abs(dx) <= 5 and dy >= 0
            if outer or lobe_l or lobe_r or cross:
                shape[y, x % W] = True
                lit[y, x % W] = lobe_r and dy < 1
    halo = shape.copy()
    halo[1:] |= shape[:-1]; halo[:-1] |= shape[1:]; halo[:, 1:] |= shape[:, :-1]; halo[:, :-1] |= shape[:, 1:]
    f[halo & ~shape] = 6
    f[shape] = 11
    f[lit] = 15
    for y in range(0, 2):                   # its hangers
        for x in (pcx - 12, pcx + 12):
            f[y, x] = 12
    # A second, smaller rack-light row fading back above the upper shops.
    for x in range(W):
        if x % 5 == 0 and rng.random() < 0.7:
            f[up0, x] = 13 if rng.random() < 0.6 else 15
    # The floor meets the fog.
    f[ground - 1:ground + 1][f[ground - 1:ground + 1] == 6] = 2
    f[ground + 1:] = 1
    # Above the upper shops: open to the dome (back layer).
    f[:up0] = np.where(f[:up0] == 6, 0, f[:up0])

    bpal = [(28, 20, 50), (34, 24, 58), (40, 28, 66), (46, 32, 74), (54, 38, 82), (60, 44, 88),
            (64, 48, 92), (110, 98, 150), (150, 140, 190), (220, 220, 255), (84, 72, 120),
            (180, 170, 220), (70, 58, 104), (96, 84, 132), fog, fog]
    # 0..6 night sky gradient, 7 rib, 8 rib lit, 9 star, 10 pane frame, 11 moon,
    # 12 pane glint dark, 13 pane glint, 14 fog
    BW = 256
    b = np.zeros((H, BW), np.uint8)
    for y in range(H):
        for x in range(BW):
            b[y, x] = min(6, int(y / 20 * 6 + bayer4(x, y)))
    for _ in range(40):
        b[rng.randrange(0, 18), rng.randrange(BW)] = 9
    mx, my = 200, 6
    for y in range(H):
        for x in range(BW):
            if math.hypot(x - mx, y - my) <= 2.5:
                b[y, x] = 11
    # The dome: a barrel vault of skylights, an arched rib every 64 px with
    # mullions up from it and pane frames across.
    for x in range(BW):
        u = ((x % 64) - 32) / 32.0
        ya = int(round(3 + 7 * u * u))
        for y in range(0, ya):
            if x % 8 == 0:
                b[y, x] = 7
        b[ya, x] = 8
        if ya + 1 < H:
            b[ya + 1, x] = 7
        for y in (2, 5):
            if y < ya and b[y, x] < 7:
                b[y, x] = 10
    for y in range(26, H):
        b[y, :] = 14 if y > 29 else 12
    return f, b, fpal, bpal


LEAGUE = dict(pal=PAL, tiles=paint_tiles, background=background("racks"), horizon=paint_horizon)


# ------------------------------------------------------------ props
PK = {
    "o": hx(0x161222), "k": hx(0x2E2C42), "m": hx(0x626480), "l": hx(0xA4A8C0), "w": hx(0xECECF4),
    "g": hx(0x48B878), "G": hx(0x227054), "s": hx(0xE68C80), "S": hx(0xA45662), "t": hx(0x62C4BA),
    "c": hx(0xE8DEC8), "n": hx(0xFA60D8), "b": hx(0x60E8FC), "a": hx(0xFFB432), "e": hx(0x5096FF),
}
PROP_LABELS = ["palm planter", "mannequin", "kiosk cart", "neon sign", "server rack",
               "vending machine", "shopping cart", "security robot / scrubber"]


def _cell():
    return Canvas(32, 48)


def prop_palm():
    c = _cell()
    # pot: salmon planter box
    c.poly([(9, 38), (23, 38), (21, 47), (11, 47)], PK["s"])
    c.rect(8, 36, 24, 38, PK["c"])
    c.rect(18, 39, 21, 46, PK["S"])
    # trunk
    for y in range(14, 37):
        x = 16 + int(2 * math.sin(y * 0.18))
        c.rect(x - 1, y, x + 1, y, PK["m"] if y % 3 else PK["k"])
    # fronds: arcs out from the crown
    for a, ln in ((-2.6, 13), (-2.0, 14), (-1.3, 11), (-0.5, 14), (0.1, 13), (-1.0, 9), (-2.3, 9)):
        for i in range(ln):
            t = i / ln
            x = 16 + math.cos(a) * i
            y = 14 + math.sin(a) * i * 0.7 + t * t * 7
            c.rect(x - 1, y, x + 1, y + 1, PK["g"] if i % 3 else PK["G"])
            if i > 3 and i % 2 == 0:
                c.set(x, y + 2, PK["G"])
    c.outline(PK["o"])
    return c


def prop_mannequin():
    c = _cell()
    w, l = PK["w"], PK["l"]
    c.rect(15, 44, 16, 46, PK["m"])          # stand pole
    c.rect(11, 46, 20, 47, PK["k"])          # base
    c.ellipse(16, 8, 3.5, 4, w)              # head (featureless)
    c.rect(15, 12, 16, 13, l)                # neck
    c.poly([(11, 14), (21, 14), (20, 26), (12, 26)], w)   # torso
    c.poly([(12, 26), (20, 26), (22, 30), (10, 30)], PK["n"])  # a magenta skirt still on
    c.rect(12, 30, 14, 43, w)                # legs
    c.rect(18, 30, 20, 43, l)
    c.line(11, 15, 7, 25, w)                 # arms: one raised, one down
    c.line(10, 15, 6, 25, w)
    c.line(21, 15, 25, 8, l)
    c.line(22, 15, 26, 8, l)
    c.rect(14, 18, 18, 18, PK["c"])          # price tag
    c.set(18, 19, PK["a"])
    c.outline(PK["o"])
    return c


def prop_kiosk():
    c = _cell()
    # canopy: cream with salmon stripes
    c.poly([(3, 10), (29, 10), (27, 6), (5, 6)], PK["c"])
    for x in range(4, 29, 4):
        c.rect(x, 6, x + 1, 10, PK["s"])
    c.rect(3, 11, 28, 11, PK["S"])
    c.rect(5, 12, 6, 30, PK["l"])            # poles
    c.rect(25, 12, 26, 30, PK["l"])
    # cart body: teal with a counter
    c.rect(3, 30, 28, 42, PK["t"])
    c.rect(3, 29, 28, 30, PK["w"])
    c.rect(5, 33, 26, 39, PK["c"])
    for k, col in enumerate(("n", "b", "a", "e")):
        c.rect(7 + k * 5, 34, 9 + k * 5, 37, PK[col])   # phone cases for sale
    c.rect(3, 41, 28, 42, PK["k"])
    c.ellipse(8, 45, 2.5, 2.5, PK["k"])       # wheels
    c.ellipse(23, 45, 2.5, 2.5, PK["k"])
    c.set(8, 45, PK["m"])
    c.set(23, 45, PK["m"])
    c.outline(PK["o"])
    return c


def prop_neon():
    from art.raster import text3
    c = _cell()
    c.rect(15, 24, 16, 46, PK["m"])          # pole
    c.rect(11, 46, 20, 47, PK["k"])
    c.rect(2, 6, 29, 24, PK["k"])            # board
    c.rect(2, 6, 29, 6, PK["m"])
    c.rect(3, 7, 28, 23, PK["o"])
    text3(c, "OPEN", 8, 9, PK["n"])          # half lit: the N is dead
    for y in range(9, 14):
        for x in range(20, 24):
            if c.get(x, y) == PK["n"]:
                c.set(x, y, PK["S"])
    text3(c, "ATM", 10, 15, PK["b"])
    c.rect(5, 21, 26, 21, PK["b"])
    c.outline(PK["o"])
    return c


def prop_rack():
    c = _cell()
    c.rect(6, 4, 25, 46, PK["k"])
    c.rect(6, 4, 25, 5, PK["m"])
    c.rect(6, 4, 7, 46, PK["m"])
    c.rect(24, 4, 25, 46, PK["o"])
    for y in range(8, 44, 4):                # server units
        c.rect(9, y, 22, y + 2, PK["o"] if y % 8 else PK["k"])
        c.rect(9, y, 22, y, PK["m"])
        for x, col in ((11, "e"), (13, "e"), (15, "a"), (20, "e")):
            if (x * 7 + y) % 5 != 0:
                c.set(x, y + 1, PK[col])
    c.rect(5, 46, 26, 47, PK["o"])
    c.outline(PK["o"])
    return c


def prop_vending():
    c = _cell()
    c.rect(5, 6, 26, 47, PK["s"])
    c.rect(5, 6, 26, 9, PK["S"])
    c.rect(7, 11, 20, 38, PK["o"])           # window
    for y in range(13, 37, 6):               # cans on shelves, lit cyan window
        c.rect(8, y + 4, 19, y + 4, PK["l"])
        for x in range(9, 19, 3):
            c.rect(x, y, x + 1, y + 3, PK[("b", "t", "a", "n")[(x + y) % 4]])
    c.rect(22, 12, 24, 22, PK["k"])          # buttons
    for y in range(13, 22, 2):
        c.set(23, y, PK["a"] if y % 4 == 1 else PK["e"])
    c.rect(8, 41, 19, 44, PK["k"])           # slot
    c.rect(5, 46, 26, 47, PK["S"])
    c.outline(PK["o"])
    return c


def prop_cart():
    c = _cell()
    l, m, w = PK["l"], PK["m"], PK["w"]
    # basket: a wire grid in perspective
    c.poly([(5, 22), (27, 22), (24, 38), (9, 38)], m)
    for x in range(6, 27, 3):
        c.line(x, 22, 9 + (x - 6) * 15 // 21, 38, l)
    for y in range(22, 39, 4):
        c.hline(5 + (y - 22) * 4 // 16, 27 - (y - 22) * 3 // 16, y, w)
    c.line(27, 22, 28, 15, l)                # handle post
    c.rect(25, 13, 29, 15, PK["s"])          # handle
    c.rect(9, 39, 25, 40, l)                 # base frame
    for x in (10, 23):
        c.ellipse(x, 44.5, 2.5, 2.5, PK["k"])
    c.rect(12, 26, 18, 31, PK["b"])          # a dead monitor someone was wheeling out
    c.rect(13, 27, 17, 30, PK["o"])
    c.outline(PK["o"])
    return c


def prop_robot():
    """A maintenance robot slumped by a pillar; the scrubber mover too."""
    c = _cell()
    w, l, m = PK["w"], PK["l"], PK["m"]
    c.ellipse(16, 40, 13, 6, PK["t"])        # the scrubber skirt
    c.ellipse(16, 41, 13, 5, PK["S"], clip=lambda x, y: y >= 41)
    for x in range(5, 28, 3):                # brush bristles
        c.vline(x, 44, 46, PK["a"])
    c.poly([(7, 22), (25, 22), (27, 38), (5, 38)], w)   # body
    c.poly([(19, 22), (25, 22), (27, 38), (21, 38)], l)
    c.ellipse(16, 18, 9, 7, w)               # dome head, tipped
    c.ellipse(19, 18, 6, 6, l, clip=lambda x, y: x > 18)
    c.rect(10, 16, 21, 19, PK["o"])          # visor
    c.rect(12, 17, 15, 18, PK["b"])          # one eye still lit
    c.rect(17, 17, 19, 18, PK["k"])
    c.rect(9, 28, 22, 30, PK["e"])           # SECURITY band
    for x in range(10, 22, 2):
        c.set(x, 29, w)
    c.rect(15, 6, 16, 11, m)                 # antenna, beacon
    c.rect(14, 4, 17, 6, PK["a"])
    c.outline(PK["o"])
    return c


PROPS = [prop_palm, prop_mannequin, prop_kiosk, prop_neon, prop_rack, prop_vending, prop_cart, prop_robot]
# Prop kinds by name, for the track and arena sources.
PROP = {n: i for i, n in enumerate(["palm", "mannequin", "kiosk", "neon", "rack", "vending", "cart", "robot"])}
# Movers (SPEC 19.4 crossing mover) name a props cell for their sprite.
MOVER_CELL = PROP["robot"]


def draw_props():
    return [fn() for fn in PROPS]


# ------------------------------------------------------------ the arena
import pack_arena as PA  # noqa: E402


class FoodCourtArena(PA.PackArena):
    """The Food Court (SPEC 19.9): the first non-brown arena. The pit is the
    dry fountain (the wishing well: coins and dead phones), the stalled
    escalators are its four kickers, kiosk and planter islands sit at the
    diagonals, and the scrubber circles the old carousel corner (NE). Lit by
    neon and rack LEDs under the skylight. More stalled escalators cross the
    side lanes over light wells (gap jumps). 18 nav nodes (a 1.9 KB blob):
    the Sandbox's layout without its fences, one gap jump a side lane."""
    name, stem, background = "THE FOOD COURT", "the_food_court", "food"

    def __init__(self):
        n = PA.ARENA
        k = np.full((n, n), PA.FLOOR, np.uint8)
        for x0 in (14, 60):            # kiosk and planter islands
            for y0 in (14, 60):
                k[y0:y0 + 14, x0:x0 + 14] = PA.SOLID
        for y in range(n):             # the fountain: a round dry basin
            for x in range(n):
                if math.hypot(x - 43.5, y - 43.5) <= 8.6:
                    k[y, x] = PA.PIT
        # Stalled escalators across the side lanes too, over the light wells
        # cut into the floor (gap jumps: rows 41..45).
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
        # The scrubber's round of the carousel corner: diagonally across the
        # NE ring, from a service door in the north rim to one in the east.
        self.mover = dict(a=(63, -3), b=(91, 25), period=840, warn=60, phase=200, damage=40, push=64,
                          size=16, speed=40)
        w = PA.rel_world
        self.props = [("palm", *w(17, 17)), ("kiosk", *w(24, 24)), ("palm", *w(70, 17)), ("neon", *w(63, 24)),
                      ("kiosk", *w(17, 70)), ("palm", *w(24, 63)), ("palm", *w(70, 70)), ("neon", *w(63, 63)),
                      ("neon", *w(44, -4)), ("neon", *w(43, 91)), ("palm", *w(-4, 34)), ("palm", *w(91, 52))]

    def floor(self, tmap, big, rng):
        """Food-court tile in the plaza round the fountain (inside the
        islands' ring), terrazzo on the outer ring; the scrubber's polished
        route across the carousel corner."""
        O = PA.O
        for ty in range(128):
            for tx in range(128):
                x, y = tx - O, ty - O
                if 14 <= x < 74 and 14 <= y < 74 and tmap[ty, tx] in ROAD_VARIANTS["food"]:
                    tmap[ty, tx] = ROAD_VARIANTS["food"][tmap[ty, tx]]
        (ax, ay), (bx, by) = self.mover["a"], self.mover["b"]
        for i in range(200):
            t = i / 199
            x, y = ax + (bx - ax) * t, ay + (by - ay) * t
            for d in (-1, 0, 1):
                tx, ty = O + int(round(x)) + d, O + int(round(y))
                if 0 <= tx < 128 and 0 <= ty < 128 and tmap[ty, tx] in (SURF, SURF_SEAM_V, SURF_SEAM_H, SURF_SEAM_X, SURF_DOT, RUT, RUT + 1):
                    tmap[ty, tx] = SWEEP_LANE

    def post(self, tmap):
        """Service doors where the scrubber's route meets the rim."""
        O = PA.O
        (ax, ay), (bx, by) = self.mover["a"], self.mover["b"]
        for i in range(300):
            t = i / 299
            tx, ty = O + int(round(ax + (bx - ax) * t)), O + int(round(ay + (by - ay) * t))
            for yy, xx in ((ty, tx), (ty, tx + 1), (ty + 1, tx)):
                if 48 <= tmap[yy, xx] < 64 or 96 <= tmap[yy, xx] < 100:
                    tmap[yy, xx] = SWEEP_GATE


ARENA = FoodCourtArena
