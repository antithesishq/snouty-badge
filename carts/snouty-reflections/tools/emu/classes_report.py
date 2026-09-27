#!/usr/bin/env python3
"""Per-class pixel costs: joins pixels_FFFF.json (bench.py) with
classes_FFFF.json (classify.py). Row y=0 of each column also carries the
per-column setup, so it is excluded from the class means and reported
separately.

usage: .venv/bin/python classes_report.py [--out out/] FRAME...
"""
import argparse
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
N, COL = 160 * 128, 128


def report(frame, out):
    px = json.load(open(os.path.join(out, f'pixels_{frame:04d}.json')))
    cl = json.load(open(os.path.join(out, f'classes_{frame:04d}.json')))
    agg = {}
    for k, lab in enumerate(cl):
        if k % COL == 0:
            continue
        agg.setdefault(lab, []).append((px['insn'][k], px['cyc'][k], k))
    tot = sum(px['cyc'])
    lines = [f"per-class pixel cost, bench frame {frame} (modelled cycles; y=0 excluded; sum over pixels {tot:,})",
             f"  {'class':22} {'pixels':>6} {'share':>6} {'insn':>7} {'cyc':>7} {'min':>5} {'max':>5} {'% frame':>8}  example(x,y)"]
    for lab, v in sorted(agg.items(), key=lambda kv: -len(kv[1])):
        n = len(v)
        i = sum(a for a, _, _ in v) / n
        c = sum(b for _, b, _ in v) / n
        ex = v[n // 2][2]
        lines.append(f"  {lab:22} {n:6} {n / N * 100:5.1f}% {i:7.1f} {c:7.1f} {min(b for _, b, _ in v):5} "
                     f"{max(b for _, b, _ in v):5} {sum(b for _, b, _ in v) / tot * 100:7.1f}%  ({ex // COL},{ex % COL})")
    y0 = [px['cyc'][k] for k in range(0, N, COL)]
    lines.append(f"  y=0 pixels mean {sum(y0) / len(y0):.1f} cyc (includes column setup); "
                 f"after last store: {px['tail'][0]} insns, {px['tail'][1]} cyc")
    return '\n'.join(lines)


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default=os.path.join(HERE, 'out'))
    ap.add_argument('frames', type=int, nargs='*', default=[0, 300])
    a = ap.parse_args()
    for f in a.frames:
        print(report(f, a.out))
