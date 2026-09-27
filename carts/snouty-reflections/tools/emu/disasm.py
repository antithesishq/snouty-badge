#!/usr/bin/env python3
"""Annotated capstone listing with per-instruction executions per pixel.

With a symbol, lists that function; without one, lists every function that
executed at least --min-share of the frame's instructions, hottest first.

usage: .venv/bin/python disasm.py ELF [SYMBOL] --counts out/addr_0000.json [--min-share 0.01]
"""
import argparse
import json

from elftools.elf.elffile import ELFFile

import model as M


def functions(elf):
    """[(names, addr, size)], aliases at one address joined with ' = '."""
    by_addr = {}
    for s in elf.get_section_by_name('.symtab').iter_symbols():
        if s['st_info']['type'] == 'STT_FUNC' and s['st_size']:
            key = (s['st_value'] & ~1, s['st_size'])
            by_addr.setdefault(key, []).append(s.name)
    return [(' = '.join(sorted(n)), a, z) for (a, z), n in by_addr.items()]


def list_function(elf, cs, name, addr, size, counts, pixels):
    text = next(s for s in elf.iter_sections() if s['sh_addr'] <= addr < s['sh_addr'] + s['sh_size'])
    code = text.data()[addr - text['sh_addr']: addr - text['sh_addr'] + size]
    lines = [f"; {name} @ {addr:#010x}, {size} bytes"]
    off = 0
    while off < len(code):
        for i in cs.disasm(code[off:], addr + off):
            c = counts.get(i.address)
            tag = f"{c / pixels:8.2f}/px" if c else " " * 11
            lines.append(f"{i.address:08x} {tag}  {i.mnemonic:10} {i.op_str}")
            off += i.size
        if off < len(code):  # literal pool or padding: skip a halfword
            lines.append(f"{addr + off:08x}              .short data")
            off += 2
    return lines


def listing(elf_path, counts_path, symbol=None, min_share=0.01, pixels=M.N_PIXELS):
    elf = ELFFile(open(elf_path, 'rb'))
    cs = M.make_cs()
    counts = {int(k, 16): v for k, v in json.load(open(counts_path)).items()} if counts_path else {}
    total = sum(counts.values()) or 1
    fns = functions(elf)
    if symbol:
        chosen = [f for f in fns if symbol in f[0].split(' = ')]
        if not chosen:
            raise SystemExit(f"emu: no function symbol {symbol} in {elf_path}")
    else:
        hot = []
        for f in fns:
            n = sum(v for a, v in counts.items() if f[1] <= a < f[1] + f[2])
            if n / total >= min_share:
                hot.append((n, f))
        chosen = [f for _, f in sorted(hot, key=lambda t: t[0], reverse=True)]
    lines = [f"; {elf_path}", f"; counts {counts_path} ({total:,} instructions executed)"]
    for f in chosen:
        n = sum(v for a, v in counts.items() if f[1] <= a < f[1] + f[2])
        lines.append("")
        lines.append(f"; {n / total * 100:.1f}% of executed instructions")
        lines += list_function(elf, cs, f[0], f[1], f[2], counts, pixels)
    return '\n'.join(lines) + '\n'


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('elf')
    ap.add_argument('symbol', nargs='?')
    ap.add_argument('--counts')
    ap.add_argument('--min-share', type=float, default=0.01)
    ap.add_argument('--pixels', type=float, default=M.N_PIXELS)
    a = ap.parse_args()
    print(listing(a.elf, a.counts, a.symbol, a.min_share, a.pixels), end='')
