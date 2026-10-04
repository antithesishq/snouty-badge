"""The six racer cars (SPEC 4.2, PLAN Track B item 2): one 32x16 sheet each.

Each car is a small 3D model (ellipsoids and convex slabs) ray-cast
orthographically at one sample per pixel with Snouty Zero's camera (26
degrees look-down), Lambert shading quantised onto fixed ramps and a 1 px
outline at the silhouette and at depth steps: a pure-Python port of
carts/snouty-zero/tools/prepare_assets.py's caster.

Cells (bottom-aligned, drawing on the bottom row, centred):
  0 rear            (the car driving away from the camera)
  1 rear quarter    (nose turned 45 degrees to screen right)
  2 side            (nose to screen right; mirror cells 1-2 for the left)
  3 wreck           (burnt hulk, rolled on its side, charred palette)
  4 airborne        (rear view, nose up, wheels hanging on extended suspension)
"""
from __future__ import annotations

import math

from .raster import KEY, Canvas, hx

CW, CH = 32, 16
CAM_PITCH = 26.0
LIGHT = (-0.45, -0.55, 0.75)
_l = math.sqrt(sum(v * v for v in LIGHT))
LIGHT = tuple(v / _l for v in LIGHT)


# --------------------------------------------------------------- vector bits
def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def norm(a):
    n = math.sqrt(dot(a, a)) or 1e-9
    return (a[0] / n, a[1] / n, a[2] / n)


def matmul(A, B):
    return [[sum(A[i][k] * B[k][j] for k in range(3)) for j in range(3)] for i in range(3)]


def rot(yaw=0.0, roll=0.0, pitch=0.0):
    """pitch about x (nose up +), roll about y (right side down +), yaw about z (nose to screen-left +).
    Local axes: x right, y forward, z up."""
    a, b, c = (math.radians(v) for v in (yaw, roll, pitch))
    rz = [[math.cos(a), -math.sin(a), 0], [math.sin(a), math.cos(a), 0], [0, 0, 1]]
    ry = [[math.cos(b), 0, math.sin(b)], [0, 1, 0], [-math.sin(b), 0, math.cos(b)]]
    rx = [[1, 0, 0], [0, math.cos(c), -math.sin(c)], [0, math.sin(c), math.cos(c)]]
    return matmul(matmul(rz, ry), rx)


def apply(R, v):          # R v
    return tuple(R[i][0] * v[0] + R[i][1] * v[1] + R[i][2] * v[2] for i in range(3))


def apply_t(R, v):        # R^T v (world -> local)
    return tuple(R[0][i] * v[0] + R[1][i] * v[1] + R[2][i] * v[2] for i in range(3))


# --------------------------------------------------------------- primitives
class Prim:
    def __init__(self, kind, mat, c=(0, 0, 0), r=(1, 1, 1), planes=None, glass=False, inside=False):
        self.kind, self.mat, self.c, self.r = kind, mat, c, r
        self.planes = planes
        self.glass, self.inside = glass, inside
        self.wheel = False

    def hit(self, o, d):
        """(t, normal) or None."""
        if self.kind == "ell":
            r, c = self.r, self.c
            oo = ((o[0] - c[0]) / r[0], (o[1] - c[1]) / r[1], (o[2] - c[2]) / r[2])
            dd = (d[0] / r[0], d[1] / r[1], d[2] / r[2])
            a = dot(dd, dd)
            b = dot(oo, dd)
            cc = dot(oo, oo) - 1
            disc = b * b - a * cc
            if disc < 0:
                return None
            t = (-b - math.sqrt(disc)) / a
            if t < 0:
                return None
            q = (oo[0] + dd[0] * t, oo[1] + dd[1] * t, oo[2] + dd[2] * t)
            return t, norm((q[0] / r[0], q[1] / r[1], q[2] / r[2]))
        t0, t1, nrm = -1e18, 1e18, (0, 0, 1)
        for pn, pd in self.planes:
            dn, on = dot(d, pn), dot(o, pn)
            if abs(dn) < 1e-12:
                if on > pd:
                    return None
                continue
            t = (pd - on) / dn
            if dn < 0:
                if t > t0:
                    t0, nrm = t, pn
            elif t < t1:
                t1 = t
        if t0 <= t1 and t0 > 0:
            return t0, norm(nrm)
        return None


def ell(c, r, mat, **kw):
    return Prim("ell", mat, c=c, r=r, **kw)


def slab(planes, mat, **kw):
    return Prim("slab", mat, planes=[(norm(n), d / math.sqrt(dot(n, n))) for n, d in planes], **kw)


def box(x0, x1, y0, y1, z0, z1, mat, extra=(), **kw):
    return slab([((1, 0, 0), x1), ((-1, 0, 0), -x0), ((0, 1, 0), y1), ((0, -1, 0), -y0),
                 ((0, 0, 1), z1), ((0, 0, -1), -z0), *extra], mat, **kw)


def ramp(cols, cuts):
    def m(p, n, lam):
        return cols[sum(1 for t in cuts if lam >= t)]
    return m


def flat(col):
    return lambda p, n, lam: col


# --------------------------------------------------------------- the caster
def render(prims, scale, R, outline, pitch=CAM_PITCH, depth_edge=0.3, cw=CW, ch=CH):
    W, H = cw * 2, ch * 3
    pr = math.radians(pitch)
    fwd = (0.0, math.cos(pr), -math.sin(pr))
    up = (0.0, math.sin(pr), math.cos(pr))
    d_l = apply_t(R, fwd)
    rgb = [[None] * W for _ in range(H)]
    depth = [[math.inf] * W for _ in range(H)]
    for j in range(H):
        sy = (H / 2 - (j + 0.5)) / scale
        for i in range(W):
            sx = (i + 0.5 - W / 2) / scale
            o_w = (sx - fwd[0] * 50, sy * up[1] - fwd[1] * 50, sy * up[2] - fwd[2] * 50)
            o_l = apply_t(R, o_w)
            best_s, best_g = None, None
            for pm in prims:
                h = pm.hit(o_l, d_l)
                if h is None:
                    continue
                if pm.glass:
                    if best_g is None or h[0] < best_g[0]:
                        best_g = (h[0], h[1], pm)
                elif best_s is None or h[0] < best_s[0]:
                    best_s = (h[0], h[1], pm)
            pick = best_s
            if best_g is not None and (best_s is None or best_g[0] < best_s[0]) and not (best_s is not None and best_s[2].inside):
                pick = best_g
            if pick is None:
                continue
            t, nl, pm = pick
            pl = (o_l[0] + d_l[0] * t, o_l[1] + d_l[1] * t, o_l[2] + d_l[2] * t)
            lam = max(0.0, min(1.0, dot(apply(R, nl), LIGHT)))
            rgb[j][i] = pm.mat(pl, nl, lam)
            depth[j][i] = t
    hit = [[rgb[j][i] is not None for i in range(W)] for j in range(H)]
    out = [row[:] for row in rgb]
    for j in range(H):
        for i in range(W):
            if not hit[j][i]:
                continue
            for dj, di in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                jj, ii = j + dj, i + di
                if 0 <= jj < H and 0 <= ii < W and depth[jj][ii] < depth[j][i] - depth_edge:
                    out[j][i] = outline
                    break
    mask = [[hit[j][i] for i in range(W)] for j in range(H)]
    for j in range(H):
        for i in range(W):
            if hit[j][i]:
                continue
            for dj, di in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                jj, ii = j + dj, i + di
                if 0 <= jj < H and 0 <= ii < W and hit[jj][ii]:
                    out[j][i] = outline
                    mask[j][i] = True
                    break
    rows = [j for j in range(H) if any(mask[j])]
    cols = [i for i in range(W) if any(mask[j][i] for j in range(H))]
    shift = (ch - 1) - rows[-1]
    x0 = (cols[0] + cols[-1] + 1) // 2 - cw // 2
    cell = Canvas(cw, ch)
    cell.span = (cols[-1] - cols[0] + 1, rows[-1] - rows[0] + 1)
    lost = 0
    for j in range(H):
        for i in range(W):
            if not mask[j][i]:
                continue
            y, x = j + shift, i - x0
            if 0 <= y < ch and 0 <= x < cw:
                cell.px[y][x] = out[j][i]
            else:
                lost += 1
    return cell, lost


# --------------------------------------------------------------- palettes
def car_palette(body, accent, **extra):
    p = {
        "OUT": hx(0x141018), "TYRE": hx(0x2C2A30), "HUB": hx(0x8A8C96),
        "GLASS": hx(0x203C50), "GLINT": hx(0x8CE8F0),
        "B0": hx(body[0]), "B1": hx(body[1]), "B2": hx(body[2]),
        "A0": hx(accent[0]), "A1": hx(accent[1]),
        "TAIL": hx(0xF04030), "LAMP": hx(0xFFF0B0),
    }
    for k, v in extra.items():
        p[k] = hx(v)
    return p


def wheel(x, y, r, w, pal, hub_side=1):
    def m(p, n, lam):
        dy, dz = p[1] - y, p[2] - r
        if abs(n[0]) > 0.6 and dy * dy + dz * dz < (0.42 * r) ** 2:
            return pal["HUB"]
        return pal["OUT"] if lam < 0.35 else pal["TYRE"]
    pm = ell((x, y, r), (w, r, r), m)
    pm.wheel = True
    return pm


def body_ramp(pal, cuts=(0.3, 0.6)):
    return ramp([pal["B0"], pal["B1"], pal["B2"]], list(cuts))


def glass_mat(pal):
    return lambda p, n, lam: pal["GLINT"] if lam > 0.86 else pal["GLASS"]


def lamp(c, r, col):
    return ell(c, r, flat(col))


# ===================================================================== models
# Units: about 0.1 of a car length. Each model's origin is its footprint centre.

def ws_body(pal, stripe=None):
    """WORKSTATION: an armoured muscle car on a 2U chassis: long hood, wide hips,
    rack-ear grooves along the flanks."""
    br = body_ramp(pal)

    def body(p, n, lam):
        c = br(p, n, lam)
        if abs(n[0]) > 0.6 and (abs(p[2] - 0.33) < 0.025 or abs(p[2] - 0.45) < 0.025):
            return pal["B0"]                      # 2U grooves
        if stripe and n[2] > 0.5 and abs(p[0]) < 0.14:
            return stripe(lam)
        return c
    prims = [
        box(-0.8, 0.8, -0.95, 0.95, 0.16, 0.5, body,
            extra=[((0, 0.5, 1), 0.88), ((0.6, 0, 1), 0.9), ((-0.6, 0, 1), 0.9), ((0, -0.6, 1), 1.0)]),
        box(-0.86, 0.86, -0.9, -0.35, 0.14, 0.46, body, extra=[((0.8, 0, 1), 1.06), ((-0.8, 0, 1), 1.06)]),   # hips
    ]
    for sx in (-1, 1):
        prims += [wheel(sx * 0.86, -0.6, 0.26, 0.17, pal), wheel(sx * 0.84, 0.62, 0.24, 0.16, pal)]
    prims += [lamp((sx * 0.55, -0.95, 0.38), (0.14, 0.03, 0.05), pal["TAIL"]) for sx in (-1, 1)]
    return prims


def tc_body(pal, cage_col):
    """THIN CLIENT: a stripped dune buggy, a roll cage over one seat, fat rear tyres."""
    br = body_ramp(pal)
    cage = ramp([pal["OUT"], cage_col], [0.3])
    prims = [
        box(-0.44, 0.44, -0.8, 0.85, 0.18, 0.4, br, extra=[((0, 0.7, 1), 0.85), ((0, -0.5, 1), 0.68)]),
        box(-0.32, 0.32, -0.98, -0.5, 0.2, 0.52, ramp([pal["OUT"], pal["TYRE"], pal["HUB"]], [0.3, 0.7])),  # engine
    ]
    for sx in (-1, 1):
        prims += [
            wheel(sx * 0.74, -0.58, 0.32, 0.22, pal), wheel(sx * 0.66, 0.62, 0.22, 0.15, pal),
            box(sx * 0.4 - 0.045, sx * 0.4 + 0.045, -0.5, -0.42, 0.3, 1.0, cage),      # rear hoop posts
            box(sx * 0.36 - 0.04, sx * 0.36 + 0.04, 0.12, 0.2, 0.35, 0.7, cage),        # front posts
            box(sx * 0.37 - 0.035, sx * 0.37 + 0.035, -0.46, 0.2, 0.66 + 0.0, 0.72, cage,
                extra=[((0, 1, 2.5), 0.2 * 1 + 0.72 * 2.5)]),                          # side rails
            box(sx * 0.66 - 0.13, sx * 0.66 + 0.13, 0.4, 0.82, 0.38, 0.44, br),           # front fenders
            box(sx * 0.74 - 0.2, sx * 0.74 + 0.2, -0.86, -0.3, 0.6, 0.68, br),           # rear fenders
        ]
    prims += [box(-0.45, 0.45, -0.5, -0.42, 0.98, 1.06, cage), box(-0.4, 0.4, 0.12, 0.2, 0.66, 0.72, cage)]
    prims += [lamp((sx * 0.2, -0.99, 0.42), (0.07, 0.03, 0.05), pal["TAIL"]) for sx in (-1, 1)]
    return prims


def mf_body(pal, body_mat=None, length=(-0.92, 0.8), top=0.74):
    """MAINFRAME: a six-wheel slab-armoured rig with a ram plough."""
    bm = body_mat or body_ramp(pal)
    y0, y1 = length
    prims = [box(-0.84, 0.84, y0, y1, 0.2, top, bm,
                 extra=[((0.5, 0, 1), top + 0.34), ((-0.5, 0, 1), top + 0.34), ((0, 0.6, 1), top + 0.5)])]
    for sx in (-1, 1):
        for wy in (y0 + 0.32, y0 + 0.82, y1 - 0.3):
            prims.append(wheel(sx * 0.84, wy, 0.24, 0.15, pal))
    prims += [lamp((sx * 0.6, y0, 0.36), (0.12, 0.03, 0.06), pal["TAIL"]) for sx in (-1, 1)]
    return prims


def plough(pal, y_front, z_top=0.62, reach=0.42, col=("A0", "A1"), bars=True):
    """A cow-catcher: a chevron wedge ahead of the nose, with bars."""
    m = ramp([pal[col[0]], pal[col[1]]], [0.45])

    def bar(p, n, lam):
        if bars and (int((p[0] + 2) * 9) % 2 == 0):
            return pal["OUT"]
        return m(p, n, lam)
    return slab([((0, 0, -1), -0.08), ((0, 0, 1), z_top), ((0, -1, 0), -y_front + 0.05),
                 ((0.55, 1, 0.5), y_front + reach * 0.6), ((-0.55, 1, 0.5), y_front + reach * 0.6),
                 ((1, 0, 0), 0.9), ((-1, 0, 0), 0.9)], bar)


def driver_head(pal, y, z, col_key, r=0.2, extra=None):
    prims = [ell((0, y, z), (r, r * 0.95, r), ramp([pal[col_key + "0"], pal[col_key + "1"]], [0.45]), inside=True)]
    return prims + (extra or [])


# --------------------------------------------------------------- the six
SCALE = 9.5   # px per model unit, one world scale for all six


def anteater():
    """SNOUTY: ANTEATER on WORKSTATION. Tan and coral like Zero's Anteater, the giant
    anteater's dark shoulder band, a long snout ram prow, and Snouty (purple) in the
    open cockpit with the eyepatch strap round his head."""
    pal = car_palette((0x7E6E5A, 0xB4A48C, 0xECE2CC), (0xA8504A, 0xF18271),
                      F0=0x662BB8, F1=0xBE7AF3, BAND=0x3A3038)
    coral = ramp([pal["A0"], pal["A1"]], [0.45])
    br = body_ramp(pal)

    def body(p, n, lam):
        band = p[1] - 0.6 * abs(p[0])          # the shoulder band: a chevron pointing back
        if -0.92 < band < -0.72:
            return pal["BAND"]
        if -0.72 <= band < -0.6:
            return pal["B2"]
        if abs(n[0]) > 0.6 and 0.26 < p[2] < 0.34:
            return coral(p, n, lam)            # coral waterline
        return br(p, n, lam)
    prims = ws_body(pal)
    prims[0].mat = body
    prims[1].mat = body

    def sn(p, n, lam):
        return pal["OUT"] if p[1] > 1.72 else br(p, n, lam)
    for (y, z, r) in [(0.95, 0.38, 0.22), (1.2, 0.36, 0.18), (1.42, 0.32, 0.14), (1.62, 0.28, 0.11), (1.76, 0.25, 0.09)]:
        prims.append(ell((0, y, z), (r * 1.15, r * 1.6, r), sn))
    prims.append(box(-0.5, 0.5, 0.1, 0.16, 0.46, 0.66, glass_mat(pal), extra=[((0, 0.5, 1), 0.72)], glass=True))

    def fur(p, n, lam):
        hx_, hz = p[0], p[2] - 0.74
        if abs(hz - 0.45 * hx_ - 0.01) < 0.05:          # the strap, tilted round his head
            return pal["OUT"]
        if hx_ < -0.12 and p[1] > -0.2 and abs(hz) < 0.1:  # the patch on his left eye
            return pal["OUT"]
        return pal["F1"] if lam > 0.55 else pal["F0"]
    prims += [
        ell((0, -0.24, 0.74), (0.25, 0.23, 0.23), fur),
        ell((-0.17, -0.32, 0.95), (0.08, 0.05, 0.09), flat(pal["F0"])),
        ell((0.17, -0.32, 0.95), (0.08, 0.05, 0.09), flat(pal["F0"])),
        ell((0, 0.04, 0.7), (0.07, 0.24, 0.07), fur),   # his own snout, pointing forward
    ]
    return pal, prims


def big_iron():
    """LEGACY: BIG IRON on MAINFRAME. IBM blue slabs, a beige band, two tape reels
    on the tail, a cow-catcher plough."""
    pal = car_palette((0x1E3266, 0x3458A8, 0x5A86D8), (0x8A8070, 0xD8CCAA), REEL=0xE8E0C8)
    br = body_ramp(pal)

    def body(p, n, lam):
        if abs(n[0]) > 0.6 and 0.4 < p[2] < 0.5:
            return pal["A1"] if lam > 0.4 else pal["A0"]   # beige band
        if n[1] < -0.7:                                       # tail face: two tape reels
            for cx in (-0.4, 0.4):
                d = (p[0] - cx) ** 2 + (p[2] - 0.5) ** 2
                if d < 0.004:
                    return pal["OUT"]
                if d < 0.045:
                    return pal["REEL"] if d > 0.012 else pal["A0"]
        if n[2] > 0.6 and abs(p[0]) < 0.6 and ((p[1] + 2) * 5) % 1 < 0.35:
            return pal["B0"]                                  # roof vents
        return br(p, n, lam)
    prims = mf_body(pal, body_mat=body)
    prims.append(plough(pal, 0.8, z_top=0.44, reach=0.38))
    return pal, prims


def ctrl_v():
    """KIDDIE: CTRL-V on THIN CLIENT. Lime buggy, stickers everywhere, a big spoiler,
    KIDDIE in the cage with goggles on."""
    pal = car_palette((0x2E6A1A, 0x5AAE2E, 0x9AE050), (0xF060A0, 0xFFE040),
                      H0=0x5A2E1A, H1=0x8E4A24, G=0xC8962E)
    stick = [pal["A0"], pal["A1"], pal["LAMP"]]
    br = body_ramp(pal)

    def body(p, n, lam):
        k = int((p[0] + 3) * 7) * 31 + int((p[1] + 3) * 6) * 17 + int((p[2] + 3) * 7) * 7
        if k % 5 == 0:
            return stick[k % 3]
        return br(p, n, lam)
    prims = tc_body(pal, cage_col=pal["HUB"])
    prims[0].mat = body
    wing = ramp([pal["A0"], pal["A1"]], [0.4])
    prims += [
        box(-0.8, 0.8, -1.12, -0.88, 0.7, 0.78, wing),
        box(-0.3, -0.24, -1.05, -0.96, 0.5, 0.7, flat(pal["OUT"])),
        box(0.24, 0.3, -1.05, -0.96, 0.5, 0.7, flat(pal["OUT"])),
    ]
    prims += driver_head(pal, -0.15, 0.72, "H", r=0.21)
    prims.append(ell((0, -0.1, 0.8), (0.23, 0.15, 0.06), flat(pal["G"]), inside=True))   # goggles band
    return pal, prims


def uptime():
    """SYSADMIN: UPTIME on WORKSTATION. Flannel red, a closed canopy, and a rack of
    blinking LEDs bolted to the rear deck."""
    pal = car_palette((0x6A1E22, 0xB0363A, 0xE06058), (0x2C2F38, 0x4A4E5C), LED=0x4CE070, AMB=0xF0B830)
    prims = ws_body(pal)
    rack = ramp([pal["A0"], pal["A1"]], [0.45])

    def rk(p, n, lam):
        if n[1] < -0.7 or abs(n[0]) > 0.7:
            u = p[0] if n[1] < -0.7 else p[1]
            row = int((p[2] - 0.46) / 0.1)
            if (p[2] - 0.46) % 0.1 < 0.04:
                return pal["OUT"]
            if int((u + 2) / 0.13) % 3 == 0:
                return pal["LED"] if (row + int((u + 2) / 0.13)) % 4 else pal["AMB"]
        return rack(p, n, lam)
    prims.append(box(-0.56, 0.56, -0.92, -0.5, 0.46, 0.86, rk))
    prims.append(ell((0, 0.0, 0.52), (0.44, 0.42, 0.24), glass_mat(pal), glass=True))
    return pal, prims


def persist():
    """ROOTKIT: PERSIST on THIN CLIENT. Matte black; only its green lights show."""
    pal = car_palette((0x0C0D10, 0x16181E, 0x22252E), (0x1E8C3A, 0x52F070),
                      HD0=0x0C0E10, HD1=0x2C2F38, TAIL=0x52F070)
    prims = tc_body(pal, cage_col=pal["B2"])
    prims += driver_head(pal, -0.15, 0.72, "HD", r=0.21)
    prims.append(ell((0, -0.12, 0.94), (0.06, 0.06, 0.08), flat(pal["HD1"])))   # the hood's point
    glow = flat(pal["A1"])
    prims += [ell((sx * 0.08, 0.06, 0.74), (0.04, 0.02, 0.03), glow, inside=True) for sx in (-1, 1)]
    prims += [lamp((sx * 0.3, 0.85, 0.34), (0.07, 0.03, 0.05), glow) for sx in (-1, 1)]
    prims.append(box(-0.5, 0.5, -0.7, 0.75, 0.1, 0.14, flat(pal["A0"])))   # underglow
    return pal, prims


def zombie():
    """BOTNET: ZOMBIE on MAINFRAME. A patched school bus, a stripe, heads in every window."""
    pal = car_palette((0x9A6A10, 0xE0A820, 0xF8D050), (0x6A6E78, 0xA0522D), SKIN=0xD2906A, HAT=0xC83A3A)
    br = body_ramp(pal)

    def body(p, n, lam):
        x, y, z = p
        side = abs(n[0]) > 0.6
        if side and 0.5 < z < 0.7:
            f = (y + 2) / 0.38
            k = int(f)
            f -= k
            if 0.14 < f < 0.86:
                if z < 0.66 and abs(f - 0.5) < 0.26 and k % 2 == 0:
                    return pal["HAT"] if z > 0.6 else pal["SKIN"]
                return pal["GLASS"]
            return pal["B0"]
        if side and abs(z - 0.4) < 0.035:
            return pal["OUT"]                                  # the black stripe
        if side and ((0.15 < y < 0.45 and z < 0.38) or (-0.85 < y < -0.55 and 0.22 < z < 0.46)):
            return pal["A0"] if lam > 0.4 else pal["OUT"]      # patches
        if n[1] < -0.7 and abs(x) < 0.66 and 0.44 < z < 0.7:
            for k, hx_ in enumerate((-0.4, 0.02, 0.42)):        # rear window: three heads
                d = (x - hx_) ** 2 + ((z - 0.5) * 1.1) ** 2
                if d < 0.014:
                    return pal["SKIN"]
                if abs(x - hx_) < 0.13 and 0.6 < z < 0.66:
                    return (pal["HAT"], pal["A1"], pal["A0"])[k]
            return pal["GLASS"]
        if n[2] > 0.6 and abs(x) < 0.7 and ((y + 2) * 3.3) % 1 < 0.12:
            return pal["B0"]                                   # roof seams
        return br(p, n, lam)
    prims = mf_body(pal, body_mat=body)
    prims.append(plough(pal, 0.8, z_top=0.4, reach=0.3, col=("OUT", "A1"), bars=False))
    tyre = ramp([pal["OUT"], pal["TYRE"]], [0.4])
    prims.append(ell((0.25, -0.35, 0.82), (0.24, 0.24, 0.08), tyre))   # a spare tyre on the roof
    prims.append(box(-0.55, -0.15, 0.1, 0.45, 0.76, 0.92, ramp([pal["A0"], pal["A1"]], [0.5])))  # salvage
    return pal, prims


CARS = [("snouty", "ANTEATER", anteater), ("legacy", "BIG IRON", big_iron), ("kiddie", "CTRL-V", ctrl_v),
        ("sysadmin", "UPTIME", uptime), ("rootkit", "PERSIST", persist), ("botnet", "ZOMBIE", zombie)]


# --------------------------------------------------------------- the sheet
EMBER_PATTERN = [(3, 1), (11, 2), (7, 4), (13, 0), (1, 3)]


def wreck_colours(pal):
    """Burnt: body and accent ramps fall to charcoal; the lights go out."""
    ch0, ch1 = pal["OUT"], pal["TYRE"]
    return {pal["B2"]: ch1, pal["B1"]: ch1, pal["B0"]: ch0, pal["A1"]: ch1, pal["A0"]: ch0,
            pal["GLINT"]: pal["GLASS"], pal["LAMP"]: ch1}


def fit(prims, R, pal):
    """Render at the shared scale, shrinking by quarter steps only if a view would overflow the cell."""
    s = SCALE
    while True:
        c, lost = render(prims, s, R, pal["OUT"])
        if not lost:
            return c
        s -= 0.25


def draw_car(fn):
    pal, prims = fn()
    cells = [fit(prims, R, pal) for R in (rot(), rot(yaw=-45), rot(yaw=-90))]
    # wreck: upside down and smouldering, charred palette, a few embers
    c = fit(prims, rot(yaw=-15, roll=180, pitch=4), pal)
    c.recolor(wreck_colours(pal))
    for (x, y) in sorted(c.mask(), key=lambda q: (q[1], q[0])):
        if (x * 7 + y * 13) % 23 == 0 and c.px[y][x] != pal["OUT"]:
            c.px[y][x] = pal["TAIL"]
    cells.append(c)
    # airborne: nose up 3 degrees, wheels hanging on extended suspension
    hang = [ell((pm.c[0], pm.c[1], pm.c[2] - 0.05), pm.r, pm.mat) if pm.wheel else pm for pm in prims]
    cells.append(fit(hang, rot(pitch=3), pal))
    sheet = Canvas(CW * 5, CH)
    for i, cell in enumerate(cells):
        sheet.paste(cell, i * CW, 0)
    return sheet, pal
