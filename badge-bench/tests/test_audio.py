#!/usr/bin/env python3
"""The streaming-audio consumer (badge_bench/audio.py), no cart needed.

    .venv/bin/python tests/test_audio.py    (after one ./bench.sh run made .venv)

Drives audio.Consumer over a fake memory holding the IPC ring words and a
ring, and checks it against sycl-badge upstream 3392a1b audio.zig
`mix_buffer_samples` (the tail arithmetic, wrap-around, silence padding),
`start_buffered` (two buffers mixed at once), the 512-sample schedule, the
statistics, the WAV writer, and os_fake's routing of the 0x29 words.
Exit 0 pass, 1 fail.
"""
import io
import os
import struct
import sys
import wave

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
from badge_bench import audio as AU  # noqa: E402
from badge_bench import os_fake as OS  # noqa: E402

RING = 0x20040000
P = AU.MIX_PERIOD_CYC


class Mem:
    """Sparse little-endian memory: the four IPC words and a ring."""

    def __init__(self):
        self.b = {}

    def mem_read(self, addr, n):
        return bytes(self.b.get(addr + i, 0) for i in range(n))

    def mem_write(self, addr, data):
        for i, v in enumerate(data):
            self.b[addr + i] = v

    def u32(self, addr):
        return struct.unpack('<I', self.mem_read(addr, 4))[0]

    def set_ring(self, ln, head, tail, ptr=RING):
        self.mem_write(AU.AUDIO_PTR, struct.pack('<IIII', ptr, ln, head, tail))
        # sample i of the ring = i & 0xff, so taken data shows where it came from
        self.mem_write(ptr, bytes(i & 0xff for i in range(ln)))

    def tail(self):
        return self.u32(AU.AUDIO_TAIL)


results = []


def short(v):
    r = repr(v)
    return r if len(r) <= 72 else r[:60] + f"... ({len(r)} chars)"


def check(name, got, want):
    ok = got == want
    print(f"{'ok  ' if ok else 'FAIL'} {name}: {short(got)}" + ('' if ok else f" (want {short(want)})"))
    results.append(ok)


def ring_bytes(start, n):
    return bytes((start + i) & 0xff for i in range(n))


def consumer(ln, head, tail, ptr=RING):
    m = Mem()
    m.set_ring(ln, head, tail, ptr)
    return m, AU.Consumer(m, keep_stream=True)


# ---- the LCD period behind vsync (lcd.zig find_framerate_setting)
check("lcd period for 1000/60 ms", round(AU.lcd_frame_ms(1000.0 / 60.0), 3), 16.74)
check("lcd period for 10 ms (tearing floor 11.46)", round(AU.lcd_frame_ms(10.0), 3), 11.46)
check("lcd period for 1000/30 ms (two sub-frames)", round(AU.lcd_frame_ms(1000.0 / 30.0), 3), 33.48)

# ---- one mix, tail <= head
m, c = consumer(4096, 1000, 0)
c.mix()
check("tail<=head: tail advances 512", m.tail(), 512)
check("tail<=head: data from the tail", bytes(c.stream), ring_bytes(0, 512))
c.mix()
check("tail<=head short: tail stops at head", m.tail(), 1000)
check("short mix pads 24 samples of silence", bytes(c.stream[512:]), ring_bytes(512, 488) + bytes([128]) * 24)
check("counts: consumed / underrun / lead-in", (c.consumed, c.underrun, c.underrun_mixes, c.lead_in),
      (1000, 24, 1, 0))
check("queue seen at each mix", (c.queue_min, c.queue_max, c.queue_n), (488, 1000, 2))

# ---- tail > head, no wrap inside this mix (tail + 512 < len)
m, c = consumer(4096, 500, 1000)
c.mix()
check("tail>head, room: 512 from the tail", (m.tail(), bytes(c.stream)), (1512, ring_bytes(1000, 512)))

# ---- wrap inside the mix
m, c = consumer(4096, 300, 3800)
c.mix()
check("wrap: tail = second part's length", m.tail(), 216)
check("wrap: len - tail then from 0", bytes(c.stream), ring_bytes(3800, 296) + ring_bytes(0, 216))
check("wrap: no underrun", (c.consumed, c.underrun), (512, 0))

# ---- tail + 512 == len goes to the wrap branch (strict <) and lands on 0
m, c = consumer(4096, 100, 3584)
c.mix()
check("tail+512 == len: tail wraps to 0", (m.tail(), bytes(c.stream)), (0, ring_bytes(3584, 512)))

# ---- wrap with too little queued: second part limited by head, rest silence
m, c = consumer(4096, 50, 4000)
c.mix()
check("wrap short: tail = head", m.tail(), 50)
check("wrap short: 96 + 50 samples, 366 silence", bytes(c.stream),
      ring_bytes(4000, 96) + ring_bytes(0, 50) + bytes([128]) * 366)

# ---- empty ring at start: two buffers of start-up silence, not underruns
m, c = consumer(4096, 0, 0)
c.frame = 7
c.start(1000.0)
check("start mixes two buffers at once", (c.mixes, c.lead_in, c.underrun, c.consumed), (2, 1024, 0, 0))
check("start: first frame, next mix one period later", (c.started_frame, c.next_due), (7, 1000.0 + P))
check("start-up silence is not in the queue stats", (c.queue_min, c.queue_n), (None, 0))
c.run_until(1000.0 + P - 1)
check("nothing due before the period", c.mixes, 2)
m.mem_write(AU.AUDIO_HEAD, struct.pack('<I', 700))
c.frame = 8
c.run_until(1000.0 + 2 * P)
check("two turns due -> two mixes", c.mixes, 4)
check("then 512 + 188 consumed, 324 underrun from frame 8", (c.consumed, c.underrun, c.first_underrun),
      (700, 324, 8))
check("lead-in unchanged after the first real sample", c.lead_in, 1024)
check("stream = everything mixed", len(c.stream), 4 * 512)

# ---- stop: no more mixes; a new start re-primes two buffers
c.stop()
c.run_until(1000.0 + 10 * P)
check("stopped: no mixes", (c.mixes, c.active, c.stops), (4, False, 1))
c.start(1000.0 + 10 * P)
check("restart mixes two buffers, keeps the first frame", (c.mixes, c.starts, c.started_frame), (6, 2, 7))
check("restart on an empty ring after audio counts as underrun", c.underrun, 324 + 1024)

# ---- no ring pointer: silence, tail untouched (audio.zig: ptr null)
m, c = consumer(4096, 100, 0, ptr=0)
m.mem_write(AU.AUDIO_TAIL, struct.pack('<I', 5))
c.mix()
check("ptr 0: silence, tail untouched", (bytes(c.stream), m.tail(), c.bad), (bytes([128]) * 512, 5, 0))

# ---- ring words out of range: reported, silent, tail untouched
m, c = consumer(4096, 4096, 0)
c.mix()
check("head == len: bad ring, silence", (c.bad, c.consumed, m.tail()), (1, 0, 0))
check("bad ring detail", c.bad_detail, "frame -1: ptr 0x20040000 len 4096 head 4096 tail 0")
m, c = consumer(0x100000, 10, 0)
c.mix()
check("ring past the end of SRAM: bad ring", c.bad, 1)

# ---- queued() and summary()
m, c = consumer(4096, 100, 4000)
check("queued wraps", c.queued(), 196)
s = c.summary()
check("summary keys", sorted(s), sorted([
    'started_frame', 'starts', 'stops', 'ring_ptr', 'ring_len', 'mixes', 'mix_samples', 'sample_rate',
    'consumed', 'lead_in', 'underrun', 'underrun_mixes', 'first_underrun', 'queue_min', 'queue_max',
    'queue_mean', 'queue_mixes', 'bad_ring', 'bad_ring_first']))

# ---- WAV
w = wave.open(io.BytesIO(AU.wav_bytes(bytes([0, 128, 255]))))
check("wav params", (w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()), (1, 1, 44100, 3))
check("wav data", w.readframes(3), bytes([0, 128, 255]))


# ---- os_fake: the 0x29 words
class StubUc:
    def __init__(self):
        self.m = Mem()

    def mem_map(self, *a):
        pass

    def mmio_map(self, *a):
        pass

    def mem_read(self, a, n):
        return self.m.mem_read(a, n)

    def mem_write(self, a, d):
        self.m.mem_write(a, d)


class StubHost:
    def __init__(self):
        self.msgs = []

    def on_message(self, kind, *a):
        self.msgs.append((kind,) + a)


h = StubHost()
uc = StubUc()
fake = OS.FakeOS(uc, h)
uc.mem_write(OS.IPC_BASE + OS.IPC_FIELDS['global_volume'], struct.pack('<f', 0.5))
for word in (0x29000002, 0x29000001, 0x29000000, 0x29000005):
    fake._message(word)
check("0x29 words: start, stop, volume, unknown",
      h.msgs, [('audio_start',), ('audio_stop',), ('volume', 0.5), ('unknown', 0x29000005)])
check("CART_STOP_AUDIO is acked", fake.to_cart, [AU.OS_ACK_STOP_AUDIO])

print(f"{sum(results)} of {len(results)} passed")
sys.exit(0 if all(results) else 1)
