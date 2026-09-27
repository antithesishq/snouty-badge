#!/usr/bin/env python3
"""Synthetic badge-calibrate bench.json (and optional "hardware" captures)
following calibrate/PLAN.md, so fit.py can be tested without the cart.

    make_calibrate_fixture.py OUT_DIR [--perturb]

Writes OUT_DIR/bench.json (20 hot entries kernels.k<id>_<name> with
per-call mnemonics, taken and class_cyc; 5 passes of 21 CAL trace lines,
priced with the default table), OUT_DIR/hardware.txt (`[CART] CAL ...`
lines, an extra incomplete pass at the end) and OUT_DIR/manual.txt
(hand-typed k= idle= busy= per-op lines). With --perturb the "hardware"
runs the vdiv kernels 1.3x slower overall and the busy run of every memory
kernel charges 1.5x its memory-class cycles; otherwise hardware = model.
"""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
from badge_bench.classes import DEFAULT_COSTS, MEMORY_CLASSES, classify  # noqa: E402

PASSES, CALL = 5, 7          # passes in the emulator run; cycles per run outside the function
# id, name, ops per iteration, per-iteration mnemonics (taken = loop back edge), extra taken/iter
KERNELS = [
    (0, 'empty', 1, {'subs': 1, 'b<cc>': 1}, 0),
    (1, 'vmul_indep', 16, {'vmul': 16, 'subs': 1, 'b<cc>': 1}, 0),
    (2, 'vmul_dep', 16, {'vmul': 16, 'subs': 1, 'b<cc>': 1}, 0),
    (3, 'vadd_vmul_mix', 16, {'vmul': 8, 'vadd': 8, 'subs': 1, 'b<cc>': 1}, 0),
    (4, 'vdiv', 16, {'vdiv': 16, 'subs': 1, 'b<cc>': 1}, 0),
    (5, 'vsqrt', 16, {'vsqrt': 16, 'vadd': 16, 'subs': 1, 'b<cc>': 1}, 0),
    (6, 'vdiv_indep', 16, {'vdiv': 16, 'subs': 1, 'b<cc>': 1}, 0),
    (7, 'ldr_seq', 16, {'ldr': 16, 'add': 16, 'adds': 1, 'cmp': 1, 'b<cc>': 1}, 0),
    (8, 'ldr_stride', 16, {'ldr': 16, 'add': 16, 'adds': 1, 'cmp': 1, 'b<cc>': 1}, 0),
    (9, 'str_seq', 16, {'str': 16, 'adds': 1, 'cmp': 1, 'b<cc>': 1}, 0),
    (10, 'vldr_vstr', 16, {'vldr': 8, 'vstr': 8, 'adds': 2, 'cmp': 1, 'b<cc>': 1}, 0),
    (11, 'ldrh_strh_fb', 16, {'ldrh': 8, 'strh': 8, 'adds': 2, 'cmp': 1, 'b<cc>': 1}, 0),
    (12, 'branch_taken', 1, {'add': 1, 'subs': 1, 'b<cc>': 1}, 0),
    (13, 'branch_pattern', 1, {'ldr': 1, 'tst': 1, 'b<cc>': 2, 'add': 1, 'subs': 1}, 0.5),
    (14, 'udiv', 16, {'udiv': 16, 'subs': 1, 'b<cc>': 1}, 0),
    (15, 'nop_fetch', 16, {'nop': 16, 'subs': 1, 'b<cc>': 1}, 0),
    (16, 'nop_fetch_w', 16, {'nop': 16, 'subs': 1, 'b<cc>': 1}, 0),
    (17, 'vcmp_vmrs', 16, {'vcmp': 4, 'vmrs': 4, 'it': 4, 'vadd': 4, 'subs': 1, 'b<cc>': 1}, 0),
    (18, 'table_lerp', 8, {'vcvt': 1, 'and': 1, 'ldr': 2, 'vsub': 1, 'vmla': 1, 'vmov': 2,
                           'add': 1, 'subs': 1, 'b<cc>': 1}, 0),
    (19, 'mixed_tracer', 64, {'vmul': 20, 'vadd': 16, 'vsub': 4, 'vmla': 8, 'vdiv': 1, 'vsqrt': 1,
                              'vldr': 6, 'vcmp': 2, 'vmrs': 2, 'ldrd': 1, 'strd': 1, 'sdiv': 1,
                              'vcvt': 1, 'subs': 1, 'b<cc>': 1}, 0),
]
# Per call: push {r4-r7, lr} / pop {r4-r7, pc} (6 cycles each), 3 alu, 2 volatile
# loads and a sink store.
PROLOGUE = {'push': 1, 'pop': 1, 'movs': 2, 'mov': 1, 'ldr': 2, 'str': 1}
PUSH_POP_CYC = 6


def per_call(ops_iter, body, extra_taken, n):
    mn = {m: c * n for m, c in body.items()}
    for m, c in PROLOGUE.items():
        mn[m] = mn.get(m, 0) + c
    taken = round(n * (1 + extra_taken)) + 1      # back edges + the entry from the caller
    cls = {}
    for m, c in mn.items():
        k = classify(m)
        cls[k] = cls.get(k, 0) + c * (PUSH_POP_CYC if k == 'multi' else DEFAULT_COSTS[k])
    return mn, taken, cls


def main():
    out = sys.argv[1]
    perturb = '--perturb' in sys.argv[2:]
    os.makedirs(out, exist_ok=True)
    hot, rows = [], []
    for k, name, opi, body, xt in KERNELS:
        it_cyc = sum(c * DEFAULT_COSTS[classify(m)] for m, c in body.items()) + 1 + xt
        n = int(max(1, 400_000 // it_cyc))
        mn, taken, cls = per_call(opi, body, xt, n)
        fn = sum(cls.values()) + taken
        run = round(fn + CALL)
        mem = sum(v for c, v in cls.items() if c in MEMORY_CLASSES)
        entries = 3 * PASSES
        hot.append(dict(name=f"kernels.k{k}_{name}", cyc=fn * entries, insn=sum(mn.values()) * entries,
                        entries=entries, addr=0x20040000 + 0x100 * k, cyc_per_frame=fn * entries / 100,
                        taken=taken * entries,
                        mnemonics={m: c * entries for m, c in mn.items()},
                        class_cyc={c: v * entries for c, v in cls.items()}))
        hw_idle = run * (1.3 if 'vdiv' in name and perturb else 1.0)
        hw_busy = hw_idle + (0.5 * mem if perturb and 7 <= k <= 11 else 0)
        rows.append((k, n, n * opi, run, round(hw_idle), round(hw_busy)))
    hot.append(dict(name='main.update', cyc=12345, insn=9000, entries=100, addr=0x20036000,
                    cyc_per_frame=123.45, taken=100, mnemonics={'bl': 100}, class_cyc={'alu': 12245}))
    hot.sort(key=lambda h: -h['cyc'])

    def fnv(vals):
        """The cart's checksum (harness.zig checksum_of, fit.checksum)."""
        h = 0x811c9dc5
        for v in vals:
            for byte in int(v).to_bytes(4, 'little'):
                h = ((h ^ byte) * 0x01000193) & 0xffffffff
        return h

    def lines(which, pfx, passes, partial):
        L = []
        for p in range(1, passes + 1):
            hashed = []
            for k, n, ops, run, hi, hb in rows:
                i, b = (run, run) if which == 'emu' else (hi, hb)
                sink = 0x1234abcd ^ k
                L.append(f"{pfx(p)}CAL k={k} n={n} ops={ops} idle_min={i} idle_med={i} "
                         f"busy_min={b} busy_med={b} sink={sink:08x}")
                hashed += [k, n, ops, i, i, b, b, sink]
            L.append(f"{pfx(p)}CAL done pass={p} sum={fnv(hashed):08x}")
        if partial:
            k, n, ops, run, hi, hb = rows[0]
            L.append(f"{pfx(passes + 1)}CAL k={k} n={n} ops={ops} idle_min=1 idle_med=1 busy_min=1 "
                     "busy_med=1 sink=00000000")
            L.append(f"{pfx(passes + 1)}CAL k=1 n=3 ops=48 idle_mi")     # cut off mid-line
        return L

    traces = [dict(frame=20 * p - 1, text=t) for p in range(1, PASSES + 1)
              for t in lines('emu', lambda _p: '', 1, False)]
    j = dict(meta=dict(tool='fixture', elf='badge-calibrate.elf', sha256='f' * 64, frames=100),
             summary=None, frames=[], hot=hot, traces=traces)
    with open(os.path.join(out, 'bench.json'), 'w') as fh:
        json.dump(j, fh, indent=1)
    with open(os.path.join(out, 'hardware.txt'), 'w') as fh:
        fh.write('boot banner\n' + '\n'.join(lines('hw', lambda _p: '[CART] ', 3, True)) + '\n')
    with open(os.path.join(out, 'manual.txt'), 'w') as fh:
        fh.write('# read off the screen\n')
        for k, n, ops, run, hi, hb in rows:
            fh.write(f"k={k} idle={hi / ops:.3f} busy={hb / ops:.3f}\n")
    print(f"wrote {out}/bench.json, hardware.txt, manual.txt" + (' (perturbed)' if perturb else ''))


if __name__ == '__main__':
    main()
