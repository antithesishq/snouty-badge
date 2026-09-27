#!/usr/bin/env python3
"""Carve rig parts for the 'glean' style from src/native_q.png (the Glean test
image resampled to its true 83x84 pixel grid and snapped to palette.json).

Run from anywhere: python3 styles/glean/make_parts.py
Legs are not carved (they are procedural); the near arm is drawn by the
animation too, so the torso is rebuilt as a clean shirt silhouette + hips.
"""
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
pal = {r[0]: tuple(int(r[1][i:i + 2], 16) for i in (1, 3, 5))
       for r in json.loads((HERE / "palette.json").read_text())["roles"]}
im = np.array(Image.open(HERE / "src" / "native_q.png").convert("RGBA"))
H, W = im.shape[:2]
Y, X = np.mgrid[0:H, 0:W]
op = im[:, :, 3] > 0


def is_(*names):
    m = np.zeros((H, W), bool)
    for n in names:
        m |= np.all(im[:, :, :3] == np.array(pal[n]), axis=-1) & op
    return m


def box(x0, y0, x1, y1):
    return (X >= x0) & (X <= x1) & (Y >= y0) & (Y <= y1)


def nb8(m):
    o = np.zeros_like(m)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dy or dx:
                o |= np.roll(np.roll(m, dy, 0), dx, 1)
    return o


def nb4(m):
    return (np.roll(m, 1, 0) | np.roll(m, -1, 0) | np.roll(m, 1, 1) | np.roll(m, -1, 1))


black = is_("OUTLINE", "SHIRT_DARK", "SHIRT")
fur = is_("FUR", "FUR_DARK", "FUR_DEEP", "FUR_LIGHT")
gold = is_("NET", "NET_DARK", "NET_LIGHT")
mesh = is_("WHITE", "NET_PALE")

OUT = HERE / "parts"
OUT.mkdir(exist_ok=True)


def save(mask_or_rgba, name):
    if mask_or_rgba.dtype == bool:
        out = np.zeros_like(im)
        out[mask_or_rgba] = im[mask_or_rgba]
    else:
        out = mask_or_rgba
    Image.fromarray(out, "RGBA").save(OUT / f"{name}.png")
    ys, xs = np.nonzero(out[:, :, 3] > 0)
    print(f"{name}: bbox {xs.min()},{ys.min()}..{xs.max()},{ys.max()}  {len(xs)} px")


# --- net: bag + hoop + handle, with their outline
bag = box(8, 9, 31, 40) & (mesh | gold | (black & nb8(mesh | gold)))
handle = gold & box(26, 20, 52, 52) & ~bag
handle_outline = black & nb8(handle) & ~nb8(fur) & box(26, 20, 52, 52)
save(bag | handle | handle_outline, "net")

# --- head: everything in its box except the handle, the fist and the sleeve
fist_src = box(45, 39, 57, 51) & (fur | (black & nb8(fur & box(45, 39, 57, 51))))
head = box(35, 17, 73, 42) & op & ~(handle | handle_outline) & ~fist_src
head &= ~(black & box(26, 33, 46, 60) & ~nb8(fur & box(35, 17, 73, 33)))
head |= is_("WHITE", "GREY") & box(44, 18, 60, 32)
head &= ~(box(35, 39, 43, 42) & black)
# fill where the handle crossed the head (rows between head extents in the head box)
head_img = np.zeros_like(im)
head_img[head] = im[head]
for y in range(17, 43):
    row = np.nonzero(head[y])[0]
    if len(row) >= 2:
        for x in range(row.min(), row.max() + 1):
            if not head[y, x] and (handle[y, x] or handle_outline[y, x]):
                head_img[y, x] = pal["FUR"] + (255,)
save(head_img, "head")

# --- tail: fur left of the body, clipped so the shoulder fur stays with the torso
tail_box = box(8, 38, 29, 56) | box(8, 47, 31, 56)
tail = tail_box & (fur | (black & nb8(fur & tail_box)))
save(tail, "tail")

# --- torso: drawn, not carved. The source shirt is a black blob whose black is
# indistinguishable from outline, so we redraw it: a round tee with a sleeve
# bump at the near shoulder, SHIRT_DARK on the lower-left, 1px OUTLINE, lavender
# hips under the hem for the legs to attach to, and a 7px Iris ring on the chest.
def ellipse(cx, cy, rx, ry):
    return ((X - cx) / rx) ** 2 + ((Y - cy) / ry) ** 2 <= 1.0


shirt = ellipse(39.5, 44, 10.5, 10) | ellipse(33, 40, 5, 5.5)
hips = ellipse(39, 53, 8.5, 4.5) & (Y >= 49)
torso = np.zeros_like(im)
hip_fill = hips & ~shirt
torso[hip_fill] = pal["FUR"] + (255,)
torso[hip_fill & ~np.roll(np.roll(hip_fill | shirt, -1, 0), 1, 1)] = pal["FUR_DARK"] + (255,)
torso[nb4(hip_fill) & ~hip_fill & ~shirt] = pal["OUTLINE"] + (255,)
interior = shirt & ~nb4(~shirt)
torso[shirt] = pal["OUTLINE"] + (255,)
torso[interior] = pal["SHIRT"] + (255,)
rim = interior & ~np.roll(np.roll(shirt, -1, 0), 1, 1)
rim |= interior & ~np.roll(np.roll(shirt, -2, 0), 2, 1)
torso[rim] = pal["SHIRT_DARK"] + (255,)
# Iris ring: radius 3 centred (42, 47), gap at the upper right like the mark
ring = ellipse(42, 47, 3.4, 3.4) & ~ellipse(42, 47, 1.9, 1.9)
gap = (X >= 43) & (Y <= 45)
torso[ring & ~gap & interior] = pal["RED"] + (255,)
torso[ring & ~gap & interior & (X <= 41) & (Y >= 48)] = pal["RED_DARK"] + (255,)
save(torso, "torso")


# --- hands: procedural fists (the source fist is cut by the handle)
def fist(d, name):
    s = d + 2
    img = Image.new("L", (s, s), 0)
    ImageDraw.Draw(img).ellipse([1, 1, d, d], fill=255)
    m = np.array(img) > 0
    out = np.zeros((s, s, 4), np.uint8)
    out[m] = pal["FUR"] + (255,)
    rim = m & ~np.roll(np.roll(m, -1, 0), 1, 1)
    out[rim] = pal["FUR_DARK"] + (255,)
    hi = m & ~np.roll(np.roll(m, 1, 0), -1, 1) & ~rim
    out[hi] = pal["FUR_LIGHT"] + (255,)
    edge = nb4(m) & ~m
    out[edge] = pal["OUTLINE"] + (255,)
    Image.fromarray(out, "RGBA").save(OUT / f"{name}.png")
    print(f"{name}: {s}x{s}")


fist(9, "holding_hand")
fist(8, "free_hand")
