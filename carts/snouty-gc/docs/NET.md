# Snouty GC netcode: two badges, one race

`cart/src/net.zig` runs a two-badge race in deterministic lockstep over
the link cable (`lib/link.zig`, root `docs/LINK.md`). SPEC section 7 is
the design and PLAN "M4 Link" the contract. This file covers the
protocol, how `main.zig` drives it frame by frame, and what the
integration track (M4 Track B) still has to build.

The idea: both badges hold the same `World`, and `sim.simulate(w,
inputs)` is pure in `(World, inputs)`. So the badges exchange only the
two humans' input bytes, one byte per tick each, and both simulate every
tick with the same pair. Nothing else reaches `simulate`: no clock, no
`cart.rand`, no render state, only the agreed bytes and the agreed setup.

## 1. Files

| File | What |
|---|---|
| `cart/src/net.zig` | `Net(L)`: lobby, input rings, packets, `step`, pause, peer-left hand-over, desync check, `world_hash` |
| `cart/src/net_test.zig` | two `Net` + two `World`s on a `lib/link_virtual.zig` cable with byte loss and the 8-byte FIFO |
| `carts/snouty-gc/build.zig` | `link` import for the cart module; `link_host` (link.zig + link_virtual.zig copied under one root) for the tests |

`Net` is generic over the link: `net.Net(link.Badge)` in the cart
(PIO2 on the badge, `.unavailable` in the wasm simulator), and a
`link.Link(...)` over the virtual cable in the tests. It owns the link
by value (`n.link`).

## 2. Protocol

### 2.1 Roles and the lobby

When the link connects (a new `link.session`), `Net` checks
`link.partner_app == 'G'` (else `wrong_cart`) and picks the roles: the
badge whose HELLO nonce is higher is the **host** (input slot 0), the
other the **guest** (slot 1). Equal nonces (1 in 65536) restart the link
for new ones.

Control messages are link DATA packets with a kind byte first. None is
5 bytes long: a 5-byte packet is always an input packet.

| Kind | Bytes | Sent by | When |
|---|---|---|---|
| `SETUP` 0xA1 | kind, race id, rules | host | lobby, every 100 ms (alternating with PICK) |
| `PICK` 0xA2 | kind, race id, pick | both | lobby, every 100 ms (host) / 50 ms (guest) |
| `GO` 0xA3 | kind, new race id, rules, racers | host | after `go()`, every 100 ms until the guest's first input arrives |
| `QUIT` 0xA4 | kind, race id | both | first message after `leave()` |
| `DESYNC` 0xA5 | kind, race id | both | every 50 ms after finding a desync |

- **rules**: track bits 0-3, crews bits 4-6 (the AI count), mode bit 7
  (0 LINK RACE, 1 LINK GC).
- **pick**: racer bits 0-2 (7 = none), ready bit 7.
- **racers**: host's racer bits 0-2, guest's bits 4-6.
- **race id**: the last race this badge joined this session (0 = none).
  A badge sends control messages only from the lobby, so a message
  carrying the id of the race the receiver is running means the sender
  left it: `peer_left` with `left = .quit`. Older ids are stale and
  ignored.

The lobby is state broadcast: each message repeats the sender's whole
state, so a lost one is replaced by the next. At most one control
message goes out every 20 ms (`timing.ctrl_gap`), and each is at most
7 wire bytes, inside the 8-byte receive FIFO.

`GO` carries everything: id, rules, both racers. The seed is not sent:
both badges derive it from the two link nonces and the race id
(`seed_of`). The guest accepts a GO only in the lobby and only for a new
id, and adopts it whatever its own pick says (the host decided).
The host's `can_go` needs both picks ready on different racers, and a
PICK heard since the host's last race (the guest is really in the lobby).

### 2.2 The input packet (always 8 wire bytes)

5 payload bytes, the input bytes of three consecutive ticks n-2, n-1, n:

| Byte | Content |
|---|---|
| 0 | n mod 64 (bits 0-5), salt (bits 6-7) |
| 1 | input byte for tick n |
| 2 | input byte for tick n-1 |
| 3 | input byte for tick n-2 |
| 4 | check piece (7 bits) |

On the wire: kind 0x10, the 5 bytes, CRC8, END = **8 bytes, always**.
SLIP would add a byte for every 0xC0 or 0xDB, and this layout never has
one: input bytes never hold Start and Select together (the OS chord;
`sanitize` clears both, as `input.zig` does), so they are never 0xC0 or
0xDB; the check piece is below 0x80; and byte 0's salt (0x00, 0x40 or
0x80) is picked so that the link's CRC is neither (the three salts give
three different CRCs and only two values are bad). So a whole packet
always fits the PIO's 8-entry receive FIFO, even when the receiver polls
only once between two packets.

The receiver takes the full tick from its low 6 bits as the value
nearest the next tick it lacks (packets are never more than a few ticks
off), and stores each byte that extends its contiguous run of the
partner's inputs.

### 2.3 Lockstep

- **Input delay 2.** Each frame `submit` stores this frame's byte as the
  input for tick `local_hi`, at most `tick + 3` (so it drives tick
  frame + 2), and sends a packet with the newest three local ticks.
  Ticks 0 and 1 are all-zero on both badges.
- **`step`** runs tick `tick` only when both bytes for it are held; one
  successful `step` per frame, so the World runs at the frame rate. A
  frame without the partner's byte is a stall: the badge redraws and
  keeps pumping and retrying (the waiting loop). While stalled,
  `submit` drops the frame's buttons (the local buffer is full).
- **Lost packets.** Each tick travels in three consecutive packets. A
  badge that lacks a tick stalls, stops submitting, so its newest tick
  stops moving; its partner sees that (`timing.peer_stalled`, 25 ms) and
  then alternates the newest window with one starting at the tick the
  staller needs (its newest minus the delay: exact while it is stalled).
  Packets go out once a frame (`submit`) or every 20 ms while nothing is
  new (`timing.resend`), never closer than 12 ms (`timing.min_gap`), so
  the partner's FIFO sees about one packet a frame. No acknowledgements,
  no retransmit protocol.
- **Clock drift.** Each badge keeps its own 60 Hz vsync; the faster one
  stalls a frame now and then.

### 2.4 Desync check

Every 32 ticks (after tick 32e) each badge hashes its World
(`world_hash`: every field by reflection, so struct padding never counts;
1,356 field mixes, a few tens of microseconds on the badge). The packet
whose newest tick is n carries 7-bit piece `(n - 8) mod 4` of the hash
of epoch `(n - 8) / 32` (the 8-tick lag makes sure both badges have
taken that hash). A piece that differs from the receiver's own is a
**desync**: `step` stops, and the badge sends `DESYNC` so its partner
stops too (it may never get the piece that would show it). Found on both
badges at most 32 ticks after the Worlds part in the tests.

### 2.5 Pause, quit, peer gone

- **Pause** is in the lockstep: a Start press edge in either human's
  byte toggles `paused` on the tick it lands, on both badges. Paused
  ticks still run (`tick` advances, inputs flow, hashes are taken) but do
  not call `simulate`. A finished race is never paused.
- **Quit** is `leave()`: back to the lobby, `QUIT` to the partner.
- **Peer gone**: the link drops (cable out: about 40 ms; partner silent:
  `link.timing.peer_timeout`, 2 s), its session changes (the partner's
  cart restarted), or a `QUIT` / lobby message with this race's id:
  `peer_left` with `left` = `.unplugged`, `.restarted` or `.quit`. The
  next `step` hands the partner's car to its AI (`Car.human =
  world.no_human`, recorded in `handed_over`) and the race goes on solo.
  That is the only World write outside `simulate`; with the partner gone
  there is nobody to agree with.

### 2.6 Timing (`net.timing`, microseconds)

| Constant | Value | Meaning |
|---|---|---|
| `min_gap` | 12 000 | no two input packets closer than this |
| `resend` | 20 000 | an input packet at least this often |
| `peer_stalled` | 25 000 | partner's newest tick still: send its missing window |
| `lobby_every` | 50 000 | lobby message period |
| `ctrl_gap` | 20 000 | first control message after a change |
| `go_every` | 100 000 | GO repeat |
| `waiting_after` | 500 000 | `state()` says `.waiting` (30 frames) |

## 3. Driving it from main.zig

```zig
const link = @import("link");
const net = @import("net.zig");
const Net = net.Net(link.Badge);
var n: Net = undefined;

// start():
n = Net.init(link.Badge.init(.{}, net.app_id, cart.rand()));
```

`n.state()` is one of `offline` (simulator: LINK shows `NO LINK IN
SIMULATOR`, greyed), `searching` (`PLUG IN THE CABLE`), `wrong_cart`,
`lobby`, `racing`, `waiting`, `peer_left`, `desync`.

**Pump** (`n.pump(cart.micros_since_boot())`) wherever LINK is in use:
the lobby, the race, pause, results. Pump points in a race frame:

1. the top of `update` (before `submit` / `step`);
2. between floor bands (every 16 rows: SPEC 11 plans a floor-band hook
   in `render.zig`, not built yet) and between the sprite and HUD
   passes;
3. after drawing, in a loop until about 14 ms into the frame, as Snouty
   Boy does (`tuning.link_pump_until_us`): the vsync wait is the one
   stretch where nothing reads the FIFO. In the host tests this halves
   the stalls under loss (section 5).

**Lobby frame** (host and guest):

```zig
n.pump(now);
switch (n.state()) {
    .lobby => {
        if (n.role == .host) n.set_rules(.{ .mode = m, .track = t, .crews = c });
        // the select: grey n.peer_racer(); ready = A pressed on a free racer
        n.set_pick(racer, ready);
        if (n.role == .host and start_pressed and n.can_go()) _ = n.go(now);
        // guest shows n.rules() (null until the first SETUP)
    },
    else => {}, // searching / wrong_cart / offline screens
}
if (n.take_started()) start_link_race(); // both badges, once per race
```

**Race start** (`start_link_race`): `sim.reset(&w, n.world_setup())`,
then apply `n.race.rules.crews` (see PLAN deferred question L3),
`follow = n.local_car()`, the usual render init. Do not step before the
reset.

**Race frame**:

```zig
n.pump(now);
var byte = input.race_byte();
if (n.paused) byte &= 0x40; // menu presses stay out of the race; Start resumes
if (resume_chosen) byte |= 0x40; // RESUME in the pause menu: a Start edge
n.submit(now, byte);
var ticked = n.step(&w);
// draw (pumping at the bands); then, until ~14 ms into the frame:
while (micros_into_frame() < 14_000) {
    n.pump(cart.micros_since_boot());
    if (!ticked) ticked = n.step(&w);
}
switch (n.state()) {
    .waiting => overlay("WAITING FOR PEER"),
    .peer_left => notice("PEER LEFT, AI DRIVING"), // n.left says why
    .desync => go_results_with("DESYNC"),
    else => {},
}
```

- One successful `step` per frame, never two (the World must run at
  the frame rate; the partner's buffer is only 3 ticks deep).
- `n.paused` (both badges agree on it) shows the pause menu; the World
  does not move while it is set. `RESUME` = submit a byte with Start for
  one frame after a frame without it; `QUIT` = `n.leave(now)`.
- After the race finishes, keep pumping and submitting (the partner may
  still need a late tick of ours) until the results are dismissed, then
  `n.leave(now)`. The partner sees `peer_left` (`.quit`) when it is still
  in the race; ignore it once its World is finished.
- After `peer_left` or `desync`, `n.leave(now)` returns to the lobby (or
  to `searching` if the cable is gone).
- Single-player races do not touch `n` (other than pumping it in the
  LINK menu).

## 4. What Track B builds

- The LINK menu: cable state (`searching`, the link's `cable()`),
  host / guest, the host's mode / track / crews rows, the guest's view of
  them, the shared racer select with `peer_racer()` greyed (host wins a
  clash), ready, host Start = `go`.
- `start_link_race`: reset, crews (L3), follow, render init.
- The race loop above: pump points in `render.zig` and the frame, the
  waiting loop, `WAITING FOR PEER`, `PEER LEFT, AI DRIVING`, `DESYNC`,
  the shared pause and QUIT.
- Simulator: `NO LINK IN SIMULATOR` (state `offline`).
- badge-bench: the worst gap between pumps in a race frame, and the cost
  of `pump` / `step` (`world_hash` every 32nd tick).
- The hand-off on cabling two badges (root docs/LINK.md section 1).

## 5. Numbers (host tests, `zig build test-gc`)

Two badges on the virtual cable, frames of 16 667 and 16 690 us, one
frame in 150 doubled (a missed vsync), pump points every 0.5 ms through a
3 ms draw, the 8-byte FIFO modelled pessimistically (a packet arrives in
an instant, so a second one while the receiver draws is lost); scripted
humans = the autopilot plus random taps.

- 10 races, clean cable (3 of them pumping to 14 ms): 75 698 ticks, World
  hashes equal on both badges at every tick, final Worlds equal. 0.41% of
  input packets lost to the FIFO model; 0.28% of frames without a tick,
  never more than 2 in a row.
- 10 races, 1% injected byte loss (8.75% of packets lost with the FIFO
  and CRC drops), pumping to 14 ms: in sync, all finish; 1.8% of frames
  without a tick, at most 8 in a row (133 ms). Without the pump loop the
  same loss gives 4.4% and 13 in a row.
- LINK GC rules race: in sync to its end.
- Unplug mid-race: both badges `peer_left` 42 ms later, each finishes with
  the AI driving the other car.
- World changed on one badge: `desync` on both at most 32 ticks later
  (the contract asks 64).
- Pause on one badge's Start: both pause on the same tick; the other
  badge's Start resumes both on the same tick; in sync to the finish.
- Quit mid-race: the partner races on with the AI; both back in the
  lobby, race 2 starts in sync with a new seed.
- Lobby: roles over 24 seeds and both cable kinds, another cart told
  apart, rules reach the guest, a racer clash blocks GO, GO through 5%
  byte loss.
- **Cost.** An idle pump is one `link.poll` (one FIFO read, one pin read)
  plus a few compares; a racing pump averages 1.99 FIFO reads. A packet
  in is 8 FIFO reads, a CRC over 6 bytes and ~30 operations in
  `on_input`; a packet out is up to three CRCs over 6 bytes (the salt)
  plus the link's own and 8 FIFO writes. `world_hash` is 1,356 field
  mixes every 32 ticks.
- **RAM.** `@sizeOf(Net(link.Badge))` = 568 bytes, of which the link is
  344 (its 8-packet receive queue and 64-byte pending buffer). No other
  buffers.
