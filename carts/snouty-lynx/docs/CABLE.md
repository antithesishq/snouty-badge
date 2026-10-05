# ComLynx on the link cable

Two badges joined by the link cable (docs/LINK.md at the repository root:
a JST-SH 3-pin cable between the UART headers, crossed or straight) play a
two-player ComLynx game: each badge emulates its own Lynx, and every
ComLynx frame one console sends goes on the other's wire. This is the
cable's transport for the ComLynx core in docs/COMLYNX.md (the real Mikey
UART, the `comlynx.Port` seam, the virtual bus, the Warbirds latency
tables). COMLYNX.md also describes the party branch's USB lobby
(`frontend/linkport.zig`, `lynxnet.zig`, `party.zig`, its sections 6, 7
and 10): those files are not on main.

## 1. Using it

1. Copy the same `.lnx` onto both badges' drives (every ComLynx game needs
   its cart in each Lynx; the badges compare the ROMs' CRC32).
2. Join the UART headers with the cable, start Snouty Lynx on both.
3. On each badge: hold Select (the menu), choose **Link cable**. The LINK
   screen says what it sees:

| Screen | Meaning |
|---|---|
| CONNECT THE CABLE ... SEARCHING... | no partner: the cable is out, or the other badge has not opened its LINK screen |
| WRONG CART: SNOUTY BOY | the partner runs another link cart |
| CONNECTING... | a Snouty Lynx answered; its hello is on the way |
| ROM MISMATCH, YOURS / THEIRS + CRCs | the two drives hold different ROMs |
| OTHER SNOUTY LYNX VERSION | the two carts speak different protocol versions |
| PARTNER LEFT THE LINK SCREEN | it pressed B; waiting |
| YOU / PARTNER, READY ticks | same ROM: press A to be ready |

4. When both are ready, both games restart linked (the guest 7 frames
   after the host: two Lynxes switched on the same tick mirror each other
   and never elect a master) and play. The strip says "Link cable:
   linked".
5. While linked: no fast forward, no chorded rewind, no menu scrubbing
   (the menu's bottom line reads "Linked: no rewind"); the game runs on
   behind the menu; the sound plays as usual. The menu's row reads
   **Leave link**: it ends the link for both (the console plays on alone,
   the scrub history restarts). The partner leaving, its cart restarting
   or the cable coming out also ends it ("Partner left link", "Link cable
   out"). Pick ROM ends it first. To play linked again, both open the LINK
   screen again (Lynx games look for their partners at power on).

The LINK row is not in the web simulator (it has no link port). On the
badge the menu shows nine rows at most: when Sound, Pick ROM (two or more
ROMs on the drive) and Link cable all show, the **Debug overlay row gives
way** (the party branch's rule for its Party row, kept identical).

## 2. Transport (frontend/cablenet.zig)

The link (lib/link.zig) carries SLIP DATA packets of up to 12 bytes at
1 Mbaud and drops one whose CRC fails; its receive queue holds 8 packets.
On top of it a small go-back-N channel: byte 0 of every reliable packet is
`seq << 4 | ack` (4-bit sequence, cumulative ack of the other direction);
at most 7 packets are unacknowledged (with the bare acks this stays within
the link's 8-packet queue); a gap makes the receiver send one NAK (resend
from its ack at once); no ack for 12 ms makes the sender resend the
window; 80 such timeouts in a row (about 1 s) restart the link (a new session on both
badges, which resets the channel). A one-byte packet is a bare ack or NAK.

| Type | Body | When |
|---|---|---|
| `'H'` hello | `crc u32`, `ready u8`, `version u8` | each new session, each change of ready |
| `'G'` go | `crc u32` | the host (larger link nonce), once both are ready with the same ROM |
| `'L'` leave | | the LINK screen or the link is left |
| `0x02` batch | `bit16 u16`, 2 entries | the first packet of a batch |
| `0x01` frames | 3 entries | the rest |

An entry is 3 bytes: the data byte and `w u16` = 9th bit << 15 | kind << 13
(frame, break on, break off) | offset from the batch's first frame in 8 us
units (up to 65 ms). A batch is what the UART sent since the last pump
(split when the bit time changes). Each badge frame of a busy game is a
few packets; at the full 62,500 baud (95 frames a badge frame) the window
holds 21 frames per round trip, and the round trip is a few ms while both
badges pump.

**The DMA receive ring is on** (`link.rp2350.rx_dma = 11`, docs/LINK.md):
a badge stepping a frame does not read the cable for up to ~4 ms (a slice)
and a burst of 12-byte packets is longer than the PIO's 8-byte FIFO. The
ring holds 256 bytes; the window keeps a burst under that.

The link session decides who is talking: a new session (partner restart,
replug) or a lost connection resets the channel and ends a linked game.
The app id is `'X'` (lib/lockstep.zig `apps.lynx`, "SNOUTY LYNX").

## 3. Timing

Relay delivery, as COMLYNX.md's relay mode: a batch's first frame goes on
this console's wire when the batch arrives (`Lynx.time()` now), the rest
at their offsets after it; frames from before a restart are dropped. The
echo is local (Warbirds needs its own frames back within ~0.5 ms). While
linked a game frame steps in 4 slices (`tuning.link_slices`, `Lynx.run_to`)
with the cable serviced after each: what the UART sent so far leaves and
what came goes on the wire mid-frame, so a hop costs about a slice of
batching. Between frames the cart pumps the cable until 14 ms into the
update (`tuning.link_pump_until_us`, Snouty Boy's figure).

Not T + D (the party's timestamped mode): with one heartbeat a badge frame
and the two badges' unrelated vsync phases, a D under two frames plus a
margin (~38 ms) makes the badges stall in turn; relay delivery has less
delay than that and never stalls. Collisions on a real ComLynx wire do not
happen here the same way (each console's wire sees its own frame first),
which two-player games tolerate (COMLYNX.md section 7.3).

Measured on two host Lynxes over lib/link_virtual.zig with the badge's
schedule (tests/comlynx_cable.zig: updates 16.7 ms apart with the two
vsyncs 5.3 ms out of phase, the frame step 9 and 11 ms with the cable
unread meanwhile, the 256-byte receive ring, then the pump):

| Run | Result |
|---|---|
| token ring (tests/comlynx/ring.lnx), 2 consoles, 4 slices, crossed / straight | 120 msg/s, 0 errors, 0 regenerations, 0 resends |
| the same, whole frames (1 slice) | 60 msg/s, 9 errors, 2 regenerations (a round trip of two frames nears the ring's 33-49 ms watchdog) |
| token ring, 0.2% of wire bytes lost | 114 msg/s; 44 resends; 3 regenerations (a resend held a hop past the watchdog) |
| 40 frames a badge frame for 2 s, 0 / 0.2% / 0.5% byte loss | 4800 of 4800 delivered each (228 / 627 resends) |
| Warbirds (local dump), crossed, straight, 0.2% loss | "2 PLAYERS" on both, both reach the cockpit (frames 760-797 after GO) |
| handshake | same ROM links both (host first, guest 7 frames later); ROM mismatch and wrong cart never link; a leave or the cable out unlinks both; replugged, linkable again |

`zig build test-lynx -Dtest-filter=cable` runs them (Warbirds skipped
without `~/roms/lynx/Warbirds.lnx`).

## 4. Cost

RAM cart, `size -A` and the scrub arena (`__stack_limit__` 0x20078000 -
`__bss_end__` - 1 KB), against origin/main 7572b89c:

| | origin/main | + ComLynx core (party, byte-identical) | + cable (this branch) |
|---|---|---|---|
| .text | 105,772 | 111,968 | 127,772 |
| .bss | 92,460 | 92,580 | 93,596 |
| scrub arena | 73,324 | ~67,000 | 49,252 |

The core's UART and port (~6.2 KB of code) come in whether or not a game
links (Mikey calls into them behind a runtime check); the cable side is
~15.8 KB of code (protocol, link driver, LINK screen, glue) and 1 KB of
.bss (the link, the 256-byte DMA ring). A RAM cart's code lives in the
same RAM as the scrub arena, so **unlinked play keeps a third less scrub
history** (party's figure was 47,740). The port's queues (~3.7 KB) are lent
from the arena only while linked. XIP cart: arena 181,316 -> 179,300.

badge-bench (calibrated busy ms mean / p95 / worst, unlinked, the bench has
no cable): m3_scrub 6.17 / 9.49 / 10.76 -> 6.18 / 9.50 / 10.78, m2_play
6.97 / 9.09 / 10.34 -> 6.98 / 9.11 / 10.36, 0 frames over. Linked, a frame
adds three slice stops (a `link_sync` and a cable service each, tens of
microseconds) and the update pumps the cable until 14 ms by design.

### Build option: `-Dlynx-link=false`

The cable is on by default (Adrian, 2026-10-05). `-Dlynx-link=false`
builds the cart without it: `frontend/cable.zig` `enabled` is false, every
entry point returns on a comptime-known branch, so the link driver, the
protocol and the LINK screen are never compiled in; the menu has no Link
cable row and the Debug overlay row is back. The core's UART stays (it is
byte-identical with the party branch). RAM cart after merging origin/main
(b8bd26c8):

| | `-Dlynx-link=true` (default) | `-Dlynx-link=false` |
|---|---|---|
| .text | 127,996 | 112,308 |
| .bss | 93,596 | 92,580 |
| scrub arena | 48,996 | 66,292 |
| RAM UF2 | 449,536 | 415,232 |

m3_scrub busy ms 6.18 / 9.50 / 10.78 in both, 0 frames over.

## 5. Hardware check

**Passed 2026-10-05** (Adrian, two badges: "works great"), with the
DMA receive ring on, its first run on hardware. The steps, for a rerun:

Two badges with this build and the same 2-player ComLynx ROM on both
drives (Warbirds, `~/roms/lynx/Warbirds.lnx`, or another from COMLYNX.md
section 8), the probe kit's JST-SH 3-pin cable between the UART headers.

1. Start Snouty Lynx on both; on each, menu -> Link cable. Expected within
   a second: the pair screen (YOU / PARTNER), the cable kind in the top
   right (CROSSED or STRAIGHT). A badge alone shows SEARCHING.
2. A on both: both games restart and the strip says "Link cable: linked".
3. Warbirds: the title shows **2 PLAYERS** on both; A, then A on the
   options board on both: both reach the cockpit and see each other's
   plane.
4. Hold Select on one badge: its game keeps running under the menu; the
   other badge's game goes on.
5. Pull the cable: within ~30 ms both strips say "Link cable out" and play
   on alone. Leave link from the menu: the other says "Partner left link".

If it stays on SEARCHING: check the cable and docs/LINK.md's search notes
(Adrian's own badge's UART header is faulty). If the games link but
Warbirds shows 1 PLAYER or stalls at the options board, note it: the
host test says the timing is well inside Warbirds's tolerance, so suspect
loss (the DMA ring is not verified on hardware yet).
