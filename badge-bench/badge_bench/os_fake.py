"""Just enough of the badge OS (core 0) for a cart on core 1.

Everything here mirrors sycl-badge/src/os/cart/platform_cart_ram.zig (the
cart side of the interface), os_abi.zig (the shared IPC block) and
os/ipc/mailbox.zig (message ids). If the SDK changes, change it here.

Memory map served to the cart:

  0x20000000..0x20080000  SRAM, plain RAM (kernel RAM, IPC block, cart RAM)
  0xD0000000 page         SIO: CPUID, FIFO_ST/WR/RD, spinlocks
  0x400B0000 page         TIMER0: TIMEHR/TIMELR/TIMERAWH/TIMERAWL, from modelled cycles
  0x40060000 page         ROSC: STATUS.RANDOMBIT (cart.rand()), seeded PRNG
  0xE0001000 page         DWT: CTRL, CYCCNT from modelled cycles
  0xE000E000 page         SCS as RAM (CPACR set so the FPU is on)

Anything else is unmapped, and an access to it is a crash.
"""
import random
import struct

from . import model as M

SRAM_BASE, SRAM_SIZE = 0x20000000, 0x80000
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

# ---- mailbox (os/ipc/mailbox.zig MessageType)
SYNC_TIME_REQ_CLR, SYNC_TIME_ACK_CLR, SYNC_TIME_REQ_TIME = 0x2a000001, 0x2a000002, 0x2a000003
FRAMEBUFFER_READY, FRAMEBUFFER_DONE = 0x25000001, 0x25000002
CART_RUNNING, CART_FINISHED, CART_CRASHED = 0x20000001, 0x20000002, 0x20000003
T_CART_TRACE, T_CART_TONE, T_FRAMEBUFFER_READY_V2, T_CART_VOLUME = 0x26, 0x27, 0x28, 0x29

# cart.Controls bits (api.zig). CLICK is owned by the OS (joystick press).
BUTTONS = {'START': 1 << 0, 'SELECT': 1 << 1, 'A': 1 << 2, 'B': 1 << 3, 'CLICK': 1 << 4,
           'UP': 1 << 5, 'DOWN': 1 << 6, 'LEFT': 1 << 7, 'RIGHT': 1 << 8}

LIGHT_LEVEL = 0x800     # mid-scale ambient light
BATTERY_LEVEL = 0xFFF   # full battery


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
        mu.mem_map(SRAM_BASE, SRAM_SIZE)
        mu.mmio_map(SIO_BASE, 0x1000, self._sio_read, None, self._sio_write, None)
        mu.mmio_map(TIMER0_BASE, 0x1000, self._timer_read, None, self._ignore_write('TIMER0'), None)
        mu.mmio_map(ROSC_BASE, 0x1000, self._rosc_read, None, self._ignore_write('ROSC'), None)
        mu.mmio_map(DWT_BASE, 0x1000, self._dwt_read, None, self._dwt_write, None)

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

    # ------------------------------------------------------------ peripherals
    def _note(self, periph, off, rw):
        k = (periph, off, rw)
        self.unknown[k] = self.unknown.get(k, 0) + 1

    def _ignore_write(self, periph):
        def w(uc, off, size, value, _):
            self._note(periph, off, 'w')
        return w

    def _sio_read(self, uc, off, size, _):
        if off == SIO_FIFO_ST:
            return FIFO_RDY | (FIFO_VLD if self.to_cart else 0)
        if off == SIO_FIFO_RD:
            return self.to_cart.pop(0) if self.to_cart else 0
        if off == SIO_CPUID:
            return 1                     # carts run on core 1
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
        elif kind == T_CART_VOLUME:
            v, = self.read('<f', 'global_volume')
            self.host.on_message('volume', v)
        else:
            self.host.on_message('unknown', w)
