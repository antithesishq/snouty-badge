#!/usr/bin/env python3
"""Run render_frame from the bench ELF (build/bench.elf) under unicorn and
count instructions and modelled Cortex-M33 cycles, per frame and per pixel.

usage: .venv/bin/python bench.py [--elf build/bench.elf] [--frames 0 300]
                                 [--mode none|bayer] [--out out/]

Per frame F it writes to --out:
  emu_FFFF.png      the rendered frame (compare with tools/check_render.mjs)
  pixels_FFFF.json  per-pixel insn/cycle cost (delta between consecutive
                    framebuffer stores; x*128+y order)
  hist_FFFF.json    mnemonic histogram (counts and modelled cycles)
  addr_FFFF.json    per-instruction execution counts (for disasm.py)
  result_emu_FFFF.json  the summary numbers
"""
import argparse
import json
import os
import struct

from unicorn import UC_HOOK_BLOCK, UC_HOOK_MEM_WRITE
from unicorn.arm_const import UC_ARM_REG_LR, UC_ARM_REG_PC, UC_ARM_REG_R0, UC_ARM_REG_SP

import model as M

HERE = os.path.dirname(os.path.abspath(__file__))
STACK_TOP = M.RAM_BASE + M.RAM_SIZE
STOP = 0x20070000  # LR sentinel inside RAM, never code


def run(elf_path, frames, out, mode='none', quiet=False):
    mu = M.make_uc()
    elf, syms = M.load_elf(mu, elf_path)
    fn = M.need(syms, 'render_frame', elf_path) & ~1
    fb = M.need(syms, 'fb_storage', elf_path)
    mu.mem_write(M.need(syms, 'bench_mode', elf_path), struct.pack('<I', 1 if mode == 'none' else 0))
    cs = M.make_cs()
    blocks = {}
    results = []
    for frame in frames:
        st = dict(insn=0, cyc=0, taken=0, prev_end=None, cur=None)
        hist, hist_cyc, bcount, marks = {}, {}, {}, []

        def hook_block(uc, addr, size, _):
            b = blocks.get((addr, size))
            if b is None:
                b = blocks[(addr, size)] = M.decode_block(cs, bytes(uc.mem_read(addr, size)), addr)
            if st['prev_end'] is not None and addr != st['prev_end']:
                st['cyc'] += M.TAKEN_EXTRA
                st['taken'] += 1
            st['cur'] = (b, st['insn'], st['cyc'])
            bcount[(addr, size)] = bcount.get((addr, size), 0) + 1
            names, cyc, pref, _idx = b
            st['insn'] += len(names)
            st['cyc'] += pref[-1] + cyc[-1]
            for n, c in zip(names, cyc):
                hist[n] = hist.get(n, 0) + 1
                hist_cyc[n] = hist_cyc.get(n, 0) + c
            st['prev_end'] = addr + size

        def hook_write(uc, access, addr, size, value, _):
            # Cost up to and including the storing instruction.
            pc = uc.reg_read(UC_ARM_REG_PC)
            b, i0, c0 = st['cur']
            k = b[3].get(pc & ~1, len(b[0]) - 1)
            marks.append(((addr - fb) // 2, i0 + k + 1, c0 + b[2][k] + b[1][k]))

        h1 = mu.hook_add(UC_HOOK_BLOCK, hook_block)
        h2 = mu.hook_add(UC_HOOK_MEM_WRITE, hook_write, begin=fb, end=fb + M.N_PIXELS * 2 - 1)
        mu.reg_write(UC_ARM_REG_SP, STACK_TOP)
        mu.reg_write(UC_ARM_REG_R0, frame)
        mu.reg_write(UC_ARM_REG_LR, STOP | 1)
        mu.emu_start(fn | 1, STOP)
        mu.hook_del(h1)
        mu.hook_del(h2)

        raw = mu.mem_read(fb, M.N_PIXELS * 2)
        png = os.path.join(out, f'emu_{frame:04d}.png')
        M.write_png(png, M.rgb565_rows(lambda k: raw[2 * k] | (raw[2 * k + 1] << 8)))

        if len(marks) != M.N_PIXELS:
            raise SystemExit(f"emu: expected {M.N_PIXELS} framebuffer stores, saw {len(marks)} "
                             "(render_frame no longer stores each pixel once; per-pixel costs need rework)")
        pix = [None] * M.N_PIXELS
        pi = pc = 0
        for off, i, c in marks:
            pix[off] = (i - pi, c - pc)
            pi, pc = i, c
        tail = (st['insn'] - pi, st['cyc'] - pc)
        with open(os.path.join(out, f'pixels_{frame:04d}.json'), 'w') as f:
            json.dump(dict(frame=frame, insn=[p[0] for p in pix], cyc=[p[1] for p in pix], tail=tail), f)
        with open(os.path.join(out, f'hist_{frame:04d}.json'), 'w') as f:
            json.dump(dict(hist=hist, hist_cyc=hist_cyc), f, indent=0)
        ac = M.addr_counts(cs, mu, bcount)
        with open(os.path.join(out, f'addr_{frame:04d}.json'), 'w') as f:
            json.dump({hex(k): v for k, v in sorted(ac.items())}, f)
        r = M.result('emu', frame, st['insn'], st['cyc'], st['taken'], hist)
        r['png'] = png
        with open(os.path.join(out, f'result_emu_{frame:04d}.json'), 'w') as f:
            json.dump(r, f)
        results.append(r)
        if not quiet:
            print(f"bench frame {frame}: {r['insn']:,} insns, {r['cyc']:,} modelled cycles "
                  f"({r['cyc_px']:.1f}/px), {r['ms']:.2f} ms at 150 MHz")
    return results


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--elf', default=os.path.join(HERE, 'build', 'bench.elf'))
    ap.add_argument('--frames', type=int, nargs='+', default=[0, 300])
    ap.add_argument('--mode', choices=['none', 'bayer'], default='none')
    ap.add_argument('--out', default=os.path.join(HERE, 'out'))
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    run(a.elf, a.frames, a.out, a.mode)


if __name__ == '__main__':
    main()
