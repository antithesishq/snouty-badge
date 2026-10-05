#!/usr/bin/env python3
"""Generate core/ports_table.zig: the multiplayer peripheral each well-known
game gets at power-on (docs/MULTIPLAYER.md, core/ports.zig `detect`).

Run from anywhere: python3 carts/snouty-genesis/tools/gen_ports_table.py

Sources (no emulator code): the ROM header dumps (serial at 0x180, checksum
at 0x18E) on each game's Sega Retro "Technical information" page, the
peripheral support from Sega Retro's "Team Player-compatible games" and "4
Way Play-compatible games" categories, the J-Cart list from Sega Retro's
and Wikipedia's J-Cart pages. `verified` = checked with a real dump here.

Key: an FNV-1a 32 hash of the 14 serial bytes (0x180-0x18D), or where the
serial is a placeholder several games share of the serial and the header
checksum (0x180-0x18F); its low three bits hold the kind. The Zig side
hashes the same bytes at power-on (`ports.detect`).
"""
import os

TAP1, EA, JCART = "tap1", "ea4way", "jcart"

# (serial, checksum or None, kind, title, verified)
# Games in both Sega Retro categories get the Team Player unless EA made
# them (EA's own adapter is what its games were built around).
ROWS = [
    # --- Sega Team Player ---
    ("GM MK-1573-00 ", None, TAP1, "Mega Bomberman", True),
    ("GM T-48123 -00", None, TAP1, "Gauntlet IV", False),
    ("GM T-081326 00", None, TAP1, "NBA Jam", False),
    ("GM T-081326 01", None, TAP1, "NBA Jam (rev 1)", False),
    ("GM T-81033  00", None, TAP1, "NBA Jam (JP)", False),
    ("GM 00004801-00", None, TAP1, "Columns III (JP)", False),
    ("GM T-23056 -00", None, TAP1, "Columns III", False),
    ("GM T-81496 -00", None, TAP1, "Dragon: The Bruce Lee Story", False),
    ("GM T-70286 -00", None, TAP1, "Dragon: The Bruce Lee Story (EU)", False),
    ("GM T-177016-00", None, TAP1, "Street Racer", False),
    ("GM T-95146-00 ", None, TAP1, "Tiny Toon Adventures: ACME All-Stars", False),
    ("GM T-125016-00", None, TAP1, "The Lost Vikings", False),
    ("GM T-.oOOo.   ", 0xB9E0, TAP1, "The Lost Vikings (EU)", False),
    ("GM 00004107-00", None, TAP1, "Party Quiz Mega Q", False),
    ("GM G-4118  -00", None, TAP1, "Puzzle & Action: Tant-R", False),
    ("GM G-4128  -00", None, TAP1, "Puzzle & Action: Ichidant-R", False),
    ("GM MK-1224 -00", None, TAP1, "Wimbledon Championship Tennis", False),
    ("GM MK-1224 -50", None, TAP1, "Wimbledon Championship Tennis (EU)", False),
    ("GM T-119066-00", None, TAP1, "Hoops Shut Up and Jam!", False),
    ("GM T-119186-00", None, TAP1, "Barkley Shut Up and Jam 2", False),
    ("GM MK-1233 -00", None, TAP1, "World Championship Soccer II", False),
    ("GM G-004122-00", None, TAP1, "Yuu Yuu Hakusho: Makyou Toitsusen", False),
    ("GM G-4133-00  ", None, TAP1, "Pepenga Pengo", False),
    ("GM MK-1221 -00", None, TAP1, "NBA Action '94", False),
    ("GM MK-1236 -00", None, TAP1, "NBA Action '95", False),
    ("GM MK-1240 -00", None, TAP1, "Prime Time NFL Football", False),
    ("GM MK-1227 -00", None, TAP1, "College Football's National Championship", False),
    # --- EA 4 Way Play ---
    ("GM T-106253-00", None, EA, "General Chaos", False),
    ("GM T-50626 -00", None, EA, "General Chaos (EU)", False),
    ("GM T-      -00", 0xC5F1, EA, "FIFA International Soccer", False),
    ("GM T-50706 -00", None, EA, "FIFA International Soccer", False),
    ("GM T-50916 -00", None, EA, "FIFA Soccer 95", False),
    ("GM T-50916 -01", None, EA, "FIFA Soccer 95 (rev 1)", False),
    ("GM T-172086-00", None, EA, "FIFA Soccer 96", False),
    ("GM T-172156-01", None, EA, "FIFA 97: Gold Edition", False),
    ("GM T-172206-00", None, EA, "FIFA Road to World Cup 98", False),
    ("GM T-50656 -00", None, EA, "NHL Hockey '94", False),
    ("GM T-50856 -00", None, EA, "NHL 95", False),
    ("GM T-172036-00", None, EA, "NHL 96", False),
    ("GM T-172146-03", None, EA, "NHL 97", False),
    ("GM T-172176-00", None, EA, "NHL 98", False),
    ("GM T-106263-00", None, EA, "Madden NFL '94", False),
    ("GM T-50676 -00", None, EA, "Madden NFL '94", False),
    ("GM T-50926 -00", None, EA, "Madden NFL '95", False),
    ("GM T-172076-00", None, EA, "Madden NFL 96", False),
    ("GM T-172136-00", None, EA, "Madden NFL 97", False),
    ("GM T-172196-00", None, EA, "Madden NFL 98", False),
    ("GM T-50936 -00", None, EA, "NBA Live 95", False),
    ("GM T-172056-00", None, EA, "NBA Live 96", False),
    ("GM T-172166-00", None, EA, "NBA Live 97", False),
    ("GM T-172186-00", None, EA, "NBA Live 98", False),
    ("GM T-      -00", 0x5364, EA, "NBA Showdown '94", False),
    ("GM T-50756 -00", None, EA, "NBA Showdown '94", False),
    ("GM T-50606 -00", None, EA, "Bill Walsh College Football", False),
    ("GM T-50826 -00", None, EA, "Bill Walsh College Football '95", False),
    ("GM T-50956 -00", None, EA, "Rugby World Cup 1995", False),
    ("GM T-50766 -00", None, EA, "Mutant League Hockey", False),
    # --- Codemasters J-Cart ---
    ("GM T-120096-50", None, JCART, "Micro Machines 2: Turbo Tournament", False),
    ("GM 00000000-00", 0x168B, JCART, "Micro Machines Military", False),
    ("GM T-123456-00", 0x1EAE, JCART, "Pete Sampras Tennis '96", False),
    ("GM XXXXXXXX-XX", 0xDF39, JCART, "Super Skidmarks", False),
]


def fnv1a(b: bytes) -> int:
    h = 0x811C9DC5
    for c in b:
        h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF
    return h


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(here, "..", "core", "ports_table.zig")
    seen = set()
    lines = [
        "//! Generated by tools/gen_ports_table.py: do not edit. The peripheral",
        "//! each well-known game gets at power-on (core/ports.zig `detect`,",
        "//! docs/MULTIPLAYER.md). A row is an FNV-1a 32 hash with its low",
        "//! three bits replaced by the `ports.Kind`: the hash of the header",
        "//! serial (0x180-0x18D), or for a placeholder serial that several",
        "//! games share, of the serial and the header checksum (0x180-0x18F).",
        "//! Literal data, no comptime work (CLAUDE.md).",
        "",
        "pub const count = %d;" % len(ROWS),
        "pub const kind_mask: u32 = 7;",
        "",
        "pub const rows = [count]u32{",
    ]
    codes = {TAP1: 2, EA: 5, JCART: 6}
    keys = set()
    for s, c, k, t, v in ROWS:
        assert len(s) == 14, s
        b = s.encode("latin1")
        if c is not None:
            b += bytes([c >> 8, c & 0xFF])
        key = fnv1a(b) & ~7
        assert key not in keys, s
        keys.add(key)
        lines.append("    0x%08X, // %s%s  %s%s" % (key | codes[k], s, " %04X" % c if c is not None else "", t, "  (verified)" if v else ""))
    lines += ["};", ""]
    with open(out, "w") as f:
        f.write("\n".join(lines))
    print("wrote", os.path.normpath(out), len(ROWS), "rows")


if __name__ == "__main__":
    main()
