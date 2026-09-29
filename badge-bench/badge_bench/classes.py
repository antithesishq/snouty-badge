"""Instruction classes of the cycle model and their default costs.

Pure Python (no unicorn/capstone), so calibrate/fit.py can import it on a
machine without the emulator. model.cycles_of prices an instruction as the
cost of its class; `--calibrate FILE` replaces the costs with a fitted table.
"""

# Model classes, in the order of calibrate/PLAN.md (and calibration.toml).
# `taken` and `fp_dep` are per-instruction events, not mnemonics.
CLASSES = ['alu', 'vmul', 'vaddsub', 'vcmp', 'vdiv', 'vsqrt', 'vfma', 'ldr', 'str',
           'vldr', 'vstr', 'ldrd_strd', 'multi', 'udiv', 'taken', 'fp_dep']

# The table the model has always used. `multi` is not a flat cost: it is
# 1 + max(registers transferred, 1) (see model.cycles_of) and is never fitted.
# `taken` is not a mnemonic: it is the extra cycle of a block entered by a
# taken branch. `fp_dep` is the stall of an instruction that reads an FP
# register (or the FPSCR flags) written by the FP data-processing
# instruction immediately before it (calibrate/PLAN.md, C3). Its default is
# 0: the uncalibrated model never charged it, and the badge fit prices it
# (about 1 cycle).
DEFAULT_COSTS = {'alu': 1, 'vmul': 1, 'vaddsub': 1, 'vcmp': 1, 'vdiv': 14, 'vsqrt': 14,
                 'vfma': 3, 'ldr': 2, 'str': 2, 'vldr': 2, 'vstr': 2, 'ldrd_strd': 3,
                 'multi': 1, 'udiv': 6, 'taken': 1, 'fp_dep': 0}

# Classes whose result the next instruction may stall on (the `fp_dep` producers).
FP_PRODUCERS = frozenset({'vmul', 'vaddsub', 'vcmp', 'vdiv', 'vsqrt', 'vfma'})

# Classes that touch the data bus (the DMA contention term applies to them).
MEMORY_CLASSES = frozenset({'ldr', 'str', 'vldr', 'vstr', 'ldrd_strd', 'multi'})

# Load/store-multiple mnemonics as capstone spells them (base names). The set
# is exactly the one the model has priced as multi since v1; ldmdb is not in
# it (it falls to alu) so that historical results stay bit-identical.
MULTI = frozenset({'vpush', 'vpop', 'push', 'pop', 'ldm', 'stm', 'vldmia', 'vstmia',
                   'vldmdb', 'vstmdb', 'ldmia', 'stmia', 'stmdb'})
# Of those, the ones whose first register operand is the base register (not
# transferred).
MULTI_WITH_BASE = frozenset({'ldm', 'stm', 'vldmia', 'vstmia', 'vldmdb', 'vstmdb',
                             'ldmia', 'stmia', 'stmdb'})

_FMA = frozenset({'vfma', 'vfms', 'vfnma', 'vfnms', 'vmla', 'vmls', 'vnmla', 'vnmls'})
_VADDSUB = frozenset({'vadd', 'vsub', 'vabs', 'vneg', 'vmov', 'vmaxnm', 'vminnm'})
_VCMP = frozenset({'vcmp', 'vcmpe', 'vmrs'})

_cache = {}


def _classify(m):
    if m in ('vdiv',):
        return 'vdiv'
    if m == 'vsqrt':
        return 'vsqrt'
    if m in _FMA:
        return 'vfma'
    if m in MULTI:
        return 'multi'
    if m in ('ldrd', 'strd'):
        return 'ldrd_strd'
    if m.startswith('ldr'):
        return 'ldr'
    if m.startswith('str'):
        return 'str'
    if m == 'vldr':
        return 'vldr'
    if m == 'vstr':
        return 'vstr'
    if m in ('udiv', 'sdiv'):
        return 'udiv'
    if m in ('vmul', 'vnmul'):
        return 'vmul'
    if m in _VADDSUB or m.startswith('vcvt') or m.startswith('vsel'):
        return 'vaddsub'
    if m in _VCMP:
        return 'vcmp'
    return 'alu'


def classify(m):
    """Model class of a base mnemonic (model.base_name: 'vmul', 'ldrb', 'b<cc>')."""
    c = _cache.get(m)
    if c is None:
        c = _cache[m] = _classify(m)
    return c
