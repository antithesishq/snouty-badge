"""Shared helpers for the track-pack content generators (M7 Track B).

A pack's league is a LEAGUES-style dict (tools/leagues.py: pal, tiles,
background, horizon) plus a props sheet, painted in the shared 128-tile
layout so the art drops into the built-in formats unchanged. This module
holds what both packs use: tile re-painting over `paint_track_pieces`, the
pack's extra tile slots, the props sheet validation, the review images
(tile contact sheet, horizon, props) and a Mode 7 mock of the cart's floor
renderer (render.zig: horizon row 32, camera height 64, focal 128, fog
banks at z 160/320/640, camera 95 px behind the car).

Numpy and Pillow only, deterministic.
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

TOOLS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOLS))
sys.dont_write_bytecode = True

import leagues as L  # noqa: E402
from leagues import (  # noqa: E402,F401
    A_OFF, A_SURF, A_WALL, A_KICKER, A_COOLANT, A_BAY, A_VENT, A_RAMP, A_START, A_JUMP, A_CRUST, DRIVABLE,
    SURF, SURF_DOT, SURF_SEAM_V, SURF_SEAM_H, SURF_SEAM_X, RUT, EDGE_OPEN, WALL, COOLANT, BAY,
    RAMP, START, SEC1, SEC2, WALL_DIAG, EDGE_DIAG, GAP, VENT_LANE, VENT_MOUTH, SWEEP_LANE,
    SWEEP_GATE, PIT, PAD_SPAWN, PAD_CRATE, KICKER, JUMP, N_, E_, S_, W_, NTILES, T, MAPN,
    Palette, Tileset, grid, side_dist, diag_dist, rot, bayer4, hash01,
)
from art.raster import KEY, Canvas  # noqa: E402

CART = TOOLS.parent
PACKS = CART / "assets" / "packs"

# Pack tile slots beyond the shared layout (all free in leagues.py's map:
# 28..31, the pipe slots 89..91 (no pack uses `pipe`), 121..127).
# Crust (SPEC 19.4, docs/PACKS.md) is pinned: 121 intact, 122 cracked, 123
# broken, all attribute A_CRUST; a map places only 121.
CRUST, CRUST_CRACK, CRUST_HOLE = 121, 122, 123
# Per-track road floors: a track's variant remaps the rasterizer's road
# roles (SURF, the seams, the dot, the ruts) onto these.
VAR_SLOTS = (28, 29, 30, 31, 89, 90, 91, 124, 125, 126, 127)
ROAD_ROLES = (SURF, SURF_DOT, SURF_SEAM_V, SURF_SEAM_H, SURF_SEAM_X, RUT, RUT + 1)

# Props sheet (SPEC 19.3; Track A's provisional M7.0 answer: 32x48 cells
# at 4 bpp, one palette of at most 15 opaque colours, up to 8 cells).
PROP_W, PROP_H, PROP_MAX = 32, 48, 8


def reput(ts, i, name, attr, px):
    """Replace tile i (paint_track_pieces already filled it)."""
    ts.names[i] = None
    ts.put(i, name, attr, px)


def remap_road(tmap, mapping):
    """A track's road variant: road role tile -> the variant's tile."""
    out = tmap.copy()
    for src, dst in mapping.items():
        out[tmap == src] = dst
    return out


# ------------------------------------------------------------ props sheet
def q565(c):
    return (c[0] * 31 // 255, c[1] * 63 // 255, c[2] * 31 // 255)


def validate_props(cells, name):
    """Equal 32x48 cells, at most PROP_MAX, <= 15 opaque colours after the
    RGB565 cut, none on the key, every cell non-empty with a transparent
    border column (billboards are drawn with the key skipped)."""
    errs = []
    if not 1 <= len(cells) <= PROP_MAX:
        errs.append(f"{name}: {len(cells)} cells, 1..{PROP_MAX}")
    cols = set()
    for i, c in enumerate(cells):
        if (c.w, c.h) != (PROP_W, PROP_H):
            errs.append(f"{name}: cell {i} is {c.w}x{c.h}")
            continue
        n = 0
        for y in range(c.h):
            for x in range(c.w):
                p = c.px[y][x]
                if p is None:
                    continue
                n += 1
                if p == KEY or q565(p) == q565(KEY):
                    errs.append(f"{name}: cell {i} colour on the key")
                cols.add(q565(p))
        if not n:
            errs.append(f"{name}: cell {i} empty")
        if any(c.px[y][0] is not None or c.px[y][c.w - 1] is not None for y in range(c.h)):
            errs.append(f"{name}: cell {i} touches its side border")
        if not any(c.px[c.h - 1][x] is not None for x in range(c.w)):
            errs.append(f"{name}: cell {i} does not stand on its bottom row")
    if len(cols) > 15:
        errs.append(f"{name}: {len(cols)} opaque colours after RGB565, max 15")
    return errs, len(cols)


def props_strip(cells):
    out = Canvas(PROP_W * len(cells), PROP_H)
    for i, c in enumerate(cells):
        out.paste(c, i * PROP_W, 0)
    return out


def props_4bpp_bytes(cells):
    """Size of the sheet at 4 bpp (what the pack carries)."""
    return PROP_W * PROP_H * len(cells) // 2


# ------------------------------------------------------------ review images
BG = (22, 20, 28)
INK = (230, 226, 236)


def font(size=12):
    return ImageFont.load_default(size=size)


def checker(w, h, k=6):
    im = Image.new("RGB", (w, h), (46, 42, 56))
    d = ImageDraw.Draw(im)
    for y in range(0, h, k):
        for x in range(0, w, k):
            if (x // k + y // k) % 2:
                d.rectangle([x, y, x + k - 1, y + k - 1], fill=(60, 56, 72))
    return im


def tiles_sheet(ts, path, title):
    """4x tiles, 16 a row, index labels, the attribute as a coloured tick."""
    rgb = ts.pal.rgb_array()
    z, g = 4, 34
    head = 22
    im = Image.new("RGB", (16 * g + 2, NTILES // 16 * (g + 10) + head + 2), BG)
    d = ImageDraw.Draw(im)
    d.text((4, 4), title, fill=INK, font=font(13))
    acol = {0: (90, 90, 90), 1: (90, 200, 120), 2: (230, 80, 80), 3: (250, 160, 40), 4: (80, 180, 250),
            5: (240, 220, 80), 6: (250, 110, 40), 7: (250, 240, 120), 8: (255, 255, 255), 9: (200, 200, 255),
            10: (200, 200, 255), 11: (250, 160, 40)}
    for i in range(NTILES):
        y, x = divmod(i, 16)
        px, py = 1 + x * g, head + y * (g + 10)
        tile = Image.fromarray(rgb[ts.tiles[i]]).resize((8 * z, 8 * z), Image.NEAREST)
        im.paste(tile, (px, py))
        d.text((px, py + 8 * z), str(i), fill=(150, 146, 160) if ts.names[i] else (70, 66, 80), font=font(9))
        d.rectangle([px + 8 * z - 6, py + 8 * z + 2, px + 8 * z - 1, py + 8 * z + 6], fill=acol.get(int(ts.attr[i]), INK))
    im.save(path)


def horizon_image(f, b, fpal, bpal, scale=2):
    hz = np.zeros((33, 512, 3), np.uint8)
    back = np.array(bpal, np.uint8)[np.tile(b, 2)]
    front = np.array(fpal, np.uint8)[f]
    hz[:32] = np.where(f[..., None] > 0, front, back)
    hz[32] = fpal[1]
    return Image.fromarray(hz).resize((512 * scale, 33 * scale), Image.NEAREST)


def props_sheet_image(cells, labels, path, title, z=4):
    w = len(cells) * (PROP_W * z + 10) + 10
    im = Image.new("RGB", (w, PROP_H * z + 60), BG)
    d = ImageDraw.Draw(im)
    d.text((10, 6), title, fill=INK, font=font(13))
    for i, (c, lab) in enumerate(zip(cells, labels)):
        x = 10 + i * (PROP_W * z + 10)
        bg = checker(PROP_W * z, PROP_H * z)
        spr = c.to_image(z)
        mask = Image.fromarray((np.array(spr) != KEY).any(2).astype(np.uint8) * 255)
        bg.paste(spr, (0, 0), mask)
        im.paste(bg, (x, 26))
        d.text((x, 30 + PROP_H * z), f"{i} {lab}", fill=INK, font=font(10))
    im.save(path)


# ------------------------------------------------------------ Mode 7 mock
HORIZON_Y, CAM_H, FOCAL, CAM_BEHIND = 32, 64, 128, 95
FOG_Z = (160, 320, 640)


def fog_banks(pal_rgb):
    p = pal_rgb.astype(np.int32)
    fog = p[0]
    return [(p + (fog - p) * k // 4).astype(np.uint8) for k in range(4)]


def mock_frame(tmap, ts, horizon, cam_x, cam_y, yaw, props=(), sheet=None, car=None):
    """One 160x128 frame as the cart draws it: the two-layer horizon strip
    over rows 0..31 (scrolled by yaw: 512 px a turn front, 256 back), the
    fog row 32, the Mode 7 floor below (nearest texel, fog bank by row
    distance). `props`: (x, y, cell) billboards scaled 1:1 at the car's
    distance (camera.zig's sprite scale), drawn back to front. `car`: a
    marker at the followed car's spot. yaw in radians."""
    f, b, fpal, bpal = horizon
    out = np.zeros((128, 160, 3), np.uint8)
    turn = (yaw / (2 * math.pi)) % 1.0
    sf = int(turn * 512)
    sb = int(turn * 256)
    xs = np.arange(160)
    front = np.array(fpal, np.uint8)
    back = np.array(bpal, np.uint8)
    fx = (xs + sf) & 511
    bx = (xs + sb) & 255
    for y in range(32):
        fi = f[y, fx]
        out[y] = np.where((fi > 0)[:, None], front[fi], back[b[y, bx]])
    out[HORIZON_Y] = ts.pal.rgb[0]
    banks = fog_banks(ts.pal.rgb_array())
    c, s = math.cos(yaw), math.sin(yaw)
    for y in range(HORIZON_Y + 1, 128):
        dy = y - HORIZON_Y
        z = CAM_H * FOCAL / dy
        sc = CAM_H / dy
        wx = cam_x + c * z + (-s * sc) * (xs - 80)
        wy = cam_y + s * z + (c * sc) * (xs - 80)
        tx = (np.floor(wx).astype(int) >> 3) & 127
        ty = (np.floor(wy).astype(int) >> 3) & 127
        t = tmap[ty, tx]
        idx = ts.tiles[t, np.floor(wy).astype(int) & 7, np.floor(wx).astype(int) & 7]
        k = 3 if z >= FOG_Z[2] else 2 if z >= FOG_Z[1] else 1 if z >= FOG_Z[0] else 0
        out[y] = banks[k][idx]
    im = Image.fromarray(out)
    # Billboards: project, sort far to near.
    draw = []
    for px, py, cell in props:
        dx, dy_ = px - cam_x, py - cam_y
        zf = dx * c + dy_ * s
        lat = -dx * s + dy_ * c
        if zf < 24:
            continue
        sx = 80 + lat * FOCAL / zf
        sy = HORIZON_Y + CAM_H * FOCAL / zf
        scale = CAM_BEHIND / zf
        draw.append((zf, sx, sy, scale, cell))
    for zf, sx, sy, scale, cell in sorted(draw, reverse=True):
        if sheet is None or scale <= 0:
            continue
        spr = sheet[cell].to_image()
        w, h = max(1, int(PROP_W * scale)), max(1, int(PROP_H * scale))
        if w > 400:
            continue
        spr = spr.resize((w, h), Image.NEAREST)
        mask = Image.fromarray((np.array(spr) != KEY).any(2).astype(np.uint8) * 255)
        im.paste(spr, (int(sx - w / 2), int(sy - h)), mask)
    if car is not None:
        d = ImageDraw.Draw(im)
        d.rectangle([72, 110, 88, 118], outline=(255, 255, 255))
    return im


def chase_cam(trk, k, ahead=0):
    """Camera behind centerline sample k (dense line), as camera.follow."""
    nd = len(trk.dx)
    j = trk.sidx[k % 256]
    j2 = (j + 6) % nd
    yaw = math.atan2(trk.dy[j2] - trk.dy[j - 6], trk.dx[j2] - trk.dx[j - 6])
    x, y = trk.dx[j], trk.dy[j]
    return x - math.cos(yaw) * CAM_BEHIND, y - math.sin(yaw) * CAM_BEHIND, yaw


def grid_of(frames, cols=4, z=2, labels=None, title=None):
    w, h = 160 * z, 128 * z
    rows = (len(frames) + cols - 1) // cols
    head = 22 if title else 0
    lab = 14 if labels else 0
    im = Image.new("RGB", (cols * (w + 6) + 6, head + rows * (h + 6 + lab) + 6), BG)
    d = ImageDraw.Draw(im)
    if title:
        d.text((6, 4), title, fill=INK, font=font(13))
    for i, fr in enumerate(frames):
        r, cc = divmod(i, cols)
        x, y = 6 + cc * (w + 6), head + 6 + r * (h + 6 + lab)
        im.paste(fr.resize((w, h), Image.NEAREST), (x, y))
        if labels:
            d.text((x, y + h + 1), labels[i], fill=INK, font=font(10))
    return im
