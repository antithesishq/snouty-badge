#!/usr/bin/env python3
"""Cross-check core/boot.zig against the real Lynx boot ROM (docs/BOOT.md).

usage: bootrom_crosscheck.py [--rom ~/roms/lynx/lynxboot.img] [--out DIR] CART.lnx [...]

Runs the 512-byte boot ROM image (Adrian's local copy, never in the repo) on
py65's 65C02 core with a minimal Lynx around it: 64 KB RAM, MAPCTL overlays,
Suzy's RCART0 cart port (block shift register + ripple counter) and the
Mikey registers the ROM writes. It stops the first time the CPU leaves the
loader and the ROM (PC outside $0200-$0FFF, the ROM's decryptor copy at
$5000-$50FF and $FE00-$FFFF), which is where
the loader hands over to the game, or after --max-steps.

For every cart it writes DIR/<name>.boot.json with:
  - "first": the state when the ROM first jumps to $0200 (what
    boot.post_boot must reproduce): A/X/Y/P/SP, MAPCTL, IODIR/IODAT, the cart
    block and counter, the Mikey/Suzy registers written, and the RAM as
    (address, hex) runs of non-zero bytes;
  - "frames": each pass through the ROM's frame decryptor at $FE4A: the
    destination pointer ($05/$06), the cart position on entry and on exit
    (the JMP $0200), the bytes written and the registers at the JMP;
  - "handover": the PC and registers where the loader left for the game;
  - "rom_entries": the ROM addresses the loader called or jumped to, with counts
    (what the emulator must trap without a boot ROM).

The output holds decrypted loader bytes of the cart (game code), so it goes
to the gitignored tests/roms/boot/ by default. Nothing from the boot ROM
image is written except the effects the tests compare. Needs py65
(tools/.venv: python3 -m venv tools/.venv && tools/.venv/bin/pip install py65).
"""
import argparse
import hashlib
import json
import os
import sys

from py65.devices.mpu65c02 import MPU

BOOT_MD5 = 'fcd403db69f54290b51035d82f835e7b'
HERE = os.path.dirname(os.path.abspath(__file__))


def cart_image(data):
    """(payload, block_size, header?) of a .lnx file, headered or not."""
    if data[:4] == b'LYNX':
        page = data[4] | data[5] << 8
        return data[64:], page, True
    sizes = {128 * 1024: 512, 256 * 1024: 1024, 512 * 1024: 2048}
    if len(data) not in sizes:
        raise SystemExit(f'headerless file of {len(data)} bytes: block size unknown')
    return data, sizes[len(data)], False


class Lynx:
    """Just enough Lynx for the boot ROM and the first loader stage."""

    def __init__(self, rom, cart, block_size):
        self.ram = bytearray(65536)
        self.rom = rom
        self.cart = cart
        self.block_size = block_size
        self.mapctl = 0
        self.shift = 0          # cart block shift register (8 bits)
        self.counter = 0        # ripple counter within the block
        self.sysctl1 = 0
        self.iodat = 0
        self.iodir = 0
        self.mikey = {}         # last value written per Mikey register
        self.suzy = {}
        self.cart_reads = 0

    # py65 indexes memory with ints (and slices in a few helpers).
    def __getitem__(self, a):
        if isinstance(a, slice):
            return [self[i] for i in range(*a.indices(65536))]
        return self.read(a)

    def __setitem__(self, a, v):
        if isinstance(a, slice):
            for i, x in zip(range(*a.indices(65536)), v):
                self[i] = x
            return
        self.write(a, v)

    def __len__(self):
        return 65536

    def cart_byte(self):
        off = self.shift * self.block_size + (self.counter % self.block_size)
        self.counter += 1
        self.cart_reads += 1
        return self.cart[off] if off < len(self.cart) else 0xFF

    def read(self, a):
        a &= 0xFFFF
        if a == 0xFFF9:
            return self.mapctl
        if 0xFC00 <= a <= 0xFCFF and not self.mapctl & 1:
            if a == 0xFCB2:
                return self.cart_byte()
            if a == 0xFC88:
                return 1            # SUZYHREV: 1.0
            return self.suzy.get(a, 0)
        if 0xFD00 <= a <= 0xFDFF and not self.mapctl & 2:
            if a == 0xFD8B:
                return self.iodat
            return self.mikey.get(a, 0)
        if 0xFE00 <= a <= 0xFFF7 and not self.mapctl & 4:
            return self.rom[a - 0xFE00]
        if 0xFFFA <= a and not self.mapctl & 8:
            return self.rom[a - 0xFE00]
        return self.ram[a]

    def write(self, a, v):
        a &= 0xFFFF
        v &= 0xFF
        if a == 0xFFF9:
            self.mapctl = v
            return
        if 0xFC00 <= a <= 0xFCFF and not self.mapctl & 1:
            self.suzy[a] = v
            return
        if 0xFD00 <= a <= 0xFDFF and not self.mapctl & 2:
            self.mikey[a] = v
            if a == 0xFD87:
                # SYSCTL1 bit 0 is the cart address strobe: a rising edge
                # clocks IODAT bit 1 into the block shift register; while the
                # strobe is high the ripple counter is held at zero.
                if v & 1 and not self.sysctl1 & 1:
                    self.shift = ((self.shift << 1) | (self.iodat >> 1 & 1)) & 0xFF
                if v & 1:
                    self.counter = 0
                self.sysctl1 = v
            elif a == 0xFD8B:
                self.iodat = v
            elif a == 0xFD8A:
                self.iodir = v
            return
        # ROM and vector space: writes land in the RAM underneath.
        self.ram[a] = v


def runs(ram, lo=0, hi=65536):
    """Non-zero RAM as [[address, hex], ...] runs."""
    out, a = [], lo
    while a < hi:
        if ram[a]:
            b = a
            while b < hi and ram[b]:
                b += 1
            out.append([a, bytes(ram[a:b]).hex()])
            a = b
        else:
            a += 1
    return out


def regs(cpu, m):
    return {'a': cpu.a, 'x': cpu.x, 'y': cpu.y, 'p': cpu.p, 'sp': cpu.sp, 'pc': cpu.pc,
            'mapctl': m.mapctl, 'iodir': m.iodir, 'iodat': m.iodat, 'sysctl1': m.sysctl1,
            'block': m.shift, 'counter': m.counter, 'cart_reads': m.cart_reads}


def run(rom, path, max_steps):
    payload, bs, headered = cart_image(open(path, 'rb').read())
    m = Lynx(rom, payload, bs)
    cpu = MPU(memory=m)
    # 65C02 reset: I set, D clear; SP after the reset sequence's three dummy
    # pushes from 0 is $FD (the real value is whatever it was before reset).
    cpu.sp = 0xFD
    cpu.p = 0x34
    cpu.pc = m.read(0xFFFC) | m.read(0xFFFD) << 8
    first = None
    frames = []
    cur = None
    handover = None
    rom_entries = {}
    prev = cpu.pc
    steps = 0
    while steps < max_steps:
        pc = cpu.pc
        if first is not None and pc >= 0xFE00 and not (prev >= 0xFE00 or 0x5000 <= prev < 0x5100):
            k = f'{pc:04X}'
            rom_entries[k] = rom_entries.get(k, 0) + 1
        prev = pc
        if pc == 0xFE4A and first is not None and m.mapctl & 4 == 0:
            cur = {'dest': m.ram[5] | m.ram[6] << 8, 'zp02': m.ram[2], 'entry': regs(cpu, m)}
        if pc == 0x0200:
            if first is None:
                first = {'regs': regs(cpu, m), 'mikey': {f'{k:04X}': v for k, v in sorted(m.mikey.items())},
                         'suzy': {f'{k:04X}': v for k, v in sorted(m.suzy.items())},
                         'ram': runs(m.ram)}
            elif cur is not None:
                end = m.ram[5] | m.ram[6] << 8
                cur['exit'] = regs(cpu, m)
                page = cur['dest'] & 0xFF00
                n = (end - cur['dest']) & 0xFF
                cur['bytes'] = bytes(m.ram[page | ((cur['dest'] + i) & 0xFF)] for i in range(n)).hex()
                frames.append(cur)
                cur = None
        if first is not None and not (0x0200 <= pc < 0x1000 or 0x5000 <= pc < 0x5100 or pc >= 0xFE00):
            handover = regs(cpu, m)
            break
        cpu.step()
        steps += 1
    return {'cart': os.path.basename(path), 'headered': headered, 'block_size': bs,
            'steps': steps, 'first': first, 'frames': frames, 'handover': handover,
            'rom_entries': rom_entries,
            'ram_at_handover': runs(m.ram) if handover else None}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('carts', nargs='+')
    ap.add_argument('--rom', default=os.path.expanduser('~/roms/lynx/lynxboot.img'))
    ap.add_argument('--out', default=os.path.join(HERE, '..', 'tests', 'roms', 'boot'))
    ap.add_argument('--max-steps', type=int, default=20_000_000)
    a = ap.parse_args()
    rom = open(a.rom, 'rb').read()
    if len(rom) != 512 or hashlib.md5(rom).hexdigest() != BOOT_MD5:
        sys.exit(f'{a.rom}: not the expected 512-byte boot ROM (md5 {BOOT_MD5})')
    os.makedirs(a.out, exist_ok=True)
    for c in a.carts:
        r = run(rom, c, a.max_steps)
        name = os.path.splitext(os.path.basename(c))[0]
        dst = os.path.join(a.out, name + '.boot.json')
        with open(dst, 'w') as f:
            json.dump(r, f, indent=1)
        fr = r['first']['regs'] if r['first'] else None
        print(f'{c}: {r["steps"]} steps; first $0200: {fr}; {len(r["frames"])} more frame(s); '
              f'handover {r["handover"] and hex(r["handover"]["pc"])}; ROM entries {r["rom_entries"]} -> {dst}')


if __name__ == '__main__':
    main()
