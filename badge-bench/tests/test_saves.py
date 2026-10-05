#!/usr/bin/env python3
"""Cart saves end to end: lib/save.zig's badge backend (the real raw-mailbox
client, built for the Cortex-M33) against badge-bench's save service.

    .venv/bin/python tests/test_saves.py    (after one ./bench.sh run made .venv; needs zig on PATH)

Builds tests/save_harness/root.zig (C-ABI exports around lib/save.zig) with
zig into a temporary directory (ReleaseSmall, ReleaseSafe and ReleaseFast,
as the carts build), loads it at 0x20040000 into unicorn with
os_fake.FakeOS, and calls the exports the way a cart would call save.*:
the probe, round trips, the flash time charged while the cart is parked
(with PRIMASK set), store rules (unchanged write, rate limit, space,
argument checks, a buffer outside RAM), list, stat, the exit hook, the
JSON file store across two "boots", and --no-saves (stock firmware: the
probe gives up after 250 ms of modelled time, then the answer is cached).
Also unit-tests saves.MemoryStore directly. Exit 0 pass, 1 fail.
"""
import os
import shutil
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.path.dirname(HERE)
REPO = os.path.dirname(BENCH)
sys.path.insert(0, BENCH)

from elftools.elf.elffile import ELFFile  # noqa: E402
from unicorn import UC_HOOK_BLOCK  # noqa: E402
from unicorn.arm_const import (UC_ARM_REG_LR, UC_ARM_REG_PC, UC_ARM_REG_PRIMASK,  # noqa: E402
                               UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3,
                               UC_ARM_REG_SP)

from badge_bench import model as M  # noqa: E402
from badge_bench import os_fake as OS  # noqa: E402
from badge_bench import saves as SV  # noqa: E402

CODES = {0: 'ok', 1: 'Unsupported', 2: 'NotFound', 3: 'NoSpace', 4: 'BadRequest', 5: 'BadBuffer',
         6: 'RateLimited', 7: 'TooBig', 8: 'IoError', 9: 'Busy'}
RET = 0x20050000                 # return sentinel (mapped SRAM, never code)
SCRATCH = 0x20060000             # where the test puts keys, data and outputs
CYC_PER_BLOCK = 200              # the test clock: modelled cycles per executed block

results = []
prefix = ['']                    # the build mode under test


def check(name, got, want):
    ok = got == want
    name = prefix[0] + name
    print(f"{'ok  ' if ok else 'FAIL'} {name}: {got!r}" + ('' if ok else f" (want {want!r})"))
    results.append(ok)
    return ok


MODES = ('ReleaseSmall', 'ReleaseSafe', 'ReleaseFast')   # what the carts build with


def build_harness(out, mode):
    zig = shutil.which('zig') or os.path.expanduser('~/.local/bin/zig')
    if not os.path.exists(zig):
        print("SKIP: zig not found (PATH or ~/.local/bin/zig)")
        sys.exit(0)
    elf = os.path.join(out, f'harness-{mode}.elf')
    cmd = [zig, 'build-exe', '-target', 'thumb-freestanding-eabihf', '-mcpu=cortex_m33',
           '-O' + mode, '-fno-strip', '-fno-entry', '-rdynamic',
           '-T', os.path.join(HERE, 'save_harness', 'harness.ld'),
           '--dep', 'save', '-Mroot=' + os.path.join(HERE, 'save_harness', 'root.zig'),
           '-Msave=' + os.path.join(REPO, 'lib', 'save.zig'),
           '-femit-bin=' + elf, '--cache-dir', os.path.join(out, 'zc'),
           '--global-cache-dir', os.path.join(out, 'zgc')]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        print(p.stderr)
        raise SystemExit("FAIL: zig build of tests/save_harness failed")
    return elf


class Badge:
    """One boot: unicorn + FakeOS + the harness image."""

    def __init__(self, elf_path, store):
        self.mu = M.make_uc()
        self.cyc = 0
        self.stalls = []         # (ms, PRIMASK while parked)
        self.os = OS.FakeOS(self.mu, self, save_store=store)
        with open(elf_path, 'rb') as fh:
            elf = ELFFile(fh)
            for seg in elf.iter_segments():
                if seg['p_type'] == 'PT_LOAD' and seg['p_filesz']:
                    self.mu.mem_write(seg['p_paddr'], seg.data())
            self.sym = {s.name: s['st_value'] for s in elf.get_section_by_name('.symtab').iter_symbols()
                        if s.name.startswith('h_') or s.name.startswith('__bss')}
        b0, b1 = self.sym['__bss_start__'], self.sym['__bss_end__']
        self.mu.mem_write(b0, bytes(b1 - b0))
        self.mu.hook_add(UC_HOOK_BLOCK, self._block)

    # -- FakeOS host interface
    def _block(self, uc, addr, size, _):
        self.cyc += CYC_PER_BLOCK

    def cycles(self):
        return self.cyc

    def wall_ms(self):
        return self.cyc / M.CYCLES_PER_MS

    def stall(self, ms):
        self.stalls.append((ms, self.mu.reg_read(UC_ARM_REG_PRIMASK) & 1))
        self.cyc += int(ms * M.CYCLES_PER_MS)

    def current_block(self):
        return 0

    def current_frame(self):
        return 0

    def on_message(self, kind, *a):
        pass

    def on_present(self, *a, **k):
        pass

    def on_cyccnt_read(self):
        pass

    # -- calls
    def call(self, name, *args):
        regs = [UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3]
        sp = 0x2007F000
        extra = args[4:]
        if extra:
            sp -= 4 * len(extra)
            self.mu.mem_write(sp, b''.join(struct.pack('<I', v) for v in extra))
        for r, v in zip(regs, args):
            self.mu.reg_write(r, v)
        self.mu.reg_write(UC_ARM_REG_SP, sp)
        self.mu.reg_write(UC_ARM_REG_LR, RET | 1)
        self.mu.emu_start(self.sym[name] | 1, RET, count=50_000_000)
        if self.mu.reg_read(UC_ARM_REG_PC) != RET:
            raise SystemExit(f"FAIL: {name} did not return (pc {self.mu.reg_read(UC_ARM_REG_PC):#x})")
        return self.mu.reg_read(UC_ARM_REG_R0)

    def put(self, off, data):
        self.mu.mem_write(SCRATCH + off, bytes(data))
        return SCRATCH + off

    def get(self, off, n):
        return bytes(self.mu.mem_read(SCRATCH + off, n))

    def u32(self, off):
        return struct.unpack('<I', self.get(off, 4))[0]

    # -- save.* in the cart's terms
    def supported(self):
        return bool(self.call('h_supported'))

    def write(self, key, data, src=None):
        k = self.put(0, key)
        s = src if src is not None else self.put(0x100, data)
        return CODES[self.call('h_write', k, len(key), s, len(data))]

    def read(self, key, n):
        k = self.put(0, key)
        r = self.call('h_read', k, len(key), SCRATCH + 0x10000, n, SCRATCH + 0x80)
        return CODES[r], self.u32(0x80) if r == 0 else None, self.get(0x10000, n)

    def delete(self, key):
        return CODES[self.call('h_delete', self.put(0, key), len(key))]

    def stat(self):
        r = self.call('h_stat', SCRATCH + 0x200)
        f = struct.unpack('<8I', self.get(0x200, 32))
        names = ('version', 'region_bytes', 'free_bytes', 'max_blob', 'entries', 'max_entries',
                 'writes_left_now', '_r')
        return CODES[r], dict(zip(names, f))

    def list(self, n):
        r = self.call('h_list', SCRATCH + 0x1000, n, SCRATCH + 0x84)
        rows = []
        for i in range(n):
            kl, key, size = struct.unpack('<I32sI', self.get(0x1000 + 40 * i, 40))
            rows.append((key[:kl].decode(), size))
        return CODES[r], self.u32(0x84), rows


def stall_ms(b):
    return sum(ms for ms, _ in b.stalls)


def test_store_unit():
    s = SV.MemoryStore()
    check("store: unchanged write is free", (s.write(b'k', b'x', 0), s.write(b'k', b'x', 0)),
          ((SV.OK, 110.0), (SV.OK, 0.0)))
    check("store: 4097 bytes = 2 blocks + directory", s.write(b'k', bytes(4097), 0), (SV.OK, 165.0))
    check("store: delete costs one directory block", s.delete(b'k', 0), (SV.OK, 55.0))
    check("store: delete absent", s.delete(b'k', 0), (SV.NOT_FOUND, 0.0))
    s = SV.MemoryStore()
    for i in range(8):
        s.write(b'r', bytes([i]), 0)
    check("store: 9th commit in a burst is rate limited", s.write(b'r', b'z', 0), (SV.RATE_LIMITED, 0.0))
    check("store: 10 s later one token", (s.write(b'r', b'z', 10_000.0), s.write(b'r', b'y', 10_000.0)),
          ((SV.OK, 110.0), (SV.RATE_LIMITED, 0.0)))
    s = SV.MemoryStore(rate_limit=False)
    big = bytes(SV.MAX_BLOB)
    check("store: empty stat", {k: s.stat(0)[k] for k in ('region_bytes', 'free_bytes', 'max_entries')},
          dict(region_bytes=62 * 4096, free_bytes=46 * 4096, max_entries=46))
    s.write(b'b0', big, 0)
    s.write(b'b1', big, 0)
    check("store: 2 x 64 KB leaves 14 blocks for a new key", s.stat(0)['free_bytes'], 14 * 4096)
    check("store: a new 15-block key would break the reserve", s.write(b'b2', bytes(15 * 4096), 0)[0],
          SV.NO_SPACE)
    check("store: 14 blocks fit", s.write(b'b2', bytes(14 * 4096), 0)[0], SV.OK)
    check("store: at the reserve, free_bytes 0", s.stat(0)['free_bytes'], 0)
    check("store: changed same-size overwrite at the reserve", s.write(b'b0', b'\1' + big[1:], 0),
          (SV.OK, 17 * 55.0))
    check("store: growing overwrite at the reserve", s.write(b'b2', bytes(15 * 4096), 0)[0], SV.NO_SPACE)
    check("store: shrinking overwrite", (s.write(b'b2', b'x', 0)[0], s.stat(0)['free_bytes']),
          (SV.OK, 13 * 4096))
    s = SV.MemoryStore(rate_limit=False)
    for i in range(46):
        s.write(b'k%d' % i, b'x', 0)
    check("store: 46 keys, then no_space", (s.stat(0)['entries'], s.stat(0)['free_bytes'],
                                           s.write(b'new', b'y', 0)[0]), (46, 0, SV.NO_SPACE))
    check("store: overwrite with 46 keys", s.write(b'k0', b'changed', 0)[0], SV.OK)


def main():
    test_store_unit()
    tmp = tempfile.mkdtemp(prefix='badge-bench-saves-')
    try:
        for mode in MODES:
            elf = build_harness(tmp, mode)
            prefix[0] = f"[{mode}] "
            badge_tests(elf, tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    n = len(results)
    bad = results.count(False)
    print(f"{n - bad}/{n} passed")
    return 0 if bad == 0 else 1


def badge_tests(elf, tmp):
    # ---- a saves OS
    b = Badge(elf, SV.MemoryStore())
    check("probe answers on the saves OS", b.supported(), True)
    check("probe is cached (one probe request)", (b.supported(), len(b.os.saves.log)), (True, 1))
    check("read of a missing key", b.read(b'boy/TETRIS/1234', 16)[0], 'NotFound')
    data = bytes(range(256)) * 4
    check("write 1 KB", b.write(b'boy/TETRIS/1234', data), 'ok')
    check("1 KB write charges 2 x 55 ms with PRIMASK set", b.stalls, [(110.0, 1)])
    check("PRIMASK restored after write", b.mu.reg_read(UC_ARM_REG_PRIMASK) & 1, 0)
    st, size, got = b.read(b'boy/TETRIS/1234', 2048)
    check("read back: size and bytes", (st, size, got[:1024] == data), ('ok', 1024, True))
    st, size, got = b.read(b'boy/TETRIS/1234', 10)
    check("short read: stored size, first 10 bytes", (st, size, got), ('ok', 1024, data[:10]))
    check("zero-length read gives the size", b.read(b'boy/TETRIS/1234', 0)[:2], ('ok', 1024))
    check("unchanged write costs nothing", (b.write(b'boy/TETRIS/1234', data), stall_ms(b)), ('ok', 110.0))
    check("write 64 KB", b.write(b'big', bytes(SV.MAX_BLOB)), 'ok')
    check("64 KB costs 17 x 55 ms", b.stalls[-1], (17 * 55.0, 1))
    check("too big", b.write(b'big', bytes(SV.MAX_BLOB + 1)), 'TooBig')
    check("empty key", b.write(b'', b'x'), 'BadRequest')
    check("33-byte key", b.write(b'k' * 33, b'x'), 'BadRequest')
    check("control byte in key", b.write(b'a\nb', b'x'), 'BadRequest')
    check("empty blob", b.write(b'k', b''), 'BadRequest')
    check("buffer in flash (not cart RAM) is refused by the OS", b.write(b'k', b'xxxx', src=0x10000000),
          'BadBuffer')
    st, s = b.stat()
    check("stat", (st, s['version'], s['region_bytes'], s['free_bytes'], s['entries'], s['max_entries'],
                   s['max_blob'], s['writes_left_now']),
          ('ok', 1, 62 * 4096, (62 - 1 - 16 - 16) * 4096, 2, 46, 65536, 6))
    st, count, rows = b.list(1)
    check("list into 1 row: 1 written, first key", (st, count, rows), ('ok', 1, [('boy/TETRIS/1234', 1024)]))
    st, count, rows = b.list(4)
    check("list into 4 rows: 2 written", (st, count, rows[1]), ('ok', 2, ('big', 65536)))
    check("delete", (b.delete(b'big'), b.stalls[-1]), ('ok', (55.0, 1)))
    check("delete again", b.delete(b'big'), 'NotFound')
    # 3 commits so far (1 KB, 64 KB, delete): 5 more empty the bucket
    check("5 more commits", [b.write(b'r', bytes([i])) for i in range(5)], ['ok'] * 5)
    check("rate limit after 8 commits", b.write(b'r', b'z'), 'RateLimited')
    b.cyc += int(10_000 * M.CYCLES_PER_MS)
    check("10 s later the next commit goes through", b.write(b'r', b'z'), 'ok')
    # exit hook
    check("exit not requested before watching", b.call('h_exit_requested'), 0)
    check("watchExit", CODES[b.call('h_watch_exit')], 'ok')
    check("exit word registered in cart RAM", OS.SRAM_BASE < b.os.saves.exit_word < OS.CART_RAM_END, True)
    check("still not requested", b.call('h_exit_requested'), 0)
    check("OS requests exit", b.os.saves.request_exit(), True)
    check("exitRequested sees it", b.call('h_exit_requested'), 1)
    b.call('h_exit_ready')
    check("exitReady writes 2", b.os.saves.exit_word_value(), 2)
    check("no unknown FIFO words", b.os.saves.ignored, 0)

    # ---- file store across two boots
    path = os.path.join(tmp, 'saves.json')
    if os.path.exists(path):
        os.remove(path)
    b1 = Badge(elf, SV.FileStore(path))
    b1.write(b'paperclips/game', b'clips=1000')
    b2 = Badge(elf, SV.FileStore(path))
    st, size, got = b2.read(b'paperclips/game', 32)
    check("file store survives a reboot", (st, size, got[:size]), ('ok', 10, b'clips=1000'))

    # ---- stock firmware (--no-saves)
    b = Badge(elf, None)
    t0 = b.cyc
    check("stock firmware: unsupported", b.supported(), False)
    waited = (b.cyc - t0) / M.CYCLES_PER_MS
    check("probe gave up after ~250 ms", 250.0 <= waited < 260.0, True)
    check("one FIFO word sent and ignored", b.os.saves_ignored, 1)
    t0 = b.cyc
    check("cached: second call is instant and sends nothing",
          (b.supported(), b.os.saves_ignored, (b.cyc - t0) / M.CYCLES_PER_MS < 1.0), (False, 1, True))
    check("write on stock firmware", b.write(b'k', b'v'), 'Unsupported')
    check("stat on stock firmware", b.stat()[0], 'Unsupported')
    check("watchExit on stock firmware", CODES[b.call('h_watch_exit')], 'Unsupported')
    check("PRIMASK clear after the probe", b.mu.reg_read(UC_ARM_REG_PRIMASK) & 1, 0)


if __name__ == '__main__':
    sys.exit(main())
