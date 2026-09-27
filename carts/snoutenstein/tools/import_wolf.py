#!/usr/bin/env python3
"""Convert a Wolfenstein 3D map (MAPHEAD + GAMEMAPS) into our ASCII level format.

    import_wolf.py MAPHEAD.WL1 GAMEMAPS.WL1 --level 0 --difficulty medium \
        --walls cart/src/levels/wolf_walls.json --out cart/src/levels/wolf_e1m1.txt
    import_wolf.py MAPHEAD.WL1 GAMEMAPS.WL1 --list

File format (id Software's released WOLFSRC, ID_CA.C):
  MAPHEAD   u16 RLEW tag, then 100 int32 offsets into GAMEMAPS (0 or -1 = no level).
  GAMEMAPS  per level at its offset: int32 planestart[3], u16 planelength[3],
            u16 width, u16 height, char name[16].
            Each plane is Carmack-compressed; the first u16 of the compressed
            block is the Carmack-expanded length in bytes. The Carmack output is
            RLEW-compressed; its first u16 is the RLEW-expanded length in bytes
            (width * height * 2). Plane 0 = walls/doors/floor areas, plane 1 =
            objects and actors, plane 2 unused.

Code tables: WL_GAME.C ScanInfoPlane / SetupGameLevel, WL_DEF.H (see SPEC.md 6.1).
Standard library only.
"""
import argparse
import json
import os
import struct
import sys

NEARTAG = 0xA7
FARTAG = 0xA8

MAX_ENEMIES = 40
MAX_DOORS = 64
MAX_PICKUPS = 256
MAX_SIZE = 64

DIFFICULTIES = {"easy": 1, "medium": 2, "hard": 3}  # gd_easy, gd_medium, gd_hard

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_WALLS = os.path.join(REPO, "cart", "src", "levels", "wolf_walls.json")


# ---------------------------------------------------------------- decoding

def carmack_expand(src, expanded_len):
    """CAL_CarmackExpand. `src` is the compressed data after the length word.
    Returns a list of u16 words (expanded_len // 2 of them)."""
    out = []
    remaining = expanded_len // 2
    i = 0
    n = len(src)
    while remaining > 0:
        if i + 2 > n:
            raise ValueError("Carmack data truncated")
        ch = src[i] | (src[i + 1] << 8)
        i += 2
        hi = ch >> 8
        count = ch & 0xFF
        if hi == NEARTAG or hi == FARTAG:
            if count == 0:
                # Escaped literal: the low byte is the next input byte.
                out.append((ch & 0xFF00) | src[i])
                i += 1
                remaining -= 1
                continue
            if hi == NEARTAG:
                offset = src[i]
                i += 1
                start = len(out) - offset
            else:
                offset = src[i] | (src[i + 1] << 8)
                i += 2
                start = offset
            if start < 0 or start >= len(out):
                raise ValueError("Carmack pointer out of range")
            for k in range(count):
                out.append(out[start + k])  # may overlap, copy word by word
            remaining -= count
        else:
            out.append(ch)
            remaining -= 1
    return out[: expanded_len // 2]


def rlew_expand(words, expanded_len, tag):
    """CAL_RLEWexpand on a list of u16 words. Returns expanded_len // 2 words."""
    out = []
    target = expanded_len // 2
    i = 0
    while len(out) < target:
        w = words[i]
        i += 1
        if w == tag:
            count, value = words[i], words[i + 1]
            i += 2
            out.extend([value] * count)
        else:
            out.append(w)
    return out[:target]


def read_maphead(data):
    tag = struct.unpack_from("<H", data, 0)[0]
    n = min(100, (len(data) - 2) // 4)
    offsets = list(struct.unpack_from("<%di" % n, data, 2))
    return tag, offsets


def read_level_header(gamemaps, offset):
    starts = struct.unpack_from("<3i", gamemaps, offset)
    lengths = struct.unpack_from("<3H", gamemaps, offset + 12)
    width, height = struct.unpack_from("<2H", gamemaps, offset + 18)
    raw = gamemaps[offset + 22: offset + 38]
    name = raw.split(b"\0", 1)[0].decode("latin-1").strip()
    return {"starts": starts, "lengths": lengths, "width": width,
            "height": height, "name": name}


def read_plane(gamemaps, header, plane, tag):
    start = header["starts"][plane]
    length = header["lengths"][plane]
    block = gamemaps[start: start + length]
    carmack_len = struct.unpack_from("<H", block, 0)[0]
    words = carmack_expand(block[2:], carmack_len)
    rlew_len = words[0]
    plane_words = rlew_expand(words[1:], rlew_len, tag)
    need = header["width"] * header["height"]
    if len(plane_words) < need:
        raise ValueError("plane %d too short (%d < %d)" % (plane, len(plane_words), need))
    return plane_words[:need]


def load_levels(maphead, gamemaps):
    """Returns (tag, [(index, header)]) for every present level."""
    tag, offsets = read_maphead(maphead)
    levels = []
    for i, off in enumerate(offsets):
        if off <= 0 or off + 38 > len(gamemaps):
            continue
        levels.append((i, read_level_header(gamemaps, off)))
    return tag, levels


# ---------------------------------------------------------------- code tables

# Plane 1 actors (WL_GAME.C ScanInfoPlane). Each base code range is the
# easy tier; +36 is the medium-only tier, +72 the hard-only tier.
#   (first code of easy tier, our letter, description)
ACTOR_GROUPS = [
    (108, "a", "guard standing"),
    (112, "a", "guard patrolling"),
    (116, "s", "officer standing"),
    (120, "s", "officer patrolling"),
    (126, "b", "SS standing"),
    (130, "b", "SS patrolling"),
    (134, "w", "dog standing"),
    (138, "w", "dog patrolling"),
]
# Mutants are not on the +36 pattern: easy 216/220, medium 234/238, hard 252/256.
MUTANT_GROUPS = [
    ((216, 234, 252), "b", "mutant standing"),
    ((220, 238, 256), "b", "mutant patrolling"),
]
BOSSES = {
    214: "Hans Grosse", 197: "Gretel Grosse", 215: "Otto Giftmacher",
    179: "General Fettgesicht", 196: "Dr. Schabbs", 160: "fake Hitler",
    178: "Hitler",
}
PICKUPS = {
    43: ("g", "gold key"), 44: ("i", "silver key"),
    47: ("+", "food"), 48: ("+", "first aid kit"),
    49: ("%", "ammo clip"), 50: ("$", "machine gun"), 51: ("$", "chaingun"),
    56: ("*", "extra life"),
}
TREASURE = {52: "cross", 53: "chalice", 54: "chest", 55: "crown"}
# Statics 23..74 (statinfo[] in WL_ACT1.C), code - 23 = index. Those that
# block movement in Wolf3D; they become floor here (no obstacle sprites).
BLOCKING_STATICS = {24, 25, 26, 28, 30, 31, 33, 34, 35, 36, 39, 40, 41, 45,
                    58, 59, 60, 62, 63, 68, 69}
PLAYER_START = {19: "^", 20: ">", 21: "v", 22: "<"}
PUSHWALL = 98
PATROL_ARROWS = range(90, 98)
EXITTILE = 99
DEAD_GUARD = 124
GHOSTS = range(224, 228)

KIND_RANK = {"a": 0, "w": 1, "b": 2, "s": 3, "H": 4}  # thinning order (lowest first)
ENEMY_CHARS = set(KIND_RANK)
PICKUP_CHARS = set("cig+%$*")
DOOR_CHARS = set("DCIGE")
WALL_CHARS = set("#12345678")


def actor_table(difficulty):
    """code -> (letter, description) for actors present at `difficulty` (1..3)."""
    table = {}
    for base, ch, desc in ACTOR_GROUPS:
        for tier in range(difficulty):
            for d in range(4):
                table[base + 36 * tier + d] = (ch, desc)
    for bases, ch, desc in MUTANT_GROUPS:
        for tier in range(difficulty):
            for d in range(4):
                table[bases[tier] + d] = (ch, desc)
    for code, desc in BOSSES.items():
        table[code] = ("H", desc)
    return table


def all_actor_codes():
    """Every actor code at any difficulty (so higher tiers are silently skipped)."""
    return set(actor_table(3))


def load_walls(path):
    """Returns (code -> texture digit 1..8, default texture)."""
    with open(path) as f:
        cfg = json.load(f)
    default = int(cfg.get("default", 1))
    mapping = {}
    for fam in cfg.get("families", []):
        tex = int(fam["texture"])
        if not 1 <= tex <= 8:
            raise ValueError("texture %d out of range in family %s" % (tex, fam.get("name")))
        for code in fam["codes"]:
            mapping[int(code)] = tex
    return mapping, default


# ---------------------------------------------------------------- conversion

def convert(plane0, plane1, width, height, difficulty=2, walls=None,
            wall_default=1, name="?"):
    """Convert two planes (lists of width*height codes) to our grid.

    Returns a dict with `rows` (list of strings, cropped), `warnings`,
    `counts`, `notes` and `crop` (x0, y0)."""
    walls = walls or {}
    warnings = []
    notes = {}
    unknown = {}

    def note(key, n=1):
        notes[key] = notes.get(key, 0) + n

    def warn_unknown(plane, code, x, y):
        k = (plane, code)
        if k not in unknown:
            unknown[k] = [0, x, y]
        unknown[k][0] += 1

    actors = actor_table(difficulty)
    every_actor = all_actor_codes()
    grid = [["." for _ in range(width)] for _ in range(height)]
    wolf_door_vertical = {}
    unmapped_walls = set()
    start = None

    # Plane 0: walls, doors, floor.
    for y in range(height):
        for x in range(width):
            t = plane0[y * width + x]
            if 1 <= t <= 63:
                tex = walls.get(t)
                if tex is None:
                    unmapped_walls.add(t)
                    tex = wall_default
                grid[y][x] = str(tex)
            elif 90 <= t <= 101:
                lock = (t - 90) // 2
                ch = {0: "D", 1: "G", 2: "I", 5: "E"}.get(lock)
                if ch is None:
                    warnings.append("door code %d at (%d,%d) has an unused lock, made plain" % (t, x, y))
                    ch = "D"
                grid[y][x] = ch
                wolf_door_vertical[(x, y)] = (t % 2 == 0)
            elif t == 106 or t >= 107:
                pass  # ambush marker, alt elevator, floor areas
            else:
                warn_unknown(0, t, x, y)

    # Plane 1: objects and actors.
    for y in range(height):
        for x in range(width):
            o = plane1[y * width + x]
            if o == 0:
                continue
            ch = None
            if o in PLAYER_START:
                if start is not None:
                    warnings.append("second player start at (%d,%d) ignored" % (x, y))
                    continue
                start = (x, y, PLAYER_START[o])
                continue
            if o in actors:
                ch = actors[o][0]
                note("enemy " + actors[o][1])
            elif o in every_actor:
                note("actors skipped (higher difficulty)")
                continue
            elif o in PICKUPS:
                ch = PICKUPS[o][0]
            elif o in TREASURE:
                note("treasure dropped")
                continue
            elif o == PUSHWALL:
                note("pushwalls left solid")
                continue
            elif o in PATROL_ARROWS or o == DEAD_GUARD:
                continue
            elif 23 <= o <= 74:
                note("decorations dropped" + (" (blocking)" if o in BLOCKING_STATICS else ""))
                continue
            elif o == EXITTILE:
                warnings.append("victory tile (99) at (%d,%d) ignored" % (x, y))
                continue
            elif o in GHOSTS:
                warnings.append("ghost %d at (%d,%d) dropped" % (o, x, y))
                continue
            else:
                warn_unknown(1, o, x, y)
                continue
            cur = grid[y][x]
            if cur != ".":
                warnings.append("object %d at (%d,%d) sits on '%s', dropped" % (o, x, y, cur))
                continue
            grid[y][x] = ch

    for (plane, code), (n, x, y) in sorted(unknown.items()):
        warnings.append("plane %d code %d (%dx, first at %d,%d) made floor" % (plane, code, n, x, y))
    if unmapped_walls:
        warnings.append("wall codes %s not in mapping, texture %d"
                        % (",".join(map(str, sorted(unmapped_walls))), wall_default))

    if start is None:
        raise ValueError("level %s has no player start" % name)

    # Border must be closed.
    for y in range(height):
        for x in range(width):
            if (x in (0, width - 1) or y in (0, height - 1)) and grid[y][x] not in WALL_CHARS:
                warnings.append("border cell (%d,%d) '%s' made wall" % (x, y, grid[y][x]))
                grid[y][x] = str(wall_default)

    # Player start: S at (x,y), its arrow at (x+1,y) must be empty floor.
    sx, sy, facing = start

    def free(x, y):
        return 0 <= x < width and 0 <= y < height and grid[y][x] == "."

    if not (free(sx, sy) and free(sx + 1, sy)):
        best = None
        # Nearest (x,y) such that both (x,y) and (x+1,y) are free floor.
        for y in range(height):
            for x in range(width - 1):
                if free(x, y) and free(x + 1, y):
                    # Nearest first; on a tie prefer staying on the same row.
                    d = ((x - sx) ** 2 + (y - sy) ** 2, y != sy)
                    if best is None or d < best[0]:
                        best = (d, x, y)
        if best is None:
            raise ValueError("no room for the start and its arrow")
        warnings.append("start moved from (%d,%d) to (%d,%d) so its arrow cell is floor"
                        % (sx, sy, best[1], best[2]))
        sx, sy = best[1], best[2]
    grid[sy][sx] = "S"
    grid[sy][sx + 1] = facing

    # Pools.
    def cells_of(chars):
        return [(x, y) for y in range(height) for x in range(width) if grid[y][x] in chars]

    def dist2(p):
        return (p[0] - sx) ** 2 + (p[1] - sy) ** 2

    enemies = cells_of(ENEMY_CHARS)
    if len(enemies) > MAX_ENEMIES:
        excess = len(enemies) - MAX_ENEMIES
        order = sorted(enemies, key=lambda p: (KIND_RANK[grid[p[1]][p[0]]], -dist2(p)))
        dropped = {}
        for x, y in order[:excess]:
            dropped[grid[y][x]] = dropped.get(grid[y][x], 0) + 1
            grid[y][x] = "."
        warnings.append("%d enemies exceed the pool of %d: dropped %s (lowest kind, farthest first)"
                        % (len(enemies), MAX_ENEMIES,
                           ", ".join("%d %s" % (n, k) for k, n in sorted(dropped.items()))))
    doors = cells_of(DOOR_CHARS)
    if len(doors) > MAX_DOORS:
        excess = len(doors) - MAX_DOORS
        # Plain doors farthest from the start become floor first.
        order = sorted(doors, key=lambda p: (grid[p[1]][p[0]] != "D", -dist2(p)))
        for x, y in order[:excess]:
            grid[y][x] = "."
        warnings.append("%d doors exceed the pool of %d: %d farthest (plain first) made floor"
                        % (len(doors), MAX_DOORS, excess))
    pickups = cells_of(PICKUP_CHARS)
    if len(pickups) > MAX_PICKUPS:
        excess = len(pickups) - MAX_PICKUPS
        rank = {"%": 0, "+": 1, "$": 2, "*": 3, "i": 9, "g": 9, "c": 9}
        order = sorted(pickups, key=lambda p: (rank[grid[p[1]][p[0]]], -dist2(p)))
        for x, y in order[:excess]:
            grid[y][x] = "."
        warnings.append("%d pickups exceed the pool of %d: %d dropped"
                        % (len(pickups), MAX_PICKUPS, excess))

    # Door orientation as our parser will derive it (walls left and right ->
    # horizontal panel) versus Wolf3D's own flag.
    for (x, y), wolf_vertical in sorted(wolf_door_vertical.items()):
        if grid[y][x] not in DOOR_CHARS:
            continue
        left = grid[y][x - 1] if x > 0 else "#"
        right = grid[y][x + 1] if x + 1 < width else "#"
        ours_vertical = not (left in WALL_CHARS and right in WALL_CHARS)
        if ours_vertical != wolf_vertical:
            warnings.append("door at (%d,%d): orientation will differ from Wolf3D" % (x, y))

    # Crop to the used area plus a one-cell wall border.
    used = [(x, y) for y in range(height) for x in range(width) if grid[y][x] not in WALL_CHARS]
    x0 = max(0, min(p[0] for p in used) - 1)
    x1 = min(width - 1, max(p[0] for p in used) + 1)
    y0 = max(0, min(p[1] for p in used) - 1)
    y1 = min(height - 1, max(p[1] for p in used) + 1)
    rows = ["".join(grid[y][x0:x1 + 1]) for y in range(y0, y1 + 1)]

    counts = count_chars(rows)
    return {"rows": rows, "warnings": warnings, "counts": counts,
            "notes": notes, "crop": (x0, y0), "start": (sx - x0, sy - y0)}


def count_chars(rows):
    c = {"enemies": 0, "doors": 0, "pickups": 0}
    per = {}
    for r in rows:
        for ch in r:
            if ch in ENEMY_CHARS:
                c["enemies"] += 1
            elif ch in DOOR_CHARS:
                c["doors"] += 1
            elif ch in PICKUP_CHARS:
                c["pickups"] += 1
            else:
                continue
            per[ch] = per.get(ch, 0) + 1
    c["per_char"] = per
    return c


def format_level(result, source, level_index, name, difficulty_name):
    rows = result["rows"]
    c = result["counts"]
    per = " ".join("%s=%d" % (k, v) for k, v in sorted(c["per_char"].items()))
    lines = [
        "# Imported from Wolfenstein 3D by tools/import_wolf.py",
        "# source: %s level %d \"%s\", difficulty %s" % (source, level_index, name, difficulty_name),
        "# size %dx%d (cropped at %d,%d of the 64x64 map)" % (
            len(rows[0]), len(rows), result["crop"][0], result["crop"][1]),
        "# enemies %d, doors %d, pickups %d (%s)" % (c["enemies"], c["doors"], c["pickups"], per),
    ]
    for k, v in sorted(result["notes"].items()):
        lines.append("# note: %s: %d" % (k, v))
    for w in result["warnings"]:
        lines.append("# warning: %s" % w)
    return "\n".join(lines + rows) + "\n"


def import_level(maphead, gamemaps, level, difficulty="medium", walls_path=DEFAULT_WALLS):
    tag, levels = load_levels(maphead, gamemaps)
    found = dict(levels)
    if level not in found:
        raise ValueError("level %d not present (have %s)" % (level, sorted(found)))
    h = found[level]
    p0 = read_plane(gamemaps, h, 0, tag)
    p1 = read_plane(gamemaps, h, 1, tag)
    walls, default = load_walls(walls_path) if walls_path else ({}, 1)
    res = convert(p0, p1, h["width"], h["height"], DIFFICULTIES[difficulty],
                  walls, default, h["name"])
    return h, res


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("maphead")
    ap.add_argument("gamemaps")
    ap.add_argument("--level", type=int, default=0)
    ap.add_argument("--difficulty", choices=sorted(DIFFICULTIES), default="medium")
    ap.add_argument("--walls", default=DEFAULT_WALLS)
    ap.add_argument("--out")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args(argv)
    with open(a.maphead, "rb") as f:
        maphead = f.read()
    with open(a.gamemaps, "rb") as f:
        gamemaps = f.read()

    if a.list:
        tag, levels = load_levels(maphead, gamemaps)
        print("RLEW tag 0x%04X, %d levels" % (tag, len(levels)))
        for i, h in levels:
            try:
                _, res = import_level(maphead, gamemaps, i, a.difficulty, a.walls)
                c = res["counts"]
                print("%3d  %-16s %dx%d -> %dx%d  enemies %d doors %d pickups %d  warnings %d"
                      % (i, h["name"], h["width"], h["height"], len(res["rows"][0]),
                         len(res["rows"]), c["enemies"], c["doors"], c["pickups"],
                         len(res["warnings"])))
            except Exception as e:  # keep listing
                print("%3d  %-16s %dx%d  error: %s" % (i, h["name"], h["width"], h["height"], e))
        return 0

    if not a.out:
        ap.error("--out is required unless --list")
    h, res = import_level(maphead, gamemaps, a.level, a.difficulty, a.walls)
    text = format_level(res, os.path.basename(a.gamemaps), a.level, h["name"], a.difficulty)
    with open(a.out, "w") as f:
        f.write(text)
    c = res["counts"]
    print("%s: %s %dx%d, enemies %d, doors %d, pickups %d, %d warnings"
          % (a.out, h["name"], len(res["rows"][0]), len(res["rows"]),
             c["enemies"], c["doors"], c["pickups"], len(res["warnings"])))
    for w in res["warnings"]:
        print("  warning:", w, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
