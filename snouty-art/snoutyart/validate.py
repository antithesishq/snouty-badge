"""Hard checks a pack must pass before it is written."""
import numpy as np

from .cycle import Cycle

def validate(cycle: Cycle, pal, cell=(96, 96)) -> dict:
    report = {"status": "passed", "errors": [], "frame_count": len(cycle.frames)}
    hashes = set()
    colours = set()
    feet = []
    for i, f in enumerate(cycle.frames):
        a = np.array(f.image.convert("RGBA"))
        if f.image.size != cell:
            report["errors"].append(f"frame {i}: size {f.image.size} != {cell}")
        alpha = np.unique(a[:, :, 3])
        if not set(alpha.tolist()) <= {0, 255}:
            report["errors"].append(f"frame {i}: soft alpha values {alpha.tolist()[:6]}")
        op = a[:, :, 3] > 0
        if not op.any():
            report["errors"].append(f"frame {i}: empty")
            continue
        cols = {tuple(c) for c in np.unique(a[op][:, :3], axis=0).tolist()}
        bad = {c for c in cols if c not in pal}
        if bad:
            report["errors"].append(f"frame {i}: off-palette colours {sorted(bad)[:4]}")
        colours |= cols
        ys, xs = np.nonzero(op)
        if xs.min() == 0 or ys.min() == 0 or xs.max() == cell[0] - 1 or ys.max() == cell[1] - 1:
            report["errors"].append(f"frame {i}: touches the cell edge (art may be clipped)")
        hashes.add(a.tobytes())
        feet.append(int(ys.max()))
    report["distinct_frame_count"] = len(hashes)
    if len(hashes) != len(cycle.frames):
        report["errors"].append("duplicate frames")
    report["visible_color_count"] = len(colours)
    report["feet_rows"] = feet
    # gait: planted toes must travel exactly -step_px per frame
    if cycle.step_px:
        n = len(cycle.frames)
        for leg in ("near", "far"):
            for i in range(n):
                cur, nxt = cycle.frames[i].meta.get(leg), cycle.frames[(i + 1) % n].meta.get(leg)
                if cur and nxt and cur.get("grounded") and nxt.get("grounded"):
                    dx = nxt["toe"][0] - cur["toe"][0]
                    if dx != -cycle.step_px:
                        report["errors"].append(f"{leg} toe slides at frame {i}->{(i+1)%n}: dx={dx}")
    diffs = []
    for i in range(len(cycle.frames)):
        a = np.array(cycle.frames[i].image)
        b = np.array(cycle.frames[(i + 1) % len(cycle.frames)].image)
        diffs.append(int(np.any(a != b, axis=-1).sum()))
    report["changed_pixels_per_adjacent_pair_including_loop"] = diffs
    if report["errors"]:
        report["status"] = "failed"
    return report
