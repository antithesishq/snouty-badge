"""A pack's BATTLE arena (SPEC 19.9) through tools/build_arena.py.

The pack module's ARENA is a `PackArena` subclass: its __init__ sets the
design grid and pads as build_arena.Arena's (kind, ramps, kickers, bays,
spawns, pads, nodes and jumps, sweep_row, sweeper), plus the Track B
extras applied after build_arena wrote its files:

  name, stem       the menu name and the file stem
  background       the wallpaper kind (<pack>.background) for the islands
  floor(tmap, big, rng)   build_arena's paint hook (the arena's own floor)
  post(tmap)       cosmetic retouches on the finished map (attributes kept)
  mover            an extra crossing mover record, a dict of build_tracks'
                   sweeper options plus a, b: rel tile ends (or None)
  props            [(kind, x, y), ...] decorative props, world px

The mover records (the Sweeper row, `mover`) name the pack's MOVER_CELL as
their sprite. Validation: build_arena's (every pad and node on floor, the
graph connected with and without jumps, the jumps clean at speed and
falling short at a crawl), the mover's cycle, the props off the floor,
and the slot budget (blob + props cells + mover cell).
"""
from __future__ import annotations

import math
import random
import zlib

import numpy as np

import common as C
import build_tracks as bt
import build_arena as ba
from leagues import DRIVABLE

O, ARENA, T = ba.O, ba.ARENA, 8
FLOOR, SOLID, PIT, FENCE = ba.FLOOR, ba.SOLID, ba.PIT, ba.FENCE


class PackArena(ba.Arena):
    background = None
    mover = None
    props = ()
    sweeper = None
    sweep_row = 7

    def __init__(self):    # subclasses set everything; no Sandbox
        pass

    def set_nodes(self, nodes, jumps):
        """nodes: [(name, x, y, flags)], jumps: [(from, to)]."""
        self.node_names = [n for n, *_ in nodes]
        self.nodes = [(x, y, f) for _, x, y, f in nodes]
        ix = {n: i for i, n in enumerate(self.node_names)}
        self.jumps = {ix[a]: ix[b] for a, b in jumps}
        assert len(self.jumps) == len(jumps) and len(self.nodes) <= ba.NAV_MAX

    def paint(self, tmap, big, rng):
        if hasattr(self, "floor"):
            self.floor(tmap, big, rng)


def rel_world(x, y):
    return (O + x) * T + T / 2, (O + y) * T + T / 2


def mover_record(o, cell):
    (ax, ay), (bx, by) = rel_world(*o["a"]), rel_world(*o["b"])
    rec = bytes([bt.K_MOVER | (cell + 1) << 4, o["warn"], o["size"], o["damage"]])
    rec += np.array([int(ax), int(ay), int(bx), int(by), o["period"], 0, o["phase"] % o["period"]], "<u2").tobytes()
    rec += bytes([o["push"], o["speed"]])
    travel = math.ceil(int(math.hypot(bx - ax, by - ay)) * 32 / o["speed"])
    return rec, travel


def build(mod, pack, ts, root, rev, errs, report):
    ar = mod.ARENA()
    key = f"{pack}_arena"
    lg = dict(mod.LEAGUE)
    if ar.background:
        lg["background"] = mod.background(ar.background)
    C.L.LEAGUES[key] = lg
    sizes = ba.build(root, rev, errs, quiet=not report, ar=ar, league=key, name=ar.stem)
    from PIL import Image
    (rev / f"{ar.stem}_map.png").unlink(missing_ok=True)   # the plain copy; the preview has the graph
    png = rev / f"{ar.stem}_preview.png"   # build_arena writes it at 1:1; the committed copy is half scale
    Image.open(png).convert("RGB").resize((512, 512), Image.LANCZOS).save(png, optimize=True)
    mp, fp = root / f"{ar.stem}_map.bin", root / f"{ar.stem}_feat.bin"
    tmap = np.frombuffer(bt.unpack_map(mp.read_bytes()), np.uint8).reshape(128, 128).copy()
    before = ts.attr[tmap].copy()
    if hasattr(ar, "post"):
        ar.post(tmap)
    if (ts.attr[tmap] != before).any():
        errs.append(f"{ar.stem}: post() changed an attribute")
    packed = bt.pack_map(tmap.tobytes())
    assert bt.unpack_map(packed) == tmap.tobytes()
    mp.write_bytes(packed)
    feat = bytearray(fp.read_bytes())
    for r in range(0, len(feat), bt.HAZARD_RECORD):
        if feat[r] & 15 == bt.K_MOVER:
            feat[r] = (feat[r] & 15) | (mod.MOVER_CELL + 1) << 4
    movers = len(feat) // bt.HAZARD_RECORD
    if ar.mover:
        rec, travel = mover_record(ar.mover, mod.MOVER_CELL)
        if travel + ar.mover["warn"] >= ar.mover["period"] // 2:
            errs.append(f"{ar.stem}: mover crossing {travel} + warn must be under half the period")
        feat += rec
        movers += 1
    fp.write_bytes(bytes(feat))
    attr = ts.attr[tmap]
    props = []
    for kind, x, y in ar.props:
        if kind not in mod.PROP:
            errs.append(f"{ar.stem}: unknown prop {kind}")
            continue
        clear = all(attr[int(y + oy) // 8 % 128, int(x + ox) // 8 % 128] not in DRIVABLE
                    for oy in (-C.PROP_W // 3, 0, C.PROP_W // 3) for ox in (-C.PROP_W // 3, 0, C.PROP_W // 3))
        if not clear:
            errs.append(f"{ar.stem}: prop {kind} at ({x},{y}) on or next to the floor")
            continue
        props.append(dict(kind=kind, cell=mod.PROP[kind], x=int(x), y=int(y), radius=0))
    blob = (root / f"{ar.stem}_arena.bin").read_bytes()
    cells = {p["cell"] for p in props} | ({mod.MOVER_CELL} if movers else set())
    need = len(blob) + len(cells) * C.PROP_W * C.PROP_H // 2
    if need > 5792:
        errs.append(f"{ar.stem}: arena blob {len(blob)} + {len(cells)} cells = {need} B, over 5792")
    if len(props) > 24:
        errs.append(f"{ar.stem}: {len(props)} props, over 24")
    if report:
        print(f"  arena {ar.stem} ({ar.name}): blob {len(blob)} B, {len(props)} props in {len(cells)} cells "
              f"(slot {need} of 5792 B), {movers} mover(s), map {len(packed)} B")
    return dict(stem=ar.stem, name=ar.name, tmap=tmap, props=props, ar=ar, crusts=[], trk=None,
                files={p.name: n for p, n in sizes.items()})


def mock_frames(res, ts, hz, cells):
    """Eight views: from each spawn pad facing in, and across the pit."""
    ar = res["ar"]
    props = [(p["x"], p["y"], p["cell"]) for p in res["props"]]
    frames, labels = [], []
    views = []
    for x, y, d in ar.spawns[:4]:
        px, py = (O + x + 1) * T, (O + y + 1) * T
        a = d * math.pi / 2
        views.append((px - math.cos(a) * C.CAM_BEHIND, py - math.sin(a) * C.CAM_BEHIND, a, f"spawn ({x},{y})"))
    for name in [n for n in ar.node_names if ar.node_names.index(n) in ar.jumps][:4]:
        i = ar.node_names.index(name)
        x0, y0 = rel_world(*ar.nodes[i][:2])
        x1, y1 = rel_world(*ar.nodes[ar.jumps[i]][:2])
        a = math.atan2(y1 - y0, x1 - x0)
        views.append((x0 - math.cos(a) * C.CAM_BEHIND, y0 - math.sin(a) * C.CAM_BEHIND, a, f"jump {name}"))
    for cx, cy, a, lab in views:
        frames.append(C.mock_frame(res["tmap"], ts, hz, cx, cy, a, props, cells, car=True))
        labels.append(lab)
    return frames, labels
