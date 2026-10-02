#!/usr/bin/env python3
"""Build the Snouty Zero league art and track tables into assets/gen/.

    python3 tools/build_tracks.py                 (from the cart directory)
    python3 tools/build_tracks.py --track cold_aisle --out assets/gen

Reads cart/src/tracks/*.track (SPEC section 7) and writes the files of
PLAN.md "Generated data formats":

  <league>_tiles.bin   256 tiles x 8x8 palette indices (16384 bytes)
  <league>_pal.bin     256 x u16 RGB565, entry 0 = fog/horizon colour
  <league>_horizon.bin front 512x32 4bpp, back 256x32 4bpp, 2 x 16 x u16
  <track>_map.bin      128x128 tile indices, map[y][x]
  <track>_attr.bin     256 attributes, one per tile index
  <track>_center.bin   256 samples x (x u16, y u16, tangent u16, half u8, flags u8)

plus docs/<track>_preview.png (1:1 map with the centerline), and
docs/<league>_tiles.png / docs/<league>_tiles.txt (contact sheet, index list).

Rasterizer rules:
  * The closed centerline is a centripetal Catmull-Rom spline through the
    control points, resampled every ~1 world px (the "dense" line). Half
    width is smoothstep-interpolated between control points.
  * A 1024x1024 surface mask is the union of discs of the local half width
    at every dense point. A tile is surface when at least 32 of its 64
    texels are in the mask (majority rule).
  * Every surface/near-surface tile is tagged with its nearest dense point:
    arc position, segment (control point i to i+1) and lateral distance.
    Features on point i apply to segment i. cold paints the whole segment;
    hot:N scatters N hot-spot tiles on the segment.
  * Bands are straight cuts: the drivable tiles whose centre lies within
    (lo, hi] px along the tangent of a centerline point (snapped to 45
    degrees so bands are clean rows, columns or diagonals) and within the
    half width (+10) across it. pad/throttled/hop: (-12, 12] at the
    segment middle (3 tiles, surface only). Start line: (-8, 8] at
    sample 0 (2 tiles, checker). Sector 1/2: (-4, 4] at samples 85/170
    (1 tile). A cut at least 8 px wide always stops a 4-connected path;
    the validator checks that the three marks split the loop in three.
  * Off-track tiles 4-adjacent to surface become edge pieces chosen by the
    4-neighbour surface mask (N=1, E=2, S=4, W=8): open-edge glow (attr 1)
    if the nearest sample's segment is `open`, else rail (attr 2). Tiles
    touching surface only diagonally get a corner piece of the same kind.
  * Everything else is the league background painter (seeded per track).

Everything is seeded from crc32 of the track or league name, so reruns are
byte-identical. The script validates its output and exits non-zero on any
failure. The tile vocabulary and the league painters live in
tools/leagues.py; only the Edge league exists so far, and a league is one
LEAGUES entry there (palette + tile painter + background + horizon).
"""
from __future__ import annotations

import argparse
import math
import random
import sys
import zlib
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

sys.dont_write_bytecode = True   # keep tools/ free of __pycache__
sys.path.insert(0, str(Path(__file__).resolve().parent))
from leagues import (  # noqa: E402  (tools/leagues.py: tile vocabulary + league painters)
    A_SURF, A_START, A_SEC1, A_SEC2, ATTR_NAMES, DRIVABLE, FLAG_BITS, SURF,
    SURF_DOT, SURF_SEAM_V, SURF_SEAM_H, SURF_SEAM_X, EDGE_OPEN, RAIL, PAD, THROT,
    COLD, HOT, HOP, START, SEC1, SEC2, RAIL_DIAG, EDGE_DIAG,
    N_, E_, S_, W_, rgb565, pack4, LEAGUES
)

CART = Path(__file__).resolve().parent.parent
T, MAPN, WORLD, NSAMP = 8, 128, 1024, 256
MARGIN = 100   # px between the centerline and the map's wrap edges


# ---------------------------------------------------------------- tracks
def parse_track(path):
    league, width, pts = None, 64, []
    for ln, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.split("#", 1)[0].split()
        if not line:
            continue
        if line[0] == "league":
            league = line[1]
        elif line[0] == "width":
            width = int(line[1])
        else:
            x, y = float(line[0]), float(line[1])
            half = float(line[2]) if len(line) > 2 else float(width)
            feats, hot = set(), 0
            for f in line[3:]:
                name, _, n = f.partition(":")
                if name not in FLAG_BITS:
                    raise SystemExit(f"{path}:{ln}: unknown feature {f!r}")
                feats.add(name)
                if name == "hot":
                    hot = int(n or 1)
            pts.append((x, y, half, feats, hot))
    if league not in LEAGUES or len(pts) < 4:
        raise SystemExit(f"{path}: needs a known league and at least 4 control points")
    return league, pts


def catmull_rom(pts, per_seg=600):
    """Centripetal Catmull-Rom through the closed point list. Returns fine
    samples (x, y, u) with u = segment index + t."""
    P = np.array([(p[0], p[1]) for p in pts])
    n = len(P)
    xs, us = [], []
    for i in range(n):
        p0, p1, p2, p3 = P[(i - 1) % n], P[i], P[(i + 1) % n], P[(i + 2) % n]
        t0 = 0.0
        t1 = t0 + np.linalg.norm(p1 - p0) ** 0.5
        t2 = t1 + np.linalg.norm(p2 - p1) ** 0.5
        t3 = t2 + np.linalg.norm(p3 - p2) ** 0.5
        tt = np.linspace(0, 1, per_seg, endpoint=False)
        t = (t1 + (t2 - t1) * tt)[:, None]
        a1 = (t1 - t) / (t1 - t0) * p0 + (t - t0) / (t1 - t0) * p1
        a2 = (t2 - t) / (t2 - t1) * p1 + (t - t1) / (t2 - t1) * p2
        a3 = (t3 - t) / (t3 - t2) * p2 + (t - t2) / (t3 - t2) * p3
        b1 = (t2 - t) / (t2 - t0) * a1 + (t - t0) / (t2 - t0) * a2
        b2 = (t3 - t) / (t3 - t1) * a2 + (t - t1) / (t3 - t1) * a3
        xs.append((t2 - t) / (t2 - t1) * b1 + (t - t1) / (t2 - t1) * b2)
        us.append(i + tt)
    xy = np.concatenate(xs + [xs[0][:1]])
    u = np.concatenate(us + [[float(n)]])
    return xy, u


class Track:
    def __init__(self, path):
        self.name = path.stem
        self.league, self.pts = parse_track(path)
        n = len(self.pts)
        fine, u = catmull_rom(self.pts)
        seglen = np.hypot(*np.diff(fine, axis=0).T)
        cum = np.concatenate([[0], np.cumsum(seglen)])
        self.length = L = cum[-1]
        nd = int(round(L))                       # dense points ~1 px apart
        s = np.arange(nd) * (L / nd)
        self.ds = L / nd
        self.dx = np.interp(s, cum, fine[:, 0])
        self.dy = np.interp(s, cum, fine[:, 1])
        du = np.interp(s, cum, u)
        self.seg = np.minimum(du.astype(int), n - 1)
        t = du - self.seg
        sm = t * t * (3 - 2 * t)
        h0 = np.array([p[2] for p in self.pts])
        self.dhalf = h0[self.seg] + (h0[(self.seg + 1) % n] - h0[self.seg]) * sm
        self.seg_start = np.interp(np.arange(n + 1), u, cum)   # arc of each control point
        self.flags = []
        for p in self.pts:
            f = 0 if "open" in p[3] else 1 << FLAG_BITS["rail"]
            for name in p[3]:
                if name != "rail":
                    f |= 1 << FLAG_BITS[name]
            self.flags.append(f)
        self.dflags = np.array(self.flags)[self.seg]
        # 256 equally spaced samples, sample 0 at control point 0.
        k = (np.arange(NSAMP) * nd) // NSAMP
        self.sidx = k
        nxt, prv = (k + 2) % nd, (k - 2) % nd
        ang = np.arctan2(self.dy[nxt] - self.dy[prv], self.dx[nxt] - self.dx[prv])
        self.turn = np.round(ang / (2 * np.pi) * 65536).astype(np.int64) % 65536

    def arc_dist(self, a, b):
        """Signed wrapped arc distance a - b."""
        L = self.length
        return (a - b + L / 2) % L - L / 2


def nearest_dense(trk, tiles_yx):
    """For tile coords (N,2) return the nearest dense index and distance from tile centres."""
    cy = tiles_yx[:, 0] * T + 4.0
    cx = tiles_yx[:, 1] * T + 4.0
    best = np.zeros(len(cx), int)
    bestd = np.full(len(cx), np.inf)
    for j0 in range(0, len(trk.dx), 512):
        ddx = cx[:, None] - trk.dx[None, j0:j0 + 512]
        ddy = cy[:, None] - trk.dy[None, j0:j0 + 512]
        d2 = ddx * ddx + ddy * ddy
        j = d2.argmin(1)
        dj = d2[np.arange(len(cx)), j]
        better = dj < bestd
        best[better], bestd[better] = j[better] + j0, dj[better]
    return best, np.sqrt(bestd)


def axis_of(turn):
    """0 when travel is mostly along x, 1 when mostly along y."""
    q = ((turn + 8192) // 16384) % 4
    return int(q % 2)


def build_track(trk, ts, lg, rng):
    nd = len(trk.dx)
    # 1. Surface mask by stamping discs, then majority-rule tiles.
    mask = np.zeros((WORLD, WORLD), bool)
    discs = {}
    for j in range(nd):
        r = int(round(trk.dhalf[j]))
        if r not in discs:
            yy, xx = np.mgrid[-r:r + 1, -r:r + 1]
            discs[r] = xx * xx + yy * yy <= r * r
        x, y = int(round(trk.dx[j])), int(round(trk.dy[j]))
        mask[y - r:y + r + 1, x - r:x + r + 1] |= discs[r]
    surf = mask.reshape(MAPN, T, MAPN, T).sum((1, 3)) >= 32
    # 2. Nearest centerline point for every tile near the track.
    near = surf.copy()
    for _ in range(2):
        g = near.copy()
        g[1:] |= near[:-1]; g[:-1] |= near[1:]; g[:, 1:] |= near[:, :-1]; g[:, :-1] |= near[:, 1:]
        g[1:, 1:] |= near[:-1, :-1]; g[:-1, :-1] |= near[1:, 1:]; g[1:, :-1] |= near[:-1, 1:]; g[:-1, 1:] |= near[1:, :-1]
        near = g
    nyx = np.argwhere(near)
    nj, _ = nearest_dense(trk, nyx)
    jmap = np.full((MAPN, MAPN), -1, int)
    jmap[nyx[:, 0], nyx[:, 1]] = nj
    arc = lambda ty, tx: jmap[ty, tx] * trk.ds
    turn_at = lambda j: math.atan2(trk.dy[(j + 2) % nd] - trk.dy[j - 2], trk.dx[(j + 2) % nd] - trk.dx[j - 2])
    tturn = lambda j: int(round(turn_at(j) / (2 * math.pi) * 65536)) % 65536
    dir4 = lambda j: ((tturn(j) + 8192) // 16384) % 4

    tmap = np.zeros((MAPN, MAPN), np.uint8)
    # 3. Plain surface with a faint 16 px seam rhythm.
    for ty, tx in np.argwhere(surf):
        v, h = tx % 2 == 0, ty % 2 == 0
        tmap[ty, tx] = SURF_SEAM_X if v and h else SURF_SEAM_V if v else SURF_SEAM_H if h else SURF
    plain = lambda ty, tx: tmap[ty, tx] in (SURF, SURF_SEAM_V, SURF_SEAM_H, SURF_SEAM_X)
    # Lane-centre dots every 32 px of arc.
    for j in range(0, nd, int(32 / trk.ds)):
        ty, tx = int(trk.dy[j]) // T, int(trk.dx[j]) // T
        if surf[ty, tx]:
            tmap[ty, tx] = SURF_DOT
    surf_list = [tuple(p) for p in np.argwhere(surf)]

    def band(j, lo, hi, tiles):
        """Tiles cut by a straight band across the track at dense point j."""
        a = round(turn_at(j) / (math.pi / 4)) * (math.pi / 4)
        ux, uy = math.cos(a), math.sin(a)
        res = []
        for ty, tx in tiles:
            rx, ry = tx * T + 4 - trk.dx[j], ty * T + 4 - trk.dy[j]
            along, across = rx * ux + ry * uy, -rx * uy + ry * ux
            if lo < along <= hi and abs(across) <= trk.dhalf[j] + 10 \
                    and abs(trk.arc_dist(arc(ty, tx), j * trk.ds)) < 64:
                res.append((ty, tx))
        return res
    # 4. Segment features.
    bands = []   # band centre arcs, kept clear of hot spots
    for i, p in enumerate(trk.pts):
        feats = p[3]
        a, b = trk.seg_start[i], trk.seg_start[i + 1]
        mid = (a + b) / 2
        if "cold" in feats:
            for ty, tx in surf_list:
                if trk.seg[jmap[ty, tx]] == i:
                    tmap[ty, tx] = COLD + axis_of(tturn(jmap[ty, tx]))
        for name, base in (("pad", PAD), ("throttled", THROT), ("hop", HOP)):
            if name in feats:
                bands.append(mid)
                jm = int(round(mid / trk.ds)) % nd
                for ty, tx in band(jm, -12, 12, surf_list):
                    tmap[ty, tx] = base + (dir4(jm) if base != THROT else 0)
        if p[4]:
            cand = [(ty, tx) for ty, tx in surf_list
                    if trk.seg[jmap[ty, tx]] == i and plain(ty, tx)
                    and math.hypot(tx * T + 4 - trk.dx[jmap[ty, tx]], ty * T + 4 - trk.dy[jmap[ty, tx]]) < trk.dhalf[jmap[ty, tx]] - 14
                    and all(abs(trk.arc_dist(arc(ty, tx), m)) > 32 for m in bands)
                    and abs(trk.arc_dist(arc(ty, tx), (a + b) / 2)) < (b - a) * 0.4]
            placed = []
            while len(placed) < p[4] and cand:
                c = cand.pop(rng.randrange(len(cand)))
                if all(abs(c[0] - q[0]) + abs(c[1] - q[1]) >= 4 for q in placed):
                    placed.append(c)
                    tmap[c] = HOT
            if len(placed) < p[4]:
                raise SystemExit(f"{trk.name}: segment {i} has room for only {len(placed)} hot spots")
    # 5. Edges and rails from the 4-neighbour surface mask.
    pad = np.pad(surf, 1)
    m4 = (pad[:-2, 1:-1] * N_ | pad[1:-1, 2:] * E_ | pad[2:, 1:-1] * S_ | pad[1:-1, :-2] * W_).astype(int)
    diag = [pad[:-2, 2:], pad[2:, 2:], pad[2:, :-2], pad[:-2, :-2]]     # NE SE SW NW
    edge = np.zeros_like(surf)
    for ty, tx in np.argwhere(~surf & near):
        j = jmap[ty, tx]
        is_open = trk.dflags[j] & (1 << FLAG_BITS["open"])
        if m4[ty, tx]:
            tmap[ty, tx] = (EDGE_OPEN if is_open else RAIL) + m4[ty, tx]
            edge[ty, tx] = True
        else:
            for c in range(4):
                if diag[c][ty, tx]:
                    tmap[ty, tx] = (EDGE_DIAG if is_open else RAIL_DIAG) + c
                    edge[ty, tx] = True
                    break
    open_edges = [tuple(q) for q in np.argwhere(edge & (ts.attr[tmap] == A_SURF))]
    # 6. Start line and sector seams (last, so they always win; they also
    #    cross open-edge tiles so the drivable strip is cut completely).
    for k, lo, hi, base in ((0, -8, 8, START), (85, -4, 4, SEC1), (170, -4, 4, SEC2)):
        j = trk.sidx[k]
        for ty, tx in band(j, lo, hi, surf_list + open_edges):
            tmap[ty, tx] = base if base == START else base + axis_of(tturn(j))
    # 7. League background on everything else.
    lg["background"](tmap, ~surf & ~edge, rng)
    return tmap, surf


def center_bytes(trk):
    out = bytearray()
    for k, j in enumerate(trk.sidx):
        x, y = int(round(trk.dx[j])), int(round(trk.dy[j]))
        h = int(round(trk.dhalf[j]))
        out += np.array([x, y, trk.turn[k]], "<u2").tobytes() + bytes([h, int(trk.dflags[j])])
    return bytes(out)


def validate(trk, tmap, ts, errs):
    attr = ts.attr
    a = attr[tmap]
    for j in range(len(trk.dx)):
        v = a[int(trk.dy[j]) // T, int(trk.dx[j]) // T]
        if v not in DRIVABLE:
            errs.append(f"{trk.name}: centerline point {j} at ({trk.dx[j]:.0f},{trk.dy[j]:.0f}) on attribute {v}")
            break
    for name in set(ts.names[i] for i in np.unique(tmap)):
        if name is None:
            errs.append(f"{trk.name}: map uses an undefined tile")
    lo, hi = MARGIN, WORLD - MARGIN
    if not (trk.dx.min() >= lo and trk.dx.max() <= hi and trk.dy.min() >= lo and trk.dy.max() <= hi):
        errs.append(f"{trk.name}: centerline leaves the {MARGIN} px margin")
    if (a[0] | a[-1]).any() or (a[:, 0] | a[:, -1]).any():
        errs.append(f"{trk.name}: track touches the map border")
    # Clearance: parts of the line far apart in arc must be far apart in space.
    step = 4
    P = np.stack([trk.dx[::step], trk.dy[::step]], 1)
    H = trk.dhalf[::step]
    d = np.hypot(*(P[:, None] - P[None]).transpose(2, 0, 1))
    ia = np.arange(len(P)) * step * trk.ds
    darc = np.abs(trk.arc_dist(ia[:, None], ia[None]))
    need = H[:, None] + H[None] + 3 * T
    far = darc > need * 2
    gap = np.where(far, d - need, 1e9)
    i0, i1 = np.unravel_index(gap.argmin(), gap.shape)
    clear = gap[i0, i1]
    if clear < 0:
        errs.append(f"{trk.name}: track parts too close (clearance {clear:.0f} px) between "
                    f"({P[i0, 0]:.0f},{P[i0, 1]:.0f}) and ({P[i1, 0]:.0f},{P[i1, 1]:.0f})")
    # Start + sector bands must cut the drivable loop into three pieces.
    driv = np.isin(a, list(DRIVABLE - {A_START, A_SEC1, A_SEC2}))
    lab = label4(driv)
    probes = [trk.sidx[k] for k in (42, 128, 213)]
    ids = [lab[int(trk.dy[j]) // T, int(trk.dx[j]) // T] for j in probes]
    if len(set(ids)) != 3 or 0 in ids:
        errs.append(f"{trk.name}: start/sector bands do not cut the track into 3 regions {ids}")
    return clear


def label4(m):
    """Connected-component labels (4-connectivity), 0 = background."""
    lab = np.zeros(m.shape, int)
    n = 0
    for sy, sx in np.argwhere(m):
        if lab[sy, sx]:
            continue
        n += 1
        stack = [(sy, sx)]
        lab[sy, sx] = n
        while stack:
            y, x = stack.pop()
            for yy, xx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                if 0 <= yy < m.shape[0] and 0 <= xx < m.shape[1] and m[yy, xx] and not lab[yy, xx]:
                    lab[yy, xx] = n
                    stack.append((yy, xx))
    return lab


def render_map(tmap, ts):
    idx = ts.tiles[tmap].transpose(0, 2, 1, 3).reshape(WORLD, WORLD)
    return ts.pal.rgb_array()[idx]


def write_preview(trk, tmap, ts, path):
    img = Image.fromarray(render_map(tmap, ts))
    dr = ImageDraw.Draw(img)
    pts = list(zip(trk.dx[::2], trk.dy[::2]))
    dr.line(pts + [pts[0]], fill=(255, 64, 200), width=1)
    x0, y0 = trk.dx[0], trk.dy[0]
    dr.ellipse([x0 - 5, y0 - 5, x0 + 5, y0 + 5], outline=(255, 255, 0), width=2)
    a = trk.turn[0] / 65536 * 2 * math.pi       # driving direction arrow at sample 0
    dr.line([(x0, y0), (x0 + 24 * math.cos(a), y0 + 24 * math.sin(a))], fill=(255, 255, 0), width=2)
    for k in (85, 170):
        j = trk.sidx[k]
        dr.ellipse([trk.dx[j] - 3, trk.dy[j] - 3, trk.dx[j] + 3, trk.dy[j] + 3], outline=(255, 255, 0))
    img.save(path, optimize=False)


def write_league(name, lg, out, docs):
    ts = lg["tiles"](lg["pal"])
    rng = random.Random(zlib.crc32(name.encode()))
    f, b, fpal, bpal = lg["horizon"](lg["pal"].rgb[0], rng)
    files = {
        out / f"{name}_tiles.bin": ts.tiles.tobytes(),
        out / f"{name}_pal.bin": lg["pal"].table565().tobytes(),
        out / f"{name}_horizon.bin": pack4(f) + pack4(b)
        + np.array([rgb565(c) for c in fpal], "<u2").tobytes() + np.array([rgb565(c) for c in bpal], "<u2").tobytes(),
    }
    for p, data in files.items():
        p.write_bytes(data)
    # Docs: contact sheet (4x, 1 px gaps), index list, horizon preview.
    rgb = lg["pal"].rgb_array()
    sheet = np.full((16 * 33 + 1, 16 * 33 + 1, 3), 255, np.uint8)
    for i in range(256):
        y, x = divmod(i, 16)
        sheet[1 + y * 33:1 + y * 33 + 32, 1 + x * 33:1 + x * 33 + 32] = rgb[ts.tiles[i]].repeat(4, 0).repeat(4, 1)
    Image.fromarray(sheet).save(docs / f"{name}_tiles.png")
    lines = [f"# {name} tileset: index, name, attribute (generated by tools/build_tracks.py)"]
    lines += [f"{i:3d}  {n:34s} {ts.attr[i]} {ATTR_NAMES[ts.attr[i]]}" for i, n in enumerate(ts.names) if n]
    lines += ["# unnamed indices hold a copy of tile 1 (rack panel), attribute 0"]
    (docs / f"{name}_tiles.txt").write_text("\n".join(lines) + "\n")
    hz = np.zeros((64, 512, 3), np.uint8)
    back = np.array(bpal, np.uint8)[np.tile(b, 2)]
    front = np.array(fpal, np.uint8)[f]
    hz[:32] = np.where(f[..., None] > 0, front, back)
    hz[32:] = back
    Image.fromarray(hz.repeat(2, 0).repeat(2, 1)).save(docs / f"{name}_horizon.png")
    return ts, files, (f, b, fpal, bpal)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--track", help="build only this track (file stem)")
    ap.add_argument("--out", default=str(CART / "assets" / "gen"))
    args = ap.parse_args()
    out, docs = Path(args.out), CART / "docs"
    out.mkdir(parents=True, exist_ok=True)
    docs.mkdir(exist_ok=True)
    paths = sorted((CART / "cart" / "src" / "tracks").glob("*.track"))
    if args.track:
        paths = [p for p in paths if p.stem == args.track]
        if not paths:
            raise SystemExit(f"no track named {args.track}")
    errs, sizes, leagues = [], {}, {}
    tracks = [Track(p) for p in paths]
    for trk in tracks:
        if trk.league not in leagues:
            ts, files, (f, b, fpal, bpal) = write_league(trk.league, LEAGUES[trk.league], out, docs)
            leagues[trk.league] = ts
            sizes.update({p: len(d) for p, d in files.items()})
            fog = ts.pal.rgb[0]
            if not ((f[-1] == 1).all() and fpal[1] == fog and (f == 15).any()):
                errs.append(f"{trk.league}: front horizon must end in a fog row (entry 1) and use LED entry 15")
            if f.max() > 15 or b.max() > 15:
                errs.append(f"{trk.league}: horizon pixel out of 4-bit range")
            if (ts.tiles == 0).any():
                errs.append(f"{trk.league}: a tile uses palette index 0")
            print(f"league {trk.league}: {len(ts.pal.rgb)} palette entries, "
                  f"{sum(n is not None for n in ts.names)} named tiles")
        ts = leagues[trk.league]
        rng = random.Random(zlib.crc32(trk.name.encode()))
        tmap, surf = build_track(trk, ts, LEAGUES[trk.league], rng)
        files = {out / f"{trk.name}_map.bin": tmap.tobytes(),
                 out / f"{trk.name}_attr.bin": ts.attr.tobytes(),
                 out / f"{trk.name}_center.bin": center_bytes(trk)}
        for p, d in files.items():
            p.write_bytes(d)
            sizes[p] = len(d)
        write_preview(trk, tmap, ts, docs / f"{trk.name}_preview.png")
        clear = validate(trk, tmap, ts, errs)
        counts = np.bincount(ts.attr[tmap].ravel(), minlength=11)
        print(f"track {trk.name}: lap {trk.length:.0f} px, {len(trk.pts)} control points, "
              f"min clearance {clear:.0f} px")
        print("  segment lengths: " + " ".join(f"{b - a:.0f}" for a, b in zip(trk.seg_start, trk.seg_start[1:])))
        print("  tiles per attribute: " + ", ".join(f"{ATTR_NAMES[i]} {c}" for i, c in enumerate(counts) if c))
        print(f"  start ({trk.dx[0]:.0f},{trk.dy[0]:.0f}) heading {trk.turn[0]}; sector1 sample 85 at "
              f"({trk.dx[trk.sidx[85]]:.0f},{trk.dy[trk.sidx[85]]:.0f}); sector2 sample 170 at "
              f"({trk.dx[trk.sidx[170]]:.0f},{trk.dy[trk.sidx[170]]:.0f})")
        if not 4000 <= trk.length <= 5000:
            print(f"  note: lap length {trk.length:.0f} outside 4000..5000")
    expect = {"tiles": 16384, "pal": 512, "horizon": 12352, "map": 16384, "attr": 256, "center": 2048}
    for p, n in sorted(sizes.items()):
        kind = p.stem.rsplit("_", 1)[1]
        if expect[kind] != n:
            errs.append(f"{p.name}: {n} bytes, expected {expect[kind]}")
        print(f"  {p.relative_to(CART) if p.is_relative_to(CART) else p}: {n} bytes")
    for e in errs:
        print("ERROR:", e, file=sys.stderr)
    sys.exit(1 if errs else 0)


if __name__ == "__main__":
    main()
