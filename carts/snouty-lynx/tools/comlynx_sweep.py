#!/usr/bin/env python3
"""Latency sweep of a ComLynx game on the virtual bus (docs/COMLYNX.md 5).

    python3 carts/snouty-lynx/tools/comlynx_sweep.py [--consoles 2,4]
        [--modes wire,relay,timestamped] [--echo local|bus|mode]
        [--batch frame] [--ms 0,1,2,4,8,16,33,50,100,150] [--updates 3000]
        [--rom ~/roms/lynx/Warbirds.lnx] [--out out/comlynx-sweep]

from the repository root. Runs `zig build run-lynx-link` once per point
(N consoles, each switched on 7 frames after the one before, each with
tools/scripts/warbirds_link.json: A at 500 to leave the title, A at 600 to
accept the options board) and reads the frames it writes every 30
updates. Per point it prints, per console: the player count Warbirds shows
on its title last ("N PLAYERS", read from the glyph; '-' = played alone), the
update at which it first shows the cockpit ('-' = never: no game), and
the ComLynx frames it sent in the last 10 s. A point passes when every
console shows N PLAYERS and reaches the cockpit. Warbirds-specific probes
(pixel colours of its title and cockpit); Adrian's dump is never in the
repository. `--ms` is the one-way latency (wire, relay) or D (timestamped).
"""
import argparse, glob, os, re, subprocess, sys
from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
SCRIPT = os.path.join(ROOT, 'carts/snouty-lynx/tools/scripts/warbirds_link.json')
ORANGE = (255, 68, 0)      # "N PLAYERS" on the title
WING = (221, 0, 0)         # the cockpit's top wing, rows 0-3

def glyph_digit(px):
    mask = [(x, y) for x in range(90, 160) for y in range(88, 102) if px[x, y] == ORANGE]
    if not mask:
        return None
    x0 = min(x for x, _ in mask)
    y0 = min(y for _, y in mask)
    g = frozenset((x - x0, y - y0) for x, y in mask if x - x0 < 7)
    return GLYPHS.get(g, '?')

GLYPHS = {}

def probe(path):
    px = Image.open(path).convert('RGB').load()
    cockpit = px[0, 1] == WING and px[159, 1] == WING
    return cockpit, glyph_digit(px)

def run_point(a, n, mode, ms, out, stagger):
    os.makedirs(out, exist_ok=True)
    for f in glob.glob(out + '/*.ppm'):
        os.remove(f)
    us = int(ms * 1000)
    args = ['zig', 'build', 'run-lynx-link', '--', os.path.expanduser(a.rom), str(n), str(a.updates), out,
            '--mode', mode, '--batch', a.batch, '--every', '30', '--quiet', '--stagger', str(stagger)]
    args += ['--delay-us', str(us)] if mode == 'timestamped' else ['--latency-us', str(us)]
    if a.echo != 'mode':
        args += ['--echo', a.echo]
    for i in range(n):
        args += ['--script', str(i), SCRIPT]
    r = subprocess.run(args, capture_output=True, text=True, cwd=ROOT)
    if r.returncode != 0:
        sys.exit(r.stderr)
    lines = r.stdout.splitlines()
    sent = {}
    for ln in lines:
        m = re.match(r'update (\d+) c(\d+) .* sent (\d+) ', ln)
        if m:
            sent.setdefault(int(m.group(2)), []).append((int(m.group(1)), int(m.group(3))))
    rows = []
    for i in range(n):
        first = None
        digit = None
        for f in sorted(glob.glob(f'{out}/c{i}_*.ppm')):
            u = int(f[-8:-4])
            c, d = probe(f)
            if c and first is None:
                first = u
            if d:
                digit = d
        s = [v for u, v in sent.get(i, []) if u >= a.updates - 601]
        rows.append((digit, first, (s[-1] - s[0]) if len(s) > 1 else 0))
    return rows, lines[-1].replace('summary: ', '')

def calibrate(a):
    # The digit glyphs from wire-mode runs of 2, 3 and 4 consoles.
    for n in (2, 3, 4):
        out = os.path.join(ROOT, a.out, f'glyph{n}')
        os.makedirs(out, exist_ok=True)
        args = ['zig', 'build', 'run-lynx-link', '--', os.path.expanduser(a.rom), str(n), '420', out, '--at', '390', '--every', '0', '--quiet']
        subprocess.run(args, capture_output=True, text=True, cwd=ROOT, check=True)
        px = Image.open(f'{out}/c0_0390.ppm').convert('RGB').load()
        mask = [(x, y) for x in range(90, 160) for y in range(88, 102) if px[x, y] == ORANGE]
        x0 = min(x for x, _ in mask)
        y0 = min(y for _, y in mask)
        GLYPHS[frozenset((x - x0, y - y0) for x, y in mask if x - x0 < 7)] = str(n)

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--consoles', default='2,4')
    p.add_argument('--modes', default='wire,relay,timestamped')
    p.add_argument('--echo', default='mode')
    p.add_argument('--batch', default='frame')
    p.add_argument('--ms', default='0,1,2,4,8,16,33,50,100,150')
    p.add_argument('--updates', type=int, default=3000)
    p.add_argument('--rom', default='~/roms/lynx/Warbirds.lnx')
    p.add_argument('--out', default='out/comlynx-sweep')
    p.add_argument('--staggers', default='7,23,41', help='power-on spacing per trial (frames)')
    a = p.parse_args()
    calibrate(a)
    for n in [int(x) for x in a.consoles.split(',')]:
        for mode in a.modes.split(','):
            for ms in [float(x) for x in a.ms.split(',')]:
                passes = 0
                trials = []
                for st in [int(x) for x in a.staggers.split(',')]:
                    rows, summ = run_point(a, n, mode, ms, os.path.join(ROOT, a.out, f'{mode}-{n}-{ms:g}-{st}'), st)
                    ok = all(d == str(n) and f is not None for d, f, _ in rows)
                    passes += ok
                    trials.append(' '.join(f"{d or '-'}/{f if f is not None else '-'}" for d, f, _ in rows))
                print(f"{n} {mode:11s} echo={a.echo:5s} batch={a.batch:5s} {ms:6g} ms  {passes}/{len(trials)}  " + ' | '.join(trials), flush=True)

if __name__ == '__main__':
    main()
