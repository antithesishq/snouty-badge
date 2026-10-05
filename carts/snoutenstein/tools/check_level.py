#!/usr/bin/env python3
"""Checks ASCII levels (cart/src/levels/*.txt) for reachability.

    tools/check_level.py FILE.txt [FILE.txt ...]

Parses the legend the way cart/src/level_parse.zig does (rows that are empty
or start with '#' are comments, trailing spaces trimmed, short rows padded
with wall, the cell after S is its facing arrow and counts as floor), then
runs a key-aware flood fill from the start: floor, pickups, enemies, plain
and exit doors always pass; C/I/G doors need their key, which is collected
when its cell is reached; repeat until nothing changes.

Reports per level: size, counts per enemy and pickup kind, door count,
textures used, unreachable cells with content, and exit reachability.
Also flags doors that are not in a one-cell gap between two walls.
Exit status 1 if any pickup, enemy or the exit is unreachable (or a
structural error), except for files named wolf_* (imported maps have
secrets) and test.txt (the debug fixture locks two keys behind their own
doors), which only print.

Deathmatch arenas (M7) are the levels with spawn points (P): they need no
S (the first P is the start), no exit and no keys, and at least four
spawns, every one reachable.
"""
import os
import sys

WALLS = set("#12345678")
DOORS = {"D": "plain", "C": "coral", "I": "iris", "G": "gold", "E": "exit", "X": "secret"}
LOCKS = {"C": "c", "I": "i", "G": "g"}
PICKUPS = {"c": "key_coral", "i": "key_iris", "g": "key_gold", "+": "hotfix",
           "%": "charge", "$": "spray_can", "*": "battery", "&": "debugger"}
ENEMIES = {"a": "gnat", "w": "wasp", "b": "beetle", "s": "spider", "H": "boss"}
ARROWS = "><v^"
SPAWN = "P"
MIN_SPAWNS = 4
MAX_ENEMIES, MAX_DOORS, MAX_PICKUPS = 40, 64, 256
SOFT_MAX_ENEMIES = 25


def parse(text):
    rows = []
    for raw in text.split("\n"):
        line = raw.rstrip("\r ")
        if not line or line[0] == "#":
            continue
        rows.append(line)
    width = max((len(r) for r in rows), default=0)
    grid = [list(r.ljust(width).replace(" ", "#")) for r in rows]
    start = None
    for y, row in enumerate(grid):
        x = 0
        while x < width:
            if row[x] == "S":
                if start is not None:
                    raise ValueError("two starts")
                arrow = row[x + 1] if x + 1 < width else ">"
                if arrow not in ARROWS:
                    raise ValueError(f"bad start arrow {arrow!r} at {x},{y}")
                start = (x, y, arrow)
                if x + 1 < width:
                    row[x + 1] = "."  # the arrow cell is floor
                    x += 1
            x += 1
    if start is None:
        for y, row in enumerate(grid):
            if SPAWN in row and start is None:
                start = (row.index(SPAWN), y, ">")
    if start is None:
        raise ValueError("no start")
    for y, row in enumerate(grid):
        for x, ch in enumerate(row):
            if ch not in WALLS and ch not in DOORS and ch not in PICKUPS \
                    and ch not in ENEMIES and ch not in ".S" + SPAWN:
                raise ValueError(f"unknown char {ch!r} at {x},{y}")
    return grid, width, len(grid), start


def cell(grid, w, h, x, y):
    if x < 0 or y < 0 or x >= w or y >= h:
        return "#"
    return grid[y][x]


def check(path):
    name = os.path.basename(path)
    # wolf_* imports have secrets that stay unreachable by design.
    lenient = name.startswith("wolf_")
    with open(path) as f:
        grid, w, h, (sx, sy, arrow) = parse(f.read())
    errors = []

    counts = {}
    textures = set()
    doors = 0
    for y in range(h):
        for x in range(w):
            ch = grid[y][x]
            counts[ch] = counts.get(ch, 0) + 1
            if ch in WALLS:
                textures.add(1 if ch == "#" else int(ch))  # default_wall 0
            if ch in DOORS:
                doors += 1
                lr = cell(grid, w, h, x - 1, y) in WALLS and cell(grid, w, h, x + 1, y) in WALLS
                ud = cell(grid, w, h, x, y - 1) in WALLS and cell(grid, w, h, x, y + 1) in WALLS
                if lr == ud:
                    errors.append(f"door {ch} at {x},{y} is not in a one-cell gap between two walls")
    n_enemies = sum(counts.get(k, 0) for k in ENEMIES)
    n_pickups = sum(counts.get(k, 0) for k in PICKUPS)
    if n_enemies > MAX_ENEMIES:
        errors.append(f"{n_enemies} enemies > {MAX_ENEMIES}")
    if doors > MAX_DOORS:
        errors.append(f"{doors} doors > {MAX_DOORS}")
    if n_pickups > MAX_PICKUPS:
        errors.append(f"{n_pickups} pickups > {MAX_PICKUPS}")
    dx, dy = {">": (1, 0), "<": (-1, 0), "v": (0, 1), "^": (0, -1)}[arrow]
    if arrow != ">" or sx + 1 < w:
        ahead = cell(grid, w, h, sx + dx, sy + dy)
        if ahead in WALLS or ahead in DOORS:
            errors.append(f"start at {sx},{sy} faces {ahead!r}, not floor")

    spawns = [(x, y) for y in range(h) for x in range(w) if grid[y][x] == SPAWN]
    arena = bool(spawns)
    if arena:
        if len(spawns) < MIN_SPAWNS:
            errors.append(f"arena has {len(spawns)} spawns < {MIN_SPAWNS}")
        for ch in "cigCIGE":
            if counts.get(ch):
                errors.append(f"arena has {ch!r} (no keys, locks or exit in deathmatch)")

    # Key-aware flood fill.
    keys = set()
    seen = set()
    order = []  # (step, what) for the path summary
    while True:
        seen_before, keys_before = len(seen), len(keys)
        seen = {(sx, sy)}
        stack = [(sx, sy)]
        while stack:
            x, y = stack.pop()
            ch = grid[y][x]
            if ch in "cig" and ch not in keys:
                keys.add(ch)
                order.append(f"key {ch} at {x},{y}")
            for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                if (nx, ny) in seen:
                    continue
                c = cell(grid, w, h, nx, ny)
                if c in WALLS:
                    continue
                if c in LOCKS and LOCKS[c] not in keys:
                    continue
                if c == "E":
                    seen.add((nx, ny))  # walking in ends the level
                    continue
                seen.add((nx, ny))
                stack.append((nx, ny))
        if len(seen) == seen_before and len(keys) == keys_before:
            break

    unreachable = []
    exit_ok = False
    exits = 0
    for y in range(h):
        for x in range(w):
            ch = grid[y][x]
            if ch == "E":
                exits += 1
                exit_ok = exit_ok or (x, y) in seen
            if (ch in PICKUPS or ch in ENEMIES or ch in DOORS or ch == SPAWN) and (x, y) not in seen:
                unreachable.append(f"{ch}@{x},{y}")
    floor_total = sum(1 for y in range(h) for x in range(w) if grid[y][x] not in WALLS)
    floor_seen = len(seen)

    def fmt(table):
        return " ".join(f"{v}={counts[k]}" for k, v in table.items() if counts.get(k))
    print(f"{name}: {w}x{h}, start {sx},{sy} facing {arrow}")
    print(f"  enemies {n_enemies}: {fmt(ENEMIES) or '-'}")
    print(f"  pickups {n_pickups}: {fmt(PICKUPS) or '-'}")
    print(f"  doors {doors}: {fmt(DOORS) or '-'}")
    print(f"  textures {sorted(textures)}" + ("" if textures >= set(range(1, 9)) else
          f" (missing {sorted(set(range(1, 9)) - textures)})"))
    print(f"  key order: {', '.join(order) or '-'}")
    if arena:
        print(f"  arena: {len(spawns)} spawns; reachable {floor_seen}/{floor_total} open cells")
    else:
        print(f"  reachable {floor_seen}/{floor_total} open cells; exit "
              f"{'reachable' if exit_ok else 'NOT reachable'}")
    if n_enemies > SOFT_MAX_ENEMIES:
        print(f"  note: {n_enemies} enemies > {SOFT_MAX_ENEMIES} (soft cap)")
    if unreachable:
        print(f"  unreachable: {' '.join(unreachable)}")
    for e in errors:
        print(f"  error: {e}")
    if exits == 0 and not arena:
        errors.append("no exit")
    bad = bool(errors) or bool([u for u in unreachable if u[0] not in DOORS]) or not (exit_ok or arena)
    if bad and lenient:
        print("  (lenient: wolf_* import or test fixture; reported, not failed)")
        return True
    return not bad


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip().split("\n\n")[1])
        return 2
    ok = True
    for path in argv[1:]:
        try:
            ok = check(path) and ok
        except (OSError, ValueError) as e:
            print(f"{path}: {e}")
            ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
