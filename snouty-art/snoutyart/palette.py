"""The fixed 15-colour Snouty palette (ref/snouty_palette.gpl) plus transparency."""
import numpy as np
from PIL import Image

OUTLINE = (23, 18, 30)       # #17121e near-black outlines
SHIRT_DARK = (41, 35, 47)    # #29232f shirt shadow
SHIRT = (66, 54, 75)         # #42364b shirt
PURPLE_DEEP = (70, 33, 116)  # #462174 fur deep shadow
PURPLE_DARK = (102, 43, 184) # #662bb8 fur shadow
PURPLE = (142, 66, 222)      # #8e42de fur
PURPLE_LIGHT = (190, 122, 243) # #be7af3 fur highlight
WHITE = (244, 239, 223)      # #f4efdf eye
GREY = (149, 141, 157)       # #958d9d glasses
RED = (238, 69, 60)          # #ee453c Iris emblem
RED_DARK = (145, 50, 47)     # #91322f emblem shadow
BROWN_DARK = (96, 57, 31)    # #60391f net shadow
BROWN = (153, 98, 47)        # #99622f net
BROWN_LIGHT = (205, 147, 75) # #cd934b net light
BROWN_PALE = (240, 195, 124) # #f0c37c net highlight

PALETTE = [OUTLINE, SHIRT_DARK, SHIRT, PURPLE_DEEP, PURPLE_DARK, PURPLE, PURPLE_LIGHT,
           WHITE, GREY, RED, RED_DARK, BROWN_DARK, BROWN, BROWN_LIGHT, BROWN_PALE]
NAMES = ["OUTLINE", "SHIRT_DARK", "SHIRT", "PURPLE_DEEP", "PURPLE_DARK", "PURPLE",
         "PURPLE_LIGHT", "WHITE", "GREY", "RED", "RED_DARK", "BROWN_DARK", "BROWN",
         "BROWN_LIGHT", "BROWN_PALE"]
KEY = (255, 0, 255)  # magenta key used by snouty-badge's converter for index 0

_PAL = np.array(PALETTE, dtype=np.int32)


def hexes():
    return ["#%02x%02x%02x" % c for c in PALETTE]


def snap(img: Image.Image, alpha_cut: int = 128) -> Image.Image:
    """Nearest palette colour for every opaque pixel; alpha hard-cut to 0/255."""
    a = np.array(img.convert("RGBA")).astype(np.int32)
    rgb, alpha = a[:, :, :3], a[:, :, 3]
    d = ((rgb[:, :, None, :] - _PAL[None, None, :, :]) ** 2).sum(-1)
    idx = d.argmin(-1)
    out = _PAL[idx].astype(np.uint8)
    opaque = alpha >= alpha_cut
    res = np.zeros_like(a, dtype=np.uint8)
    res[:, :, :3] = np.where(opaque[:, :, None], out, 0)
    res[:, :, 3] = np.where(opaque, 255, 0)
    return Image.fromarray(res, "RGBA")


def to_indexed(img: Image.Image) -> Image.Image:
    """4-bit indexed PNG: index 0 transparent, indices 1..15 = PALETTE order."""
    a = np.array(img.convert("RGBA"))
    idx = np.zeros(a.shape[:2], dtype=np.uint8)
    opaque = a[:, :, 3] > 0
    for i, c in enumerate(PALETTE):
        m = opaque & np.all(a[:, :, :3] == np.array(c, dtype=np.uint8), axis=-1)
        idx[m] = i + 1
    bad = opaque & (idx == 0)
    if bad.any():
        raise ValueError(f"{int(bad.sum())} opaque pixels are off-palette")
    p = Image.fromarray(idx, "P")
    flat = list(KEY) + [v for c in PALETTE for v in c]
    p.putpalette(flat + [0] * (768 - len(flat)))
    p.info["transparency"] = 0
    return p


def flatten_key(img: Image.Image) -> Image.Image:
    """Transparency -> magenta key, RGB (what snouty-badge's converter wants)."""
    bg = Image.new("RGBA", img.size, KEY + (255,))
    bg.alpha_composite(img.convert("RGBA"))
    return bg.convert("RGB")


def gpl(name: str) -> str:
    lines = ["GIMP Palette", f"Name: {name}", "Columns: 5",
             "# 15 opaque colors; transparency is index 0 in the indexed PNG."]
    for c, h in zip(PALETTE, hexes()):
        lines.append("%3d %3d %3d  %s" % (c[0], c[1], c[2], h))
    return "\n".join(lines) + "\n"
