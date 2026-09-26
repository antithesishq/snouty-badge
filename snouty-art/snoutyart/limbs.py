"""Procedural limbs: outlined capsules through joints, shaded on the lower-left."""
import math

import numpy as np
from PIL import Image, ImageDraw

from . import palette
from .rig import Layer


def _mask(size, polylines, widths):
    m = Image.new("L", size, 0)
    d = ImageDraw.Draw(m)
    for pts, w in zip(polylines, widths):
        pts = [(float(x), float(y)) for x, y in pts]
        if len(pts) > 1:
            d.line(pts, fill=255, width=w, joint="curve")
        r = w / 2.0
        for x, y in pts:
            d.ellipse([x - r, y - r, x + r, y + r], fill=255)
    return np.array(m) > 127


def _shift(m, dx, dy):
    out = np.zeros_like(m)
    h, w = m.shape
    ys, ye = max(0, dy), min(h, h + dy)
    xs, xe = max(0, dx), min(w, w + dx)
    out[ys:ye, xs:xe] = m[ys - dy:ye - dy, xs - dx:xe - dx]
    return out


def _dilate4(m):
    return m | _shift(m, 1, 0) | _shift(m, -1, 0) | _shift(m, 0, 1) | _shift(m, 0, -1)


def capsule_layer(size, polylines, widths, z, fill=palette.PURPLE,
                  shade=palette.PURPLE_DARK, shade_px=2, outline=palette.OUTLINE,
                  light=None, light_dir=(1, -1)) -> Layer:
    """Draw thick polylines (one per entry) merged into one outlined blob.
    shade_px pixels along the lower-left rim get the shade colour; if light is
    given, a 1px rim toward light_dir gets it."""
    m = _mask(size, polylines, widths)
    rim = _dilate4(m) & ~m
    img = np.zeros((size[1], size[0], 4), dtype=np.uint8)
    img[m] = fill + (255,)
    if shade is not None and shade_px > 0:
        inner = m.copy()
        sh = np.zeros_like(m)
        for _ in range(shade_px):
            edge = inner & ~_shift(inner, 1, -1)  # lower-left rim: neighbour at (x-1,y+1) empty
            sh |= edge
            inner = inner & ~edge
        img[sh & m] = shade + (255,)
    if light is not None:
        lx, ly = light_dir
        hi = m & ~_shift(m, -lx, -ly)
        img[hi] = light + (255,)
    img[rim] = outline + (255,)
    return Layer(z, Image.fromarray(img, "RGBA"))


def leg(rig, hip, knee, ankle, toe, z, spec=None, foot=None, sole=None,
        toe_bump=0, **kw) -> Layer:
    """Leg: thigh+shin capsule of width w, foot capsule from ankle to toe.

    Optional (defaults keep the original round-foot look):
      foot="flat": the foot is a thinner capsule (spec["foot_height"], default
        width-2) from a heel point just behind the ankle to the toe, so it
        reads as a flat foot rather than a ball.
      toe_bump: radius in px of a small bump on top of the toe end (0 = none).
      sole: colour for the 1 px underside of the foot (pixels whose neighbour
        below is empty, within the foot region)."""
    s = spec or rig.limbs["leg"]
    if foot != "flat":
        lay = capsule_layer(rig.cell, [[hip, knee, ankle], [ankle, toe]],
                            [s["width"], s["foot_width"]], z, **kw)
        return lay
    fh = s.get("foot_height", max(3, s["width"] - 2))
    ax, ay = ankle
    tx, ty = toe
    L = math.hypot(tx - ax, ty - ay) or 1.0
    ux, uy = (tx - ax) / L, (ty - ay) / L
    back = s.get("heel", 1.5)
    heel = (ax - ux * back, ay - uy * back)
    polys = [[hip, knee, ankle], [heel, toe]]
    widths = [s["width"], fh]
    if toe_bump:
        # on top of the foot (perpendicular toward "up" relative to the foot)
        px, py = uy, -ux
        if py > 0:
            px, py = -px, -py
        bx = tx - ux * toe_bump + px * (fh / 2.0 - 0.5)
        by = ty - uy * toe_bump + py * (fh / 2.0 - 0.5)
        polys.append([(bx, by)])
        widths.append(int(round(2 * toe_bump)))
    lay = capsule_layer(rig.cell, polys, widths, z, **kw)
    if sole is not None:
        a = np.array(lay.image)
        op = a[:, :, 3] > 0
        body = op & ~np.all(a[:, :, :3] == np.array(kw.get("outline", palette.OUTLINE),
                                                   dtype=np.uint8), axis=-1)
        fm = _mask(rig.cell, [[heel, toe]], [fh + 2])
        below_rim = body & ~_shift(body, 0, -1)  # pixel below is not body
        a[below_rim & fm] = sole + (255,)
        lay = Layer(z, Image.fromarray(a, "RGBA"))
    return lay


def arm(rig, shoulder, elbow, wrist, z, spec=None, **kw) -> Layer:
    s = spec or rig.limbs["arm"]
    return capsule_layer(rig.cell, [[shoulder, elbow, wrist]], [s["width"]], z, **kw)
