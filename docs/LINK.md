# Badge-to-badge link cable

Two SYCL Badge V2s joined by a cable on their UART headers, for multiplayer:
a Game Boy link cable in Snouty Boy first, then two-player Snouty Zero and
a Snoutenstein deathmatch. The shared code is `lib/link.zig`; the test cart
is `carts/snouty-link`.

## 1. The cable

The badge has three small JST-SH (1.0 mm pitch) headers. From the V2 KiCad
files (`sycl-badge/kicad/v2`):

| Header | Connector | Pins | For the link |
|---|---|---|---|
| UART (J4) | JST-SH 3-pin, Raspberry Pi debug style | 1 = GPIO28, 2 = GND, 3 = GPIO29; 100 R in series on 1 and 3 | **this one** |
| I2C (J2) | JST-SH 4-pin (Qwiic / STEMMA QT) | GND, 3V3, SDA = GPIO12, SCL = GPIO13, 10k pull-ups | not used |
| SWD (J3) | JST-SH 3-pin | debug only | no |

Use a **JST-SH 3-pin to 3-pin cable** between the two UART headers. Either
kind works: crossed (pin 1 to pin 3, TX to RX) or straight (pin 1 to pin 1,
as Raspberry Pi debug-probe cables are believed to be). The link finds out
which and swaps its pins to match. A Qwiic (4-pin) cable does not fit the
UART header.

Nothing in either OS uses UART0, GPIO28/29 or PIO2 (checked in the pinned
SDK a6ce19f and upstream 5955625): the OS console is USB, pio0 is audio and
pio1 the neopixels. The cart drives the pins itself from core 1.

## 2. How the link works

- **Search.** Each badge drives one of its two header pins high (an idle
  UART line) and listens on the other, flipping which at random every
  40-120 ms. When it hears a high line for 5 ms it locks: the partner is
  driving the pin it listens on. A crossed cable locks both badges in the
  same mode; a straight cable locks them in opposite modes. Outputs only
  drive high while searching, so two outputs never fight.
- **Handshake.** Once locked, the pins become a 1 Mbaud 8N1 UART on PIO2
  (`lib/link_rp2350.zig`; PIO rather than the UART0 block because UART0's TX
  is fixed on GPIO28). The badge sends HELLO every 20 ms, but only while
  its receive line is high: then the partner is driving that line, so it is
  not also driving ours. Hearing a HELLO means connected. No HELLO within
  1.5 s: search again.
- **Connected.** Packets are SLIP-framed `kind, body..., crc8, END`. The
  link answers HELLO, KEEPALIVE and PING itself and queues DATA packets (up
  to 12 bytes) for the cart. A keepalive goes out every 250 ms; nothing
  heard for 2 s, or the receive line low for 30 ms (cable out), means the
  partner is gone: search again.
- **Sessions.** Each lock picks a random nonce that travels in HELLO. When
  the partner's nonce changes (its cart restarted) or our own link locked
  again, `session` goes up: a cart restarts its game protocol whenever
  `session` changes.

### Using it from a cart

```zig
const link = @import("link"); // build.zig: cart.addImport("link", lib/link.zig)

var l: link.Badge = undefined;
// start():
l = link.Badge.init(.{}, 'B', cart.rand()); // app id: the partner sees it in partner_app
// update(), and in a loop while waiting for the partner:
l.poll(cart.micros_since_boot());
if (l.connected()) _ = l.send(now, &.{ 1, 2, 3 });
while (l.recv()) |p| use(p.slice());
```

`link.Badge` uses PIO2 on the badge and is `.unavailable` in the wasm
simulator. Host tests use `lib/link_virtual.zig`, a simulated cable with
both orientations that counts fights and lost bytes.

### Limits to design around

- **Receive buffer = the PIO FIFO, 8 bytes.** `poll` empties it into the
  parser. A DATA packet of n bytes is n + 3 wire bytes, plus one for each
  0xC0 or 0xDB byte in it. If more than 8 wire bytes arrive between two
  polls, bytes are lost and the CRC drops that packet. So keep packets short
  (n <= 5 is always safe), poll at least once per frame, and poll in a loop
  while waiting for the partner.
- **Optional DMA receive ring.** `link.rp2350.rx_dma = 11` (any cart
  channel, 3-15) before the link locks, or followed by `restart`, makes
  a DMA channel copy every received byte into a 256-byte ring, so nothing
  is lost however long the cart goes between polls. It is safe on every
  firmware since March 2026 (the pinned a6ce19f too): the OS aborts cart
  DMA channels 3-15 when a cart stops, by either exit path
  (`reset_after_cart`); on older firmware the channel would keep writing
  into the next cart's RAM. Off by default, and no game depends on it
  (Adrian: occasional loss is fine, no firmware update required). The
  test cart's Up switches it. Snouty Lynx's link cable runs with it on
  and passed on two badges (2026-10-05, carts/snouty-lynx/docs/CABLE.md).
- **Delivery is best effort.** A dropped packet is gone (`stats`
  counts CRC errors and framing errors). Lockstep games resend or carry
  enough state to recover.
- **After the cart exits** PIO2 keeps running: the transmit pin idles high
  and the partner may think we are still there until its 2 s timeout. The
  next cart that starts the link resets PIO2.
- **Restart while connected.** If the partner restarts and searches in the
  mode that drives our transmit wire, a keepalive we send meets its high
  output for a few microseconds. The two 100 R series resistors limit that
  to about 16 mA, which the pads tolerate.
- **Clock.** The divider assumes clk_sys = 150 MHz, which neither OS
  changes (badge-bench's hardware capture measured it). Both badges share
  the assumption, so a wrong guess would change the baud rate on both
  sides alike.

## 3. Plan

### M0: the link and a test cart (done, verified on hardware)

- `lib/link.zig`, `lib/link_rp2350.zig`, `lib/link_virtual.zig`,
  `lib/tests/link_unit.zig` (in `zig build test`).
- `carts/snouty-link`: shows state, the two header pins while searching,
  cable orientation, partner app/version/session, round trip, received
  and lost packets, CRC and framing errors, and both badges' buttons.
- badge-bench fakes the link registers with no cable plugged in.
- Added after M1: Up switches the receiver between the PIO FIFO and the
  DMA ring (`F`/`D` on the MODE line, `FIFO`/`DMA` on the CABLE line).
  **Hardware check:** connected, LOST should stop rising with DMA on both
  badges; it rises now and then with FIFO.

Status 2026-10-04: host tests pass for both cable kinds over 200 seeds
each, at 1 ms and at frame-rate polling (worst connect 0.08 s crossed,
0.5 s straight), with no fights; data with SLIP bytes intact; a corrupted
packet dropped by the CRC; unplug and replug; partner restart; silent
partner timeout; ping. The PIO programs match microzig's assembler for
RP2350 word for word. The cart runs in badge-bench (12 ms a frame by
design: it polls the link until 12 ms into each frame so pings come back
at wire speed).

**Hardware, 2026-10-04 (show day).** Carl's badge: self test OK on both
pins; with a Raspberry Pi Debug Probe at 115200 the badge locks on the
probe's line, its HELLOs reach the terminal and 20 typed characters gave
20 received bytes. Carl's badge and a fresh badge on the probe kit's
JST-SH cable at 1 Mbaud: CONNECTED, STRAIGHT, each badge shows the
other's buttons instantly. RTT read ~2.4 ms: the test cart only polls
after drawing, so that is its own frame schedule (the wire round trip is
~0.1 ms). About 40 packets LOST, rising occasionally: the 8-byte FIFO
overflows when a DATA packet and a PONG arrive while the cart draws. Fix
first in M1 (DMA receive ring on firmware that aborts cart DMA at exit).
Adrian's own badge: GPIO29 reads high with nothing attached even right
after being driven low, and PIO never moved GPIO28 (registers all
correct): treat its UART header as faulty. RP2350-E9: a pull-down input
can float latched high, so the search probes the listen pin (drive low
2 us, release, read) before trusting a high.

**Hardware check (Adrian):** flash `snouty-link.uf2` on two badges, join
the UART headers, start Snouty Link on both. Expected within a second:
CONNECTED, the cable kind, RTT around 100-300 us, RX climbing about 60 a
second, LOST and CRC at 0, and each badge lighting the other's buttons.
If it stays SEARCHING, note PIN1/PIN3 on both screens and the cable kind.

### M1: Game Boy link cable in Snouty Boy (done, verified on hardware)

- `carts/snouty-boy/core/serial.zig`: byte-level cable. The master's
  internal-clock transfer sends a request (SB, sequence number) and keeps
  the CPU running, as the real shift register does; it completes once the
  byte time has passed (1024 M-cycles, 32 with the CGB fast clock) and the
  reply is in, so a late reply only looks like a slow transfer. Resend
  after ~4 ms, give up with 0xFF after ~0.25 s. The slave answers each
  request with its SB, completing its own transfer only if one is waiting
  on the external clock; a repeated request gets the cached reply. The
  wire is three bytes a message (6 on the wire), within the 8-byte FIFO.
  `Gb.link` null (no partner): the old stub, unchanged.
- `cart/src/frontend/linkport.zig`: `link.Badge` with app id 'B'; the core
  gets the wire only while the partner runs Snouty Boy. Between frames the
  cart keeps answering until 14 ms into the update
  (`tuning.link_pump_until_us`). While linked: no fast forward, no chorded
  rewind, no menu scrubbing, no recording (linked frames cannot replay);
  the history restarts at plug and unplug. A strip says "Link cable
  connected" / "unplugged" for 2 s.
- Tests (`tests/link_unit.zig`): exchange timing, lost requests and
  replies, a slave that is not waiting, timeout, no-wire stub; two Tetris
  consoles (your own `tests/roms/tetris.gb`, skipped without it) reach the
  same 2-player game with identical playfields, also with every 5th
  message dropped each way. `tests/flow_unit.zig`: linked, the fast
  forward and rewind gestures do nothing.
- badge-bench (Tetris from a drive image, no cable): mean 6.91 ms vs 6.95
  before, worst 11.04 vs 11.12; 2048 3.44 vs 3.41: no cost.

**Hardware check:** two working badges with Snouty Boy and Tetris on the
drive, UART headers joined. "Link cable connected" shows on both; on each,
Start, Right to 2PLAYER, then Start on one badge first (it becomes the
master) and on the other; both reach MARIO VS. LUIGI and play the same
pieces. Pulling the cable shows "Link cable unplugged".

**Hardware, 2026-10-05 (show day).** Adrian played a full 2-player Tetris
game between two badges over the probe kit's JST-SH cable: works.

### Lockstep games: `lib/lockstep.zig` (tag lockstep/v1)

Two-badge lockstep shared by every link game, extracted from Snouty GC's
M4 net code (verified on two badges, `snouty-gc/m4-hw`): lobby, input
exchange, desync check, pause, peer-left hand-over, version check. One
rules byte is byte-identical to GC M4; 2-8 bytes use a paged SETUP.
`docs/LOCKSTEP.md` is the guide (API, the game's `G`, protocol, pump
policy, common screen wording, app ids). Users: Snouty GC (`net.zig`,
wrapper on branch `link/gc-lockstep` under GC's review), Snouty Cycles
(link duel, in progress), Snouty Zero, Snoutenstein.

### M2: two-player Snouty Zero (done, hardware check open)

LINK RACE in the main menu (tag `snouty-zero/m6`; `carts/snouty-zero`
PLAN M6, RUNNING section 9): the host picks the track, both pick a
machine, the guest drives a rival's slot; pause together, no rewind, the
AI takes over a machine whose badge leaves.

### M3: Snoutenstein deathmatch (done, hardware check open)

DEATHMATCH on the title (tag `snoutenstein/m7`; `carts/snoutenstein`
PLAN M7, RUNNING section 7): Server Room or Build Farm DM, frag limit,
bugs on/off; B + Left/Right strafes; a partner leaving is a forfeit win.
