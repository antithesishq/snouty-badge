# Snouty Lynx

An Atari Lynx emulator cart for the SYCL Badge V2, written in Zig for
Antithesis. On the badge it plays a `.lnx` (or headerless `.lyx`) ROM copied
onto the badge's USB drive, with an embedded ROM as the fallback and as the
simulator's ROM. The Lynx's 160x102 picture sits 1:1 at the top of the
badge's 160x128 screen with a 26-row status strip below it. The core
emulates the 65C02, Suzy's sprite engine and math unit, and Mikey's
timers and palette; the menu has a time scrubber (SPEC.md). On the badges'
new OS firmware it plays the Lynx's sound through the speaker (M5).

Status: M5 (sound) in progress; M0-M4 are on main, history in PLAN.md. The
Iris-mark splash, then the game (the real core since M1: the 65C02, Mikey,
Suzy, the boot without the boot ROM), the strip with "SNOUTY LYNX", the
ROM name and where it came from, the emulator menu and picker (M2) and the
time scrubber (M3), the sound (M5, below); the neopixels stay off. The embedded fallback ROM is `roms/raycast.lnx`,
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
| Select, tap              | Option 1                                               |
| Select, hold 500 ms      | Emulator menu (the game pauses under it)               |
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

| Row                      | Does                                                   |
|--------------------------|--------------------------------------------------------|
| Resume                   | Back to the game                                       |
| Buttons: A=A B=B         | Swap badge A and B                                     |
| Sound: On                | Sound on or off (On at boot; not in the simulator)     |
| Press Option 2           | Resume with Option 2 held for 4 frames                 |
| Restart Pause+Opt1       | Resume with Pause + Option 1 held for 4 frames (the Lynx restart chord) |
| Debug overlay: Off       | The strip shows fps, step times, instructions, Suzy pixels, and with sound on the audio queue and underruns ("q1470/0") in place of the ROM name |
| Reset                    | Power on again (the boot reruns)                       |
| Pick ROM                 | The drive's ROM list (only with two or more playable files) |
| About                    | Version, file, header title and maker, size, source, CRC |

Sound (M5). The badges' new OS firmware (sycl-badge upstream from
"Streaming Audio, v1 Mixer") plays a ring of 44.1 kHz samples the cart
fills; the cart sends the Lynx's four audio channels there, 735 samples
a frame, and boots with sound On (Adrian's call for this cart; every other
cart boots silent, ../../docs/SOUND.md). The volume is the firmware's:
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
   into the chosen file. With no Lynx file on the drive a help box says
   how to add one and the embedded ROM runs underneath (A or B hides the
   box); a refused file (rotated screen, bank 1) is named with the reason.

The ROM file also shows in the OS cart menu and fails to load if picked
there; that is cosmetic. Commercial ROMs never enter the repository
(`*.lnx`/`*.lyx` are gitignored at the root).

- `docs/RUNNING.md`: build options, tests, preview, simulator, badge-bench, flashing.
- `SPEC.md`: design. `PLAN.md`: current milestone contract. `CLAUDE.md`: layout and conventions.
