"""Run a cart ELF from _start under unicorn with the fake OS and cut the
execution into frames.

Frame windows. The SDK's _start (platform_cart_ram.zig) is

    os_align_cycles();  root.start();
    while (true) { _ = cycles(); root.update(); cart_api.present(); }

and cycles() reads DWT_CYCCNT. os_align_cycles reads it once after asking
the OS for the time; the next read is the loop's, just before the first
update(). Every frame boundary is that loop read (same block address each
time), so frame i is exactly one loop iteration: cycles(), update() #i and
the whole present() that follows it (dirty-rect scan, FIFO handshake, the
copy_forward memcpy or clear, buffer swap). This is the same cost as the
window between two present() messages that carts/snouty-reflections/tools/emu
uses, shifted by the tail of present(); unlike that window it gives update
#0 without the cost of start(). start() (and everything before it) is
reported separately.

Controls for update #i are written at boundary i; neopixels, the user LED
and tones are read at boundary i+1; the framebuffer named in present()'s
message is captured when the message is sent.
"""
import struct

from unicorn import (UC_HOOK_BLOCK, UC_HOOK_INTR, UC_HOOK_MEM_FETCH_UNMAPPED,
                     UC_HOOK_MEM_READ_UNMAPPED, UC_HOOK_MEM_WRITE_UNMAPPED, UC_MEM_FETCH_UNMAPPED,
                     UC_MEM_READ_UNMAPPED, UC_MEM_WRITE_UNMAPPED, UcError)
from unicorn import arm_const as A
from unicorn.arm_const import UC_ARM_REG_LR, UC_ARM_REG_PC, UC_ARM_REG_SP

from . import model as M
from . import os_fake as OS
from .elf import BenchError

# Unicorn/QEMU ARM exception numbers seen through UC_HOOK_INTR.
EXCP_NAMES = {1: 'undefined instruction (UDF or unsupported)', 2: 'SVC', 3: 'prefetch abort',
              4: 'data abort', 5: 'IRQ', 6: 'FIQ', 7: 'breakpoint (BKPT)',
              8: 'exception exit', 9: 'kernel trap', 16: 'semihosting',
              17: 'NOCP (coprocessor disabled)', 18: 'INVSTATE (bad Thumb state)',
              19: 'stack limit', 20: 'lazy FP', 21: 'LSERR', 22: 'unaligned access',
              23: 'divide by zero'}


class Crash(Exception):
    def __init__(self, kind, detail, pc=None, addr=None):
        super().__init__(detail)
        self.kind, self.detail, self.pc, self.addr = kind, detail, pc, addr


class Result:
    def __init__(self):
        self.frames = []        # dicts: frame, insn, cyc, taken, ms, presents, controls, ...
        self.startup = None     # dict insn, cyc, ms
        self.crash = None       # dict
        self.hang = None        # dict
        self.traces = []        # (frame, text)
        self.tones = []         # (frame, dict)
        self.volumes = []       # (frame, value)
        self.unknown_msgs = []  # (frame, word)
        self.status_words = []
        self.pngs = {}          # frame -> framebuffer bytes
        self.blocks = {}        # key -> [addr, size, ninsn, cyc, count, taken] over the frames
        self.warnings = []
        self.vsync = None
        self.os = None
        self.scratch = []       # SRAM8/9 accesses (out of bounds of the cart's RAM)


def poke_value(elf, spec):
    """'SYM=VALUE' -> (name, addr, size, value)."""
    if '=' not in spec:
        raise BenchError(f"--poke wants SYM=VALUE, got '{spec}'")
    name, val = spec.split('=', 1)
    name = name.strip()
    addr, size, _t = elf.need(name)
    try:
        v = int(val.strip(), 0)
    except ValueError:
        raise BenchError(f"--poke {spec}: VALUE must be an integer (0x.. allowed)")
    width = size if size in (1, 2, 4) else 4
    return name, addr, width, v & ((1 << (8 * width)) - 1)


def run(elf, frames, controls, pokes=(), seed=1, png_every=0, max_frame_ms=1000.0,
        on_trace=None, log=None):
    """Emulate `frames` updates. controls: list of u16 per frame."""
    res = Result()
    mu = M.make_uc()
    cs = M.make_cs()
    blocks = {}                         # (addr << 16 | size) -> [addr, size, ninsn, cyc, count, taken]
    insn = cyc = taken = 0
    prev_end = None
    cur_block = 0
    max_frame_cyc = int(max_frame_ms * M.CYCLES_PER_MS)
    limit = 10 * max_frame_cyc          # cycle count at which the current window is a hang
    decode_err = []

    class Host:
        phase = 'boot'      # boot -> align -> start -> run
        armed = False
        frame = -1          # frame currently executing (-1 = start-up)
        win = None          # (insn, cyc, taken) at the start of the window
        presents = 0
        present_idx = None
        tone_count = 0
        startup_blocks = None
        stopping = False
        extra_reads = 0

        def cycles(self):
            return cyc

        def current_block(self):
            return cur_block

        def current_frame(self):
            return self.frame

        def on_message(self, kind, *a):
            f = self.frame
            if kind == 'sync':
                self.phase = 'align'
            elif kind == 'trace':
                res.traces.append((f, a[0]))
                if on_trace:
                    on_trace(f, a[0])
            elif kind == 'tone':
                res.tones.append((f, a[0]))
            elif kind == 'volume':
                res.volumes.append((f, a[0]))
            elif kind == 'status':
                res.status_words.append((f, a[0]))
                if a[0] in (OS.CART_FINISHED, OS.CART_CRASHED):
                    res.warnings.append(f"cart sent status word {a[0]:#010x} in frame {f}; stopping")
                    self.stopping = True
                    mu.emu_stop()
            else:
                res.unknown_msgs.append((f, a[0]))

        def on_present(self, flags, legacy=False):
            self.presents += 1
            self.present_idx = flags & 1
            f = self.frame
            if png_every and f >= 0 and f % png_every == 0:
                res.pngs[f] = fake.framebuffer(self.present_idx)
            if self.phase == 'start':
                # No DWT read between start() and the first present: this
                # cart's _start is not the SDK loop. Fall back to present-to-
                # present windows; the start-up window then includes update #0
                # and frame i is update #i+1.
                res.warnings.append("no DWT_CYCCNT read before the first present(); using "
                                    "present-to-present windows, start-up includes update #0 "
                                    "and frame i is update #i+1")
                self.phase = 'present'
                self.boundary()
            elif self.phase == 'present':
                self.boundary()
            elif self.phase == 'run':
                self.armed = True

        def on_cyccnt_read(self):
            if self.phase == 'align':
                self.phase = 'start'           # os_align_cycles' own read
            elif self.phase == 'start':
                # The loop's cycles(), inlined into _start. If this read is
                # outside _start, start() itself read DWT_CYCCNT and frame 0
                # begins too early.
                a, z, _t = elf.syms['_start']
                if not ((a & ~1) <= cur_block < (a & ~1) + z):
                    res.warnings.append(
                        f"first DWT_CYCCNT read after start-up is in {elf.describe_code(cur_block)}, "
                        "not in _start: frame 0 may include the tail of start()")
                self.phase = 'run'
                self.boundary()
            elif self.phase == 'run':
                if self.armed:                 # first read after present(): loop top
                    self.boundary()
                else:
                    self.extra_reads += 1

        def boundary(self):
            """End frame self.frame (if any) and begin the next."""
            nonlocal limit
            self.armed = False
            k = self.frame + 1
            if self.frame < 0:
                res.startup = dict(insn=insn, cyc=cyc, ms=cyc / M.CYCLES_PER_MS)
                res.vsync = fake.vsync()
                self.startup_blocks = {key: (b[4], b[5]) for key, b in blocks.items()}
            else:
                w_insn, w_cyc, w_taken = self.win
                d = cyc - w_cyc
                res.frames.append(dict(
                    frame=self.frame, insn=insn - w_insn, cyc=d, taken=taken - w_taken,
                    ms=d / M.CYCLES_PER_MS, presents=self.presents,
                    fb=self.present_idx, controls=controls[self.frame],
                    neopixels=fake.neopixels(), user_led=fake.user_led(),
                    tones=len(res.tones) - self.tone_count))
                if log:
                    log(res.frames[-1])
            if k >= frames:
                self.stopping = True
                mu.emu_stop()
                return
            fake.set_controls(controls[k])
            self.frame = k
            self.presents = 0
            self.tone_count = len(res.tones)
            self.win = (insn, cyc, taken)
            limit = cyc + max_frame_cyc

    host = Host()
    fake = OS.FakeOS(mu, host, seed=seed)
    res.os = fake

    # ---- load the cart the way the OS does: segments, zeroed .bss, SP, _start
    for vaddr, data, memsz in elf.segments():
        if not (OS.SRAM_BASE <= vaddr and vaddr + memsz <= OS.SRAM_BASE + OS.SRAM_SIZE):
            raise BenchError(f"{elf.path}: PT_LOAD segment at {vaddr:#010x} is outside SRAM; "
                             "is this a RAM cart built with cart_ram.ld?")
        if data:
            mu.mem_write(vaddr, data)
        if memsz > len(data):
            mu.mem_write(vaddr + len(data), bytes(memsz - len(data)))
    if '__bss_start__' in elf.syms and '__bss_end__' in elf.syms:
        b0, b1 = elf.syms['__bss_start__'][0], elf.syms['__bss_end__'][0]
        if b1 > b0:
            mu.mem_write(b0, bytes(b1 - b0))
    fake.init_ipc()
    fake.set_controls(0)
    for name, addr, width, v in pokes:
        mu.mem_write(addr, v.to_bytes(width, 'little'))
    start = elf.need('_start')[0]

    def hook_block(uc, addr, size, _):
        nonlocal insn, cyc, taken, prev_end, cur_block
        key = (addr << 16) | size
        b = blocks.get(key)
        if b is None:
            try:
                n, c = M.decode_block(cs, bytes(uc.mem_read(addr, size)), addr)
            except M.DecodeError as e:
                decode_err.append(str(e))
                uc.emu_stop()
                return
            b = blocks[key] = [addr, size, n, c, 0, 0]
        if addr != prev_end and prev_end is not None:
            cyc += M.TAKEN_EXTRA
            taken += 1
            b[5] += 1
        prev_end = addr + size
        cur_block = addr
        insn += b[2]
        cyc += b[3]
        b[4] += 1
        if cyc > limit:
            uc.emu_stop()

    crash = {}

    def hook_unmapped(uc, access, addr, size, value, _):
        what = {UC_MEM_READ_UNMAPPED: 'read', UC_MEM_WRITE_UNMAPPED: 'write',
                UC_MEM_FETCH_UNMAPPED: 'instruction fetch'}.get(access, f'access {access}')
        crash.update(kind='unmapped', detail=f"{what} of {size} bytes at unmapped {addr:#010x}",
                     addr=addr, access=what)
        return False

    def hook_intr(uc, intno, _):
        crash.update(kind='exception', detail=f"CPU exception {intno}: "
                     f"{EXCP_NAMES.get(intno, 'unknown')}", intno=intno)
        uc.emu_stop()

    mu.hook_add(UC_HOOK_BLOCK, hook_block)
    mu.hook_add(UC_HOOK_MEM_READ_UNMAPPED | UC_HOOK_MEM_WRITE_UNMAPPED | UC_HOOK_MEM_FETCH_UNMAPPED,
                hook_unmapped)
    mu.hook_add(UC_HOOK_INTR, hook_intr)
    mu.reg_write(UC_ARM_REG_SP, OS.STACK_TOP)
    mu.reg_write(UC_ARM_REG_LR, 0xFFFFFFFF)
    prev_end = start & ~1

    uc_err = None
    try:
        mu.emu_start(start | 1, 0xFFFFFFFE)
    except UcError as e:
        uc_err = e
    pc = mu.reg_read(UC_ARM_REG_PC)

    if decode_err:
        raise BenchError(decode_err[0])
    if crash or uc_err is not None:
        c = dict(crash) if crash else dict(kind='unicorn', detail=str(uc_err))
        if uc_err is not None and crash:
            c['unicorn'] = str(uc_err)
        c.update(frame=host.frame, pc=pc, block=cur_block,
                 pc_sym=elf.describe_code(pc & ~1), block_sym=elf.describe_code(cur_block),
                 pc_line=elf.source_line(pc & ~1),
                 lr=mu.reg_read(UC_ARM_REG_LR), sp=mu.reg_read(UC_ARM_REG_SP),
                 regs=[mu.reg_read(getattr(A, f'UC_ARM_REG_R{i}')) for i in range(13)])
        if 'addr' in c:
            c['addr_sym'] = describe_addr(elf, c['addr'])
        res.crash = c
    elif not host.stopping:
        if cyc > limit:
            res.hang = dict(frame=host.frame, pc=pc, block=cur_block,
                            block_sym=elf.describe_code(cur_block), max_frame_ms=max_frame_ms,
                            insn=insn - (host.win[0] if host.win else 0))
        else:
            res.crash = dict(kind='returned', detail="_start returned (LR sentinel reached)",
                             frame=host.frame, pc=pc, block=cur_block,
                             pc_sym=elf.describe_code(pc & ~1), block_sym=elf.describe_code(cur_block))
    if res.startup is None and host.phase != 'run':
        res.warnings.append(f"never reached the update loop (sync phase '{host.phase}', "
                            f"FIFO handshake '{fake.sync_state}')")
    # Per-block counts over the measured frames only (start-up subtracted).
    sb = host.startup_blocks or {}
    for key, b in blocks.items():
        c0, t0 = sb.get(key, (0, 0))
        if b[4] - c0:
            res.blocks[key] = [b[0], b[1], b[2], b[3], b[4] - c0, b[5] - t0]
    for (rw, blk), (n, first, fr) in sorted(fake.scratch_log.items(), key=lambda kv: kv[1][2]):
        res.warnings.append(
            f"cart {rw}s SRAM8/9 scratch above its stack top: {n} accesses from block {blk:#010x} "
            f"({elf.describe_code(blk)}{elf.source_suffix(blk)}), first {first:#010x} in frame {fr}; "
            "on hardware this is OS stack memory: an out-of-bounds access in the cart")
        res.scratch.append(dict(rw=rw, block=blk, count=n, first_addr=first, frame=fr,
                                sym=elf.describe_code(blk), line=elf.source_line(blk)))
    if host.extra_reads:
        res.warnings.append(f"the cart read DWT_CYCCNT {host.extra_reads} times inside update() "
                            "(cart.cycles() or tracy zones); harmless, frames still cut at the loop")
    for (p, off, rw), n in sorted(fake.unknown.items()):
        res.warnings.append(f"unmodelled {p} register {'read' if rw == 'r' else 'write'} at "
                            f"offset {off:#05x} ({n} times); returned 0 / ignored")
    return res


def describe_addr(elf, a):
    if OS.IPC_BASE <= a < OS.IPC_BASE + 2 * OS.FB_SIZE:
        return f"ipc_data.framebuffers[{(a - OS.IPC_BASE) // OS.FB_SIZE}]"
    if OS.IPC_BASE <= a < OS.IPC_END:
        off = a - OS.IPC_BASE
        best = max((o, n) for n, o in OS.IPC_FIELDS.items() if o <= off)
        return f"ipc_data.{best[1]}+{off - best[0]:#x}"
    if OS.SRAM_BASE <= a < OS.SRAM_BASE + OS.SRAM_SIZE:
        return elf.describe_data(a)
    if a < 0x10000000:
        return "low memory (null pointer or small offset from one?)"
    if 0x10000000 <= a < 0x20000000:
        return "XIP flash (not available to RAM carts here)"
    if 0x40000000 <= a < 0x60000000:
        return "APB/AHB peripheral not faked by badge-bench"
    if 0xD0000000 <= a < 0xE0000000:
        return "SIO outside the faked page"
    if a >= 0xE0000000:
        return "private peripheral bus (not faked)"
    return "unmapped"
