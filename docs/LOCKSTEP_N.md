# Party lockstep, up to 16 badges (`lib/lockstep_n.zig`)

`lib/lockstep_n.zig` runs one game on up to 16 badges plugged into one
laptop (or several laptops joined by a network lobby) in deterministic
lockstep. Every badge holds the same World and steps it with the same 16
input bytes, one byte per human per tick; nothing else reaches the World.
It is the N-player sibling of the two-badge cable lockstep
(`lib/lockstep.zig`, docs/LOCKSTEP.md), which it leaves untouched.

The transport is the fork firmware's cart serial port and the laptop's
`badge lobby` relay. It has shipped: sycl-badge-fork main 8ca6da6
("Merge feature/cart-serial into main", `fork/CART_SERIAL.md`; main has
since added a network lobby, `badge lobby --tailcat` / `badge join`,
fork/NET_LOBBY.md, with the cart side unchanged). Our carts build against
the pinned SDK, so they speak the documented ring ABI and lobby protocol
v1 themselves; section 7.1 runs them against the real relay.

The rule a game keeps is the same as for the cable: `G.simulate(w, in,
present)` is pure in `(World, in, present)`. No clock, no `cart.rand`, no
render state.

| File | What |
|---|---|
| `lib/cart_serial.zig` | the ring ABI: `Badge(.{})` (static rings at `ipc_data.cart_serial`), `Virtual(.{})` for host tests |
| `lib/party.zig` | lobby protocol v1 client: COBS framing, HELLO, WELCOME, ROSTER, SEND/DATA (to one, 0xFF others, 0xFE all), PING/PONG, LEAVE, ERROR |
| `lib/lockstep_n.zig` | `LockstepN(B, G)`, the game-id registry |
| `lib/party_virtual.zig` | a model of `badge lobby` and the badges' USB for tests |
| `lib/tests/party_unit.zig` | COBS and every v1 message against byte vectors, the client, the relay model |
| `lib/tests/lockstep_n_unit.zig` | 2 to 17 badges on the relay model (section 7) |
| `tools/party_e2e/main.zig`, `tools/party_e2e.sh` | N badges in one process over the real `badge lobby` (section 7.1); `zig build party-e2e` builds it, never part of a cart build |
| `lib/party_host.zig` | `party`, `party_virtual` and `cart_serial` as one module for a cart's host tests (party_virtual imports party.zig itself, so they cannot be two modules); carts on the badge import the files directly |
| `carts/snoutenstein/cart/src/party_host.zig` | the party deathmatch's pure core as one module root for host programs (party_e2e) |

Carts import one module, `lib/lockstep_n.zig`, and reach the client as
`lockstep_n.party`; `lib/cart_serial.zig` is a second module. (A separate
`party` module on the same file would put one file in two modules.)

## 1. The game's side: `G`

| Decl | Type | Meaning |
|---|---|---|
| `World` | type | the deterministic game state |
| `simulate` | `fn (w: *World, in: *const [16]u8, present: u16) void` | one tick; `in[s]` is slot s's byte (0 for slots not played by a human), `present` the slots their human still plays this tick |
| `hash` | `fn (w: *const World) u32` | a hash of the World, every `check_every` ticks; the game's own (a Genesis World is a whole machine). `lockstep.hash_fields` suits a small World |
| `hand_over` | `fn (w: *World, slot: u4) void` | a player left: the game's AI takes `slot` from this tick on (called by `step` before `simulate`, on the same tick on every badge) |
| `rules_len` | comptime_int, 1 to 8 | bytes of rules the host chooses (Snoutenstein 2; Genesis 4P carries a ROM CRC32) |
| `input_delay` | `u32`, 1 to 30 | the default input delay in ticks; the host may pick another in the lobby (`set_delay`), GO carries it |
| `check_every` | `u32`, optional, default 32 | ticks between World hashes; at least the race's delay + 2 |
| `pause_bit` | `?u8`, optional, default null | a press edge of this bit in any human's byte toggles `paused` on that tick everywhere |
| `can_pause` | `fn (w: *const World) bool`, optional | false: the race cannot pause |
| `picks_ok` | `fn (picks: *const [16]u8, mask: u16) bool`, optional | whether GO may start with these picks of the ready slots |
| `pick_bits` | `u8`, optional, default 7 | pick values are below `1 << pick_bits` |
| `version` | `u8`, optional, default 0 | sent in PICK and GO: a badge on another version is never raced with |
| `stall_drop_ms` | `u32`, optional, default 3000 | a participant silent this long while the others wait for its input is dropped |
| `min_players` | `u8`, optional, default 2 | humans GO needs |
| `send_every` | `u32`, optional, default 1 | ticks per INPUT frame; 2 halves the frame rate through the relay (the fallback of section 5, point 3) |

Input bytes are the game's, all 8 bits (COBS needs no reserved values;
the cable's Start+Select rule is the game's business here).

## 2. The API

```zig
const lockstep_n = @import("lockstep_n");
const cart_serial = @import("cart_serial");
const Port = cart_serial.Badge(.{}); // 4 KiB in, 1 KiB out
const Party = lockstep_n.LockstepN(Port, Game);
var pt: Party = undefined;

// start():
pt = Party.init(.{}, .{ .game = lockstep_n.games.snoutenstein, .name = player_name }, cart.rand());
```

| Call | What |
|---|---|
| `init(port, opts, entropy) Self` | owns the port (by value; `Badge` is zero-sized); `opts`: game id, name (12), max players; `entropy` seeds GO |
| `pump(now)` | read and handle every frame waiting, send what is due; callable from anywhere |
| `state() State` | `unsupported`, `disconnected`, `idle`, `joining`, `lobby`, `racing`, `waiting`, `desync`, `dropped` |
| `busy() bool` | a race runs |
| `wants_pump() bool` | `busy()` or joining: pump in a loop to 14 ms |
| `local_slot() u4`, `present() u16`, `host_slot() ?u4`, `is_host()`, `name(slot)` | the room: this badge's id, the roster, the host (lowest id), names |
| `set_rules(r)`, `rules() ?Rules` | host: the rules to offer; everyone: the agreed or offered rules (null until the host's SETUP) |
| `set_delay(d)`, `delay_offer()`, `suggested_delay()`, `rtt_us()` | host: the race's input delay; a suggestion from everyone's round trips (section 6) |
| `set_pick(pick, ready)`, `peer_pick_of(slot)`, `ready_mask()`, `other_version_mask()` | picks and ready flags |
| `can_go()`, `go(now)` | host: start a race of the ready players |
| `take_started() bool` | once per race start: reset the World from `rules()`, `picks()`, `participants()`, `seed()` |
| `submit(now, byte)` | this frame's input byte while `busy` |
| `step(w) bool` | run the next tick if every human's byte is in |
| `humans_mask()`, `bots_mask()`, `paused`, `delay`, `tick`, `stats` | the race |
| `match_running() bool` | in the lobby while others of this room race: "MATCH IN PROGRESS" |
| `leave(now)` | back to the lobby (pause QUIT, results done, after `desync` or `dropped`) |
| `exit(now)`, `enter()` | leave the room altogether (LEAVE) and come back |

## 3. Driving it from a cart

As docs/LOCKSTEP.md section 3, with one difference that matters: **drain
the receive ring every frame, long frames included.** The relay never
drops a frame for a connected player; when a player's cart stops reading,
the relay removes it (ROSTER to the others, port closed) once more than
64 KiB has waited for it for 1 s, or 1 MiB is waiting (section 5). A cart pumps at the top of `update`, from band
hooks inside long draws while `busy`, and in the loop to 14 ms while
`wants_pump`. A cart whose tick takes 20-29 ms (Genesis) pumps inside it.

Lobby frame:

```zig
pt.pump(now);
switch (pt.state()) {
    .unsupported => grey("NEEDS PARTY FIRMWARE"),
    .disconnected => show("START BADGE LOBBY ON THE LAPTOP"),
    .lobby => {
        if (pt.is_host()) { pt.set_rules(menu_rules); pt.set_delay(menu_delay); }
        pt.set_pick(my_pick, ready);
        if (pt.match_running()) show("MATCH IN PROGRESS");
        if (pt.is_host() and start_pressed and pt.can_go()) _ = pt.go(now);
    },
    else => {},
}
if (pt.take_started()) start_party_race();
```

Race frame: `pump`, `submit(now, byte)`, `step(&w)` (repeat `step` in the
pump loop while it returns false), then by state: `.waiting` "WAITING FOR
PLAYERS", `.desync` ends the round, `.dropped` "DROPPED" and back to the
lobby (`leave`). `bots_mask()` changing is the "P7 LEFT, AI PLAYING"
notice. After the World is finished keep submitting until the results are
dismissed, then `leave`.

## 4. Protocol

### 4.1 Lobby protocol v1 (the relay's)

Frames are COBS-encoded bodies (type + payload, at most 250 bytes) ending
in 0x00. Cart to host: HELLO 0x01 (version 1, game [8], name [12],
max_players), SEND 0x02 (to, data), PING 0x03 (u32), LEAVE 0x04. Host to
cart: WELCOME 0x81 (version, you, room, max_players), ROSTER 0x82 (count,
count x (id, name [12])), DATA 0x83 (from, data), PONG 0x84, ERROR 0x8F
(code, text). `lib/party.zig` sends a lone 0x00 then HELLO whenever the
port connects (`connected()` false to true), resynchronises on 0x00, and
writes a frame whole or not at all. While no WELCOME comes, `LockstepN`
says HELLO again every 2 s (`party.hello_retry_us`, as the fork's own
`cart.lobby`): a host that opens a serial port flushes its input right
after raising DTR (pyserial does), so a HELLO sent at once can be lost,
and the end to end runs lost exactly that HELLO on a pty. The fork now
opens serial links with DTR low and raises it after the flush, and
"until WELCOME, re-send HELLO every 2 s" is a spec rule for every cart
(fork main after c1fe509). Should both
arrive, the relay takes the second as a rejoin, which is harmless in the
lobby.

Byte for byte against the reference: `lib/tests/party_unit.zig` holds
every v1 message both ways (HELLO, SEND to an id, 0xFF and 0xFE, empty
and 240-byte data, PING, LEAVE, WELCOME, ROSTER of 1 and 16 players,
DATA, PONG, ERROR, a 250-byte body) and the COBS edge cases (empty,
zeros, 253/254/255/508-byte runs), generated by the fork's
`tools/badge/badge/frames.py` at 8ca6da6. One difference was fixed: after
a full 254-byte block at the very end both references (frames.py and the
cart side `src/os/cart/lobby.zig`) write one more block code, 0x01, where
our encoder stopped (as the Wikipedia examples do). Both forms decode
alike and a v1 body (250 bytes at most) never has such a block, so no
frame on the wire changed.

### 4.2 Our messages (DATA payloads, all SEND to 0xFF)

| Kind | Bytes | Sent by | When |
|---|---|---|---|
| INPUT, first byte below 0x80 | tick of the first byte mod 128, then 1 to 16 input bytes for consecutive ticks | each racer | at `submit` (or every `send_every` ticks) |
| SETUP 0x80 | kind, rules[rules_len] | host | when the rules change, a player joins, or it becomes host |
| PICK 0x81 | kind, pick (bits 0-6) \| ready (bit 7), version, rtt (2 ms units) | everyone in the lobby | on a change, a join, after a race |
| GO 0x82 | kind, race id, version, delay, seed u32, mask u16, rules, one pick per mask slot | host | `go()` |
| QUIT 0x83 | kind, race id | a racer | `leave()` |
| DROP 0x84 | kind, race id, slot, tick u32 | the proposer | a stalled slot (4.5) |
| ACK 0x85 | kind, race id, slot, cut u32 | every other racer | on a DROP |
| HASH 0x86 | kind, epoch u16, hash u32 | each racer | every `check_every` ticks, after the inputs up to it |

The transport is lossless and ordered, so lobby messages go out on a
change only; a joiner gets everyone's state because a ROSTER with a new
id makes everyone send it again. Integers are little-endian.

**On the wire**: one tick of one badge is SEND(0xFF, [tick, byte]) = 4
body bytes, 6 with COBS and the 0x00; each other badge receives DATA(from,
[tick, byte]) = 6 bytes. Measured with hashes: 6.35 bytes out per tick,
6.35 x (n - 1) in (95 at 16 badges, 5.7 KB/s).

### 4.3 The race

- GO names the participants (the ready players) and carries everything:
  id, delay, seed, rules, picks. All participants start at tick 0; ticks
  below the delay are all-zero inputs. A participant that is not in its
  lobby when GO arrives sends QUIT at once (its slot goes to the AI at
  tick `delay`); one already gone from the room is handed over there too.
- `submit` stores the byte for tick `local_hi` (at most `tick + delay + 1`)
  and sends it. `step` runs tick t when it holds every human's byte for t.
  Several ticks may share an INPUT frame; the receiver checks the tick
  byte against the next tick it expects from that slot (a mismatch is a
  protocol error and ends the race as a desync).
- A badge runs at most delay + 1 ticks ahead of any other, so each slot's
  input ring (64 ticks) holds at most 2 x delay + 2 at delay 30.
- **Leave**: QUIT, or a ROSTER without the player. By the relay's one
  order (section 5, point 1) every badge has the same inputs of the leaver
  when either arrives: the leaver plays its slot up to the last of them
  and `hand_over` gives it to the AI from the next tick, on every badge.
- **Join during a race**: the newcomer is not in GO's mask, ignores the
  race, and sees `match_running()` (from GO if it saw it, else from the
  inputs flowing past); the next GO includes it.
- **Pause**: a press edge of `pause_bit` in any human's byte toggles
  `paused` on that tick; paused ticks run (inputs, hashes) without
  `simulate`.

### 4.4 Desync

Every `check_every` ticks each racer hashes its World and broadcasts HASH
after the inputs that led to it. Each badge compares every other racer's
hash with its own as soon as it has both (it keeps four of its own and the
last one of each other racer: `check_every > delay + 1` makes that
enough). Every badge sees every hash, so a mismatch is found on all of
them (tests: at most 12 ticks after the Worlds part at delay 3, contract
2 x 32 + 2 x delay + 4).

### 4.5 Stall-drop

A participant whose input for the current tick this badge lacks and from
which no frame has come for `G.stall_drop_ms` is *suspect*. Silence is
measured from the slot's last frame, not from tick progress: a badge whose
ticks take 30 ms sends a frame each tick and is never suspect, it just
slows everyone down. The lowest participant that is not suspect proposes
the drop.

The PLAN's `DROP(slot, tick)` alone is not safe: the proposer cannot know
where the relay put its own DROP among the stalled badge's frames (no
echo), and a frame the badge sent just before waking up can reach the
others before the DROP and the proposer after it. So:

- every other racer cuts the slot at the inputs it holds when the DROP
  arrives (by the one order, the same everywhere) and replies ACK(slot,
  cut);
- the proposer takes no tick at or past the inputs it held when it
  proposed until the first ACK, and then uses that cut (the stalled
  badge's frames ordered before the DROP reach it before any ACK);
- with no other live racer left to ACK (two players, or everyone else
  suspect), the proposer's own count is the cut: nobody else plays on;
- two proposers of one drop (only when views of who is silent differ)
  wait for an ACK from a third; with none, the race ends as a desync
  after twice the stall time rather than risk two histories;
- the dropped badge, if it wakes up, reads the DROP: `dropped`, then
  `leave` takes it to the lobby.

### 4.6 Lobby

Host = the lowest id in the roster. Each badge PINGs the relay every 0.5
s in the lobby and keeps the worst of its last four round trips; it goes
out in PICK. `can_go`: this badge hosts and is ready, at least
`min_players` ready players on this version, `G.picks_ok`. `go` picks the
next race id, a seed from the entropy and the clock, and the host's delay.

## 5. Transport requirements (for the OS session)

What the lockstep relies on from the firmware and `badge lobby`, all four
confirmed: by exedev-94 on 2026-10-05, in the shipped spec
(`fork/CART_SERIAL.md` at 8ca6da6, "Rules"), and end to end against the
real relay (section 7.1). What breaks if one fails:

1. **One order per room.** The relay queues each frame to every recipient
   before it looks at the next frame of that room, so all players see the
   room's DATA in one global order (each minus its own frames); the ROSTER
   that removes a player is queued after every frame that player got to
   the relay. Bytes a leaver had in flight when its port died reach no one,
   which keeps the order the same for all.
   *If it fails*: a leave lands on different ticks on different badges
   (one hands the slot to the AI a tick earlier) and the hash check ends
   the race as a desync; a DROP's cut differs between ACKers.
2. **Lossless while connected**, with USB back-pressure: when a badge's
   receive ring is full the OS stops taking USB data and the relay waits;
   the relay never skips a frame for a connected player.
   *If it fails*: a lost INPUT stalls every badge on that tick until the
   stall-drop removes a live player; a lost HASH hides a desync; a lost
   GO leaves a participant in the lobby while the others wait for it.
3. **Throughput**: 16 badges x 60 INPUT frames a second through the relay,
   about 1,000 frames in and 15,000 out a second (6 bytes each).
   Measured by exedev-94 (host tool `feature/cart-serial` 5ddec50,
   `tools/badge/bench_lobby.py`, the relay alone on the VM): 16 carts at
   60 Hz with 6-byte SENDs, relay latency p50 0.16 ms, p99 5.4 ms, max
   10.6 ms (VM scheduling jitter), 100% delivered. So one INPUT frame per
   tick at 60 Hz is the default (`G.send_every = 1`). End to end with 16
   badges through the real relay (section 7.1): 0.03% of frames without
   a tick, input latency p50 0.14 ms, p99 6.3 ms. Still to measure: real
   USB.
   *If it fails*: the relay's queues grow and everyone waits (lockstep
   stalls). Fallback, kept supported but not the default: `G.send_every =
   2` (30 frames a second, two ticks each, about one more tick of delay),
   or a server-side tick bundle later.
4. **The rings stop at cart exit**: the OS zeroes `ipc_data.cart_serial`
   at cart start and detaches at stop, so the next cart never sees bytes
   meant for this one.
   *If it fails*: a stale ring address points into the next cart's RAM.

The ABI (shipped, `src/os/cart/os_abi.zig` at 8ca6da6): `CartSerialRings`,
40 bytes, ten u32 words (magic "SER1", rx_buf, rx_cap, rx_write, rx_read,
tx_buf, tx_cap, tx_write, tx_read, status), its address in the u32 at
0x200350F4, `os_flags` (u16 at 0x200350EA) bit 1 = supported, `status`
bit 0 = host open (DTR), bit 1 = attached (the OS serves the rings).
The layout is recorded in the fork's `fork/ABI.md` (main c044a3d) beside
the ext-flash OS's (bit 2, 0x200350F8-0x200350FC). The ext-flash test
firmware e2.2, from before that, also sets bit 1 and keeps its flash size
at 0x200350F4, so `supported` also needs that word to be 0 (the fork
zeroes it at cart start) or our own rings; on e2.2 a cart sees stock
firmware.
What the OS checks on every pass (`src/os/system/cart_serial.zig`
`validate`; a struct that fails is ignored, as if closed), and how
`lib/cart_serial.zig` meets it:

| OS rule | `cart_serial` |
|---|---|
| struct address non-zero and 4-byte aligned | `Storage` is an extern struct, align 4 (comptime assert) |
| magic 0x53455231 | set by `reset` |
| each capacity a power of two, at least 64 | `Storage(rx, tx)` refuses others at comptime |
| the 40-byte struct and both rings entirely in cart RAM 0x20035100-0x20080000 | static storage in .bss (the pinned cart_ram.ld puts it there); `Badge.open` checks the range at run time and stays closed otherwise |
| neither ring overlaps the struct or the other ring | the rings follow the struct back to back (comptime asserts on the offsets) |
| writers: data, `dmb`, index; readers: index, `dmb`, data | `read` and `write` do exactly that (`dmb sy` on the badge) |
| the OS may finish its current pass after the cart stores 0 | the struct and rings are static; a second `open` after `close` leaves the OS's indices alone (only the first open fills the struct; later ones skip unread input from the cart's side) |

**A rejoin** (shipped rule, fork 99e0a2c): a HELLO from a player already
in a room is a LEAVE then a fresh join in the same relay step: the others
get the ROSTER without the player before any ROSTER with it again, even
when it gets its old room and id back (it may get another room or id;
the relay's placement is a fresh join). LockstepN needs nothing more: the
ROSTER without it fixes its last tick (point 1), and a ROSTER with the
same id again is a newcomer, not in the race's GO mask, so it waits in
the lobby. Covered by `lib/tests/party_unit.zig` (the relay model does the
same) and end to end (section 7.1).

**Drain every frame, and sizing.** The relay (one thread, frames queued
in arrival order) removes a player only when more than 64 KiB has waited
for it for 1 s, or 1 MiB is waiting (`--queue-limit`, 16 times that),
and (fork main after c1fe509) any link with no write progress for 5 s
(`dead_time`; SocketLink sets SO_SNDBUF to 4 KB, so a stopped simulator
shows within 1-2 s more); `lib/party_virtual.zig` models the queue rules
exactly that (`stuck_limit`, `stuck_us`, `hard_limit`; its queue holds
256 KiB, so that is its hard limit, and tests scale the stuck limit down
per port where they want a removal soon). A 16-badge race brings 15 x 6
= 90 bytes a tick plus hashes, 5.7 KB/s; 64 KiB is about 11 s of it, so
only a cart that has stopped is removed. Our default receive ring is 4
KiB (about 45 ticks, 0.75 s, before the relay starts queueing; the OS
session's note: 2 KiB is about 13 frames of the fork's own demo
traffic), the transmit ring 1 KiB; both are comptime options of
`cart_serial.Badge`. A badge that stops pumping briefly loses nothing
(tests: a spectator frozen 3 s had its ring full and 5 KB queued at the
relay, kept and caught up); one that stops for good is removed and seen
by the others as a normal leave.

"Waited at the relay" counts only the relay's own queue, behind the
operating system's buffers. A badge's tty buffers a few KB (a pty about
20 KB), so a stopped badge backs bytes up into the relay soon; a
simulator's TCP socket buffers whatever the kernel's send-buffer
autotuning allows (Linux: up to 4 MB), so the relay never removes a
stopped simulator in practice (end to end: 45 KB sat in the relay's
socket after 40 s, the relay's queue empty). The lockstep does not need
the relay for that: its stall-drop hands the slot over after 3 s either
way.

**Self-echo shipped in v1** (SEND to 0xFE: everyone including the sender,
who gets DATA(from = itself) at its place in the room's order). LockstepN
does not use it (it applies its own byte locally and ignores DATA from
itself); `party.Client.broadcast_echo` is there for carts that need a
shared line. Finding from the Lynx ComLynx work
(`carts/snouty-lynx/docs/COMLYNX.md`): a relay round trip is far too
slow for a UART's own echo (Warbirds wants it within about 0.5 ms), so
the Lynx echoes locally and sends only its GO through 0xFE. Self-echo is
for control messages that must take their place in the room's order, not
for per-byte traffic.

End-to-end port ranges (fake simulator ports, never the real 7341-7356):
Snoutenstein `tools/party_e2e.sh` 27341+, Genesis 27400-27449, Lynx
`zig build lynx-e2e` 27500-27549.

## 6. Timing and the input delay

| Constant | Value | Meaning |
|---|---|---|
| `timing.waiting_after` | 500 ms | `state()` says `.waiting` |
| `timing.ping_every` | 500 ms | lobby PING to the relay |
| `G.stall_drop_ms` | 3000 ms | silent while missing: dropped |
| `timing.drop_give_up` | 2 x stall | an unresolved drop ends the race as a desync |

The delay is the host's choice per race (1 to 30 ticks, GO carries it).
On one laptop 3 ticks is plenty (tests: 0.06-0.46% of frames without a
tick, never 3 in a row). Over a network lobby, `suggested_delay()` takes
the two worst round trips to the relay a and b (a byte from a reaches b in
about (rtt_a + rtt_b) / 2) and returns `ceil(that / 16.7 ms) + 1`. Tests:
10 ms plus up to 75 ms of jitter each way measured up to 133 ms and
suggested 11; at delay 12 the race stayed in sync with 0.3% of frames
without a tick.

## 7. Numbers (host tests, `zig build test`)

All of this runs against the relay model, not real USB. Badges with their own 60 Hz frames (16 667 us plus 3 us per badge, one in
150 doubled), pumping at the frame's top and every 2 ms to 14 ms; the
relay model with 1 ms latency and up to 1.5 ms jitter each way unless
said; humans holding random bytes, all 8 bits.

- **2, 4, 8, 16 badges, 10,000 ticks**: in sync at every tick, no drops;
  frames without a tick 0.06%, 0.21%, 0.35%, 0.46%, never more than 2 in a
  row (clock drift: the fastest badge waits for the slowest).
- 8 rules bytes; delay 1; two ticks per INPUT frame (`send_every = 2`):
  in sync.
- **Leave** at tick 400: AI from tick 403 on all six; **unplug**: AI from
  the same tick on all.
- **Stall-drop** of a frozen badge (also of the host, slot 0, and of a
  badge whose USB the relay stops serving while it stays connected): one
  proposal, the same hand-over tick on all; the stalled badge wakes up
  `dropped` and returns to the lobby.
- **A badge with 30 ms ticks** runs 1,500 ticks with the others: never
  dropped, everyone at its pace.
- **Desync** (one World changed): found on all six at most 12 ticks later.
- **Pause** on the same tick on all four, and resume.
- **Join during a race**: the newcomer waits (`match_running`), the next
  race has five.
- **Back-pressure**: a spectator frozen 3 s (ring full, 5 KB queued) is
  kept and catches up; frozen 10 s with the stuck limit scaled to 16 KiB
  it is removed (more than that waited 1 s); the race goes on. A racer
  whose cart stops reading in a 16-badge race (stuck limit scaled to 256
  bytes) is removed by the relay; the 15 others hand its slot over on the
  same tick, with no stall-drop needed.
- **Network**: delay 12 with 150 ms of jitter, 3,000 ticks in sync.
- **RAM**: `@sizeOf(LockstepN(cart_serial.Badge(.{}), G))` = 2,576 bytes
  for 16 slots and 2 rules bytes (the input rings are 1 KB of it), plus
  the port's static rings, 5,160 bytes (4 KiB + 1 KiB + 40).

### 7.1 End to end over the real relay (`tools/party_e2e.sh`)

No hardware: `tools/party_e2e/main.zig` plays N badges in one process.
Each is what the fork's simulator is to the relay
(`src/simulator/serial.zig`): a TCP listener on 127.0.0.1 serving one
client at a time, the cart's 4 KiB receive ring filled from the socket
only while it has room, the 1 KiB transmit ring drained to it (discarded
while no client is connected), `connected()` = a client is connected. On
each runs the cart's code unchanged: `LockstepN(port, match.GN)`, the
match started as `cart/src/party.zig` starts it, the input byte bot.zig's
for the badge's own slot from its own World, on the badge's own 60 Hz
frame (pump and submit at the top, then pump as bytes arrive until 14
ms, nothing in the vsync gap). The relay is the fork's own `badge lobby`
(`python3 -B tools/badge/badge.py lobby --no-usb --sim <the run's ports>
--stats 0`), on ports clear of the simulators' 7341-7356.

```
tools/party_e2e.sh                # 2, 4, 8, 16 badges, then events (about 6 min)
tools/party_e2e.sh 16             # one run; `events` for the events run
SYCL_BADGE_FORK=~/sycl-badge-fork PARTY_E2E_PORT=27341 PARTY_E2E_LOGS=/tmp/e2e tools/party_e2e.sh
zig build party-e2e               # zig-out/bin/party_e2e alone (start a lobby yourself)
```

It needs python3 with pyserial (the relay imports it for serial links).
Plain runs: BUGS ON, frag limit 5, the arena the lobby suggests for the
head count, delay 3, to the frag limit (two bots need 10,000-18,000 ticks
for that, so the 2-badge run plays at 4x, still at delay 3). Checks:
every badge logs the same World hash at every tick, no badge sees a
desync, every badge ends with the same World, few frames without a tick.

Results, 2026-10-05 (the VM, 8 cores, the relay at fork main b994d04, its
lobby code unchanged since 8ca6da6). Input latency = from a badge's
submit to another badge's LockstepN holding the byte (one process, one
clock): the relay plus the receiver's frame phase.

| Badges | Arena | Ticks | Frames without a tick | Input latency p50 / p99 / max | Bytes in per tick |
|---|---|---|---|---|---|
| 2 (4x) | Server Room | 24,227 | 0 of 48,314 | 0.09 / 4.1 / 16.7 ms | 6.3 |
| 4 | Server Room | 4,518 | 0 of 17,792 | 0.09 / 3.5 / 33.3 ms | 19.1 |
| 8 | Build Farm DM | 2,010 | 0 of 15,512 | 0.09 / 4.6 / 52.1 ms | 44.6 |
| 16 | Data Hall | 2,569 | 42 of 40,010 (0.10%), never 2 in a row | 0.16 / 4.7 / 16.4 ms | 95.8 |

All in sync at every tick; 6.36 bytes out per badge per tick, as the
model said. One INPUT frame per tick at 60 Hz (`send_every = 1`) holds
at 16 badges.

**Events** (8 badges, Build Farm DM, frag limit 15, `tools/party_e2e.sh
events`): at tick 200 one badge is unplugged (its simulator quits); at
350 one says HELLO again on the same link (the relay's rejoin: every
racer's wire shows the ROSTER without it, then the one with it); at 500
one is reset and the relay reconnects it (a fresh join); at 650 one
freezes, sitting on a pty (`--port /dev/pts/N`, the relay's serial path,
as for a badge). Each was handed to the AI on the same tick on all four
racers (202, 352, 502, 652); the frozen one by the stall-drop after 3 s
(177 frames without a tick, the only ones of the run), then removed by
the relay 21 s later ("not reading: 2058 bytes queued", once its tty's
20 KB had filled); it woke to a closed link and joined afresh. The three
that came back wait in the lobby (MATCH IN PROGRESS); the four racers
finish in sync. Input latency p50 0.13 ms, p99 4.6 ms.

What the real relay showed that the model had not: a HELLO sent the
moment a serial link opens can be lost (pyserial flushes input right
after raising DTR), so the client now retries it every 2 s (section
4.1); the relay never removed a stopped simulator over TCP (fixed in the
fork by the 5 s `dead_time`, section 5);
rooms count from 1 and a HELLO of another version leaves the room first
(the model now does the same).

## 8. Game ids

`lockstep_n.games` (HELLO `game`, 8 bytes; rooms with different ids never
mix; bump the last character when a game's wire changes):

| Id | Cart |
|---|---|
| `SNOUTDM1` | Snoutenstein party deathmatch |
| `SNGENRM1` | Snouty Genesis party, RAM cart (Z80 stub); `carts/snouty-genesis/docs/MULTIPLAYER.md` |
| `SNGENFL1` | Snouty Genesis party, XIP / simulator build (real Z80): a different machine, so it never shares a room with `SNGENRM1` |
| `LX` + 6 hex digits | Snouty Lynx ComLynx: `LX` and the low 24 bits of the ROM's CRC32, so only consoles on the same ROM meet (`carts/snouty-lynx/docs/COMLYNX.md`) |

New ids: 8 ASCII bytes; never start one with `LX` (the Lynx range).

## 9. Genesis 4P and other carts

Nothing here is Snoutenstein's. Genesis 4-player (multitap) uses the same
`LockstepN` with one input byte per pad and slot (8 bits, no reserved
values), its own `G.hash` over the machine, `rules_len` 4 or more for the
ROM CRC32 (the guest compares it before readying), and `G.stall_drop_ms`
well above its 20-29 ms tick (silence counts from the last frame, so slow
ticks never drop anyone). Its tick runs longer than a frame, so it pumps
inside the tick (the relay removes a player that stops reading). A game
that wants a shared byte line rather than lockstep (Lynx ComLynx) uses
`party.Client` directly with `broadcast_echo`. Each new game takes a game
id in section 8.
