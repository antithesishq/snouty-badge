#!/usr/bin/env python3
"""Generate the shore texture (PLAN.md "M2 Materials and shore", "M2.2").

Run from the cart directory:  python3 tools/gen_shore.py

Writes, deterministically:
  cart/src/shore_texels.bin   256x48 4-bit indices, two per byte, low nibble = even u
  cart/src/shore_data.zig     palette (linear RGB) + @embedFile of the texels
  tools/shore_palette.json    the same palette for reference.py
  docs/shore_texture.png      4x preview, transparent shown as magenta

Everything is drawn in code except Snouty, who is downscaled 3:1 from the
run study's reference pose (../snouty-run/assets/Snouty_Run_Study_05/
assets/reference_on_grid.png) and recoloured to this palette. Needs Pillow
only for reading that PNG and writing the preview.

Content, left to right as seen from the lake (M2.2):
  u   3..72   jetty, Snouty standing on it (u 22..45)
  u  52..80   Stanley Park treeline at the waterline
  u  60..76   the Lions' twin peaks, top of the hazy North Shore band that
              runs behind everything
  u  78..107  West End towers, plain building mass (the 3D Iris logo stood
              in front of u 80..104 until it moved right of the skyline)
  u 108..113  the Living Shangri-La, the tallest and slimmest tower
  u 114..223  the downtown glass towers catching the sun, "ADRIAN HATCH"
              over "ANTITHESIS" in front of their shaded lower floors
  u 224..237  Harbour Centre: saucer and mast
  u 238..255  Canada Place's white sails at the waterline, the 3D Iris logo
              standing in front of them (x = -13.5)

Design notes: the texture is point-sampled at about one texel per pixel at
best and mostly seen upside down in rippling water, so everything is at
least two texels thick and colours are few and far apart. The tracer
mirrors u, so this is drawn the normal way round (u = 0 is the left edge
as seen from the lake). The shore is front-lit by the low sun behind the
camera (a little to the left: +x is small u), in front of a sunset sky
(horizon (1.00, 0.55, 0.25) going pink higher up): towers have lit left
faces and shaded right edges, glass glows gold, the lower city is in
shade, the mountains are a hazy dusk purple, the title is light cream
outlined in near-black. Palette values are linear RGB and already lit.
"""

import json
import os
import random

from PIL import Image

W, H = 256, 48
HERE = os.path.dirname(os.path.abspath(__file__))
CART = os.path.dirname(HERE)
SNOUTY_SRC = os.path.join(
    CART, "..", "snouty-run", "assets", "Snouty_Run_Study_05", "assets", "reference_on_grid.png"
)

# ---------------------------------------------------------------- palette
# Linear RGB in [0, 1], already lit (the tracer applies no shading).
T = 0  # transparent
TREE = 1        # Stanley Park foliage
BROWN_LIT = 2   # sun-warmed tree rims and lit wood
CONCRETE = 3    # lit concrete (Harbour Centre, West End), Canada Place pier
WOOD_DARK = 4   # wood in shade, wet mud
GLASS_LIT = 5   # glass catching the low sun
SAND = 6        # lit sand, seawall, Snouty's net
GLASS_DARK = 7  # glass in shade, the lower city
CREAM, INK = 8, 9
PURPLE, PURPLE_LIT, PURPLE_DARK = 10, 11, 12
RED = 13
HAZE = 14       # North Shore mountains
WHITE = 15      # eye white, Canada Place's sails

PALETTE = [
    (0.0, 0.0, 0.0),        # 0  transparent (unused)
    (0.035, 0.065, 0.025),  # 1  tree
    (0.400, 0.210, 0.070),  # 2  lit rim / lit wood
    (0.800, 0.560, 0.420),  # 3  lit concrete
    (0.090, 0.040, 0.018),  # 4  wood dark / mud
    (1.000, 0.480, 0.120),  # 5  glass, lit gold
    (0.720, 0.420, 0.180),  # 6  sand, lit
    (0.045, 0.065, 0.130),  # 7  glass in shade, lower city
    (1.000, 0.860, 0.560),  # 8  title cream
    (0.010, 0.008, 0.012),  # 9  ink / outline / shirt
    (0.200, 0.050, 0.460),  # 10 Snouty purple
    (0.420, 0.170, 0.700),  # 11 Snouty purple, lit
    (0.070, 0.020, 0.170),  # 12 Snouty purple, shade
    (0.800, 0.070, 0.035),  # 13 logo red
    (0.580, 0.310, 0.340),  # 14 mountain haze
    (0.900, 0.840, 0.700),  # 15 white
]
assert len(PALETTE) == 16

# Snouty's sRGB source palette (Snouty_Run_Study_05/snouty_palette.gpl) -> ours.
SNOUTY_MAP = {
    (0x17, 0x12, 0x1E): INK,
    (0x29, 0x23, 0x2F): INK,
    (0x42, 0x36, 0x4B): INK,
    (0x46, 0x21, 0x74): PURPLE_DARK,
    (0x66, 0x2B, 0xB8): PURPLE,
    (0x8E, 0x42, 0xDE): PURPLE_LIT,
    (0xBE, 0x7A, 0xF3): PURPLE_LIT,
    (0xF4, 0xEF, 0xDF): WHITE,
    (0x95, 0x8D, 0x9D): WHITE,
    (0xEE, 0x45, 0x3C): RED,
    (0x91, 0x32, 0x2F): RED,
    (0x60, 0x39, 0x1F): WOOD_DARK,
    (0x99, 0x62, 0x2F): BROWN_LIT,
    (0xCD, 0x93, 0x4B): SAND,
    (0xF0, 0xC3, 0x7C): SAND,
}

# ---------------------------------------------------------------- canvas
tex = [[T] * W for _ in range(H)]


def put(u, v, i):
    if 0 <= u < W and 0 <= v < H:
        tex[v][u] = i


def get(u, v):
    if 0 <= u < W and 0 <= v < H:
        return tex[v][u]
    return T


def rect(u0, v0, u1, v1, i):
    """Fill [u0, u1) x [v0, v1)."""
    for v in range(v0, v1):
        for u in range(u0, u1):
            put(u, v, i)


# ---------------------------------------------------------------- layout
JETTY_U0, JETTY_U1 = 3, 72      # deck extent
DECK_V = 42                     # deck top row (2 rows thick)
LAND_U0 = 60                    # where the bank starts
SHORE_V = 45                    # shoreline strip rows 45..47
SNOUTY_U0 = 22                  # left column of Snouty's 24-wide cell
LINE1_V, LINE2_V = 17, 31       # top rows of "ADRIAN HATCH", "ANTITHESIS"
TEXT_U0, TEXT_U1 = 108, 237     # the names stay inside [108, 237)
LOGO_U0, LOGO_U1, LOGO_V0 = 80, 105, 22   # plain area behind the 3D logo

rng = random.Random(0x5A0071)

# ---------------------------------------------------------------- mountains
# A hazy band behind everything: a low ridge, rising toward the Lions'
# twin peaks above Stanley Park, drifting down to the right.
ridge = [0] * W
for u in range(W):
    x = u / W
    v = 27.0 - 3.0 * x
    v -= 2.0 * max(0.0, 1.0 - abs(u - 70) / 40.0)      # the Lions' shoulder
    v -= 2.5 * max(0.0, 1.0 - abs(u - 175) / 45.0)     # Grouse / Seymour
    ridge[u] = v
# the Lions: two blunt rock peaks, 3 texels wide at the top
for c in (64, 72):
    for u in range(c - 8, c + 9):
        d = max(0, abs(u - c) - 1)
        if 0 <= u < W:
            ridge[u] = min(ridge[u], 14 + d * 1.4)
# stepped by two rows so the slope stays chunky
for u in range(W):
    r = int(round(ridge[u]))
    for v in range(r, SHORE_V):
        put(u, v, HAZE)

# ---------------------------------------------------------------- Stanley Park
top = [H] * W
u = 50
while u < 84:
    w = rng.randrange(6, 11)
    h = rng.randrange(7, 13)
    cx = u + w / 2.0
    peak = SHORE_V - 1 - h
    for x in range(u, u + w):
        d = abs(x + 0.5 - cx) / (w / 2.0)
        t = peak + int(d * h * 0.9) // 2 * 2
        top[x] = min(top[x], t)
    u += w - rng.randrange(1, 3)
for x in range(W):
    if not 52 <= x < 82:
        top[x] = H
for _ in range(2):
    for x in range(1, W - 1):
        a, b, c = top[x - 1], top[x], top[x + 1]
        if b < a and b < c:
            top[x] = min(a, c)
        elif b > a and b > c:
            top[x] = max(a, c)
for x in range(W):
    t = top[x]
    for v in range(max(t, 0), SHORE_V):
        put(x, v, BROWN_LIT if v - t < 2 else TREE)

# ---------------------------------------------------------------- towers


def tower(u0, w, t, style, crown=None):
    """A tower [u0, u0 + w) from row t down to the shoreline.

    lit:      gold glass face, shaded right edge, dark floor bands
    dark:     shaded glass, sunlit left edge and crown
    concrete: lit concrete, shaded right edge, dark window bands
    crown:    'step' (narrower top 4 rows), 'point' (stepped roof)
    """
    for v in range(t, SHORE_V):
        for x in range(u0, u0 + w):
            k = v - t
            xr = u0 + w - 1 - x          # 0 at the right edge
            xl = x - u0
            if crown == "step" and k < 4 and (xl < 2 or xr < 2):
                continue
            if crown == "point":
                inset = max(0, (6 - k) // 2 * 2) // 2
                if xl < inset or xr < inset:
                    continue
            if style == "lit":
                c = GLASS_DARK if xr < 2 else GLASS_LIT
                if xr >= 2 and k >= 3 and k % 6 in (4, 5):
                    c = GLASS_DARK
            elif style == "dark":
                c = GLASS_LIT if (xl < 2 or k < 2) else GLASS_DARK
            else:
                c = GLASS_DARK if xr < 2 else CONCRETE
                if xr >= 2 and k >= 3 and k % 5 in (3, 4):
                    c = GLASS_DARK
            put(x, v, c)


# West End (left of the logo, and above it)
tower(76, 6, 30, "concrete")
tower(82, 7, 20, "lit")
tower(90, 6, 16, "concrete")
tower(97, 8, 12, "dark", "step")
tower(105, 3, 26, "concrete")
# downtown glass cluster behind the names (its lower floors go plain below)
CLUSTER = [
    (114, 8, 10, "dark", None),
    (122, 7, 7, "lit", "step"),
    (131, 8, 12, "concrete", None),
    (139, 7, 8, "lit", None),
    (146, 9, 4, "dark", "step"),     # Shaw Tower-ish, second tallest
    (157, 7, 9, "lit", "point"),
    (164, 8, 6, "lit", None),
    (174, 8, 11, "concrete", None),
    (182, 7, 7, "dark", None),
    (191, 9, 10, "lit", "step"),
    (200, 7, 13, "concrete", None),
    (207, 8, 9, "dark", None),
    (215, 8, 14, "lit", None),
]
for u0, w, t, style, crown in CLUSTER:
    tower(u0, w, t, style, crown)

# The Living Shangri-La: tallest, slimmest, lit glass with a slim crown.
SHANGRI_U0 = 108
tower(SHANGRI_U0, 6, 0, "lit", "step")

# Behind the names the city's lower floors are in shade: plain.
for v in range(LINE1_V - 1, SHORE_V):
    for x in range(114, 225):
        put(x, v, GLASS_DARK)

# The logo stands in front here: plain building mass, no detail.
for v in range(LOGO_V0, SHORE_V):
    for x in range(LOGO_U0, LOGO_U1):
        if get(x, v) not in (T, HAZE, TREE, BROWN_LIT):
            put(x, v, GLASS_DARK)

# ---------------------------------------------------------------- Harbour Centre
HC_C = 231  # centre column (between 230 and 231)
rect(228, 14, 234, SHORE_V, GLASS_DARK)          # shaft, shaded
rect(228, 14, 230, SHORE_V, CONCRETE)            # its sunlit left side
rect(230, 16, 232, SHORE_V, GLASS_LIT)           # glass elevators catch the sun
rect(223, 8, 239, 10, CONCRETE)                  # saucer rim, lit
rect(224, 10, 238, 12, GLASS_DARK)               # observation deck windows
rect(226, 12, 236, 14, GLASS_DARK)               # underside, in shade
rect(230, 1, 232, 8, GLASS_DARK)                 # mast
rect(229, 6, 233, 8, GLASS_DARK)                 # mast base

# ---------------------------------------------------------------- Canada Place
rect(237, 40, W, SHORE_V, CONCRETE)              # pier building
rect(237, 42, W, 44, GLASS_DARK)                 # its window band
for c in (240, 244, 248, 252):         # four 4-wide tents, 2-wide tips
    for x in range(c - 2, c + 2):
        d = int(abs(x + 0.5 - c))       # 0 for the tip pair, 1 outside
        peak = 31 + (c // 4 % 2)
        for v in range(peak + 3 * d, 40):
            put(x, v, WHITE)

# ---------------------------------------------------------------- shoreline
for x in range(LAND_U0 - 4, W):
    put(x, SHORE_V, SAND)
    put(x, SHORE_V + 1, SAND if (x // 5) % 3 else WOOD_DARK)
    put(x, SHORE_V + 2, WOOD_DARK)
for _ in range(14):
    x = rng.randrange(LAND_U0, 80)
    rect(x, SHORE_V, x + 2, SHORE_V + 1, WOOD_DARK)

# ---------------------------------------------------------------- jetty
rect(JETTY_U0, DECK_V, JETTY_U1, DECK_V + 1, BROWN_LIT)
rect(JETTY_U0, DECK_V + 1, JETTY_U1, DECK_V + 2, WOOD_DARK)
for px in range(JETTY_U0 + 1, JETTY_U1 - 2, 11):
    rect(px, DECK_V + 2, px + 3, H, WOOD_DARK)
    rect(px, DECK_V + 2, px + 1, H, BROWN_LIT)
# mooring bollard at the tip
rect(JETTY_U0 + 1, DECK_V - 3, JETTY_U0 + 4, DECK_V, WOOD_DARK)
rect(JETTY_U0 + 1, DECK_V - 3, JETTY_U0 + 2, DECK_V, BROWN_LIT)
# plank seams on the deck face
for sx in range(JETTY_U0 + 6, JETTY_U1, 6):
    put(sx, DECK_V + 1, INK)

# ---------------------------------------------------------------- Snouty


def load_snouty():
    im = Image.open(SNOUTY_SRC).convert("RGBA")
    bbox = im.getbbox()
    im = im.crop(bbox)
    sw, sh = im.size
    px = im.load()
    cw, ch = (sw + 2) // 3, (sh + 2) // 3
    out = [[T] * cw for _ in range(ch)]
    # priority for ties: details that would vanish win over body fill
    prio = {INK: 1, PURPLE: 2, PURPLE_LIT: 3, PURPLE_DARK: 2, SAND: 3, WOOD_DARK: 2,
            BROWN_LIT: 3, RED: 6, WHITE: 6}
    for cy in range(ch):
        for cx in range(cw):
            votes = {}
            opaque = 0
            for dy in range(3):
                for dx in range(3):
                    x, y = cx * 3 + dx, cy * 3 + dy
                    if x >= sw or y >= sh:
                        continue
                    r, g, b, a = px[x, y]
                    if a < 128:
                        continue
                    opaque += 1
                    i = SNOUTY_MAP.get((r, g, b))
                    if i is None:
                        i = min(SNOUTY_MAP.items(),
                                key=lambda kv: sum((p - q) ** 2 for p, q in zip(kv[0], (r, g, b))))[1]
                    votes[i] = votes.get(i, 0) + 1
            if opaque >= 4:
                out[cy][cx] = max(votes, key=lambda i: (votes[i] * 2 + prio.get(i, 0), -i))
    return out


snouty = load_snouty()
sh_h, sh_w = len(snouty), len(snouty[0])
feet_v = DECK_V - 1
sv0 = feet_v - (sh_h - 1)
# The 3:1 reduction loses the source's 1-pixel outline; redraw one in ink
# around the silhouette so he stays crisp against the sky and in ripples.
for cy in range(sh_h):
    for cx in range(sh_w):
        if snouty[cy][cx] != T:
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                x, y = SNOUTY_U0 + cx + dx, sv0 + cy + dy
                if y < DECK_V and get(x, y) in (T, HAZE):
                    put(x, y, INK)
for cy in range(sh_h):
    for cx in range(sh_w):
        i = snouty[cy][cx]
        if i != T:
            put(SNOUTY_U0 + cx, sv0 + cy, i)

# ---------------------------------------------------------------- names
FONT = {
    "A": [".######.", "########", "##....##", "##....##", "##....##", "##....##",
          "########", "########", "##....##", "##....##", "##....##", "##....##"],
    "C": [".######.", "########", "##....##", "##......", "##......", "##......",
          "##......", "##......", "##......", "##....##", "########", ".######."],
    "D": ["######..", "#######.", "##...###", "##....##", "##....##", "##....##",
          "##....##", "##....##", "##....##", "##...###", "#######.", "######.."],
    "E": ["########", "########", "##......", "##......", "##......", "######..",
          "######..", "##......", "##......", "##......", "########", "########"],
    "H": ["##....##", "##....##", "##....##", "##....##", "##....##", "########",
          "########", "##....##", "##....##", "##....##", "##....##", "##....##"],
    "I": ["########", "########", "...##...", "...##...", "...##...", "...##...",
          "...##...", "...##...", "...##...", "...##...", "########", "########"],
    "N": ["##....##", "###...##", "####..##", "####..##", "##.##.##", "##.##.##",
          "##.##.##", "##..####", "##..####", "##...###", "##....##", "##....##"],
    "R": ["#######.", "########", "##....##", "##....##", "##....##", "########",
          "#######.", "##..##..", "##..###.", "##...##.", "##...###", "##....##"],
    "S": [".######.", "########", "##....##", "##......", "##......", "#######.",
          ".#######", "......##", "......##", "##....##", "########", ".######."],
    "T": ["########", "########", "...##...", "...##...", "...##...", "...##...",
          "...##...", "...##...", "...##...", "...##...", "...##...", "...##..."],
}
for g in FONT.values():
    assert len(g) == 12 and all(len(r) == 8 for r in g)


def text_cells(s, v0):
    width = len(s) * 9 - 1
    u0 = (TEXT_U0 + TEXT_U1 - width) // 2
    assert TEXT_U0 <= u0 - 1 and u0 + width + 1 <= TEXT_U1
    cells = set()
    for k, ch in enumerate(s):
        if ch == " ":
            continue
        for gy, row in enumerate(FONT[ch]):
            for gx, c in enumerate(row):
                if c == "#":
                    cells.add((u0 + k * 9 + gx, v0 + gy))
    return cells


cells = text_cells("ADRIAN HATCH", LINE1_V) | text_cells("ANTITHESIS", LINE2_V)
# ink outline (8-neighbourhood) then the cream letters on top
for (x, y) in cells:
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            put(x + dx, y + dy, INK)
for (x, y) in cells:
    put(x, y, CREAM)

# ---------------------------------------------------------------- outputs


def fmt(f):
    s = repr(round(f, 4))
    return s if "." in s or "e" in s else s + ".0"


def srgb(c):
    c = max(0.0, min(1.0, c))
    c = c * 12.92 if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055
    return int(round(c * 255))


def main():
    n = W * H // 2
    data = bytearray(n)
    for v in range(H):
        for u in range(0, W, 2):
            lo, hi = tex[v][u], tex[v][u + 1]
            assert 0 <= lo < 16 and 0 <= hi < 16
            data[v * (W // 2) + u // 2] = lo | (hi << 4)
    with open(os.path.join(CART, "cart", "src", "shore_texels.bin"), "wb") as f:
        f.write(bytes(data))

    lines = [
        "//! GENERATED by tools/gen_shore.py. Do not edit.",
        '//! Shore texture, PLAN.md "Shore texture format".',
        "pub const width = %d;" % W,
        "pub const height = %d;" % H,
        "pub const palette: [16][3]f32 = .{",
    ]
    for r, g, b in PALETTE:
        lines.append("    .{ %s, %s, %s }," % (fmt(r), fmt(g), fmt(b)))
    lines += [
        "};",
        'pub const texels: *const [%d]u8 = @embedFile("shore_texels.bin");' % n,
        "",
    ]
    with open(os.path.join(CART, "cart", "src", "shore_data.zig"), "w") as f:
        f.write("\n".join(lines))

    with open(os.path.join(HERE, "shore_palette.json"), "w") as f:
        json.dump([[round(c, 4) for c in p] for p in PALETTE], f)
        f.write("\n")

    rgb = [(255, 0, 255)] + [tuple(srgb(c) for c in p) for p in PALETTE[1:]]
    img = Image.new("RGB", (W, H))
    img.putdata([rgb[tex[v][u]] for v in range(H) for u in range(W)])
    img = img.resize((W * 4, H * 4), Image.NEAREST)
    os.makedirs(os.path.join(CART, "docs"), exist_ok=True)
    img.save(os.path.join(CART, "docs", "shore_texture.png"), optimize=True)


if __name__ == "__main__":
    main()
