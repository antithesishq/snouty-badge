"""The six 48x48 racer portraits (SPEC 4.1), one sheet and one palette each.

Light comes from the upper left. Every portrait has an opaque backdrop in
the racer's own colour, so it reads as a comm window at half scale over the
race view. Snouty is the study05 rig (head + torso parts from snouty-art)
with code-drawn eyepatch, strap, scar and squint layers; the other five are
code-drawn here.
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image

from .raster import BAYER4, Canvas, hx

REPO = Path(__file__).resolve().parents[4]
STUDY05 = REPO / "snouty-art" / "styles" / "study05" / "parts"

S = 48
OUT = hx(0x17121E)   # shared near-black outline (study05 OUTLINE)


def sky(cv: Canvas, top, low, horizon: int, soft: int = 3):
    """Two-band sky: `top` above the horizon row, `low` below, Bayer-dithered over +-soft rows."""
    for y in range(cv.h):
        for x in range(cv.w):
            t = (y - horizon + soft) / (2 * soft)
            th = BAYER4[y % 4][x % 4] / 16
            cv.px[y][x] = low if t > th else top


def skyline(cv: Canvas, x0: int, x1: int, tops, col):
    """A flat silhouette along the bottom: tops[i] is the top row of column x0 + i (repeats)."""
    for x in range(x0, x1 + 1):
        t = tops[(x - x0) % len(tops)]
        cv.rect(x, t, x, cv.h - 1, col)


def part(cv: Canvas, draw, ramp, cuts, sphere, out=OUT, outline=True, dither=0.0, clip_y=None):
    """Draw one shaded, outlined part: `draw(layer, colour)` fills a shape on a
    fresh layer, which is shaded with spherical normals `sphere` = (cx, cy, rx, ry)
    over `ramp`, outlined and pasted. Returns the part's pixel set."""
    layer = Canvas(cv.w, cv.h)
    draw(layer, ramp[-1])
    if clip_y is not None:
        for y in range(int(clip_y) + 1, layer.h):
            layer.px[y] = [None] * layer.w
    px = layer.mask()
    layer.shade(px, *sphere, ramp, cuts, dither=dither)
    if outline:
        layer.outline(out)
    cv.paste(layer)
    return px


# ===================================================================== SNOUTY
SN = {
    "OUT": OUT, "SHIRT_D": hx(0x29232F), "SHIRT": hx(0x42364B),
    "FUR_DEEP": hx(0x462174), "FUR_D": hx(0x662BB8), "FUR": hx(0x8E42DE), "FUR_L": hx(0xBE7AF3),
    "WHITE": hx(0xF4EFDF), "GREY": hx(0x958D9D), "RED": hx(0xEE453C), "RED_D": hx(0x91322F),
    "BG_D": hx(0x3A1E1C), "BG_L": hx(0x7A3F28), "SCAR": hx(0xF0A0B4),
}


def snouty() -> Canvas:
    p = SN
    o, w, g = p["OUT"], p["WHITE"], p["GREY"]
    fur, fur_d, fur_l, fur_deep = p["FUR"], p["FUR_D"], p["FUR_L"], p["FUR_DEEP"]
    bg = Canvas(S, S)
    sky(bg, p["BG_D"], p["BG_L"], horizon=24, soft=8)
    # the Dumps on the horizon: a ridge of dead monitors, a smoke column
    skyline(bg, 26, 47, [38, 38, 38, 36, 36, 36, 36, 39, 39, 35, 35, 35, 35, 35, 37, 37, 40, 40, 34, 34, 34, 34], p["SHIRT_D"])
    cv = bg.copy()
    rig = Image.new("RGBA", (80, 86), (0, 0, 0, 0))
    for part in ("torso", "head"):
        rig.alpha_composite(Image.open(STUDY05 / f"{part}.png").convert("RGBA"))
    body = Canvas.from_image(rig.crop((30, 11, 78, 59)))
    head = {(x, y) for (x, y) in body.mask() if body.px[y][x] in (fur, fur_d, fur_l, fur_deep)}
    cv.paste(body)
    # ---- the glasses temple that ran back from the near eye becomes fur
    for x in range(12, 19):
        if cv.get(x, 18) == o:
            cv.set(x, 18, fur_d if x < 16 else fur)
    # ---- the squinting far eye, in what is left of the far lens
    far = [
        "bbooooob",
        "boDDDDoo",
        "oddooooo",
        "odowwkgo",
        "odfoooog",
        "odffffgo",
        "odfffllo",
    ]
    cmap = {"o": o, "D": fur_deep, "d": fur_d, "f": fur, "l": fur_l, "w": w, "k": o, "g": g}
    for j, row in enumerate(far):
        for i, ch in enumerate(row):
            x, y = 28 + i, 14 + j
            cv.set(x, y, bg.get(x, y) if ch == "b" else cmap[ch])
    # ---- the eyepatch over the near eye (stage left of the face)
    patch = [
        "...ooooo...",
        "..oxxxxxoo.",
        ".oxssxxxxo.",
        ".oxsxxxxxxo",
        "oxxxxxxxxxo",
        "oxxxxxxxxxo",
        "oxxxxxxxxxo",
        ".oxxxxxxxo.",
        ".ooxxxxxoo.",
        "...ooooo...",
    ]
    cv.stamp(patch, 18, 13, {"o": o, "x": p["SHIRT_D"], "s": p["SHIRT"]})
    # strap: back under the ear, and up across the brow; only on the head
    on_head = lambda x, y: (x, y) in head
    for (x0, y0, x1, y1) in [(18, 17, 8, 13), (18, 18, 8, 14), (23, 13, 26, 6), (24, 13, 27, 6)]:
        cv.line(x0, y0, x1, y1, o, clip=on_head)
    # ---- the scar under the patch, with stitches
    sc = p["SCAR"]
    cv.line(21, 23, 24, 28, sc, clip=on_head)
    for (x, y) in ((20, 25), (22, 24), (21, 27), (23, 26)):
        cv.set(x, y, sc)
    return cv


# ===================================================================== LEGACY
LG = {
    "OUT": OUT, "BG_D": hx(0x0B1E14), "BG_L": hx(0x1E4A2C),
    "HAT_D": hx(0x4A3A2C), "HAT": hx(0x76604A), "HAT_L": hx(0xA48A68),
    "SKIN_D": hx(0x93604A), "SKIN": hx(0xC88C6A), "SKIN_L": hx(0xE8B48E),
    "BEARD_D": hx(0x8C8C98), "BEARD": hx(0xBEBEC8), "BEARD_L": hx(0xE8E8F0),
    "PAPER": hx(0xF2E6C0), "SHIRT": hx(0x5E7EA0), "RED": hx(0xC8403A),
}


def legacy() -> Canvas:
    import random
    p = LG
    o = p["OUT"]
    cv = Canvas(S, S, p["BG_D"])
    # a green-screen terminal behind him: rows of old code
    rng = random.Random(1964)
    for y in range(2, S, 3):
        x = 2 + rng.randrange(3)
        while x < S - 2:
            n = rng.randrange(2, 7)
            cv.hline(x, min(S - 3, x + n - 1), y, p["BG_L"])
            x += n + rng.randrange(1, 4)
    skin = [p["SKIN_D"], p["SKIN"], p["SKIN_L"]]
    beard = [p["BEARD_D"], p["BEARD"], p["BEARD_L"]]
    hat = [p["HAT_D"], p["HAT"], p["HAT_L"]]
    # cardigan shoulders and shirt collar
    part(cv, lambda l, c: l.poly([(2, 48), (6, 39), (16, 35), (32, 35), (42, 39), (46, 48)], c),
         hat, [0.3, 0.75], (24, 30, 26, 22))
    cv.poly([(17, 36), (24, 44), (31, 36)], p["SHIRT"])
    # pocket protector with pens, on the cardigan's left breast
    cv.rect(35, 41, 39, 46, p["SHIRT"])
    cv.vline(36, 39, 41, p["RED"])
    cv.vline(38, 38, 41, p["PAPER"])
    # ears and face
    for ex in (12.5, 35.5):
        part(cv, lambda l, c, ex=ex: l.ellipse(ex, 25, 2.6, 3.6, c), skin, [0.3, 0.75], (ex, 24, 3, 4))
    face = part(cv, lambda l, c: l.ellipse(24, 25, 11.5, 12, c), skin, [0.25, 0.7], (22, 21, 14, 15))
    # the beard, wide and long, and the moustache
    def beard_shape(l, c):
        l.poly([(12, 27), (14, 36), (18, 43), (24, 46), (30, 43), (34, 36), (36, 27), (31, 32), (24, 33), (17, 32)], c)
        for (bx, by, r) in ((13, 31, 2.5), (15, 37, 3), (19, 42, 3), (24, 44, 3), (29, 42, 3), (33, 37, 3), (35, 31, 2.5)):
            l.ellipse(bx, by, r, r, c)
    part(cv, beard_shape, beard, [0.25, 0.62], (24, 33, 13, 14), dither=0.12)
    part(cv, lambda l, c: (l.ellipse(20.5, 31.5, 4.5, 2.2, c), l.ellipse(27.5, 31.5, 4.5, 2.2, c)),
         beard, [0.2, 0.6], (24, 30, 9, 4))
    cv.hline(21, 27, 35, o)  # the frown under the moustache
    cv.set(20, 36, o)
    cv.set(28, 36, o)
    # bulbous nose
    part(cv, lambda l, c: l.ellipse(24, 27.5, 3.2, 3, c), skin, [0.3, 0.7], (23, 26.5, 3.5, 3.5))
    cv.set(23, 26, p["PAPER"])
    # bifocals: thick frames, magnified eyes, the reading line across each lens
    for lx in (13, 26):
        cv.rect(lx, 18, lx + 8, 25, o)
        cv.rect(lx + 1, 19, lx + 7, 24, p["PAPER"])
        cv.ellipse(lx + 4.5, 21, 2.2, 2.2, p["SHIRT"])
        cv.rect(lx + 4, 20, lx + 5, 21, o)              # big pupils
        cv.hline(lx + 1, lx + 7, 19, p["SKIN_D"])      # heavy lids
        cv.hline(lx + 1, lx + 7, 23, o)                # bifocal line
        cv.hline(lx + 1, lx + 7, 24, p["BEARD_L"])
        cv.set(lx + 1, 20, p["BEARD_L"])               # glint
    cv.hline(22, 25, 20, o)  # bridge
    # bushy brows, low and slanting down to the middle: grumpy
    brow = [
        "LLL.......",
        "LLLLLL....",
        ".BLLLLLLL.",
        "...BBLLLLL",
        "......BBB.",
    ]
    cv.stamp(brow, 12, 14, {"L": p["BEARD_L"], "B": p["BEARD_D"]})
    cv.stamp(brow, 27, 14, {"L": p["BEARD_L"], "B": p["BEARD_D"]}, flip=True)
    # the fedora, a punch card in the band
    dy = -2
    part(cv, lambda l, c: l.ellipse(24, 14.5 + dy, 20.5, 3, c), hat, [0.2, 0.55], (24, 12 + dy, 22, 8))
    part(cv, lambda l, c: l.poly([(11, 14 + dy), (13, 4 + dy), (19, 2 + dy), (24, 4 + dy), (29, 2 + dy), (35, 4 + dy), (37, 14 + dy)], c),
         hat, [0.3, 0.7], (24, 8 + dy, 16, 12))
    cv.rect(12, 11 + dy, 36, 13 + dy, p["HAT_D"])
    cv.hline(12, 36, 10 + dy, o)
    card = [(28, 12 + dy), (30, 0), (38, 1), (35, 13 + dy)]
    cv.poly(card, p["PAPER"])
    cv.polyline(card + [card[0]], o)
    cv.line(30, 0, 31, 1, o)
    for (hx_, hy) in ((32, 2), (34, 3), (31, 5), (33, 5), (35, 6), (32, 8), (34, 9)):
        cv.rect(hx_, hy, hx_, hy + 1, p["HAT_D"])
    return cv




# ===================================================================== KIDDIE
KD = {
    "OUT": OUT, "BG_D": hx(0x0E3440), "BG_L": hx(0x1C6270),
    "SKIN_D": hx(0xC07860), "SKIN": hx(0xF0B088), "SKIN_L": hx(0xFFD8B8),
    "HAIR_D": hx(0x5A2E1A), "HAIR": hx(0x8E4A24),
    "HOOD_D": hx(0x3E7A22), "HOOD": hx(0x6CB43A), "HOOD_L": hx(0xA8E05A),
    "BRASS": hx(0xC8962E), "LENS": hx(0x2A4A3A), "WHITE": hx(0xF6F4EA), "MOUTH": hx(0x7A1E2A),
}


def kiddie() -> Canvas:
    p = KD
    o, w = p["OUT"], p["WHITE"]
    cv = Canvas(S, S, p["BG_D"])
    # backdrop: forum-banner stripes
    for y in range(S):
        for x in range(S):
            if (x + y) % 10 < 3:
                cv.px[y][x] = p["BG_L"]
    skin = [p["SKIN_D"], p["SKIN"], p["SKIN_L"]]
    hood = [p["HOOD_D"], p["HOOD"], p["HOOD_L"]]
    # hoodie: shoulders and the hood bunched round the neck
    part(cv, lambda l, c: l.poly([(1, 48), (4, 38), (13, 33), (31, 33), (40, 38), (44, 48)], c),
         hood, [0.3, 0.72], (22, 30, 26, 22))
    part(cv, lambda l, c: l.ellipse(22, 36, 13, 4.5, c), hood, [0.35, 0.8], (21, 33, 14, 7))
    cv.vline(18, 39, 44, p["WHITE"])  # drawstrings
    cv.vline(26, 39, 43, p["WHITE"])
    # ears, head
    part(cv, lambda l, c: l.ellipse(10.5, 24, 2.5, 3.5, c), skin, [0.3, 0.75], (10.5, 23, 3, 4))
    part(cv, lambda l, c: l.ellipse(33.5, 24, 2.5, 3.5, c), skin, [0.3, 0.75], (33.5, 23, 3, 4))
    part(cv, lambda l, c: (l.ellipse(22, 23, 11.5, 11, c), l.ellipse(22, 28, 9, 6, c)),
         skin, [0.22, 0.68], (20, 20, 14, 14))
    # messy hair: spikes over the forehead
    hair = [p["HAIR_D"], p["HAIR"]]
    def hair_shape(l, c):
        l.ellipse(22, 12.5, 12.5, 6, c)
        for (x0, y0, x1, y1, x2, y2) in ((9, 14, 6, 6, 14, 9), (14, 9, 13, 1, 20, 7), (19, 7, 22, 0, 25, 7),
                                         (24, 7, 31, 1, 29, 9), (29, 9, 38, 5, 34, 14), (33, 13, 38, 17, 34, 18)):
            l.poly([(x0, y0), (x1, y1), (x2, y2)], c)
    part(cv, hair_shape, hair, [0.45], (20, 10, 14, 10))
    # welding goggles pushed up on the forehead, strap round the hair
    cv.rect(9, 12, 35, 13, o)
    for gx in (16, 28):
        cv.ellipse(gx, 12.5, 5, 4.5, o)
        cv.ellipse(gx, 12.5, 4, 3.5, p["BRASS"])
        cv.ellipse(gx, 12.5, 2.6, 2.3, p["LENS"])
        cv.set(gx - 1, 11, w)
        cv.set(gx, 11, w)
    cv.rect(21, 12, 23, 13, p["BRASS"])
    # eyebrows up, eyes wide
    eye = [
        ".oo.",
        "owwo",
        "owko",
        "okko",
        ".oo.",
    ]
    for ex in (16, 28):
        cv.stamp([".ooo", "o..."], ex - 2, 16, {"o": p["HAIR_D"]})
        cv.stamp(eye, ex - 2, 18, {"o": o, "w": w, "k": o})
    # freckles and nose
    for (fx, fy) in ((13, 24), (15, 25), (29, 24), (31, 25)):
        cv.set(fx, fy, p["SKIN_D"])
    cv.set(22, 24, p["SKIN_D"])
    cv.set(21, 25, p["SKIN_D"])
    cv.hline(22, 23, 25, p["SKIN_D"])
    # the gap-tooth grin
    mouth = [
        ".ooooooooooooo.",
        "owwwwwwowwwwwwo",
        "owwwwwwowwwwwwo",
        ".ommmmmmmmmmmo.",
        "..ommmmmmmmmo..",
        "...ooooooooo...",
    ]
    cv.stamp(mouth, 15, 27, {"o": o, "w": w, "m": p["MOUTH"]})
    cv.set(14, 26, o)
    cv.set(30, 26, o)
    # the thumbs-up, a plaster on the stump of a finger
    def fist(l, c):
        l.rect(34, 34, 44, 44, c)
        l.ellipse(39, 44, 5.5, 3, c)
        l.rect(36, 24, 40, 34, c)
        l.ellipse(38, 24.5, 2.6, 2.4, c)
    part(cv, fist, skin, [0.3, 0.72], (36, 32, 10, 14))
    for fy in (37, 40, 43):
        cv.hline(34, 41, fy, p["SKIN_D"])
    cv.rect(41, 36, 44, 38, w)  # plaster on the short finger
    cv.set(42, 37, p["SKIN_D"])
    return cv



# =================================================================== SYSADMIN
SA = {
    "OUT": OUT, "BG_D": hx(0x10162E), "BG_L": hx(0x222E56),
    "SKIN_D": hx(0x6A3E2C), "SKIN": hx(0x986444), "SKIN_L": hx(0xC08A62),
    "HAIR_D": hx(0x2A1C24), "HAIR": hx(0x4C3442), "BAGS": hx(0x4A2838),
    "FLAN_D": hx(0x6A1E22), "FLAN": hx(0xB0363A), "GREY": hx(0xA8A8B4), "WHITE": hx(0xF0F0F4),
    "LED": hx(0x4CE070), "AMBER": hx(0xF0B830),
}


def sysadmin() -> Canvas:
    p = SA
    o, w, g = p["OUT"], p["WHITE"], p["GREY"]
    cv = Canvas(S, S, p["BG_D"])
    # backdrop: two server racks with their blinkenlights
    for (x0, x1) in ((0, 9), (37, 47)):
        cv.rect(x0, 0, x1, S - 1, p["BG_L"])
        for y in range(2, S, 4):
            cv.hline(x0 + 1, x1 - 1, y, p["BG_D"])
            cv.set(x0 + 2 + (y * 7) % 4, y + 1, p["LED"] if (y // 4) % 3 else p["AMBER"])
            cv.set(x1 - 2 - (y * 5) % 3, y + 2, p["LED"])
    skin = [p["SKIN_D"], p["SKIN"], p["SKIN_L"]]
    hair = [p["HAIR_D"], p["HAIR"]]
    flan = [p["FLAN_D"], p["FLAN"]]
    # flannel shoulders, a plaid by rows and columns
    sh = part(cv, lambda l, c: l.poly([(1, 48), (5, 38), (15, 34), (29, 34), (39, 38), (43, 48)], c),
              [p["FLAN"]], [], (22, 30, 26, 22))
    for (x, y) in sh:
        vx, hy = (x + 1) % 6 in (0, 1), y % 6 in (0, 1)
        if vx or hy:
            cv.set(x, y, o if (vx and hy) else p["FLAN_D"])
    cv.poly([(17, 35), (22, 41), (27, 35)], p["SKIN_D"])  # open collar
    # hair behind the head, the bun on top with a pencil through it
    def back_hair(l, c):
        l.ellipse(22, 21, 13, 14, c)
        l.rect(9, 21, 35, 34, c)
    part(cv, back_hair, hair, [0.5], (20, 18, 16, 16))
    # face
    part(cv, lambda l, c: (l.ellipse(22, 24, 10, 11.5, c), l.ellipse(22, 29, 7.5, 6, c)),
         skin, [0.22, 0.66], (20, 21, 13, 14))
    # fringe: a few tired strands across the forehead
    part(cv, lambda l, c: l.poly([(11, 21), (13, 13), (22, 10), (31, 13), (33, 21), (29, 16), (24, 15), (20, 17), (15, 16)], c),
         hair, [0.5], (20, 12, 12, 8), outline=False)
    cv.line(12, 21, 11, 27, p["HAIR"])  # loose strands
    cv.line(32, 21, 33, 26, p["HAIR"])
    # half-lidded eyes with bags under them
    for ex in (17, 27):
        cv.hline(ex - 3, ex + 2, 20, o)
        cv.hline(ex - 3, ex + 2, 21, p["SKIN_D"])
        cv.stamp(["owwkkw", ".owkko"], ex - 3, 22, {"o": o, "w": w, "k": o})
        cv.stamp([".bbbb.", "..bb.."], ex - 3, 24, {"b": p["BAGS"]})
    # nose and a flat, done-with-it mouth
    cv.line(22, 23, 21, 27, p["SKIN_D"])
    cv.hline(21, 23, 28, p["SKIN_D"])
    cv.hline(19, 25, 31, o)
    cv.set(26, 32, o)
    # headset: band over the head, cups, the mic boom to the mouth
    for r in (0, 1):
        for x in range(9, 36):
            t = (x - 22) / 13
            if abs(t) <= 1:
                cv.set(x, int(round(21 - (1 - t * t) ** 0.5 * (14 - r))), o if r == 0 else g)
    part(cv, lambda l, c: l.ellipse(22, 5.5, 6, 4.5, c), hair, [0.45], (21, 4, 7, 6))  # the bun
    cv.line(13, 1, 31, 9, p["AMBER"])  # a pencil through it
    cv.line(13, 2, 31, 10, p["AMBER"])
    cv.rect(12, 1, 13, 2, p["FLAN"])
    cv.set(32, 10, o)
    for cx_ in (9, 32):
        part(cv, lambda l, c, cx_=cx_: l.rect(cx_, 20, cx_ + 3, 28, c), [p["HAIR_D"], g], [0.5], (cx_, 22, 4, 6))
    cv.polyline([(11, 28), (12, 31), (15, 33), (18, 33)], o)
    cv.rect(17, 32, 19, 34, g)
    cv.rect(17, 32, 19, 32, o)
    # the mug: white enamel, a skull on it, steam
    def mug(l, c):
        l.rect(31, 36, 41, 47, c)
        l.ellipse(36, 36, 5.5, 1.6, c)
    part(cv, mug, [g, w], [0.45], (33, 38, 10, 14))
    for yy in (39, 40, 41, 42, 43, 44):
        cv.set(43, yy, o)
    cv.hline(41, 43, 38, o)
    cv.hline(41, 43, 45, o)
    cv.hline(32, 40, 35, p["HAIR_D"])  # the coffee
    skull = [
        ".ooo.",
        "ooooo",
        "o.o.o",
        "ooooo",
        ".o.o.",
    ]
    cv.stamp(skull, 34, 39, {"o": o})
    for (sx, phase) in ((34, 0), (38, 2)):
        for k in range(8):
            y = 33 - k
            x = sx + (1 if (k + phase) % 4 in (1, 2) else 0)
            cv.set(x, y, w if k < 6 else g)
    return cv



# ==================================================================== ROOTKIT
RK = {
    "BLACK": hx(0x050607), "OUT": hx(0x0C0E10), "BG": hx(0x0A1410), "CODE_D": hx(0x123A22), "CODE": hx(0x1E6A36),
    "HOOD_D": hx(0x1A1C22), "HOOD": hx(0x2C2F38), "HOOD_L": hx(0x464A58),
    "GLOW": hx(0x1E8C3A), "EYE": hx(0x52F070), "EYE_L": hx(0xD8FFD8), "SMIRK": hx(0x8A9098), "METAL": hx(0xB4B8C4),
}


def rootkit() -> Canvas:
    import random
    p = RK
    o = p["OUT"]
    cv = Canvas(S, S, p["BG"])
    # falling code behind: dim columns with a bright head
    rng = random.Random(0x7007)
    for x in range(1, S, 3):
        y0 = rng.randrange(-20, S)
        n = rng.randrange(6, 18)
        for k in range(n):
            y = y0 + k * 2
            if 0 <= y < S:
                cv.set(x, y, p["CODE"] if k == n - 1 else p["CODE_D"])
    hood = [p["HOOD_D"], p["HOOD"], p["HOOD_L"]]
    # cloak shoulders
    part(cv, lambda l, c: l.poly([(0, 48), (2, 40), (12, 34), (34, 34), (44, 40), (47, 48)], c),
         hood, [0.3, 0.7], (22, 30, 26, 22), out=o)
    # the hood: a point at the top, falling wide to the shoulders
    def hood_shape(l, c):
        l.poly([(24, 1), (32, 6), (38, 16), (40, 30), (38, 42), (10, 42), (8, 30), (10, 16), (16, 6)], c)
    part(cv, hood_shape, hood, [0.28, 0.66], (21, 16, 18, 22), out=o)
    # fold lines
    cv.line(24, 2, 21, 9, p["HOOD_D"])
    cv.line(37, 20, 35, 34, p["HOOD_D"])
    cv.line(11, 22, 13, 34, p["HOOD_L"])
    # the opening: a void with a lit rim on the light side
    void = Canvas(S, S)
    void.ellipse(24, 25, 9.5, 12.5, p["BLACK"])
    void.rect(15, 25, 33, 41, p["BLACK"])
    cv.paste(void)
    for (x, y) in void.mask():
        if (x - 1, y) not in void.mask() and x < 24:
            cv.set(x - 1, y, p["HOOD_L"])
    # two green eyes, a little glow round them
    for ex in (19, 28):
        cv.stamp([".ggg.", "geeeg", "eLLee", ".ggg."], ex - 1, 21, {"g": p["GLOW"], "e": p["EYE"], "L": p["EYE_L"]})
    # the smirk: lopsided, up at the right
    cv.stamp(["........s", "s......s.", ".sssss..."], 20, 30, {"s": p["SMIRK"]})
    cv.set(27, 30, p["METAL"])
    # drawstrings with metal tips
    for (x, y0, y1) in ((17, 40, 45), (31, 40, 44)):
        cv.vline(x, y0, y1, p["HOOD_L"])
        cv.set(x, y1 + 1, p["METAL"])
    return cv


# ===================================================================== BOTNET
BN = {
    "OUT": OUT, "BG_D": hx(0x3A1418), "BG_L": hx(0x8A6A1E),
    "SKIN_D": hx(0x9C5A40), "SKIN": hx(0xD2906A), "SKIN_L": hx(0xF0BC94), "WHITE": hx(0xF4F0E8),
    "RED": hx(0xC83A3A), "YELLOW": hx(0xF0C030), "FOIL_D": hx(0x8A90A0), "FOIL": hx(0xD4DAE6),
    "BLUE": hx(0x3A6AC8), "GREEN": hx(0x4AA84A), "SHIRT": hx(0x5A3A6A),
}


FACES = {
    # eyes (left, right) as stamps at (cx-5, cy-3) and (cx+2, cy-3); mouth at (cx-3, cy+3)
    "blank": (["kw.", "kw."], ["kw.", "kw."], [".......", "..ooo..", "..ooo.."]),
    "sleep": (["...", "kkk"], ["...", "kkk"], [".......", "...o...", "..oro..", "...o..."]),
    "shifty": (["wk.", "wk."], ["wk.", "wk."], [".......", "...ooo.", "ooo...."]),
    "grin": (["kk.", "kk."], ["kk.", "kk."], ["ooooooo", "owwwwwo", ".ooooo."]),
}


def cousin(cv: Canvas, p, cx, cy, face):
    """One cousin: the family face (round, big round nose, ears out) and an expression."""
    o, w = p["OUT"], p["WHITE"]
    skin = [p["SKIN_D"], p["SKIN"], p["SKIN_L"]]
    part(cv, lambda l, c: (l.ellipse(cx - 7.5, cy + 1, 2, 2.6, c), l.ellipse(cx + 7.5, cy + 1, 2, 2.6, c)),
         skin, [0.3, 0.75], (cx, cy, 9, 4))
    part(cv, lambda l, c: l.ellipse(cx, cy + 0.5, 7.5, 8, c), skin, [0.12, 0.62], (cx - 2, cy - 3, 11, 11))
    le, re, mouth = FACES[face]
    cmap = {"k": o, "w": w, "o": o, "r": p["RED"]}
    cv.stamp(le, cx - 5, cy - 1, cmap)
    cv.stamp(re, cx + 2, cy - 1, cmap)
    cv.stamp(mouth, cx - 3, cy + 4, cmap)
    # the family nose
    cv.stamp([".oo.", "osso", ".oo."], cx - 2, cy + 1, {"o": p["SKIN_D"], "s": p["SKIN_L"]})


def botnet() -> Canvas:
    p = BN
    o, w = p["OUT"], p["WHITE"]
    cv = Canvas(S, S, p["BG_D"])
    # backdrop: inside the bus, the window frames
    cv.rect(0, 0, S - 1, 1, p["BG_L"])
    cv.rect(22, 0, 25, S - 1, p["BG_L"])
    cv.vline(23, 0, S - 1, p["YELLOW"])
    shirts = [p["SHIRT"], p["GREEN"], p["BLUE"], p["RED"]]
    # back row (higher), then the front row, overlapping; one asleep under a hard hat
    heads = [(12, 12, "blank", hat_beanie), (35, 11, "sleep", hat_hardhat),
             (13, 33, "shifty", hat_tinfoil), (35, 33, "grin", hat_propeller)]
    for i, (cx, cy, face, hat) in enumerate(heads):
        part(cv, lambda l, c, cx=cx, cy=cy: l.ellipse(cx, cy + 14, 11, 5, c), [p["SKIN_D"], shirts[i]], [0.2],
             (cx, cy + 12, 10, 6))
        cousin(cv, p, cx, cy, face)
        hat(cv, p, cx, cy)
    # Zz over the sleeper
    cv.stamp(["oooo", "..o.", ".o..", "oooo"], 43, 1, {"o": w})
    cv.stamp(["ooo", ".o.", "ooo"], 44, 6, {"o": w})
    return cv


def hat_beanie(cv, p, cx, cy):
    part(cv, lambda l, c: (l.ellipse(cx, cy - 5, 8, 5, c), l.rect(cx - 8, cy - 6, cx + 8, cy - 4, c)),
         [p["RED"]], [], (cx, cy - 6, 8, 5), clip_y=cy - 4)
    cv.hline(cx - 8, cx + 8, cy - 4, p["WHITE"])
    part(cv, lambda l, c: l.ellipse(cx, cy - 11, 2.5, 2.5, c), [p["WHITE"]], [], (cx, cy - 11, 3, 3))


def hat_tinfoil(cv, p, cx, cy):
    part(cv, lambda l, c: l.poly([(cx - 9, cy - 3), (cx + 1, cy - 16), (cx + 9, cy - 3)], c),
         [p["FOIL_D"], p["FOIL"]], [0.5], (cx - 2, cy - 8, 9, 8))
    for (dx, dy) in ((-3, -7), (2, -11), (4, -6)):
        cv.set(cx + dx, cy + dy, p["WHITE"])
    cv.line(cx - 4, cy - 6, cx, cy - 10, p["FOIL_D"])


def hat_hardhat(cv, p, cx, cy):
    part(cv, lambda l, c: (l.ellipse(cx, cy - 5, 7.5, 5.5, c), l.rect(cx - 10, cy - 4, cx + 10, cy - 3, c)),
         [p["BG_L"], p["YELLOW"]], [0.45], (cx - 1, cy - 7, 9, 6), clip_y=cy - 3)
    cv.vline(cx, cy - 10, cy - 5, p["BG_L"])


def hat_propeller(cv, p, cx, cy):
    part(cv, lambda l, c: (l.ellipse(cx, cy - 5, 7.5, 4.5, c), l.rect(cx - 8, cy - 5, cx + 8, cy - 4, c)),
         [p["BLUE"]], [], (cx, cy - 6, 8, 5), clip_y=cy - 4)
    cv.poly([(cx, cy - 10), (cx, cy - 5), (cx + 7, cy - 5)], p["YELLOW"])
    cv.poly([(cx, cy - 10), (cx, cy - 5), (cx - 7, cy - 5)], p["GREEN"])
    cv.vline(cx, cy - 13, cy - 9, p["OUT"])
    cv.hline(cx - 5, cx + 5, cy - 14, p["RED"])
    cv.set(cx, cy - 14, p["OUT"])


HATS = [hat_beanie, hat_tinfoil, hat_hardhat, hat_propeller]



PORTRAITS = [("snouty", snouty), ("legacy", legacy), ("kiddie", kiddie), ("sysadmin", sysadmin), ("rootkit", rootkit), ("botnet", botnet)]
