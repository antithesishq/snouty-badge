#!/usr/bin/env python3
"""Write cart/src/gen/art.zig: the pixel-art trombone, drawn in code.

    python3 tools/gen_art.py               # rewrite the file
    python3 tools/gen_art.py --check       # exit 1 if the committed file differs
    python3 tools/gen_art.py --png OUT.png # also write a 4x preview (closed and
                                           # at 7th position) for eyeballing

The trombone lies sideways across the top of the screen, as the player
holds it seen from their right: the tuning-slide bow at the far left, the
bell tube above with the bell flaring to the right, the gooseneck down into
the slide's upper leg, the mouthpiece on the lower leg, and the slide
reaching right. Two sprites, both in screen coordinates:

- `horn`: everything that does not move (bell section, mouthpiece, braces,
  the inner slide tubes in chrome).
- `slide`: the outer slide in brass (both legs, the hand brace, the crook
  with its bumper), drawn on top at an x offset of 0..`slide_travel` px
  (`slide_px_per_position` per position: position 1 is offset 0, 7 is 6
  positions out).

Each sprite is rows of palette characters ('.' transparent), so the art
reads in the generated source. `palette` maps characters to colours; the
cart recolours 'r' (bell rim) and 'k' (bell throat) with the level, so the
bell glows when the horn sounds.
"""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "cart", "src", "gen", "art.zig")

W, H = 160, 128

# Palette: character -> 0xRRGGBB. Order is the palette index.
PALETTE = [
    ("h", 0xFFF4C0),  # brass highlight
    ("l", 0xF2C94C),  # brass light
    ("b", 0xC8922A),  # brass
    ("d", 0x7A5414),  # brass shadow
    ("e", 0x4A320A),  # brass deep edge
    ("r", 0xFFE08A),  # bell rim (recoloured with the level)
    ("k", 0x3A2408),  # bell throat (recoloured with the level)
    ("w", 0xF0F4F8),  # chrome highlight
    ("c", 0xA8B2BE),  # chrome
    ("s", 0x5C6672),  # chrome shadow
    ("m", 0x2A2A30),  # bumper / cork
]

# Geometry (screen coordinates).
BELL_Y = 27  # bell tube centre
BOW_LO_Y = 37  # lower tube of the tuning-slide bow
UP_Y = 46  # slide upper leg centre (the gooseneck's leg)
LO_Y = 55  # slide lower leg centre (the mouthpiece's leg)
BOW_X = 9  # centre x of the tuning-slide bow
BELL_THROAT_X = 50
BELL_MOUTH_X = 80
BELL_MOUTH_R = 13
RECEIVER_X = 39
INNER_END_X = 96
OUTER_X0 = 45  # outer slide's open end at position 1
OUTER_X1 = 97  # where the crook starts
CROOK_R = 5
POSITION_PX = 9
TRAVEL = 6 * POSITION_PX


class Canvas:
    def __init__(self):
        self.px = [["." for _ in range(W)] for _ in range(H)]

    def set(self, x, y, ch):
        if 0 <= x < W and 0 <= y < H:
            self.px[y][x] = ch

    def get(self, x, y):
        return self.px[y][x] if 0 <= x < W and 0 <= y < H else "."

    def rows(self):
        """Bounding box and its rows."""
        xs = [x for y in range(H) for x in range(W) if self.px[y][x] != "."]
        ys = [y for y in range(H) for x in range(W) if self.px[y][x] != "."]
        x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
        return x0, y0, ["".join(self.px[y][x0 : x1 + 1]) for y in range(y0, y1 + 1)]


def brass_shade(rel):
    """Shade across a brass tube, rel 0 (top) .. 1 (bottom)."""
    if rel < 0.2:
        return "h"
    if rel < 0.45:
        return "l"
    if rel < 0.75:
        return "b"
    return "d"


def hline_tube(cv, x0, x1, yc, thick, shades):
    """A horizontal tube: rows top to bottom take `shades`."""
    top = yc - thick // 2
    for i in range(thick):
        for x in range(x0, x1 + 1):
            cv.set(x, top + i, shades[i])


def vbar(cv, x, y0, y1, shades):
    """A vertical brace, columns left to right take `shades`."""
    for i, ch in enumerate(shades):
        for y in range(y0, y1 + 1):
            cv.set(x + i, y, ch)


def arc_tube(cv, cx, cy, r, thick, a0, a1, light_side):
    """A bent tube: points within thick/2 of the circle radius r around
    (cx, cy), between angles a0..a1 (degrees, 0 = right, 90 = down)."""
    half = thick / 2.0
    for y in range(int(cy - r - thick), int(cy + r + thick) + 1):
        for x in range(int(cx - r - thick), int(cx + r + thick) + 1):
            dx, dy = x + 0.5 - cx, y + 0.5 - cy
            d = math.hypot(dx, dy)
            if abs(d - r) > half:
                continue
            a = math.degrees(math.atan2(dy, dx)) % 360
            lo, hi = a0 % 360, a1 % 360
            inside = lo <= a <= hi if lo <= hi else (a >= lo or a <= hi)
            if not inside:
                continue
            # Light on the outer edge facing up, dark inside/below.
            rel = (d - (r - half)) / thick  # 0 inner .. 1 outer
            up = -dy / max(d, 1e-6)  # 1 = top of the bend
            if light_side == "outer":
                k = 0.5 - 0.35 * up * (2 * rel - 1)
            else:
                k = 0.5 + 0.35 * up * (2 * rel - 1)
            k = 0.5 * k + 0.5 * (0.5 - 0.5 * up)
            cv.set(x, y, brass_shade(min(max(k, 0.0), 0.999)))


def bell_radius(x):
    t = (x - BELL_THROAT_X) / (BELL_MOUTH_X - BELL_THROAT_X)
    return 1.5 + (BELL_MOUTH_R - 1.5) * (t ** 2.4)


def draw_horn():
    cv = Canvas()
    # Bell tube: from the bow to the throat.
    hline_tube(cv, BOW_X, BELL_THROAT_X, BELL_Y, 3, "lbd")
    # The flare.
    for x in range(BELL_THROAT_X, BELL_MOUTH_X + 1):
        r = bell_radius(x)
        top = math.floor(BELL_Y + 0.5 - r)
        bot = math.ceil(BELL_Y - 0.5 + r)
        for y in range(top, bot + 1):
            rel = (y - top) / max(bot - top, 1)
            ch = brass_shade(rel)
            if y == top or y == bot:
                ch = "e" if y == bot else "l"
            cv.set(x, y, ch)
    # The mouth, seen a little from the front: a rim ellipse, the throat inside.
    rx = 3.2
    for y in range(BELL_Y - BELL_MOUTH_R - 1, BELL_Y + BELL_MOUTH_R + 2):
        for x in range(BELL_MOUTH_X - 4, BELL_MOUTH_X + 5):
            dx = (x - BELL_MOUTH_X) / rx
            dy = (y - BELL_Y) / (BELL_MOUTH_R + 0.6)
            q = dx * dx + dy * dy
            if q <= 1.0:
                inner = (x - BELL_MOUTH_X + 0.8) / (rx - 1.2)
                inner_q = inner * inner + ((y - BELL_Y) / (BELL_MOUTH_R - 1.6)) ** 2
                cv.set(x, y, "k" if inner_q < 1.0 and q < 0.62 else "r")
    # Tuning-slide bow at the far left: a half circle joining the bell tube
    # and the lower bow tube.
    r = (BOW_LO_Y - BELL_Y) / 2
    arc_tube(cv, BOW_X, (BELL_Y + BOW_LO_Y) / 2 + 0.5, r, 3, 90, 270, "outer")
    # Lower bow tube to the gooseneck.
    goose_r = UP_Y - BOW_LO_Y
    gx = RECEIVER_X - goose_r
    hline_tube(cv, BOW_X, gx, BOW_LO_Y, 3, "lbd")
    # Gooseneck: a quarter bend down into the slide's upper leg.
    arc_tube(cv, gx + 0.5, UP_Y + 0.5, goose_r, 3, 270, 360, "outer")
    # Brace between the bell tube and the bow's lower tube, and bell to slide.
    vbar(cv, 20, BELL_Y + 2, BOW_LO_Y - 2, "ld")
    vbar(cv, 44, BELL_Y + 2, UP_Y - 2, "ld")
    # Inner slide tubes in chrome (exposed as the slide goes out).
    for yc in (UP_Y, LO_Y):
        for x in range(RECEIVER_X, INNER_END_X + 1):
            cv.set(x, yc - 1, "w")
            cv.set(x, yc, "c")
    # Position marks on the inner tubes (a tape mark per position past 1st).
    for p in range(1, 7):
        x = OUTER_X0 + p * POSITION_PX - 1
        cv.set(x, UP_Y, "s")
        cv.set(x, LO_Y, "s")
    # Mouthpiece on the lower leg: shank, cup and rim.
    for x in range(26, RECEIVER_X):
        cv.set(x, LO_Y - 1, "w")
        cv.set(x, LO_Y, "c")
    for x, half in ((22, 3), (23, 3), (24, 2), (25, 1)):
        for y in range(LO_Y - half, LO_Y + half + 1):
            cv.set(x, y, "w" if y < LO_Y - half + 2 else ("c" if y < LO_Y + half else "s"))
    vbar(cv, 21, LO_Y - 3, LO_Y + 3, "c")
    # Receiver: ferrules where the legs leave the bell section, and the
    # inner slide's cross brace between them.
    for yc in (UP_Y, LO_Y):
        hline_tube(cv, RECEIVER_X - 1, RECEIVER_X + 2, yc, 4, "hlbd")
    vbar(cv, RECEIVER_X + 1, UP_Y + 2, LO_Y - 2, "wcs")
    return cv


def draw_slide():
    """The outer slide at position 1."""
    cv = Canvas()
    for yc in (UP_Y, LO_Y):
        hline_tube(cv, OUTER_X0, OUTER_X1, yc, 3, "lbd")
        # Ferrule at the open end.
        hline_tube(cv, OUTER_X0, OUTER_X0 + 1, yc, 5, "hlbbd")
    # Crook: a half circle on the right joining the legs.
    r = (LO_Y - UP_Y) / 2
    arc_tube(cv, OUTER_X1 + 0.5, (UP_Y + LO_Y) / 2 + 0.5, r, 3, 270, 90, "outer")
    # Bumper on the crook's tip.
    tip = OUTER_X1 + int(r) + 2
    for y in range(UP_Y + 3, LO_Y - 2):
        cv.set(tip, y, "m")
    # Hand brace between the legs.
    vbar(cv, OUTER_X0 + 7, UP_Y + 2, LO_Y - 2, "hlbd")
    return cv


def zig_rows(name, x0, y0, rows):
    out = [f"pub const {name} = Sprite{{", f"    .x = {x0},", f"    .y = {y0},", "    .rows = &.{"]
    out.extend(f'        "{r}",' for r in rows)
    out.append("    },")
    out.append("};")
    return out


def render():
    horn = draw_horn().rows()
    slide = draw_slide().rows()
    out = []
    out.append("//! Generated by tools/gen_art.py; do not edit by hand.")
    out.append("//! The pixel-art trombone: `horn` (the fixed part) and `slide` (the")
    out.append("//! outer slide at position 1), rows of palette characters, '.' clear.")
    out.append("")
    out.append("pub const Sprite = struct {")
    out.append("    x: i32,")
    out.append("    y: i32,")
    out.append("    rows: []const []const u8,")
    out.append("};")
    out.append("")
    out.append('pub const palette_chars = "' + "".join(c for c, _ in PALETTE) + '";')
    out.append("pub const palette = [_]u32{")
    out.extend(f"    0x{v:06X}," for _, v in PALETTE)
    out.append("};")
    out.append("")
    out.append(f"pub const slide_px_per_position: i32 = {POSITION_PX};")
    out.append(f"pub const slide_travel: i32 = {TRAVEL};")
    out.append(f"/// The crook's right edge at position 1 (the ruler lines up with it).")
    out.append(f"pub const crook_x: i32 = {slide[0] + len(slide[2][0]) - 1};")
    out.append(f"pub const slide_y0: i32 = {UP_Y};")
    out.append(f"pub const slide_y1: i32 = {LO_Y};")
    out.append(f"pub const bell_x: i32 = {BELL_MOUTH_X};")
    out.append(f"pub const bell_y: i32 = {BELL_Y};")
    out.append(f"pub const bell_r: i32 = {BELL_MOUTH_R};")
    out.append(f"pub const mouthpiece_x: i32 = 21;")
    out.append(f"pub const mouthpiece_y: i32 = {LO_Y};")
    out.append("")
    out.extend(zig_rows("horn", *horn))
    out.append("")
    out.extend(zig_rows("slide", *slide))
    out.append("")
    return "\n".join(out)


def preview_png(path):
    from PIL import Image

    colours = dict(PALETTE)
    img = Image.new("RGB", (W, 2 * 70), (11, 15, 26))
    for panel, off in ((0, 0), (1, TRAVEL)):
        for name, cv in (("horn", draw_horn()), ("slide", draw_slide())):
            x0, y0, rows = cv.rows()
            dx = off if name == "slide" else 0
            for j, row in enumerate(rows):
                for i, ch in enumerate(row):
                    if ch == ".":
                        continue
                    x, y = x0 + i + dx, y0 + j - 8 + panel * 70
                    if 0 <= x < W and 0 <= y < img.height:
                        v = colours[ch]
                        img.putpixel((x, y), (v >> 16, (v >> 8) & 255, v & 255))
    img.resize((W * 4, img.height * 4), Image.NEAREST).save(path)
    print(f"gen_art: preview {path}")


def main() -> int:
    args = sys.argv[1:]
    text = render()
    if "--png" in args:
        preview_png(args[args.index("--png") + 1])
    if "--check" in args:
        try:
            with open(OUT) as f:
                ok = f.read() == text
        except FileNotFoundError:
            ok = False
        print("gen_art: " + ("up to date" if ok else "cart/src/gen/art.zig differs; run tools/gen_art.py"))
        return 0 if ok else 1
    with open(OUT, "w") as f:
        f.write(text)
    print(f"gen_art: wrote {os.path.relpath(OUT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
