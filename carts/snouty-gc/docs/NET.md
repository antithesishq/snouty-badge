# Snouty GC netcode: two badges, one race

`cart/src/net.zig` runs a two-badge race in deterministic lockstep over
the link cable (`lib/link.zig`, root `docs/LINK.md`). SPEC section 7 is
the design and PLAN "M4 Link" the contract. This file covers the
protocol, how `main.zig` drives it frame by frame, and what the
integration track (M4 Track B) built.

The idea: both badges hold the same `World`, and `sim.simulate(w,
inputs)` is pure in `(World, inputs)`. So the badges exchange only the
two humans' input bytes, one byte per tick each, and both simulate every
tick with the same pair. Nothing else reaches `simulate`: no clock, no
`cart.rand`, no render state, only the agreed bytes and the agreed setup.

**M6 (LINK BATTLE): version 1, five rules bytes.** LINK BATTLE needs
LIVES and TIME beside the mode, the arena and CREWS, more than M4's one
rules byte holds. Since M6 `net.Game` has `rules_len = 5` and `version =
1`, so lockstep sends the rules in its paged SETUP (root
`docs/LOCKSTEP.md` 4.3: SETUP pages 0x80 | page << 2 | flips, GO 0x90 |
flip with a CRC8 of the rules) and the link HELLO's version byte is 0x11.
The five bytes (`Rules.encode`): mode (0 LINK RACE, 1 LINK GC, 2 LINK
BATTLE), track (`track.tracks`, or `track.arenas` in battle), CREWS (AI
cars: 4, 2, 0), LIVES (1, 3, 5, 9; 0 INF), TIME (2, 3, 5 minutes; 0
NONE, never with INF). `Rules.decode` maps any bytes onto rows the menus
offer, so both badges always build a round they can run. A badge running
M4 to M5.1 (version 0) and this one never race: the M5.1 badge and this
one both show `WRONG VERSION` and send nothing; an M4 badge (which
ignores the version) waits in its lobby (docs/LOCKSTEP.md 4.7).
`net.GameV0` is the M5.1 game, kept so `net_compat_test.zig` still
proves its wire is M4's byte for byte; sections 2.1 and 2.2 below
describe that version-0 form, which the paged form replaces only in
SETUP and GO.

## 1. Files

| File | What |
|---|---|
| `cart/src/net.zig` | `Net(L)`: GC's names (`Rules`, `Pick`, `Race`, `world_setup`, `world_hash`, ...) over the shared `lib/lockstep.zig` (root `docs/LOCKSTEP.md`); `net.Game` is GC as lockstep's game (M6: version 1, five rules bytes), `net.GameV0` the M5.1 one for the tests: rules, racer picks, Start as the pause bit, the hand-over; `NetOf(L, G)` takes either |
| `cart/src/net_test.zig` | two `Net` + two `World`s on a `lib/link_virtual.zig` cable with byte loss and the 8-byte FIFO |
| `cart/src/net_m4.zig` | test only: the M4 net.zig (90683be4, tag `snouty-gc/m4-hw`) verbatim |
| `cart/src/net_compat_test.zig` | the version-0 wire (`GameV0`) is byte-identical to M4 (one scripted session on both stacks), an M4 badge and a v0 one race in sync, the cart's version 1 never races an M4 badge, and a v0 (M5.1) and a v1 (M6) badge both say `wrong_version` and never race |
| `cart/src/battle_text.zig` | M6: the lobby's rows for LINK RACE / LINK GC / LINK BATTLE and the host's rule changes (`lobby_change`), host-tested in `battle_ui_test.zig` |
| `carts/snouty-gc/build.zig` | `link` and `lockstep` imports for the cart module; `link_host` (link.zig + link_virtual.zig copied under one root) and `lockstep` for the tests |

Since the conversion (after M4) the lockstep itself lives in
`lib/lockstep.zig`, extracted from M4's net.zig; this file still
describes GC's protocol, which with one rules byte is lockstep's GC form
unchanged. `Net` is generic over the link: `net.Net(link.Badge)` in the
cart (PIO2 on the badge, `.unavailable` in the wasm simulator), and a
`link.Link(...)` over the virtual cable in the tests. It owns the
lockstep by value (`n.ls`), and the lockstep owns the link (`n.ls.link`);
`n.ls.role`, `n.ls.left`, `n.ls.paused` and `n.ls.stats` are its fields.

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

- **rules** (version 0, M4 to M5.1): track bits 0-3, crews bits 4-6 (the
  AI count), mode bit 7 (0 LINK RACE, 1 LINK GC). Version 1 (M6) sends
  the five rules bytes of the top of this file in paged SETUPs instead.
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
`wrong_version` (since the lockstep conversion: `WRONG VERSION / UPDATE
BOTH BADGES`; the wasm `debug_link_view:7` fakes it), `lobby`, `racing`, `waiting`, `peer_left`, `desync`.

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

The loop runs while `n.wants_pump()` (lockstep's: `busy()`, or the link
handshaking). Since the integration the LINK lobby and the link racer
select run it too: a HELLO is 10 wire bytes, two more than the 8-byte
receive FIFO, so a badge pumping once a frame kept a truncated HELLO
(the next HELLO's leading END closed it). Searching (no cable) and a
settled lobby pump once a frame at the top only; before, GC's lobby
looped to 14 ms in every state.

**Lobby frame** (host and guest):

```zig
n.pump(now);
switch (n.state()) {
    .lobby => {
        if (n.role == .host) n.set_rules(.{ .mode = m, .track = t, .crews = c, .lives = l, .minutes = min });
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
if (n.paused) byte = hold.byte(byte & 0x40); // only Start; RESUME holds it (net.Resume)
hold.took(byte, n.submit(now, byte)); // submit says whether it kept the byte
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
  does not move while it is set. `RESUME` = `net.Resume`: hold Start on
  every byte until `n.paused` turns off, after one kept byte without it
  (`submit` drops a byte while `step` is stalled, so a one-frame edge
  could be lost and the race stayed paused; found at the lockstep
  conversion, fixed at the integration); `QUIT` = `n.leave(now)`.
- After the race finishes, keep pumping and submitting (the partner may
  still need a late tick of ours) until the results are dismissed, then
  `n.leave(now)`. The partner sees `peer_left` (`.quit`) when it is still
  in the race; ignore it once its World is finished.
- After `peer_left` or `desync`, `n.leave(now)` returns to the lobby (or
  to `searching` if the cable is gone).
- Single-player races do not touch `n` (other than pumping it in the
  LINK menu).

## 4. What Track B built (M4 Track B, 2026-10-05)

- The LINK menu (`main.zig` `lobby_frame`, `link_ui.zig`): cable state
  (`PLUG IN THE CABLE` / `SEARCHING...`, `WRONG CART`), host / guest and
  the cable kind, the host's MODE / TRACK / CREWS rows (Up/Down, Left/
  Right), the guest's read-only view, the partner's pick. The shared
  racer select is `select.zig` with `select.link` set: the partner's
  ready racer greyed `TAKEN`, ready marks, the host's A with both ready
  is `go` (L12: the guest's mark drops on a clash).
- `start_link_race`: `sim.reset(&w, world_setup())` (CREWS in
  `world.Setup.crews` now, L3), `me = follow = local_car()`.
- The race loop as section 3, with the pump points: the top of
  `update`, after the tick, before the horizon and every 16 of its
  columns, every `tuning.link_pump_rows` (3) floor rows, after the floor
  lines, after gathering the sprites and between every two drawn, between
  the HUD's passes (and the CAPTCHA card's halves and grid rows, the
  RACE CONDITION glitch's bands), after the HUD; then the loop to 14 ms.
  `render.band_hook` (main's `pump`) is null outside a link race.
- **After the finish** (`w.phase == .finished`) the race frame stops
  stepping and runs `sim.simulate(&w, .{0, 0})` alone: no input reaches a
  finished World (finished humans drive on their AI; `sim_test` checks
  it), so both badges stay equal without the lockstep, and a badge whose
  partner already left for its results never waits. The Net stays in
  `racing` and keeps resending the last window until `leave`.
- Pause: `n.paused` opens the pause list (RESUME, QUIT, SOUND); only the
  Start bit is submitted; RESUME and B hold Start until `paused` is off
  (`net.Resume`, since the integration; a kept byte without Start first
  if the last kept one had it); QUIT is `leave`.
- `DESYNC` ends on the results with a `DESYNC: RACE ENDED` band; the
  results' last A is `leave`, back to the lobby.
- Simulator: LINK greyed, `NO LINK IN SIMULATOR`; `debug_link_view` and
  `debug_link_notice` show made-up screens for the preview.
- badge-bench: no connected-peer fake exists, so `--poke
  gc_pump_probe=1` runs every pump point in a single-player race (the
  link searching) plus the per-tick work that needs no partner
  (`encode_input` a frame, `world_hash` every 32 ticks) and traces the
  worst gap by site every 120 frames (PLAN M4 status has the numbers).
- The hand-off: `docs/LINK_PLAY.md`.

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
- M6 LINK BATTLE: the five rules bytes reach the guest through 1% loss
  and both badges build the same round (LIVES 9, TIME 5, CREWS 2 on the
  arena); 6 seeded rounds (every LIVES row, CREWS 4 / 2 / 0, 2 minutes)
  in sync every tick to their end on a clean cable (38,627 ticks, 0.37%
  of input packets lost to the FIFO model, at most 13 frames in a row
  without a tick) and 6 more with 1% byte loss (37,510 ticks, 8.6% of
  packets lost, at most 17 in a row); each ends by lives or time, with a
  human still in finished and one out of lives marked out.
- M6 versions: a v0 (M5.1) and a v1 (M6) badge, either side, both
  cable kinds, clean and 1% loss, 10 s each: both `wrong_version`, no
  DATA packet sent by either, never racing.
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
