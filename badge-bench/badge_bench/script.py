"""Button input: the carts' preview.mjs script JSON and --press shorthand.

A script is a JSON array of {"from": T1, "to": T2, "hold": ["A", "UP"]},
inclusive update indices (0 = the first update() after start()). --press
items are BTN:T1-T2 (bare T1-T2 means A). Same rules as preview.mjs: the
controls word before update #i is the OR of every entry covering i; CLICK is
refused because the OS owns it.
"""
import json
import re

from .elf import BenchError
from .os_fake import BUTTONS


def _button(name, where):
    n = name.strip().upper() if isinstance(name, str) else None
    if n == 'CLICK':
        raise BenchError(f"{where}: CLICK cannot be pressed (the OS owns the joystick click)")
    if n is None or n not in BUTTONS:
        raise BenchError(f"{where}: unknown button {json.dumps(name)} "
                         f"(use {' '.join(b for b in BUTTONS if b != 'CLICK')})")
    return BUTTONS[n]


def load_script(path):
    try:
        with open(path) as fh:
            data = json.load(fh)
    except OSError as e:
        raise BenchError(f"cannot read script {path}: {e.strerror}")
    except ValueError as e:
        raise BenchError(f"script {path} is not valid JSON: {e}")
    if not isinstance(data, list):
        raise BenchError(f"script {path}: top level must be a JSON array of "
                         '{"from", "to", "hold"} entries')
    out = []
    for i, ent in enumerate(data):
        at = f"script {path} entry {i}"
        if not isinstance(ent, dict):
            raise BenchError(f"{at}: must be an object")
        for k in ent:
            if k not in ('from', 'to', 'hold'):
                raise BenchError(f'{at}: unknown field "{k}" (allowed: from, to, hold)')
        for k in ('from', 'to'):
            v = ent.get(k)
            if not isinstance(v, int) or isinstance(v, bool) or v < 0:
                raise BenchError(f'{at}: field "{k}" must be a non-negative integer tick')
        if ent['to'] < ent['from']:
            raise BenchError(f'{at}: "to" ({ent["to"]}) is before "from" ({ent["from"]})')
        if not isinstance(ent.get('hold'), list):
            raise BenchError(f'{at}: field "hold" must be an array of button names')
        bits = 0
        for j, b in enumerate(ent['hold']):
            bits |= _button(b, f'{at} hold[{j}]')
        out.append((ent['from'], ent['to'], bits))
    return out


def parse_press(item):
    """'A:10-20' or '10-20' -> [(from, to, bits)]; comma-separated lists allowed."""
    out = []
    for part in item.split(','):
        m = re.match(r'^\s*(?:([A-Za-z]+)\s*:)?\s*(\d+)\s*-\s*(\d+)\s*$', part)
        if not m:
            raise BenchError(f"bad --press item '{part}' (want BTN:T1-T2 or T1-T2)")
        a, b = int(m.group(2)), int(m.group(3))
        if b < a:
            raise BenchError(f"bad --press item '{part}': end {b} < start {a}")
        out.append((a, b, _button(m.group(1) or 'A', f"--press '{part}'")))
    return out


def controls_table(frames, entries, base=0):
    """controls[i] = the u16 written to ipc_data.controls before update #i."""
    ctl = [base] * frames
    for a, b, bits in entries:
        for i in range(a, min(b, frames - 1) + 1):
            ctl[i] |= bits
    return ctl


def names(bits):
    return '+'.join(n for n, b in BUTTONS.items() if bits & b) or '-'
