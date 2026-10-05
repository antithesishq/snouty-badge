# Cart saves

Carts can keep small named blobs (emulator battery RAM, game progress,
high scores) that survive cart switches, power-off and OS updates. The
badge OS stores them in internal flash, in the 256 KB that used to be the
XIP cart window; USB never sees them, so a mounted drive cannot corrupt
them and they take no room on it.

This is on branch `saves/m1` only. It is not merged to main while it
needs a patched OS.

## 1. It needs the patched OS

Saves are a feature of a patched SYCL OS: sycl-badge branch `cart-saves`
(in the SYCL badge fork: `feature/cart-saves`). Its `fork/CART_SAVES_PLAN.md`
is the frozen ABI v1 spec, store format and hardware test, and
`fork/CART_SAVES.md` the cart author's guide. Flash the OS UF2
built from that repo (`sycl-os-saves.uf2`: BOOT_SEL + RESET, then copy it
to the RP2350 drive). Keep the organizers' OS UF2 so you can go back.
That OS refuses XIP carts. Only RAM carts run on it.

Stock firmware ignores the save message. On stock firmware, in the web
simulator and in wasm builds, `save.supported()` is false and every call
returns `error.Unsupported`. **A cart must hide its Save and Load entries
when `supported()` is false.** It must not show an entry that always
fails.

## 2. API: `lib/save.zig`

Add the module in the cart's `build.zig` (`cart.addImport("save",
b.createModule(.{ .root_source_file = b.path("lib/save.zig") }))`), then
`const save = @import("save");`.

```zig
pub const Error = error{ Unsupported, NotFound, NoSpace, BadRequest, BadBuffer, RateLimited, TooBig, IoError, Busy };
pub const max_key = 32;
pub const max_blob = 64 * 1024;
pub const Stat = extern struct { version, region_bytes, free_bytes, max_blob, entries, max_entries, writes_left_now, _r: u32 };

pub fn supported() bool;                                 // probe once per boot, cached
pub fn read(key: []const u8, dst: []u8) Error!usize;     // stored size (may exceed dst.len; copies min)
pub fn write(key: []const u8, src: []const u8) Error!void; // blocking, atomic
pub fn delete(key: []const u8) Error!void;
pub fn stat() Error!Stat;
pub fn list(out: []ListEntry) Error!usize;               // rows written (<= out.len); total = stat().entries
pub fn watchExit() Error!void;                           // ask for a warning before "Exit cart"
pub fn exitRequested() bool;                             // the OS wrote 1 to our exit word
pub fn exitReady() void;                                 // saved: the OS may stop us now (writes 2)
```

| Error | Meaning |
|---|---|
| `Unsupported` | stock firmware, simulator or wasm: no saves |
| `NotFound` | no such key (read, delete) |
| `NoSpace` | a new key, or an overwrite that grows a key, would eat into the 16-block reserve; or 46 keys are already stored |
| `BadRequest` | key not 1..32 bytes of printable ASCII (0x20..0x7E), or an empty blob |
| `BadBuffer` | the buffer is not in cart RAM (for example a pointer into a drive ROM: copy the data to RAM first) |
| `RateLimited` | too many commits: 8 in a burst, then one more per 10 s. Nothing was written, so try again later |
| `TooBig` | blob over 64 KB |
| `IoError` | a stored blob failed its CRC on read (the key stays, so you can rewrite it), or a status this client does not know |
| `Busy` | the OS was serving another request, or left this one pending for 2 s |

Limits: 1..64 KB per blob, at most 46 keys, 184 KB (46 blocks of 4 KB)
in all. Every blob takes whole blocks, so a 100-byte save uses 4 KB. The
store has 62 data blocks, but every commit leaves 16 of them free (one
64 KB blob's worth), so an overwrite that doesn't grow a key always has
room for its new copy and never fails with `NoSpace`. `stat().free_bytes`
is what a new key could take now (0 at 46 keys).
`stat().region_bytes` is the 62-block data capacity (248 KB).

Backends are chosen from the build target. The badge backend runs on the
cart core and speaks ABI v1 over the mailbox itself, because the pinned
SDK has no save API. `none` is for wasm. `fake` is for host builds and
tests: an in-memory store with the OS's rules. Its hooks are
`save.fake.reset()`, `setSupported(false)` (acts like stock firmware),
`setExitRequested()`, `exitWord()`, `advanceMs()` (the rate limiter's
clock), `setRateLimit()`, `failNext(err)`, `commits()`, `flashMs()`,
`reboot()` and `peek()`. lib/tests/save_unit.zig shows them in use.

## 3. Keys

Use `<cart>/<slot>` so carts never collide:

- `boy/<header title>/<global checksum>`: Snouty Boy battery RAM, one key
  per game. The checksum keeps two ROMs with the same title apart.
- `paperclips/game`
- `gcp/career`

Keys are 1..32 bytes, so shorten long titles. The OS does not enforce the
`/` convention.

## 4. What a save costs

`write` and `delete` block. The cart is parked inside the call, with
interrupts masked, while the OS erases and programs flash. Expected cost
(CART_SAVES_PLAN.md, datasheet typical, still to be measured on a badge) is
**(ceil(len / 4096) + 1) x 55 ms**: each 4 KB data block plus one
directory block. That is ~0.1 s for 1 KB, ~0.5 s for 32 KB and ~0.9 s for
64 KB. A delete costs one directory block (~55 ms). badge-bench charges
exactly this (section 7).

A write whose bytes equal the stored blob returns at once. It costs no
flash and no rate-limit token, so "save if anything changed" can simply
call `write`. `read`, `stat` and `list` are quick.

On stock firmware the first `supported()` waits 250 ms for the probe to
time out, once per boot. Call it in `start()` or when the menu first
opens, never mid-game.

**No flash reads during a save.** While the OS erases flash it switches
XIP off, so nothing on the cart core may touch a 0x10xxxxxx address during
a `write` or `delete`: no drive ROM reads (lib/romfs.zig pointers), no
interrupt handler running from flash. `lib/save.zig` parks the cart in a
RAM-resident loop with PRIMASK set until the OS is done. An emulator that
reads its ROM by pointer is safe, because it is not running then. `src`
must be in cart RAM, so copy drive data into RAM first.

## 5. When to save

- **On menu open.** The player pauses and expects a hitch.
- **On an exit request** (section 6).
- **When the game is idle after its own save.** For battery RAM, flush
  about 1 s after the game stops writing SRAM, at most once per 30 s.
- On an explicit Save entry in the cart's menu, if it has one.

Never save every frame, and do not save on a timer while the player is
active. The rate limiter will refuse it (`RateLimited`), and each commit
freezes the cart for at least 110 ms.

## 6. The exit hook

The settings box (Start+Select) has an "Exit cart" entry that would
otherwise stop the cart at once. To save first:

```zig
pub fn start() void {
    if (save.supported()) save.watchExit() catch {};
}

pub fn update() void {
    if (save.exitRequested()) {
        flush_save();            // save.write(...) if anything changed
        save.exitReady();        // the OS may stop us now
        return;
    }
    ...
}
```

Calling `watchExit()` again resets the word to 0, so an earlier request is
forgotten. After `watchExit()` the OS writes 1 to an exit word in cart RAM when the
player picks "Exit cart". It shows "Saving...", keeps serving save
requests, and stops the cart once the cart calls `exitReady()` (which
writes 2) or after 3 s. Check `exitRequested()` once a frame. The OS
forgets the word when the cart stops.

## 7. Testing

- Host tests: `zig build test` runs lib/tests/save_unit.zig against the
  fake. A cart's own host tests can use `save.fake` the same way.
- badge-bench serves save requests by default, from an empty in-memory
  store. `--saves FILE.json` keeps the store in a file across runs.
  `--no-saves` acts like stock firmware: requests are never answered, so
  the probe times out. `--no-save-rate-limit` turns the rate limit off.
  `--exit-at N` plays "Exit cart" before update N. A frame that saved
  shows `[save N ms]`, and the report sums the requests
  (badge-bench/README.md "Cart saves").
  `badge-bench/tests/test_saves.py` runs lib/save.zig's badge backend,
  built for the M33, against the bench's service.
- On the badge: CART_SAVES_PLAN.md "Hardware test" (the OS repo's save-test
  cart).
