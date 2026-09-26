"""Parts rig: load pixel parts with pivots, compose posed layers into a cell."""
import json
import math
from dataclasses import dataclass, field
from pathlib import Path

from PIL import Image

from . import ROOT, palette


@dataclass
class Part:
    name: str
    image: Image.Image   # RGBA, on-palette
    pivot: tuple         # pixel in image coords that sits on the anchor
    z: int
    ref_pos: tuple       # where the pivot sits in reference coords by default


@dataclass
class Placed:
    """One posed part. dx, dy move the pivot from its default reference position
    (cell coords = ref coords + ref_to_cell_offset). rot is degrees, CCW positive
    on screen (so a positive rot tips the right-hand side up)."""
    part: str
    dx: int = 0
    dy: int = 0
    rot: float = 0.0
    z: int | None = None
    flip: bool = False


@dataclass
class Layer:
    z: int
    image: Image.Image  # cell-sized RGBA


class Rig:
    def __init__(self, path: Path = ROOT / "rig" / "rig.json"):
        self.spec = json.loads(Path(path).read_text())
        self.cell = tuple(self.spec["cell_size"])
        self.origin = tuple(self.spec["cell_origin"])
        self.off = tuple(self.spec["ref_to_cell_offset"])
        self.joints_ref = {k: tuple(v) for k, v in self.spec["joints_ref"].items()}
        self.limbs = self.spec["limbs"]
        self.parts: dict[str, Part] = {}
        for name, p in self.spec["parts"].items():
            img = palette.snap(Image.open(ROOT / "rig" / "parts" / p["file"]))
            pivot = tuple(p["pivot"])
            ref_pos = tuple(p.get("ref_pos", pivot))
            self.parts[name] = Part(name, img, pivot, p["z"], ref_pos)

    # --- coordinates -----------------------------------------------------
    def ref_to_cell(self, pt):
        return (pt[0] + self.off[0], pt[1] + self.off[1])

    def joint(self, name, dx=0, dy=0):
        """Default cell position of a named reference joint, plus an offset."""
        x, y = self.ref_to_cell(self.joints_ref[name])
        return (x + dx, y + dy)

    def anchor(self, part: str, dx=0, dy=0):
        """Cell position of a part's pivot after an offset."""
        x, y = self.ref_to_cell(self.parts[part].ref_pos)
        return (x + dx, y + dy)

    # --- rendering -------------------------------------------------------
    def render_part(self, pl: Placed) -> Layer:
        part = self.parts[pl.part]
        img = part.image
        px, py = part.pivot
        if pl.flip:
            img = img.transpose(Image.FLIP_LEFT_RIGHT)
            px = img.width - 1 - px
        if pl.rot:
            # Pad so the pivot sits at the centre of a square canvas, rotate
            # about that centre with nearest-neighbour, then place the centre.
            s = 2 * max(img.width, img.height) + 4
            c = s // 2
            canvas = Image.new("RGBA", (s, s), (0, 0, 0, 0))
            canvas.alpha_composite(img, (c - px, c - py))
            img = canvas.rotate(pl.rot, resample=Image.NEAREST, expand=False)
            px, py = c, c
        ax, ay = self.anchor(pl.part, pl.dx, pl.dy)
        layer = Image.new("RGBA", self.cell, (0, 0, 0, 0))
        layer.alpha_composite(img, (ax - px, ay - py))
        return Layer(part.z if pl.z is None else pl.z, palette.snap(layer))

    def compose(self, layers: list[Layer]) -> Image.Image:
        out = Image.new("RGBA", self.cell, (0, 0, 0, 0))
        for layer in sorted(layers, key=lambda l: l.z):
            out.alpha_composite(layer.image)
        return palette.snap(out)


def ik2(root, target, l1, l2, bend=1):
    """Two-bone IK. Returns the middle joint (knee/elbow) for a chain from root
    to target with segment lengths l1, l2. bend=+1 puts the joint on the
    right-hand side of the root->target direction (screen coords, y down),
    which for a leg pointing down is the knee forward (to the right). If the
    target is out of reach the chain straightens toward it."""
    rx, ry = root
    tx, ty = target
    dx, dy = tx - rx, ty - ry
    d = math.hypot(dx, dy)
    if d < 1e-6:
        return (rx + l1, ry)
    d = min(d, l1 + l2 - 1e-3)
    d = max(d, abs(l1 - l2) + 1e-3)
    a = (l1 * l1 - l2 * l2 + d * d) / (2 * d)
    h = math.sqrt(max(l1 * l1 - a * a, 0.0))
    ux, uy = dx / d, dy / d
    mx, my = rx + a * ux, ry + a * uy
    # perpendicular: (-uy, ux) is the left side when facing along u; right is (uy, -ux)
    return (mx + bend * h * uy, my - bend * h * ux)
