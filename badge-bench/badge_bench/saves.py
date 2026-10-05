"""The patched OS's cart saves (sycl-badge branch cart-saves, fork/CART_SAVES_PLAN.md
ABI v1), served to the cart: the mailbox word 0x2C carries
(request address - 0x20000000) / 4 of a 64-byte SaveRequest in cart RAM;
the OS validates it, works and answers through the struct only (status,
result, then state = done), never through the FIFO.

Two parts, so the store can be swapped (for Track A's save_store.zig
behind a host binary, say) without touching the request side:

  Store         what is stored and the store's rules: limits, copy-on-write
                block accounting with the 16-block reserve, unchanged
                write = no-op, rate limit. MemoryStore mirrors the OS's
                store (sycl-badge cart-saves src/os/system/save_store.zig:
                beginWrite/beginDelete check order, stat, list).
                MemoryStore keeps it in memory, FileStore also in a JSON
                file (--saves FILE) so state survives between runs.
  SaveService   the OS glue: reads the request from emulated memory,
                validates it as the OS does, calls the store, writes the
                answer and returns the modelled flash time to charge the
                cart (it is parked in its wait loop meanwhile).

Flash time: a write that changes the blob costs (ceil(len / 4096) + 1) x
55 ms (each 4 KB data block erased, programmed and verified, plus one
directory block), a delete 55 ms (the directory block), anything else (probe, read, stat, list, exit_watch,
an unchanged write, a refused request) 0. CART_SAVES_PLAN.md: ~45 ms erase +
~10 ms program per 4 KB, datasheet typical, to measure on hardware.
"""
import base64
import json
import os
import struct

MSG_TYPE = 0x2C
MAGIC = 0x31564153           # "SAV1"
ABI_VERSION = 1

OP_PROBE, OP_READ, OP_WRITE, OP_DELETE, OP_STAT, OP_LIST, OP_EXIT_WATCH = 1, 2, 3, 4, 5, 6, 7
OP_NAMES = {1: 'probe', 2: 'read', 3: 'write', 4: 'delete', 5: 'stat', 6: 'list', 7: 'exit_watch'}
ST_IDLE, ST_PENDING, ST_BUSY, ST_DONE = 0, 1, 2, 3
(OK, NOT_FOUND, NO_SPACE, BAD_REQUEST, BAD_BUFFER, RATE_LIMITED, TOO_BIG, IO_ERROR,
 BUSY) = range(9)
STATUS_NAMES = ['ok', 'not_found', 'no_space', 'bad_request', 'bad_buffer', 'rate_limited',
                'too_big', 'io_error', 'busy']

# SaveRequest (64 bytes): magic op state status key_len key[32] buf len result
REQ_FMT = '<5I32s3I'
REQ_SIZE = struct.calcsize(REQ_FMT)
OFF_STATE, OFF_STATUS, OFF_RESULT = 8, 12, 60
STAT_FMT = '<8I'             # SaveStat
LIST_FMT = '<I32sI'          # SaveListEntry, 40 bytes
LIST_SIZE = struct.calcsize(LIST_FMT)

# Process RAM the OS accepts for the struct and for buf..buf+len.
RAM_LO, RAM_HI = 0x20020000, 0x20080000

# Store format (CART_CART_SAVES_PLAN.md "Store format", save_store.zig): 64 blocks of
# 4 KB, two of them directory copies. Every commit leaves RESERVE_BLOCKS data
# blocks free so any overwrite finds room for its new copy: 46 usable blocks
# (184 KB) and, a key taking at least one block, 46 keys. The directory has
# 63 slots (format constant).
BLOCK = 4096
REGION_BLOCKS = 64
DATA_BLOCKS = 62
RESERVE_BLOCKS = 16
MAX_ENTRIES = 46
DIR_SLOTS = 63
MAX_KEY = 32
MAX_BLOB = 64 * 1024
BURST, REFILL_MS = 8, 10_000
BLOCK_MS = 55.0


def blocks_of(n):
    return (n + BLOCK - 1) // BLOCK


def valid_key(k):
    return 1 <= len(k) <= MAX_KEY and all(0x20 <= c <= 0x7E for c in k)


class Store:
    """The store interface SaveService uses. Keys are bytes. Every call gets
    `now_ms` (the OS's clock, for the rate limiter). write/delete return
    (status, flash_ms)."""

    def read(self, key, now_ms):           # -> bytes, or None if absent
        raise NotImplementedError

    def write(self, key, data, now_ms):    # -> (status, flash_ms)
        raise NotImplementedError

    def delete(self, key, now_ms):         # -> (status, flash_ms)
        raise NotImplementedError

    def stat(self, now_ms):                # -> dict of the SaveStat fields
        raise NotImplementedError

    def keys(self):                        # -> [(key, size)] in directory order
        raise NotImplementedError


class MemoryStore(Store):
    """save_store.zig's rules over a list of directory slots. Slots are
    reused first free (so list order is the order the OS gives); data
    blocks are only counted. Write check order (beginWrite, after the
    service's bad_request / too_big): unchanged blob -> ok (no flash, no
    token); new key with 46 keys stored -> no_space; fewer free blocks than
    ceil(len/4096) (the old copy still exists) -> no_space; a growing commit
    that would leave fewer than 16 free (old copy counted as freed) ->
    no_space; no token -> rate_limited; commit. Delete: not_found (no
    token), rate_limited, commit. The rate bucket starts full (a fresh
    boot)."""

    def __init__(self, rate_limit=True):
        self.slots = [None] * DIR_SLOTS     # [key, data] or None
        self.rate_limit = rate_limit
        self.tokens = BURST
        self.refill_from = 0.0
        self.commits = 0

    # -- helpers
    def _find(self, key):
        for i, s in enumerate(self.slots):
            if s is not None and s[0] == key:
                return i
        return None

    def used_blocks(self):
        return sum(blocks_of(len(s[1])) for s in self.slots if s is not None)

    def free_blocks(self):
        return DATA_BLOCKS - self.used_blocks()

    def count(self):
        return sum(s is not None for s in self.slots)

    def _refill(self, now_ms):
        if self.tokens >= BURST:
            self.refill_from = now_ms
            return
        add = int((now_ms - self.refill_from) // REFILL_MS)
        if add > 0:
            self.tokens = min(BURST, self.tokens + add)
            self.refill_from = now_ms if self.tokens >= BURST else self.refill_from + add * REFILL_MS

    def _take_token(self, now_ms):
        if not self.rate_limit:
            return True
        self._refill(now_ms)
        if self.tokens == 0:
            return False
        self.tokens -= 1
        return True

    def _committed(self):
        self.commits += 1

    # -- Store
    def read(self, key, now_ms):
        i = self._find(key)
        return None if i is None else self.slots[i][1]

    def write(self, key, data, now_ms):
        data = bytes(data)
        i = self._find(key)
        if i is not None and self.slots[i][1] == data:
            return OK, 0.0
        need = blocks_of(len(data))
        if i is None and self.count() >= MAX_ENTRIES:
            return NO_SPACE, 0.0
        free = self.free_blocks()
        old = blocks_of(len(self.slots[i][1])) if i is not None else 0
        if free < need:
            return NO_SPACE, 0.0
        if need > old and free + old - need < RESERVE_BLOCKS:
            return NO_SPACE, 0.0
        if not self._take_token(now_ms):
            return RATE_LIMITED, 0.0
        if i is None:
            i = self.slots.index(None)
        self.slots[i] = [bytes(key), data]
        self._committed()
        return OK, (need + 1) * BLOCK_MS

    def delete(self, key, now_ms):
        i = self._find(key)
        if i is None:
            return NOT_FOUND, 0.0
        if not self._take_token(now_ms):
            return RATE_LIMITED, 0.0
        self.slots[i] = None
        self._committed()
        return OK, BLOCK_MS

    def stat(self, now_ms):
        if self.rate_limit:
            self._refill(now_ms)
        n = self.count()
        spare = max(0, self.free_blocks() - RESERVE_BLOCKS)
        return dict(version=ABI_VERSION, region_bytes=DATA_BLOCKS * BLOCK,
                    free_bytes=0 if n >= MAX_ENTRIES else spare * BLOCK, max_blob=MAX_BLOB,
                    entries=n, max_entries=MAX_ENTRIES,
                    writes_left_now=self.tokens if self.rate_limit else BURST)

    def keys(self):
        return [(s[0], len(s[1])) for s in self.slots if s is not None]


class FileStore(MemoryStore):
    """MemoryStore persisted to a JSON file after every commit (written to a
    temporary file and renamed, so an interrupted run keeps the old one):
    {"format": "badge-bench-saves", "version": 1, "slots": [null |
    {"key": str, "data": base64}]}. A missing file is an empty store. The
    rate bucket is not stored: each run is a fresh boot."""

    FORMAT = 'badge-bench-saves'

    def __init__(self, path, rate_limit=True):
        super().__init__(rate_limit=rate_limit)
        self.path = path
        if os.path.exists(path):
            self._load()

    def _load(self):
        try:
            with open(self.path) as fh:
                d = json.load(fh)
        except (OSError, ValueError) as e:
            raise ValueError(f"--saves {self.path}: unreadable save file ({e})")
        if d.get('format') != self.FORMAT or d.get('version') != 1:
            raise ValueError(f"--saves {self.path}: not a {self.FORMAT} v1 file")
        slots = d.get('slots', [])
        if len(slots) > DIR_SLOTS:
            raise ValueError(f"--saves {self.path}: {len(slots)} slots, at most {DIR_SLOTS}")
        for i, s in enumerate(slots):
            if s is not None:
                self.slots[i] = [s['key'].encode('ascii'), base64.b64decode(s['data'])]
        if self.count() > MAX_ENTRIES or self.free_blocks() < RESERVE_BLOCKS:
            raise ValueError(f"--saves {self.path}: more than {MAX_ENTRIES} keys or "
                             f"{DATA_BLOCKS - RESERVE_BLOCKS} blocks stored")

    def _committed(self):
        super()._committed()
        self.flush()

    def flush(self):
        d = dict(format=self.FORMAT, version=1, slots=[
            None if s is None else dict(key=s[0].decode('ascii'), size=len(s[1]),
                                        data=base64.b64encode(s[1]).decode('ascii'))
            for s in self.slots])
        tmp = self.path + '.tmp'
        with open(tmp, 'w') as fh:
            json.dump(d, fh, indent=1)
        os.replace(tmp, self.path)


class SaveService:
    """The OS side of message 0x2C over a unicorn-like `mem` (mem_read(addr,
    n), mem_write(addr, bytes)). handle(payload, now_ms, frame) serves one
    request and returns the modelled flash ms to charge, or None when the
    word names no struct the OS can answer (outside process RAM). Requests
    are logged in self.log; the exit word registered by exit_watch is in
    self.exit_word (address, or 0)."""

    def __init__(self, mem, store):
        self.mem = mem
        self.store = store
        self.log = []          # dicts: frame, op, key, len, status, result, flash_ms
        self.exit_word = 0
        self.flash_ms = 0.0
        self.ignored = 0

    def _u32(self, addr, v):
        self.mem.mem_write(addr, struct.pack('<I', v & 0xffffffff))

    @staticmethod
    def _in_ram(addr, n):
        return RAM_LO <= addr and addr + n <= RAM_HI

    def handle(self, payload, now_ms, frame=None):
        addr = 0x20000000 + (payload & 0xffffff) * 4
        if not self._in_ram(addr, REQ_SIZE):
            self.ignored += 1
            self.log.append(dict(frame=frame, op='?', key='', len=0, status='ignored',
                                 result=0, flash_ms=0.0, addr=addr))
            return None
        self._u32(addr + OFF_STATE, ST_BUSY)
        status, result, ms, op, key, n = self._serve(addr, now_ms)
        self._u32(addr + OFF_STATUS, status)
        self._u32(addr + OFF_RESULT, result)
        self._u32(addr + OFF_STATE, ST_DONE)
        self.flash_ms += ms
        self.log.append(dict(frame=frame, op=OP_NAMES.get(op, f'op{op}'),
                             key=key.decode('ascii', 'replace'), len=n,
                             status=STATUS_NAMES[status], result=result, flash_ms=ms))
        return ms

    def _serve(self, addr, now_ms):
        magic, op, _state, _status, key_len, key, buf, n, _r = struct.unpack(
            REQ_FMT, bytes(self.mem.mem_read(addr, REQ_SIZE)))
        k = key[:key_len] if key_len <= MAX_KEY else b''
        bad = lambda st=BAD_REQUEST: (st, 0, 0.0, op, k, n)
        if magic != MAGIC or op not in OP_NAMES:
            return bad()
        if op == OP_PROBE:
            return OK, ABI_VERSION, 0.0, op, k, n
        if op == OP_EXIT_WATCH:
            if buf and (buf & 3 or not self._in_ram(buf, 4)):
                return bad(BAD_BUFFER)
            self.exit_word = buf
            return OK, 0, 0.0, op, k, n
        if op in (OP_READ, OP_WRITE, OP_DELETE) and not valid_key(k):
            return bad()
        if op == OP_WRITE:
            if n == 0:
                return bad()
            if n > MAX_BLOB:
                return bad(TOO_BIG)
        if op in (OP_READ, OP_WRITE, OP_STAT, OP_LIST) and n and not self._in_ram(buf, n):
            return bad(BAD_BUFFER)
        if op == OP_READ:
            data = self.store.read(k, now_ms)
            if data is None:
                return NOT_FOUND, 0, 0.0, op, k, n
            m = min(n, len(data))
            if m:
                self.mem.mem_write(buf, data[:m])
            return OK, len(data), 0.0, op, k, n
        if op == OP_WRITE:
            data = bytes(self.mem.mem_read(buf, n))
            st, ms = self.store.write(k, data, now_ms)
            return st, 0, ms, op, k, n
        if op == OP_DELETE:
            st, ms = self.store.delete(k, now_ms)
            return st, 0, ms, op, k, n
        if op == OP_STAT:
            s = self.store.stat(now_ms)
            if n:
                raw = struct.pack(STAT_FMT, s['version'], s['region_bytes'], s['free_bytes'],
                                  s['max_blob'], s['entries'], s['max_entries'],
                                  s['writes_left_now'], 0)
                self.mem.mem_write(buf, raw[:min(n, len(raw))])
            return OK, s['free_bytes'], 0.0, op, k, n
        # OP_LIST: result = rows written (save_store.zig list); totals via stat
        rows = self.store.keys()[:n // LIST_SIZE]
        out = b''.join(struct.pack(LIST_FMT, len(kk), kk, size) for kk, size in rows)
        if out:
            self.mem.mem_write(buf, out)
        return OK, len(rows), 0.0, op, k, n

    def request_exit(self):
        """What "Exit cart" does: write 1 to the exit word. False if none."""
        if not self.exit_word:
            return False
        self._u32(self.exit_word, 1)
        return True

    def exit_word_value(self):
        if not self.exit_word:
            return 0
        return struct.unpack('<I', bytes(self.mem.mem_read(self.exit_word, 4)))[0]

    def summary(self):
        by_op = {}
        for e in self.log:
            d = by_op.setdefault(e['op'], dict(count=0, flash_ms=0.0, statuses={}))
            d['count'] += 1
            d['flash_ms'] += e['flash_ms']
            d['statuses'][e['status']] = d['statuses'].get(e['status'], 0) + 1
        return dict(requests=len(self.log), flash_ms=self.flash_ms, by_op=by_op,
                    commits=getattr(self.store, 'commits', None),
                    keys=[dict(key=k.decode('ascii', 'replace'), size=s) for k, s in self.store.keys()])
