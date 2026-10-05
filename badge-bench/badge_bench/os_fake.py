"""Just enough of the badge OS (core 0) for a cart on core 1.

Everything here mirrors sycl-badge/src/os/cart/platform_cart_ram.zig (the
cart side of the interface), os_abi.zig (the shared IPC block) and
os/ipc/mailbox.zig (message ids). If the SDK changes, change it here. The
streaming audio of the newer firmware (upstream 3392a1b; the pinned SDK
has no API for it) is audio.py.

Memory map served to the cart:

  0x20000000..0x20080000  SRAM, plain RAM (kernel RAM, IPC block, cart RAM)
  0x20080000..0x20082000  SRAM8/9 (SCRATCH_X/Y): RAM, but every access is
                          logged; above the cart's stack top, so a cart
                          touching it is reading past the end of something
  0xD0000000 page         SIO: CPUID, FIFO_ST/WR/RD, spinlocks
  0x400B0000 page         TIMER0: TIMEHR/TIMELR/TIMERAWH/TIMERAWL, from modelled cycles
  0x40060000 page         ROSC: STATUS.RANDOMBIT (cart.rand()), seeded PRNG
  0xE0001000 page         DWT: CTRL, CYCCNT from modelled cycles
  0xE000E000 page         SCS as RAM (CPACR set so the FPU is on)
  0x40020000, 0x40028000, 0x40038000, 0x50400000
                          RESETS (all aliases), IO_BANK0, PADS_BANK0, PIO2:
                          lib/link.zig's registers with no cable plugged in
                          (writes ignored, SIO GPIO_IN reads 0, so the link
                          stays searching; RESET_DONE reads done, PIO2 FSTAT
                          reads its FIFOs empty)
  0x40090000 page         I2C0: lib/i2c_rp2350.zig's controller with nothing
                          on the Qwiic port (I2C0Fake: every address NACKs,
                          so the time-of-flight driver sees "absent" at once)

Anything else is unmapped, and an access to it is a crash.
"""
import random
import struct

from . import audio as AU
from . import model as M

SRAM_BASE, SRAM_SIZE = 0x20000000, 0x80000
SCRATCH_BASE, SCRATCH_SIZE = 0x20080000, 0x2000
CART_RAM_BASE, CART_RAM_END = 0x20035100, 0x20080000
STACK_TOP = CART_RAM_END

# ---- abi.ipc_data (os_abi.zig CartIPCData), base 0x20020000
IPC_BASE = 0x20020000
SCREEN_W, SCREEN_H = 160, 128
FB_SIZE = SCREEN_W * SCREEN_H * 2            # 0xA000
FB_ADDR = (IPC_BASE, IPC_BASE + FB_SIZE)
IPC_FIELDS = {                               # offset from IPC_BASE
    'tracy_ring': 0x14000, 'trace_buf': 0x15000, 'neopixels': 0x15080,
    'controls': 0x15090, 'light_level': 0x15092, 'user_led': 0x15094,
    'battery_level': 0x15096, 'dirty_rect': 0x15098, 'tone_freq': 0x1509C,
    'tone_duration': 0x150A0, 'tone_volume': 0x150A4, 'tone_flags': 0x150A8,
    'global_volume': 0x150AC, 'tracy_read_pos': 0x150B0, 'tracy_write_ctrl': 0x150C0,
    'tracy_spinlock': 0x150D0, 'vsync_flags': 0x150E0, 'vsync_frame_ms': 0x150E4,
    'clear_color': 0x150E8,
}
IPC_END = IPC_BASE + 0x150EC
TRACE_BUF_SIZE = 0x80

# ---- peripherals
SIO_BASE = 0xD0000000
SIO_CPUID, SIO_FIFO_ST, SIO_FIFO_WR, SIO_FIFO_RD = 0x000, 0x050, 0x054, 0x058
SIO_SPINLOCK0, SIO_SPINLOCK31 = 0x100, 0x17C
FIFO_VLD, FIFO_RDY = 1 << 0, 1 << 1
TIMER0_BASE = 0x400B0000
TIMEHR, TIMELR, TIMERAWH, TIMERAWL = 0x08, 0x0C, 0x24, 0x28
ROSC_BASE = 0x40060000
ROSC_STATUS, ROSC_RANDOMBIT = 0x0C, 0x1C
DWT_BASE = 0xE0001000
DWT_CTRL, DWT_CYCCNT = 0x000, 0x004
SIO_GPIO_IN = 0x004
SIO_GPIO_WRITES = (0x018, 0x020, 0x038, 0x040)   # GPIO_OUT_SET/CLR, GPIO_OE_SET/CLR
RESETS_BASE, IO_BANK0_BASE, PADS_BANK0_BASE = 0x40020000, 0x40028000, 0x40038000
PIO2_BASE = 0x50400000
I2C0_BASE = 0x40090000
PIO_FSTAT_EMPTY = 0x0F000F00                     # TXEMPTY and RXEMPTY, all four SMs

# ---- mailbox (os/ipc/mailbox.zig MessageType)
SYNC_TIME_REQ_CLR, SYNC_TIME_ACK_CLR, SYNC_TIME_REQ_TIME = 0x2a000001, 0x2a000002, 0x2a000003
FRAMEBUFFER_READY, FRAMEBUFFER_DONE = 0x25000001, 0x25000002
CART_RUNNING, CART_FINISHED, CART_CRASHED = 0x20000001, 0x20000002, 0x20000003
T_CART_TRACE, T_CART_TONE, T_FRAMEBUFFER_READY_V2 = 0x26, 0x27, 0x28
# Type 0x29 is audio in the newer firmware, compared as whole words
# (upstream 3392a1b kernel.zig handle_cart_message, os_abi.zig): 0x29000000
# CART_VOLUME, 0x29000001 CART_STOP_AUDIO (acked with 0x29000003),
# 0x29000002 CART_START_AUDIO; the stream itself is audio.py.

# cart.Controls bits (api.zig). CLICK is owned by the OS (joystick press).
BUTTONS = {'START': 1 << 0, 'SELECT': 1 << 1, 'A': 1 << 2, 'B': 1 << 3, 'CLICK': 1 << 4,
           'UP': 1 << 5, 'DOWN': 1 << 6, 'LEFT': 1 << 7, 'RIGHT': 1 << 8}

LIGHT_LEVEL = 0x800     # mid-scale ambient light
BATTERY_LEVEL = 0xFFF   # full battery


class I2C0Fake:
    """RP2350 I2C0 (DW_apb_i2c) with no device on the bus: a data command
    written while enabled raises TX_ABRT with ABRT_7B_ADDR_NOACK and
    STOP_DET at once, as a NACKed address does; reading IC_CLR_TX_ABRT,
    IC_CLR_STOP_DET or IC_CLR_INTR clears them. FIFOs read empty and
    never full; other registers read back what was written."""
    IC_DATA_CMD, IC_INTR_STAT, IC_RAW_INTR_STAT = 0x10, 0x2C, 0x34
    IC_CLR_INTR, IC_CLR_TX_ABRT, IC_CLR_STOP_DET = 0x40, 0x54, 0x60
    IC_ENABLE, IC_STATUS, IC_TXFLR, IC_RXFLR = 0x6C, 0x70, 0x74, 0x78
    IC_TX_ABRT_SOURCE, IC_ENABLE_STATUS, IC_COMP_TYPE = 0x80, 0x9C, 0xFC
    TX_EMPTY, TX_ABRT, STOP_DET = 1 << 4, 1 << 6, 1 << 9
    STATUS_TFNF_TFE = 0x06
    ABRT_7B_ADDR_NOACK = 1

    def __init__(self):
        self.regs = {}
        self.enabled = 0
        self.abort = False
        self.stop_det = False
        self.nacks = 0

    def read(self, uc, off, size, _):
        if off == self.IC_RAW_INTR_STAT:
            return self.TX_EMPTY | (self.TX_ABRT if self.abort else 0) | (self.STOP_DET if self.stop_det else 0)
        if off == self.IC_INTR_STAT:
            return 0                     # everything masked
        if off == self.IC_TX_ABRT_SOURCE:
            return self.ABRT_7B_ADDR_NOACK if self.abort else 0
        if off == self.IC_CLR_TX_ABRT:
            self.abort = False
            return 1
        if off == self.IC_CLR_STOP_DET:
            self.stop_det = False
            return 0
        if off == self.IC_CLR_INTR:
            self.abort = self.stop_det = False
            return 0
        if off == self.IC_STATUS:
            return self.STATUS_TFNF_TFE
        if off in (self.IC_TXFLR, self.IC_RXFLR, self.IC_DATA_CMD):
            return 0
        if off == self.IC_ENABLE:
            return self.enabled
        if off == self.IC_ENABLE_STATUS:
            return self.enabled & 1
        if off == self.IC_COMP_TYPE:
            return 0x44570140
        return self.regs.get(off, 0)

    def write(self, uc, off, size, value, _):
        if off == self.IC_ENABLE:
            self.enabled = value & 1     # ABORT (bit 1) completes at once
        elif off == self.IC_DATA_CMD:
            if self.enabled and not self.abort:
                self.abort = self.stop_det = True
                self.nacks += 1
        else:
            self.regs[off] = value


class FakeOS:
    """Serves the peripherals and the FIFO protocol. `host` is the runner; it
    gets on_present(flags), on_cyccnt_read() and on_message(kind, ...) calls
    and provides cycles() (modelled cycles so far)."""

    def __init__(self, mu, host, seed=1):
        self.mu = mu
        self.host = host
        self.rng = random.Random(seed)
        self.to_cart = []            # FIFO words queued for the cart
        self.sync_state = 'boot'     # boot -> cleared -> timed
        self.timer_latch_hi = 0
        self.spinlocks = 0
        self.cyccnt_offset = 0
        self.unknown = {}            # (peripheral, offset, 'r'/'w') -> count
        self.status_words = []
        self.scratch = bytearray(SCRATCH_SIZE)
        self.scratch_log = {}        # (rw, block) -> [count, first addr, frame]
        mu.mem_map(SRAM_BASE, SRAM_SIZE)
        mu.mmio_map(SCRATCH_BASE, SCRATCH_SIZE, self._scratch_read, None, self._scratch_write, None)
        mu.mmio_map(SIO_BASE, 0x1000, self._sio_read, None, self._sio_write, None)
        mu.mmio_map(TIMER0_BASE, 0x1000, self._timer_read, None, self._ignore_write('TIMER0'), None)
        mu.mmio_map(ROSC_BASE, 0x1000, self._rosc_read, None, self._ignore_write('ROSC'), None)
        mu.mmio_map(DWT_BASE, 0x1000, self._dwt_read, None, self._dwt_write, None)
        # lib/link.zig, no cable: expected traffic, so nothing is noted.
        nop_write = lambda uc, off, size, value, _: None
        mu.mmio_map(RESETS_BASE, 0x4000, lambda uc, off, size, _: 0xffffffff if off == 0x8 else 0, None, nop_write, None)
        mu.mmio_map(IO_BANK0_BASE, 0x1000, lambda uc, off, size, _: 0, None, nop_write, None)
        mu.mmio_map(PADS_BANK0_BASE, 0x1000, lambda uc, off, size, _: 0, None, nop_write, None)
        mu.mmio_map(PIO2_BASE, 0x1000, lambda uc, off, size, _: PIO_FSTAT_EMPTY if off == 0x4 else 0, None, nop_write, None)
        # lib/i2c_rp2350.zig, nothing on the Qwiic port: expected traffic too.
        self.i2c0 = I2C0Fake()
        mu.mmio_map(I2C0_BASE, 0x1000, self.i2c0.read, None, self.i2c0.write, None)

    # ------------------------------------------------------------ shared memory
    def init_ipc(self):
        self.write_u16(IPC_BASE + IPC_FIELDS['light_level'], LIGHT_LEVEL)
        self.write_u16(IPC_BASE + IPC_FIELDS['battery_level'], BATTERY_LEVEL)

    def write_u16(self, addr, v):
        self.mu.mem_write(addr, struct.pack('<H', v & 0xffff))

    def read(self, fmt, field):
        a = IPC_BASE + IPC_FIELDS[field]
        return struct.unpack(fmt, bytes(self.mu.mem_read(a, struct.calcsize(fmt))))

    def set_controls(self, bits):
        self.write_u16(IPC_BASE + IPC_FIELDS['controls'], bits)

    def neopixels(self):
        """[(r, g, b)] x 5; the IPC layout is g, r, b (api.NeopixelColor)."""
        raw = bytes(self.mu.mem_read(IPC_BASE + IPC_FIELDS['neopixels'], 15))
        return [(raw[3 * i + 1], raw[3 * i], raw[3 * i + 2]) for i in range(5)]

    def user_led(self):
        return bool(self.mu.mem_read(IPC_BASE + IPC_FIELDS['user_led'], 1)[0])

    def vsync(self):
        flags, = self.read('<I', 'vsync_flags')
        ms, = self.read('<f', 'vsync_frame_ms')
        return flags, ms

    def framebuffer(self, index):
        return bytes(self.mu.mem_read(FB_ADDR[index & 1], FB_SIZE))

    def flush_lcd(self, lcd, index, flags, legacy=False):
        """Copy what the OS would send to the LCD into `lcd` (FB_SIZE bytes,
        same column-major layout): the whole framebuffer for a legacy present,
        else only the dirty rect when PresentFlags bit 1 says there is one,
        else nothing (kernel.zig: a v2 present without a rect is an empty
        frame). Carts in .copy_forward that write pixels without
        mark_dirty_rect leave those pixels off the screen."""
        fb = self.framebuffer(index)
        if legacy:
            lcd[:] = fb
            return
        if not flags & 2:
            return
        x0, y0, x1, y1 = self.read('<4B', 'dirty_rect')
        x1, y1 = min(x1, SCREEN_W), min(y1, SCREEN_H)
        if x0 >= x1 or y0 >= y1:
            return
        for x in range(x0, x1):
            a, b = 2 * (x * SCREEN_H + y0), 2 * (x * SCREEN_H + y1)
            lcd[a:b] = fb[a:b]

    # ------------------------------------------------------------ peripherals
    def _note(self, periph, off, rw):
        k = (periph, off, rw)
        self.unknown[k] = self.unknown.get(k, 0) + 1

    def _ignore_write(self, periph):
        def w(uc, off, size, value, _):
            self._note(periph, off, 'w')
        return w

    def _scratch_note(self, rw, off):
        k = (rw, self.host.current_block())
        e = self.scratch_log.get(k)
        if e is None:
            self.scratch_log[k] = [1, SCRATCH_BASE + off, self.host.current_frame()]
        else:
            e[0] += 1

    def _scratch_read(self, uc, off, size, _):
        self._scratch_note('read', off)
        return int.from_bytes(self.scratch[off:off + size], 'little')

    def _scratch_write(self, uc, off, size, value, _):
        self._scratch_note('write', off)
        self.scratch[off:off + size] = (value & ((1 << (8 * size)) - 1)).to_bytes(size, 'little')

    def _sio_read(self, uc, off, size, _):
        if off == SIO_FIFO_ST:
            return FIFO_RDY | (FIFO_VLD if self.to_cart else 0)
        if off == SIO_FIFO_RD:
            return self.to_cart.pop(0) if self.to_cart else 0
        if off == SIO_CPUID:
            return 1                     # carts run on core 1
        if off == SIO_GPIO_IN:
            return 0                     # no link cable: header pins low
        if SIO_SPINLOCK0 <= off <= SIO_SPINLOCK31 and off % 4 == 0:
            bit = 1 << ((off - SIO_SPINLOCK0) // 4)
            if self.spinlocks & bit:
                return 0                 # taken (never by core 0 here)
            self.spinlocks |= bit
            return bit
        self._note('SIO', off, 'r')
        return 0

    def _sio_write(self, uc, off, size, value, _):
        if off == SIO_FIFO_WR:
            self._message(value & 0xffffffff)
        elif SIO_SPINLOCK0 <= off <= SIO_SPINLOCK31 and off % 4 == 0:
            self.spinlocks &= ~(1 << ((off - SIO_SPINLOCK0) // 4))
        elif off in SIO_GPIO_WRITES:
            pass                         # lib/link.zig driving a header pin
        else:
            self._note('SIO', off, 'w')

    def micros(self):
        return self.host.cycles() // M.CYCLES_PER_US

    def _timer_read(self, uc, off, size, _):
        us = self.micros()
        if off == TIMELR:                # reading TIMELR latches TIMEHR
            self.timer_latch_hi = (us >> 32) & 0xffffffff
            return us & 0xffffffff
        if off == TIMEHR:
            return self.timer_latch_hi
        if off == TIMERAWL:
            return us & 0xffffffff
        if off == TIMERAWH:
            return (us >> 32) & 0xffffffff
        self._note('TIMER0', off, 'r')
        return 0

    def _rosc_read(self, uc, off, size, _):
        if off == ROSC_STATUS:           # STABLE | ENABLED | RANDOMBIT(16)
            return 0x80001000 | (self.rng.getrandbits(1) << 16)
        if off == ROSC_RANDOMBIT:
            return self.rng.getrandbits(1)
        self._note('ROSC', off, 'r')
        return 0

    def _dwt_read(self, uc, off, size, _):
        if off == DWT_CYCCNT:
            self.host.on_cyccnt_read()
            return (self.host.cycles() + self.cyccnt_offset) & 0xffffffff
        if off == DWT_CTRL:
            return 0x40000001            # 4 comparators, CYCCNTENA
        self._note('DWT', off, 'r')
        return 0

    def _dwt_write(self, uc, off, size, value, _):
        if off == DWT_CYCCNT:
            self.cyccnt_offset = (value - self.host.cycles()) & 0xffffffff
        elif off != DWT_CTRL:
            self._note('DWT', off, 'w')

    # ------------------------------------------------------------ mailbox
    def _message(self, w):
        if w == SYNC_TIME_REQ_CLR:
            self.to_cart.clear()
            self.to_cart.append(SYNC_TIME_ACK_CLR)
            self.sync_state = 'cleared'
            return
        if w == SYNC_TIME_REQ_TIME:
            # os_align_cycles reads DWT_CYCCNT right after sending this and
            # sets its offset so cycles() == OS time; we answer with the
            # modelled cycle count itself (two words, high first).
            t = self.host.cycles()
            self.to_cart += [(t >> 32) & 0xffffffff, t & 0xffffffff]
            self.sync_state = 'timed'
            self.host.on_message('sync')
            return
        if w in (CART_RUNNING, CART_FINISHED, CART_CRASHED):
            self.status_words.append(w)
            self.host.on_message('status', w)
            return
        if w == FRAMEBUFFER_READY:       # legacy present: same reply
            self.to_cart.append(FRAMEBUFFER_DONE)
            self.host.on_present(0, legacy=True)
            return
        if w == AU.CART_START_AUDIO:
            self.host.on_message('audio_start')
            return
        if w == AU.CART_STOP_AUDIO:      # kernel.zig: ack first, then stop
            self.to_cart.append(AU.OS_ACK_STOP_AUDIO)
            self.host.on_message('audio_stop')
            return
        if w == AU.CART_VOLUME:
            v, = self.read('<f', 'global_volume')
            self.host.on_message('volume', v)
            return
        kind, payload = w >> 24, w & 0xffffff
        if kind == T_FRAMEBUFFER_READY_V2:
            # PresentFlags: bit0 framebuffer index, bit1 dirty rect, bit2
            # vsync updated, bit3 clear frame. The LCD flush is instant here.
            self.to_cart.append(FRAMEBUFFER_DONE)
            self.host.on_present(payload)
        elif kind == T_CART_TRACE:
            n = min(payload, TRACE_BUF_SIZE - 1)
            s = bytes(self.mu.mem_read(IPC_BASE + IPC_FIELDS['trace_buf'], n))
            self.host.on_message('trace', s.decode('utf-8', 'replace'))
        elif kind == T_CART_TONE:
            freq, dur, vol, flags = self.read('<fffI', 'tone_freq')
            self.host.on_message('tone', dict(freq=freq, duration=dur, volume=vol, flags=flags))
        else:
            self.host.on_message('unknown', w)
