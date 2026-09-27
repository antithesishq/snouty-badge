"""Text and JSON reports: per-frame table, statistics, hot functions."""
import math

from . import classes as K
from . import model as M
from . import os_fake as OS
from .script import names


def percentile(sorted_vals, p):
    """Nearest-rank percentile of an ascending list."""
    if not sorted_vals:
        return 0.0
    k = max(1, math.ceil(p / 100.0 * len(sorted_vals)))
    return sorted_vals[k - 1]


def stats(frames, budget_ms, key='ms'):
    """Summary of the per-frame `key` milliseconds ('ms', or 'busy_ms' when
    calibrated)."""
    if not frames:
        return None
    ms = [f[key] for f in frames]
    s = sorted(ms)
    rank = (lambda f: f['cyc']) if key == 'ms' else (lambda f: f[key])
    worst = max(frames, key=rank)
    best = min(frames, key=rank)
    over = [f['frame'] for f in frames if f[key] > budget_ms]
    mean = sum(ms) / len(ms)
    return dict(
        frames=len(frames), min_ms=best[key], min_frame=best['frame'], mean_ms=mean,
        p95_ms=percentile(s, 95), max_ms=worst[key], worst_frame=worst['frame'],
        mean_insn=sum(f['insn'] for f in frames) / len(frames),
        mean_cyc=sum(f['cyc'] for f in frames) / len(frames),
        max_cyc=worst['cyc'], max_insn=worst['insn'],
        budget_ms=budget_ms, over_budget=len(over), first_over=over[0] if over else None,
        verdict=verdict(mean, percentile(s, 95), worst['ms'], budget_ms))


def verdict(mean, p95, mx, budget):
    if mx <= 0.8 * budget:
        return f"comfortably under budget (worst frame uses {mx / budget * 100:.0f}%)"
    if mx <= budget:
        return f"under budget, little headroom (worst frame uses {mx / budget * 100:.0f}%)"
    if p95 <= budget:
        return "borderline: a few frames over budget (p95 under)"
    if mean <= budget:
        return "borderline: mean under budget, p95 over"
    return f"over budget (mean is {mean / budget * 100:.0f}% of budget)"


def hot_functions(elf, blocks, nframes):
    """[(name, cycles, insns, entries)] sorted by cycles, from per-block counts.
    A block is charged to the sized function containing its first
    instruction; the taken-branch cycle goes to the block entered."""
    acc = {}
    for addr, size, n, c, count, taken, _m in blocks.values():
        i = elf.func_index(addr)
        if i is not None:
            fa, _z, name = elf.funcs[i]
        else:
            fa, name = None, f"[outside any function: {elf.describe_code(addr)}]"
        a = acc.setdefault(name, [0, 0, 0, fa, 0])
        a[0] += c * count + taken * M.TAKEN_EXTRA
        a[1] += n * count
        if fa is not None and addr == fa:
            a[2] += count
        a[4] += taken
    out = [dict(name=k, cyc=v[0], insn=v[1], entries=v[2], addr=v[3],
                cyc_per_frame=v[0] / max(nframes, 1), taken=v[4]) for k, v in acc.items()]
    out.sort(key=lambda d: -d['cyc'])
    return out


def add_mix(elf, hot, blocks, top=50):
    """Give the first `top` hot entries `mnemonics` ({base name: executions
    over the run}) and `class_cyc` ({model class: modelled issue cycles over
    the run}, taken-branch cycles not included) from the counted blocks."""
    want = {h['name']: h for h in hot[:top]}
    for h in want.values():
        h['mnemonics'], h['class_cyc'] = {}, {}
    cs = M.make_cs()
    for addr, size, _n, _c, count, _t, _m in blocks.values():
        i = elf.func_index(addr)
        name = elf.funcs[i][2] if i is not None else f"[outside any function: {elf.describe_code(addr)}]"
        h = want.get(name)
        if h is None:
            continue
        code = elf.code_bytes(addr, size)
        if code is None:
            continue
        mn, cc = h['mnemonics'], h['class_cyc']
        for ins in cs.disasm(code, addr):
            m = M.base_name(ins)
            mn[m] = mn.get(m, 0) + count
            k = K.classify(m)
            cc[k] = cc.get(k, 0) + M.cycles_of(ins, m) * count
    for h in want.values():
        h['mnemonics'] = dict(sorted(h['mnemonics'].items(), key=lambda kv: -kv[1]))
        h['class_cyc'] = {k: h['class_cyc'][k] for k in K.CLASSES if k in h['class_cyc']}


def fmt_frame_row(f, budget_ms):
    ms = f['ms']
    fps = 1000.0 / ms if ms else float('inf')
    tag = 'OVER' if ms > budget_ms else 'ok'
    return (f"{f['frame']:6d} {f['insn']:12,d} {f['cyc']:12,d} {ms:8.2f} {fps:7.1f}  "
            f"{tag:<4} {names(f['controls'])}")


def fmt_frame_row_cal(f, budget_ms):
    ms, busy = f['ms'], f['busy_ms']
    fps = 1000.0 / busy if busy else float('inf')
    tag = 'OVER' if busy > budget_ms else 'ok'
    return (f"{f['frame']:6d} {f['insn']:12,d} {f['cyc']:12,.0f} {ms:8.2f} {busy:8.2f} {fps:7.1f}  "
            f"{tag:<4} {names(f['controls'])}")


def text(meta, res, st, hot, every, top, show_symbols):
    L = []
    L.append(f"badge-bench: {meta['elf']}  (sha256 {meta['sha256'][:12]})")
    L.append(f"  frames {meta['frames']}, script {meta['script'] or 'none'}"
             + (f", press {' '.join(meta['press'])}" if meta['press'] else '')
             + (f", pokes {' '.join(meta['pokes'])}" if meta['pokes'] else '')
             + f", seed {meta['seed']}" + (f", config {meta['config']}" if meta['config'] else ''))
    if meta.get('note'):
        L.append(f"  note: {meta['note']}")
    cal = meta.get('calibration')
    if cal:
        L.append(f"  calibrated: {cal['file']} (fitted {cal['date']}, residual "
                 f"{cal['residual_rms']:.3f} cycles/op)")
    if res.vsync:
        fl, vms = res.vsync
        L.append(f"  cart asks for vsync {'on' if fl & 1 else 'off'}"
                 + (f", {vms:.2f} ms/frame" if fl & 1 and vms else '')
                 + f"; budget {meta['budget_ms']:g} ms at {M.CLOCK_HZ / 1e6:g} MHz (modelled)")
    if res.startup:
        s = res.startup
        L.append(f"  start-up (reset to the first update): {s['insn']:,} insns, "
                 + (f"{s['cyc']:,.0f}" if isinstance(s['cyc'], float) else f"{s['cyc']:,}")
                 + f" cycles, {s['ms']:.2f} ms")
    L.append('')
    if res.frames:
        if cal:
            L.append(f"{'frame':>6} {'insns':>12} {'cycles':>12} {'idle ms':>8} {'busy ms':>8} "
                     f"{'fps':>7}  {'':4} input")
        else:
            L.append(f"{'frame':>6} {'insns':>12} {'cycles':>12} {'ms':>8} {'fps':>7}  {'':4} input")
        worst = st['worst_frame'] if st else None
        shown = 0
        for f in res.frames:
            if f['frame'] % every == 0 or f['frame'] == worst:
                row = (fmt_frame_row_cal if cal else fmt_frame_row)(f, meta['budget_ms'])
                if f['frame'] == worst:
                    row += '   <- worst'
                L.append(row)
                shown += 1
        if shown < len(res.frames):
            L.append(f"  ({shown} of {len(res.frames)} frames shown: every {every}th and the worst)")
        L.append('')
    if st:
        L.append(f"summary over {st['frames']} frames (update #0..#{st['frames'] - 1}):")
        if cal:
            for label, t in (('idle ms ', st['idle']), ('busy ms ', st)):
                L.append(f"  {label} min {t['min_ms']:.2f} (frame {t['min_frame']})  mean {t['mean_ms']:.2f}"
                         f"  p95 {t['p95_ms']:.2f}  max {t['max_ms']:.2f} (frame {t['worst_frame']})")
            L.append(f"  mean {st['mean_insn']:,.0f} insns, {st['mean_cyc']:,.0f} cycles per frame;"
                     f" worst (busy) {st['max_insn']:,} insns, {st['max_cyc']:,.0f} cycles")
        else:
            L.append(f"  ms/frame  min {st['min_ms']:.2f} (frame {st['min_frame']})  mean {st['mean_ms']:.2f}"
                     f"  p95 {st['p95_ms']:.2f}  max {st['max_ms']:.2f} (frame {st['worst_frame']})")
            L.append(f"  mean {st['mean_insn']:,.0f} insns, {st['mean_cyc']:,.0f} cycles per frame;"
                     f" worst {st['max_insn']:,} insns, {st['max_cyc']:,} cycles")
        L.append(f"  budget {st['budget_ms']:g} ms: {st['over_budget']} of {st['frames']} frames over"
                 + (f" (first: frame {st['first_over']})" if st['first_over'] is not None else '')
                 + f"; worst-case fps {1000.0 / st['max_ms']:.1f}, mean-case fps {1000.0 / st['mean_ms']:.1f}")
        L.append(f"  verdict: {st['verdict']}")
        if cal:
            L.append(f"  (calibrated against hardware on {cal['date']}; residual {cal['residual_rms']:.3f} "
                     f"cycles/op; busy ms adds DMA contention to the first {cal['dma_ms']:g} ms of "
                     "memory traffic)")
        else:
            L.append("  (a model: issue cycles only, zero-wait SRAM, no bus contention; treat as a floor)")
        L.append('')
    # Side channels.
    if res.frames:
        changes, prev = 0, None
        for f in res.frames:
            key = (tuple(f['neopixels']), f['user_led'])
            if key != prev:
                changes += 1
                prev = key
        last = res.frames[-1]
        lit = [f"#{r:02x}{g:02x}{b:02x}" for r, g, b in last['neopixels']]
        L.append(f"neopixels/user LED: {changes} distinct states over the run; last "
                 f"{' '.join(lit)} LED {'on' if last['user_led'] else 'off'}")
    if res.tones:
        fr = sorted({f for f, _ in res.tones})
        t0 = res.tones[0][1]
        L.append(f"tones: {len(res.tones)} CART_TONE messages on {len(fr)} frames (first frame {fr[0]}: "
                 f"{t0['freq']:.0f} Hz, {t0['duration']:.2f}, volume {t0['volume']:.2f})")
    if res.volumes:
        L.append(f"volume: {len(res.volumes)} CART_VOLUME messages, last {res.volumes[-1][1]:.2f}")
    if res.traces:
        L.append(f"traces: {len(res.traces)} CART_TRACE messages (see above / --json)")
    if res.unknown_msgs:
        L.append(f"unknown FIFO words: {len(res.unknown_msgs)}, first {res.unknown_msgs[0][1]:#010x} "
                 f"in frame {res.unknown_msgs[0][0]}")
    for w in res.warnings:
        L.append(f"warning: {w}")
    if show_symbols and hot:
        total = sum(h['cyc'] for h in hot) or 1
        L.append('')
        L.append(f"hot functions over {len(res.frames)} frames (cycles charged to the function "
                 "containing the PC; inlined code counts in its caller):")
        L.append(f"  {'%':>5} {'cycles/frame':>13} {'insns/frame':>12} {'calls/frame':>11}  function")
        nf = max(len(res.frames), 1)
        for h in hot[:top]:
            L.append(f"  {h['cyc'] / total * 100:5.1f} {h['cyc'] / nf:13,.0f} {h['insn'] / nf:12,.0f}"
                     f" {h['entries'] / nf:11.1f}  {h['name']}")
        if len(hot) > top:
            rest = sum(h['cyc'] for h in hot[top:])
            L.append(f"  {rest / total * 100:5.1f} {rest / nf:13,.0f} {'':12} {'':11}  "
                     f"({len(hot) - top} more functions)")
    if res.crash:
        L.append('')
        L.extend(crash_lines(res.crash))
    if res.hang:
        h = res.hang
        L.append('')
        L.append(f"HANG: frame {h['frame']} ran past {h['max_frame_ms']:g} modelled ms without "
                 f"finishing (no present() + loop); last block {h['block']:#010x} in {h['block_sym']}")
    return '\n'.join(L) + '\n'


def crash_lines(c):
    where = 'start-up' if c.get('frame', -1) < 0 else f"frame {c['frame']}"
    L = [f"CRASH in {where}: {c['detail']}"]
    L.append(f"  pc {c['pc']:#010x} ({c['pc_sym']}); last block {c['block']:#010x} ({c['block_sym']})")
    if c.get('pc_line'):
        L.append(f"  source {c['pc_line']}")
    if 'addr' in c:
        L.append(f"  faulting address {c['addr']:#010x}: {c['addr_sym']}")
    if 'lr' in c:
        L.append(f"  lr {c['lr']:#010x}, sp {c['sp']:#010x}")
    if 'regs' in c:
        r = c['regs']
        L.append('  ' + ' '.join(f"r{i}={r[i]:08x}" for i in range(7)))
        L.append('  ' + ' '.join(f"r{i}={r[i]:08x}" for i in range(7, 13)))
    if c.get('unicorn'):
        L.append(f"  unicorn: {c['unicorn']}")
    return L


def to_json(meta, res, st, hot, top=50):
    return dict(
        meta=meta, summary=st, startup=res.startup,
        vsync=dict(flags=res.vsync[0], frame_ms=res.vsync[1]) if res.vsync else None,
        frames=[dict(f, neopixels=[list(p) for p in f['neopixels']]) for f in res.frames],
        hot=[{k: v for k, v in h.items()} for h in hot[:top]],
        traces=[dict(frame=f, text=t) for f, t in res.traces],
        tones=[dict(frame=f, **t) for f, t in res.tones],
        volumes=[dict(frame=f, volume=v) for f, v in res.volumes],
        unknown_fifo=[dict(frame=f, word=w) for f, w in res.unknown_msgs],
        warnings=res.warnings, scratch_accesses=res.scratch, crash=res.crash, hang=res.hang,
        model=dict(clock_hz=M.CLOCK_HZ, ipc_base=OS.IPC_BASE))
