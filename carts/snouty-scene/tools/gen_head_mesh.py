#!/usr/bin/env python3
"""Generates the low-poly Snouty head mesh of cart/src/parts/head.zig.

Rewrites the table between the `// mesh-begin` and `// mesh-end` markers
of head.zig (vertices as [3]f32, faces as { a, b, c, material }, wound
counter-clockwise seen from outside). Rerun and commit when the shape
changes:

    python3 carts/snouty-scene/tools/gen_head_mesh.py [--sheet out.png]

--sheet also writes a contact sheet of 12 poses rendered the way the cart
does (painter's algorithm, flat shading), for judging the shape quickly.

The model: snout along +x, y up, z toward the head's left. A 6-segment
ellipsoid skull (back pole plus three rings), a snout of three rings
curving down to a pink nose cap, two pyramid ears with dark insides, two
eyes as raised diamonds (grey glasses rim, white lens, dark pupil), and a
red tongue (a thin tetrahedron whose tip, the last vertex, the cart moves
to flick it out). Recentred and scaled to radius 1.4.
"""
import math
import pathlib
import re
import sys

HEAD, SNOUT, EAR_IN, WHITE, PUPIL, NOSE, RIM, TONGUE = range(8)
MAT_RGB = [0x8E42DE, 0xA864EC, 0x3A1850, 0xF4EFDF, 0x17121E, 0xE070C8, 0x5A5068, 0xEE453C]
MAT_BIAS = [0, 0, 0, 0.35, 0.45, 0, 0.30, 0]
RADIUS = 1.4

V = []
F = []


def sub(a, b): return [a[i] - b[i] for i in range(3)]
def add(a, b): return [a[i] + b[i] for i in range(3)]
def mul(a, s): return [x * s for x in a]
def dot(a, b): return sum(a[i] * b[i] for i in range(3))
def norm(a): return mul(a, 1 / math.sqrt(dot(a, a)))


def cross(a, b):
    return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]


def vert(p):
    V.append(list(p))
    return len(V) - 1


def tri(a, b, c, mat, inside):
    """Adds a face, wound so its normal points away from `inside`."""
    n = cross(sub(V[b], V[a]), sub(V[c], V[a]))
    cen = mul(add(add(V[a], V[b]), V[c]), 1 / 3)
    if dot(n, sub(cen, inside)) < 0:
        b, c = c, b
    F.append((a, b, c, mat))


def quad(a, b, c, d, mat, inside):
    tri(a, b, c, mat, inside)
    tri(a, c, d, mat, inside)


RX, RY, RZ = 0.74, 0.70, 0.66
SEG = 6


def ell(th, ph):
    """Skull surface: th from the back pole (0) to the front (pi), ph around x from +z."""
    return [-math.cos(th) * RX, math.sin(th) * math.sin(ph) * RY, math.sin(th) * math.cos(ph) * RZ]


def surf_frame(th, ph):
    p = ell(th, ph)
    return p, norm([p[0] / RX**2, p[1] / RY**2, p[2] / RZ**2])


def ring(cx, cy, ry, rz):
    return [vert([cx, cy + math.sin(math.radians(60 * k)) * ry, math.cos(math.radians(60 * k)) * rz])
            for k in range(SEG)]


def build():
    origin = [0, 0, 0]
    back = vert([-RX, 0, 0])
    rings = [[vert(ell(math.radians(th), math.radians(60 * k))) for k in range(SEG)] for th in (45, 90, 135)]
    for k in range(SEG):
        tri(back, rings[0][k], rings[0][(k + 1) % SEG], HEAD, origin)
    for r in range(2):
        for k in range(SEG):
            k2 = (k + 1) % SEG
            quad(rings[r][k], rings[r][k2], rings[r + 1][k2], rings[r + 1][k], HEAD, origin)

    # Snout: three rings curving down, then the nose cap.
    centres = [[0.40, 0.0, 0], [0.76, -0.12, 0], [1.28, -0.25, 0], [1.70, -0.38, 0]]
    snout = [rings[2], ring(0.76, -0.12, 0.36, 0.33), ring(1.28, -0.25, 0.28, 0.26), ring(1.70, -0.38, 0.22, 0.21)]
    for r, mat in enumerate((HEAD, SNOUT, SNOUT)):
        inside = mul(add(centres[r], centres[r + 1]), 0.5)
        for k in range(SEG):
            k2 = (k + 1) % SEG
            quad(snout[r][k], snout[r][k2], snout[r + 1][k2], snout[r + 1][k], mat, inside)
    tip = vert([1.86, -0.36, 0])
    for k in range(SEG):
        tri(tip, snout[3][k], snout[3][(k + 1) % SEG], NOSE, centres[3])

    # Ears: pyramids leaning back, dark inside facing forward.
    for side in (1, -1):
        p, n = surf_frame(math.radians(58), math.radians(90 - 40 * side))
        fwd = norm(sub([1, 0, 0], mul(n, n[0])))
        lat = cross(n, fwd)
        p = sub(p, mul(n, 0.06))
        b1 = vert(add(add(p, mul(lat, 0.26)), mul(fwd, 0.08)))
        b2 = vert(add(add(p, mul(lat, -0.26)), mul(fwd, 0.08)))
        b3 = vert(add(p, mul(fwd, -0.22)))
        apex = vert(add(add(p, mul(n, 0.38)), mul(fwd, -0.08)))
        inside = add(p, mul(fwd, -0.05))
        tri(b1, b2, apex, EAR_IN, inside)
        tri(b2, b3, apex, HEAD, inside)
        tri(b3, b1, apex, HEAD, inside)

    # Eyes: diamonds raised off the skull, rim under lens under pupil.
    for side in (1, -1):
        p, n = surf_frame(math.radians(118), math.radians(90 - 62 * side))
        fwd = norm(sub([1, 0, 0], mul(n, n[0])))
        up = norm(cross(fwd, n) if side > 0 else cross(n, fwd))

        def diamond(centre, half, lift, mat):
            c = add(centre, mul(n, lift))
            pts = [vert(add(c, mul(fwd, half))), vert(add(c, mul(up, half))),
                   vert(add(c, mul(fwd, -half))), vert(add(c, mul(up, -half)))]
            quad(*pts, mat, sub(c, n))

        diamond(p, 0.26, 0.03, RIM)
        diamond(p, 0.205, 0.06, WHITE)
        diamond(add(p, mul(fwd, 0.045)), 0.09, 0.09, PUPIL)

    # Tongue last: three root vertices under the nose, then the tip at full
    # extension (the cart pulls it back to the roots' centre).
    root = [1.74, -0.47, 0]
    d = norm([1.0, -0.30, 0])
    side = [0, 0, 1]
    upv = cross(d, side)
    r1 = vert(add(root, mul(side, 0.11)))
    r2 = vert(add(root, mul(side, -0.11)))
    r3 = vert(add(root, mul(upv, 0.10)))
    tipv = vert(add(root, mul(d, 0.80)))
    inside = add(root, mul(d, 0.2))
    inside = add(inside, mul(upv, 0.02))
    tri(r1, r2, tipv, TONGUE, inside)
    tri(r2, r3, tipv, TONGUE, inside)
    tri(r3, r1, tipv, TONGUE, inside)

    body = V[:-4]  # the extended tongue does not count toward the size
    xs = [q[0] for q in body]
    ys = [q[1] for q in body]
    c = [(max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2, 0]
    moved = [sub(q, c) for q in V]
    r = max(math.sqrt(dot(q, q)) for q in moved[:-4])
    V[:] = [mul(q, RADIUS / r) for q in moved]


def emit():
    out = ["// mesh-begin",
           "// %d vertices, %d faces; the last vertex is the tongue tip, the last" % (len(V), len(F)),
           "// three faces the tongue." ,
           "pub const vertices = [_][3]f32{"]
    for q in V:
        out.append("    .{ %s, %s, %s }," % tuple("%.4f" % x for x in q))
    out += ["};", "", "/// a, b, c (counter-clockwise seen from outside), material.",
            "pub const faces = [_][4]u8{"]
    for a, b, c, m in F:
        out.append("    .{ %d, %d, %d, %d }," % (a, b, c, m))
    out += ["};", "pub const tongue_faces = 3;", "// mesh-end"]
    return "\n".join(out)


def sheet(path):
    from PIL import Image, ImageDraw
    poses = [(0, 0), (0.6, 0.2), (1.57, 0.1), (2.4, 0.3), (3.14, 0), (-0.8, -0.3),
             (0.3, 1.0), (1.2, -0.9), (-1.57, 0.2), (2.0, 0.6), (0.9, 0.5), (-0.4, 0.4)]
    img = Image.new("RGB", (640, 384))
    light = norm([-0.48, 0.58, 0.66])
    for i, (yaw, pitch) in enumerate(poses):
        im = Image.new("RGB", (160, 128), (6, 4, 14))
        dr = ImageDraw.Draw(im)
        cy, sy, cp, sp = math.cos(yaw), math.sin(yaw), math.cos(pitch), math.sin(pitch)

        def rot(q):
            x, y, z = q
            x, z = cy * x + sy * z, -sy * x + cy * z
            y, z = cp * y - sp * z, sp * y + cp * z
            return [x, y, z]
        world = [rot(q) for q in V]
        scr = [(80 + 110 * q[0] / (3.2 - q[2]), 64 - 110 * q[1] / (3.2 - q[2]), 3.2 - q[2]) for q in world]
        faces = []
        for a, b, c, m in F:
            A, B, C = scr[a], scr[b], scr[c]
            if (B[0] - A[0]) * (C[1] - A[1]) - (B[1] - A[1]) * (C[0] - A[0]) >= 0:
                continue
            n = norm(cross(sub(world[b], world[a]), sub(world[c], world[a])))
            lv = min(15, int(max(0, dot(n, light)) * 16))
            f = (90 + (166 * lv) // 15) / 256
            rgb = tuple(int(((MAT_RGB[m] >> s) & 255) * f) for s in (16, 8, 0))
            faces.append((A[2] + B[2] + C[2] - 3 * MAT_BIAS[m], [A[:2], B[:2], C[:2]], rgb))
        for _, pts, rgb in sorted(faces, key=lambda e: -e[0]):
            dr.polygon(pts, fill=rgb)
        img.paste(im, ((i % 4) * 160, (i // 4) * 128))
    img.resize((1280, 768), Image.NEAREST).save(path)


def main():
    build()
    target = pathlib.Path(__file__).resolve().parent.parent / "cart/src/parts/head.zig"
    src = target.read_text()
    new = re.sub(r"// mesh-begin.*// mesh-end", lambda _: emit(), src, flags=re.S)
    target.write_text(new)
    print("gen_head_mesh: %d vertices, %d faces -> %s" % (len(V), len(F), target), file=sys.stderr)
    if "--sheet" in sys.argv:
        sheet(sys.argv[sys.argv.index("--sheet") + 1])


if __name__ == "__main__":
    main()
