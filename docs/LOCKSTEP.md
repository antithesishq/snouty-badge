# Two-badge lockstep (`lib/lockstep.zig`)

`lib/lockstep.zig` runs one game on two badges joined by the link cable
(`lib/link.zig`, `docs/LINK.md`) in deterministic lockstep. Both badges
hold the same World and step it with the same pair of input bytes, one
byte per human per tick; nothing else crosses the cable during a race.
It came out of Snouty GC's M4 net code (`carts/snouty-gc/cart/src/net.zig`
at 90683be4, verified on two badges as tag `snouty-gc/m4-hw`) and is
shared by Snouty GC, Snouty Cycles, Snouty Zero, Snoutenstein's
deathmatch and Snouty Genesis (two players on one emulated Genesis,
carts/snouty-genesis/docs/LINK_PLAY.md: the World is the console, a tick
two Genesis frames, a 6-byte rules offer with the ROM's CRC32). New to it? Start
with `carts/snouty-pong` (README.md there): the smallest game on it,
written as a walkthrough.

The rule a game keeps: `G.simulate(w, inputs)` is pure in `(World,
inputs)`. No clock, no `cart.rand`, no render state, only the agreed
bytes and the agreed setup (rules, picks, seed) reach the World.

| File | What |
|---|---|
| `lib/lockstep.zig` | `Lockstep(L, G)`, `hash_fields`, the app-id registry, the wire helpers |
| `lib/tests/lockstep_unit.zig` | two badges on `lib/link_virtual.zig` with byte loss and the 8-byte FIFO, for delays 2 and 3, 1 to 8 rules bytes, narrow and wide picks |

## 1. The game's side: `G`

`Lockstep(L, G)` takes the link type `L` (`link.Badge` on the badge,
`link.Link(Port)` over the virtual cable in host tests) and a namespace
`G` the game supplies:

| Decl | Type | Meaning |
|---|---|---|
| `World` | type | the deterministic game state |
| `simulate` | `fn (w: *World, in: [2]u8) void` | one tick; `in[0]` is the host's byte, `in[1]` the guest's |
| `hash` | `fn (w: *const World) u32` | a hash of the whole World, called once every `check_every` ticks; `lockstep.hash_fields(World, w)` hashes a small World by reflection, a big one (Cycles' 38 KB) writes its own |
| `hand_over` | `fn (w: *World, slot: u1) void` | the partner left: its AI takes `slot` from now on. The only World write outside `simulate` (nobody is left to agree with) |
| `rules_len` | comptime_int, 1 to 8 | bytes of rules the host chooses (GC 1, Cycles 4, GC LINK BATTLE 5) |
| `input_delay` | `u32`, 2 to 6 | ticks between sampling a byte and the tick it drives (GC 2, Cycles 3) |
| `check_every` | `u32`, optional, default 32 | ticks between World hashes |
| `pause_bit` | `?u8`, optional, default null | a press edge of this bit in either human's byte toggles `paused` on that tick on both badges (GC: Start, 0x40) |
| `picks_ok` | `fn (host: u8, guest: u8) bool`, optional, default true | whether GO may start with these picks (GC: two different racers) |
| `can_pause` | `fn (w: *const World) bool`, optional, default true | false: the race cannot pause (GC: the race is finished) |
| `pick_bits` | `u8`, optional, default 3 | pick values are below `1 << pick_bits` (1 to 7) |
| `version` | `u4`, optional, default 0 | the game's protocol version (section 4.7) |

Input bytes: the cart's own layout, except that bits 6 and 7 are never
both set (`submit` clears both when they are: in the usual layout that is
Start+Select, the OS chord). That keeps the SLIP bytes 0xC0 and 0xDB out
of the input packet.

The app id is the one the cart gives its link: `link.Badge.init(.{},
lockstep.apps.cycles, cart.rand())`. A partner whose HELLO carries another
app byte is `wrong_cart`; there is nothing else to configure.

## 2. The API

```zig
const link = @import("link");
const lockstep = @import("lockstep");
const Ls = lockstep.Lockstep(link.Badge, Game);
var ls: Ls = undefined;

// start():
ls = Ls.init(link.Badge.init(.{}, lockstep.apps.cycles, cart.rand()));
```

| Call | What |
|---|---|
| `init(l) Self` | owns the link by value as `.link`; sets the link's `app_version` from `G.version` |
| `pump(now)` | poll the link, read packets, send what is due; callable from anywhere |
| `state() State` | `offline`, `searching`, `wrong_cart`, `wrong_version`, `lobby`, `racing`, `waiting`, `peer_left`, `desync` |
| `busy() bool` | a race runs (`racing`, `waiting`, `peer_left`) |
| `wants_pump() bool` | `busy()`, or the link is handshaking (a 10-byte HELLO overflows the 8-byte FIFO): pump in a loop to 14 ms |
| `role`, `left`, `paused`, `stats` | fields: host / guest / none; why the partner left; the agreed pause; counters |
| `local_slot() u1` | 0 on the host, 1 on the guest |
| `partner_name() []const u8` | `app_name(link.partner_app)` |
| `set_rules(r: [rules_len]u8)` | host, lobby: the rules to offer |
| `rules() ?[rules_len]u8` | in a race (until `leave`) the agreed rules; in the lobby the host's offer, or what the guest has heard in full (null until then) |
| `set_pick(pick: u8, ready: bool)` | this badge's pick (low `pick_bits` bits; the game decides what each value means, "none" included; it starts as all ones) and ready flag |
| `peer_pick() ?u8`, `peer_ready() bool` | the partner's last PICK this lobby (null until heard, and again after each race) |
| `can_go() bool` | host: both ready, `G.picks_ok` agrees |
| `go(now) bool` | host: start the race (false unless `can_go`) |
| `take_started() bool` | true once per race start, on both badges: reset the World now |
| `rules()`, `picks() [2]u8`, `seed() u32` | the agreed setup: picks in slot order (host's, guest's); the seed from both link nonces and the race id |
| `submit(now, byte)` | this frame's input byte, once a frame while `busy` |
| `step(w) bool` | run the next tick if both bytes are here; at most one success a frame |
| `leave(now)` | back to the lobby (pause QUIT, results done, after `peer_left` or `desync`); the partner hears QUIT |

`hash_fields(T, v) u32` is GC's `world_hash`, generic: every field by
reflection (padding never read), one mix per field. `app_name(id)` is the
registry lookup of section 6.

## 3. Driving it from a cart

### 3.1 Pumping

The link's receive buffer is the PIO's 8-byte FIFO: an input packet is 8
wire bytes, so a second packet that arrives before the cart reads the
first is lost. Pump in three places:

1. **The top of `update`**, every frame while the link is in use (the
   link menu, the lobby, the race, pause, results).
2. **Band hooks inside long draws**, only while `busy()`: any draw over a
   few milliseconds calls the pump between bands. GC sets
   `render.band_hook = &pump` for a link race (null otherwise) and its
   renderer calls it every 3 floor rows, every 16 horizon columns, between
   two sprites and between the HUD's passes. `pump` is safe at any of
   these points: it touches only the link and the lockstep, never the
   World.
3. **After drawing, in a loop until about 14 ms into the frame, only
   while `wants_pump()`** (a race, or the link handshaking: a HELLO is 10
   wire bytes, more than the FIFO), retrying a stalled `step` in a race. The vsync wait is the one
   stretch where nothing reads the FIFO; in the host tests the loop halves
   the stalls under loss (GC's NET.md section 5).

When not `wants_pump` (offline, searching, the lobby) one pump a frame is
enough. With no cable a pump is one `link.poll` and a compare (the host
test counts port calls against a bare link: equal), so solo frames that
pump cost nothing measurable; Cycles' no-cable 12 ms bench gate holds.

### 3.2 Lobby frame (both badges)

```zig
ls.pump(now);
switch (ls.state()) {
    .lobby => {
        if (ls.role == .host) ls.set_rules(menu_rules);
        ls.set_pick(my_pick, ready); // grey ls.peer_pick() if picks must differ
        if (ls.role == .host and start_pressed and ls.can_go()) _ = ls.go(now);
        // the guest shows ls.rules() (null until heard)
    },
    else => {}, // offline / searching / wrong_cart / wrong_version screens
}
if (ls.take_started()) start_link_race(); // both badges, once per race
```

### 3.3 Race start

`start_link_race` resets the World from `ls.rules().?`, `ls.picks()` and
`ls.seed()`, and follows slot `ls.local_slot()`. Do not step before the
reset.

### 3.4 Race frame

```zig
ls.pump(now);
var byte = race_byte();
if (ls.paused) byte &= pause_bit; // menu presses stay out of the race
ls.submit(now, byte);
var ticked = ls.step(&w);
// draw (band hooks pump); then:
while (ls.wants_pump() and micros_into_frame() < 14_000) {
    ls.pump(cart.micros_since_boot());
    if (!ticked) ticked = ls.step(&w);
}
switch (ls.state()) {
    .waiting => overlay("WAITING FOR PEER"),
    .peer_left => notice("PEER LEFT, AI DRIVING"), // ls.left says why
    .desync => end_round("DESYNC"),
    else => {},
}
```

- One successful `step` per frame, never two: the World runs at the frame
  rate, and the partner holds only `input_delay + 1` ticks of ours.
- While `step` is stalled, `submit` drops the frame's byte (the local
  buffer is full). A press the cart injects (a RESUME menu row sending a
  pause-bit edge) must therefore be held until `paused` flips, not sent
  for one frame.
- `paused` is the same on both badges; paused ticks still run (inputs
  flow, hashes are taken) but do not call `simulate`.
- After the World is finished, keep pumping and submitting (anything)
  until the results are dismissed, then `leave`: the partner may still
  lack a late tick of ours, and the last window is resent meanwhile. A
  game whose finished World still moves (GC's AI drives the finished
  cars) can run it outside the lockstep with zero inputs, as GC does.
- After `peer_left` or `desync`, `leave(now)` goes back to the lobby (or
  to `searching` if the cable is gone).

## 4. Protocol

### 4.1 Roles and the lobby

On a new link session `Lockstep` checks `link.partner_app == link.app`
(else `wrong_cart`) and the partner's version (else `wrong_version`) and
picks the roles: the badge whose HELLO nonce is higher is the **host**
(slot 0), the other the **guest** (slot 1). Equal nonces (1 in 65536)
restart the link for new ones.

Control messages are link DATA packets with a kind byte first. A 5-byte
packet is always an input packet, so no control message is 5 bytes.

The lobby is state broadcast: every message repeats the sender's state,
so a lost one is replaced by the next. At most one control message goes
out every 20 ms.

### 4.2 Messages, one rules byte and picks of up to 3 bits (GC M4)

Byte-identical to GC's M4 net.zig (the wire of `snouty-gc/m4-hw`):

| Kind | Bytes | Sent by | When |
|---|---|---|---|
| `SETUP` 0xA1 | kind, race id, rules | host | lobby, every 100 ms (alternating with PICK) |
| `PICK` 0xA2 | kind, race id, pick (value bits 0-6, ready bit 7) | both | lobby, every 100 ms (host) / 50 ms (guest) |
| `GO` 0xA3 | kind, new race id, rules, picks (host bits 0-2, guest bits 4-6) | host | after `go()`, every 100 ms until the guest's first input arrives |
| `QUIT` 0xA4 | kind, race id | both | first message after `leave()` |
| `DESYNC` 0xA5 | kind, race id | both | every 50 ms after finding a desync |

- **race id**: the last race this badge joined this session (0 = none).
  A badge sends control messages only from the lobby, so a message with
  the id of the race the receiver runs means the sender left it:
  `peer_left`, `left = .quit`. Older ids are stale and ignored.
- GO carries everything; the guest accepts it only in the lobby and only
  for a new id, if `G.picks_ok` agrees, and adopts it whatever its own pick
  says. The seed is not sent: both derive it from the two nonces and the
  race id.
- A GO whose rules byte and race id are both SLIP bytes can be 9 wire
  bytes (GC M4 has the same); the next GO 100 ms later is the same, so
  avoid rules bytes 0xC0 and 0xDB here (more rules bytes avoid it by
  construction).

### 4.3 Messages, 2 to 8 rules bytes or wider picks

The paged form; the lobby works as above. PICK, QUIT and DESYNC are
unchanged.

| Kind | Bytes | Sent by |
|---|---|---|
| `SETUP` page 0x80 \| page << 2 \| flip1 << 1 \| flip0 | kind, race id, rules[2 page], rules[2 page + 1] (each XORed with 0x80 when its flip bit is set) | host, cycling through the `(rules_len + 1) / 2` pages, alternating with PICK |
| `GO` 0x90 \| flip (3-bit picks) | kind, new race id, CRC8 of the rules (XORed with 0x80 when flip), picks (host bits 0-2, guest bits 4-6) | host |
| `GO` (wider picks) | CRC8 of the rules & 0x7F, new race id, host pick, guest pick | host; the only 4-byte message whose first byte is below 0x80 |

- Every message here is at most 8 wire bytes: the flip bits keep rules
  bytes and the digest off 0xC0 / 0xDB, race ids skip those two values,
  picks are below 0x80, so only the link's CRC may need an escape.
- An odd `rules_len` pads its last page with 0.
- The guest keeps a bit per page it has heard this session; `rules()` is
  null until it has them all. It accepts GO only when it has every page
  and the CRC8 of what it heard equals GO's digest (7 bits with wide
  picks).
- From `go()` until the guest's first input the host alternates GO with
  SETUP pages, 50 ms apart, so a guest that missed the last change catches
  up and the next GO matches. Because of that a SETUP never means "the
  host left" in this form (PICK and QUIT still do).
- A rules change sends the changed page first.
- Moving a cart from one rules byte to several changes its wire: bump
  `G.version` when doing it.

### 4.4 The input packet (always 8 wire bytes)

5 payload bytes, the input bytes of three consecutive ticks n-2, n-1, n:

| Byte | Content |
|---|---|
| 0 | n mod 64 (bits 0-5), salt (bits 6-7) |
| 1 | input byte for tick n |
| 2 | input byte for tick n-1 |
| 3 | input byte for tick n-2 |
| 4 | check piece (7 bits) |

On the wire: link kind 0x10, the 5 bytes, CRC8, END = 8 bytes. Input
bytes never have bits 6 and 7 together, so they are never 0xC0 or 0xDB;
the check piece is below 0x80; and the salt (0x00, 0x40 or 0x80) is
picked so that the link's CRC is neither. The receiver takes the full
tick from the low 6 bits as the value nearest the next tick it lacks.

### 4.5 Lockstep

- `submit` stores the frame's byte as the input for tick `local_hi`, at
  most `tick + input_delay + 1`, and sends the newest three local ticks.
  Ticks below `input_delay` are all-zero on both badges.
- `step` runs tick `tick` only when both bytes for it are held. A frame
  without the partner's byte is a stall: the badge redraws and keeps
  pumping and retrying.
- **Lost packets.** Each tick travels in three consecutive packets. A
  badge that lacks a tick stalls and stops submitting, so its newest tick
  stops moving; its partner sees that (25 ms) and then alternates the
  newest window with one starting at the tick the staller needs (its
  newest minus the delay: exact while it is stalled). Packets go out once
  a frame or every 20 ms while nothing is new, never closer than 12 ms.
  No acknowledgements.
- **Delay 3 and up** (and every paged / wide form) also keep remote ticks
  that arrive past a hole and take them once it fills (a 16-bit mask
  beside the ring). A badge may run `input_delay + 1` ticks ahead of its
  partner, so at delay 3 the newest window starts past what a badge that
  lost a packet needs; without this the 3-tick recovery window chases the
  gap and a race stalls about 40% of its frames. GC's own form at delay
  2 receives exactly as GC M4 does.
- **Clock drift.** Each badge keeps its own 60 Hz vsync; the faster one
  stalls a frame now and then.
- Rings are 16 ticks: each holds at most `2 * input_delay + 2` (8 at
  delay 3, 14 at the largest delay 6).

### 4.6 Desync check, pause, quit, peer gone

- **Desync.** Every `check_every` ticks each badge takes `G.hash`. The
  packet whose newest tick is n carries 7-bit piece `(n - lag) mod 4` of
  the hash of epoch `(n - lag) / check_every`, `lag = 2 * input_delay + 4`
  (both badges have taken it by then). A piece that differs is a desync:
  `step` stops and the badge sends DESYNC so its partner stops too. Found
  on both badges at most 33 ticks after the Worlds part (tests; the
  contract is 64).
- **Pause.** A press edge of `pause_bit` in either human's byte toggles
  `paused` on the tick it lands, on both badges. `G.can_pause` false
  clears it.
- **Quit** is `leave()`: back to the lobby, QUIT to the partner.
- **Peer gone**: the link drops (cable out: about 30 ms; partner silent:
  2 s), its session changes (the partner's cart restarted), or a QUIT /
  lobby message with this race's id: `peer_left` with `left` =
  `.unplugged`, `.restarted` or `.quit`. The next `step` calls
  `G.hand_over(w, partner_slot)` once and the race goes on solo.

### 4.7 Versions

`G.version` (0 to 15, default 0) rides in the high nibble of the link
HELLO's version byte (`link.app_version`); the low nibble stays
`link.protocol_version` (1). Version 0 sends exactly 0x01, as GC M4 does.
`link.partner_version` is the raw byte.

A partner on the same cart with another version is `wrong_version`, and
in that state the badge sends no lobby or control message at all. An
older badge that ignores the version byte (GC M4) therefore never hears a
PICK or a GO from the newer one: it can never start a race or desync, it
just waits in its lobby. Bump the version whenever the game's wire
meaning changes: the rules layout (one byte to several), the input bits,
or what `simulate` does with them.

## 5. Timing (`lockstep.timing`, microseconds)

GC's values, unchanged:

| Constant | Value | Meaning |
|---|---|---|
| `min_gap` | 12 000 | no two input packets closer than this |
| `resend` | 20 000 | an input packet at least this often |
| `peer_stalled` | 25 000 | partner's newest tick still: send its missing window |
| `lobby_every` | 50 000 | lobby message period |
| `ctrl_gap` | 20 000 | first control message after a change |
| `go_every` | 100 000 | GO repeat |
| `waiting_after` | 500 000 | `state()` says `.waiting` (30 frames) |

## 6. Screens and app ids

The wording carts share, so two different carts read alike:

| State | Screen |
|---|---|
| `offline` | `NO LINK IN SIMULATOR` (the link menu row greyed) |
| `searching` | `PLUG IN THE CABLE` |
| `wrong_cart` | `WRONG CART: <partner's cart>` (`ls.partner_name()`) |
| `wrong_version` | `WRONG VERSION: UPDATE BOTH BADGES` |
| `waiting` | `WAITING FOR PEER` (an overlay on the race) |
| `peer_left` | `PEER LEFT, AI DRIVING` (or the game's equivalent: the AI takes the partner's slot) |
| `desync` | ends the round (GC: a `DESYNC` band on the results), then the lobby |

The app-id registry (`lockstep.apps`, `lockstep.app_name`):

| Id | Cart | `app_name` |
|---|---|---|
| `'L'` | Snouty Link (the link test cart) | `SNOUTY LINK` |
| `'B'` | Snouty Boy | `SNOUTY BOY` |
| `'G'` | Snouty GC | `SNOUTY GC` |
| `'C'` | Snouty Cycles | `SNOUTY CYCLES` |
| `'Z'` | Snouty Zero | `SNOUTY ZERO` |
| `'S'` | Snoutenstein | `SNOUTENSTEIN` |
| `'P'` | Snouty Pong (the example game, `carts/snouty-pong`) | `SNOUTY PONG` |
| `'M'` | Snouty Genesis (two players, `carts/snouty-genesis/docs/LINK_PLAY.md`) | `SNOUTY GENESIS` |

Anything else is `ANOTHER CART`. A new cart takes a free letter and adds
it to both tables.

## 7. Numbers (host tests, `zig build test`)

Two badges on the virtual cable, frames of 16 667 and 16 690 us, one
frame in 150 doubled, pump points every 0.5 ms through a 3 ms draw, the
8-byte FIFO modelled pessimistically (a packet arrives in an instant, so
a second one while the receiver draws is lost), scripted humans holding
random buttons. Per configuration (delay 2 and 3, 1 and 4 rules bytes;
5 rules bytes and 7-bit picks for some): 8 races of about 2 400 ticks.

- **Clean cable**: World hashes equal on both badges at every tick, final
  Worlds equal. 0.5% of input packets lost to the FIFO model; 0.14-0.30%
  of frames without a tick, never more than 2 in a row. The race start
  (the GO round trip and the first windows) waits up to 1 frame in GC's
  form and up to 7 (13 with 5 rules bytes when GO goes before the guest
  has every page) otherwise.
- **1% byte loss** (about 8.7% of input packets lost with the FIFO and
  CRC drops), pumping to 14 ms: in sync, all finish; 1.3-1.6% of frames
  without a tick, at most 9 in a row.
- **Unplug** mid-race: `peer_left` on both 30-31 ms later; `hand_over`
  ran for the partner's slot on each.
- **Desync** (one World changed): found on both at most 32 ticks (delay
  2) / 33 (delay 3) later.
- Pause and resume on the same tick on both; quit then a rematch in sync
  with a new seed; roles over 24 seeds and both cable kinds; a wrong cart
  told apart; rules of 2 to 8 bytes (SLIP bytes included) reach the
  guest, also when changed in the frame of GO; a `picks_ok` clash blocks
  GO; GO through 5% byte loss; v0 against v1 never races.
- **Cost.** With no cable a pump is the link's poll; an input packet in
  is 8 FIFO reads, a CRC over 6 bytes and some 30 operations; out, up to
  three CRCs for the salt plus the link's own and 8 FIFO writes. `G.hash`
  runs once every `check_every` ticks.
- **RAM.** `@sizeOf(Lockstep(link.Badge, G))` = 560 bytes for one rules
  byte (568 for 4), of which the link is 344. GC M4's Net was 568.

## Ideas for a later version

- **Clock drift at input delay 3** (Snouty Cycles, 2026-10-05): each badge
  keeps its own 60 Hz vsync, so the faster one drifts to the edge of the
  delay buffer and stalls now and then. A time-sync skip (the faster
  badge skips a frame's step when it leads by the whole delay) cut
  Cycles' clean-cable stalls to about 0.1% in its own stand-in. Not in
  v1: it changes when ticks run, so it needs a `G.version` bump for
  carts that adopt it.
- **The DMA receive ring** (`link.rp2350.rx_dma`, root docs/LINK.md)
  removes FIFO loss entirely once verified on hardware; carts stay
  correct without it.
