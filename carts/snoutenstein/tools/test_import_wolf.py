#!/usr/bin/env python3
"""Tests for tools/import_wolf.py.

    python3 tools/test_import_wolf.py              # run the tests
    python3 tools/test_import_wolf.py --check F..  # check level files against the parser rules

Builds a synthetic MAPHEAD/GAMEMAPS pair in memory with reference RLEW and
Carmack encoders (the Carmack stream contains near pointers, far pointers and
escaped tag bytes), imports it and checks the ASCII output. `check_level`
mirrors the constraints of cart/src/levels.zig `parse`.
"""
import contextlib
import io
import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import import_wolf as iw  # noqa: E402

TAG = 0xABCD
W = H = 64


# ---------------------------------------------------------------- encoders

def rlew_compress(words, tag=TAG):
    out = []
    i = 0
    while i < len(words):
        w = words[i]
        n = 1
        while i + n < len(words) and words[i + n] == w and n < 0xFFFF:
            n += 1
        if n > 3 or w == tag:
            out += [tag, n, w]
        else:
            out += [w] * n
        i += n
    return out


def carmack_compress(words, stats=None):
    """Greedy LZ over words. Returns bytes (without the length word)."""
    out = bytearray()
    i = 0
    stats = stats if stats is not None else {}
    while i < len(words):
        best_len, best_start = 0, 0
        for s in range(i):  # O(n^2), fine for tests
            n = 0
            while i + n < len(words) and words[s + n] == words[i + n] and n < 255:
                n += 1
            if n > best_len or (n == best_len and n and s > best_start):
                best_len, best_start = n, s
        if best_len >= 2:
            back = i - best_start
            if back <= 255:
                out += bytes([best_len, iw.NEARTAG, back])
                stats["near"] = stats.get("near", 0) + 1
            else:
                out += bytes([best_len, iw.FARTAG]) + struct.pack("<H", best_start)
                stats["far"] = stats.get("far", 0) + 1
            i += best_len
            continue
        w = words[i]
        if (w >> 8) in (iw.NEARTAG, iw.FARTAG):
            out += bytes([0, w >> 8, w & 0xFF])  # count 0 escapes the tag
            stats["escape"] = stats.get("escape", 0) + 1
        else:
            out += struct.pack("<H", w)
        i += 1
    return bytes(out)


def compress_plane(words, stats=None):
    rlew = rlew_compress(words)
    inner = [len(words) * 2] + rlew
    body = carmack_compress(inner, stats)
    return struct.pack("<H", len(inner) * 2) + body


def build_files(levels):
    """levels: list of (name, plane0, plane1). Returns (maphead, gamemaps, stats)."""
    stats = {}
    gm = bytearray(b"TED5v1.0")
    offsets = []
    for name, p0, p1 in levels:
        planes = [compress_plane(p0, stats), compress_plane(p1, stats),
                  compress_plane([0] * (W * H))]
        starts = []
        for p in planes:
            starts.append(len(gm))
            gm += p
        offsets.append(len(gm))
        gm += struct.pack("<3i3H2H", *starts, *[len(p) for p in planes], W, H)
        gm += name.encode().ljust(16, b"\0")
    mh = struct.pack("<H", TAG) + struct.pack("<100i", *(offsets + [0] * (100 - len(offsets))))
    return mh, bytes(gm), stats


def blank():
    return [1] * (W * H), [0] * (W * H)


def put(plane, x, y, v):
    plane[y * W + x] = v


def room(p0, x0, y0, x1, y1, floor=108):
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            put(p0, x, y, floor)


# ---------------------------------------------------------------- parser mirror

def check_level(text):
    """Mirror of levels.zig parse(). Returns a list of problems (empty = OK).
    Border cells must be wall or door (outside the map is wall, so a door on
    the edge still leaves the level closed)."""
    rows = []
    for raw in text.split("\n"):
        line = raw.rstrip("\r ")
        if not line or line[0] == "#":
            continue
        rows.append(line)
    errs = []
    if len(rows) > 64:
        errs.append("more than 64 rows")
    width = max((len(r) for r in rows), default=0)
    if width > 64:
        errs.append("row wider than 64")
    grid = [list(r.ljust(width, "#").replace(" ", "#")) for r in rows]
    known = set(".#12345678DCIGESci g+%$*awbsH^v<>".replace(" ", ""))
    starts = 0
    doors = pickups = enemies = 0
    for y, r in enumerate(grid):
        x = 0
        while x < width:
            ch = r[x]
            if ch == "S":
                starts += 1
                if x + 1 >= width or r[x + 1] not in "^v<>":
                    errs.append("S at (%d,%d) not followed by an arrow" % (x, y))
                x += 2
                continue
            if ch in "^v<>":
                errs.append("stray arrow at (%d,%d)" % (x, y))
            elif ch not in known:
                errs.append("unknown char %r at (%d,%d)" % (ch, x, y))
            elif ch in "DCIGE":
                doors += 1
            elif ch in "cig+%$*":
                pickups += 1
            elif ch in "awbsH":
                enemies += 1
            if (x in (0, width - 1) or y in (0, len(grid) - 1)) and ch not in "#12345678DCIGE":
                errs.append("border not closed at (%d,%d) %r" % (x, y, ch))
            x += 1
    if starts != 1:
        errs.append("%d starts" % starts)
    if doors > 64:
        errs.append("%d doors" % doors)
    if pickups > 256:
        errs.append("%d pickups" % pickups)
    if enemies > 40:
        errs.append("%d enemies" % enemies)
    return errs


def grid_rows(text):
    return [l for l in text.split("\n") if l and l[0] != "#"]


# ---------------------------------------------------------------- tests

WALLS = os.path.join(iw.REPO, "cart", "src", "levels", "wolf_walls.json")


def feature_map():
    p0, p1 = blank()
    # Room A x1..10, y1..6; room B x12..20, y1..6; door between at (11,3).
    room(p0, 1, 1, 10, 6)
    room(p0, 12, 1, 20, 6, floor=106)  # ambush marker is floor too
    put(p0, 11, 3, 90)                 # plain door, walls above/below
    # Corridor south of room A through a gold door (horizontal) at (3,7).
    room(p0, 3, 8, 3, 12)
    put(p0, 3, 7, 93)
    put(p0, 5, 7, 94)                  # silver door, north-south passage
    room(p0, 5, 8, 5, 12)
    put(p0, 3, 13, 101)                # elevator door
    put(p0, 8, 1, 8)                   # blue stone wall inside room A (texture 2)
    put(p0, 9, 6, 70)                  # unknown plane 0 code -> floor + warning
    # Objects.
    put(p1, 2, 2, 19)                  # start facing north, wall-free
    put(p1, 3, 2, 34)                  # potted plant right of the start -> dropped decoration
    put(p1, 4, 4, 43)                  # gold key
    put(p1, 5, 4, 44)                  # silver key
    put(p1, 6, 4, 47)                  # food
    put(p1, 7, 4, 48)                  # medkit
    put(p1, 8, 4, 49)                  # clip
    put(p1, 9, 4, 50)                  # machine gun
    put(p1, 10, 4, 51)                 # chaingun
    put(p1, 10, 5, 56)                 # extra life
    put(p1, 9, 5, 52)                  # cross: dropped
    put(p1, 13, 2, 108)                # guard standing, easy
    put(p1, 14, 2, 113)                # guard patrol, easy
    put(p1, 15, 2, 144)                # guard standing, medium only
    put(p1, 16, 2, 180)                # guard standing, hard only
    put(p1, 13, 3, 116)                # officer
    put(p1, 14, 3, 126)                # SS
    put(p1, 15, 3, 134)                # dog
    put(p1, 16, 3, 216)                # mutant, easy
    put(p1, 17, 3, 234)                # mutant, medium
    put(p1, 18, 3, 252)                # mutant, hard
    put(p1, 13, 5, 214)                # Hans
    put(p1, 0, 3, 98)                  # pushwall marker on a wall
    put(p1, 14, 5, 90)                 # patrol arrow: silent
    # Two copies of a 264-word pseudo-random wall strip, far apart and outside
    # the used area (cropped away): the Carmack encoder must use far pointers.
    seed = 12345
    for y in range(8):
        for x in range(30, 63):
            seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
            v = 1 + (seed >> 16) % 49
            put(p0, x, 20 + y, v)
            put(p0, x, 44 + y, v)
    return p0, p1


class Decode(unittest.TestCase):
    def test_carmack_handmade(self):
        # words: 0x1234, 0xA705 (escaped), near copy 2 back x2, far copy from 0 x3
        data = bytes([0x34, 0x12, 0x00, 0xA7, 0x05, 0x02, 0xA7, 0x02,
                      0x03, 0xA8, 0x00, 0x00, 0x00, 0xA8, 0x77])
        got = iw.carmack_expand(data, 2 * 8)
        self.assertEqual(got, [0x1234, 0xA705, 0x1234, 0xA705,
                               0x1234, 0xA705, 0x1234, 0xA877])

    def test_roundtrip(self):
        seed, rand = 1, []
        for _ in range(300):
            seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
            rand.append(seed >> 15)
        # random block, escapes, a short-range repeat, then the block again (> 255 back)
        words = rand + [0xA7FF, 0xA800] + list(range(40)) * 3 + rand[:60]
        stats = {}
        comp = compress_plane(words, stats)
        for k in ("near", "far", "escape"):
            self.assertGreater(stats.get(k, 0), 0, k)
        carmack_len = struct.unpack_from("<H", comp)[0]
        inner = iw.carmack_expand(comp[2:], carmack_len)
        self.assertEqual(iw.rlew_expand(inner[1:], inner[0], TAG), words)

    def test_rlew_tag_literal(self):
        words = [TAG, 5, 5, 5, 5, 5, 1]
        self.assertEqual(iw.rlew_expand(rlew_compress(words), 14, TAG), words)


class Import(unittest.TestCase):
    def setUp(self):
        p0, p1 = feature_map()
        p0b, p1b = crowd_map()
        self.mh, self.gm, self.stats = build_files([("Feature", p0, p1), ("Crowd", p0b, p1b)])

    def text(self, level, difficulty="medium"):
        h, res = iw.import_level(self.mh, self.gm, level, difficulty, WALLS)
        return res, iw.format_level(res, "TEST", level, h["name"], difficulty)

    def test_encoder_exercised(self):
        self.assertGreater(self.stats.get("near", 0), 0)
        self.assertGreater(self.stats.get("far", 0), 0)

    def test_list(self):
        tag, levels = iw.load_levels(self.mh, self.gm)
        self.assertEqual(tag, TAG)
        self.assertEqual([(i, h["name"]) for i, h in levels], [(0, "Feature"), (1, "Crowd")])

    def test_feature_medium(self):
        res, text = self.text(0)
        self.assertEqual(check_level(text), [])
        rows = grid_rows(text)
        self.assertEqual(res["crop"], (0, 0))
        self.assertEqual(rows[:9], [
            "1111111111111111111111",
            "1.......2..1.........1",
            "1.S^.......1.aaa.....1",
            "1..........D.sbwbb...1",
            "1...gi++%$$1.........1",
            "1.........*1.H.......1",
            "1..........1.........1",
            "111G1I1111111111111111",
            "111.1.1111111111111111",
        ])
        self.assertEqual(rows[13][:5], "111E1")
        self.assertEqual(len(rows), 15)
        # 94 is a vertical door (walls above/below in Wolf3D) placed in an
        # east-west wall: the parser will make it horizontal, so warn.
        self.assertTrue(any("door at (5,7)" in w for w in res["warnings"]))
        self.assertFalse(any("door at (11,3)" in w or "door at (3,7)" in w for w in res["warnings"]))
        self.assertEqual(res["counts"]["per_char"],
                         {"a": 3, "s": 1, "b": 3, "w": 1, "H": 1, "D": 1, "G": 1,
                          "I": 1, "E": 1, "g": 1, "i": 1, "+": 2, "%": 1, "$": 2, "*": 1})
        self.assertTrue(any("plane 0 code 70" in w for w in res["warnings"]))
        self.assertEqual(res["notes"].get("treasure dropped"), 1)
        self.assertEqual(res["notes"].get("pushwalls left solid"), 1)
        self.assertEqual(res["notes"].get("actors skipped (higher difficulty)"), 2)

    def test_difficulty(self):
        for diff, n_a, n_b in (("easy", 1 + 1, 1 + 1), ("medium", 3, 3), ("hard", 4, 4)):
            res, _ = self.text(0, diff)
            per = res["counts"]["per_char"]
            # a: guards 108,113 (+144 medium, +180 hard); b: SS + mutants per tier
            self.assertEqual(per.get("a"), n_a, diff)
            self.assertEqual(per.get("b"), n_b, diff)

    def test_start_moved(self):
        p0, p1 = feature_map()
        put(p1, 3, 2, 49)  # a clip right of the start: the pair must move
        mh, gm, _ = build_files([("Moved", p0, p1)])
        h, res = iw.import_level(mh, gm, 0, "medium", WALLS)
        text = iw.format_level(res, "TEST", 0, h["name"], "medium")
        self.assertEqual(check_level(text), [])
        self.assertTrue(any("start moved" in w for w in res["warnings"]))
        rows = grid_rows(text)
        self.assertEqual(rows[2][1:4], "S^%")
        self.assertEqual(res["start"], (1, 2))

    def test_thinning(self):
        res, text = self.text(1)
        self.assertEqual(check_level(text), [])
        per = res["counts"]["per_char"]
        self.assertEqual(res["counts"]["enemies"], 40)
        self.assertEqual(per.get("s"), 5)        # officers kept
        self.assertEqual(per.get("a"), 35)       # 45 guards -> 35
        rows = grid_rows(text)
        # The 10 dropped guards are the 10 farthest from the start (1,1).
        _, p1 = crowd_map()
        guards = [(x, y) for y in range(H) for x in range(W) if p1[y * W + x] == 108]
        guards.sort(key=lambda p: -((p[0] - 1) ** 2 + (p[1] - 1) ** 2))
        for x, y in guards[:10]:
            self.assertEqual(rows[y][x], ".", (x, y))
        for x, y in guards[10:]:
            self.assertEqual(rows[y][x], "a", (x, y))
        self.assertTrue(any("50 enemies exceed the pool of 40: dropped 10 a" in w
                            for w in res["warnings"]))

    def test_cli(self):
        with tempfile.TemporaryDirectory() as d:
            mhp, gmp, out = (os.path.join(d, n) for n in ("MAPHEAD.TST", "GAMEMAPS.TST", "o.txt"))
            for path, data in ((mhp, self.mh), (gmp, self.gm)):
                with open(path, "wb") as f:
                    f.write(data)
            with contextlib.redirect_stdout(io.StringIO()) as so, \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(iw.main([mhp, gmp, "--level", "0", "--out", out,
                                          "--walls", WALLS]), 0)
            self.assertIn("Feature 22x15, enemies 9, doors 4, pickups 8", so.getvalue())
            with open(out) as f:
                text = f.read()
            self.assertTrue(text.startswith("# Imported from Wolfenstein 3D"))
            self.assertEqual(check_level(text), [])


def crowd_map():
    """45 guards and 5 officers in one room; start at the top-left."""
    p0, p1 = blank()
    room(p0, 1, 1, 20, 10)
    put(p1, 1, 1, 20)  # start facing east
    for i in range(5):
        put(p1, 10 + i, 1, 116)  # officers near the top
    n = 0
    for y in (2, 4, 6, 8, 10):
        for x in range(2, 20, 2):
            if n < 45:
                put(p1, x, y, 108)
                n += 1
    return p0, p1


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--check":
        bad = 0
        for path in sys.argv[2:]:
            with open(path) as f:
                errs = check_level(f.read())
            print("%s: %s" % (path, "OK" if not errs else "; ".join(errs[:10])))
            bad += bool(errs)
        sys.exit(1 if bad else 0)
    unittest.main()
