"""Weapons, decals, pickups, effects, the GC claw and HUD bits (PLAN Track B items 3-6).

Small sprites are hand-placed pixel stamps (one ASCII row per pixel row,
'.' is transparent) over one palette per sheet; the larger effects are
drawn with shapes. Every sheet is a horizontal strip of equal cells.
"""
from __future__ import annotations

import math
import random

from .raster import Canvas, hx, strip, text3, text3_width


def cell(w, h, rows, cmap, ox=None, oy=None):
    """A w x h cell with the stamp centred (or at ox, oy)."""
    c = Canvas(w, h)
    sw, sh = max(len(r) for r in rows), len(rows)
    x = (w - sw) // 2 if ox is None else ox
    y = (h - sh) // 2 if oy is None else oy
    c.stamp(rows, x, y, cmap)
    return c


# ==================================================================== weapons
# 8x8 projectiles and drops, seen in the world (the renderer scales them).
WP = {
    "o": hx(0x141018), "w": hx(0xF4F4F0), "c": hx(0x4FD6E8), "C": hx(0x1E7A9A),
    "y": hx(0xFFD23C), "r": hx(0xF08A24), "R": hx(0xD83A3A), "b": hx(0x2A62D8),
    "n": hx(0x1A2E6A), "l": hx(0xB4B8C4), "g": hx(0x6C7080), "d": hx(0x2E2C36), "k": hx(0x141018),
}

WEAPONS = [
    ("ping", "PING pellet (an ICMP echo: a bright cyan blip)", [
        "........",
        "........",
        "...cc...",
        "..cwwc..",
        "..cwwc..",
        "...cc...",
        "........",
        "........",
    ]),
    ("broadcast", "BROADCAST pellet (a hot orange spark, one of five)", [
        "........",
        "...r....",
        "..ryr...",
        ".rywyr..",
        "..ryr...",
        "...r....",
        "........",
        "........",
    ]),
    ("phish_rear", "SPEAR PHISH from behind: round body, four fins, exhaust", [
        "...oo...",
        "...lo...",
        "..oooo..",
        ".olyylo.",
        ".olyrlo.",
        "..oooo..",
        "...lo...",
        "...oo...",
    ]),
    ("phish_side", "SPEAR PHISH side (nose right): a silver fish, spear tip forward, exhaust at the tail", [
        "........",
        "........",
        "o..ooo..",
        "rolllllo",
        "yollkllw",
        "rolgggoo",
        "o..ooo..",
        "........",
    ]),
    ("phish_quarter", "SPEAR PHISH three-quarter (nose up-right)", [
        ".......w",
        ".....ool",
        "....olko",
        "...ollo.",
        "..ollo..",
        "oogoo...",
        "ryo.....",
        "yr......",
    ]),
    ("logic_bomb", "LOGIC BOMB armed: a mine marked `if`, red light on", [
        "...RR...",
        ".ooRRoo.",
        "owddwwdo",
        "odddwddo",
        "owdwwwdo",
        "owddwddo",
        "owddwddo",
        ".oooooo.",
    ]),
    ("logic_bomb_off", "LOGIC BOMB blink frame: light off", [
        "...oo...",
        ".oooooo.",
        "owddwwdo",
        "odddwddo",
        "owdwwwdo",
        "owddwddo",
        "owddwddo",
        ".oooooo.",
    ]),
    ("fork_bomb", "FORK BOMB child: a round bomb with `&`, fuse lit", [
        "......yr",
        ".oooooo.",
        "oddwwddo",
        "odwddwdo",
        "oddwwddo",
        "odwddwwo",
        "oddwwdwo",
        ".oooooo.",
    ]),
    ("kernel_panic", "KERNEL PANIC packet: a blue packet with :(", [
        "oooooooo",
        "obbbbbbo",
        "obwbbwbo",
        "obbbwbbo",
        "obwbwbbo",
        "obbbbwbo",
        "obbbbbbo",
        "oooooooo",
    ]),
    ("ddos_drone", "DDOS drone (4x4 in the middle of the cell)", [
        "..R..R..",
        "...oo...",
        "..oRRo..",
        "..oRRo..",
        "...oo...",
        "..R..R..",
    ]),
    ("duck", "RUBBER DUCK on its tether (side, facing right)", [
        "...yyy..",
        "..yyyoy.",
        "..yyyyrr",
        "y..yyy..",
        "yyyyyyy.",
        "yyyyyyy.",
        ".yyyyy..",
        "........",
    ]),
]


def draw_weapons():
    cells = []
    for name, _, rows in WEAPONS:
        if name == "ddos_drone":
            cells.append(cell(8, 8, rows, WP, oy=1))
        else:
            cells.append(cell(8, 8, [r[:8] for r in rows], WP))
    # the duck gets an outline of its own: yellow on a sunny floor needs it
    duck = cells[-1]
    d2 = Canvas(8, 8)
    d2.paste(duck)
    d2.outline(WP["o"])
    d2.paste(duck)
    cells[-1] = d2
    return strip(cells)


# ===================================================================== decals
# 16x8 flat sprites drawn as seen from above; the renderer squashes them onto the floor.
DC = {
    "o": hx(0x141018), "1": hx(0x0E5A3A), "2": hx(0x1E9A5A), "3": hx(0x6AF0A0),
    "u": hx(0x5A3A26), "U": hx(0xA0603A), "g": hx(0x6C7080), "l": hx(0xB4B8C4),
    "y": hx(0xE8C050), "Y": hx(0xA88A2A), "R": hx(0xA83A2A), "r": hx(0xD86A3A),
    "w": hx(0xF4F4F0), "k": hx(0x2A2830), "a": hx(0xE8A830),
}

DECALS = [
    ("leak_a", "MEMORY LEAK puddle (green ooze, leaked bits floating)", [
        "....11111111....",
        "..112222222211..",
        ".12223222223221.",
        "122232222322221.",
        "122222232222221.",
        ".12222322222321.",
        "..11222222221...",
        "....111111111...",
    ]),
    ("leak_b", "MEMORY LEAK shimmer frame", [
        "....11111111....",
        "..112222222211..",
        ".12222232222221.",
        "122322222222321.",
        "122222222232221.",
        ".12232222222221.",
        "..11222222221...",
        "....111111111...",
    ]),
    ("bitrot", "BIT ROT caltrop: a rusted jack", [
        "................",
        "......o.........",
        ".....oUo...o....",
        "..o..oUoo.oUo...",
        ".oUoouUUuuUo....",
        "..ooUUuUUoo.....",
        "....ouoouo......",
        ".....o..o.......",
    ]),
    ("spaghetti", "SPAGHETTI CODE tangle (yellow cable loops)", [
        "...yyy....yyY...",
        "..y...yyyy...y..",
        ".Y..yyY..yyy..y.",
        ".y.y...yy...y.y.",
        "..yY..y..y..Yy..",
        "...yyy....yyy.y.",
        ".y....yyyy....Y.",
        "..yyY......yyy..",
    ]),
    ("firewall_base", "FIREWALL base: a line of burning bricks", [
        "kkkkkkkkkkkkkkkk",
        "RRRkRRRRkRRRRkRR",
        "rRRkrRRRkrRRRkrR",
        "kkkkkkkkkkkkkkkk",
        "RkRRRRkRRRRkRRRR",
        "RkrRRRkrRRRkrRRR",
        "kkkkkkkkkkkkkkkk",
        "................",
    ]),
    ("chip", "CYCLE chip: a little CPU, worth 10 CYCLES", [
        "......l.l.......",
        "....l.l.l.l.....",
        "...okkkkkkko....",
        "..lkkaakkkkkl...",
        "...kkaakkkkk....",
        "..lkkkkkkkkkl...",
        "...okkkkkkko....",
        "....l.l.l.l.....",
    ]),
    ("scorch", "scorch mark left by a wreck or a blast", [
        "....k..kk.......",
        "..kkkkkkkkk.k...",
        ".kkkkkkkkkkkk...",
        "kkkkkkkkkkkkkk..",
        ".kkkkkkkkkkkkkk.",
        "..kkkkkkkkkkk...",
        "...k.kkkkkk.....",
        "........k.......",
    ]),
]


def draw_decals():
    return strip([cell(16, 8, rows, DC) for _, _, rows in DECALS])


# ==================================================================== pickups
# 16x16 HUD icons (SPEC 6.3 order), then the roulette blank and the crates.
PK = {
    "o": hx(0x141018), "w": hx(0xF4F4F0), "l": hx(0xB4B8C4), "g": hx(0x6C7080),
    "b": hx(0x2A62D8), "n": hx(0x1A2E6A), "c": hx(0x4FD6E8), "y": hx(0xFFD23C),
    "r": hx(0xF08A24), "R": hx(0xD83A3A), "G": hx(0x4CC850), "B": hx(0x7A4A24),
    "t": hx(0xC8955A), "e": hx(0xE2D6BC), "P": hx(0x9A5AE0),
}

PICKUPS = [
    ("PREFETCH", "a fast-forward double chevron: loads the road ahead", [
        "................",
        "................",
        "..oo......oo....",
        ".occo....occo...",
        ".owcco...owcco..",
        "..owcco...owcco.",
        "...owcco...owcco",
        "....owcco...owco",
        "....owcco...owco",
        "...owcco...owcco",
        "..owcco...owcco.",
        ".owcco...owcco..",
        ".occo....occo...",
        "..oo......oo....",
        "................",
        "................",
    ]),
    ("HONEYPOT", "a honey pot, honey running over the rim", [
        "................",
        "....oooooooo....",
        "...oyyyyyyyyo...",
        "..oooooooooooo..",
        "..oyyBBBBBByyo..",
        "...oyrrrrrryo...",
        "..oryyrrrrryro..",
        ".orrryrrrrrrrro.",
        ".orrryrwwwwrrro.",
        ".orrrrwBBBBwrro.",
        ".orrrrwwwwwwrro.",
        ".oBrrrrrrrrrrBo.",
        "..oBrrrrrrrrBo..",
        "...oBBBBBBBBo...",
        "....oooooooo....",
        "................",
    ]),
    ("RUBBER DUCK", "a rubber duck: explain the bug to it", [
        "................",
        "......oooo......",
        ".....oyyyyo.....",
        "....oyyyyoyo....",
        "....oyyyyyyroo..",
        "....oyyyyyrrrro.",
        ".oo..oyyyyoooo..",
        "oyyo..oyyyo.....",
        "oyyyooyyyyyoo...",
        "oyyyyyyyyyyyyo..",
        ".oyyyyyyyyyyyyo.",
        ".oyyyyyyyyyyyro.",
        "..oyyyyyyyyyro..",
        "...ooyyyyyroo...",
        ".....ooooooo....",
        "................",
    ]),
    ("HOT PATCH", "a plaster, glowing hot: no reboot required", [
        "................",
        "..........r.....",
        "........oorro...",
        ".......oeeoyo...",
        "......oeeeeo....",
        ".....oeeRReo....",
        "....oeeRRRReo...",
        "...oeeeRRReeo...",
        "..oeeeeeRRe.....",
        "..oeeeeeeeo.....",
        ".r.oeeeeeo......",
        "rro.oeeeo.......",
        ".yr..ooo........",
        "..r.............",
        "................",
        "................",
    ]),
    ("SPAGHETTI CODE", "spaghetti with a meatball, on a plate", [
        "................",
        "................",
        "......oooo......",
        ".....oRRRRo.....",
        "....oRRwRRRo....",
        "..oyyoRRRRoyyo..",
        ".oyyyyooooyyyyo.",
        ".oyoyyyyoyyyoyo.",
        "oyyyoyyyyyoyyyyo",
        "oyoyyyoyyyyyoyyo",
        "ollyyyyyoyyyylo.",
        "olllllllllllllo.",
        ".oggllllllllggo.",
        "..ooggggggggoo..",
        "....oooooooo....",
        "................",
    ]),
    ("FORK BOMB", "a bomb marked & with its fuse lit", [
        "...........y.r..",
        ".........r.yy...",
        "..........oyr...",
        ".........og.....",
        ".......oog......",
        ".....oooooooo...",
        "....ogoooooooo..",
        "...ogooowwoooo..",
        "...ogoowoowooo..",
        "...oooowoowooo..",
        "...ooooowwoooo..",
        "...ooowoowoowo..",
        "....oowooowwoo..",
        ".....oowwwooww..",
        "......oooooo....",
        "................",
    ]),
    ("BIT FLIP", "a cosmic ray flipping a 0 into a 1", [
        "................",
        ".........oo.....",
        "........oyyo....",
        ".......oyyo.....",
        "......oyyo......",
        ".....oyyyyyo....",
        "....ooooyyo.....",
        ".......oyo......",
        "..ooo..oo..ooo..",
        ".owwwo....oowwo.",
        ".owoowo..owwwwo.",
        ".owoowo...oowwo.",
        ".owoowo....owwo.",
        ".owoowo....owwo.",
        "..owwo....owwwwo",
        "...oo......oooo.",
    ]),
    ("DEADLOCK", "a padlock chained to both sides", [
        "................",
        ".....oooooo.....",
        "....ollllllo....",
        "...olgoooolgo...",
        "...olo....olo...",
        "...olo....olo...",
        ".oooooooooooooo.",
        "oggoyyyyyyyyoggo",
        "olloyyyyyyyyollo",
        "oggoyyyooyyyoggo",
        ".ooyyyyooyyyyoo.",
        "...oyyyyooyyo...",
        "...oyyyyyyyyo...",
        "...oryyyyyyro...",
        "....oooooooo....",
        "................",
    ]),
    ("DDOS", "a swarm of packet drones closing on a target", [
        "................",
        ".oRo...oRo......",
        "..o.....o...oRo.",
        "............o...",
        "......oooo......",
        ".oRo.owwwwo.....",
        "..o.owRRRRwo....",
        "....owRwwRwo.oRo",
        "....owRwwRwo..o.",
        "....owRRRRwo....",
        "oRo..owwwwo.....",
        ".o....oooo......",
        "...........oRo..",
        "...oRo......o...",
        "....o...oRo.....",
        ".........o......",
    ]),
    ("HEISENBUG", "a bug you cannot quite observe", [
        "................",
        "....o......o....",
        ".....o....o.....",
        "......oooo......",
        ".....oPPPPo.....",
        "................",
        "..o.oPwPPwPo.o..",
        "................",
        "....oPPoPPPo....",
        "................",
        "..o.oPPoPPPo.o..",
        "................",
        ".....oPPoPo.....",
        "................",
        "....o..oo..o....",
        "................",
    ]),
    ("RACE CONDITION", "two crossing arrows: swap places", [
        "................",
        "..oo........oo..",
        ".occo......orro.",
        "occcco....orrrro",
        "ooccoo....oorroo",
        "..occo....orro..",
        "...occo..orro...",
        "....occoorro....",
        ".....occrro.....",
        ".....orrcco.....",
        "....orro.occo...",
        "...orro...occo..",
        "..orro.....occo.",
        "..oro.......oco.",
        "...o.........o..",
        "................",
    ]),
    ("KERNEL PANIC", "a blue screen with :(", [
        "................",
        ".oooooooooooooo.",
        ".obbbbbbbbbbbbo.",
        ".obbbbbbbbbwbbo.",
        ".obbwwbbbbwbbbo.",
        ".obbwwbbbwwbbbo.",
        ".obbbbbbbwbbbbo.",
        ".obbwwbbbwwbbbo.",
        ".obbwwbbbbwbbbo.",
        ".obbbbbbbbbwbbo.",
        ".obnnnnnnnbbbbo.",
        ".obbbbbbbbbbbbo.",
        ".oooooooooooooo.",
        "......oggo......",
        "....oooooooo....",
        "................",
    ]),
    ("CAPTCHA", "a 3x3 picture grid with traffic lights in some squares", [
        "oooooooooooooooo",
        "olRllollllolRllo",
        "olyllollllolyllo",
        "olGllollllolGllo",
        "ollllollllollllo",
        "oooooooooooooooo",
        "ollllolRllollllo",
        "ollllolyllollllo",
        "ollllolGllollllo",
        "ollllollllollllo",
        "oooooooooooooooo",
        "ollllollllollllo",
        "ollllollllollllo",
        "ollllollllollllo",
        "ollllollllollllo",
        "oooooooooooooooo",
    ]),
    ("SUDO", "root's # under a crown", [
        "................",
        "..o..o..o..o....",
        ".oyo.oyooyo.oyo.",
        ".oyyoyyyyyyoyyo.",
        ".oyyyyRyyRyyyyo.",
        ".oyyyyyyyyyyyyo.",
        "..oooooooooooo..",
        "....owo..owo....",
        "..oowwoooowwoo..",
        "..owwwwwwwwwwo..",
        "..oowwoooowwoo..",
        "....owo..owo....",
        "..oowwoooowwoo..",
        "..owwwwwwwwwwo..",
        "..oowwoooowwoo..",
        "....oo....oo....",
    ]),
    ("ZERO-DAY", "a calendar page reading 0", [
        "................",
        "...o..o..o..o...",
        "..oloooloooloo..",
        ".oRlRRRlRRRlRRo.",
        ".oRRRRRRRRRRRRo.",
        ".owwwwwwwwwwwwo.",
        ".owwwwooooowwwo.",
        ".owwwoowwwoowwo.",
        ".owwwowwwooowwo.",
        ".owwwowwoowowwo.",
        ".owwwowoowwowwo.",
        ".owwwoooowwowwo.",
        ".owwwoowwwoowwo.",
        ".owwwwooooowwgo.",
        ".oooooooooooooo.",
        "................",
    ]),
    ("PROMPT INJECTION", "a syringe into a > prompt", [
        "............o...",
        "...........olo..",
        "..........olgoo.",
        ".........oGGlo..",
        "........oGGGo...",
        ".......oGGGo....",
        "......oGGGo.....",
        ".....olllo......",
        "....olo.........",
        "oooooooooo......",
        "onnnnnnnno......",
        "onwnnnnnno......",
        "onnwnnnnno......",
        "onwnnwwwno......",
        "onnnnnnnno......",
        "oooooooooo......",
    ]),
    ("(roulette blank)", "FETCHING...: an empty slot with three dots", [
        "................",
        "................",
        "................",
        "................",
        "................",
        "................",
        "................",
        "..oo...oo...oo..",
        ".owlo.owlo.owlo.",
        ".ollo.ollo.ollo.",
        "..oo...oo...oo..",
        "................",
        "................",
        "................",
        "................",
        "................",
    ]),
]


def crate(label_col, mark=False):
    """The RMA crate (a 3/4 view box), also its HONEYPOT fakes."""
    rows = [
        "................",
        "...ooooooooooooo",
        "..otttttttttttBo",
        ".ooooooooooooooo",
        ".otBtttttttttBto",
        ".otLLLLLLLLLLLto",
        ".otLLLLLLLLLLLto",
        ".otLLLLLLLLLLLto",
        ".otLLLLLLLLLLLto",
        ".otLLLLLLLLLLLto",
        ".otLLLLLLLLLLLto",
        ".otBtttttttttBto",
        ".otttttttttttttB",
        ".ooooooooooooooo",
        "................",
        "................",
    ]
    cmap = dict(PK)
    cmap["L"] = label_col
    c = cell(16, 16, rows, cmap, ox=0, oy=0)
    text3(c, "RMA", 3, 6, PK["o"])
    if mark:
        c.rect(3, 5, 13, 10, label_col)
        text3(c, "?", 7, 6, PK["r"])
    return c


def draw_pickups():
    cells = [cell(16, 16, rows, PK) for _, _, rows in PICKUPS]
    # CAPTCHA: a green tick across the bottom row, "I am human"
    tick = Canvas(16, 16)
    for (x0, y0, x1, y1) in ((4, 11, 7, 14), (7, 14, 13, 8), (4, 12, 7, 15), (7, 15, 13, 9)):
        tick.line(x0, y0, x1, y1, PK["G"])
    t2 = tick.copy()
    t2.outline(PK["o"])
    cells[12].paste(t2)
    cells += [crate(PK["w"]), crate(PK["e"]), crate(PK["e"], mark=True)]
    return strip(cells)


PICKUP_CELLS = [name for name, _, _ in PICKUPS] + ["RMA crate", "HONEYPOT crate", "HONEYPOT crate, ? frame"]


# ===================================================================== effects
FX = {
    "w": hx(0xFFFFF0), "y": hx(0xFFD23C), "r": hx(0xF08A24), "R": hx(0xD83A3A), "D": hx(0x7A1E1E),
    "s": hx(0xB4B0B8), "S": hx(0x7C7884), "k": hx(0x4A4650), "K": hx(0x2A2830), "o": hx(0x141018),
}


def blob(c: Canvas, cx, cy, r, col, rng, rough=0.25, n=14):
    """A rough disc: radius varies by angle."""
    radii = [r * (1 + rng.uniform(-rough, rough)) for _ in range(n)]
    for y in range(c.h):
        for x in range(c.w):
            dx, dy = x + 0.5 - cx, y + 0.5 - cy
            d = math.hypot(dx, dy)
            a = (math.atan2(dy, dx) / (2 * math.pi)) % 1 * n
            i = int(a)
            f = a - i
            rr = radii[i] * (1 - f) + radii[(i + 1) % n] * f
            if d <= rr:
                c.set(x, y, col)


def explosion(frame: int) -> Canvas:
    c = Canvas(24, 24)
    rng = random.Random(40 + frame)
    cx = cy = 12
    if frame == 0:
        blob(c, cx, cy, 6, FX["r"], rng, 0.35)
        blob(c, cx, cy, 4.5, FX["y"], rng, 0.3)
        blob(c, cx, cy, 2.5, FX["w"], rng, 0.2)
        for k in range(8):
            a = k * math.pi / 4 + 0.3
            for t in range(7, 10):
                c.set(int(cx + math.cos(a) * t), int(cy + math.sin(a) * t), FX["y"] if t < 9 else FX["r"])
    elif frame == 1:
        blob(c, cx, cy, 10, FX["D"], rng, 0.2)
        blob(c, cx, cy, 8.5, FX["R"], rng, 0.25)
        blob(c, cx - 1, cy - 1, 6.5, FX["r"], rng, 0.3)
        blob(c, cx - 1, cy - 1, 4, FX["y"], rng, 0.3)
        blob(c, cx - 1, cy - 2, 2, FX["w"], rng, 0.2)
    elif frame == 2:
        blob(c, cx, cy, 11, FX["k"], rng, 0.18)
        blob(c, cx, cy - 1, 9, FX["S"], rng, 0.25)
        blob(c, cx + 1, cy, 7, FX["R"], rng, 0.35)
        blob(c, cx + 1, cy + 1, 4.5, FX["r"], rng, 0.35)
        blob(c, cx + 2, cy + 1, 2, FX["y"], rng, 0.3)
        for _ in range(6):
            c.set(rng.randrange(3, 21), rng.randrange(3, 21), FX["y"])
    else:
        blob(c, cx, cy, 11, FX["k"], rng, 0.2)
        blob(c, cx - 1, cy - 2, 8, FX["S"], rng, 0.3)
        blob(c, cx - 2, cy - 3, 4, FX["s"], rng, 0.3)
        hole = Canvas(24, 24)
        blob(hole, cx + 2, cy + 3, 4.5, FX["o"], rng, 0.4)
        for (x, y) in hole.mask():
            c.set(x, y, None)
        for _ in range(5):
            c.set(rng.randrange(4, 20), rng.randrange(4, 20), FX["r"])
    c.outline(FX["o"]) if frame in (1, 2) else None
    return c


def smoke(frame: int) -> Canvas:
    c = Canvas(24, 24)
    rng = random.Random(70 + frame)
    if frame == 0:
        blob(c, 12, 13, 5.5, FX["S"], rng, 0.2)
        blob(c, 11, 12, 4, FX["s"], rng, 0.2)
        c.outline(FX["k"])
    else:
        blob(c, 12, 11, 8.5, FX["k"], rng, 0.2)
        blob(c, 11, 10, 6.5, FX["S"], rng, 0.25)
        blob(c, 10, 9, 3.5, FX["s"], rng, 0.25)
    return c


def spark(frame: int) -> Canvas:
    c = Canvas(24, 24)
    rng = random.Random(7)
    rays = [(k * math.pi / 4 + rng.uniform(-0.25, 0.25), rng.uniform(0.8, 1.0)) for k in range(8)]
    r0, r1 = (0.0, 5.0) if frame == 0 else (4.0, 9.0)
    for k, (a, sc) in enumerate(rays):
        if frame and k % 2:
            continue
        steps = int((r1 - r0) * 2) + 1
        for j in range(steps + 1):
            rr = (r0 + (r1 - r0) * j / steps) * sc
            x, y = int(round(11.5 + rr * math.cos(a))), int(round(11.5 + rr * math.sin(a)))
            c.set(x, y, (FX["w"] if j >= steps - 1 else FX["y"]) if frame == 0 else (FX["y"] if j >= steps - 1 else FX["r"]))
    if frame == 0:
        c.rect(10, 10, 13, 13, FX["w"])
    return c


def muzzle() -> Canvas:
    """Muzzle flash pointing up the screen (forward from a car seen from behind)."""
    rows = [
        "...........w............",
        "...........w............",
        "..........ywy...........",
        "..........ywy...........",
        ".....r....ywy....r......",
        "......r..ywwwy..r.......",
        ".......ryywwwyyr........",
        "........yywwwyy.........",
        "...rrryyywwwwwyyyrrr....",
        "........yywwwyy.........",
        ".......ryyywyyyr........",
        "......r..ryyyr..r.......",
        ".....r....rrr....r......",
    ]
    return cell(24, 24, rows, FX, ox=0, oy=6)


def flame(frame: int) -> Canvas:
    """FIREWALL flame tongue, 2 frames; its foot sits on the bottom rows."""
    rows = [
        [
            "........................",
            "..........r.............",
            ".........rr.............",
            ".........rRr......r.....",
            "........rryr.....rr.....",
            "....r...ryyrr....rRr....",
            "....rr..ryyyr...rryr....",
            "...rRr.rryyyrr..ryyr....",
            "...ryrrryywyyr.rryyrr...",
            "..rryyrryywwyrrryyyyr...",
            "..ryyyyryywwyyrryywyr...",
            ".rryywyyyywwwyyyywwyrr..",
            ".ryywwyyywwwwyyyywwyyr..",
            ".ryywwwyywwwwwyyywwwyr..",
            "rryywwwwwwwwwwwwwwwwyrr.",
            "Rryyywwwwwwwwwwwwwwyyrr.",
            "RRryyyyyyyyyyyyyyyyyyrRR",
            ".RRrrrrrrrrrrrrrrrrrrRR.",
        ],
        [
            "........................",
            "................r.......",
            "...r...........rr.......",
            "...rr..........rRr......",
            "...rRr........rryr......",
            "...ryr...r....ryyrr.....",
            "..rryrr..rr..rryyyr.....",
            "..ryyyr.rRr..ryywyrr....",
            "..ryyyrrryrr.ryywyyr....",
            ".rryywyrryyrrryywwyrr...",
            ".ryywwyyryyyrryywwyyr...",
            ".ryywwyyyywyyyyywwwyrr..",
            "rryywwwyyywwyyyywwwyyr..",
            "ryyywwwwywwwwyywwwwwyr..",
            "ryywwwwwwwwwwwwwwwwwyrr.",
            "Rryyywwwwwwwwwwwwwwyyrr.",
            "RRryyyyyyyyyyyyyyyyyyrRR",
            ".RRrrrrrrrrrrrrrrrrrrRR.",
        ],
    ][frame]
    return cell(24, 24, rows, FX, ox=0, oy=24 - len(rows) - 1)


FX_CELLS = ["explosion 0 (flash)", "explosion 1 (fireball)", "explosion 2 (burning smoke)", "explosion 3 (dying)",
            "smoke puff small", "smoke puff big", "spark 0", "spark 1", "muzzle flash (points up)",
            "FIREWALL flame 0", "FIREWALL flame 1"]


def draw_fx():
    cells = [explosion(i) for i in range(4)] + [smoke(0), smoke(1), spark(0), spark(1), muzzle(), flame(0), flame(1)]
    return strip(cells)


# ======================================================================= claw
CL = {
    "o": hx(0x141018), "g": hx(0x5A5E6A), "l": hx(0x9A9EAA), "w": hx(0xD8DCE6), "y": hx(0xF0C030),
    "k": hx(0x2A2830), "R": hx(0xE03A3A),
}


def claw(closed: bool) -> Canvas:
    """The GC claw (24x32): cable, a hazard-striped hoist block with a red light, three prongs."""
    c = Canvas(24, 32)
    o = CL["o"]
    c.rect(11, 0, 12, 9, CL["g"])          # cable
    c.vline(11, 0, 9, CL["l"])
    c.rect(5, 9, 18, 17, o)               # hoist block
    c.rect(6, 10, 17, 16, CL["y"])
    for x in range(6, 18):
        for y in range(10, 17):
            if (x + y) % 6 < 3:
                c.set(x, y, CL["k"])
    c.rect(9, 11, 14, 14, o)
    c.rect(10, 12, 13, 13, CL["g"])
    c.rect(11, 12, 12, 12, CL["R"])
    c.rect(7, 17, 16, 19, o)              # hub
    c.rect(8, 18, 15, 18, CL["l"])
    if closed:
        prongs = [[(8, 19), (6, 23), (7, 28), (10, 30)], [(15, 19), (17, 23), (16, 28), (13, 30)], [(11, 19), (11, 29)], [(12, 19), (12, 29)]]
    else:
        prongs = [[(8, 19), (3, 22), (1, 27), (3, 31)], [(15, 19), (20, 22), (22, 27), (20, 31)], [(11, 19), (11, 27)], [(12, 19), (12, 27)]]
    lay = Canvas(24, 32)
    for pts in prongs:
        for a, b in zip(pts, pts[1:]):
            lay.line(a[0], a[1], b[0], b[1], CL["l"])
            lay.line(a[0] + 1, a[1], b[0] + 1, b[1], CL["w"] if pts[0][0] < 12 else CL["g"])
    lay.outline(o)
    c.paste(lay)
    return c


def draw_claw():
    return strip([claw(False), claw(True)])


# ======================================================================== hud
HD = {
    "o": hx(0x141018), "w": hx(0xF4F4F0), "R": hx(0xF0403A), "r": hx(0xF08A24), "g": hx(0x8A8E9A),
    "c": hx(0x4FD6E8), "y": hx(0xFFD23C), "G": hx(0x4CE070), "b": hx(0x2A62D8), "l": hx(0xB4B8C4),
}

HUD = [
    ("reticle", "SPEAR PHISH reticle, searching (grey fish hook)", [
        "......gg....",
        ".....g..g...",
        ".....g..g...",
        "........g...",
        "........g...",
        "........g...",
        "..g.....g...",
        "..gg....g...",
        "..g.g..g....",
        "...g.gg.....",
        "....g.......",
        "............",
    ]),
    ("reticle_lock", "reticle locked: red hook in corner brackets", [
        "RR...RR...RR",
        "R...R..R...R",
        ".....R.R....",
        "........R...",
        "........R...",
        "........R...",
        "..R.....R...",
        "..RR....R...",
        "..R.R..R....",
        "R..R.RR....R",
        "R...R......R",
        "RR........RR",
    ]),
    ("reticle_lock2", "reticle locked, pulse frame (brackets pulled in)", [
        "............",
        ".RR..RR..RR.",
        ".R..R..R.R..",
        ".....R.R....",
        "........R...",
        "........R...",
        "..R.....R...",
        "..RR....R...",
        ".RR.R..R..R.",
        ".R.R.RR...R.",
        ".RR.R....RR.",
        "............",
    ]),
    ("burst_pip", "BURST charge pip (a cyan bolt)", [
        "............",
        "......oo....",
        ".....oco....",
        "....occo....",
        "...occo.....",
        "..owccccco..",
        "..ooocccoo..",
        "....occo....",
        "...occo.....",
        "...oco......",
        "...oo.......",
        "............",
    ]),
    ("ammo_pip", "rear ammo pip", [
        "............",
        "............",
        "............",
        "....oooo....",
        "...oyyyyo...",
        "...oywyyo...",
        "...oyyyyo...",
        "...oyyrro...",
        "....oooo....",
        "............",
        "............",
        "............",
    ]),
    ("ack", "ACK over a car that took a hit", [
        "............",
        "............",
        "............",
        "............",
        ".GGG.GGG.G.G",
        ".G.G.G...G.G",
        ".GGG.G...GG.",
        ".G.G.G...G.G",
        ".G.G.GGG.G.G",
        "............",
        "............",
        "............",
    ]),
    ("panic_tag", "KERNEL PANIC :( over a frozen car", [
        "oooooooooooo",
        "obbbbbbbbbbo",
        "obbwbbbbwbbo",
        "obbbbbbbbbbo",
        "obbbbbbbbbbo",
        "obbbwwwwbbbo",
        "obbwbbbbwbbo",
        "obbbbbbbbbbo",
        "oooooooooooo",
        ".....ob.....",
        "......o.....",
        "............",
    ]),
    ("sudo_tag", "SUDO # over a rooted car", [
        "...oo..oo...",
        "...oyo.oyo..",
        ".oooyoooyoo.",
        ".oyyyyyyyyo.",
        ".ooyoooyooo.",
        "..oyo.oyo...",
        ".oooyoooyoo.",
        ".oyyyyyyyyo.",
        ".ooyoooyooo.",
        "..oyo.oyo...",
        "..oo..oo....",
        "............",
    ]),
    ("captcha_tag", "CAPTCHA grid over a stopped car", [
        "oooooooooooo",
        "olllolllolGo",
        "olRlolllolGo",
        "olllollloGlo",
        "oooooooooooo",
        "olllolRlollo",
        "olllolllollo",
        "olllolllollo",
        "oooooooooooo",
        "olllolllolRo",
        "oooooooooooo",
        "............",
    ]),
    ("honey_tag", "HONEYPOT ? that flickers on the fake crate", [
        "............",
        "....oooo....",
        "...orrrro...",
        "..orroorro..",
        "..oro..orro.",
        "...o..orro..",
        ".....orro...",
        ".....oro....",
        "......o.....",
        ".....oro....",
        ".....oro....",
        "......o.....",
    ]),
]


def draw_hud():
    return strip([cell(12, 12, rows, HD) for _, _, rows in HUD])
