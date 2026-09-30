# Side-profile flying anteater facing right: long drooping snout, humped back, bushy tail streaming
# left, stubby arms flapping with big claws, the giant anteater's black shoulder band with a pale edge.
from PIL import Image
import math, sys
W, H = 44, 28
COL = {'o': (0x24, 0x1C, 0x22), 'b': (0xB4, 0xA4, 0x8C), 'l': (0xEC, 0xE2, 0xCC), 'k': (0x3A, 0x30, 0x38), 'c': (0xFA, 0xF6, 0xEE), 'e': (0x10, 0x0C, 0x10)}
def blank(): return [['.'] * W for _ in range(H)]
def ellipse(g, cx, cy, rx, ry, ch, rot=0.0):
    c, s = math.cos(rot), math.sin(rot)
    for y in range(H):
        for x in range(W):
            dx, dy = x + .5 - cx, y + .5 - cy
            u, v = dx * c + dy * s, -dx * s + dy * c
            if (u / rx) ** 2 + (v / ry) ** 2 <= 1: g[y][x] = ch
def line(g, x0, y0, x1, y1, r0, ch, r1=None):
    r1 = r0 if r1 is None else r1
    n = int(max(abs(x1 - x0), abs(y1 - y0)) * 2) + 1
    for i in range(n + 1):
        t = i / n; x, y = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t; r = r0 + (r1 - r0) * t
        for yy in range(int(y - r) - 1, int(y + r) + 2):
            for xx in range(int(x - r) - 1, int(x + r) + 2):
                if 0 <= xx < W and 0 <= yy < H and (xx + .5 - x) ** 2 + (yy + .5 - y) ** 2 <= r * r: g[yy][xx] = ch
def outline(g):
    out = [r[:] for r in g]
    for y in range(H):
        for x in range(W):
            if g[y][x] == '.':
                for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                    yy, xx = y + dy, x + dx
                    if 0 <= yy < H and 0 <= xx < W and g[yy][xx] != '.': out[y][x] = 'o'; break
    return out
def frame(phase):
    g = blank()
    # tail: bushy, streaming back-left and slightly up, scalloped
    ellipse(g, 9, 14, 8.5, 4.2, 'b', rot=-0.25)
    for k in range(5):
        a = -0.25; t = -1 + k / 2
        ellipse(g, 9 + 7.5 * t * math.cos(a) - 4.2 * math.sin(a) * 0.9, 14 + 7.5 * t * math.sin(a) + 4.2 * math.cos(a) * 0.9, 2.2, 2.2, 'b')
    for k in range(4):   # light streaks along the tail
        t = -0.8 + k * 0.5
        line(g, 9 + 7 * t * math.cos(-0.25) + 1, 14 + 7 * t * math.sin(-0.25), 9 + 7 * t * math.cos(-0.25) - 1.5, 14 + 7 * t * math.sin(-0.25) + 3.8, 0.6, 'l')
    # body: humped back
    ellipse(g, 23, 15, 9, 6.2, 'b', rot=0.15)
    # head and long snout, drooping
    ellipse(g, 31.5, 11.5, 3.6, 3.1, 'b')
    pts = [(33, 11), (37, 12.2), (40.5, 14.2), (43.2, 17)]
    rs = (1.9, 1.35, 0.95, 0.65)
    for (x0, y0), (x1, y1), ra, rb in zip(pts, pts[1:], rs, rs[1:]): line(g, x0, y0, x1, y1, ra, 'b', rb)
    line(g, 40.5, 14.6, 43.2, 17, 0.45, 'l')         # pale snout tip
    # shoulder band: dark wedge from the throat up over the shoulder, pale edge in front
    line(g, 29, 18, 25, 9.5, 1.6, 'k')
    line(g, 30.5, 18.5, 27.2, 10.5, 0.6, 'l')
    # ear and eye
    ellipse(g, 30, 8.6, 1.1, 1.5, 'b'); g[10][32] = 'e'
    # legs tucked: a hind leg stub
    ellipse(g, 18, 20.5, 2.2, 1.6, 'b')
    # arm: flaps from the shoulder, big claws
    ang = {0: -1.1, 1: -0.35, 2: 0.55}[phase]      # negative = raised
    sx, sy = 27.5, 15.5; L = 8.5
    ex, ey = sx + L * math.cos(ang), sy + L * math.sin(ang)
    line(g, sx, sy, ex, ey, 2.0, 'b', 1.5)
    for j in (-1, 0, 1):
        a2 = ang + j * 0.4
        line(g, ex + 1.0 * math.cos(a2), ey + 1.0 * math.sin(a2), ex + 3.4 * math.cos(a2), ey + 3.4 * math.sin(a2), 0.6, 'c')
    return outline(g)
def to_img(g):
    im = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    for y in range(H):
        for x in range(W):
            if g[y][x] != '.': im.putpixel((x, y), COL[g[y][x]] + (255,))
    return im
frames = [frame(p) for p in (0, 1, 2)]
S = 6
sheet = Image.new('RGB', (3 * (W + 4) * S, H * S), (0x38, 0x24, 0x50))
for i, g in enumerate(frames):
    im = to_img(g).resize((W * S, H * S), Image.NEAREST); sheet.paste(im, (i * (W + 4) * S, 0), im)
sheet.save('sheet3.png')
bg = Image.open(sys.argv[1]).convert('RGB'); im = to_img(frames[1]); bg.paste(im, (80 - W // 2, 118 - H), im)
bg.resize((640, 512), Image.NEAREST).save('sheet3_scene.png')
if len(sys.argv) > 2:
    with open(sys.argv[2], 'w') as f:
        for i, g in enumerate(frames):
            f.write('    // phase %d: %s\n    .{\n' % (i, ('arms raised', 'arms level', 'arms down')[i]))
            for row in g: f.write('        "%s",\n' % ''.join(row))
            f.write('    },\n')
