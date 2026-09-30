#!/usr/bin/env python3
"""Generate the 64x64 blue-noise dither table (SPEC.md 5.5 mode 2, PLAN.md M3).

Run from the cart directory:  python3 tools/gen_bluenoise.py

Writes cart/src/bluenoise64.bin: 4096 bytes, row-major (index y * 64 + x),
each byte the rank of that cell in Ulichney's void-and-cluster ordering
scaled to 0..255 (rank * 256 // 4096, so every value occurs 16 times). The
cart turns byte v into the threshold (v + 0.5) / 256 at start().

Deterministic: fixed seed, toroidal Gaussian energy (sigma 1.5). Needs numpy.
"""
import os
import numpy as np

N = 64
SIGMA = 1.5
SEED = 0x5EED
OUT = os.path.join(os.path.dirname(__file__), "..", "cart", "src", "bluenoise64.bin")


def kernel():
    d = np.minimum(np.arange(N), N - np.arange(N)).astype(np.float64)
    g = np.exp(-(d[:, None] ** 2 + d[None, :] ** 2) / (2 * SIGMA * SIGMA))
    return g  # g[dy, dx], toroidal distance from (0, 0)


K = kernel()


def splat(energy, y, x, sign):
    energy += sign * np.roll(np.roll(K, y, axis=0), x, axis=1)


def energy_of(pattern):
    e = np.zeros((N, N))
    for y, x in zip(*np.nonzero(pattern)):
        splat(e, y, x, 1.0)
    return e


def tightest_cluster(pattern, e):
    masked = np.where(pattern, e, -np.inf)
    return np.unravel_index(np.argmax(masked), e.shape)


def largest_void(pattern, e):
    masked = np.where(pattern, np.inf, e)
    return np.unravel_index(np.argmin(masked), e.shape)


def main():
    rng = np.random.default_rng(SEED)
    total = N * N
    ones = total // 10
    pattern = np.zeros((N, N), dtype=bool)
    pattern.flat[rng.choice(total, ones, replace=False)] = True

    # Initial binary pattern: move the tightest cluster to the largest void
    # until that is a no-op.
    e = energy_of(pattern)
    while True:
        c = tightest_cluster(pattern, e)
        pattern[c] = False
        splat(e, c[0], c[1], -1.0)
        v = largest_void(pattern, e)
        pattern[v] = True
        splat(e, v[0], v[1], 1.0)
        if v == c:
            break
    initial = pattern.copy()
    e_initial = e.copy()

    rank = np.full((N, N), -1, dtype=np.int64)

    # Phase 1: remove tightest clusters, ranks ones-1 .. 0.
    p = initial.copy()
    e = e_initial.copy()
    for r in range(ones - 1, -1, -1):
        c = tightest_cluster(p, e)
        p[c] = False
        splat(e, c[0], c[1], -1.0)
        rank[c] = r

    # Phase 2: fill largest voids up to half, ranks ones .. total/2 - 1.
    p = initial.copy()
    e = e_initial.copy()
    for r in range(ones, total // 2):
        v = largest_void(p, e)
        p[v] = True
        splat(e, v[0], v[1], 1.0)
        rank[v] = r

    # Phase 3: the minority is now the zeros; take the tightest cluster of
    # zeros (lowest energy of ones = most crowded zeros) for the rest.
    e0 = energy_of(~p)
    for r in range(total // 2, total):
        c = tightest_cluster(~p, e0)
        p[c] = True
        splat(e0, c[0], c[1], -1.0)
        rank[c] = r

    assert (rank >= 0).all() and len(np.unique(rank)) == total
    table = (rank * 256 // total).astype(np.uint8)
    with open(OUT, "wb") as f:
        f.write(table.tobytes())
    print(f"wrote {os.path.normpath(OUT)} ({table.size} bytes)")


if __name__ == "__main__":
    main()
