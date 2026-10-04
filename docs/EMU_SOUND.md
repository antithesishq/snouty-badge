# Emulator sound on the new firmware (contract)

Written 2026-10-04. Adrian ran Snouty Boy on a badge with Tetris DX, turned
Sound on and heard nothing at full volume. Cause: the show badges run the
newer upstream firmware (sycl-badge 97c093e "Streaming Audio, v1 Mixer",
checked at 3392a1b), which ignores `CART_TONE`: the OS no longer plays a
buzzer voice and only plays a cart-owned ring of 44.1 kHz u8 samples. Every
emulator turns its sound chip into one `tone2` voice, so every emulator is
silent there. Adrian: "we should keep sound off by default but we should
fix this on all emulators."

Scope: Snouty Boy (DMG + Color), Snouty Gear, Snouty Genesis. Snouty Lynx
gets the same thing from its own M5 (branch `lynx/m5-sound`, another
session; boots off too). Integration branch `emu-sound` (worktree
`/home/exedev/emu-sound/int`, from origin/main 7f4adfa), three Opus
tracks, then tags `snouty-boy/sound`, `snouty-gear/sound`,
`snouty-genesis/sound`, merge to main, push.

## 1. Already on the branch (the plan commit)

- `lib/stream_audio.zig`: cherry-pick of Lynx M5's 759bfe9 (API frozen,
  the Lynx session reports any fix). The ABI is in its header: ring words
  at 0x2003509C (ptr, len, head, tail), FIFO 0x29000002 to start, never
  0x29000001.
- `badge-bench`: cherry-pick of Lynx M5's f287a52. The bench consumes the
  ring as the new OS does (2 x 512 start-up, then 512 per 11.6 ms) and
  `--wav FILE.wav` writes what the speaker would get.
- `lib/audio_feed.zig` (new, host tests in `zig build test`): Lynx's rate
  control, resample, ramp-out and resume priming, generic over the
  samples per update. `Feed(.{ .nominal, .max_src, .ring_bytes })`;
  `frame(samples)` after every update that stepped the game, `stop()`
  in every update that did not (menu, scrub, picker, Sound off). No-ops
  in wasm. Carts add it as module `audio_feed` with
  `b.path("lib/audio_feed.zig")` (it imports stream_audio by file).

## 2. Rules for every emulator

Core:

- The sound chip renders samples at the badge rate from the console's own
  clock: after each stepped console frame, `audio_out` holds the sound of
  exactly that frame's console time at 44,100 Hz, as many samples as that
  time spans with the fraction carried to the next frame (a Game Boy
  frame is 738.4 samples: 738 or 739; Game Gear and Genesis NTSC ~736).
  `audio_len` says how many. Unsigned 8-bit mono, 128 = silence.
- Box filter: each output sample is the mean level over its bin (integrate
  level x duration), so a 100 kHz square does not alias into a whine. A
  bit-identical closed form or table fast path is welcome; measure first.
- Lazy: catch a channel up to "now" when the CPU writes or reads one of
  its registers, and at the end of the frame; no per-sample events.
- `audio_render: bool` on the console. False: nothing is rendered and the
  existing register model runs exactly as today (a sound-off build pays
  only a branch). The frontend sets it from the Sound setting.
- Mix to mono (stereo registers average L and R; a game that writes none
  must give plain sums), one named gain constant, chosen from real games
  (section 4) so the weak speaker gets a loud signal without clipping
  the common case. Reasoning in a comment next to it.
- State the CPU can see (registers, status bits, counters a register
  reads back) stays where it is, so keyframes, the scrubber and the
  determinism tests cover it. Render-only state (phase accumulators,
  LFSR, envelope levels the CPU cannot read) goes in the console struct
  too if the keyframe copies it for free; otherwise outside, and a
  restore resets it (a few ms of wrong sound after a scrub step is fine;
  garbage or a crash is not). Golden frame hashes and determinism tests
  must not change.
- Behaviour comes from public documents (Pan Docs, SMS Power, the
  YM2612 / SN76489 datasheets and community write-ups); other emulators
  may be read for behaviour the documents leave open; nothing copied.
  Cite sources in the file comment as the cores already do.
- No float in the core. Tables come from a host generator or are built at
  `start()` (Adrian's Mac runs out of memory on heavy comptime).

Frontend (`cart/src/frontend/audio.zig`):

- Badge builds stream through `audio_feed`. They never call `cart.tone2`
  or the `tone` import any more: on the new firmware those calls write
  the old tone words, which are now the ring's ptr/len/head/tail. On old
  firmware the badge is silent (the show badges run the new one;
  documented, no detection).
- Wasm builds keep today's simulator path exactly (the `tone` import shim,
  `pick_voice`/`voice()`): the pinned simulator has no streaming audio
  and its `tone` path works in Chrome.
- The Sound row stays as it is, initialised from `build_options.sound`
  (off by default). Off: `audio_render = false` and `feed.stop()`.
  The boot chime, if the cart has one, becomes samples through the feed
  on the badge (a short square burst; behind the same flag).
- Debug overlay: the queue (samples) and the underrun count.
- Report the RAM arena change (the ring is .bss).

Verification, per cart, recorded in the cart's PLAN.md status:

- `zig build`, `zig build test`, `zig build check-float` (where the cart
  has it); every other cart's UF2 byte-identical to a build of the plan
  commit.
- badge-bench (calibrated `busy ms`) on the cart's existing scripts: the
  default build (sound off) within 0.05 ms mean of the plan commit; a
  `-Dsound=true` build with 0 updates over budget, the audio share (mean
  and worst ms) reported, and `underruns 0` on the overlay figure.
- WAVs: `badge-bench --wav` from the sound-on ELF for each local ROM in
  section 4, in the cart's `out/` (gitignored; WAVs of commercial games
  are never committed), plus a host-tool WAV path if that is easier to
  drive. Listen-test by looking: no clipping run longer than a few
  samples, levels in range, pitch of a known note right (unit test).
- Unit tests (prefix `sound:`): pitch from period registers, duty, LFSR
  sequences, envelopes, the chip's special paths (wave RAM, DAC), the
  box filter on a square at a known frequency (mean level), scrub
  round trip (restore, step, same `audio_out` or the documented reset).

Ownership: a track touches only its own `carts/<cart>/` and its
`badge-bench/carts/<binary>*.toml`. Root docs (docs/SOUND.md,
docs/INSTALL.md, CLAUDE.md, README) are the integrator's. Commit on the
track branch; do not merge, tag or push.

## 3. Per cart

### Track A: Snouty Boy (`carts/snouty-boy`, branch `emu-sound-boy`)

- `core/apu.zig` today models channels 1-3 as registers for
  `pick_voice`. Add sample generation for all four: ch1/ch2 square with
  duty (12.5/25/50/75%), sweep and envelope as modelled; ch3 wave RAM
  playback (32 4-bit samples, position, output level shift); ch4 noise
  (15-bit and 7-bit LFSR, divisor and shift, envelope), length counters,
  DAC enables, NR50 master volume, NR51 routing. The frame sequencer and
  power behaviour already modelled stay authoritative. Color mode uses
  the same APU (PCM12/PCM34 read-back optional).
- `Gb.audio_out` sized for 739 (double-speed CGB still has 738.4 samples
  per frame of real time: the clock doubles, the frame does not).
- `Feed(.{ .nominal = 738, .max_src = 739, .ring_bytes = 4096 })`.
- Local ROMs: `~/roms/tetrisdx.gbc` (Adrian's report), `~/roms/tetris.gb`;
  the repo's test ROMs. The input scripts that reach play (title, Start)
  are in the 2026-09-30 Tetris fix notes (carts/snouty-boy PLAN.md).
- Budget: the cart's bench scripts as in its PLAN.md status (<= 8 ms per
  GB frame mean target, 16.7 ms hard).

### Track B: Snouty Gear (`carts/snouty-gear`, branch `emu-sound-gear`)

- `core/psg.zig` (SN76489) today is registers for `voice()`. Add
  synthesis: three tone channels (10-bit period, clock 3,579,545 / 16,
  period 0 and 1 behave as on Sega's chip: constant output), noise with
  the Sega 16-bit LFSR (taps per SMS Power, reset on a noise write),
  white/periodic, rates /512 /1024 /2048 or tone 2; attenuation 2 dB
  steps (15 = off, table); Game Gear stereo port 06 averaged to mono.
- `Feed(.{ .nominal = 736, .max_src = 738, .ring_bytes = 4096 })`
  (check the frame's exact cycle count: 228 x 262 Z80 cycles).
- Local ROMs: `~/sonic.gg` (music heavy), `roms/waternet.gg`.
- Budget: the cart's bench scripts (mean ~3 ms today).

### Track C: Snouty Genesis (`carts/snouty-genesis`, branch `emu-sound-genesis`)

- Sound only matters where the Z80 runs: the XIP cart. The RAM cart
  (the default UF2 since M5) stubs the Z80 to fit and has 7.9 KB spare,
  so most games' music cannot play there; it stays silent with the Sound
  row hidden, as today. Say so in its docs. (Whether the XIP cart is
  usable on a SYCL badge is Adrian's hardware check, 2026-10-05.)
- `core/ym2612.zig` today: registers, timers, `pick`. Add FM synthesis:
  per operator the phase generator (F-number, block, detune, multiple),
  the envelope generator (AR, D1R, D2R, RR, SL, key scaling, the
  envelope clock; SSG-EG may be left out and noted), the log-sine and
  exponent tables, total level, the eight algorithms, operator 1
  feedback, channel 3 special mode, the DAC on channel 6 (register 2A
  writes land in the bin of their console time: drums and voices are
  DAC), the LFO (AMS/PMS) if it fits the budget (noted if not), L/R
  enables to mono. Plus `core/psg.zig` synthesis (same chip as Gear;
  write it here, the two can share later).
- Two Genesis frames per update: `audio_out` per update ~1,472 samples,
  `Feed(.{ .nominal = 1472, .max_src = 1476, .ring_bytes = 8192 })`.
- Budget is the hard part: Miniplanets XIP is 20.74 mean / 29.07 worst of
  33.3 ms today. FM at 44.1 kHz is ~35 k operator evaluations per
  update. Provide a rate knob in `tunables.zig` (render FM at 44,100,
  22,050 or 14,700 and repeat samples) and pick the highest that keeps
  the sound-on XIP build at 0 updates over budget on the existing
  scripts; report all three.
- Local ROMs: `roms/miniplanets.bin` (Echo engine on the Z80, FM + PSG +
  DAC), `~/roms/genesis/sonic1.bin` (SMPS on the 68000, DAC drums on the
  Z80), the test ROM.
- Flash: 30.5 KB left in the XIP window at M4; report the growth.

## 4. Integration (me)

Merge the three tracks, root docs (docs/SOUND.md: the streaming section
and the emulator rows; CLAUDE.md speaker line; INSTALL.md if it mentions
sound), full-tree verification as section 2, WAVs to Adrian's Mac, tags,
merge to main, push, and the pull-and-run notes.

## Status

- 2026-10-04: plan commit; tracks A, B, C started.
