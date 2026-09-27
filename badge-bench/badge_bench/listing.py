"""Capstone listing of the hottest functions, each instruction annotated with
executions per frame and modelled cycles per frame over the run."""
from . import model as M


def instruction_counts(cs, mu_read, blocks):
    """{address: executions} from per-block counts."""
    out = {}
    for addr, size, _n, _c, count, _t in blocks.values():
        code = mu_read(addr, size)
        if code is None:
            continue
        for i in cs.disasm(code, addr):
            out[i.address] = out.get(i.address, 0) + count
    return out


def function_listing(elf, cs, addr, size, name, counts, nframes, share):
    code = elf.code_bytes(addr, size)
    lines = [f"; {name} @ {addr:#010x}, {size} bytes, {share:.1f}% of the run's modelled cycles"]
    if code is None:
        return lines + ["; (code not in an executable section of the ELF)"]
    lines.append(f"; {'address':8} {'exec/frame':>11} {'cyc/frame':>10}  instruction")
    off = 0
    while off < len(code):
        for i in cs.disasm(code[off:], addr + off):
            c = counts.get(i.address, 0)
            if c:
                cyc = c * M.cycles_of(i, M.base_name(i)) / nframes
                tag = f"{c / nframes:11.2f} {cyc:10.1f}"
            else:
                tag = f"{'':11} {'':10}"
            lines.append(f"  {i.address:08x} {tag}  {i.mnemonic:10} {i.op_str}")
            off += i.size
        if off < len(code):  # literal pool or padding: skip a halfword
            lines.append(f"  {addr + off:08x} {'':11} {'':10}  .short {int.from_bytes(code[off:off + 2], 'little'):#06x}")
            off += 2
    return lines


def listing(elf, hot, blocks, nframes, n=5):
    cs = M.make_cs()
    counts = instruction_counts(cs, elf.code_bytes, blocks)
    total = sum(h['cyc'] for h in hot) or 1
    out = [f"; {elf.path}", f"; top {n} functions by modelled cycles over {nframes} frames;",
           "; exec/frame = executions of the instruction per frame, cyc/frame = its issue",
           "; cycles per frame (taken-branch cycles not included). Inlined callees appear",
           "; inside their caller."]
    chosen = [h for h in hot if h['addr'] is not None][:n]
    for h in chosen:
        i = elf.func_index(h['addr'])
        a, z, name = elf.funcs[i]
        out.append('')
        out += function_listing(elf, cs, a, z, name, counts, max(nframes, 1), h['cyc'] / total * 100)
    return '\n'.join(out) + '\n'
