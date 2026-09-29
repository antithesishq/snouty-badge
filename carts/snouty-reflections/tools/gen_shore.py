#!/usr/bin/env python3
"""Generate the shore texture (PLAN.md "M2 Materials and shore").

Run from the cart directory:  python3 tools/gen_shore.py

Writes, deterministically:
  cart/src/shore_texels.bin   256x32 4-bit indices, two per byte, low nibble = even u
  cart/src/shore_data.zig     palette (linear RGB) + @embedFile of the texels
  tools/shore_palette.json    the same palette for reference.py
  docs/shore_texture.png      4x preview, transparent shown as magenta

Everything is drawn in code except Snouty, who is downscaled 3:1 from the
run study's reference pose (../snouty-run/assets/Snouty_Run_Study_05/
assets/reference_on_grid.png) and recoloured to this palette. Needs Pillow
only for reading that PNG and writing the preview.

Design notes: the texture is point-sampled at about one texel per pixel at
best and mostly seen upside down in rippling water, so everything is at
least two texels thick and colours are few and far apart. The tracer
mirrors u, so this is drawn the normal way round (u = 0 is the left edge
as seen from the lake). The shore is front-lit by the low sun behind the
camera and sits in front of a sunset sky (horizon (1.00, 0.55, 0.25)):
dark trees with warm lit rims, a light cream title outlined in near-black.
"""

import json
import os
import random

from PIL import Image

W, H = 256, 32
HERE = os.path.dirname(os.path.abspath(__file__))
CART = os.path.dirname(HERE)
SNOUTY_SRC = os.path.join(
    CART, "..", "snouty-run", "assets", "Snouty_Run_Study_05", "assets", "reference_on_grid.png"
)

# ---------------------------------------------------------------- palette
# Linear RGB in [0, 1], already lit (the tracer applies no shading).
T = 0  # transparent
TREE_DEEP, TREE_MID, TREE_LIT = 1, 2, 3
WOOD_DARK, WOOD_LIT = 4, 5
SAND, MUD = 6, 7
CREAM, INK = 8, 9
PURPLE, PURPLE_LIT, PURPLE_DARK = 10, 11, 12
RED, TAN, EYE = 13, 14, 15

PALETTE = [
    (0.0, 0.0, 0.0),        # 0  transparent (unused)
    (0.018, 0.028, 0.016),  # 1  tree deep
    (0.050, 0.080, 0.028),  # 2  tree mid
    (0.330, 0.240, 0.060),  # 3  tree lit rim (sun-warmed olive)
    (0.090, 0.040, 0.018),  # 4  wood dark
    (0.420, 0.200, 0.075),  # 5  wood lit
    (0.720, 0.420, 0.180),  # 6  sand, lit
    (0.160, 0.080, 0.040),  # 7  wet mud
    (1.000, 0.860, 0.560),  # 8  title cream
    (0.010, 0.008, 0.012),  # 9  ink / outline / shirt
    (0.200, 0.050, 0.460),  # 10 Snouty purple
    (0.420, 0.170, 0.700),  # 11 Snouty purple, lit
    (0.070, 0.020, 0.170),  # 12 Snouty purple, shade
    (0.800, 0.070, 0.035),  # 13 logo red
    (0.640, 0.330, 0.110),  # 14 net tan
    (0.900, 0.840, 0.700),  # 15 eye white
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
    (0xF4, 0xEF, 0xDF): EYE,
    (0x95, 0x8D, 0x9D): EYE,
    (0xEE, 0x45, 0x3C): RED,
    (0x91, 0x32, 0x2F): RED,
    (0x60, 0x39, 0x1F): WOOD_DARK,
    (0x99, 0x62, 0x2F): WOOD_LIT,
    (0xCD, 0x93, 0x4B): TAN,
    (0xF0, 0xC3, 0x7C): TAN,
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
DECK_V = 26                     # deck top row (2 rows thick)
LAND_U0 = 64                    # where the bank starts rising
SHORE_V = 29                    # shoreline strip rows 29..31
TEXT_U0, TEXT_V0 = 118, 14      # "ANTITHESIS" top-left
SNOUTY_U0 = 22                  # left column of Snouty's 24-wide cell

# ---------------------------------------------------------------- treeline
rng = random.Random(0x5A0071)

# Top row of the canopy per column; H means no tree there.
top = [H] * W
u = LAND_U0 + 2
while u < W + 4:
    kind = rng.choice(["pine", "pine", "round"])
    if kind == "pine":
        w = rng.randrange(7, 13)
        h = rng.randrange(17, 27)
    else:
        w = rng.randrange(10, 17)
        h = rng.randrange(15, 21)
    cx = u + w / 2.0
    base = SHORE_V - 1
    peak = base - h
    for x in range(u, u + w):
        if not 0 <= x < W:
            continue
        d = abs(x + 0.5 - cx) / (w / 2.0)  # 0 at centre, 1 at edge
        if kind == "pine":
            # stepped cone: two texel steps so edges stay chunky
            t = peak + int(d * h * 0.9) // 2 * 2
        else:
            t = peak + int(round((1.0 - (1.0 - d * d) ** 0.5) * h * 0.8))
        top[x] = min(top[x], t)
    u += w - rng.randrange(1, 4)  # slight overlap: V gaps between crowns

# The bank rises from the jetty into the trees: no canopy left of LAND_U0,
# a low grassy slope just after it.
for x in range(W):
    if x < LAND_U0:
        top[x] = H
    elif x < LAND_U0 + 6:
        top[x] = max(top[x], SHORE_V - 1 - (x - LAND_U0))

# Keep the canopy clear of the title: at least two mass rows above it.
for x in range(TEXT_U0 - 3, TEXT_U0 + 10 * 9 + 2):
    if 0 <= x < W:
        top[x] = min(top[x], TEXT_V0 - 3)

# Minimum stroke: remove 1-texel spikes and notches in the profile.
for _ in range(2):
    for x in range(1, W - 1):
        a, b, c = top[x - 1], top[x], top[x + 1]
        if b < a and b < c:
            top[x] = min(a, c)
        elif b > a and b > c:
            top[x] = max(a, c)

# Fill the tree mass with a lit rim, a mid band, then deep shade.
for x in range(LAND_U0, W):
    t = top[x]
    for v in range(max(t, 0), SHORE_V):
        depth = v - t
        if depth < 2:
            put(x, v, TREE_LIT)
        elif depth < 5:
            put(x, v, TREE_MID)
        else:
            put(x, v, TREE_DEEP)

# Lit left/right crown edges (two texels wide) where the neighbour is sky.
for v in range(H):
    for x in range(LAND_U0, W):
        if get(x, v) in (TREE_MID, TREE_DEEP) and v < SHORE_V - 6:
            for dx in (-1, -2, 1, 2):
                if get(x + dx, v) == T:
                    put(x, v, TREE_LIT if abs(dx) == 1 or v - top[x] < 6 else TREE_MID)
                    break

# Some mid-tone foliage clumps in the deep shade (2x2 or larger), kept off
# the title area.
for _ in range(60):
    x = rng.randrange(LAND_U0 + 4, W - 3)
    v = rng.randrange(8, SHORE_V - 3)
    if TEXT_U0 - 4 <= x <= TEXT_U0 + 92 and TEXT_V0 - 3 <= v <= TEXT_V0 + 13:
        continue
    if all(get(x + a, v + b) == TREE_DEEP for a in range(-1, 4) for b in range(-1, 3)):
        rect(x, v, x + 3, v + 2, TREE_MID)

# ---------------------------------------------------------------- shoreline
for x in range(LAND_U0 - 4, W):
    put(x, SHORE_V, SAND)
    put(x, SHORE_V + 1, SAND if (x // 5) % 3 else MUD)
    put(x, SHORE_V + 2, MUD)
# Pebble clumps along the sand.
for _ in range(14):
    x = rng.randrange(LAND_U0, W - 3)
    rect(x, SHORE_V, x + 2, SHORE_V + 1, MUD)
# Bank slope under the first few columns of the land.
for x in range(LAND_U0 - 4, LAND_U0 + 4):
    put(x, SHORE_V - 1, SAND if x >= LAND_U0 - 2 else T)

# ---------------------------------------------------------------- jetty
rect(JETTY_U0, DECK_V, JETTY_U1, DECK_V + 1, WOOD_LIT)
rect(JETTY_U0, DECK_V + 1, JETTY_U1, DECK_V + 2, WOOD_DARK)
for px in range(JETTY_U0 + 1, JETTY_U1 - 2, 11):
    rect(px, DECK_V + 2, px + 3, H, WOOD_DARK)
    rect(px, DECK_V + 2, px + 1, H, WOOD_LIT)
# mooring bollard at the tip
rect(JETTY_U0 + 1, DECK_V - 3, JETTY_U0 + 4, DECK_V, WOOD_DARK)
rect(JETTY_U0 + 1, DECK_V - 3, JETTY_U0 + 2, DECK_V, WOOD_LIT)
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
    prio = {INK: 1, PURPLE: 2, PURPLE_LIT: 3, PURPLE_DARK: 2, TAN: 3, WOOD_DARK: 2,
            WOOD_LIT: 3, RED: 6, EYE: 6}
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
                if y < DECK_V and get(x, y) == T:
                    put(x, y, INK)
for cy in range(sh_h):
    for cx in range(sh_w):
        i = snouty[cy][cx]
        if i != T:
            put(SNOUTY_U0 + cx, sv0 + cy, i)

# ---------------------------------------------------------------- title
FONT = {
    "A": [".######.", "########", "##....##", "##....##", "##....##", "##....##",
          "########", "########", "##....##", "##....##", "##....##", "##....##"],
    "N": ["##....##", "###...##", "####..##", "####..##", "##.##.##", "##.##.##",
          "##.##.##", "##..####", "##..####", "##...###", "##....##", "##....##"],
    "T": ["########", "########", "...##...", "...##...", "...##...", "...##...",
          "...##...", "...##...", "...##...", "...##...", "...##...", "...##..."],
    "I": ["########", "########", "...##...", "...##...", "...##...", "...##...",
          "...##...", "...##...", "...##...", "...##...", "########", "########"],
    "H": ["##....##", "##....##", "##....##", "##....##", "##....##", "########",
          "########", "##....##", "##....##", "##....##", "##....##", "##....##"],
    "E": ["########", "########", "##......", "##......", "##......", "######..",
          "######..", "##......", "##......", "##......", "########", "########"],
    "S": [".######.", "########", "##....##", "##......", "##......", "#######.",
          ".#######", "......##", "......##", "##....##", "########", ".######."],
}
for g in FONT.values():
    assert len(g) == 12 and all(len(r) == 8 for r in g)

text = "ANTITHESIS"
cells = set()
for k, ch in enumerate(text):
    for gy, row in enumerate(FONT[ch]):
        for gx, c in enumerate(row):
            if c == "#":
                cells.add((TEXT_U0 + k * 9 + gx, TEXT_V0 + gy))
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


def main():
    data = bytearray(W * H // 2)
    for v in range(H):
        for u in range(0, W, 2):
            lo, hi = tex[v][u], tex[v][u + 1]
            assert 0 <= lo < 16 and 0 <= hi < 16
            data[v * 128 + u // 2] = lo | (hi << 4)
    assert len(data) == 4096
    with open(os.path.join(CART, "cart", "src", "shore_texels.bin"), "wb") as f:
        f.write(bytes(data))

    lines = [
        "//! GENERATED by tools/gen_shore.py. Do not edit.",
        '//! Shore texture, PLAN.md "Shore texture format".',
        "pub const width = 256;",
        "pub const height = 32;",
        "pub const palette: [16][3]f32 = .{",
    ]
    for r, g, b in PALETTE:
        lines.append("    .{ %s, %s, %s }," % (fmt(r), fmt(g), fmt(b)))
    lines += [
        "};",
        'pub const texels: *const [4096]u8 = @embedFile("shore_texels.bin");',
        "",
    ]
    with open(os.path.join(CART, "cart", "src", "shore_data.zig"), "w") as f:
        f.write("\n".join(lines))

    with open(os.path.join(HERE, "shore_palette.json"), "w") as f:
        json.dump([[round(c, 4) for c in p] for p in PALETTE], f)
        f.write("\n")

    def srgb(c):
        c = max(0.0, min(1.0, c))
        c = c * 12.92 if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055
        return int(round(c * 255))

    rgb = [(255, 0, 255)] + [tuple(srgb(c) for c in p) for p in PALETTE[1:]]
    img = Image.new("RGB", (W, H))
    img.putdata([rgb[tex[v][u]] for v in range(H) for u in range(W)])
    img = img.resize((W * 4, H * 4), Image.NEAREST)
    os.makedirs(os.path.join(CART, "docs"), exist_ok=True)
    img.save(os.path.join(CART, "docs", "shore_texture.png"), optimize=True)


if __name__ == "__main__":
    main()
