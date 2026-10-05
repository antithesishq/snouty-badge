#!/usr/bin/env python3
"""Build the track packs' content (M7 Track B): Dead Mall and The Boneyard.

    python3 tools/packs/make_packs.py              (from the cart directory)
    python3 tools/packs/make_packs.py --pack dead_mall --review DIR

For each pack (tools/packs/<pack>.py: palette, tiles, background, horizon,
props; its arena in tools/packs/arenas.py) this writes the pack directory
assets/packs/<pack>/ of docs/PACKS.md: pal.bin, tiles.bin, horizon.bin,
attr.bin (build_tracks.write_league's files), per track and arena
<id>_map.bin, <id>_center.bin, <id>_feat.bin (and <id>_arena.bin),
props.png and pack.toml (with every track's props placements), then runs
tools/build_pack.py's build into assets/packs/<pack>/<FILE>.GCP. Review
images go to docs/packs/<pack>/ (tileset, horizon, props, half-scale map
previews); `--review DIR` also writes full-size previews and Mode 7 mock
frames (packs/common.py mock_frame) there.

Track sources are assets/packs/<pack>/tracks/*.track: build_tracks.py's
format (control points `x y half features`) plus these Track B lines and
words, stripped before the rasterizer sees them:

  name <TRACK NAME>          the menu name (default: the file stem, upper case)
  order <n>                  position in the pack (1..)
  floor <variant>            the road floor (<pack>.ROAD_VARIANTS)
  background <kind>          the wallpaper beyond the walls (<pack>.background)
  centerline <yes|no>        runway dashes along the line (packs that have them)
  prop <kind> <x> <y>        one prop at world px (x, y), off the road
  props <k1,k2..> seg <i> side <left|right|both> gap <px> [off <px>] [skip <n>]
  solid <kind> <x> <y> <radius>   a solid prop (a wall circle) at (x, y)
                             a row of props along segment i, `off` px beyond
                             the road's edge (default 20), every `gap` px;
                             kinds cycle; a spot on or near road is skipped
  furrow <half> <x y> <x y>..  a trench (pit tiles) along the polyline, painted
                             only over the wallpaper beyond the walls (cosmetic)
  features: crust[,len=N,warn=W,period=P,lo=A,hi=B]  a band of crust (SPEC 19.4)
                             across the road at the segment's middle, N px either
                             side (12), breaking W ticks after the first touch
                             (30) and broken for P ticks (300); only the road
                             tiles from A to B px off the centerline (right of
                             travel positive; default all of the road), so a
                             band can leave a way round its hole
            shadow[,len=N]   a wing shadow band across the road (cosmetic)
            drift[,p=N]      sand drifts over N% of the segment's road (cosmetic)

Row and `prop` props are decorative and kept off the drivable floor; a
`solid` prop must sit off the racing line (the validator checks that its
circle leaves the centerline 24 px clear). A crust band is written as a
crust record (docs/PACKS.md: warn 30 and period 300 unless the source says, its tiles' rectangle); a
`sweeper` mover's record names the pack's MOVER_CELL as its sprite. Everything is deterministic (seeded from crc32
of the names); the script validates and exits non-zero on any failure.
"""
from __future__ import annotations

import argparse
import importlib
import json
import math
import random
import sys
import tempfile
import zlib
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import common as C  # noqa: E402
import build_tracks as bt  # noqa: E402
from leagues import A_SURF, DRIVABLE, ATTR_NAMES  # noqa: E402

PACK_NAMES = ("dead_mall", "boneyard", "seabed", "cold_storage")
MY_FEATS = ("crust", "shadow", "drift")
CRUST_LEN, SHADOW_LEN = 12, 14
PROP_OFF, PROP_CLEAR = 20, 10     # default offset beyond the road edge; footprint radius kept off road
# The crust record (docs/PACKS.md): warn at least (band depth + 24 px of
# car) / 1.7 px/tick, so the crack shows while the car that made it is still
# crossing (M9.1: that car gets across whatever the warn; the warn is the
# next car's notice). A 24 px band (len 12) needs 29: 30 ticks. Broken for
# 300 ticks, so every car within 5 s behind meets the hole.
CRUST_WARN, CRUST_PIT_TICKS = 30, 300
K_CRUST = 4                       # world.HazardKind.crust
PROPS_MAX = 24                    # docs/PACKS.md: props records per track


def load_pack(name):
    return importlib.import_module(name)


# ------------------------------------------------------------ sources
class Source:
    """A Track B track source: the rasterizer's lines plus ours."""

    def __init__(self, path, pack):
        self.path, self.stem = path, path.stem
        self.name = self.stem.replace("_", " ").upper()
        self.order, self.floor, self.bg, self.centerline = 99, None, None, False
        self.props_explicit, self.props_rows = [], []
        self.my = {}               # control point index -> {feature: opts}
        self.furrows = []          # (half width, [(x, y), ...]) scorched trenches beyond the road
        keep = []
        idx = 0
        for ln, raw in enumerate(path.read_text().splitlines(), 1):
            body = raw.split("#", 1)[0]
            w = body.split()
            if not w:
                keep.append(raw)
                continue
            if w[0] == "name":
                self.name = " ".join(w[1:])
            elif w[0] == "order":
                self.order = int(w[1])
            elif w[0] == "floor":
                self.floor = w[1]
            elif w[0] == "background":
                self.bg = w[1]
            elif w[0] == "centerline":
                self.centerline = w[1] == "yes"
            elif w[0] == "prop":
                self.props_explicit.append((w[1], float(w[2]), float(w[3]), 0, ln))
            elif w[0] == "furrow":
                v = [float(t) for t in w[2:]]
                self.furrows.append((float(w[1]), list(zip(v[0::2], v[1::2]))))
            elif w[0] == "solid":
                self.props_explicit.append((w[1], float(w[2]), float(w[3]), int(w[4]), ln))
            elif w[0] == "props":
                o = dict(zip(w[2::2], w[3::2]))
                self.props_rows.append(dict(kinds=w[1].split(","), seg=int(o["seg"]), side=o.get("side", "both"),
                                            gap=float(o.get("gap", 32)), off=float(o.get("off", PROP_OFF)),
                                            skip=int(o.get("skip", 0)), line=ln))
            elif w[0] in ("league", "width", "pit_band"):
                keep.append(f"league {pack}" if w[0] == "league" else body)
            else:
                rest, mine = [], {}
                for f in w[3:]:
                    nm, _, kv = f.partition(",")
                    if nm in MY_FEATS:
                        mine[nm] = {k: int(v) for k, _, v in (a.partition("=") for a in kv.split(",") if a)}
                    else:
                        rest.append(f)
                if mine:
                    self.my[idx] = mine
                keep.append(" ".join(w[:3] + rest))
                idx += 1
        if not any(k.startswith("league") for k in keep):
            keep.insert(0, f"league {pack}")
        self.text = "\n".join(keep) + "\n"


# ------------------------------------------------------------ geometry
def tile_arcs(trk, tiles):
    nj, d = bt.nearest_dense(trk, np.array(tiles))
    return nj, d


def band_tiles(trk, jm, lo, hi, cand, nj):
    """build_tracks' band (a straight cut across the line at dense jm)."""
    nd = len(trk.dx)
    a = math.atan2(trk.dy[(jm + 2) % nd] - trk.dy[jm - 2], trk.dx[(jm + 2) % nd] - trk.dx[jm - 2])
    a = round(a / (math.pi / 4)) * (math.pi / 4)
    ux, uy = math.cos(a), math.sin(a)
    out = []
    for (ty, tx), j in zip(cand, nj):
        rx, ry = tx * 8 + 4 - trk.dx[jm], ty * 8 + 4 - trk.dy[jm]
        along, across = rx * ux + ry * uy, -rx * uy + ry * ux
        if lo < along <= hi and abs(across) <= trk.dhalf[jm] + 10 and abs(trk.arc_dist(j * trk.ds, jm * trk.ds)) < 64:
            out.append((ty, tx))
    return out


def seg_dist(px, py, a, b):
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / max(dx * dx + dy * dy, 1e-9)))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def seg_mid_dense(trk, i):
    a, b = trk.seg_start[i], trk.seg_start[i + 1]
    return int(round((a + b) / 2 / trk.ds)) % len(trk.dx)


# ------------------------------------------------------------ one track
def build_one(pack, mod, ts, src, errs, out, review, report):
    lg = dict(mod.LEAGUE)
    if src.bg:
        lg["background"] = mod.background(src.bg)
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / f"{src.stem}.track"
        p.write_text(src.text)
        trk = bt.Track(p)
    tmap, surf = bt.build_track(trk, ts, lg, random.Random(zlib.crc32(src.stem.encode())))
    variant = src.floor or next(iter(mod.ROAD_VARIANTS))
    if variant not in mod.ROAD_VARIANTS:
        errs.append(f"{src.stem}: unknown floor {variant}")
        variant = next(iter(mod.ROAD_VARIANTS))
    vmap = mod.ROAD_VARIANTS[variant]
    tmap = C.remap_road(tmap, vmap)
    plain = {vmap.get(r, r) for r in C.ROAD_ROLES}
    surf_list = [tuple(q) for q in np.argwhere(surf)]
    nj, _ = tile_arcs(trk, surf_list)
    jof = {q: j for q, j in zip(surf_list, nj)}
    lateral = {}
    nd = len(trk.dx)
    for (ty, tx), j in jof.items():
        ox, oy = tx * 8 + 4 - trk.dx[j], ty * 8 + 4 - trk.dy[j]
        tdx, tdy = trk.dx[(j + 2) % nd] - trk.dx[j - 2], trk.dy[(j + 2) % nd] - trk.dy[j - 2]
        lateral[(ty, tx)] = (tdx * oy - tdy * ox) / math.hypot(tdx, tdy)
    # Centerline dashes (runway / taxiway lines), 16 px on, 16 off.
    if src.centerline:
        lines = getattr(mod, "CENTER_LINES", {}).get(variant)
        if not lines:
            errs.append(f"{src.stem}: centerline on a floor without dashes")
        else:
            for q, j in jof.items():
                if tmap[q] in plain and abs(lateral[q]) <= 4 and int(j * trk.ds // 16) % 2 == 0:
                    tmap[q] = lines[bt.axis_of(int(trk.turn[min(255, j * 256 // nd)]))]
    crusts = []
    for i, mine in sorted(src.my.items()):
        jm = seg_mid_dense(trk, i)
        if "shadow" in mine:
            ln = mine["shadow"].get("len", SHADOW_LEN)
            sh = getattr(mod, "SHADOW_TILES", {}).get(variant)
            for q in band_tiles(trk, jm, -ln, ln, surf_list, nj):
                if tmap[q] in plain or tmap[q] in getattr(mod, "STRIPE_TILES", ()):
                    tmap[q] = sh
        if "drift" in mine:
            pct = mine["drift"].get("p", 30) / 100
            for q, j in jof.items():
                if trk.seg[j] == i and tmap[q] in plain:
                    h = C.hash01(q[0], q[1], 77)
                    if h < pct:
                        tmap[q] = mod.DRIFT_HEAVY if h < pct * 0.3 else mod.DRIFT
        if "crust" in mine:
            ln = mine["crust"].get("len", CRUST_LEN)
            warn = mine["crust"].get("warn", CRUST_WARN)
            period = mine["crust"].get("period", CRUST_PIT_TICKS)
            lat_lo, lat_hi = mine["crust"].get("lo", -999), mine["crust"].get("hi", 999)
            if warn * 17 < (2 * ln + 24) * 10:
                errs.append(f"{src.stem}: crust warn {warn} under (depth {2 * ln} + 24) / 1.7 px/tick")
            cells = []
            for q in band_tiles(trk, jm, -ln, ln, surf_list, nj):
                if not lat_lo <= lateral[q] <= lat_hi:
                    continue
                if tmap[q] in plain or tmap[q] in getattr(mod, "STRIPE_TILES", ()):
                    tmap[q] = C.CRUST
                    cells.append(q)
            if not cells:
                errs.append(f"{src.stem}: crust on segment {i} painted nothing")
                continue
            ys, xs = zip(*cells)
            crusts.append(dict(seg=i, tiles=[[int(x), int(y)] for y, x in cells],
                               x0=min(xs) * 8, y0=min(ys) * 8, x1=max(xs) * 8 + 8, y1=max(ys) * 8 + 8,
                               sample=int(jm * 256 // nd), warn=warn, period=period))
    # Furrows: pit tiles over the wallpaper (tiles 1..15) along polylines.
    for half, pts in src.furrows:
        for ty in range(128):
            for tx in range(128):
                if not 1 <= tmap[ty, tx] <= 15:
                    continue
                px, py = tx * 8 + 4, ty * 8 + 4
                d = min(seg_dist(px, py, a, b) for a, b in zip(pts, pts[1:]))
                if d <= half:
                    tmap[ty, tx] = C.PIT if d <= half - 8 else getattr(mod, "FURROW_LIP", C.PIT)
    # Validation: build_tracks' checks on the final map.
    clear = bt.validate(trk, tmap, ts, errs)
    hills = bt.validate_hills(trk, errs)
    crates = bt.validate_crates(trk, tmap, ts, errs)
    bt.validate_hazards(trk, tmap, ts, surf, errs)
    for x, y, k in crates:
        for c in crusts:
            if c["x0"] - 24 <= x <= c["x1"] + 24 and c["y0"] - 24 <= y <= c["y1"] + 24:
                errs.append(f"{src.stem}: crate at ({x:.0f},{y:.0f}) next to crust")
    for c in crusts:
        if min(abs(trk.arc_dist(c["sample"] * trk.length / 256, trk.sidx[k] * trk.ds)) for k in bt.SEAMS) < 40:
            errs.append(f"{src.stem}: crust within 40 px of the start line or a sector seam")
        for kind, jm, o, e0, e1 in trk.hazards:
            if abs(trk.arc_dist(jm * trk.ds, c["sample"] * trk.length / 256)) < 48:
                errs.append(f"{src.stem}: crust within 48 px of a hazard lane")
    if len(trk.hazards) + len(crusts) > bt.HAZARD_MAX:
        errs.append(f"{src.stem}: {len(trk.hazards)} hazards + {len(crusts)} crusts over the {bt.HAZARD_MAX} the World holds")
    if not 3500 <= trk.length <= 4500:
        errs.append(f"{src.stem}: lap length {trk.length:.0f} outside 3500..4500 (SPEC 5.2)")
    r, rx, ry, rseg = bt.min_radius(trk)
    if r < 30:
        errs.append(f"{src.stem}: corner radius {r:.0f} px at ({rx:.0f},{ry:.0f}) under 30 px")
    props = place_props(src, mod, trk, tmap, ts, errs)
    packed = bt.pack_map(tmap.tobytes())
    if bt.unpack_map(packed) != tmap.tobytes():
        errs.append(f"{src.stem}: packed map does not round-trip")
    if len(packed) >= 8192:
        errs.append(f"{src.stem}: packed map {len(packed)} bytes, budget under 8192")
    feat = mover_sprites(bt.hazard_bytes(trk), mod.MOVER_CELL) + crust_bytes(crusts)
    files = {f"{src.stem}_map.bin": packed, f"{src.stem}_center.bin": bt.center_bytes(trk), f"{src.stem}_feat.bin": feat}
    for n, d in files.items():
        (out / n).write_bytes(d)
    cells_used = {p["cell"] for p in props} | ({mod.MOVER_CELL} if any(k == bt.K_MOVER for k, *_ in trk.hazards) else set())
    if report:
        print(f"track {src.stem} ({src.name}): lap {trk.length:.0f} px, floor {variant}, clearance {clear:.0f}, "
              f"min radius {r:.0f}, {len(trk.hops)} ramp pit(s), {len(crates)} crates, "
              f"{len(trk.hazards)} hazards, {len(crusts)} crust bands, {len(props)} props in {len(cells_used)} cells, "
              f"map {len(packed)} B")
    return dict(trk=trk, tmap=tmap, props=props, crusts=crusts, files=files, name=src.name, stem=src.stem,
                laps=3, hazards=[(k, jm) for k, jm, *_ in trk.hazards])


def mover_sprites(feat, cell):
    """A mover record's sprite: props cell + 1 in byte 0's high nibble."""
    b = bytearray(feat)
    for r in range(0, len(b), bt.HAZARD_RECORD):
        if b[r] & 15 == bt.K_MOVER:
            b[r] = (b[r] & 15) | ((cell + 1) << 4)
    return bytes(b)


def crust_bytes(crusts):
    """Crust records (docs/PACKS.md, kind 4): the band's whole-tile
    rectangle (x1, y1 exclusive), warn and period (CRUST_WARN and
    CRUST_PIT_TICKS unless the source says), the rest 0."""
    out = bytearray()
    for c in crusts:
        out += bytes([K_CRUST, c["warn"], 0, 0])
        out += np.array([c["x0"], c["y0"], c["x1"], c["y1"], c["period"], 0, 0], "<u2").tobytes()
        out += bytes([0, 0])
    return bytes(out)


def prop_spot_ok(trk, attr, x, y, reach=PROP_CLEAR):
    """A prop's footprint is off the drivable floor and inside the map margin."""
    if not (24 <= x <= 1000 and 24 <= y <= 1000):
        return False
    for oy in (-reach, 0, reach):
        for ox in (-reach, 0, reach):
            if attr[int(y + oy) // 8 % 128, int(x + ox) // 8 % 128] in DRIVABLE:
                return False
    return True


def place_props(src, mod, trk, tmap, ts, errs):
    attr = ts.attr[tmap]
    props = []
    for kind, x, y, radius, ln in src.props_explicit:
        if kind not in mod.PROP:
            errs.append(f"{src.stem}:{ln}: unknown prop {kind}")
            continue
        if radius == 0 and not prop_spot_ok(trk, attr, x, y):
            errs.append(f"{src.stem}:{ln}: prop {kind} at ({x:.0f},{y:.0f}) on or next to the road")
            continue
        if radius and np.hypot(trk.dx - x, trk.dy - y).min() < radius + 24:
            errs.append(f"{src.stem}:{ln}: solid prop {kind} at ({x:.0f},{y:.0f}) within {radius + 24} px of the line")
            continue
        props.append(dict(kind=kind, cell=mod.PROP[kind], x=int(x), y=int(y), radius=radius))
    nd = len(trk.dx)
    for row in src.props_rows:
        a, b = trk.seg_start[row["seg"]], trk.seg_start[row["seg"] + 1]
        sides = (-1, 1) if row["side"] == "both" else ((-1,) if row["side"] == "left" else (1,))
        placed = 0
        k = 0
        s = a + row["gap"] / 2
        while s < b:
            j = int(round(s / trk.ds)) % nd
            tdx, tdy = trk.dx[(j + 2) % nd] - trk.dx[j - 2], trk.dy[(j + 2) % nd] - trk.dy[j - 2]
            n = math.hypot(tdx, tdy)
            rx, ry = -tdy / n, tdx / n          # driver's right (y down)
            for sg in sides:
                if row["skip"] and k % (row["skip"] + 1) == row["skip"]:
                    k += 1
                    continue
                d = trk.dhalf[j] + row["off"]
                x, y = trk.dx[j] + rx * d * sg, trk.dy[j] + ry * d * sg
                kind = row["kinds"][k % len(row["kinds"])]
                k += 1
                if kind not in mod.PROP:
                    errs.append(f"{src.stem}:{row['line']}: unknown prop {kind}")
                    continue
                if prop_spot_ok(trk, attr, x, y):
                    props.append(dict(kind=kind, cell=mod.PROP[kind], x=int(round(x)), y=int(round(y)), radius=0))
                    placed += 1
            s += row["gap"]
        if not placed:
            errs.append(f"{src.stem}:{row['line']}: the props row on segment {row['seg']} placed nothing")
    if len(props) > PROPS_MAX:
        errs.append(f"{src.stem}: {len(props)} props, over {PROPS_MAX}")
    return props


# ------------------------------------------------------------ previews
def preview(res, ts, path, scale=1.0, cells=None):
    img = Image.fromarray(bt.render_map(res["tmap"], ts))
    dr = ImageDraw.Draw(img)
    trk = res["trk"]
    pts = list(zip(trk.dx[::2], trk.dy[::2]))
    dr.line(pts + [pts[0]], fill=(255, 64, 200), width=1)
    x0, y0 = trk.dx[0], trk.dy[0]
    a = trk.turn[0] / 65536 * 2 * math.pi
    dr.ellipse([x0 - 5, y0 - 5, x0 + 5, y0 + 5], outline=(255, 255, 0), width=2)
    dr.line([(x0, y0), (x0 + 24 * math.cos(a), y0 + 24 * math.sin(a))], fill=(255, 255, 0), width=2)
    for x, y, _ in trk.crates():
        dr.rectangle([x - 4, y - 4, x + 4, y + 4], outline=(255, 255, 255))
    for kind, jm, o, e0, e1 in trk.hazards:
        dr.line([e0, e1], fill=(255, 120, 30) if kind == bt.K_BLAST else (255, 230, 40), width=2)
    for c in res["crusts"]:
        dr.rectangle([c["x0"], c["y0"], c["x1"], c["y1"]], outline=(120, 255, 255))
    for p in res["props"]:
        dr.ellipse([p["x"] - 3, p["y"] - 3, p["x"] + 3, p["y"] + 3], fill=(40, 255, 120), outline=(0, 0, 0))
    if scale != 1.0:
        img = img.resize((int(1024 * scale), int(1024 * scale)), Image.LANCZOS)
    img.save(path, optimize=True)


def mock_frames(res, ts, hz, cells, n=8, every=None):
    trk = res["trk"]
    props = [(p["x"], p["y"], p["cell"]) for p in res["props"]]
    frames, labels = [], []
    for k in range(0, 256, 256 // n):
        x, y, yaw = C.chase_cam(trk, k)
        frames.append(C.mock_frame(res["tmap"], ts, hz, x, y, yaw, props, cells, car=True))
        labels.append(f"sample {k}")
    return frames, labels


# ------------------------------------------------------------ one pack
def toml_props(props):
    rows = [f"[{p['cell']}, {p['x']}, {p['y']}, {p['radius']}]" for p in props]
    lines = []
    for k in range(0, len(rows), 6):
        lines.append("  " + ", ".join(rows[k:k + 6]) + ",")
    return "[\n" + "\n".join(lines) + "\n]" if rows else "[]"


def write_toml(path, mod, results, arena, ncells):
    out = [f"# {mod.TITLE}: written by tools/packs/make_packs.py (do not edit; edit the",
           f"# sources in tools/packs/). docs/PACKS.md.",
           f'file = "{mod.FILE}"', f'name = "{mod.TITLE}"', f'league = "{mod.TITLE}"', "",
           "[props]", 'sheet = "props.png"', f"cell = [{C.PROP_W}, {C.PROP_H}]", f"count = {ncells}", ""]
    for r in results:
        out += ["[[track]]", f'id = "{r["stem"]}"', f'name = "{r["name"]}"', f"laps = {r['laps']}",
                f"props = {toml_props(r['props'])}", ""]
    if arena:
        out += ["[[arena]]", f'id = "{arena["stem"]}"', f'name = "{arena["name"]}"',
                f"props = {toml_props(arena['props'])}", ""]
    path.write_text("\n".join(out))


def build_pack(name, errs, review=None, report=True):
    import build_pack as bp
    mod = load_pack(name)
    C.L.LEAGUES[name] = mod.LEAGUE
    root = C.PACKS / name
    rev = C.CART / "docs" / "packs" / name
    root.mkdir(parents=True, exist_ok=True)
    rev.mkdir(parents=True, exist_ok=True)
    pal = mod.LEAGUE["pal"]
    ts = mod.LEAGUE["tiles"](pal)
    if (ts.tiles == 0).any():
        errs.append(f"{name}: a tile uses palette index 0")
    if len(pal.rgb) > 256:
        errs.append(f"{name}: {len(pal.rgb)} palette entries")
    if list(np.nonzero(ts.attr == C.A_CRUST)[0]) not in ([], [121, 122, 123]):
        errs.append(f"{name}: crust attribute on tiles {list(np.nonzero(ts.attr == C.A_CRUST)[0])}")
    hz = mod.LEAGUE["horizon"](pal.rgb[0], random.Random(zlib.crc32(name.encode())))
    f, b, fpal, bpal = hz
    if not ((f[-1] == 1).all() and fpal[1] == pal.rgb[0] and (f == 15).any()):
        errs.append(f"{name}: front horizon must end in a fog row (entry 1) and use LED entry 15")
    if f.max() > 15 or b.max() > 15 or len(fpal) != 16 or len(bpal) != 16:
        errs.append(f"{name}: horizon out of 4-bit range")
    files = {"pal.bin": pal.table565().tobytes(), "tiles.bin": bt.packed_checked(ts.tiles.tobytes(), C.NTILES * 64),
             "horizon.bin": bt.packed_checked(L4(f, b, fpal, bpal), 12352), "attr.bin": ts.attr.tobytes()}
    for n, d in files.items():
        (root / n).write_bytes(d)
    cells = mod.draw_props()
    perr, ncol = C.validate_props(cells, name)
    errs += perr
    C.props_strip(cells).to_image().save(root / "props.png")
    C.tiles_sheet(ts, rev / "tiles.png", f"{mod.TITLE} tileset (tools/packs/{name}.py)")
    C.horizon_image(*hz).save(rev / "horizon.png")
    C.props_sheet_image(cells, mod.PROP_LABELS, rev / "props.png", f"{mod.TITLE} props (32x48, 4 bpp, {ncol} colours)")
    srcs = sorted((Source(p, name) for p in (HERE / "src" / name).glob("*.track")), key=lambda s: (s.order, s.stem))
    results = []
    for src in srcs:
        res = build_one(name, mod, ts, src, errs, root, review, report)
        results.append(res)
        preview(res, ts, rev / f"{src.stem}.png", scale=0.5)
    arena = None
    if getattr(mod, "ARENA", None):
        import pack_arena
        arena = pack_arena.build(mod, name, ts, root, rev, errs, report)
    write_toml(root / "pack.toml", mod, results, arena, len(cells))
    gcp = None
    if not errs:
        try:
            file, data, rep = bp.build(root)
            gcp = root / f"{file}.GCP"
            gcp.write_bytes(data)
            # The host tests and previews embed a copy (never the badge cart).
            (C.CART / "cart" / "src" / "gen" / "packs" / f"{file}.GCP").write_bytes(data)
            if report:
                print("\n".join(rep))
        except bp.PackError as e:
            errs.append(f"{name}: build_pack: {e}")
    if report:
        print(f"pack {name}: {len(results)} tracks, arena {'yes' if arena else 'no'}, props {len(cells)} cells "
              f"({C.props_4bpp_bytes(cells)} B at 4 bpp, {ncol} colours), tiles {len(files['tiles.bin'])} B, "
              f"horizon {len(files['horizon.bin'])} B packed" + (f", {gcp.name} {gcp.stat().st_size} B" if gcp else ""))
    if review:
        rd = Path(review)
        rd.mkdir(parents=True, exist_ok=True)
        for res in results + ([arena] if arena else []):
            if res is not arena:
                preview(res, ts, rd / f"{name}_{res['stem']}_map.png")
            fr, lab = (pack_arena.mock_frames(res, ts, hz, cells) if res is arena else mock_frames(res, ts, hz, cells))
            g = C.grid_of(fr, 4, 2, lab, f"{mod.TITLE}: {res['name']} (Mode 7 mock)")
            g.save(rd / f"{name}_{res['stem']}_mock.png")
            # The contact sheet: the overhead map (half scale) beside the frames.
            mp = Image.open(rev / (f"{res['stem']}_preview.png" if res is arena else f"{res['stem']}.png")).convert("RGB")
            sheet = Image.new("RGB", (mp.width + g.width + 12, max(mp.height, g.height) + 12), C.BG)
            sheet.paste(mp, (6, 6 + 22))
            sheet.paste(g, (mp.width + 12, 6))
            sheet.save(rd / f"{name}_{res['stem']}_contact.png")
    return dict(mod=mod, ts=ts, results=results, arena=arena, gcp=gcp)


def L4(f, b, fpal, bpal):
    return C.L.pack4(f) + C.L.pack4(b) + np.array([C.L.rgb565(c) for c in fpal], "<u2").tobytes() \
        + np.array([C.L.rgb565(c) for c in bpal], "<u2").tobytes()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--pack", choices=PACK_NAMES)
    ap.add_argument("--review", help="also write full-size previews and Mode 7 mocks here")
    args = ap.parse_args()
    errs = []
    for name in ([args.pack] if args.pack else PACK_NAMES):
        build_pack(name, errs, args.review)
    for e in errs:
        print("ERROR:", e, file=sys.stderr)
    sys.exit(1 if errs else 0)


if __name__ == "__main__":
    main()
