#!/usr/bin/env python3
"""Per-pixel counts of codegen categories that the optimisation work cares
about (literal-pool loads, spills, core<->FP moves, conversions, compares,
divide and sqrt sites), from an addr_FFFF.json count file and its ELF.

usage: .venv/bin/python categorize.py ELF COUNTS.json
"""
import json
import re
import sys
from collections import Counter

from elftools.elf.elffile import ELFFile

import model as M


def categorize(elf_path, counts_path):
    e = ELFFile(open(elf_path, 'rb'))
    SHF_EXECINSTR = 0x4
    secs = [(s['sh_addr'], s.data()) for s in e.iter_sections()
            if s['sh_flags'] & SHF_EXECINSTR and s['sh_type'] == 'SHT_PROGBITS']
    cs = M.make_cs()
    cnt = {int(k, 16): v for k, v in json.load(open(counts_path)).items()}
    cat, sites = Counter(), []
    for a, c in cnt.items():
        sec = next(((b, d) for b, d in secs if b <= a < b + len(d)), None)
        if sec is None:
            continue
        base, data = sec
        i = next(cs.disasm(data[a - base:a - base + 4], a), None)
        if i is None:
            continue
        m, o = i.mnemonic, i.op_str
        if m.startswith('vldr'):
            k = ('vldr [pc] literal const' if '[pc' in o else
                 'vldr [sp] spill reload' if '[sp' in o else 'vldr [reg] table/data')
        elif m.startswith('vstr'):
            k = 'vstr [sp] spill' if '[sp' in o else 'vstr other'
        elif m.startswith('ldr') or m.startswith('str'):
            k = m.split('.')[0] + (' [sp]' if '[sp' in o else '')
        elif m == 'vmov' and (re.match(r'^[rl]', o.split(',')[0])
                              or re.search(r', (r\d+|sb|sl|fp|ip|lr)$', o)):
            k = 'vmov core<->fp'
        elif m.startswith('vmov'):
            k = 'vmov fp<->fp/imm'
        elif m.startswith('vcvt'):
            k = m.split('.')[0] + ' ' + '.'.join(m.split('.')[1:])
        elif m.startswith('vdiv') or m.startswith('vsqrt'):
            k = m.split('.')[0]
            sites.append((c / M.N_PIXELS, hex(a), m, o))
        elif m in ('vcmp.f32', 'vcmpe.f32'):
            k = 'vcmp'
        elif m == 'vmrs':
            k = 'vmrs'
        else:
            continue
        cat[k] += c
    lines = [f"codegen categories per pixel ({counts_path}):"]
    for k, v in sorted(cat.items(), key=lambda kv: -kv[1]):
        lines.append(f"  {k:28} {v / M.N_PIXELS:7.2f}/px")
    lines.append("  div/sqrt sites (executions per pixel):")
    for s in sorted(sites, reverse=True):
        lines.append("    %.3f %s %s %s" % s)
    return '\n'.join(lines)


if __name__ == '__main__':
    print(categorize(sys.argv[1], sys.argv[2]))
