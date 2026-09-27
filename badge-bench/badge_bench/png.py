"""Framebuffer -> PNG, no dependencies.

Hardware layout (sycl-badge src/os/cart/api.zig): Framebuffer is
[160][128]Pixel, column-major (x * 128 + y), and on the badge Pixel is a
plain bitcast of DisplayColor = packed struct(u16) { r: u5, g: u6, b: u5 },
so red is bits 0..4, green 5..10, blue 11..15, stored little-endian.
"""
import struct
import zlib

W, H = 160, 128


def _lut(bits):
    m = (1 << bits) - 1
    return [round(v * 255 / m) for v in range(m + 1)]


_L5, _L6 = _lut(5), _lut(6)


def fb_to_rgb_rows(fb):
    """fb: 0xA000 bytes -> list of H rows of RGB888 bytes."""
    px = struct.unpack(f'<{W * H}H', fb)
    rows = []
    for y in range(H):
        row = bytearray(3 * W)
        for x in range(W):
            v = px[x * H + y]
            row[3 * x] = _L5[v & 31]
            row[3 * x + 1] = _L6[(v >> 5) & 63]
            row[3 * x + 2] = _L5[v >> 11]
        rows.append(bytes(row))
    return rows


def write_png(path, rows, w=W, h=H):
    raw = b''.join(b'\x00' + r for r in rows)

    def chunk(t, d):
        c = struct.pack('>I', len(d)) + t + d
        return c + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr)
                + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def write_fb(path, fb):
    write_png(path, fb_to_rgb_rows(fb))
