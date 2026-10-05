# Snouty Lynx

An Atari Lynx emulator cart for the SYCL Badge V2, written in Zig for
Antithesis. On the badge it plays a `.lnx` (or headerless `.lyx`) ROM copied
onto the badge's USB drive; the badge cart carries no ROM of its own (the
web simulator embeds one). The Lynx's 160x102 picture sits 1:1 at the top of the
badge's 160x128 screen with a 26-row status strip below it. The core
emulates the 65C02, Suzy's sprite engine and math unit, and Mikey's
timers and palette; the menu has a time scrubber (SPEC.md). On the badges'
new OS firmware it plays the Lynx's sound through the speaker (M5).

Status: M0-M5 are on main, history in PLAN.md. The
Iris-mark splash, then the game (the real core since M1: the 65C02, Mikey,
Suzy, the boot without the boot ROM), the strip with "SNOUTY LYNX", the
ROM name and where it came from, the emulator menu and picker (M2) and the
time scrubber (M3), the sound (M5, below; off by default); the neopixels
stay off. The simulator's embedded ROM is `roms/raycast.lnx`,
42Bastian's textured raycaster (Apache-2.0, `roms/LICENSE-raycast.txt`);
the boot path that decrypts a cart's loader without the Lynx boot ROM is
`core/boot.zig` (`docs/BOOT.md`).

## Controls

| Badge                    | Lynx / emulator                                        |
|--------------------------|--------------------------------------------------------|
| D-pad                    | D-pad                                                  |
| A                        | A (outer button); B with the menu's Buttons swap       |
| B                        | B (inner button); A with the swap                      |
| Start                    | Pause                                                  |
| Select, tap              | Option 1 (200 ms after the release: the double-tap window) |
| Select, hold 500 ms      | Emulator menu (the game pauses under it)               |
| Select, tap, then press and hold | Fast forward while held (silent, `>>2x` or `>>1.5x` top right) |
| Left during that hold    | Chorded rewind: the game freezes, Left/Right step time; let go of Select to play on |
| Left/Right in the menu   | Time scrubber: 0.5 s back / forward (not on a setting row) |
| Start + Select           | Back to the badge OS (the OS's chord)                  |

Menu: Up/Down move, A chooses, B or a Select tap resumes; Left/Right or A
flip a setting. On every other row Left/Right scrub time: back or forward
half a second, 4 steps a second while held. The panel's bottom line reads
"Scrub: live / 3.5s" or "Scrub: -1.5 / 3.5s" (position / history held).
After a step the panel gives way to that line in a bar over the restored
picture: Left/Right keep scrubbing, B or a Select tap play on from there
(the later history is dropped), Up/Down/A bring the menu back. Reset and
Pick ROM forget the history.

Party (ComLynx, docs/COMLYNX.md): the menu's Party row opens the PARTY
lobby. It needs the fork firmware with the cart serial port and `badge
lobby` running on the laptop the badges are plugged into; badges running
the same ROM meet in one room. A: ready; the host (the first badge in)
picks SYNC with Left/Right (T+25 MS by default; RELAY for no waiting)
and starts with Start once everyone is ready. Every badge then restarts
the game linked, as Lynxes on a ComLynx cable. While linked there is no
fast forward or scrubbing, the game runs on behind the menu, and the
Party row reads Leave party.

Fast forward: tap Select, then press it again within 200 ms and hold it.
The game runs faster for as long as Select stays held, the d-pad and
buttons still reaching it; letting go is 1x again and delivers nothing.
That tap is not Option 1 (a lone tap still is, 200 ms later than it
used to be). A Lynx frame costs 6-10 ms on the badge, so the speed is
what fits: about 1.5x in raycast and Hard Drivin', up to 4x for light
frames (docs/RUNNING.md, PLAN.md "Fast forward"). The scrubber keeps
every fast-forwarded frame. Left is reserved while fast forwarding:
pressing it turns the rest of the hold into rewind (the chorded rewind).
The game freezes under the menu's scrub bar ("Scrub: -1.7 / 1.7s", or
"Rewind: no history"), Left steps back a record (1 s) at once and
Left/Right step back and forward with the menu's repeat; no button
reaches the game and Start holds the position. Letting go of Select
plays on from there and drops the later history, as resuming from the
menu does.

| Row                      | Does                                                   |
|--------------------------|--------------------------------------------------------|
| Resume                   | Back to the game                                       |
| Buttons: A=A B=B         | Swap badge A and B                                     |
| Sound: Off               | Sound on or off (off at boot, `-Dsound=true` starts it on; not in the simulator) |
| Press Option 2           | Resume with Option 2 held for 4 frames                 |
| Restart Pause+Opt1       | Resume with Pause + Option 1 held for 4 frames (the Lynx restart chord) |
| Debug overlay: Off       | The strip shows fps, step times, instructions, Suzy pixels, and with sound on the audio queue and underruns ("q1470/0") in place of the ROM name |
| Reset                    | Power on again (the boot reruns)                       |
| Pick ROM                 | The drive's ROM list (only with two or more playable files) |
| Link cable               | The LINK screen: two badges on the link cable play a ComLynx game (docs/CABLE.md); "Leave link" while linked; not in the simulator |
| About                    | Version, file, header title and maker, size, source, CRC |

With Sound, Pick ROM and Link cable all showing, the Debug overlay row
gives way (nine rows fit). `-Dlynx-link=false` builds the cart without
the link cable: no Link cable row, ~17 KB more scrub history
(docs/CABLE.md section 4).

Link cable (M7, docs/CABLE.md). Two badges joined by the link cable on
their UART headers, the same `.lnx` on both drives: open the menu's Link
cable on both, press A on both, and both games restart linked: a
two-player ComLynx game (Warbirds and the others in docs/COMLYNX.md
section 8). While linked there is no fast forward, rewind or scrubbing.

Sound (M5). The badges' new OS firmware (sycl-badge upstream from
"Streaming Audio, v1 Mixer") plays a ring of 44.1 kHz samples the cart
fills; the cart sends the Lynx's four audio channels there, 735 samples
a frame. It boots silent like every cart (../../docs/SOUND.md): the menu's
Sound row turns it on, and `zig build -Dcart=snouty-lynx -Dsound=true`
builds a cart that starts with it on. The volume is the firmware's:
Start + Select opens its settings box (Volume with Left/Right). In the menu,
a scrub and the picker the sound fades out (a 64-sample ramp) and comes
back with the game. The old firmware plays nothing (no harm), and the web
simulator has no streaming audio, so the simulator build is silent and
has no Sound row.

```sh
(cd ../.. && zig build -Dcart=snouty-lynx)   # ../../zig-out/firmware/snouty-lynx.uf2, ../../zig-out/bin/snouty-lynx.wasm
(cd ../.. && zig build test-lynx)            # this cart's host tests (`zig build test`: all carts)
```

## A ROM on the badge drive

The badge's USB drive (`SYCLBADGE`) holds carts and any other file. With the
default build (`-Dlynx-rom-source=drive`):

1. Plug in the badge, switch it on; the drive mounts.
2. Copy `snouty-lynx.uf2` onto it (as for any cart,
   [docs/INSTALL.md](../../docs/INSTALL.md) at the repository root), and
   copy one `.lnx` file (or a headerless `.lyx` dump) next to it.
   Best on a freshly wiped drive, so the file is contiguous; a fragmented
   file still works through the per-cluster path and the strip says `frag`.
3. **Eject the drive before playing.** The OS writes flash while a host
   writes the drive, and a cart reading it at the same time could see torn
   data (docs/ROM_DRIVE.md section 2 at the repository root).
4. Start Snouty Lynx. The strip reads `SNOUTY LYNX` and the ROM's header
   title (or file name), then `drive 128 KB` and `crc 6DF63834` (plus
   `raw` for a headerless file, `frag` for a fragmented one). With two or
   more playable files a list opens after the splash: Up/Down, A plays, B
   runs the first; the menu's Pick ROM row brings it back and restarts
   into the chosen file. With no playable Lynx file on the drive (or no
   drive volume) the cart shows "No Lynx ROM on the badge drive." with how
   to add one and the reason (`drive: no .lnx/.lyx file`, `drive:
   NoVolume`, or a refused file such as `drive: ROT.LNX: rotated`), and
   stays there; leave through the OS menu.

The ROM file also shows in the OS cart menu and fails to load if picked
there; that is cosmetic. Commercial ROMs never enter the repository
(`*.lnx`/`*.lyx` are gitignored at the root).

- `docs/RUNNING.md`: build options, tests, preview, simulator, badge-bench, flashing.
- `SPEC.md`: design. `PLAN.md`: current milestone contract. `CLAUDE.md`: layout and conventions.
