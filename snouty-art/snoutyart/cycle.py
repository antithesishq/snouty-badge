"""Frame/Cycle containers shared by animations and the exporter."""
from dataclasses import dataclass, field

import numpy as np
from PIL import Image


@dataclass
class Frame:
    image: Image.Image          # cell-sized RGBA, on-palette
    label: str = ""
    duration_ms: int = 40
    meta: dict = field(default_factory=dict)  # joints, grounded flags, offsets

    def feet_row(self) -> int:
        a = np.array(self.image)[:, :, 3]
        return int(np.nonzero(a)[0].max())


@dataclass
class Cycle:
    name: str                   # e.g. "snouty_run"
    frames: list
    playback: str = "forward, loop; never ping-pong"
    step_px: int | None = None  # planted-toe travel per frame (run), None otherwise
    notes: dict = field(default_factory=dict)
    grid_columns: int | None = None
