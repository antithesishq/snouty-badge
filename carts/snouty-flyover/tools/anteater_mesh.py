#!/usr/bin/env python3
"""Low-poly anteater mesh for the flyover's avatar (cart/src/anteater_mesh.zig).

The flyer is seen from the voxel camera's own view: above and behind, tilted
down, so the mesh is a real 3D model that the cart's model.zig rotates, tilts,
lights and rasterises every frame (flat-shaded triangles). This script builds
the mesh procedurally (lathed body of revolution, a drooping snout, a bushy
tail, forelegs on flap bones), writes it as Zig literals, and renders a
preview with the same projection as model.zig so the look can be judged on a
real frame.

    python3 tools/anteater_mesh.py --zig cart/src/anteater_mesh.zig
    python3 tools/anteater_mesh.py --preview bg.png out.png [--flap 0.6] [--roll -0.2]

Model space: x right, y up, z forward (the nose points +z). One unit is
emitted as 256 (i16). Bones: 0 body, 1 left foreleg, 2 right foreleg (they
rotate about the z axis through their shoulder pivot: the flap), 3 head and
snout (rotates about the y axis through the neck: the sway).
"""
import argparse, math
from PIL import Image, ImageDraw

MATS = {  # material -> 0xRRGGBB, in the order model.zig's table expects
    'fur': 0xC8B89C, 'dark': 0x4A3E46, 'light': 0xF0E8D4, 'claw': 0xFAF6EE,
}
MAT_ID = {m: i for i, m in enumerate(MATS)}
PIVOT = {1: (-0.42, -0.02, 0.42), 2: (0.42, -0.02, 0.42), 3: (0.0, 0.3, 0.8)}

verts, tris = [], []  # (x, y, z, bone), (a, b, c, mat)

def V(x, y, z, bone=0):
    verts.append((x, y, z, bone)); return len(verts) - 1

def T(a, b, c, mat):
    tris.append((a, b, c, MAT_ID[mat]))

def lathe(rings, segs, mat_fn, bone=0, cap_start=None, cap_end=None, phase=0.0):
    """rings: list of (centre(x,y,z), rx, ry, basis(u,v) unit vectors). Returns ring vertex ids.
    Faces wind so the outward normal is right-handed (seen from outside, counter-clockwise)."""
    ids = []
    for (c, rx, ry, (u, v)) in rings:
        ring = []
        for s in range(segs):
            a = 2 * math.pi * (s + phase) / segs
            p = [c[i] + rx * math.cos(a) * u[i] + ry * math.sin(a) * v[i] for i in range(3)]
            ring.append(V(*p, bone))
        ids.append(ring)
    for r in range(len(ids) - 1):
        for s in range(segs):
            a, b = ids[r][s], ids[r][(s + 1) % segs]
            c2, d = ids[r + 1][s], ids[r + 1][(s + 1) % segs]
            m = mat_fn(r, s)
            T(a, c2, b, m); T(b, c2, d, m)
    if cap_start is not None:
        cid = V(*cap_start, bone); ring = ids[0]
        for s in range(segs): T(ring[s], ring[(s + 1) % segs], cid, mat_fn(-1, s))
    if cap_end is not None:
        cid = V(*cap_end, bone); ring = ids[-1]
        for s in range(segs): T(ring[(s + 1) % segs], ring[s], cid, mat_fn(len(ids) - 1, s))
    return ids

X, Y = (1, 0, 0), (0, 1, 0)

def build():
    # Body: tapered trunk along z, slightly wider than tall; the giant anteater's
    # dark shoulder band runs round the sides and belly of rings 1-2.
    prof = [(-0.95, 0.34), (-0.45, 0.52), (0.1, 0.5), (0.55, 0.38), (0.85, 0.27)]
    rings = [((0, 0.02 + 0.1 * (r / 0.5), z), r * 1.05, r * 0.85, (X, Y)) for z, r in prof]
    def body_mat(r, s):
        if r in (2,) and s not in (1,):      # band on ring 2, open at the very top segment
            return 'dark'
        if r == 1 and s in (3, 4):           # band wraps under the chest
            return 'dark'
        return 'fur'
    lathe(rings, 6, body_mat, cap_start=(0, 0.1, -1.05), phase=0.25)
    # Head: short cone from the neck.
    head = [((0, 0.3, 0.85), 0.27, 0.24, (X, Y)), ((0, 0.3, 1.2), 0.2, 0.18, (X, Y))]
    lathe(head, 6, lambda r, s: 'fur', bone=3, phase=0.25)
    # Snout: long, nearly level with a gentle droop, tapering; the tip is pale.
    sn = []
    for k in range(5):
        t = k / 4
        c = (0, 0.3 - 0.32 * t * t, 1.2 + 1.7 * t)
        r = 0.16 - 0.11 * t
        sn.append((c, r, r, (X, Y)))
    lathe(sn, 4, lambda r, s: 'light' if r >= 3 else 'fur', bone=3, cap_end=(0, 0.3 - 0.32 - 0.02, 2.95), phase=0.5)
    # Ears: two small pyramids.
    for sx in (-1, 1):
        base = [((sx * 0.17, 0.5, 1.0), 0.07, 0.07, (X, (0, 0, 1)))]
        lathe(base, 4, lambda r, s: 'dark', bone=3, cap_end=(sx * 0.2, 0.74, 0.98))
    # Tail: bushy, flattened, streaming back and up; jagged tufts on the outer rings.
    tl = []
    for k in range(4):
        t = k / 3
        c = (0, 0.15 + 0.35 * t, -1.0 - 1.0 * t)
        r = 0.2 + 0.3 * math.sin(math.pi * min(1, t * 1.1)) * (1 - 0.3 * t)
        tl.append((c, r * 1.3, r * 0.5, (X, Y)))
    def tail_mat(r, s):
        return 'light' if (r >= 2 and s % 2 == 0) else 'fur'
    lathe(tl, 5, tail_mat, cap_end=(0, 0.52, -2.15), phase=0.5)
    # Forelegs (flap bones): a prism from the shoulder outward, claws at the end.
    for bone, sx in ((1, -1), (2, 1)):
        px, py, pz = PIVOT[bone]
        axis = (sx * 0.96, -0.1, 0.25)
        n = math.sqrt(sum(a * a for a in axis)); axis = tuple(a / n for a in axis)
        u = (0, 0, 1); v = (0, 1, 0)
        segs = []
        for k, (d, r) in enumerate([(0.0, 0.13), (0.45, 0.1), (0.75, 0.08)]):
            c = (px + axis[0] * d, py + axis[1] * d, pz + axis[2] * d)
            segs.append((c, r, r * 0.8, (u, v)))
        tip = (px + axis[0] * 1.0, py + axis[1] * 1.0 - 0.05, pz + axis[2] * 1.0)
        lathe(segs, 4, lambda r, s: 'claw' if r >= 2 else 'fur', bone=bone, cap_end=tip)
    # Hind legs tucked back under the rump.
    for sx in (-1, 1):
        c0 = (sx * 0.3, -0.3, -0.6); c1 = (sx * 0.34, -0.5, -0.95)
        lathe([(c0, 0.11, 0.1, (X, (0, 0, 1))), (c1, 0.08, 0.08, (X, (0, 0, 1)))], 4,
              lambda r, s: 'fur', cap_end=(sx * 0.35, -0.55, -1.05))

def transform(flap, roll, tilt, sway=0.0):
    """Model -> camera space (x right, y up, z forward), as model.zig does it:
    bone rotation at the pivot (forelegs about z, head about y), roll about z,
    then the camera tilt about x."""
    out = []
    cr, sr = math.cos(roll), math.sin(roll)
    ct, st = math.cos(tilt), math.sin(tilt)
    for (x, y, z, bone) in verts:
        if bone == 3:
            px, _, pz = PIVOT[3]
            ca, sa = math.cos(sway), math.sin(sway)
            dx, dz = x - px, z - pz
            x, z = px + dx * ca + dz * sa, pz - dx * sa + dz * ca
        elif bone:
            px, py, _ = PIVOT[bone]
            a = flap if bone == 2 else -flap
            ca, sa = math.cos(a), math.sin(a)
            dx, dy = x - px, y - py
            x, y = px + dx * ca - dy * sa, py + dx * sa + dy * ca
        x, y = x * cr - y * sr, x * sr + y * cr
        y, z = y * ct + z * st, -y * st + z * ct
        out.append((x, y, z))
    return out

def preview(bg_path, out_path, flap=0.5, roll=0.0, tilt_deg=24.0, sway=0.0, dist=5.2, scale=100.0, cx=80, cy=100, up=4):
    cam = transform(flap, roll, math.radians(tilt_deg), sway)
    L = (-0.35, 0.8, 0.5); n = math.sqrt(sum(a * a for a in L)); L = tuple(a / n for a in L)
    faces = []
    for (a, b, c, m) in tris:
        pa, pb, pc = cam[a], cam[b], cam[c]
        n = ((pb[1]-pa[1])*(pc[2]-pa[2]) - (pb[2]-pa[2])*(pc[1]-pa[1]),
             (pb[2]-pa[2])*(pc[0]-pa[0]) - (pb[0]-pa[0])*(pc[2]-pa[2]),
             (pb[0]-pa[0])*(pc[1]-pa[1]) - (pb[1]-pa[1])*(pc[0]-pa[0]))
        nl = math.sqrt(sum(q * q for q in n)) or 1
        # view vector from the triangle to the camera (origin), culling by facing
        ctr = [(pa[i] + pb[i] + pc[i]) / 3 for i in range(3)]
        view = (-ctr[0], -ctr[1], -(ctr[2] + dist))
        if n[0]*view[0] + n[1]*view[1] + n[2]*view[2] <= 0:
            continue
        shade = 0.45 + 0.55 * max(0.0, (n[0]*L[0] + n[1]*L[1] + n[2]*L[2]) / nl)
        depth = ctr[2]
        pts = []
        for p in (pa, pb, pc):
            zz = p[2] + dist
            pts.append(((cx + p[0] * scale / zz) * up, (cy - p[1] * scale / zz) * up))
        rgb = list(MATS.values())[m]
        col = tuple(min(255, int(((rgb >> sh) & 0xFF) * shade)) for sh in (16, 8, 0))
        faces.append((depth, pts, col))
    faces.sort(key=lambda f: -f[0])
    bg = Image.open(bg_path).convert('RGB').resize((160 * up, 128 * up), Image.NEAREST)
    d = ImageDraw.Draw(bg)
    for _, pts, col in faces:
        d.polygon(pts, fill=col)
    bg.save(out_path)
    return len(faces)

def write_zig(path):
    with open(path, 'w') as f:
        f.write('//! Low-poly anteater mesh, generated by tools/anteater_mesh.py; do not edit.\n')
        f.write('//! Units of 1/256; x right, y up, z forward. Bones: 0 body, 1 left foreleg,\n//! 2 right foreleg (flap about z), 3 head (sway about y); pivots below.\n//! Materials: 0 fur, 1 dark, 2 light, 3 claw.\n')
        f.write('pub const Vert = struct { x: i16, y: i16, z: i16, bone: u8 };\n')
        f.write('pub const Tri = struct { a: u8, b: u8, c: u8, mat: u8 };\n')
        f.write('pub const pivots = [4][3]i16{ .{ 0, 0, 0 }, .{ %d, %d, %d }, .{ %d, %d, %d }, .{ %d, %d, %d } };\n' % tuple(
            round(v * 256) for b in (1, 2, 3) for v in PIVOT[b]))
        f.write('pub const material_rgb = [4]u32{ %s };\n' % ', '.join('0x%06X' % c for c in MATS.values()))
        f.write('pub const verts = [%d]Vert{\n' % len(verts))
        for (x, y, z, bone) in verts:
            f.write('    .{ .x = %d, .y = %d, .z = %d, .bone = %d },\n' % (round(x * 256), round(y * 256), round(z * 256), bone))
        f.write('};\n')
        f.write('pub const tris = [%d]Tri{\n' % len(tris))
        for (a, b, c, m) in tris:
            f.write('    .{ .a = %d, .b = %d, .c = %d, .mat = %d },\n' % (a, b, c, m))
        f.write('};\n')

if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--zig'); ap.add_argument('--preview', nargs=2)
    ap.add_argument('--flap', type=float, default=0.5); ap.add_argument('--roll', type=float, default=0.0)
    ap.add_argument('--tilt', type=float, default=24.0); ap.add_argument('--sway', type=float, default=0.0)
    args = ap.parse_args()
    build()
    assert len(verts) < 256, len(verts)
    print('verts', len(verts), 'tris', len(tris))
    if args.zig: write_zig(args.zig)
    if args.preview:
        n = preview(args.preview[0], args.preview[1], flap=args.flap, roll=args.roll, tilt_deg=args.tilt, sway=args.sway)
        print('drawn', n)
