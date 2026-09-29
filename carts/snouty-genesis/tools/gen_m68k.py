#!/usr/bin/env python3
"""Writes core/m68k_tables.zig: the 68000 decode for core/m68k.zig.

Run from anywhere: `python3 carts/snouty-genesis/tools/gen_m68k.py`.

One Python function, `decode(op)`, names the handler of every 16-bit
opcode (an illegal EA combination decodes to `illegal`, line A/F to their
exceptions). The output has two shapes of the same map, and m68k.zig picks
one with `decode_variant` (PLAN.md M1 Track A asks for both, measured):

- `Op`: the handler enum, in first-use order (<= 256 handlers, u8).
- `decode`: 64 K x u8, one byte per opcode (one load; 64 KB of flash).
- Two-level: `l1[op >> 6]` (1 K x u8) names a group of the 64 opcodes that
  share bits 15-6; a group is `{ fallback, first, count }` into `entries`,
  each `{ mask, op }` where bit `op & 63` of `mask` set means that handler.
  The first matching entry wins, else the fallback (a few KB).

No comptime work in Zig (Adrian's Mac OOMs on heavy comptime): everything
here is literal data.
"""
import os
import sys

# EA index of (mode, reg): 0 Dn, 1 An, 2 (An), 3 (An)+, 4 -(An), 5 d16(An),
# 6 d8(An,Xn), 7 abs.W, 8 abs.L, 9 d16(PC), 10 d8(PC,Xn), 11 #imm.
def ea_index(mode, reg):
    if mode < 7:
        return mode
    return 7 + reg if reg <= 4 else None


ALL = set(range(12))
DATA = ALL - {1}
MEM = ALL - {0, 1}
ALT = set(range(9))
DATA_ALT = ALT - {1}
MEM_ALT = ALT - {0, 1}
CTRL = {2, 5, 6, 7, 8, 9, 10}
CTRL_ALT = {2, 5, 6, 7, 8}

SZ = {0: "b", 1: "w", 2: "l"}
SHIFT = ["as", "ls", "rox", "ro"]


def decode(op):
    line = op >> 12
    mode = (op >> 3) & 7
    reg = op & 7
    ea = ea_index(mode, reg)
    ss = (op >> 6) & 3
    rx = (op >> 9) & 7
    bit8 = (op >> 8) & 1

    def ok(cls):
        return ea is not None and ea in cls

    if line == 0:
        if bit8:
            if mode == 1:
                return ["movep_mr_w", "movep_mr_l", "movep_rm_w", "movep_rm_l"][ss]
            kind = ["btst", "bchg", "bclr", "bset"][ss]
            if kind == "btst":
                return "btst_reg" if ok(DATA) else "illegal"
            return kind + "_reg" if ok(DATA_ALT) else "illegal"
        if rx == 4:  # static bit ops
            kind = ["btst", "bchg", "bclr", "bset"][ss]
            if kind == "btst":
                return "btst_imm" if ok(DATA - {11}) else "illegal"
            return kind + "_imm" if ok(DATA_ALT) else "illegal"
        name = {0: "ori", 1: "andi", 2: "subi", 3: "addi", 5: "eori", 6: "cmpi"}.get(rx)
        if name is None or ss == 3:
            return "illegal"
        if name in ("ori", "andi", "eori") and mode == 7 and reg == 4:
            if ss == 0:
                return name + "_ccr"
            if ss == 1:
                return name + "_sr"
            return "illegal"
        return f"{name}_{SZ[ss]}" if ok(DATA_ALT) else "illegal"

    if line in (1, 2, 3):
        size = {1: "b", 3: "w", 2: "l"}[line]
        dmode = (op >> 6) & 7
        dea = ea_index(dmode, rx)
        src_ok = ea is not None and (ea != 1 or size != "b")
        if not src_ok or dea is None:
            return "illegal"
        if dea == 1:
            return "illegal" if size == "b" else f"movea_{size}"
        if dea not in DATA_ALT:
            return "illegal"
        if dea == 0:
            return f"move_{size}_dn"
        return f"move_{size}"

    if line == 4:
        if bit8:
            if ss == 2:
                return "chk" if ok(DATA) else "illegal"
            if ss == 3:
                return "lea" if ok(CTRL) else "illegal"
            return "illegal"
        sub = (op >> 8) & 0xF
        if sub in (0, 2, 4, 6):
            if ss == 3:
                if sub == 0:
                    return "move_from_sr" if ok(DATA_ALT) else "illegal"
                if sub == 4:
                    return "move_to_ccr" if ok(DATA) else "illegal"
                if sub == 6:
                    return "move_to_sr" if ok(DATA) else "illegal"
                return "illegal"
            name = {0: "negx", 2: "clr", 4: "neg", 6: "not"}[sub]
            return f"{name}_{SZ[ss]}" if ok(DATA_ALT) else "illegal"
        if sub == 8:
            if ss == 0:
                return "nbcd" if ok(DATA_ALT) else "illegal"
            if ss == 1:
                if mode == 0:
                    return "swap"
                return "pea" if ok(CTRL) else "illegal"
            if mode == 0:
                return "ext_w" if ss == 2 else "ext_l"
            if ok(CTRL_ALT) or ea == 4:
                return "movem_rm_w" if ss == 2 else "movem_rm_l"
            return "illegal"
        if sub == 0xA:
            if op == 0x4AFC:
                return "illegal"
            if ss == 3:
                return "tas" if ok(DATA_ALT) else "illegal"
            return f"tst_{SZ[ss]}" if ok(DATA_ALT) else "illegal"
        if sub == 0xC:
            if ss >= 2 and (ok(CTRL) or ea == 3):
                return "movem_mr_w" if ss == 2 else "movem_mr_l"
            return "illegal"
        if sub == 0xE:
            if ss == 1:
                low = op & 0x3F
                if low < 0x10:
                    return "trap"
                if low < 0x18:
                    return "link"
                if low < 0x20:
                    return "unlk"
                if low < 0x28:
                    return "move_to_usp"
                if low < 0x30:
                    return "move_from_usp"
                return {0x30: "reset", 0x31: "nop", 0x32: "stop", 0x33: "rte",
                        0x35: "rts", 0x36: "trapv", 0x37: "rtr"}.get(low, "illegal")
            if ss == 2:
                return "jsr" if ok(CTRL) else "illegal"
            if ss == 3:
                return "jmp" if ok(CTRL) else "illegal"
            return "illegal"
        return "illegal"

    if line == 5:
        if ss == 3:
            if mode == 1:
                return "dbcc"
            return "scc" if ok(DATA_ALT) else "illegal"
        name = "subq" if bit8 else "addq"
        if ea == 1:
            return "illegal" if ss == 0 else f"{name}_a"
        return f"{name}_{SZ[ss]}" if ok(DATA_ALT) else "illegal"

    if line == 6:
        cc = (op >> 8) & 0xF
        return "bra" if cc == 0 else "bsr" if cc == 1 else "bcc"

    if line == 7:
        return "illegal" if bit8 else "moveq"

    if line in (8, 0xC):
        base = "or" if line == 8 else "and"
        if ss == 3:
            name = ("divu" if line == 8 else "mulu") if not bit8 else ("divs" if line == 8 else "muls")
            return name if ok(DATA) else "illegal"
        if not bit8:
            return f"{base}_ea_dn_{SZ[ss]}" if ok(DATA) else "illegal"
        if mode in (0, 1):
            if line == 8:
                if ss == 0:
                    return "sbcd_r" if mode == 0 else "sbcd_m"
                return "illegal"
            if ss == 0:
                return "abcd_r" if mode == 0 else "abcd_m"
            if ss == 1:
                return "exg_dd" if mode == 0 else "exg_aa"
            return "exg_da" if mode == 1 else "illegal"
        return f"{base}_dn_ea_{SZ[ss]}" if ok(MEM_ALT) else "illegal"

    if line in (9, 0xD):
        base = "sub" if line == 9 else "add"
        if ss == 3:
            return (f"{base}a_l" if bit8 else f"{base}a_w") if ok(ALL) else "illegal"
        if not bit8:
            if ea is None or (ea == 1 and ss == 0):
                return "illegal"
            return f"{base}_ea_dn_{SZ[ss]}"
        if mode in (0, 1):
            return f"{base}x_{'m' if mode else 'r'}_{SZ[ss]}"
        return f"{base}_dn_ea_{SZ[ss]}" if ok(MEM_ALT) else "illegal"

    if line == 0xB:
        if ss == 3:
            return ("cmpa_l" if bit8 else "cmpa_w") if ok(ALL) else "illegal"
        if not bit8:
            if ea is None or (ea == 1 and ss == 0):
                return "illegal"
            return f"cmp_{SZ[ss]}"
        if mode == 1:
            return f"cmpm_{SZ[ss]}"
        return f"eor_{SZ[ss]}" if ok(DATA_ALT) else "illegal"

    if line == 0xE:
        d = "l" if bit8 else "r"
        if ss == 3:
            if (op >> 11) & 1:
                return "illegal"
            kind = SHIFT[(op >> 9) & 3]
            return f"{kind}{d}_mem" if ok(MEM_ALT) else "illegal"
        kind = SHIFT[(op >> 3) & 3]
        return f"{kind}{d}_{SZ[ss]}"

    return "linea" if line == 0xA else "linef"


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(here, "..", "core", "m68k_tables.zig")
    names = ["illegal"]
    index = {"illegal": 0}
    table = bytearray(65536)
    for op in range(65536):
        n = decode(op)
        if n not in index:
            index[n] = len(names)
            names.append(n)
        table[op] = index[n]
    if len(names) > 256:
        sys.exit(f"{len(names)} handlers: more than a u8")

    # Two-level: groups of 64 opcodes sharing bits 15-6.
    groups = []
    group_ix = {}
    entries = []
    l1 = bytearray(1024)
    for g in range(1024):
        ops = [table[(g << 6) | lo] for lo in range(64)]
        # Fallback: the most common handler; entries for the rest.
        counts = {}
        for h in ops:
            counts[h] = counts.get(h, 0) + 1
        fallback = max(counts, key=lambda h: (counts[h], h == 0))
        ents = []
        for h in sorted(counts):
            if h == fallback:
                continue
            mask = 0
            for lo in range(64):
                if ops[lo] == h:
                    mask |= 1 << lo
            ents.append((mask, h))
        key = (fallback, tuple(ents))
        if key not in group_ix:
            group_ix[key] = len(groups)
            groups.append((fallback, len(entries), len(ents)))
            entries.extend(ents)
        l1[g] = group_ix[key]
    if len(groups) > 256:
        sys.exit(f"{len(groups)} groups: more than a u8")

    def zstr(data):
        return "".join(f"\\x{b:02x}" for b in data)

    lines = []
    w = lines.append
    w("//! Generated by tools/gen_m68k.py; do not edit. The 68000 decode:")
    w("//! `Op` names the handler, `decode[op]` is its index (64 K x u8), and")
    w("//! `l1`/`groups`/`entries` are the same map in two levels (see the")
    w("//! generator's docstring). Literal data only (no comptime building).")
    w("")
    w(f"/// {len(names)} handlers, in first-use order.")
    w("pub const Op = enum(u8) {")
    for n in names:
        w(f"    {n},")
    w("};")
    w("")
    w("/// Handler index of every opcode.")
    # One string literal (a ++ chain costs the compiler quadratic memory).
    w(f"pub const decode: *const [65536]u8 = \"{zstr(table)}\";")
    w("")
    w("/// Group of `op >> 6`.")
    w(f"pub const l1: *const [1024]u8 = \"{zstr(l1)}\";")
    w("")
    w("pub const Group = struct { fallback: u8, count: u8, first: u16 };")
    w("pub const Entry = struct { mask: u64, op: u8 };")
    w("")
    w(f"pub const groups = [{len(groups)}]Group{{")
    for fb, first, cnt in groups:
        w(f"    .{{ .fallback = {fb}, .count = {cnt}, .first = {first} }},")
    w("};")
    w("")
    w(f"pub const entries = [{len(entries)}]Entry{{")
    for mask, h in entries:
        w(f"    .{{ .mask = 0x{mask:016x}, .op = {h} }},")
    w("};")
    w("")
    with open(out, "w") as f:
        f.write("\n".join(lines))
    print(f"{out}: {len(names)} handlers, {len(groups)} groups, {len(entries)} entries")


if __name__ == "__main__":
    main()
