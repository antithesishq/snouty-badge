"""Cold Storage (SPEC 19.8): Antarctica. AI compute halls dug into the ice
shelf, seawater intake pipes as wide as tunnels, glaciers calving into
black water, wind farms on the ridges, and a geothermal plant on the
volcano's flank feeding a humming switchyard. Every surface is ice, steel
or black volcanic rock.

The league in the shared tile layout (tools/leagues.py) plus the pack's
slots (packs/common.py): packed snow as the base road, black basalt road
with orange dashes (Erebus Grid), a grated steel walkway (laid as a band
with the `shadow` word), the intake pipe's ribbed floor (build_tracks'
`pipe`), glare ice (the `drift` word at p=100: slick, attribute coolant),
meltwater channels (the coolant band) and the thin sea ice (crust).

Palette: white and pale cyan ice, deep navy water, black basalt, hazard
orange on the pipes and the plant, a green and magenta aurora over a
polar twilight sky. No sand, no pastel, no brown.
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
from art.raster import hx, text3  # noqa: E402

NAME = "cold_storage"
TITLE = "COLD STORAGE"
FILE = "COLDSTOR"

PAL = Palette([
    ("fog", (148, 158, 200)),
    # road: packed snow, tyre ruts, orange marker dots
    ("floor", (230, 236, 246)), ("floor_seam", (204, 214, 234)), ("lane_dot", (244, 132, 44)),
    ("snow_lt", (242, 246, 252)), ("snow_dk", (214, 222, 238)),
    ("rut", (172, 186, 212)), ("rut_cable", (150, 166, 198)),
    # basalt road (Erebus Grid): black rock, ash, orange dashes
    ("rock", (58, 56, 64)), ("rock_lt", (74, 72, 80)), ("rock_seam", (44, 42, 50)), ("ash", (96, 92, 100)),
    ("dash", (246, 132, 40)),
    # grated steel walkway, the intake pipe
    ("grate", (96, 106, 122)), ("grate_dk", (46, 52, 66)), ("grate_hi", (150, 162, 178)), ("grate_or", (232, 116, 34)),
    ("pipe_floor", (84, 94, 112)), ("rib", (236, 118, 36)), ("rib_dk", (146, 66, 26)),
    # glare ice
    ("ice", (150, 212, 238)), ("ice_hi", (228, 250, 255)), ("ice_dk", (104, 174, 214)), ("ice_crack", (72, 132, 188)),
    # off-track: the shelf's snow, the glacier's blue ice, basalt, the halls' steel deck
    ("bg_snow", (184, 198, 228)), ("bg_snow_lt", (210, 222, 244)), ("bg_snow_dk", (156, 174, 214)),
    ("glac", (122, 178, 222)), ("glac_lt", (164, 206, 236)), ("glac_dk", (70, 124, 186)),
    ("crev", (34, 62, 120)), ("crev_dk", (16, 30, 70)),
    ("basalt", (30, 28, 36)), ("basalt_lt", (46, 44, 54)), ("basalt_ash", (70, 66, 76)),
    ("ember", (250, 116, 34)), ("ember_dk", (150, 52, 26)),
    ("deck", (64, 72, 90)), ("deck_lt", (80, 88, 108)), ("deck_dk", (42, 48, 62)),
    ("dome", (176, 190, 214)), ("dome_dk", (122, 138, 170)), ("dome_lit", (255, 196, 112)), ("dome_glow", (255, 236, 186)),
    # barriers: hazard orange and navy stripes, a snowbank behind (the scrap_* roles)
    ("wall_a", (240, 118, 30)), ("wall_b", (26, 32, 52)),
    ("scrap", (196, 210, 234)), ("scrap_hi", (232, 240, 252)), ("scrap_dk", (150, 170, 208)), ("scrap_rust", (122, 150, 200)),
    ("wall_base", (104, 126, 170)),
    # the shelf's edge over the sea, the crevasses
    ("lip", (240, 248, 255)), ("lip_dk", (110, 162, 212)),
    ("void", (12, 22, 52)), ("void_mid", (34, 62, 110)),
    # features
    ("cool", (44, 104, 168)), ("cool_hi", (176, 230, 255)), ("cool_rim", (98, 160, 210)),
    ("bay_floor", (36, 44, 66)), ("bay_stripe", (244, 128, 38)), ("bay_hi", (255, 232, 200)),
    ("vent_rim", (88, 96, 114)), ("vent_dk", (26, 28, 40)), ("vent_glow", (255, 150, 52)),
    ("ramp", (156, 196, 230)), ("ramp_hi", (220, 238, 252)), ("ramp_arrow", (246, 128, 36)),
    ("chk_w", (244, 248, 252)), ("chk_k", (22, 26, 40)),
    ("seam_lit", (110, 200, 250)), ("seam_glow", (210, 252, 255)),
    # crust: thin sea ice, dark and translucent over the water
    ("thin", (92, 146, 196)), ("thin_hi", (170, 214, 242)), ("thin_dk", (56, 98, 152)), ("thin_crack", (244, 250, 255)),
    ("floe", (206, 226, 246)),
])

# Background tiles (1..15, attribute off).
CS_SNOW, CS_SASTRUGI, CS_SNOW_DK = 1, 2, 3          # the shelf's snow
CS_GLAC, CS_CREV, CS_RUBBLE = 4, 5, 6              # the glacier: blue ice, a crevasse, serac rubble
CS_BASALT, CS_ASH, CS_FUMAROLE, CS_SNOWROCK = 7, 8, 9, 10   # the volcano
CS_DECK = 11                                        # the halls' steel deck
CS_DOME = 12                                        # 12..15 2x2 a server hall's dome from above
# Road slots (attribute surface unless said).
ROCK, ROCK_SEAM, ROCK_ASH = 28, 29, 30              # basalt road
GRATE = 31                                          # grated steel walkway (the `shadow` band)
# 89..91: the intake pipe's floor and ribs (build_tracks' `pipe`, leagues.py PIPE / PIPE_RIB)
ICE, ICE_CRACK = 124, 125                           # glare ice: attribute coolant (the `drift` word)
DASH, DASH_Y = 126, 127                             # orange centerline dash on the rock road
DRIFT, DRIFT_HEAVY = ICE, ICE_CRACK

ROAD_VARIANTS = {
    "snow": {},
    "rock": {SURF: ROCK, SURF_SEAM_V: ROCK, SURF_SEAM_H: ROCK, SURF_SEAM_X: ROCK_SEAM,
             SURF_DOT: ROCK, RUT: ROCK_ASH, RUT + 1: ROCK_ASH},
}
# The `shadow` word lays the grated walkway across the road (the halls,
# the switchyard's deck), whatever the floor.
SHADOW_TILES = {"snow": GRATE, "rock": GRATE}
STRIPE_TILES = (DASH, DASH_Y)
CENTER_LINES = {"rock": (DASH, DASH_Y)}


def snow(P, x, y, salt, base="floor", lt="snow_lt", dk="snow_dk"):
    """2x2 grains of low contrast (calm at speed)."""
    h = hash01(x // 2, y // 2, salt)
    return P[dk] if h < 0.12 else (P[lt] if h < 0.24 else P[base])


def paint_tiles(P):
    ts = Tileset(P)
    s = lambda x, y, k: snow(P, x, y, k, "bg_snow", "bg_snow_lt", "bg_snow_dk")  # noqa: E731
    # --- background ---
    ts.put(CS_SNOW, "shelf snow", A_OFF, grid(lambda x, y: s(x, y, 1)))
    ts.put(CS_SASTRUGI, "wind-carved sastrugi", A_OFF, grid(
        lambda x, y: P["bg_snow_lt"] if (2 * x + y) % 8 in (0, 1) else (P["bg_snow_dk"] if (2 * x + y) % 8 == 2 else s(x, y, 2))))
    ts.put(CS_SNOW_DK, "snow in blue shadow", A_OFF, grid(
        lambda x, y: P["bg_snow_dk"] if hash01(x // 2, y // 2, 3) < 0.7 else P["bg_snow"]))
    g = lambda x, y, k: P["glac_dk"] if hash01(x // 2, y // 2, k) < 0.14 else (P["glac_lt"] if hash01(x // 2, y // 2, k + 1) < 0.2 else P["glac"])  # noqa: E731
    ts.put(CS_GLAC, "glacier ice", A_OFF, grid(lambda x, y: g(x, y, 4)))

    def crevasse(x, y):
        c = 3.5 + 1.4 * math.sin(x * 0.8 + 1)
        d = abs(y - c)
        if d < 0.8:
            return P["crev_dk"]
        if d < 1.6:
            return P["crev"]
        if d < 2.2:
            return P["glac_lt"]
        return g(x, y, 5)
    ts.put(CS_CREV, "glacier crevasse", A_OFF, grid(crevasse))

    def rubble(x, y):
        for cx, cy, r in ((2, 2, 1.8), (5.5, 4.5, 2.2), (2, 6, 1.4)):
            dd = math.hypot(x - cx, y - cy)
            if dd < r:
                return P["glac_lt"] if x + y < cx + cy else (P["glac_dk"] if dd > r - 0.8 else P["glac"])
        return g(x, y, 6)
    ts.put(CS_RUBBLE, "serac rubble", A_OFF, grid(rubble))
    b = lambda x, y, k: P["basalt_lt"] if hash01(x // 2, y // 2, k) < 0.18 else P["basalt"]  # noqa: E731
    ts.put(CS_BASALT, "black basalt", A_OFF, grid(lambda x, y: b(x, y, 7)))
    ts.put(CS_ASH, "volcanic ash", A_OFF, grid(
        lambda x, y: P["basalt_ash"] if hash01(x // 2, y // 2, 8) < 0.55 else b(x, y, 8)))

    def fumarole(x, y):
        r = math.hypot(x - 3.5, y - 3.5)
        if r < 1.2:
            return P["ember"]
        if r < 2.2:
            return P["ember_dk"]
        if r < 3.2:
            return P["basalt_ash"]
        return b(x, y, 9)
    ts.put(CS_FUMAROLE, "fumarole", A_OFF, grid(fumarole))
    ts.put(CS_SNOWROCK, "snow on basalt", A_OFF, grid(
        lambda x, y: s(x, y, 10) if math.hypot(x - 3.5, (y - 3.5) * 1.3) + 0.9 * math.sin(x * 1.3 + y) < 3.0 else b(x, y, 10)))
    ts.put(CS_DECK, "steel deck", A_OFF, grid(
        lambda x, y: P["deck_dk"] if x == 0 or y == 0 else (P["deck_lt"] if (x, y) in ((2, 2), (5, 5)) else P["deck"])))
    dome = np.zeros((16, 16), np.uint8)
    for y in range(16):
        for x in range(16):
            r = math.hypot(x - 7.5, y - 7.5)
            v = s(x, y, 11)
            if r < 7.2:
                v = P["dome"] if (x - 7.5) + (y - 7.5) < 1 else P["dome_dk"]
                if abs(r - 4.2) < 0.6:
                    v = P["dome_lit"]          # the lit ring of a hall's skylight
                if r < 1.6:
                    v = P["dome_glow"]
                if r > 6.4:
                    v = P["bg_snow_dk"]
            dome[y, x] = v
    for k, (oy, ox) in enumerate(((0, 0), (0, 8), (8, 0), (8, 8))):
        ts.put(CS_DOME + k, f"server hall dome {'TL TR BL BR'.split()[k]}", A_OFF, dome[oy:oy + 8, ox:ox + 8])

    # --- road: packed snow, seams every 16 px ---
    c = lambda x, y, k: snow(P, x, y, k)  # noqa: E731
    ts.put(SURF, "packed snow", A_SURF, grid(lambda x, y: c(x, y, 21)))
    ts.put(SURF_DOT, "snow, an orange marker", A_SURF, grid(
        lambda x, y: P["lane_dot"] if 3 <= x <= 4 and 3 <= y <= 4 else c(x, y, 22)))
    ts.put(SURF_SEAM_V, "snow seam left", A_SURF, grid(lambda x, y: P["floor_seam"] if x == 0 else c(x, y, 23)))
    ts.put(SURF_SEAM_H, "snow seam top", A_SURF, grid(lambda x, y: P["floor_seam"] if y == 0 else c(x, y, 24)))
    ts.put(SURF_SEAM_X, "snow seam corner", A_SURF, grid(lambda x, y: P["floor_seam"] if x == 0 or y == 0 else c(x, y, 25)))

    L.paint_track_pieces(ts, P)
    L.paint_arena_pieces(ts, P)

    # Ruts: tyre tracks pressed in the snow.
    r = grid(lambda x, y: P["rut"] if y in (1, 6) else (P["rut_cable"] if y in (2, 5) and hash01(x, y, 26) < 0.3 else c(x, y, 26)))
    reput(ts, RUT, "tyre tracks (travel x)", A_SURF, r)
    reput(ts, RUT + 1, "tyre tracks (travel y)", A_SURF, r.T.copy())

    # Barriers: orange and navy hazard stripes facing the road, a snowbank behind.
    def wall_px(d, x, y):
        if d <= 1:
            return P["wall_a"] if ((x >> 1) + (y >> 1)) & 1 else P["wall_b"]
        if d >= 6:
            return P["wall_base"]
        h = hash01(x // 2, y // 2, 27)
        return P["scrap_hi"] if h < 0.2 else P["scrap"] if h < 0.6 else P["scrap_dk"] if h < 0.85 else P["scrap_rust"]
    for m in range(16):
        reput(ts, WALL + m, f"barrier mask {m:04b}", A_WALL,
              grid(lambda x, y: wall_px(side_dist(m, x, y), x, y) if m else P["wall_base"]))
    for cc in range(4):
        reput(ts, WALL_DIAG + cc, f"barrier corner {'NE SE SW NW'.split()[cc]}", A_WALL,
              grid(lambda x, y: wall_px(diag_dist(cc, x, y), x, y)))

    # The shelf's edge: snow, a white rim, the blue ice cliff, the black sea.
    def open_px(d, x, y):
        if d <= 2:
            return c(x, y, 28)
        if d == 3:
            return P["lip"]
        if d == 4:
            return P["lip_dk"]
        return P["void_mid"] if (x * 3 + y * 5) % 11 == 0 else P["void"]
    for m in range(16):
        reput(ts, EDGE_OPEN + m, f"shelf edge mask {m:04b}", A_SURF,
              grid(lambda x, y: open_px(side_dist(m, x, y), x, y) if m else P["lip_dk"]))
    for cc in range(4):
        reput(ts, EDGE_DIAG + cc, f"shelf edge corner {'NE SE SW NW'.split()[cc]}", A_SURF,
              grid(lambda x, y: open_px(diag_dist(cc, x, y), x, y)))

    # Ramps, jumps, kickers: blue ice plates with orange chevrons.
    def plate(x, y, kind):
        if y in (0, 7):
            return P["wall_b"] if x % 2 else P["ramp_arrow"]
        if kind == "kicker" and 1 <= x <= 6 and (abs(y - 3.5) + x) % 4 < 1.2:
            return P["ramp_arrow"]
        if kind != "kicker" and 2 <= x <= 6 and abs(abs(y - 3.5) - (6 - x)) < 0.8:
            return P["ramp_arrow"]
        return P["ramp_hi"] if x % 3 == 0 else P["ramp"]
    for k in range(4):
        reput(ts, RAMP + k, f"ice ramp {'ESWN'[k]}", A_RAMP, rot(grid(lambda x, y: plate(x, y, "ramp")), k))
        reput(ts, KICKER + k, f"ice kicker {'ESWN'[k]}", A_KICKER, rot(grid(lambda x, y: plate(x, y, "kicker")), k))
        reput(ts, JUMP + k, f"ice jump {'ESWN'[k]}", A_JUMP, rot(grid(lambda x, y: plate(x, y, "jump")), k))

    # Meltwater: a channel of open water across the road (attribute coolant).
    def melt(x, y):
        h = hash01(x, y, 29)
        if (x + 2 * y) % 7 == 0 and h < 0.6:
            return P["cool_hi"]
        return P["cool_rim"] if h < 0.18 else P["cool"]
    reput(ts, COOLANT, "meltwater channel", A_COOLANT, grid(melt))
    # A vent's lane: grated steel over the warm outflow; the vent in the wall.
    lane = grid(lambda x, y: P["grate_or"] if y in (0, 7) and x % 4 < 2 else (
        P["vent_rim"] if y in (0, 7) else (P["vent_glow"] if x % 2 == 0 and y in (2, 5) else P["vent_dk"] if x % 2 == 0 else P["grate"])))
    reput(ts, VENT_LANE, "outflow grate (travel x)", A_VENT, lane)
    reput(ts, VENT_LANE + 1, "outflow grate (travel y)", A_VENT, lane.T.copy())

    def mouth(x, y):
        r = math.hypot(x - 3.5, y - 3.5)
        if r > 3.6:
            return P["wall_a"] if (x + y) % 4 < 2 else P["wall_b"]
        if r < 1.3:
            return P["vent_glow"]
        return P["vent_dk"] if (x + y) % 2 else P["vent_rim"]
    m = grid(mouth)
    reput(ts, VENT_MOUTH, "outflow vent (travel x)", A_WALL, m)
    reput(ts, VENT_MOUTH + 1, "outflow vent (travel y)", A_WALL, m.T.copy())
    # The calving ice's path: scraped ice streaks; its gap in the barrier.
    sk = grid(lambda x, y: P["ice_dk"] if x in (1, 6) else (P["ice"] if x in (2, 5) else c(x, y, 30)))
    reput(ts, SWEEP_LANE, "calving scrape (travel x)", A_SURF, sk)
    reput(ts, SWEEP_LANE + 1, "calving scrape (travel y)", A_SURF, sk.T.copy())
    gate = grid(lambda x, y: P["glac_lt"] if ((x + y) >> 1) & 1 else P["glac_dk"])
    reput(ts, SWEEP_GATE, "glacier gap (travel x)", A_WALL, gate)
    reput(ts, SWEEP_GATE + 1, "glacier gap (travel y)", A_WALL, gate.T.copy())
    # The sea beyond an open edge, and in a crevasse: black water, a floe.
    reput(ts, PIT, "the sea", A_OFF, grid(
        lambda x, y: P["floe"] if hash01(x // 4, y // 4, 41) < 0.03 else (P["void_mid"] if hash01(x // 2, y // 2, 42) < 0.1 else P["void"])))

    # --- pack slots ---
    def thin(x, y, cracked):
        if cracked and (abs(x - 1.3 * y + 2) < 0.6 or abs(x + y - 9) < 0.6 or (y == 2 and x > 4)):
            return P["thin_crack"]
        h = hash01(x // 2, y // 2, 61)
        return P["thin_hi"] if h < 0.1 else (P["thin_dk"] if h < 0.32 else P["thin"])
    ts.put(CRUST, "thin sea ice", A_CRUST, grid(lambda x, y: thin(x, y, False)))
    ts.put(CRUST_CRACK, "thin ice cracking", A_CRUST, grid(lambda x, y: thin(x, y, True)))
    ts.put(CRUST_HOLE, "through the ice: the sea", A_CRUST, grid(
        lambda x, y: P["floe"] if (x, y) in ((1, 1), (2, 1), (6, 5)) else (P["void_mid"] if hash01(x // 2, y // 2, 63) < 0.15 else P["void"])))
    rk = lambda x, y, k: P["rock_lt"] if hash01(x // 2, y // 2, k) < 0.16 else P["rock"]  # noqa: E731
    ts.put(ROCK, "basalt road", A_SURF, grid(lambda x, y: rk(x, y, 31)))
    ts.put(ROCK_SEAM, "basalt road joint", A_SURF, grid(lambda x, y: P["rock_seam"] if x == 0 or y == 0 else rk(x, y, 32)))
    ts.put(ROCK_ASH, "ash on the road", A_SURF, grid(lambda x, y: P["ash"] if hash01(x // 2, y // 2, 33) < 0.5 else rk(x, y, 33)))
    ts.put(GRATE, "grated steel walkway", A_SURF, grid(
        lambda x, y: P["grate_dk"] if (x % 4 == 3 or y % 4 == 3) else (P["grate_hi"] if (x, y) in ((0, 0), (4, 4)) else P["grate"])))
    dash = grid(lambda x, y: P["dash"] if 3 <= y <= 4 and 1 <= x <= 6 else rk(x, y, 34))
    ts.put(DASH, "orange road dash (travel x)", A_SURF, dash)
    ts.put(DASH_Y, "orange road dash (travel y)", A_SURF, dash.T.copy())

    def glare(x, y, cracked):
        if (x - y) % 8 in (0, 1) and hash01(x // 3, y // 3, 35) < 0.7:
            return P["ice_hi"]                  # the glare: long diagonal streaks
        if cracked and abs(x + 0.5 * y - 6) < 0.6:
            return P["ice_crack"]
        return P["ice_dk"] if hash01(x // 2, y // 2, 36) < 0.12 else P["ice"]
    ts.put(ICE, "glare ice", A_COOLANT, grid(lambda x, y: glare(x, y, False)))
    ts.put(ICE_CRACK, "glare ice, cracked", A_COOLANT, grid(lambda x, y: glare(x, y, True)))
    for i in range(NTILES):
        if ts.names[i] is None:
            ts.tiles[i] = ts.tiles[1]
    return ts


# ------------------------------------------------------------ backgrounds
def _scatter(block, rng, base_choices):
    n = block.shape[0]
    for ty in range(n):
        for tx in range(n):
            r = rng.random()
            acc = 0.0
            block[ty, tx] = base_choices[-1][0]
            for t, p in base_choices:
                acc += p
                if r < acc:
                    block[ty, tx] = t
                    break
    return np.ones_like(block, bool)


def _place2x2(block, avail, rng, base, count):
    n = block.shape[0]
    for _ in range(count):
        for _try in range(200):
            x, y = rng.randrange(n - 2), rng.randrange(n - 2)
            if avail[max(0, y - 1):y + 3, max(0, x - 1):x + 3].all():
                block[y:y + 2, x:x + 2] = np.array([[base, base + 1], [base + 2, base + 3]])
                avail[max(0, y - 1):y + 3, max(0, x - 1):x + 3] = False
                break


def block_shelf(block, rng):
    """The ice shelf: snow with sastrugi, blue drifts, a few hall domes."""
    avail = _scatter(block, rng, [(CS_SASTRUGI, 0.12), (CS_SNOW_DK, 0.06), (CS_SNOW, 1.0)])
    _place2x2(block, avail, rng, CS_DOME, 3)


def block_glacier(block, rng):
    """The glacier's foot: blue ice, crevasses in short rows, serac rubble."""
    n = block.shape[0]
    _scatter(block, rng, [(CS_RUBBLE, 0.05), (CS_SNOW_DK, 0.06), (CS_SNOW, 0.22), (CS_GLAC, 1.0)])
    for _ in range(9):
        x, y = rng.randrange(n), rng.randrange(n)
        for k in range(rng.randint(2, 5)):
            block[y, (x + k) % n] = CS_CREV


def block_basalt(block, rng):
    """The volcano's flank: black rock, ash, snow patches, a few fumaroles."""
    _scatter(block, rng, [(CS_ASH, 0.12), (CS_SNOWROCK, 0.03), (CS_FUMAROLE, 0.004), (CS_BASALT, 1.0)])


def block_halls(block, rng):
    """The halls' roofs: steel deck with skylight domes in rows."""
    n = block.shape[0]
    block[:] = CS_DECK
    for y in range(1, n - 1, 6):
        for x in range(1, n - 1, 6):
            if rng.random() < 0.7:
                block[y:y + 2, x:x + 2] = np.array([[CS_DOME, CS_DOME + 1], [CS_DOME + 2, CS_DOME + 3]])


def background(kind):
    blocks = {"shelf": (block_shelf, CS_SNOW), "glacier": (block_glacier, CS_GLAC),
              "basalt": (block_basalt, CS_BASALT), "halls": (block_halls, CS_DECK)}
    fn, plain = blocks[kind]

    def paint(tmap, free, rng):
        L.wallpaper(tmap, free, rng, fn, (CS_DOME,), plain)
    return paint


# ------------------------------------------------------------ horizon
def paint_horizon(fog, rng):
    """Front 512x32: the ice cliffs over the open sea, a cluster of server
    domes lit from inside, a wind farm on a snow ridge (red beacons), and
    Erebus with its plume and the plant's orange lights on the flank. Back
    256x32: the polar twilight, stars, and the aurora's green and magenta
    curtains."""
    fpal = [fog, fog, (22, 36, 74), (64, 96, 146), (240, 246, 252), (146, 182, 222), (66, 76, 102),
            (255, 192, 108), (38, 36, 46), (206, 216, 236), (176, 180, 198), (228, 234, 242),
            (132, 144, 168), (242, 120, 36), (96, 30, 34), (255, 62, 52)]
    # 0 transparent, 1 fog, 2 sea, 3 sea glint, 4 ice cliff, 5 cliff shade, 6 dome / hall body,
    # 7 dome light, 8 basalt, 9 volcano snow, 10 plume, 11 turbine white, 12 turbine shade / ridge,
    # 13 hazard orange (the plant), 14 beacon off (blink), 15 beacon on
    W, H = 512, 32
    f = np.zeros((H, W), np.uint8)
    ground = 29
    # The volcano: a broad cone, a snow cap with gullies running down,
    # the crater's glow and its plume leaning east.
    vx, vtop = 300, 5
    for x in range(vx - 90, vx + 91):
        d = abs(x - vx)
        top = vtop + int(d * 0.3 + d * d / 1100)
        g = (x - vx + 5) % 11 - 5                  # snow tongues down the gullies
        cap = vtop + 5 + int(2 * abs(math.sin(x * 0.35))) + max(0, 9 - 3 * abs(g) - d // 8)
        for y in range(max(top, 0), ground + 1):
            f[y, x % W] = 9 if y < cap else 8
    for y in range(0, vtop + 1):
        k = vtop - y
        for x in range(vx - 2 + k // 2, vx + 3 + 2 * k):
            if bayer4(x, y) < 0.8:
                f[y, x % W] = 10
    f[vtop, vx - 1:vx + 2] = 13                     # the crater's glow
    # The geothermal plant on the flank: an orange-lit block and a stack.
    px0 = vx + 34
    for y in range(ground - 7, ground + 1):
        for x in range(px0, px0 + 14):
            f[y, x] = 6 if (x + y) % 5 else 7
    f[ground - 7, px0:px0 + 14] = 13
    for y in range(ground - 13, ground - 7):
        f[y, px0 + 10:px0 + 12] = 12
    f[ground - 14, px0 + 10] = 15
    # A snow ridge west of the volcano with a wind farm on it.
    rx0, rx1 = 120, 212
    for x in range(rx0, rx1):
        t = (x - rx0) / (rx1 - rx0)
        top = ground - 4 - int(5 * math.sin(t * math.pi))
        for y in range(top, ground + 1):
            if f[y, x] == 0:
                f[y, x] = 9 if y < top + 2 else 12
    for x in range(rx0 + 10, rx1 - 6, 16):
        t = (x - rx0) / (rx1 - rx0)
        base = ground - 4 - int(5 * math.sin(t * math.pi))
        hub = base - 13
        for y in range(hub, base):
            f[y, x] = 11
        ang = (x * 37) % 120
        for k in range(3):
            a = math.radians(ang + 120 * k)
            for rr in range(1, 8):
                xx, yy = x + int(round(math.cos(a) * rr)), hub + int(round(math.sin(a) * rr * 0.9))
                if 0 <= yy < H:
                    f[yy, xx] = 11 if rr < 6 else 12
        f[hub, x] = 15
    # Server domes lit from inside, on the shelf east of the volcano.
    for cx, r in ((420, 9), (438, 7), (452, 10), (470, 6)):
        for x in range(cx - r, cx + r + 1):
            hh = int(math.sqrt(max(r * r - (x - cx) ** 2, 0)) * 0.8)
            for y in range(ground - hh, ground + 1):
                lit = (y - (ground - hh)) in (2, 3) and (x - cx) % 3 != 0
                f[y, x] = 7 if lit else 6
        f[ground - int(r * 0.8) - 1, cx] = 15
    # Ice cliffs standing out of the sea: tabular bergs and the shelf's
    # front, white tops, blue-shaded faces, a notch here and there.
    x = 0
    while x < W:
        w = rng.randint(16, 44)
        h = rng.randint(4, 8)
        if not any(f[ground - 3, (x + k) % W] for k in range(-2, w + 2)):
            for k in range(w):
                top = ground - h + (1 if k in (0, w - 1) or (k * 7 + h) % 13 == 0 else 0)
                for y in range(top, ground - 1):
                    f[y, (x + k) % W] = 4 if y < top + 2 and k < w - 3 else 5
        x += w + rng.randint(6, 30)
    # The open sea along the bottom, with glints.
    for y in (ground - 1, ground):
        for xx in range(W):
            if f[y, xx] in (0, 4, 5):
                f[y, xx] = 3 if bayer4(xx * 3, y) < 0.18 else 2
    f[ground + 1:] = 1

    bpal = [(14, 16, 48), (20, 24, 62), (30, 36, 80), (44, 52, 102), (64, 72, 128), (90, 98, 156),
            (120, 126, 180), (196, 150, 186), (70, 236, 150), (36, 150, 112), (230, 80, 210),
            (130, 52, 150), (236, 240, 255), (150, 150, 198), fog, fog]
    # 0..6 twilight gradient, 7 the pink glow at the horizon, 8/9 aurora green bright/dim,
    # 10/11 aurora magenta bright/dim, 12 star, 13 high haze
    BW = 256
    b = np.zeros((H, BW), np.uint8)
    for y in range(H):
        for xx in range(BW):
            b[y, xx] = min(6, int(y / 24 * 6 + bayer4(xx, y)))
            if y >= 25:
                b[y, xx] = 7 if bayer4(xx, y) < (y - 24) / 5 else 6
    for _ in range(40):                               # stars, high up
        sx, sy = rng.randrange(BW), rng.randrange(0, 12)
        b[sy, sx] = 12
    # The aurora: curtains along a slow wave, green below, a magenta fringe above.
    for xx in range(BW):
        mid = 10 + 4 * math.sin(xx / BW * 2 * math.pi * 2 + 0.6) + 2 * math.sin(xx / BW * 2 * math.pi * 5)
        bright = 0.5 + 0.5 * math.sin(xx * 0.37) * math.sin(xx * 0.11 + 1)
        length = 5 + int(5 * bright)
        for k in range(length):
            y = int(mid) + k - 2
            if not 0 <= y < 24:
                continue
            fade = k / length
            if k < 2:
                if bayer4(xx, y) < 0.7:
                    b[y, xx] = 10 if bright > 0.55 else 11
            elif bayer4(xx, y) < 1.0 - fade * 0.8:
                b[y, xx] = 8 if bright > 0.45 and fade < 0.6 else 9
    b[ground + 1:] = 14
    return f, b, fpal, bpal


LEAGUE = dict(pal=PAL, tiles=paint_tiles, background=background("shelf"), horizon=paint_horizon)


# ------------------------------------------------------------ props
PK = {
    "o": hx(0x10121C), "W": hx(0xF4F8FC), "w": hx(0xC8D8EC), "c": hx(0x8CC8E6), "C": hx(0x508CC4),
    "k": hx(0x343A48), "m": hx(0x6E7686), "l": hx(0xAAB2C0), "n": hx(0xF07824), "N": hx(0xAA4618),
    "y": hx(0xFAD246), "r": hx(0xDC3232), "g": hx(0xFFC878), "s": hx(0xDCE6F4), "B": hx(0x2C3C78),
}
PROP_LABELS = ["intake pipe mouth", "pylon", "wind turbine", "ice pinnacle (calving)", "radar dome",
               "frozen crane", "penguin colony sign", "emperor penguin"]


def _cell():
    return Canvas(32, 48)


def snow_base(c, x0=4, x1=27):
    for x in range(x0, x1 + 1):
        h = 1 + int(1.5 * (1 - abs((x - (x0 + x1) / 2) / ((x1 - x0) / 2)) ** 2))
        c.vline(x, 47 - h, 47, PK["s"] if x % 6 else PK["w"])


def prop_pipe():
    """The mouth of a seawater intake pipe standing out of the snow, an
    orange collar, the dark throat, a grille."""
    c = _cell()
    c.rect(6, 30, 25, 45, PK["m"])                 # the pipe's body going down
    c.rect(20, 30, 25, 45, PK["k"])
    c.ellipse(15.5, 24, 14, 12, PK["n"])           # the collar
    c.ellipse(15.5, 24, 14, 12, PK["N"], clip=lambda x, y: x > 20 or y > 31)
    c.ellipse(15.5, 24, 10.5, 9, PK["o"])          # the throat
    c.ellipse(14.5, 23, 7, 6, PK["B"])
    for x in range(8, 24, 3):                      # the grille
        c.line(x, 16, x, 32, PK["l"], clip=lambda xx, yy: c.get(xx, yy) in (PK["o"], PK["B"]))
    c.rect(4, 42, 27, 43, PK["W"])                 # snow on the shoulder
    snow_base(c, 2, 29)
    c.outline(PK["o"])
    return c


def prop_pylon():
    """A steel lattice pylon: insulators and the switchyard's lines."""
    c = _cell()
    for y in range(4, 46):
        hw = 2 + (y - 4) * 0.22
        c.set(15.5 - hw, y, PK["m"])
        c.set(16.5 + hw, y, PK["k"])
        if y % 6 == 0:
            c.hline(int(15.5 - hw), int(16.5 + hw), y, PK["m"])
        if y % 6 == 3:
            c.line(15.5 - hw, y - 3, 16.5 + hw, y + 3, PK["l"])
    for y0, hw in ((8, 10), (18, 12)):             # cross arms
        c.rect(16 - hw, y0, 16 + hw, y0 + 1, PK["k"])
        for x in (16 - hw, 16 + hw):
            c.rect(x - 1, y0 + 2, x, y0 + 5, PK["c"])   # glass insulators
    c.rect(15, 1, 16, 4, PK["k"])
    c.set(15, 1, PK["r"])
    c.rect(6, 44, 26, 45, PK["W"])
    snow_base(c, 4, 27)
    c.outline(PK["o"])
    return c


def prop_turbine():
    """A wind turbine on the ridge, its tower rimed, three blades."""
    c = _cell()
    c.rect(15, 14, 17, 46, PK["W"])
    c.rect(17, 14, 17, 46, PK["w"])
    c.rect(14, 40, 18, 46, PK["l"])                # the base
    hub = (16, 12)
    for a in (-90, 30, 150):
        r = math.radians(a)
        c.line(hub[0], hub[1], hub[0] + math.cos(r) * 13, hub[1] + math.sin(r) * 11, PK["W"])
        c.line(hub[0] + 1, hub[1], hub[0] + 1 + math.cos(r) * 12, hub[1] + math.sin(r) * 10, PK["w"])
    c.rect(13, 10, 19, 13, PK["l"])                # the nacelle
    c.set(19, 10, PK["r"])
    c.rect(15, 26, 17, 27, PK["n"])                # a hazard band
    snow_base(c, 6, 25)
    c.outline(PK["o"])
    return c


def prop_pinnacle():
    """An ice pinnacle (a serac): faceted blue-white ice. Also the calving
    block that slides off the glacier face (the mover's sprite)."""
    c = _cell()
    c.poly([(3, 46), (28, 46), (27, 26), (22, 10), (16, 3), (11, 12), (5, 24)], PK["c"])
    c.poly([(16, 3), (22, 10), (27, 26), (28, 46), (18, 46), (17, 20)], PK["C"])     # the shaded facet
    c.poly([(16, 3), (11, 12), (5, 24), (9, 26), (14, 14)], PK["W"])                 # the lit facet
    c.line(17, 20, 18, 46, PK["w"])
    c.line(9, 28, 13, 40, PK["W"])
    c.line(22, 30, 25, 44, PK["B"])
    snow_base(c, 2, 29)
    c.outline(PK["o"])
    return c


def prop_radar():
    """A radar dome on a steel stand, white panels, a red beacon."""
    c = _cell()
    c.rect(9, 32, 22, 45, PK["m"])
    c.rect(18, 32, 22, 45, PK["k"])
    c.rect(13, 38, 17, 45, PK["g"])                # a lit door
    c.ellipse(15.5, 20, 13, 13, PK["W"])
    c.ellipse(15.5, 20, 13, 13, PK["w"], clip=lambda x, y: x > 19 or y > 27)
    for k in range(-2, 3):                          # the panel seams
        c.line(15.5 + k * 5, 8, 15.5 + k * 6, 32, PK["l"], clip=lambda x, y: c.get(x, y) in (PK["W"], PK["w"]))
    c.line(4, 20, 27, 20, PK["l"], clip=lambda x, y: c.get(x, y) in (PK["W"], PK["w"]))
    c.rect(15, 5, 16, 7, PK["r"])
    snow_base(c, 3, 28)
    c.outline(PK["o"])
    return c


def prop_crane():
    """A frozen crane: an orange jib, icicles, a hook that will not move."""
    c = _cell()
    c.rect(7, 10, 9, 45, PK["n"])                  # the mast
    c.rect(9, 10, 9, 45, PK["N"])
    for y in range(12, 44, 4):
        c.line(7, y, 9, y + 3, PK["N"])
    c.rect(3, 8, 29, 10, PK["n"])                  # the jib
    c.rect(3, 10, 29, 10, PK["N"])
    c.rect(2, 11, 6, 15, PK["k"])                  # the counterweight
    for x in range(10, 29, 3):                     # icicles under the jib
        c.vline(x, 11, 11 + (x * 7) % 4 + 1, PK["c"])
    c.vline(25, 11, 30, PK["k"])                   # the cable and its hook
    c.rect(24, 30, 26, 32, PK["l"])
    c.rect(4, 7, 29, 7, PK["W"])                   # snow on the jib
    c.rect(5, 42, 12, 45, PK["k"])
    snow_base(c, 2, 26)
    c.outline(PK["o"])
    return c


def prop_sign():
    """The penguin colony sign: a navy board, white letters, a penguin
    pictogram. The penguins are gone."""
    c = _cell()
    c.rect(7, 30, 8, 46, PK["m"])
    c.rect(23, 30, 24, 46, PK["m"])
    c.rect(2, 5, 29, 31, PK["B"])
    c.ellipse(16, 11.5, 3, 3.5, PK["W"])           # the pictogram
    c.ellipse(16, 7.5, 2, 2, PK["W"])
    c.set(18, 7, PK["y"])
    text3(c, "PENGUIN", 3, 16, PK["W"])
    text3(c, "COLONY", 5, 22, PK["W"])
    c.rect(2, 28, 29, 31, PK["n"])                 # the orange foot band
    c.rect(2, 4, 29, 5, PK["W"])                   # snow on the top
    snow_base(c, 3, 28)
    c.outline(PK["o"])
    return c


def prop_penguin():
    """The emperor penguin who did not get the memo."""
    c = _cell()
    c.ellipse(16, 33, 9, 13, PK["o"])              # the back (black)
    c.ellipse(17, 34, 6, 11, PK["W"])              # the white front
    c.ellipse(17, 36, 6, 9, PK["w"], clip=lambda x, y: x > 19)
    c.ellipse(15, 17, 5.5, 5, PK["o"])             # the head
    c.ellipse(18, 21, 2.5, 3, PK["y"])             # the yellow ear patch / neck
    c.ellipse(19, 24, 3, 2.5, PK["g"])
    c.line(19, 16, 25, 19, PK["k"])                # the beak: dark above, orange below
    c.line(19, 17, 24, 20, PK["n"])
    c.set(17, 16, PK["W"])
    c.rect(10, 28, 11, 40, PK["k"])                # a flipper
    c.rect(13, 45, 16, 46, PK["n"])                # feet
    c.rect(18, 45, 21, 46, PK["n"])
    snow_base(c, 6, 26)
    c.outline(PK["B"])
    return c


PROPS = [prop_pipe, prop_pylon, prop_turbine, prop_pinnacle, prop_radar, prop_crane, prop_sign, prop_penguin]
PROP = {n: i for i, n in enumerate(["pipe", "pylon", "turbine", "pinnacle", "radar", "crane", "sign", "penguin"])}
MOVER_CELL = PROP["pinnacle"]


def draw_props():
    return [fn() for fn in PROPS]


# ------------------------------------------------------------ the arena
import pack_arena as PA  # noqa: E402
import build_tracks as bt  # noqa: E402

# The Moon Pool's ring of steam vents (timed blasts, written into the
# arena's feat records by `MoonPoolArena.post`): from the pool's rim at
# its four diagonals, out toward the islands' inner corners, firing in a
# rotating sequence.
POOL_C, POOL_R = 43.5, 8.6
VENT_RING = dict(period=240, on=30, warn=45, damage=20, push=56, size=10)


class MoonPoolArena(PA.PackArena):
    """The Moon Pool (SPEC 19.9): a hall drilled into the ice shelf where
    the intake pipes drop into the sea. The pit is the moon pool itself,
    black water in the middle; the whole floor is glare ice (attribute
    coolant: every car slides), except the crate pads' grated plates, the
    spawn pads and the bays. Ice kickers face the pool from all four sides;
    a ring of four steam vents fires out from its rim at the diagonals, one
    after another; the intake pipes' shafts cut across the side lanes,
    jumped on ice ramps (gap jumps, so rounds don't drag); the pipe housings
    are the four islands. 18 nav nodes (the Food Court's graph: the
    Sandbox's islands, pads and pit without its fences, one gap jump a side
    lane), a 1.9 KB blob."""
    name, stem, background = "THE MOON POOL", "the_moon_pool", "halls"
    GAP_ROWS = (41, 46)    # the pipe shafts across the side lanes: rows 41..45

    def __init__(self):
        n = PA.ARENA
        k = np.full((n, n), PA.FLOOR, np.uint8)
        for x0 in (14, 60):            # the pipe housings
            for y0 in (14, 60):
                k[y0:y0 + 14, x0:x0 + 14] = PA.SOLID
        for y in range(n):             # the moon pool
            for x in range(n):
                if math.hypot(x - POOL_C, y - POOL_C) <= POOL_R:
                    k[y, x] = PA.PIT
        g0, g1 = self.GAP_ROWS
        self.ramps = []
        for x0, x1 in ((0, 13), (74, 87)):
            k[g0:g1, x0:x1 + 1] = PA.PIT
            self.ramps.append((x0, g0 - 2, x1, g0 - 1, 1))   # facing S, north of the shaft
            self.ramps.append((x0, g1, x1, g1 + 1, 3))       # facing N, south of it
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
        self.sweeper = None            # no Sweeper: the four vents fill the World's hazard slots
        w = PA.rel_world
        self.props = [("pipe", *w(20, 20)), ("crane", *w(24, 17)), ("pipe", *w(67, 20)), ("pylon", *w(63, 24)),
                      ("pipe", *w(20, 67)), ("radar", *w(24, 63)), ("pipe", *w(67, 67)), ("crane", *w(63, 70)),
                      ("turbine", *w(44, -4)), ("sign", *w(43, 91)), ("penguin", *w(-4, 34)), ("radar", *w(91, 52))]

    def vents(self):
        """The ring's four blast records (mouth at the pool's rim, out along
        the diagonal to the island's inner corner), phases a quarter apart."""
        out = []
        o = VENT_RING
        for q, (sx, sy) in enumerate(((-1, -1), (1, -1), (1, 1), (-1, 1))):
            r0, r1 = POOL_R + 1.2, POOL_R + 8.5
            d = 1 / math.sqrt(2)
            x0, y0 = PA.rel_world(POOL_C - 0.5 + sx * r0 * d, POOL_C - 0.5 + sy * r0 * d)
            x1, y1 = PA.rel_world(POOL_C - 0.5 + sx * r1 * d, POOL_C - 0.5 + sy * r1 * d)
            rec = bytes([bt.K_BLAST, o["warn"], o["size"], o["damage"]])
            rec += np.array([int(x0), int(y0), int(x1), int(y1), o["period"], o["on"], q * o["period"] // 4], "<u2").tobytes()
            rec += bytes([o["push"], 0])
            out.append((rec, (x0, y0), (x1, y1)))
        return out

    def floor(self, tmap, big, rng):
        """Glare ice over the whole floor (attribute coolant), but grated
        plates round the crate pads (they must be plain floor) and the
        vents' outflow grates along the ring's lanes."""
        O = PA.O
        road = (SURF, SURF_SEAM_V, SURF_SEAM_H, SURF_SEAM_X, SURF_DOT, RUT, RUT + 1)
        keep = set()
        for x, y in self.pads:
            for oy in (-1, 0, 1):
                for ox in (-1, 0, 1):
                    keep.add((O + y + oy, O + x + ox))
        for ty in range(128):
            for tx in range(128):
                if tmap[ty, tx] not in road:
                    continue
                if (ty, tx) in keep:
                    tmap[ty, tx] = GRATE
                else:
                    tmap[ty, tx] = ICE_CRACK if hash01(tx, ty, 71) < 0.18 else ICE
        for _, (x0, y0), (x1, y1) in self.vents():
            for i in range(64):
                t = i / 63
                x, y = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
                for oy in (-4, 4):
                    for ox in (-4, 4):
                        ty, tx = int(y + oy) // 8, int(x + ox) // 8
                        if tmap[ty, tx] in (ICE, ICE_CRACK):
                            tmap[ty, tx] = VENT_LANE + (0 if (x1 - x0) * (y1 - y0) > 0 else 1)

    def post(self, tmap):
        """The pool's open water (floes on the black), and the ring's blast
        records appended to the arena's feat file (pack_arena reads it back
        after this hook; there is no Sweeper record before them)."""
        for ty in range(128):
            for tx in range(128):
                if tmap[ty, tx] == GAP:          # a pit tile with no floor beside it
                    tmap[ty, tx] = PIT
        import common as C
        feat = C.PACKS / NAME / f"{self.stem}_feat.bin"
        feat.write_bytes(feat.read_bytes() + b"".join(rec for rec, *_ in self.vents()))


ARENA = MoonPoolArena
