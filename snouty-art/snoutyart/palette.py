"""Per-style palettes: at most 15 opaque colours plus transparency, each colour
bound to a role name (FUR, OUTLINE, NET, ...) so animations stay style-agnostic."""
import json
from pathlib import Path

import numpy as np
from PIL import Image

KEY = (255, 0, 255)  # magenta key used by snouty-run's converter for index 0


def _hex(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


class Palette:
    def __init__(self, path: Path):
        spec = json.loads(Path(path).read_text())
        self.name = spec["name"]
        self.roles = [r[0] for r in spec["roles"]]
        self.colors = [_hex(r[1]) for r in spec["roles"]]
        if len(self.colors) > 15:
            raise ValueError(f"{self.name}: {len(self.colors)} colours, max is 15")
        if len(set(self.colors)) != len(self.colors):
            raise ValueError(f"{self.name}: duplicate colours")
        for role, c in zip(self.roles, self.colors):
            setattr(self, role, c)
        self._arr = np.array(self.colors, dtype=np.int32)
        self._set = set(self.colors)

    def __contains__(self, c):
        return tuple(c) in self._set

    def hexes(self):
        return ["#%02x%02x%02x" % c for c in self.colors]

    def snap(self, img: Image.Image, alpha_cut: int = 128) -> Image.Image:
        """Nearest palette colour for every opaque pixel; alpha hard-cut to 0/255."""
        a = np.array(img.convert("RGBA")).astype(np.int32)
        rgb, alpha = a[:, :, :3], a[:, :, 3]
        d = ((rgb[:, :, None, :] - self._arr[None, None, :, :]) ** 2).sum(-1)
        out = self._arr[d.argmin(-1)].astype(np.uint8)
        opaque = alpha >= alpha_cut
        res = np.zeros_like(a, dtype=np.uint8)
        res[:, :, :3] = np.where(opaque[:, :, None], out, 0)
        res[:, :, 3] = np.where(opaque, 255, 0)
        return Image.fromarray(res, "RGBA")

    def to_indexed(self, img: Image.Image) -> Image.Image:
        """4-bit indexed PNG: index 0 transparent, indices 1..n = palette order."""
        a = np.array(img.convert("RGBA"))
        idx = np.zeros(a.shape[:2], dtype=np.uint8)
        opaque = a[:, :, 3] > 0
        for i, c in enumerate(self.colors):
            idx[opaque & np.all(a[:, :, :3] == np.array(c, dtype=np.uint8), axis=-1)] = i + 1
        bad = opaque & (idx == 0)
        if bad.any():
            raise ValueError(f"{int(bad.sum())} opaque pixels are off-palette")
        p = Image.fromarray(idx, "P")
        flat = list(KEY) + [v for c in self.colors for v in c]
        p.putpalette(flat + [0] * (768 - len(flat)))
        p.info["transparency"] = 0
        return p

    @staticmethod
    def flatten_key(img: Image.Image) -> Image.Image:
        """Transparency -> magenta key, RGB (what snouty-run's converter wants)."""
        bg = Image.new("RGBA", img.size, KEY + (255,))
        bg.alpha_composite(img.convert("RGBA"))
        return bg.convert("RGB")

    def gpl(self, name: str) -> str:
        lines = ["GIMP Palette", f"Name: {name}", "Columns: 5",
                 f"# {len(self.colors)} opaque colors; transparency is index 0 in the indexed PNG."]
        for role, c, h in zip(self.roles, self.colors, self.hexes()):
            lines.append("%3d %3d %3d  %s %s" % (c[0], c[1], c[2], h, role))
        return "\n".join(lines) + "\n"
