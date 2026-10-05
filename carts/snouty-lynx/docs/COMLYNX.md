# ComLynx in Snouty Lynx

ComLynx is the Lynx's multi-console link: every console of a game hangs
on one open-collector serial line, so a byte one console sends is heard by
every console, its sender included, and two consoles sending at once
garble each other (a low bit wins). This milestone (PLAN.md "M6 ComLynx:
contract", branch `lynx/comlynx`) builds a real Mikey UART, the seam a
transport plugs into, an in-process bus for 2-8 consoles, tests on real
and hardware-test ROMs, the measurements a transport has to meet
(section 7 is written for the session building the USB / lobby
transport), and then the network step on that transport: ComLynx over
the lobby protocol with a PARTY screen (section 10).

## 1. What is built

| Piece | Where | What |
|---|---|---|
| UART | `core/uart.zig`, state `Mikey.uart` | SERCTL/SERDAT, timer 4 baud clock, 11-bit frames, parity / 9th bit, TXRDY/TXEMPTY/RXRDY, two-deep receiver, PARERR/OVERRUN/FRAMERR/RXBRK, RESETERR, TXBRK, the latched serial interrupt, MTEST0 UARTturbo |
| Port | `core/comlynx.zig`, `Lynx.attach_link` | One console's side of the bus: the frames it sent (`out`, stamped with emulated time) and the frames on its wire (`wire`, ANDed when sampled) |
| Slicing | `Lynx.begin_frame` / `run_to` / `finish_frame` | `step_frame` in pieces, so consoles can run side by side in time slices (`step_frame` is now exactly `begin_frame` + `finish_frame`) |
| Virtual bus | `core/comlynx_virtual.zig` | 2-8 consoles in one process: `wire`, `relay` and `timestamped` modes, latency, jitter, power-on stagger |
| Tools | `zig build run-lynx -- ... --uart`, `zig build run-lynx-link`, `tools/comlynx_sweep.py` | One console with a lone port; N consoles on the virtual bus; the Warbirds latency sweep |
| Tests | `tests/comlynx_unit.zig`, `tests/comlynx_warbirds.zig`, `tests/comlynx/ring.s` | Register semantics, lynx-tests uart/uart2/uart3/uart4 result screens, cc65 token rings on 4 and 8 consoles, Warbirds on 2 and 4 |
| Frontend | `cart/src/frontend/linkport.zig`, `lynxnet.zig`, `party.zig` | The `linked` mode (scrubber, chorded rewind and fast forward off), the port in the lent scrub arena, ComLynx over lib/party.zig and lib/cart_serial.zig, the PARTY lobby screen (menu row Party) |
| End to end | `tools/lynx_e2e.zig`, `tools/lynx_e2e.sh` | Warbirds on N host Lynxes through the real `badge lobby` |

**Unlinked nothing changes.** Without a port (`Lynx.link == null`: the
default, and always until a PARTY game starts) Mikey keeps the M1 stub
byte for byte: SERCTL reads $A0, SERDAT 0, TXINTEN holds INTSET bit 4.
The golden frame hashes and every lynx-tests row are unchanged, the CPU
fast path has no new work, and timer 4 stays a quiet timer (section 9 has
the cost).

## 2. UART semantics

Sources: the Epyx hardware appendix (monlynx.de/lynx/hardware.html: the
SERCTL bits, "break received (24 bit periods)"; lynx10.html, the bug
list: "the UART interrupt is not edge sensitive", TXD powers up TTL
high), the timer chapter (timer 4 is the baud generator and its
interrupt bit is the UART's), cc65's `libsrc/lynx/ser/lynx-comlynx.s`
(62,500 baud = timer 4 backup 1 on the 1 us clock; the 9th bit is always
sent; "the receiver will always read the parity and report parity
errors"; "disable the interrupt before clearing it"), the Atari Lynx
programming tutorial part 13 (atarilynxdeveloper, the bit tables), and
above all drhelius's lynx-tests `uart`, `uart2`, `uart3` and `uart4` carts
(MIT, measured on hardware). Gearlynx (GPL) was read for behaviour where
the documents are silent; its two fitted constants are named where used.
Nothing is copied from any emulator.

Registers:

| | Write | Read |
|---|---|---|
| SERCTL $FD8C bit 7 | TXINTEN | TXRDY (holding register empty) |
| bit 6 | RXINTEN | RXRDY (a frame waits) |
| bit 5 | (0) | TXEMPTY (holding and shifter empty) |
| bit 4 | PAREN | PARERR |
| bit 3 | RESETERR (strobe) | OVERRUN |
| bit 2 | TXOPEN (1 open collector) | FRAMERR |
| bit 1 | TXBRK | RXBRK |
| bit 0 | PAREVEN | PARBIT (the received 9th bit) |
| SERDAT $FD8D | the holding register | the oldest received frame |

The model (`core/uart.zig` has the long form):

- **Baud**: one bit is 8 timer-4 underflows (the UART's /8 prescaler,
  free running): bit = (backup + 1) x 8 us x 2^clock. Backup 1 on the
  1 us clock is ComLynx's 62,500 baud: 16 us = 256 ticks a bit, 176 us
  a frame, 5,682 frames a second, 94.7 per 1/60 s. MTEST0 bit 4
  (UARTturbo) gives a bit per microsecond. A linked timer 4 clocks the
  prescaler from its borrows.
- **Frame**: start (0), 8 data bits LSB first, the 9th bit, stop (1).
  The 9th bit is fixed when the frame starts: with PAREN the parity of
  the data (PAREVEN set: even parity, i.e. 1 for an odd number of ones;
  lynx-tests uart2 PARITY), without PAREN the PAREVEN bit itself (mark or
  space). The receiver flags PARERR when the 9th bit differs from what
  its own PAREN/PAREVEN expect (uart4 PARITY LINK: the receiver judges).
  The often-quoted "the parity includes the parity bit" bug is not
  visible between Lynxes (all share the rule) and is not modelled.
- **Transmit timing** (lynx-tests uart, uart3): a write to an idle
  transmitter loads the shifter; the start bit goes out at the next bit
  edge, TXRDY rises one edge later (2 bits after the write: "TXRDY
  IDLE"), the echo is latched mid stop bit (about 11.5 bits), TXEMPTY one
  bit after the stop bit (13 bits: "TXEMPTY IDLE"). A byte written while
  the shifter is busy waits in the holding register (a second write
  replaces it) and starts the moment the frame before ends, with TXRDY
  at once: back-to-back frames are exactly 11 bits apart ("TXRDY FULL",
  "TXEMPTY FULL" 22 bits, uart3 "ECHO GAP").
- **TXBRK** holds the line low and freezes the transmitter; a byte held
  meanwhile starts three bit edges after the release (Gearlynx's fit);
  the console's own receiver is off while it breaks (uart2 "SERCTL
  CHANGE": no RXRDY during a break). TXOPEN clear keeps frames off the
  bus (the console still hears itself).
- **Receive**: the receiver samples its wire (the AND of every frame on
  it, its own included) as a real UART does: a falling edge, the start
  bit checked half a bit in, each bit mid-bit at the receiver's own bit
  time, the frame latched at the middle of its stop bit. A low stop bit
  is a framing error; low for 24 bit times, RXBRK. Two frames on the
  wire at once (a collision) give whatever the AND gives: garbage and
  framing errors (uart4 COLLISION, `comlynx_unit` "collide").
- **The two-deep receiver** (Gearlynx's fit of lynx-tests): a frame
  landing on one unread is kept behind it, except the console's own echo
  arriving within 800 us of the one before, which replaces the newest
  and sets OVERRUN. So at 9,600 baud two echoes are both kept (uart2
  OVERRUN ERR) while at 62,500 a burst of echoes keeps only the newest
  (uart3 BURST ECHO, SLOW READER); a peer's frames always get the
  second place (uart4 OWN ECHO). SERDAT reads the oldest; PARERR,
  FRAMERR, RXBRK and PARBIT read the oldest frame's; RESETERR clears the
  errors and OVERRUN.
- **Interrupt**: the level is (TXINTEN and TXRDY) or (RXINTEN and
  RXRDY). While it is high INTSET bit 4 is set; INTRST clears the bit,
  and it is set again at once while the level holds (uart2 IRQ LEVEL;
  cc65's driver: disable the interrupt before clearing it).
- **Cost**: nothing on the CPU path. The UART catches up when SERCTL,
  SERDAT, INTSET/INTRST, timer 4 or MTEST0 are touched, at
  `Lynx.link_sync`, and at its own Mikey event `uart_event`, which is set
  only for the next bit edge at which an enabled interrupt level could
  rise (none while idle or with interrupts off). Times are Mikey's
  32-bit ticks (no 64-bit arithmetic on the badge).

Deviations: uart TXRDY FULL at 9,600 baud reads $11 where hardware reads
$12/$13 (one 64 us tick: the phase of our 1 us grid against the test's
timer); framing of a remote break is reported once (FRAMERR, RXBRK) and
the receiver waits for the line to go high; a timer-4 change in the
middle of a frame keeps the frame's recorded bit time.

## 3. The bus interface (the transport's seam)

```zig
const comlynx = core.comlynx;
var port: comlynx.Port = .{ .id = my_id, .echo = .local };
lynx.attach_link(&port);          // the real UART; null detaches (stub again)

// every pump point (at least once per badge frame):
lynx.link_sync();                 // the UART caught up: everything sent is in port.out
while (port.take()) |f| send(f);  // f.time: start bit, emulated ticks since reset
                                  // f.bit_ticks, f.data, f.ninth, f.kind (.frame / .break_on / .break_off)
for (received) |r|                // r: comlynx.RxFrame
    _ = lynx.link_deliver(r);     // r.start on THIS console's clock (Lynx.time()); a past
                                  // start is taken as now, after the sender's previous frame
```

- `TxFrame.time` / `RxFrame.start` are 16 MHz ticks on the console's
  `Lynx.time()` scale. A frame handed over with a future start waits on
  the wire until then (deliver ahead of time when you can; the wire
  holds 96 frames). The receiver needs `bit_ticks` (the sender's bit
  time) to rebuild the 11 wire bits; a receiver at another baud reads
  garbage, as on hardware.
- `Port.echo = .local`: the UART puts its own frames on its own wire at
  once (the cable's behaviour); the bus must then not deliver them back.
  `.bus`: the console hears itself only when the bus delivers its frame.
  Warbirds needs `.local` (section 5).
- `Lynx.begin_frame(pad)`, `run_to(t)`, `finish_frame()` split a frame for
  side-by-side stepping; `run_to` stops after the instruction or sprite
  run that reaches `t` (up to ~4 ms late for a long sprite run).
- The port has no pointers and lives anywhere the caller likes (the
  frontend puts it in the lent scrub arena, section 6).

`core/comlynx_virtual.zig` implements three buses over it:

| Mode | Echo | Delivery to the others | Collisions |
|---|---|---|---|
| `wire` | local, at once | start + latency + 0..jitter, per link in order | yes (wired AND) |
| `relay` | through the relay (or `--echo local`) | batches (per frame, per burst, per slice) up to the relay, one total order, then to everyone | no (frames never overlap) |
| `timestamped` | at T + D (or `--echo local`: at once) | at exactly the sender's T + D | yes, identical on every console |

## 4. Hardware rows

Every lynx-tests UART row reproduces except one: `uart` (one console, a
lone port) 5 of 6 (TXRDY FULL at 9,600 baud one tick short), `uart2` 5 of
5, `uart3` 6 of 6, `uart4` on two consoles over the virtual wire 5 of 5 on
both (master and slave elect themselves through the ROM's own logon).
Pinned in `tests/comlynx_unit.zig` (result-screen hashes).

## 5. Tests and latency tolerance

### 5.1 Unit and ROM tests

`zig build test-lynx -Dtest-filter=comlynx` (all in the default
`test-lynx`): `tests/comlynx_unit.zig` (the stub unchanged without a
port; a lone console's TXRDY / echo / TXEMPTY timing; back-to-back
frames 11 bits apart; the 9th bit for each parity mode and PARERR; the
two-deep queue and the 800 us overrun; the latched serial interrupt;
TXBRK; baud from timer 4 and MTEST0 turbo; a collision between two
consoles; the lynx-tests result screens; the token rings),
`tests/comlynx_warbirds.zig` (Warbirds on 2 and 4 virtual consoles, and
that an echo through the bus makes it play alone),
`tests/comlynx_party.zig` (section 10). The Warbirds tests read
`~/roms/lynx/Warbirds.lnx` (Adrian's dump, never committed) and are
skipped without it.

### 5.2 Token rings (tests/comlynx/ring.s)

Our own cc65 program (`tools/make_comlynx_roms.sh` builds it; the
1,057-byte `ring.lnx` is committed): N consoles pass a token (a
two-byte message to the next id), everyone parses the shared stream
(own echo included), console 0 regenerates the token after ~3 timer-6
ticks (33-49 ms) of silence, as a game's master would. Receiver by
serial interrupt or by polling (the joystick held at power on picks id,
N and the mode). Messages per second on console 0 / sequence errors /
regenerations, 600 frames, `COMLYNX_TABLE=1 zig build test-lynx
-Dtest-filter="latency table"`:

| One-way latency | 0 | 1 ms | 2 ms | 5 ms | 10 ms | 20 ms | 30 ms | 50 ms |
|---|---|---|---|---|---|---|---|---|
| 4, irq, wire | 1986/0/0 | 683/0/0 | 405/0/0 | 182/0/0 | 95/0/0 | 93/419/1 | 65/916/1 | 177/181/9 |
| 4, poll, wire | 1993/0/0 | 693/0/0 | 408/0/0 | 183/0/0 | 95/0/0 | 96/357/1 | 65/916/1 | 177/47/10 |
| 8, irq, wire | 1987/0/0 | 683/0/0 | 405/0/0 | 182/0/0 | 95/0/0 | 97/1132/1 | 65/88/1 | 176/1074/9 |
| 8, poll, wire | 1993/0/0 | 693/0/0 | 408/0/0 | 183/0/0 | 95/0/0 | 97/1132/1 | 65/88/1 | 177/1741/11 |
| 4 or 8, relay (frame batches) | 59/0/0 | 59/0/0 | 59/0/0 | 59/0/0 | 119/184/1 | 59/88/1 | 59/88/1 | 98/256/7 |

A pass costs one hop: ~0.5 ms on the wire (two frames and the code), so
the rate is 1 / (latency + 0.5 ms) up to 10 ms, the same for interrupt
and polling receivers and for 4 and 8 consoles (the ring is serial).
From 20 ms the hop nears the watchdog and the regenerated token runs
beside the old one: sequence errors. Through the relay with one batch
per frame every hop waits for its sender's frame end: one pass per
frame (59/s), errors once latency plus a frame passes the watchdog.
The pattern tolerates whatever its own timeout allows; latency costs
throughput, not correctness, below it.

### 5.3 Warbirds on the virtual bus

Warbirds (Atari 1990) is up to four players over ComLynx: the title
shows "N PLAYERS" when it finds the others, the options board then
waits for all players, and the game starts in the cockpit.
`tools/comlynx_sweep.py` runs N consoles (switched on 7, 23 or 41 frames
apart: three trials) with A at 500 and 600 frames, 3,000 frames, and
counts a trial as passing when every console shows N PLAYERS and
reaches the cockpit. Trials passed of 3 (`out/sweep-final.txt` has the
details):

**The echo must be local.** With the console's own echo delayed (the
relay's self-echo, or T + D for the sender too), Warbirds sees nothing
of its own frames in time and every console plays alone:

| Own echo delay | 0 | 0.25 ms | 0.5 ms | 0.75 ms | 1 ms | 2 ms | 4 ms |
|---|---|---|---|---|---|---|---|
| 2 consoles | 3/3 | 3/3 | 3/3 | 3/3 | 0/3 | 0/3 | 0/3 |
| 3 consoles | 3/3 | 3/3 | 3/3 | 1/3 | 0/3 | 0/3 | 0/3 |
| 4 consoles | 3/3 | 3/3 | 3/3 | 0/3 | 0/3 | 0/3 | 0/3 |

(timestamped mode with the echo through the bus; the relay mode with
the echo through it and per-slice batches fails from 1 ms the same way.)

**With a local echo**, one-way latency to the other consoles (`wire`:
peers' frames after a fixed latency, collisions as on the cable; this
is also exactly timestamped mode with D = the latency):

| One-way latency | 0-8 ms | 12 ms | 16 ms | 25 ms | 33 ms | 50 ms | 75 ms | 100 ms | 150 ms |
|---|---|---|---|---|---|---|---|---|---|
| 2 consoles | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 2/3 | 2/3 | 0/3 |
| 3 consoles | 3/3 | 3/3 | 3/3 | 3/3 | 0/3 | 0/3 | 1/3 | 0/3 | 0/3 |
| 4 consoles | 3/3 | 3/3 | 1/3 | 1/3 | 0/3 | 0/3 | 0/3 | 0/3 | 0/3 |

Relay mode (one total order, no collisions, echo local), by batching:

| One-way latency | 0 | 2 ms | 4 ms | 8 ms | 12 ms | 16 ms | 25 ms | 33 ms | 50 ms | 75 ms | 100 ms |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 2, per frame | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 0/3 | 2/3 |
| 2, per burst | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 1/3 |
| 3, per frame | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 0/3 | 2/3 | 0/3 | 0/3 |
| 3, per burst | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 0/3 | 0/3 | 0/3 |
| 4, per frame | 0/3 | 2/3 | 3/3 | 3/3 | 3/3 | 2/3 | 3/3 | 0/3 | 0/3 | 0/3 | 0/3 |
| 4, per burst | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 2/3 | 1/3 | 0/3 | 0/3 | 0/3 | 0/3 |
| 4, per slice | 3/3 | 3/3 | 3/3 | 3/3 | 2/3 | 1/3 | 2/3 | 0/3 | 0/3 | 0/3 | 0/3 |

So Warbirds tolerates, with its echo local: **2 players ~50 ms one way
(sometimes 100), 3 players ~25 ms, 4 players ~12 ms**; its own echo
**under 0.75 ms**. Past the limit the consoles still find each other
(N PLAYERS) but the start handshake stalls or a console miscounts the
players. Batching per frame costs up to a frame (16.7 ms) on top of the
latency (2 players: 50 instead of 75 ms); per burst (a message once the
sender is quiet for a frame time) costs next to nothing. 4 players in
relay mode are erratic at low latency: four consoles answering at once
rely on collisions sorting them out, which a relay without collisions
does not do. The timings here are emulated time; in a timestamped game
they do not depend on the network at all (section 7).

### 5.4 Through the lobby model and the real relay

Section 10: the same Warbirds start over `lib/party_virtual.zig` and
over the real `badge lobby`:

| Run | Result |
|---|---|
| party_virtual, 2 badges, relay mode, 1 / 8 ms one way | pass |
| party_virtual, 2 badges, T + 17, 25, 33, 50 ms | pass (T + 75: fail) |
| party_virtual, 4 badges, relay mode | fail |
| party_virtual, 4 badges, T + 25 and T + 33 ms | pass (T + 17: too many stalls; T + 50: fail) |
| party_virtual, 4 badges at T + 25, one unplugged mid game | the other three play on |
| real relay, 2 badges, relay mode / T + 25 ms | pass / pass |
| real relay, 4 badges, T + 25 ms | pass |
| real relay, 4 badges, T + 25 ms, a rejoin and an unplug mid game | the others play on |
| real relay, 4 badges, relay mode | fail |

The real relay's latency on this VM (localhost TCP, the badges as TCP
listeners, measured from a ComLynx message leaving one badge to its DATA
reaching another): **p50 0.0-0.2 ms, p99 3.6-8.2 ms, max 8-36 ms**
(3,000-18,500 messages a run, two sessions of the default runs). The OS session measured p50 0.16 ms /
p99 5.4 ms for 16 players; USB adds 1 ms frames and the OS loop's
packet a pass, so budget p99 ~8 ms on badges.

## 6. Frontend (linked mode)

`cart/src/frontend/linkport.zig`, as Snouty Boy's link cable: while
`linked` the core has a port, fast forward and the chorded rewind are
ignored and the scrubber is off (the menu's Left/Right do nothing), since
a console that rewinds or speeds up leaves the others behind; the game
also runs on behind the menu (the others do not wait), and a
timestamped badge that must wait for its peers holds the picture. The
ComLynx port's queues (~3.7 KB) live in the scrub arena, lent from the
moment the lobby opens (`rewind.lend` / `take_back`), so being able to
link costs the scrub history nothing; the history restarts empty when
the link ends. Pump points: `before_frame` (drain the cart serial ring:
every frame, the relay removes a badge that stops reading) and
`after_frame` (`link_sync`, then one message with what the UART sent).
The menu's Party row opens the lobby (section 10); linked it reads
Leave party.

## 7. Transport requirements (for the USB / lobby session)

Written for the session building the badge-to-badge transport (fork
firmware `feature/cart-serial`, the lobby protocol v1 relay). The
measurements are section 5; the implementation on this side is section
10. Status against what the lobby offers today:

1. **Carry each ComLynx frame with its 9th bit and its time.** Met:
   lynxnet's 'F' message carries 4 bytes a frame (start time as
   microseconds back from the message's end time, data, the 9th bit,
   break on/off) after an 8-byte header (sequence, the sender's link
   time at the message's end: its heartbeat, the bit time). The 9th bit
   matters: games use it as a marker (mark/space) or parity, and a
   receiver configured otherwise must see PARERR.
2. **The echo stays local; the relay's self-echo is not used for the
   UART.** Hardware loops a console's frame back to its own receiver
   at once (it is one wire), and Warbirds needs that echo within ~0.5 ms
   (section 5.3: every console plays alone from 0.75-1 ms). No relay
   round trip comes close, so lynxnet puts the frame on its own wire
   itself and sends to everyone else (to = 0xFF). The lobby's self-echo
   (to = 0xFE) remains useful for control messages that must land in
   the same order everywhere: lynxnet's GO goes to 0xFE, so every badge,
   the host included, restarts on the same message. If the relay ever
   echoed every frame regardless, lynxnet would have to drop its own
   DATA (it does not feed DATA from itself to the UART).
3. **One total order per room, lossless, in order per sender.** Met by
   the relay. With the echo local, two consoles that send within the
   latency of each other may see the pair in different orders (each its
   own first); Warbirds copes (2-3 players at the latencies above), and
   timestamped mode removes the effect entirely (4).
4. **Timestamped delivery (recommended).** Each frame is stamped with
   its sender's link time T (link time = emulated time since GO, on
   every console); every receiver puts it on its wire at exactly T + D
   of its own link time. A console never steps a frame that would end
   past min over the peers of (their last heartbeat) + D, with 4 ms
   margin (a frame can run on through a sprite run); it holds the
   picture instead (a stall). Every console then sees the same remote
   frames at the same emulated instant whatever the network jitter,
   and a game behaves as on a cable whose other end is D away: tested
   (party_virtual) with 1 ms and 6 + 6 ms of latency giving the
   identical game. Costs: D is extra latency the game must tolerate
   (5.3: 2 players 50 ms, 3 players 25, 4 players ~12-25), and a
   console stalls whenever a peer's heartbeat is older than D. With one
   message per badge frame the heartbeat is up to a frame old on top of
   the relay, so **D >= 16.7 ms + p99 one-way latency + ~4 ms** runs
   without stalls: on USB (p99 ~8 ms) D = 25-33 ms, which suits 2 and 3
   players and is at Warbirds's edge for 4 (the T + 25 runs above pass,
   1 of 3 virtual trials at 25 ms does). Over the internet (tens of ms)
   only 2-player games. Lower D for 4 players needs the badge to step in
   slices of a frame with a heartbeat each (open item, section 11).
5. **Relay mode (D = 0)** is the fallback without stalls: frames go on
   the wire when they arrive. Warbirds: 2 players up to ~50 ms, 3 up to
   ~25 ms, 4 unreliable. Messages per burst or per frame both work;
   lynxnet sends one per badge frame (8 + 4 n bytes, usually 1-10
   frames: under 64 bytes, one USB packet).
6. **No collisions on the transport.** Correct as it is: collisions
   happen on each console's own wire, where frames from different
   senders overlap (timestamped mode reproduces the same overlaps on
   every console, as the cable does). The relay must never merge, drop
   or reorder a sender's messages.
7. **Bandwidth.** At 62,500 baud a sender puts out at most 5,682 frames
   a second = 94.7 per badge frame; 4 bytes each plus the header and the
   lobby's framing is about 23 KB/s per sender at full rate, and a
   receiver takes (N - 1) times that (3 senders: ~70 KB/s, 1.2 KB per
   frame). Warbirds in play sends 1-10 frames per badge frame per
   console (the real-relay run, 4 players: ~80 bytes in and 20-35 out
   per badge frame, lobby framing included).
   The receive ring (2 KiB, drained every frame) holds more than a
   frame of 3 peers at full rate; the relay's 64 KiB per-player limit
   is never near.
8. **Join, leave, rejoin.** A ROSTER without a player = that console
   unplugged (its frames stop, a break it held ends; timestamped peers
   stop waiting for it). A rejoin (LEAVE then a fresh join, maybe with
   another id) is an unplug and a new console; the new console is not
   in the running game (Lynx games find players at power on): the
   frontend drops it back to playing alone. A badge that joins during a
   game waits in the lobby (Warbirds cannot take it in).
9. **ROM identity.** The lobby game id is "LX" + 6 hex digits of the
   ROM's CRC32, so the relay only puts badges running the same dump in
   one room; READY and GO carry the full CRC and a badge ignores a GO
   for another CRC.
10. **Power-on stagger.** GO restarts every badge's console, player k
   after 7 x k frames: Lynxes switched on the same tick mirror each
   other (Warbirds and the lynx-tests elect a master from timers that
   are then identical) and never find a master. Real consoles never
   start together.

## 8. ROMs for a real check

Warbirds (Adrian supplied it 2026-10-05) is the only commercial
ComLynx title tested. For a real check, these dumps (one per console:
every ComLynx game needs a cart in each Lynx), with the maximum number
of consoles from the manuals (AtariAge HTML manuals, archive.org scans),
Robert Jung's reviews and the Lynx FAQ
(amigan.1emu.net/kolsen/faq.html):

| Title | Consoles | Notes |
|---|---|---|
| Todd's Adventures in Slime World | 8 | the only 8-player one; the best stress test |
| Checkered Flag | 6 | polygon 3D; drones fill up to 10 cars |
| BattleWheels | 6 | |
| Gauntlet: The Third Encounter | 4 | |
| California Games | 4 | the manual says 2; 3-4 work |
| Warbirds | 4 | tested here |
| Battlezone 2000 | 4 | polygon 3D |
| Xenophobe | 4 | |
| Super Off-Road | 4 | Telegames |
| Awesome Golf | 4 | |
| Malibu Bikini Volleyball | 4 | the FAQ says 2; 2-on-2 |
| Jimmy Connors Tennis | 4 | doubles |
| Tournament Cyberball 2072 | 4 | |
| Rampage | 4 | |
| Zarlor Mercenary | 4 | |
| Hockey, Baseball Heroes, Rampart, Robo-Squash, Lynx Casino, Basketbrawl, Pit-Fighter, Double Dragon, Joust, NFL Football, Xybots, World Class Soccer, European Soccer Challenge, Shanghai, Super Skweek, Bill & Ted's Excellent Adventure, Turbo Sub | 2 | |
| Hyperdrome, Championship Rally (late releases) | 4 | Championship Rally's 4 is doubtful |
| Road Riot 4WD (2003 prototype release) | 2 | reported buggy in ComLynx |

The most useful to ask for: Slime World (8 consoles, the bus's limit),
Checkered Flag (6, 3D), Gauntlet III and Xenophobe (4, action), and a
2-player one with a different driver (Joust or Robo-Squash).
Single-player despite their reputation: Hard Drivin', Blue Lightning,
S.T.U.N. Runner, Steel Talons (the Lynx dropped the arcade's 2 players),
Electrocop, Ninja Gaiden, Klax, Toki, Paperboy, A.P.B., RoadBlasters.

## 9. Cost

badge-bench, calibrated, busy ms (mean / p95 / worst), RAM cart, the
default unlinked state, against origin/main e21702ce built the same way:

| Script | origin/main | this branch (UART only) | this branch (final) |
|---|---|---|---|
| m3_scrub (480 frames) | 6.17 / 9.49 / 10.76 | 6.18 / 9.50 / 10.78 | 6.18 / 9.50 / 10.78 |
| m2_play (400) | 6.75 / 9.02 / 10.27 | 6.76 / 9.03 / 10.28 | 6.76 / 9.03 / 10.28 |
| hd_drive (1,800, local dump) | 8.86 / 11.82 / 15.56 | 8.86 / 11.82 / 15.55 | 8.86 / 11.82 / 15.55 |

0 frames over budget in every run: unlinked the UART costs nothing per
frame (the CPU path is unchanged, timer 4 stays quiet).

Memory (RAM cart, `size -A`, `__bss_end__`): origin/main .text 105,772 B,
.bss 92,460 B, scrub arena 73,324 B (0x20078000 - 0x20065d94 - 1 KB
guard). Final: .text 126,888 B, .bss 96,396 B, arena 47,740 B
(-25,584 B: about a third less scrub history). Of that, the UART and
the port in the core ~6.2 KB of code; the lobby client (party.zig),
lynxnet, the PARTY screen and cart_serial ~14.5 KB of code; the static
serial rings and client 3.9 KB of .bss. The ComLynx port's queues
(~3.7 KB) are in the lent arena, not .bss. XIP cart: code in flash,
.bss +3.9 KB (arena 177 KB).


## 10. The network step (lobby protocol v1)

`cart/src/frontend/lynxnet.zig` (generic over the client type, no
cart-api, host-tested), on `lib/party.zig`'s client over
`lib/cart_serial.zig`'s `Badge` port (frontend/linkport.zig). Messages,
the payload of one SEND / DATA:

| Type | Bytes | When |
|---|---|---|
| 'F' frames | `seq u8`, `t_end u32` (link us), `bit16 u16`, then per frame `back u16` (us before t_end), `data u8`, `flags u8` (bit 0 9th bit, 1 break on, 2 break off) | every badge frame while linked, to 0xFF (an empty one is the heartbeat); split at 58 frames |
| 'R' ready | `ready u8`, `d_ms u8`, `crc u32` | each roster change and twice a second in the lobby |
| 'G' go | `d_ms u8` (0 relay mode), `crc u32` | the host, to 0xFE |

The PARTY screen (`cart/src/frontend/party.zig`) follows Snoutenstein's
M8 lobby: NEEDS PARTY FIRMWARE / START BADGE LOBBY ON THE LAPTOP /
JOINING..., then the room (roster in id order with READY, the host's
SYNC row: RELAY or T+17/25/33/50 MS, default T+25), A ready, the host's
Start goes when everyone is, B back. GO restarts every badge's game
linked, player k 7 frames after player k - 1.

Tests:

- `tests/comlynx_party.zig` over `lib/party_virtual.zig` (the model of
  `badge lobby` and the badges' USB): Warbirds on 2 badges in relay mode
  and 4 at T + 25 reach the game; timestamped mode is the same game at
  1 ms and 6 + 6 ms of latency (frame hashes equal, nothing late); a
  badge unplugged mid game leaves the other three playing.
  `COMLYNX_TABLE=1 ... -Dtest-filter="lobby sweep"` prints the sweep of
  section 5.4. The party libs come in through `lib/party_host.zig`, a
  three-line module re-exporting them (party_virtual.zig imports
  party.zig itself, and a file can belong to one module only).
- `carts/snouty-lynx/tools/lynx_e2e.sh` (needs the fork checkout,
  pyserial and the dump; ports 27500-27549): N host Lynxes behind TCP
  listeners, the real `badge lobby`, the cart's own network code at
  60 Hz. Defaults: 2 badges relay, 2 at T + 25, 4 at T + 25, 4 at T + 33,
  4 at T + 25 with a rejoin and an unplug. Prints the relay latency.

## 11. Not done / open

- **Sub-frame heartbeats.** Timestamped mode needs D of at least a badge
  frame plus the relay's p99, ~25 ms on USB; Warbirds with 4 players is
  reliable only to ~12 ms. Stepping the frame in 2-4 slices
  (`begin_frame` / `run_to` / `finish_frame` exist) with a pump and a
  heartbeat after each would bring D down to a slice plus the latency.
- **No hardware run.** Everything here is host-side: the UART against
  the lynx-tests hardware measurements, the network against the lobby
  model and the real relay over TCP. Nothing has run on a badge.
- **One commercial title.** Only Warbirds; section 8 lists the rest.
- `uart` TXRDY FULL at 9,600 baud (one tick); a timer-4 change mid
  frame; a remote break's RXBRK timing (section 2).
- A rejoined badge plays alone until the next GO (Lynx games find their
  players at power on); a badge that joins mid game waits in the lobby.
- The scrub arena is a third smaller in the RAM cart (section 9).
