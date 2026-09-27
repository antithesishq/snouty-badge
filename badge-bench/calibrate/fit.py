#!/usr/bin/env python3
"""Fit badge-bench's cycle model to a badge-calibrate hardware capture.

    fit.py --hardware CAPTURE.txt --emulator bench.json [--out calibration.toml] [--elf-sha SHA]
    fit.py --manual --hardware PHOTO.txt --emulator bench.json [--out ...]
    fit.py --selftest bench.json [--out calibration.toml]

CAPTURE.txt is the badge's console (lines `[CART] CAL k=...`, any prefix up
to `CAL ` is ignored); the last complete pass (the one ending with the last
`CAL done`) is used. With --manual the file holds hand-typed lines
`k=<id> idle=<cycles/op> busy=<cycles/op>` read off the screen instead.

bench.json is `badge-bench zig-out/firmware/badge-calibrate.elf --json` from
the same ELF: its own CAL trace lines are the modelled count per kernel run,
and its hot[] entries `kernels.k<id>_<name>` give each kernel's instruction
mix (mnemonics, taken branches, per-class cycles) per call.

The fit: one row per kernel, one unknown per model class (calibrate/PLAN.md
order, `multi` excluded: its modelled cycles move to the right-hand side).
Right-hand side: measured idle_min of one run, less the modelled multi
cycles and less the modelled cost of the run outside the kernel function
(the call, the return and the cycle-counter reads: emulator idle_min minus
the function's cycles per call, a few cycles; not fitted, it is 2e-5 of a
run and would make the system ill-conditioned). Least squares, pure Python. Contention: the busy run's extra
cycles per memory-class cycle over the memory kernels K7-K11.

--selftest feeds the emulator's own trace lines in as the hardware capture:
every ratio must be 1.000, the residual 0 and the fitted table the default
(within 0.01); exit status 1 otherwise.

Pure Python 3.9+: imports only badge_bench.classes (no unicorn/capstone).
"""
import argparse
import datetime
import json
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from badge_bench.classes import CLASSES, DEFAULT_COSTS, MEMORY_CLASSES, classify  # noqa: E402

MEMORY_KERNELS = (7, 8, 9, 10, 11)       # SPEC.md section 3: ldr/str/vldr/vstr kernels
FITTED = [c for c in CLASSES if c != 'multi']
UNKNOWNS = FITTED
MULTI_GUESS = 5                           # cycles per push/pop if bench.json lacks class_cyc
CAL_RE = re.compile(r'CAL (k=\d+\b.*|done\b.*)$')
MANUAL_RE = re.compile(r'\bk=(\d+)\s+idle=([0-9.]+)\s+busy=([0-9.]+)')
HEX_KEYS = ('sink', 'sum')


class FitError(Exception):
    pass


# ---------------------------------------------------------------- parsing

def _fields(s):
    out = {}
    for k, v in re.findall(r'(\w+)=(\S+)', s):
        try:
            out[k] = int(v, 16) if k in HEX_KEYS else int(v)
        except ValueError:
            try:
                out[k] = float(v)
            except ValueError:
                out[k] = v
    return out


def parse_cal(lines, what):
    """{id: fields} of the last complete pass, plus the `done` fields."""
    cur, done = {}, None
    for line in lines:
        m = CAL_RE.search(line.rstrip('\r\n'))
        if not m:
            continue
        body = m.group(1)
        if body.startswith('done'):
            done = (cur, _fields(body))
            cur = {}
        else:
            f = _fields(body)
            if not all(k in f for k in ('k', 'ops', 'idle_min', 'busy_min')):
                continue                      # a truncated line
            cur[f['k']] = f
    if done is None:
        raise FitError(f"{what}: no complete pass (no 'CAL done' line)")
    rows, d = done
    if isinstance(d.get('sum'), int) and len(rows) == 20:
        got = checksum(rows)
        if got != d['sum']:
            raise FitError(f"{what}: CAL done sum={d['sum']:08x} but the 20 rows hash to {got:08x}: "
                           "a garbled or mixed capture (lines from two passes?)")
        d['sum_ok'] = True
    return done


def checksum(rows):
    """The cart's FNV-1a-32 (harness.zig checksum_of): per kernel in id order,
    k n ops idle_min idle_med busy_min busy_med sink, each as 4 little-endian bytes."""
    h = 0x811c9dc5
    for k in sorted(rows):
        r = rows[k]
        for x in (r['k'], r['n'], r['ops'], r['idle_min'], r['idle_med'], r['busy_min'], r['busy_med'], r['sink']):
            for b in int(x).to_bytes(4, 'little'):
                h = ((h ^ b) * 0x01000193) & 0xffffffff
    return h


def parse_manual(lines, emu, what):
    """Hand-typed cycles/op -> the same shape as parse_cal (times ops)."""
    got = {}
    for line in lines:
        m = MANUAL_RE.search(line)
        if m:
            k = int(m.group(1))
            if k not in emu:
                raise FitError(f"{what}: kernel k={k} is not in the emulator run")
            ops = emu[k]['ops']
            i, b = float(m.group(2)) * ops, float(m.group(3)) * ops
            got[k] = dict(k=k, n=emu[k].get('n'), ops=ops, idle_min=i, idle_med=i,
                          busy_min=b, busy_med=b)
    if not got:
        raise FitError(f"{what}: no 'k=<id> idle=<c/op> busy=<c/op>' lines")
    return got, {'pass': 'manual'}


def load_emulator(path):
    with open(path) as fh:
        j = json.load(fh)
    lines = [t['text'] for t in j.get('traces', [])]
    trace, done = parse_cal(lines, f"{path} traces")
    mixes, warn = {}, []
    for h in j.get('hot', []):
        m = re.search(r'\bkernels\.k(\d+)_(\w+)', h['name'])
        if not m:
            continue
        k, name = int(m.group(1)), m.group(2)
        if 'mnemonics' not in h:
            raise FitError(f"{path}: hot entry {h['name']} has no 'mnemonics' "
                           "(re-run badge-bench with --json from this version)")
        e = h.get('entries') or 0
        if e <= 0:
            warn.append(f"{h['name']}: 0 entries in the run, row dropped")
            continue
        cnt = {c: 0.0 for c in CLASSES}
        for mn, n in h['mnemonics'].items():
            cnt[classify(mn)] += n / e
        cnt['taken'] = h.get('taken', 0) / e
        if 'class_cyc' in h:
            multi = h['class_cyc'].get('multi', 0) / e
        else:
            multi = cnt['multi'] * MULTI_GUESS
            if cnt['multi']:
                warn.append(f"{h['name']}: no class_cyc in bench.json; push/pop priced at "
                            f"{MULTI_GUESS} cycles each")
        mixes[k] = dict(name=name, entries=e, count=cnt, multi_cyc=multi, fn_cyc=h['cyc'] / e)
    ent = sorted({round(m['entries']) for m in mixes.values()})
    if len(ent) > 1:
        warn.append(f"kernel functions were entered different numbers of times ({ent}); a loop "
                    "head at a function's first instruction inflates `entries`")
    return dict(json=j, trace=trace, done=done, mixes=mixes, warnings=warn,
                sha=j.get('meta', {}).get('sha256'))


# ---------------------------------------------------------------- algebra

def solve(A, b):
    """Solve the square system A x = b (Gaussian elimination, partial pivoting)."""
    n = len(A)
    M = [row[:] + [b[i]] for i, row in enumerate(A)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(M[r][c]))
        if abs(M[p][c]) < 1e-300:
            raise FitError("singular normal equations")
        M[c], M[p] = M[p], M[c]
        for r in range(c + 1, n):
            f = M[r][c] / M[c][c]
            if f:
                for j in range(c, n + 1):
                    M[r][j] -= f * M[c][j]
    x = [0.0] * n
    for c in range(n - 1, -1, -1):
        x[c] = (M[c][n] - sum(M[c][j] * x[j] for j in range(c + 1, n))) / M[c][c]
    return x


def independent(cols, tol=1e-9):
    """Indices of columns (lists) kept by modified Gram-Schmidt: a column
    whose part orthogonal to the kept ones is below tol of its norm is
    dependent."""
    basis, keep = [], []
    for i, c in enumerate(cols):
        norm = math.sqrt(sum(v * v for v in c))
        if norm == 0:
            continue
        v = [x / norm for x in c]
        for q in basis:
            d = sum(a * b for a, b in zip(v, q))
            v = [a - d * b for a, b in zip(v, q)]
        r = math.sqrt(sum(a * a for a in v))
        if r > tol:
            basis.append([a / r for a in v])
            keep.append(i)
    return keep


def lstsq_fixed(rows, rhs, names, fixed):
    """Least squares for the unknowns not in `fixed` ({name: value}); columns
    scaled to unit norm for conditioning."""
    free = [i for i, n in enumerate(names) if n not in fixed]
    y = [rhs[r] - sum(rows[r][i] * fixed[n] for i, n in enumerate(names) if n in fixed)
         for r in range(len(rows))]
    scale = [math.sqrt(sum(rows[r][i] ** 2 for r in range(len(rows)))) or 1.0 for i in free]
    X = [[rows[r][i] / s for i, s in zip(free, scale)] for r in range(len(rows))]
    AtA = [[sum(X[r][a] * X[r][b] for r in range(len(X))) for b in range(len(free))]
           for a in range(len(free))]
    Atb = [sum(X[r][a] * y[r] for r in range(len(X))) for a in range(len(free))]
    z = solve(AtA, Atb) if free else []
    out = dict(fixed)
    for i, s, v in zip(free, scale, z):
        out[names[i]] = v / s
    return out


def fit(rows, rhs, names, defaults):
    """-> (solution dict, notes). Unidentifiable columns keep their default;
    negative results are clamped to 0 and the rest refitted."""
    notes = []
    cols = [[r[i] for r in rows] for i in range(len(names))]
    keep = set(independent(cols))
    fixed = {}
    for i, n in enumerate(names):
        if i not in keep:
            fixed[n] = defaults[n]
            why = ("no kernel exercises it" if not any(cols[i]) else
                   "it is collinear with other classes over these kernels")
            notes.append(f"{n}: not identifiable ({why}); kept at the default {defaults[n]:g}")
    while True:
        sol = lstsq_fixed(rows, rhs, names, fixed)
        neg = [n for n in names if n not in fixed and sol[n] < 0]
        if not neg:
            return sol, notes
        for n in neg:
            notes.append(f"{n}: fitted {sol[n]:.3f} < 0, clamped to 0 and the rest refitted")
            fixed[n] = 0.0


# ---------------------------------------------------------------- the fit

def run_fit(emu, hw, hw_done, manual=False):
    trace, mixes = emu['trace'], emu['mixes']
    ids = sorted(k for k in trace if k in mixes and k in hw)
    notes = list(emu['warnings'])
    for k in sorted(set(trace) | set(hw)):
        if k not in ids:
            where = [w for w, d in (('emulator trace', trace), ('hardware capture', hw),
                                    ('hot[] entries', mixes)) if k not in d]
            notes.append(f"kernel {k}: missing from the {', '.join(where)}; row dropped")
    if len(ids) < 2:
        raise FitError("fewer than two kernels in both captures")
    for k in ids:
        if hw[k].get('ops') != trace[k]['ops'] and not manual:
            notes.append(f"kernel {k}: ops differ (hardware {hw[k].get('ops')}, emulator "
                         f"{trace[k]['ops']}): not the same ELF?")
    call = {k: trace[k]['idle_min'] - mixes[k]['fn_cyc'] for k in ids}
    lo, hi = min(call.values()), max(call.values())
    if lo < 0 or hi - lo > 4:
        notes.append(f"modelled cost outside the kernel functions ranges {lo:.1f}..{hi:.1f} cycles "
                     "per run (expected a few, the same for all): check `entries` in bench.json")
    rows, rhs = [], []
    for k in ids:
        c = mixes[k]['count']
        rows.append([c[n] for n in FITTED])
        rhs.append(hw[k]['idle_min'] - mixes[k]['multi_cyc'] - call[k])
    sol, fnotes = fit(rows, rhs, UNKNOWNS, DEFAULT_COSTS)
    notes += fnotes
    pred = {k: sum(r * sol[n] for r, n in zip(row, UNKNOWNS)) + mixes[k]['multi_cyc'] + call[k]
            for k, row in zip(ids, rows)}
    per_op = [(pred[k] - hw[k]['idle_min']) / trace[k]['ops'] for k in ids if trace[k]['ops']]
    rms = math.sqrt(sum(v * v for v in per_op) / len(per_op)) if per_op else 0.0

    def mem_cyc(k):
        c = mixes[k]['count']
        return sum(c[n] * sol[n] for n in MEMORY_CLASSES if n != 'multi') + mixes[k]['multi_cyc']

    memk = [k for k in ids if k in MEMORY_KERNELS]
    extra = sum(hw[k]['busy_min'] - hw[k]['idle_min'] for k in memk)
    msum = sum(mem_cyc(k) for k in memk)
    factor = 1.0 + extra / msum if msum else 1.0
    plain = (sum(hw[k]['busy_min'] for k in memk) / sum(hw[k]['idle_min'] for k in memk)
             if memk else 1.0)
    per_class = {}
    for n in ('ldr', 'str', 'vldr', 'vstr', 'ldrd_strd'):
        num = den = 0.0
        for k in memk:
            c = mixes[k]['count'][n] * sol[n]
            m = mem_cyc(k)
            if c and m:
                num += (hw[k]['busy_min'] - hw[k]['idle_min']) * c / m
                den += c
        if den:
            per_class[n] = 1.0 + num / den
    other = [k for k in ids if k not in MEMORY_KERNELS]
    fetch = [(k, hw[k]['busy_min'] / hw[k]['idle_min']) for k in other if hw[k]['idle_min']]
    return dict(ids=ids, sol=sol, pred=pred, rms=rms, call=(lo, hi), factor=factor, plain=plain,
                per_class=per_class, fetch=fetch, notes=notes, memk=memk, hw=hw, hw_done=hw_done)


# ---------------------------------------------------------------- output

def report(emu, R):
    trace, mixes, hw, sol = emu['trace'], emu['mixes'], R['hw'], R['sol']
    L = []
    L.append(f"{'id':>3} {'name':<16} {'ops':>8} {'model/op':>9} {'idle/op':>9} {'busy/op':>9} "
             f"{'fit/op':>9} {'r_idle':>7} {'r_busy':>7}")
    for k in R['ids']:
        ops, mod = trace[k]['ops'], trace[k]['idle_min']
        po = (lambda v: f"{v / ops:9.3f}") if ops else (lambda v: f"{v:9.0f}")
        L.append(f"{k:3d} {mixes[k]['name']:<16} {ops:8d} {po(mod)} {po(hw[k]['idle_min'])} "
                 f"{po(hw[k]['busy_min'])} {po(R['pred'][k])} {hw[k]['idle_min'] / mod:7.3f} "
                 f"{hw[k]['busy_min'] / mod:7.3f}")
    L.append("  (per op columns are raw run cycles / ops, loop overhead and the call included;"
             " ops = 0 rows show run cycles)")
    L.append('')
    L.append(f"{'class':<10} {'default':>8} {'fitted':>8}")
    for n in FITTED:
        L.append(f"{n:<10} {DEFAULT_COSTS[n]:8g} {sol[n]:8.3f}")
    L.append(f"{'multi':<10} {'1+regs':>8} {'(fixed)':>8}")
    L.append(f"call overhead (modelled, not fitted): {R['call'][0]:g}..{R['call'][1]:g} cycles per run "
             "outside the kernel function")
    L.append('')
    L.append(f"residual: {R['rms']:.3f} cycles/op RMS over {len(R['ids'])} kernels")
    L.append(f"contention factor: {R['factor']:.3f} busy cycles per idle memory-class cycle over "
             f"kernels {', '.join(map(str, R['memk'])) or 'none'} (whole-kernel busy/idle "
             f"{R['plain']:.3f})")
    if R['per_class']:
        L.append('  per class: ' + ', '.join(f"{n} {v:.3f}" for n, v in R['per_class'].items()))
    if R['fetch']:
        worst = max(R['fetch'], key=lambda kv: abs(kv[1] - 1))
        L.append(f"non-memory kernels busy/idle: {min(v for _, v in R['fetch']):.3f}.."
                 f"{max(v for _, v in R['fetch']):.3f}"
                 + (f"; kernel {worst[0]} at {worst[1]:.3f}: instruction fetch contends with the "
                    "DMA too (the model does not charge it)" if abs(worst[1] - 1) > 0.02 else
                    " (no fetch contention)"))
    for n in R['notes']:
        L.append(f"note: {n}")
    return '\n'.join(L) + '\n'


def toml(emu, R, hw_path, emu_path, sha, dma_ms):
    trace, mixes, hw, sol = emu['trace'], emu['mixes'], R['hw'], R['sol']
    q = lambda s: '"' + str(s).replace('\\', '\\\\').replace('"', '\\"') + '"'
    L = ["# badge-bench cycle model calibration, written by calibrate/fit.py.",
         "# Use: badge-bench --calibrate this_file.toml", "",
         "[meta]",
         f"date = {q(datetime.date.today().isoformat())}",
         f"elf_sha256 = {q(sha or '')}",
         f"hardware_capture = {q(os.path.basename(hw_path))}",
         f"emulator_run = {q(os.path.basename(emu_path))}",
         f"residual_rms = {R['rms']:.4f}",
         f"call_overhead = {R['call'][1]:g}", "",
         "[costs]"]
    L += [f"{n} = {sol[n]:.3f}" for n in FITTED]
    L += ["", "[contention]", f"dma_ms = {dma_ms:g}", f"factor = {R['factor']:.4f}",
          f"whole_kernel_ratio = {R['plain']:.4f}"]
    L += [f"{n} = {v:.4f}" for n, v in R['per_class'].items()]
    for k in R['ids']:
        mod = trace[k]['idle_min']
        h = hw[k]
        L += ["", "[[kernels]]", f"id = {k}", f"name = {q(mixes[k]['name'])}",
              f"ops = {trace[k]['ops']}", f"modelled = {mod}"]
        for key in ('idle_min', 'idle_med', 'busy_min', 'busy_med'):
            v = h.get(key, h['idle_min' if key.startswith('idle') else 'busy_min'])
            L.append(f"{key} = {v:.0f}" if isinstance(v, float) else f"{key} = {v}")
        L += [f"ratio_idle = {h['idle_min'] / mod:.4f}", f"ratio_busy = {h['busy_min'] / mod:.4f}"]
    return '\n'.join(L) + '\n'


def selftest_check(R, emu):
    bad = []
    for k in R['ids']:
        r = R['hw'][k]['idle_min'] / emu['trace'][k]['idle_min']
        if f"{r:.3f}" != '1.000':
            bad.append(f"kernel {k} ratio_idle {r:.3f}")
    if R['rms'] >= 0.0005:
        bad.append(f"residual {R['rms']:.4f} cycles/op")
    for n in FITTED:
        if abs(R['sol'][n] - DEFAULT_COSTS[n]) > 0.01:
            bad.append(f"{n} fitted {R['sol'][n]:.3f}, default {DEFAULT_COSTS[n]}")
    return bad


def main(argv=None):
    ap = argparse.ArgumentParser(prog='fit.py', description=__doc__.split('\n\n')[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--hardware', metavar='CAPTURE.txt', help='badge console capture (or --manual file)')
    ap.add_argument('--emulator', metavar='bench.json', help='badge-bench --json of the same ELF')
    ap.add_argument('--manual', action='store_true',
                    help='--hardware holds hand-typed "k=<id> idle=<c/op> busy=<c/op>" lines')
    ap.add_argument('--selftest', metavar='bench.json',
                    help="use the emulator's own trace as the capture; expect ratios 1 and the defaults")
    ap.add_argument('--out', metavar='calibration.toml',
                    help='write the fit here (default calibrate/calibration.toml; --selftest: none)')
    ap.add_argument('--elf-sha', metavar='SHA', help='ELF sha256 for [meta] (default: bench.json meta)')
    ap.add_argument('--dma-ms', type=float, default=5.24, help='DMA window after present() (5.24)')
    a = ap.parse_args(argv)
    try:
        if a.selftest:
            emu_path = hw_path = a.selftest
            emu = load_emulator(emu_path)
            hw, done = emu['trace'], emu['done']
        else:
            if not (a.hardware and a.emulator):
                ap.error('--hardware and --emulator are required (or --selftest bench.json)')
            emu_path, hw_path = a.emulator, a.hardware
            emu = load_emulator(emu_path)
            with open(hw_path, errors='replace') as fh:
                lines = fh.read().splitlines()
            hw, done = (parse_manual(lines, emu['trace'], hw_path) if a.manual
                        else parse_cal(lines, hw_path))
        R = run_fit(emu, hw, done, manual=a.manual)
    except (FitError, OSError, ValueError, KeyError) as e:
        print(f"fit.py: error: {e}", file=sys.stderr)
        return 2
    src = 'selftest (emulator trace as the capture)' if a.selftest else hw_path
    print(f"fit.py: {src}, pass {done.get('pass', '?')}"
          + (f" sum {done['sum']:08x}" if isinstance(done.get('sum'), int) else '')
          + f"; emulator {emu_path} (pass {emu['done'].get('pass', '?')})")
    print(report(emu, R), end='')
    out = a.out or (None if a.selftest else os.path.join(HERE, 'calibration.toml'))
    if out:
        with open(out, 'w') as fh:
            fh.write(toml(emu, R, hw_path, emu_path, a.elf_sha or emu['sha'], a.dma_ms))
        print(f"wrote {out}")
    if a.selftest:
        bad = selftest_check(R, emu)
        if bad:
            print("fit.py selftest: FAIL: " + '; '.join(bad))
            return 1
        print(f"fit.py selftest: PASS ({len(R['ids'])} kernels, ratios 1.000, residual "
              f"{R['rms']:.3f}, defaults reproduced within 0.01)")
    return 0


if __name__ == '__main__':
    sys.exit(main())
