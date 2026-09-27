#!/usr/bin/env python3
"""Run the real cart ELF (<repository root>/zig-out/firmware/snouty-reflections.elf) under
unicorn from its _start, faking just enough of the badge OS: the SIO FIFO
(time sync and FRAMEBUFFER_DONE replies), TIMER0 and DWT_CYCCNT. Each window
between two present() messages is one full update() (input, dither, render,
present). Before each window main.frame and dither.mode are poked, so the
frame list can be arbitrary. The first window (start-up) is discarded.

usage: .venv/bin/python real.py [--elf ../../../../zig-out/firmware/snouty-reflections.elf]
                                [--frames 0 300] [--mode none|bayer] [--out out/]

Writes real_FFFF.png, real_addr_FFFF.json, real_hist_FFFF.json and
result_real_FFFF.json per frame.
"""
import argparse
import json
import os
import struct

from unicorn import UC_HOOK_BLOCK, UC_HOOK_MEM_WRITE
from unicorn.arm_const import UC_ARM_REG_LR, UC_ARM_REG_SP

import model as M

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))  # this cart, carts/snouty-reflections
MONO = os.path.dirname(os.path.dirname(REPO))  # repository root, where zig build writes zig-out/
# The OS's two framebuffers (sycl-badge src/os/cart/platform_cart_ram.zig), 0xA000 each.
FB0, FB1, FB_SIZE = 0x20020000, 0x2002A000, 0xA000
SIO, TIMER0, DWT = 0xD0000000, 0x400b0000, 0xE0001000
# Cart <-> OS FIFO words (sycl-badge src/os/cart/platform_cart_ram.zig).
SYNC_TIME_REQ_CLR, SYNC_TIME_ACK_CLR = 0x2a000001, 0x2a000002
SYNC_TIME_REQ_TIME = 0x2a000003  # answered with two zero words (time 0)
FRAMEBUFFER_DONE = 0x25000002


def run(elf_path, frames, out, mode='none', quiet=False):
    mu = M.make_uc()
    elf, syms = M.load_elf(mu, elf_path)
    frame_addr = M.need(syms, 'main.frame', elf_path)
    mu.mem_write(M.need(syms, 'dither.mode', elf_path), struct.pack('<I', 1 if mode == 'none' else 0))
    start = M.need(syms, '_start', elf_path)
    cs = M.make_cs()
    st = dict(insn=0, cyc=0, taken=0, queue=[], presents=0, prev_end=None, cur_frame=None)
    plan = list(frames)
    windows = []

    def begin_window():
        st.update(win_insn=st['insn'], win_cyc=st['cyc'], win_taken=st['taken'],
                  bcount={}, hist={}, hist_cyc={}, img={})

    def sio_read(uc, off, size, _):
        if off == 0x50:  # FIFO_ST: RDY always, VLD when a reply is queued
            return 0x2 | (1 if st['queue'] else 0)
        if off == 0x58:  # FIFO_RD
            return st['queue'].pop(0) if st['queue'] else 0
        return 0

    def sio_write(uc, off, size, value, _):
        if off != 0x54:  # FIFO_WR
            return
        if value == SYNC_TIME_REQ_CLR:
            st['queue'].append(SYNC_TIME_ACK_CLR)
        elif value == SYNC_TIME_REQ_TIME:
            st['queue'] += [0, 0]
        else:  # present(): one update() finished
            st['queue'].append(FRAMEBUFFER_DONE)
            st['presents'] += 1
            if st['presents'] >= 2:
                windows.append(dict(frame=st['cur_frame'], insn=st['insn'] - st['win_insn'],
                                    cyc=st['cyc'] - st['win_cyc'], taken=st['taken'] - st['win_taken'],
                                    bcount=st['bcount'], hist=st['hist'], hist_cyc=st['hist_cyc'],
                                    img=st['img']))
            if not plan:
                uc.emu_stop()
                return
            f = plan.pop(0)
            uc.mem_write(frame_addr, struct.pack('<I', f))
            st['cur_frame'] = f
            begin_window()

    mu.mmio_map(SIO, 0x1000, sio_read, None, sio_write, None)
    mu.mmio_map(TIMER0, 0x1000, lambda uc, off, size, _: (st['cyc'] // 150) & 0xffffffff, None,
                lambda *x: None, None)
    mu.mmio_map(DWT, 0x1000, lambda uc, off, size, _: st['cyc'] & 0xffffffff, None,
                lambda *x: None, None)

    blocks = {}

    def hook_block(uc, addr, size, _):
        b = blocks.get((addr, size))
        if b is None:
            names, cyc, _p, _i = M.decode_block(cs, bytes(uc.mem_read(addr, size)), addr)
            b = blocks[(addr, size)] = (names, cyc, sum(cyc))
        if st['prev_end'] is not None and addr != st['prev_end']:
            st['cyc'] += M.TAKEN_EXTRA
            st['taken'] += 1
        st['prev_end'] = addr + size
        st['insn'] += len(b[0])
        st['cyc'] += b[2]
        bc = st['bcount']
        bc[(addr, size)] = bc.get((addr, size), 0) + 1
        h, hc = st['hist'], st['hist_cyc']
        for n, c in zip(b[0], b[1]):
            h[n] = h.get(n, 0) + 1
            hc[n] = hc.get(n, 0) + c

    def hook_fb(uc, access, addr, size, value, _):
        st['img'][(addr - FB0) % FB_SIZE] = value & 0xffff

    begin_window()
    mu.hook_add(UC_HOOK_BLOCK, hook_block)
    mu.hook_add(UC_HOOK_MEM_WRITE, hook_fb, begin=FB0, end=FB1 + FB_SIZE - 1)
    mu.reg_write(UC_ARM_REG_SP, M.RAM_BASE + M.RAM_SIZE)
    mu.reg_write(UC_ARM_REG_LR, 0xFFFFFFFF)
    mu.emu_start(start | 1, 0xFFFFFFFE)
    if len(windows) != len(frames):
        raise SystemExit(f"emu: real ELF presented {len(windows)} of {len(frames)} frames; "
                         "the OS protocol fake in real.py needs updating")

    results = []
    for w in windows:
        f = w['frame']
        png = os.path.join(out, f'real_{f:04d}.png')
        M.write_png(png, M.rgb565_rows(lambda k: w['img'].get(2 * k, 0)))
        ac = M.addr_counts(cs, mu, w['bcount'])
        with open(os.path.join(out, f'real_addr_{f:04d}.json'), 'w') as fh:
            json.dump({hex(k): v for k, v in sorted(ac.items())}, fh)
        with open(os.path.join(out, f'real_hist_{f:04d}.json'), 'w') as fh:
            json.dump(dict(hist=w['hist'], hist_cyc=w['hist_cyc']), fh)
        r = M.result('real', f, w['insn'], w['cyc'], w['taken'], w['hist'])
        r['png'] = png
        r['pixels_written'] = len(w['img'])
        with open(os.path.join(out, f'result_real_{f:04d}.json'), 'w') as fh:
            json.dump(r, fh)
        results.append(r)
        if not quiet:
            print(f"real frame {f}: {r['insn']:,} insns, {r['cyc']:,} modelled cycles "
                  f"({r['cyc_px']:.1f}/px), {r['ms']:.2f} ms at 150 MHz (whole update())")
    return results


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--elf', default=os.path.join(MONO, 'zig-out', 'firmware', 'snouty-reflections.elf'))
    ap.add_argument('--frames', type=int, nargs='+', default=[0, 300])
    ap.add_argument('--mode', choices=['none', 'bayer'], default='none')
    ap.add_argument('--out', default=os.path.join(HERE, 'out'))
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    run(a.elf, a.frames, a.out, a.mode)


if __name__ == '__main__':
    main()
