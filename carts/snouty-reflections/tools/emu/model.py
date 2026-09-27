"""Shared pieces of the emulated cycle benchmark: the Cortex-M33 cycle
model, the unicorn/capstone setup, ELF helpers and a tiny PNG writer.

The cycle model is a model, not a measurement. It assumes code and data in
zero-wait-state SRAM and no pipeline stalls; see README.md for its blind
spots. Change it here and every runner picks it up.
"""
import struct
import zlib

from capstone import CS_ARCH_ARM, CS_MODE_MCLASS, CS_MODE_THUMB, Cs
from capstone.arm import ARM_CC_AL, ARM_CC_INVALID, ARM_OP_REG
from elftools.elf.elffile import ELFFile
from unicorn import UC_ARCH_ARM, UC_MODE_MCLASS, UC_MODE_THUMB, Uc, UcError
from unicorn.arm_const import UC_CPU_ARM_CORTEX_M33

W, H = 160, 128
N_PIXELS = W * H
CLOCK_HZ = 150e6
RAM_BASE, RAM_SIZE = 0x20000000, 0x80000

_CONDS = ('eq', 'ne', 'hs', 'cs', 'lo', 'cc', 'mi', 'pl', 'vs', 'vc',
          'hi', 'ls', 'ge', 'lt', 'gt', 'le')

# ------------------------------------------------------------ cycle model

def base_name(ins):
    """Mnemonic without size suffix or condition code (bne -> b<cc>)."""
    m = ins.mnemonic.split('.')[0]
    if m.startswith('it'):
        return m
    if ins.cc not in (ARM_CC_AL, ARM_CC_INVALID) or (m[:1] == 'b' and m[1:] in _CONDS):
        for s in _CONDS:
            if m.endswith(s) and len(m) > len(s):
                m = m[:-len(s)]
                break
        if m == 'b':
            m = 'b<cc>'
    return m


def _reglist_len(ins):
    return sum(1 for op in ins.operands if op.type == ARM_OP_REG)


_MULTI = ('vpush', 'vpop', 'push', 'pop', 'ldm', 'stm', 'vldmia', 'vstmia',
          'vldmdb', 'vstmdb', 'ldmia', 'stmia', 'stmdb')
_MULTI_BASE = ('ldm', 'stm', 'vldmia', 'vstmia', 'vldmdb', 'vstmdb', 'ldmia', 'stmia', 'stmdb')


def cycles_of(ins, m):
    """Modelled issue cycles of one instruction (m = base_name(ins))."""
    if m in ('vdiv', 'vsqrt'):
        return 14
    if m in ('vfma', 'vfms', 'vfnma', 'vfnms', 'vmla', 'vmls', 'vnmla', 'vnmls'):
        return 3
    if m in _MULTI:
        n = _reglist_len(ins) - (1 if m in _MULTI_BASE else 0)
        return 1 + max(n, 1)
    if m in ('ldrd', 'strd'):
        return 3
    if m.startswith('ldr') or m.startswith('str') or m in ('vldr', 'vstr'):
        return 2
    if m in ('sdiv', 'udiv'):
        return 6
    return 1


# A taken branch (any change of flow that is not a fall-through into the
# next block) costs one extra cycle: the M33 has no branch predictor.
TAKEN_EXTRA = 1


def decode_block(cs, code, addr):
    """(names, per-insn cycles, prefix cycles, addr->index) for one block."""
    ins = list(cs.disasm(code, addr))
    assert sum(i.size for i in ins) == len(code), hex(addr)
    names = [base_name(i) for i in ins]
    cyc = [cycles_of(i, n) for i, n in zip(ins, names)]
    pref, acc = [], 0
    for c in cyc:
        pref.append(acc)
        acc += c
    idx = {i.address: k for k, i in enumerate(ins)}
    return names, cyc, pref, idx


# ------------------------------------------------------------ setup

def make_cs():
    cs = Cs(CS_ARCH_ARM, CS_MODE_THUMB | CS_MODE_MCLASS)
    cs.detail = True
    return cs


def make_uc():
    """Cortex-M33 unicorn with 512 KB SRAM at 0x20000000 and the FPU on."""
    mu = Uc(UC_ARCH_ARM, UC_MODE_THUMB | UC_MODE_MCLASS)
    mu.ctl_set_cpu_model(UC_CPU_ARM_CORTEX_M33)
    mu.mem_map(RAM_BASE, RAM_SIZE)
    # Unicorn does not expose the SCS as memory; map a plain page and write
    # CPACR (CP10/CP11 full access) so the code sees the FPU enabled.
    try:
        mu.mem_write(0xE000ED88, struct.pack('<I', 0x00F00000))
    except UcError:
        mu.mem_map(0xE000E000, 0x1000)
        mu.mem_write(0xE000ED88, struct.pack('<I', 0x00F00000))
    return mu


def load_elf(mu, path):
    """Load PT_LOAD segments; return (ELFFile, {symbol: value})."""
    elf = ELFFile(open(path, 'rb'))
    for seg in elf.iter_segments():
        if seg['p_type'] == 'PT_LOAD' and seg['p_filesz']:
            mu.mem_write(seg['p_vaddr'], seg.data())
    return elf, symbols(elf)


def symbols(elf):
    return {s.name: s['st_value'] for s in elf.get_section_by_name('.symtab').iter_symbols()}


def need(syms, name, elf_path):
    if name not in syms:
        raise SystemExit(f"emu: symbol '{name}' not found in {elf_path}; "
                         f"the cart changed shape, update tools/emu")
    return syms[name]


# ------------------------------------------------------------ output

def rgb565_rows(get_word):
    """Column-major RGB565 framebuffer -> H rows of RGB888 bytes."""
    rows = [[] for _ in range(H)]
    for x in range(W):
        for y in range(H):
            v = get_word(x * H + y)
            rows[y] += [round((v & 31) * 255 / 31), round(((v >> 5) & 63) * 255 / 63),
                        round(((v >> 11) & 31) * 255 / 31)]
    return rows


def write_png(path, rows):
    raw = b''.join(b'\x00' + bytes(r) for r in rows)

    def chunk(t, d):
        c = struct.pack('>I', len(d)) + t + d
        return c + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    ihdr = struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr)
                + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def addr_counts(cs, mu, bcount):
    """Per-instruction execution counts from per-block counts."""
    out = {}
    for (ba, bs), c in bcount.items():
        for i in cs.disasm(bytes(mu.mem_read(ba, bs)), ba):
            out[i.address] = out.get(i.address, 0) + c
    return out


def result(kind, frame, insn, cyc, taken, hist):
    return dict(kind=kind, frame=frame, insn=insn, cyc=cyc, taken=taken,
                cyc_px=cyc / N_PIXELS, ms=cyc / CLOCK_HZ * 1e3, fps=CLOCK_HZ / cyc,
                vdiv_px=hist.get('vdiv', 0) / N_PIXELS, vsqrt_px=hist.get('vsqrt', 0) / N_PIXELS)
