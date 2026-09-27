"""Downscale a finished image to a small pixel-art cell on a fixed palette.

The cart textures are 32x32 4-bit sheets and sprites need a 1 px empty
border, so a source (a 96 px frame, a logo SVG rasterised at 288 px, a
512 px button) is cropped to what is opaque, fitted inside a box, area
averaged with the alpha handled separately (so transparent background never
bleeds into the edge colour), thresholded, and every opaque pixel is snapped
to the nearest palette colour. Palettes are RGB565-snapped first so the
count the cart sees equals the count we produce.
"""
from __future__ import annotations

import numpy as np
from PIL import Image

KEY = (255, 0, 255)


def rgb565_snap(pal: np.ndarray) -> np.ndarray:
    p = pal.astype(np.int32)
    out = np.stack([(p[:, 0] >> 3) * 255 // 31, (p[:, 1] >> 2) * 255 // 63, (p[:, 2] >> 3) * 255 // 31], axis=1)
    out = out.astype(np.uint8)
    for c in out:
        if tuple(c) == KEY:
            c[1] = 8
    return np.unique(out, axis=0)


def key_white(a: np.ndarray, thresh: int = 235) -> np.ndarray:
    """RGBA with near-white pixels made transparent (logo refs on white)."""
    a = a.copy()
    white = (a[..., :3] >= thresh).all(axis=2)
    a[white, 3] = 0
    return a


def bbox(mask: np.ndarray) -> tuple[int, int, int, int]:
    ys, xs = np.where(mask)
    return int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1


def resize_rgba(a: np.ndarray, w: int, h: int, alpha_thresh: float = 0.5) -> tuple[np.ndarray, np.ndarray]:
    """Area-average resize. Returns (rgb h x w x 3, opaque mask h x w).
    Transparent pixels take the mean opaque colour before filtering so the
    edge colour is the art's, not the background's."""
    rgb = a[..., :3].astype(np.float32)
    alpha = a[..., 3].astype(np.float32) / 255.0
    if (alpha < 1).any():
        mean = (rgb * alpha[..., None]).sum((0, 1)) / max(alpha.sum(), 1.0)
        rgb = rgb * alpha[..., None] + mean * (1 - alpha[..., None])
    rgb_im = Image.fromarray(rgb.round().clip(0, 255).astype(np.uint8), "RGB").resize((w, h), Image.BOX)
    al_im = Image.fromarray((alpha * 255).round().astype(np.uint8), "L").resize((w, h), Image.BOX)
    return np.array(rgb_im), np.array(al_im) >= round(alpha_thresh * 255)


def snap(rgb: np.ndarray, mask: np.ndarray, palette: np.ndarray) -> np.ndarray:
    """Nearest palette colour (weighted RGB distance) for every masked pixel."""
    pal = palette.astype(np.float32)
    w = np.array([0.30, 0.59, 0.11], np.float32)
    pts = rgb[mask].astype(np.float32)
    d = (((pts[:, None, :] - pal[None, :, :]) ** 2) * w).sum(axis=2)
    out = rgb.copy()
    out[mask] = palette[d.argmin(axis=1)]
    return out


def median_cut(rgb: np.ndarray, mask: np.ndarray, max_colors: int) -> np.ndarray:
    """Palette from the masked pixels when no fixed palette is given."""
    pts = rgb[mask]
    n = max_colors
    while True:
        strip = Image.fromarray(pts.reshape(1, -1, 3), "RGB")
        q = strip.quantize(colors=n, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
        pal = rgb565_snap(np.array(q.getpalette()[: 3 * n], np.int32).reshape(-1, 3))
        if len(pal) <= max_colors:
            return pal
        n -= 1


def fit(a: np.ndarray, box_w: int, box_h: int, alpha_thresh: float = 0.5) -> tuple[np.ndarray, np.ndarray]:
    """Crop to the opaque bbox and fit inside box_w x box_h keeping aspect.
    Returns (rgb, mask) at the fitted size."""
    x0, y0, x1, y1 = bbox(a[..., 3] >= 128)
    crop = a[y0:y1, x0:x1]
    h, w = crop.shape[:2]
    k = min(box_w / w, box_h / h)
    nw, nh = max(1, round(w * k)), max(1, round(h * k))
    return resize_rgba(crop, nw, nh, alpha_thresh)


def to_cell(rgb: np.ndarray, mask: np.ndarray, cell: int = 32, anchor: str = "centre") -> np.ndarray:
    """Place a fitted image in a cell x cell RGB array on the magenta key.
    anchor 'centre' or 'bottom' (feet on the last border row)."""
    out = np.zeros((cell, cell, 3), np.uint8)
    out[:] = KEY
    h, w = rgb.shape[:2]
    ox = (cell - w) // 2
    oy = (cell - h) // 2 if anchor == "centre" else cell - 1 - h
    sub = out[oy:oy + h, ox:ox + w]
    sub[mask] = rgb[mask]
    return out


def downscale(a: np.ndarray, box: int = 30, palette: np.ndarray | None = None,
              max_colors: int = 15, cell: int = 32, anchor: str = "centre",
              alpha_thresh: float = 0.5) -> np.ndarray:
    """RGBA source -> cell x cell RGB on the key, opaque pixels on `palette`
    (or a median-cut palette of at most max_colors). A lower alpha_thresh
    keeps thin strokes of a flat mark that area averaging would erase."""
    rgb, mask = fit(a, box, box, alpha_thresh)
    if palette is None:
        palette = median_cut(rgb, mask, max_colors)
    rgb = snap(rgb, mask, rgb565_snap(palette))
    return to_cell(rgb, mask, cell, anchor)


def load_rgba(path) -> np.ndarray:
    return np.array(Image.open(path).convert("RGBA"))


def hex_palette(hexes) -> np.ndarray:
    return np.array([[int(h[i:i + 2], 16) for i in (1, 3, 5)] for h in hexes], np.uint8)
