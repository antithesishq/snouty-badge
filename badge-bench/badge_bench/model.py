"""The Cortex-M33 cycle model and the unicorn/capstone setup.

Copied from carts/snouty-reflections/tools/emu/model.py so the two tools price
instructions identically (tests/test_reflections.sh checks that). The model
counts issue cycles only, with code and data in zero-wait SRAM; see the
README for its blind spots. Change it here and every report picks it up.
"""
import struct

from capstone import CS_ARCH_ARM, CS_MODE_MCLASS, CS_MODE_THUMB, Cs
from capstone.arm import ARM_CC_AL, ARM_CC_INVALID, ARM_OP_REG
from unicorn import UC_ARCH_ARM, UC_MODE_MCLASS, UC_MODE_THUMB, Uc, UcError
from unicorn.arm_const import UC_CPU_ARM_CORTEX_M33

CLOCK_HZ = 150_000_000
CYCLES_PER_US = CLOCK_HZ // 1_000_000
CYCLES_PER_MS = CLOCK_HZ / 1000.0

_CONDS = ('eq', 'ne', 'hs', 'cs', 'lo', 'cc', 'mi', 'pl', 'vs', 'vc',
          'hi', 'ls', 'ge', 'lt', 'gt', 'le')


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


# A taken branch (any block entry that is not a fall-through from the
# previous block) costs one extra cycle: the M33 has no branch predictor.
TAKEN_EXTRA = 1


class DecodeError(Exception):
    pass


def decode_block(cs, code, addr):
    """(instruction count, modelled cycles) of one unicorn translation block."""
    ins = list(cs.disasm(code, addr))
    got = sum(i.size for i in ins)
    if got != len(code):
        raise DecodeError(f"capstone decoded {got} of {len(code)} bytes of the block at "
                          f"{addr:#010x}; the instruction at {addr + got:#010x} is not "
                          f"understood by the cycle model")
    return len(ins), sum(cycles_of(i, base_name(i)) for i in ins)


def make_cs():
    cs = Cs(CS_ARCH_ARM, CS_MODE_THUMB | CS_MODE_MCLASS)
    cs.detail = True
    return cs


SCS_BASE = 0xE000E000
CPACR = 0xE000ED88


def make_uc():
    """Cortex-M33 unicorn with the FPU enabled (CPACR CP10/CP11 full access)."""
    mu = Uc(UC_ARCH_ARM, UC_MODE_THUMB | UC_MODE_MCLASS)
    mu.ctl_set_cpu_model(UC_CPU_ARM_CORTEX_M33)
    # Unicorn does not expose the SCS as memory; map a plain page and write
    # CPACR so the code sees the FPU enabled.
    try:
        mu.mem_write(CPACR, struct.pack('<I', 0x00F00000))
    except UcError:
        mu.mem_map(SCS_BASE, 0x1000)
        mu.mem_write(CPACR, struct.pack('<I', 0x00F00000))
    return mu
