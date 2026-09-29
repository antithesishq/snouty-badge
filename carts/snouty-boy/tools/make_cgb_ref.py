#!/usr/bin/env python3
"""Convert cgb-acid2's reference PNG to the committed RGB555 reference.

Usage (from carts/snouty-boy/):
    tools/make_cgb_ref.py [tests/roms/cgb-acid2-reference.png] [tests/cgb_acid2_reference.bin]

Output: 160x144 pixels, row-major, each a little-endian u16
r5 | g5 << 5 | b5 << 10 (46,080 bytes), which tests/cgb_acid2.zig compares
against the palette RAM colours of the emulated frame.

The reference PNG was made from RGB555 colours with the per-channel
expansion c8 = (c5 << 3) | (c5 >> 2). This tool inverts it with c5 = c8 >> 3
and asserts, for every pixel and channel, that expanding c5 again gives the
PNG's value back, so the conversion is exact, not a rounding.

Stdlib only: a minimal PNG decoder (zlib + the five scanline filters) for
8-bit-or-less greyscale, RGB, palette, grey+alpha and RGBA images,
non-interlaced. The upstream reference is a 4-bit palette image.
"""
import struct
import sys
import zlib

W, H = 160, 144


def read_png(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos = 8
    idat = b""
    plte = None
    ihdr = None
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos : pos + 4])
        kind = data[pos + 4 : pos + 8]
        body = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif kind == b"PLTE":
            plte = [tuple(body[i : i + 3]) for i in range(0, len(body), 3)]
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
    w, h, depth, ctype, comp, filt, interlace = ihdr
    assert comp == 0 and filt == 0, "unknown PNG compression/filter method"
    assert interlace == 0, "interlaced PNG not supported"
    assert depth <= 8, "16-bit PNG not supported"
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    bits_pp = depth * channels
    bpp = max(1, bits_pp // 8)  # filter byte distance
    stride = (w * bits_pp + 7) // 8
    raw = zlib.decompress(idat)
    assert len(raw) == h * (stride + 1), "bad image data length"

    rows = []
    prev = bytearray(stride)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1 : (y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 0:
                pred = 0
            elif f == 1:
                pred = a
            elif f == 2:
                pred = b
            elif f == 3:
                pred = (a + b) // 2
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
            else:
                raise AssertionError(f"bad filter type {f}")
            line[i] = (line[i] + pred) & 0xFF
        rows.append(bytes(line))
        prev = line

    def samples(line):
        if depth == 8:
            return list(line)
        per = 8 // depth
        mask = (1 << depth) - 1
        out = []
        for byte in line:
            for k in range(per):
                out.append((byte >> (8 - depth * (k + 1))) & mask)
        return out

    pixels = []
    for line in rows:
        s = samples(line)[: w * channels]
        for x in range(w):
            px = s[x * channels : (x + 1) * channels]
            if ctype == 3:
                rgb = plte[px[0]]
            elif ctype in (0, 4):
                v = px[0] * 255 // ((1 << depth) - 1)
                rgb = (v, v, v)
            else:
                rgb = tuple(px[:3])
            pixels.append(rgb)
    return w, h, pixels


def to555(c8):
    c5 = c8 >> 3
    assert (c5 << 3) | (c5 >> 2) == c8, f"channel value {c8} is not a c5 expansion"
    return c5


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "tests/roms/cgb-acid2-reference.png"
    dst = sys.argv[2] if len(sys.argv) > 2 else "tests/cgb_acid2_reference.bin"
    w, h, pixels = read_png(src)
    assert (w, h) == (W, H), f"expected {W}x{H}, got {w}x{h}"
    out = bytearray()
    for r, g, b in pixels:
        out += struct.pack("<H", to555(r) | to555(g) << 5 | to555(b) << 10)
    assert len(out) == W * H * 2
    open(dst, "wb").write(out)
    print(f"{dst}: {len(out)} bytes, {len(set(pixels))} distinct colours")


if __name__ == "__main__":
    main()
