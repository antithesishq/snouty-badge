"""badge-bench command line (see README.md)."""
import argparse
import hashlib
import json
import os
import sys

from . import __version__
from . import config as C
from . import model as M
from . import report as R
from . import run as RUN
from .elf import BenchError, CartElf
from .audio import SAMPLE_RATE as AUDIO_RATE, wav_bytes
from .listing import listing
from .png import write_fb
from .script import controls_table, load_script, parse_press

EXIT_OK, EXIT_SETUP, EXIT_USAGE, EXIT_CRASH, EXIT_HANG = 0, 1, 2, 4, 5

DESCRIPTION = """\
Run a SYCL Badge V2 cart ELF (zig-out/firmware/<cart>.elf) on an emulated
Cortex-M33 with a fake badge OS, count every instruction and report modelled
milliseconds per update() (150 MHz) and where the cycles go.

A model, calibrated against a badge: when calibrate/calibration.toml exists
its fitted per-class costs, FP stall and LCD-DMA contention factor are
applied (idle ms and busy ms per frame). --no-calibrate gives the raw
model: issue cycles only, zero-wait SRAM, no contention, a floor.
"""

EPILOG = """\
exit status: 0 ran all frames; 1 setup error (bad ELF, symbol, script,
config); 2 usage error; 4 the cart crashed (unmapped access or CPU
exception: PC, address and nearest symbol are printed); 5 a frame ran past
--max-frame-ms without presenting (hang).

per-cart defaults: carts/<elf basename>.toml (budget_ms, frames, script,
pokes, press, note, romfs); command-line flags win. --no-config ignores it.
"""


def build_parser():
    ap = argparse.ArgumentParser(prog='badge-bench', description=DESCRIPTION, epilog=EPILOG,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('elf', help='cart ELF built for cart_ram.ld (zig-out/firmware/<cart>.elf)')
    ap.add_argument('--script', metavar='FILE.json',
                    help='button script, preview.mjs format: [{"from":T1,"to":T2,"hold":["A"]}]')
    ap.add_argument('--press', metavar='BTN:T1-T2', action='append', default=None,
                    help='hold BTN for updates T1..T2 inclusive (bare T1-T2 = A); repeatable, '
                         'comma lists allowed')
    ap.add_argument('--frames', type=int, metavar='N', help='updates to run after start() (default 300)')
    ap.add_argument('--every', type=int, default=1, metavar='K',
                    help='show every K-th frame in the table (plus the worst); also the default '
                         '--png stride (default 1)')
    ap.add_argument('--budget-ms', type=float, metavar='MS', help='frame budget (default 16.7)')
    ap.add_argument('--out', metavar='DIR', help='output directory for --png/--listing/--json '
                    '(default out/<cart>)')
    ap.add_argument('--png', nargs='?', type=int, const=0, default=None, metavar='K',
                    help='write DIR/frame_NNNN.png every K-th frame (default K = --every)')
    ap.add_argument('--lcd', action='store_true',
                    help='--png shows the modelled LCD: only each present\'s dirty rect reaches it, '
                         'as on the badge (pixels a .copy_forward cart writes without '
                         'mark_dirty_rect stay off the screen)')
    ap.add_argument('--stack', action='store_true',
                    help='RAM cart: report the stack\'s high-water mark (free RAM painted at load, '
                         'scanned at the end)')
    ap.add_argument('--listing', action='store_true',
                    help='write DIR/listing.lst: annotated disassembly of the top 5 functions')
    ap.add_argument('--symbols', action='store_true', help='print the hot-function table')
    ap.add_argument('--top', type=int, default=20, metavar='N', help='rows in the hot-function table (20)')
    ap.add_argument('--poke', metavar='SYM=VALUE', action='append', default=None,
                    help='write VALUE to global SYM (its size if 1/2/4 bytes, else a u32) after '
                         'loading, before _start; repeatable')
    ap.add_argument('--json', action='store_true', help='write DIR/bench.json (per-frame table, hot list)')
    ap.add_argument('--seed', type=int, default=1, help='seed for cart.rand() (ROSC random bit), default 1')
    ap.add_argument('--max-frame-ms', type=float, default=1000.0, metavar='MS',
                    help='modelled ms after which a frame counts as hung (default 1000)')
    ap.add_argument('--traces', type=int, default=20, metavar='N',
                    help='print at most N cart trace() strings live (default 20; all go to --json)')
    ap.add_argument('--config', metavar='FILE.toml', help='per-cart defaults file (default carts/<cart>.toml)')
    ap.add_argument('--no-config', action='store_true', help='ignore carts/<cart>.toml')
    ap.add_argument('--progress', action='store_true', help='print a line per frame as it finishes')
    ap.add_argument('--flash-cycles', type=int, default=0, metavar='N',
                    help='XIP carts: add N cycles per instruction fetched from the cart flash window '
                         '(default 0, no penalty; calibrate against the OS overlay\'s XIP hit rate)')
    ap.add_argument('--romfs', metavar='IMAGE',
                    help='map this FAT12 image of the badge drive (tools/make_romfs.py, up to 1280 KB) '
                         'read-only at 0x10080000, where carts find ROM files (default: the cart '
                         'toml\'s romfs key)')
    ap.add_argument('--flash-read-cycles', type=int, default=0, metavar='N',
                    help='add N cycles per data load from the romfs image (default 0, no penalty)')
    ap.add_argument('--calibrate', metavar='FILE.toml',
                    help='use the fitted class costs of this calibrate/fit.py calibration file and '
                         'report idle-bus and DMA-busy ms per frame (default: '
                         'calibrate/calibration.toml when it exists)')
    ap.add_argument('--no-calibrate', action='store_true',
                    help='the raw model (default costs, no contention), even if calibrate/calibration.toml exists')
    ap.add_argument('--wav', metavar='FILE.wav',
                    help='write the samples the newer firmware\'s audio mixer consumed from the '
                         'cart\'s stream (8-bit unsigned mono 44,100 Hz WAV, from its '
                         'CART_START_AUDIO on, silence where the ring ran dry); nothing is '
                         'written if the cart never starts audio')
    ap.add_argument('--version', action='version', version=f'badge-bench {__version__}')
    return ap


def main(argv=None):
    ap = build_parser()
    a = ap.parse_args(argv)
    try:
        return _main(a)
    except BenchError as e:
        print(f"badge-bench: error: {e}", file=sys.stderr)
        return EXIT_SETUP
    except KeyboardInterrupt:
        print("badge-bench: interrupted", file=sys.stderr)
        return 130


def _main(a):
    elf = CartElf(a.elf)
    name = os.path.splitext(os.path.basename(a.elf))[0]
    cfg, cfg_path = ({}, None) if a.no_config else C.load(a.elf, a.config)
    frames = a.frames if a.frames is not None else cfg.get('frames', 300)
    budget = a.budget_ms if a.budget_ms is not None else float(cfg.get('budget_ms', 16.7))
    script = a.script if a.script is not None else cfg.get('script')
    press = a.press if a.press is not None else list(cfg.get('press', []))
    pokes_s = a.poke if a.poke is not None else list(cfg.get('pokes', []))
    romfs = a.romfs if a.romfs is not None else cfg.get('romfs')
    if a.flash_read_cycles < 0:
        raise BenchError("--flash-read-cycles must not be negative")
    romfs_img = RUN.load_romfs(romfs) if romfs else None
    if frames < 1:
        raise BenchError("--frames must be at least 1")
    if a.every < 1:
        raise BenchError("--every must be at least 1")
    png_every = 0 if a.png is None else (a.png or a.every)
    out = a.out or os.path.join('out', name)

    entries = load_script(script) if script else []
    for p in press:
        entries += parse_press(p)
    controls = controls_table(frames, entries)
    pokes = [RUN.poke_value(elf, p) for p in pokes_s]

    meta = dict(tool=f'badge-bench {__version__}', elf=a.elf, sha256=hashlib.sha256(elf.raw).hexdigest(),
                frames=frames, script=script, press=press, pokes=pokes_s, seed=a.seed,
                budget_ms=budget, config=cfg_path, note=cfg.get('note'),
                clock_mhz=M.CLOCK_HZ / 1e6, xip=elf.is_xip(), flash_cycles=a.flash_cycles,
                romfs=romfs, romfs_bytes=len(romfs_img) if romfs_img else 0,
                flash_read_cycles=a.flash_read_cycles)

    cal = None
    if a.calibrate and a.no_calibrate:
        raise BenchError("--calibrate and --no-calibrate exclude each other")
    cal_path = a.calibrate or (None if a.no_calibrate or not os.path.isfile(C.DEFAULT_CALIBRATION)
                               else C.DEFAULT_CALIBRATION)
    if cal_path:
        cal = C.load_calibration(cal_path)
        cal['costs'] = M.set_costs(cal['costs'])
        cal['default'] = not a.calibrate
        meta['calibration'] = cal

    printed = [0]

    def on_trace(f, s):
        printed[0] += 1
        if printed[0] <= a.traces:
            print(f"[trace {'start' if f < 0 else f'frame {f}'}] {s}", flush=True)
        elif printed[0] == a.traces + 1:
            print("[trace] (more traces not printed; see --json)", flush=True)

    def progress(f):
        print(f"  frame {f['frame']}: {f['insn']:,} insns, {f['cyc']:,} cycles, {f['ms']:.2f} ms",
              file=sys.stderr, flush=True)

    res = RUN.run(elf, frames, controls, pokes, seed=a.seed, png_every=png_every,
                  max_frame_ms=a.max_frame_ms, on_trace=on_trace,
                  log=progress if a.progress else None, flash_cycles=a.flash_cycles,
                  romfs=romfs_img, flash_read_cycles=a.flash_read_cycles, lcd=a.lcd,
                  keep_audio=bool(a.wav), stack=a.stack)
    if cal:
        add_busy(res.frames, cal)
        st = R.stats(res.frames, budget, key='busy_ms')
        if st:
            st['idle'] = R.stats(res.frames, budget)
    else:
        st = R.stats(res.frames, budget)
    hot = R.hot_functions(elf, res.blocks, len(res.frames)) if (a.symbols or a.listing or a.json) else []
    if a.json:
        R.add_mix(elf, hot, res.blocks)
    txt = R.text(meta, res, st, hot, a.every, a.top, a.symbols)
    print(txt, end='')

    wrote = []
    if png_every or a.listing or a.json:
        os.makedirs(out, exist_ok=True)
    for f, fb in sorted(res.pngs.items()):
        p = os.path.join(out, f'frame_{f:04d}.png')
        write_fb(p, fb)
        wrote.append(p)
    if a.listing and res.frames:
        p = os.path.join(out, 'listing.lst')
        with open(p, 'w') as fh:
            fh.write(listing(elf, hot, res.blocks, len(res.frames)))
        wrote.append(p)
    if a.json:
        p = os.path.join(out, 'bench.json')
        with open(p, 'w') as fh:
            json.dump(R.to_json(meta, res, st, hot), fh, indent=1)
        wrote.append(p)
    if wrote:
        with open(os.path.join(out, 'report.txt'), 'w') as fh:
            fh.write(txt)
        pngs = [w for w in wrote if w.endswith('.png')]
        other = [w for w in wrote if not w.endswith('.png')]
        print(f"wrote {out}/: " + ', '.join(
            ([f"{len(pngs)} PNGs"] if pngs else []) + [os.path.basename(w) for w in other] + ['report.txt']))
    if a.wav:
        if res.audio_stream is None:
            print(f"badge-bench: the cart never sent CART_START_AUDIO; {a.wav} not written")
        else:
            d = os.path.dirname(a.wav)
            if d:
                os.makedirs(d, exist_ok=True)
            with open(a.wav, 'wb') as fh:
                fh.write(wav_bytes(res.audio_stream))
            n = len(res.audio_stream)
            print(f"wrote {a.wav}: {n:,} samples ({n / AUDIO_RATE:.2f} s) at {AUDIO_RATE} Hz, "
                  "8-bit unsigned mono")
    if res.crash:
        return EXIT_CRASH
    if res.hang:
        return EXIT_HANG
    return EXIT_OK


def add_busy(frames, cal):
    """busy ms = idle ms + memory-class cycles x (factor - 1) x the share of
    the frame that overlaps the DMA window (min(1, dma_ms / idle ms))."""
    k = cal['factor'] - 1.0
    for f in frames:
        idle = f['ms']
        share = min(1.0, cal['dma_ms'] / idle) if idle > 0 else 1.0
        f['busy_ms'] = idle + f['mem_cyc'] * k * share / M.CYCLES_PER_MS
