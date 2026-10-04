#!/usr/bin/env python3
"""B visibility check: does one press of B change the picture, everywhere?

    python3 tools/check_verbs.py [--wasm W] [--out DIR] [--min PX] [--kinds bus,heap,...]

For every segment kind (the Bus and the six districts) it presses B once at
three local rows (early, middle, late) on two flight lines (the centre line,
and one steered 24 cells off it), in manual flight, and compares the frames
after the press with the same flight without the press. Flight is identical
in both runs: Start at tick 90 turns the autopilot off, and a Start pair
every 300 ticks keeps the idle timer from turning it back on (a press of B
does not move the camera). The score of one press is the most pixels that
differ in one frame above the caption (rows 0..109) over the 45 frames after
it; a press passes at --min pixels (default 1200, about 7% of the view).
debug_b_last tells whether the district took the press. Also reports the
share of presses taken when B is pressed every 12 ticks.

Exit 0 when every press passes, 1 otherwise. Runs preview.mjs in parallel.
"""
import argparse, json, os, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
CART = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(CART))
KINDS = ['bus', 'heap', 'sort', 'tree', 'hash', 'stack', 'pipeline']
TICKS = 2300  # one Bus + district of every kind after the boot segment
WINDOW = 45
CAPTION_Y = 110


def script(offset, extra=()):
    s = [{'from': 90, 'to': 90, 'hold': ['START']}]
    if offset:
        s.append({'from': 100, 'to': 100 + offset, 'hold': ['RIGHT']})
    for k in range(300, TICKS, 300):
        s += [{'from': k, 'to': k, 'hold': ['START']}, {'from': k + 2, 'to': k + 2, 'hold': ['START']}]
    return s + list(extra)


def run(wasm, out, sc, frames, quiet=False, sample=None):
    os.makedirs(out, exist_ok=True)
    path = os.path.join(out, 'script.json')
    json.dump(sc, open(path, 'w'))
    cmd = ['node', os.path.join(ROOT, 'tools', 'preview.mjs'), wasm, '--frames', str(frames),
           '--script', path, '--out', out, '--every', '1']
    if quiet:
        cmd.append('--quiet')
    if sample:
        cmd += ['--sample', sample]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return json.load(open(os.path.join(out, 'frames.json')))


def frame(out, t):
    from PIL import Image
    return Image.open(os.path.join(out, 'frame_%04d.png' % t)).convert('RGB').tobytes()


def changed(a, b):
    n = 0
    for i in range(0, 160 * CAPTION_Y * 3, 3):
        if a[i:i + 3] != b[i:i + 3]:
            n += 1
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--wasm', default=os.path.join(ROOT, 'zig-out', 'bin', 'snouty-flyover.wasm'))
    ap.add_argument('--out', default=None)
    ap.add_argument('--min', type=int, default=1200)
    ap.add_argument('--kinds', default=','.join(KINDS))
    ap.add_argument('--offsets', default='0,24')
    args = ap.parse_args()
    kinds = args.kinds.split(',')
    out = args.out or tempfile.mkdtemp(prefix='check_verbs_')
    offsets = [int(o) for o in args.offsets.split(',')]

    # Baselines: one per flight line, PNGs every frame, with the segment trace.
    base = {}
    with ThreadPoolExecutor() as ex:
        futs = {o: ex.submit(run, args.wasm, os.path.join(out, 'base_%d' % o), script(o), TICKS,
                             sample='debug_segment_kind,debug_segment_index,debug_cam_y,debug_cam_x')
                for o in offsets}
        for o, f in futs.items():
            base[o] = f.result()

    # Press ticks: early / middle / late local rows of the first full segment
    # of each kind (the boot segment is skipped).
    jobs = []
    for o in offsets:
        v = base[o]['samples']['values']
        seg_kind, seg_idx = v['debug_segment_kind'], v['debug_segment_index']
        spans = {}
        for t in range(len(seg_kind)):
            if seg_idx[t] == seg_idx[0]:
                continue
            k = KINDS[seg_kind[t]]
            if k in spans and spans[k][2] != seg_idx[t]:
                continue
            s = spans.setdefault(k, [t, t, seg_idx[t]])
            s[1] = t
        for k in kinds:
            if k not in spans:
                print('no %s segment in %d ticks' % (k, TICKS))
                continue
            t0, t1, _ = spans[k]
            if t1 + WINDOW >= TICKS:
                continue
            for name, frac in (('early', 0.12), ('mid', 0.5), ('late', 0.8)):
                t = t0 + int((t1 - t0) * frac)
                jobs.append((o, k, name, t))

    def press(job):
        o, k, name, t = job
        d = os.path.join(out, 'press_%d_%s_%s' % (o, k, name))
        r = run(args.wasm, d, script(o, [{'from': t, 'to': t, 'hold': ['B']}]), t + WINDOW + 1,
                sample='debug_b_last')
        bl = r['samples']['values']['debug_b_last'][-1]
        took = (bl >> 16) > 0 and (bl & 1) == 1
        to = KINDS[(bl >> 8) & 255] if bl >> 16 else '-'
        best = 0
        bo = os.path.join(out, 'base_%d' % o)
        for dt in range(1, WINDOW + 1):
            best = max(best, changed(frame(bo, t + dt), frame(d, t + dt)))
        return (o, k, name, t, to, took, best)

    with ThreadPoolExecutor() as ex:
        results = list(ex.map(press, jobs))

    # Spam: B every 12 ticks on the centre line, share taken per kind.
    spam = run(args.wasm, os.path.join(out, 'spam'),
               script(0, [{'from': t, 'to': t, 'hold': ['B']} for t in range(100, TICKS, 12)]), TICKS,
               quiet=True, sample='debug_b_last')
    took_n, press_n, prev = {}, {}, 0
    for bl in spam['samples']['values']['debug_b_last']:
        if bl >> 16 != prev >> 16:
            k = KINDS[(bl >> 8) & 255]
            press_n[k] = press_n.get(k, 0) + 1
            took_n[k] = took_n.get(k, 0) + (bl & 1)
        prev = bl

    ok = True
    print('%-9s %-6s %4s %6s  %-9s %5s %7s' % ('kind', 'when', 'off', 'tick', 'went to', 'took', 'max px'))
    for (o, k, name, t, to, took, best) in results:
        good = took and to == k and best >= args.min
        ok &= good
        print('%-9s %-6s %4d %6d  %-9s %5s %7d %s' % (k, name, o, t, to, 'yes' if took else 'no', best,
                                                    '' if good else '  FAIL'))
    print()
    print('B every 12 ticks, presses taken:')
    for k in kinds:
        if k in press_n:
            print('  %-9s %2d of %2d' % (k, took_n.get(k, 0), press_n[k]))
    print('\nframes in', out)
    print('check_verbs: %s (min %d px)' % ('PASS' if ok else 'FAIL', args.min))
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
