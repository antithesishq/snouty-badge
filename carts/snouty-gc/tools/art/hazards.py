"""Track hazard sprites (M3): the Dumps' Sweeper, a huge maintenance crawler
the Hyperscalers send over the landfill (SPEC 3.3).

hazards.png is a strip of 48x32 cells:
  0, 1  end view (seen from behind or ahead: the crawler is the same both
        ways), the brush bar's bristles in two phases
  2, 3  side view facing right, the brush drum turning in two phases
The warning beacon on the roof is drawn dark; the cart lights it (amber
flashes during `warn`, steady while crossing) as a few flat pixels over the
sprite, at BEACON_END / BEACON_SIDE (cell px, top-left of a 4x3 lamp).
"""
from __future__ import annotations

from .raster import Canvas, hx, strip

HZ = {
    "o": hx(0x141018),   # outline, stripe black
    "t": hx(0x2A2830),   # tread
    "T": hx(0x5A5E6A),   # tread lugs, wheels
    "w": hx(0xE4E6EE),   # hull light
    "l": hx(0xA8ACB8),   # hull mid
    "s": hx(0x6A6E7A),   # hull shadow
    "y": hx(0xF0C030),   # hazard yellow
    "b": hx(0xD07020),   # brush bristles
    "B": hx(0x7A3A10),   # brush dark
    "r": hx(0xE03A3A),   # scanner eye
    "R": hx(0xFF9A8A),   # eye glint
    "a": hx(0x8A5A10),   # beacon (dark)
    "c": hx(0x4FD6E8),   # status LEDs
}

# Where the cart draws the lit beacon (4 x 3 px, top-left), per view.
BEACON_END = (22, 1)
BEACON_SIDE = (17, 1)


def end_view(phase: int) -> Canvas:
    c = Canvas(48, 32)
    o = HZ["o"]
    # Treads left and right.
    for x0 in (2, 36):
        c.rect(x0, 18, x0 + 9, 30, HZ["t"])
        for y in range(19 + phase, 30, 2):
            c.hline(x0 + 1, x0 + 8, y, HZ["T"])
    # Hull: a wide box with a sloped top.
    c.poly([(6, 8), (42, 8), (44, 12), (44, 24), (4, 24), (4, 12)], HZ["l"])
    c.poly([(8, 6), (40, 6), (42, 8), (6, 8)], HZ["w"])
    c.rect(6, 9, 41, 12, HZ["w"])
    c.rect(5, 20, 43, 24, HZ["s"])
    # Hazard stripes across the hull's lower band.
    for x in range(5, 44):
        for y in range(17, 20):
            c.set(x, y, HZ["y"] if (x + y) % 6 < 3 else o)
    # The scanner: a red slit across the face with a glint.
    c.rect(14, 13, 33, 15, o)
    c.rect(15, 14, 32, 14, HZ["r"])
    gx = 18 + phase * 9
    c.rect(gx, 14, gx + 3, 14, HZ["R"])
    # Status LEDs.
    for k in range(3):
        c.set(8 + 2 * k, 11, HZ["c"])
    # Roof beacon (dark; the cart lights it).
    bx, by = BEACON_END
    c.rect(bx - 1, by + 3, bx + 4, by + 5, HZ["s"])
    c.rect(bx, by, bx + 3, by + 2, HZ["a"])
    # The brush bar under the hull between the treads, bristles flicking.
    c.rect(12, 25, 35, 27, HZ["B"])
    for x in range(12, 36):
        if (x + phase) % 3 != 0:
            c.vline(x, 26, 30 - ((x * 7 + phase) % 2), HZ["b"])
    c.outline(o)
    return c


def side_view(phase: int) -> Canvas:
    c = Canvas(48, 32)
    o = HZ["o"]
    # Tread along the bottom with road wheels.
    c.rect(4, 22, 37, 30, HZ["t"])
    c.ellipse(5, 26, 4, 4.5, HZ["t"])
    c.ellipse(36, 26, 4, 4.5, HZ["t"])
    for k, x in enumerate(range(7, 36, 7)):
        c.ellipse(x + 0.5, 26.5, 2.5, 2.5, HZ["T"])
        c.set(x, 26, HZ["t"] if (k + phase) % 2 else HZ["s"])
    for x in range(4 + phase, 38, 3):
        c.set(x, 21, HZ["T"])
        c.set(x, 31, HZ["T"])
    # Hull, the cab end to the right.
    c.poly([(3, 9), (34, 9), (40, 13), (40, 21), (3, 21)], HZ["l"])
    c.rect(3, 6, 30, 9, HZ["w"])
    c.rect(4, 10, 33, 12, HZ["w"])
    c.rect(3, 19, 40, 21, HZ["s"])
    for x in range(3, 41):
        for y in range(16, 19):
            c.set(x, y, HZ["y"] if (x + y) % 6 < 3 else o)
    # Vents along the side, LEDs.
    for x in range(7, 24, 4):
        c.vline(x, 11, 14, HZ["s"])
    for k in range(3):
        c.set(26 + 2 * k, 12, HZ["c"])
    # The scanner at the cab end.
    c.rect(36, 13, 39, 15, o)
    c.rect(37, 14, 39, 14, HZ["r"])
    if phase:
        c.set(38, 14, HZ["R"])
    # Roof beacon.
    bx, by = BEACON_SIDE
    c.rect(bx - 1, by + 3, bx + 4, by + 5, HZ["s"])
    c.rect(bx, by, bx + 3, by + 2, HZ["a"])
    # The brush drum ahead of the cab, spokes turning.
    c.ellipse(42.5, 25.5, 5, 5.5, HZ["B"])
    for k in range(8):
        import math
        a = (k + phase * 0.5) * math.pi / 4
        x1 = 42.5 + math.cos(a) * 5
        y1 = 25.5 + math.sin(a) * 5.5
        c.line(42, 25, x1, y1, HZ["b"])
    c.rect(40, 18, 42, 21, HZ["s"])   # the drum's arm
    c.outline(o)
    return c


def draw_hazards():
    return strip([end_view(0), end_view(1), side_view(0), side_view(1)])


HAZARD_CELLS = ["Sweeper end view, brush phase 0", "Sweeper end view, brush phase 1",
                "Sweeper side view (facing right), drum phase 0", "Sweeper side view, drum phase 1"]
