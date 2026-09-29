#!/usr/bin/env python3
"""Driver for the emulated cycle benchmark; run it through tools/emu/run.sh,
which builds build/bench.elf and bootstraps the venv first.

  default   bench ELF frames 0 and 300, reference check, summary table,
            per-class pixel costs
  --sweep   also frames 0..575 step 25 (the whole orbit), min/max/worst
  --real    also the real cart ELF (zig-out/firmware/snouty-reflections.elf
            at the repository root, needs `zig build` there), same frames,
            same checks
  --listing annotated capstone listings and codegen categories of frame 0

Outputs go to tools/emu/out/ (sweep frames in out/sweep/); the printed
report is also saved as out/summary.txt. Exit status 3 if a frame 0/300
reference check fails.
"""
import argparse
import datetime
import os
import shutil
import subprocess
import sys
import time

import bench
import categorize
import classes_report
import classify
import disasm
import model as M
import real

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))  # this cart, carts/snouty-reflections
MONO = os.path.dirname(os.path.dirname(REPO))  # repository root, where zig build writes zig-out/
BENCH_ELF = os.path.join(HERE, 'build', 'bench.elf')
REAL_ELF = os.path.join(MONO, 'zig-out', 'firmware', 'snouty-reflections.elf')
# M2.1 variant the bench ELF is built as (build.sh reads the same variable) and
# its orbit length: one orbit is 30 s at every frame rate.
VARIANT = os.environ.get('EMU_VARIANT', 'cut20')
ORBIT = 30 * {'full20': 20, 'cut20': 20, 'full15': 15, 'half30': 30}[VARIANT]
CHECK_FRAMES = [0, ORBIT // 2]
SWEEP_FRAMES = list(range(0, ORBIT, ORBIT // 24))


def reference(frames, out):
    cmd = [sys.executable, os.path.join(REPO, 'tools', 'reference.py')]
    for f in frames:
        cmd += ['--frame', str(f)]
    p = subprocess.run(cmd + ['--variant', VARIANT, '--out', out], capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit(f"emu: tools/reference.py failed:\n{p.stdout}{p.stderr}")


def check(png, ref, diff):
    """Run tools/check_render.mjs; return (passed, one-line summary)."""
    p = subprocess.run(['node', os.path.join(REPO, 'tools', 'check_render.mjs'), png, ref, '--diff', diff],
                       capture_output=True, text=True)
    if p.returncode not in (0, 3):
        raise SystemExit(f"emu: check_render failed to run on {png}:\n{p.stdout}{p.stderr}")
    lines = p.stdout.strip().splitlines()
    verdict = lines[-1] if lines else '?'
    detail = next((l.strip() for l in lines if 'max difference' in l), '')
    return p.returncode == 0, f"{verdict}  ({detail})" if detail else verdict


def rel(path):
    return os.path.relpath(path, REPO)


def table(results):
    head = (f"  {'run':5} {'frame':>5} {'insns/frame':>12} {'cycles/frame':>13} {'cyc/px':>7} "
            f"{'ms@150MHz':>9} {'fps':>6} {'vdiv/px':>7} {'vsqrt/px':>8}  check")
    lines = [head]
    for r in results:
        lines.append(f"  {r['kind']:5} {r['frame']:5} {r['insn']:12,} {r['cyc']:13,} {r['cyc_px']:7.1f} "
                     f"{r['ms']:9.2f} {r['fps']:6.1f} {r['vdiv_px']:7.2f} {r['vsqrt_px']:8.2f}  {r.get('check', '')}")
    return lines


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--sweep', action='store_true', help='also run the orbit sweep (frames 0..575 step 25)')
    ap.add_argument('--real', action='store_true', help='also run the real cart ELF (needs zig build)')
    ap.add_argument('--listing', action='store_true', help='write annotated listings to out/')
    ap.add_argument('--mode', choices=['none', 'bayer'], default='none',
                    help='dither mode (default none, which is what the reference matches)')
    a = ap.parse_args()

    out = os.path.join(HERE, 'out')
    os.makedirs(out, exist_ok=True)
    if a.real and not os.path.exists(REAL_ELF):
        raise SystemExit(f"emu: {rel(REAL_ELF)} not found; run `zig build` in the repo root first")
    t_start = time.time()
    report = [f"emulated cycle benchmark, {datetime.datetime.now().isoformat(timespec='seconds')}",
              f"  bench ELF {rel(BENCH_ELF)}"]
    real_elf = os.path.join(out, 'real.elf')
    if a.real:
        # Snapshot it: a rebuild during the run must not mix two binaries.
        mtime = datetime.datetime.fromtimestamp(os.path.getmtime(REAL_ELF)).isoformat(timespec='seconds')
        shutil.copyfile(REAL_ELF, real_elf)
        report.append(f"  real ELF  {rel(REAL_ELF)} (built {mtime}, snapshot {rel(real_elf)})")
    report.append(f"  dither mode {a.mode}; model: see tools/emu/README.md")

    print(f"emu: bench ELF, frames {CHECK_FRAMES}")
    results = bench.run(BENCH_ELF, CHECK_FRAMES, out, a.mode)
    if a.real:
        print(f"emu: real ELF, frames {CHECK_FRAMES}")
        results += real.run(real_elf, CHECK_FRAMES, out, a.mode)

    print("emu: reference check")
    reference(CHECK_FRAMES, out)
    failed = []
    for r in results:
        ref = os.path.join(out, f"ref_{r['frame']:04d}.png")
        ok, line = check(r['png'], ref, os.path.join(out, f"diff_{r['kind']}_{r['frame']:04d}.png"))
        r['check'] = line.split()[0]
        print(f"  {r['kind']} {r['frame']:04d}: {line}")
        if not ok:
            failed.append(f"{r['kind']} {r['frame']}")

    print("emu: classifying ray paths")
    class_tables = []
    for f in CHECK_FRAMES:
        classify.classify(f, out)
        class_tables.append(classes_report.report(f, out))

    sweep_lines = []
    if a.sweep:
        sw = os.path.join(out, 'sweep')
        os.makedirs(sw, exist_ok=True)
        reference(SWEEP_FRAMES, sw)
        kinds = [('emu', bench.run, BENCH_ELF)] + ([('real', real.run, real_elf)] if a.real else [])
        for kind, fn, elf in kinds:
            print(f"emu: {kind} sweep, frames 0..575 step 25")
            rs = fn(elf, SWEEP_FRAMES, sw, a.mode, quiet=True)
            bad = []
            for r in rs:
                ok, line = check(r['png'], os.path.join(sw, f"ref_{r['frame']:04d}.png"),
                                 os.path.join(sw, f"diff_{kind}_{r['frame']:04d}.png"))
                r['check'] = line.split()[0]
                if not ok:
                    bad.append(r['frame'])
            lo = min(rs, key=lambda r: r['cyc'])
            hi = max(rs, key=lambda r: r['cyc'])
            sweep_lines += [f"orbit sweep, {kind} ELF ({len(rs)} frames):"] + table(rs)
            sweep_lines.append(f"  {kind}: min {lo['cyc_px']:.1f} cyc/px (frame {lo['frame']}), "
                               f"max {hi['cyc_px']:.1f} cyc/px = {hi['ms']:.2f} ms (worst frame {hi['frame']}); "
                               f"reference check {len(rs) - len(bad)}/{len(rs)} PASS"
                               + (f", FAIL at {bad} (informational)" if bad else ""))

    listing_lines = []
    if a.listing:
        runs = [('emu', BENCH_ELF, os.path.join(out, 'addr_0000.json'))]
        if a.real:
            runs.append(('real', real_elf, os.path.join(out, 'real_addr_0000.json')))
        for kind, elf, counts in runs:
            lst = os.path.join(out, f'listing_{kind}_0000.lst')
            with open(lst, 'w') as fh:
                fh.write(disasm.listing(elf, counts))
            cat = categorize.categorize(elf, counts)
            with open(os.path.join(out, f'categories_{kind}_0000.txt'), 'w') as fh:
                fh.write(cat + '\n')
            listing_lines += [f"listing: {rel(lst)}", cat]

    report += [""] + ["summary (modelled Cortex-M33 cycles; fps is uncapped, the cart locks to 20):"] + table(results)
    report += [""] + class_tables
    if sweep_lines:
        report += [""] + sweep_lines
    if listing_lines:
        report += [""] + listing_lines
    report.append("")
    report.append(f"done in {time.time() - t_start:.0f} s; outputs in {rel(out)}/")
    text = '\n'.join(report)
    print()
    print(text)
    with open(os.path.join(out, 'summary.txt'), 'w') as fh:
        fh.write(text + '\n')
    if failed:
        print(f"emu: reference check FAILED for {', '.join(failed)}", file=sys.stderr)
        sys.exit(3)


if __name__ == '__main__':
    main()
