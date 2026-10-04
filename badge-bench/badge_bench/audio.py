"""The new badge firmware's streaming audio, as the OS consumes it.

Mirrors sycl-badge upstream 3392a1b (commit 97c093e "Streaming Audio, v1
Mixer"): src/os/drivers/audio.zig `start_buffered`/`mix_buffer_samples`,
src/os/kernel.zig `handle_cart_message`, src/os/cart/os_abi.zig. The cart
owns a ring of unsigned 8-bit mono samples at 44,100 Hz (128 = silence)
and publishes it in the IPC block:

  0x2003509C  audio_buffer_ptr   u32 address of the ring (0: none)
  0x200350A0  audio_buffer_len   u32 ring length in samples
  0x200350A4  audio_buffer_head  u32, cart writes: next sample it will write
  0x200350A8  audio_buffer_tail  u32, OS writes: next sample it will read

FIFO word 0x29000002 (CART_START_AUDIO) starts the mixer: the OS mixes two
512-sample DMA buffers at once (`setup_ping_pong_DMA`), then one more each
time a buffer finishes playing, i.e. every 512 samples of wall time. A mix
takes up to 512 queued samples from the tail (with the OS's exact
wrap-around arithmetic) and pads the rest of the buffer with silence (an
underrun). 0x29000001 (CART_STOP_AUDIO) stops it (the OS acks with
0x29000003). The pinned SDK has none of this; carts speak the ABI directly.

`Consumer` keeps its own clock in wall cycles (badge-bench's modelled
cycles plus the vsync waits, see run.py) and is pure Python over a
`mem` object with mem_read(addr, n) and mem_write(addr, bytes) (the
unicorn instance, or a fake in tests/test_audio.py).
"""
import struct

from . import model as M

AUDIO_PTR, AUDIO_LEN, AUDIO_HEAD, AUDIO_TAIL = 0x2003509C, 0x200350A0, 0x200350A4, 0x200350A8
CART_VOLUME, CART_STOP_AUDIO, CART_START_AUDIO, OS_ACK_STOP_AUDIO = (
    0x29000000, 0x29000001, 0x29000002, 0x29000003)
SAMPLE_RATE = 44100
MIX_SAMPLES = 512                     # audio.zig dma_buf_size (1 << 9)
SILENCE = 128
MIX_PERIOD_CYC = MIX_SAMPLES * M.CLOCK_HZ / SAMPLE_RATE   # ~11.6 ms of wall time
SRAM_BASE, SRAM_END = 0x20000000, 0x20080000


def lcd_frame_ms(raw_frame_ms):
    """The LCD period the OS really sets for a cart's set_vsync_enabled(ms):
    sycl-badge src/os/drivers/lcd.zig `find_framerate_setting` (pinned and
    upstream agree), FRMCTR1 ms = (160 + porch) * (clk_div + 4) / 200 on the
    panel's nominal 200 kHz oscillator. 1000/60 gives 16.74 ms (59.74 Hz),
    not 16.67: a cart pushing 735 samples a frame falls ~190 samples/s short
    of the 44,100 the mixer takes, which its rate control must absorb."""
    def ms(clk_div, porch):
        return (160.0 + porch) * (clk_div + 4.0) / 200.0
    if raw_frame_ms <= 0:
        return 0.0
    max_single = ms(0x0F, 0x1F)
    sub = max(1.0, -(-raw_frame_ms // max_single))
    target = raw_frame_ms / sub
    if target < ms(0x08, 0x1F):
        return ms(0x08, 0x1F) * sub
    clk_div, porch = 0x0F, 0x1F
    actual = max_single
    while clk_div > 0:
        n = ms(clk_div - 1, porch)
        if n < target:
            break
        actual = n
        clk_div -= 1
    while porch > 0:
        n = ms(clk_div, porch - 1)
        if n < target:
            break
        actual = n
        porch -= 1
    return actual * sub


class Consumer:
    """The OS mixer's view of the cart's ring. Statistics:

    started_frame   frame of the first CART_START_AUDIO (None: never)
    starts, stops   start / stop words received
    mixes           512-sample buffers mixed
    consumed        real samples taken from the ring
    lead_in         silence padded before the first real sample (the two
                    buffers mixed at start when the ring is still empty)
    underrun        silence padded after the first real sample
    underrun_mixes  mixes that padded after the first real sample
    first_underrun  frame of the first such mix (None: none)
    queue_*         queued samples seen at each mix from the first non-empty
                    one on (before taking): min, max, sum / count = mean
    bad             mixes with ring words out of range (treated as silent,
                    tail untouched); the first described in bad_detail
    stream          bytearray of everything mixed (only with keep_stream)
    """

    def __init__(self, mem, keep_stream=False):
        self.mem = mem
        self.active = False
        self.next_due = float('inf')     # wall cycles of the next mix
        self.frame = -1                  # set by the runner, for first_underrun
        self.started_frame = None
        self.starts = self.stops = 0
        self.mixes = self.consumed = self.lead_in = self.underrun = self.underrun_mixes = 0
        self.first_underrun = None
        self.queue_min = self.queue_max = None
        self.queue_sum = self.queue_n = 0
        self.bad = 0
        self.bad_detail = None
        self.ring = None                 # (ptr, len) at the last start
        self.stream = bytearray() if keep_stream else None

    # ------------------------------------------------------------ messages
    def start(self, wall):
        """CART_START_AUDIO at wall cycles `wall`: `start_buffered` stops any
        running DMA, mixes both buffers now and plays them back to back."""
        self.starts += 1
        if self.started_frame is None:
            self.started_frame = self.frame
        ptr, ln = struct.unpack('<II', bytes(self.mem.mem_read(AUDIO_PTR, 8)))
        self.ring = (ptr, ln)
        self.active = True
        self.mix()
        self.mix()
        self.next_due = wall + MIX_PERIOD_CYC

    def stop(self):
        """CART_STOP_AUDIO: the OS acks (the caller queues OS_ACK_STOP_AUDIO)
        and stops the DMA; nothing more is mixed until the next start."""
        self.stops += 1
        self.active = False
        self.next_due = float('inf')

    def run_until(self, wall):
        """Mix every buffer whose turn came at or before wall cycles `wall`."""
        while self.next_due <= wall:
            self.mix()
            self.next_due += MIX_PERIOD_CYC

    # ------------------------------------------------------------ the mixer
    def _u32(self, addr):
        return struct.unpack('<I', bytes(self.mem.mem_read(addr, 4)))[0]

    def _take(self, ptr, off, n):
        return bytes(self.mem.mem_read(ptr + off, n)) if n > 0 else b''

    def mix(self):
        """One `mix_buffer_samples`, line for line, with a bounds check the
        OS does not have (a cart with broken ring words is reported, not
        emulated reading wherever they point)."""
        self.mixes += 1
        ptr, ln, head, tail = struct.unpack('<IIII', bytes(self.mem.mem_read(AUDIO_PTR, 16)))
        out = b''
        q = None
        if ptr:
            if not (ln and head < ln and tail < ln and SRAM_BASE <= ptr and ptr + ln <= SRAM_END):
                self.bad += 1
                if self.bad_detail is None:
                    self.bad_detail = (f"frame {self.frame}: ptr {ptr:#010x} len {ln} head {head} "
                                       f"tail {tail}")
            else:
                q = (head - tail) % ln
                if tail <= head or tail + MIX_SAMPLES < ln:
                    n = min(head - tail, MIX_SAMPLES) if tail <= head else MIX_SAMPLES
                    out = self._take(ptr, tail, n)
                    new_tail = tail + n
                else:
                    n1 = ln - tail
                    out = self._take(ptr, tail, n1)
                    n2 = min(head, MIX_SAMPLES - n1)
                    out += self._take(ptr, 0, n2)
                    new_tail = n2
                self.mem.mem_write(AUDIO_TAIL, struct.pack('<I', new_tail))
        got = len(out)
        pad = MIX_SAMPLES - got
        seen_audio = self.consumed > 0 or got > 0
        self.consumed += got
        if seen_audio and q is not None:
            self.queue_min = q if self.queue_min is None else min(self.queue_min, q)
            self.queue_max = q if self.queue_max is None else max(self.queue_max, q)
            self.queue_sum += q
            self.queue_n += 1
        if pad:
            if seen_audio:
                self.underrun += pad
                self.underrun_mixes += 1
                if self.first_underrun is None:
                    self.first_underrun = self.frame
            else:
                self.lead_in += pad
        if self.stream is not None:
            self.stream += out
            self.stream += bytes([SILENCE]) * pad

    # ------------------------------------------------------------ reporting
    def queued(self):
        """Samples queued now (head - tail mod len), None without a valid ring."""
        ptr, ln, head, tail = struct.unpack('<IIII', bytes(self.mem.mem_read(AUDIO_PTR, 16)))
        if not ptr or not ln or head >= ln or tail >= ln:
            return None
        return (head - tail) % ln

    def summary(self):
        return dict(
            started_frame=self.started_frame, starts=self.starts, stops=self.stops,
            ring_ptr=self.ring[0] if self.ring else None, ring_len=self.ring[1] if self.ring else None,
            mixes=self.mixes, mix_samples=MIX_SAMPLES, sample_rate=SAMPLE_RATE,
            consumed=self.consumed, lead_in=self.lead_in, underrun=self.underrun,
            underrun_mixes=self.underrun_mixes, first_underrun=self.first_underrun,
            queue_min=self.queue_min, queue_max=self.queue_max,
            queue_mean=self.queue_sum / self.queue_n if self.queue_n else None,
            queue_mixes=self.queue_n, bad_ring=self.bad, bad_ring_first=self.bad_detail)


def wav_bytes(samples, rate=SAMPLE_RATE):
    """A canonical RIFF/WAVE file of 8-bit unsigned mono PCM."""
    n = len(samples)
    return (b'RIFF' + struct.pack('<I', 36 + n) + b'WAVEfmt '
            + struct.pack('<IHHIIHH', 16, 1, 1, rate, rate, 1, 8)
            + b'data' + struct.pack('<I', n) + bytes(samples))
