# Sound off by default across all carts

Status: decided by Adrian 2026-09-30 (section 4), implemented on branch
`sound-off` the same day. Companion to docs/NEOPIXELS.md, which this
follows in shape. Since 2026-10-04 Snouty Lynx streams its sound on the
new firmware (sections 7 and 8), under the same rule.

## 1. The rule

Every cart boots silent. Every cart that can make sound has a runtime
toggle (a menu row or a button) so sound can be switched on for a session.
The boot default is a build flag, `-Dsound=true`, for a set of carts that
should start loud; nothing else in a cart decides it.

## 2. What the OS gives us (and does not)

- Carts make sound only through `cart.tone2` (one buzzer voice; each call
  cancels the previous one) and `cart.set_global_volume(0..1)`
  (`sycl-badge/src/os/cart/api.zig`). RAM and XIP carts share the same
  platform file, so both reach the kernel; the wasm simulator's
  `set_global_volume` is a no-op ("TODO wasm volume", `platform_wasm.zig`).
- The kernel plays whatever a cart asks (`kernel.zig`, `CART_TONE`,
  `CART_VOLUME`). Global volume starts at 1.0 and `audio.reset()` puts it
  back to 1.0 and stops the tone whenever a cart stops
  (`sycl-badge/src/os/drivers/audio.zig`). There is **no persisted volume
  or mute setting**, no OS menu item for it, and no storage a cart could
  keep a preference in (the badge drive is read-only to carts). So a mute
  cannot live in the OS without an upstream change, and a runtime toggle
  cannot survive a power cycle: whatever a cart's default is, that is what
  the show floor hears.
- The OS menu itself never calls `audio.tone`, so silencing the carts
  silences the badge.
- `set_global_volume(0.0)` drives the speaker-enable line low (SPKR_EN /
  SD_MODE), a true hardware mute for the cart's lifetime. Not used: every
  `tone2` call already sits behind a cart's flag (section 3) and the OS
  resets volume per cart anyway. Kept in mind if a stray tone ever slips
  through.

## 3. Per cart

| Cart | Makes sound? | Flag | Boot default | Runtime toggle |
|---|---|---|---|---|
| snoutenstein | yes, 13 SFX | `cart/src/audio.zig` `enabled` | `-Dsound` (off) | Select on the title screen ("SELECT: SOUND ON/OFF") |
| snouty-boy | yes, all four APU channels streamed (section 7) + boot chime | `frontend/menu.zig` `sound_enabled`, copied into `audio.enabled` each frame | `-Dsound` (off) | menu row "Sound: On/Off" |
| snouty-gear | yes, the PSG streamed (section 7) + boot chime | same shape as Boy; the wasm build drives the simulator's `tone` import itself | `-Dsound` (off) | menu row "Sound: On/Off"; `debug_settings` bit 0 |
| snouty-genesis | yes, PSG/YM2612 tone voice | `frontend/audio.zig` `enabled` | `-Dsound` (off) | badge A in the menu placeholder ("A: sound on/off"); the M2 menu's Sound row takes over; `debug_sound_on` |
| snouty-bugs | yes, SPEC section 11 effects via `lib/tone_stream.zig` | `cart/src/audio.zig` `enabled` | `-Dsound` (off) | Select, any time (state on the title) |
| snouty-reflections | yes, background music (Gymnopedie No. 1) streamed by `cart/src/music.zig` (section 7); not in half30 | `music.enabled` | `-Dsound` (off) | Start in the attract orbit ("MUSIC ON/OFF") |
| snouty-lynx | yes, Mikey's four channels as 44.1 kHz PCM, new firmware only (section 8) | `frontend/audio.zig` `enabled` | `-Dsound` (off) | menu row "Sound: On/Off" (not in the wasm build); `debug_settings` bit 0 |
| snouty-zero | yes, 6 tones + the engine drone via `lib/tone_stream.zig` | `cart/src/sound.zig` `enabled` | `-Dsound` (off) | menu item "SOUND: ON/OFF" |
| snouty-theremin | yes, its own continuous voice streamed (section 7; `cart/src/voice.zig`, `audio.zig`) | `main.zig` `muted` | **on** (an instrument, docs/TOF.md deferred question 1; `-Dsound` does not apply) | Select, any time (SOUND / MUTED in the status bar) |
| snouty-run | no | | | |
| snouty-maze | no, by decision (2026-09-27, "it'll be annoying") | | | |

Before this change snoutenstein was already off; Boy, Gear and Genesis
booted with sound on and Genesis had no toggle (its menu is M2).

Every `tone2` call in the four sounding carts is behind that cart's flag
(`play`, `start_tone`, `update`, `chime`), and each cart's `update` stops a
held tone the frame the flag goes false, so a toggle to off is silent at
once and a toggle to on re-issues the game's voice within a frame.

## 4. Design (Adrian, 2026-09-30)

Decisions: sound configurable in software in every cart (menu row or
button); default off; the default changeable with a build flag.

### 4.1 One build option

`sound: bool` in `common.Options` (`build/common.zig`), declared once in
the root `build.zig`:

```
-Dsound=true    start every cart with sound on (default false)
```

Each sounding cart passes it through its `build_options` module exactly as
`neopixels` is passed (`options.addOption(bool, "sound", opts.sound)`;
Gear and Genesis gained an options module for it, imported as
`build_options` in their `build_cart_modules`).

### 4.2 The option seeds the runtime flag, toggles stay

A cart's sound flag is initialised from `build_options.sound` and only
its runtime toggle changes it afterwards:

- snoutenstein `audio.zig`: `pub var enabled: bool = build_options.sound;`
- snouty-boy `frontend/menu.zig`: `pub var sound_enabled: bool = build_options.sound;`
- snouty-gear `frontend/menu.zig`: the same line
- snouty-genesis `frontend/audio.zig`: `pub var enabled: bool = build_options.sound;`,
  and `main.zig`'s menu placeholder toggles it on badge A and shows the
  state on a third banner line (the M2 menu replaces this with its Sound
  row).

Why a runtime default rather than compiling the audio out (as the LEDs
were): the LED code was compiled out because the hardware makes it
unusable. Sound is a venue preference, and a demo that cannot show the
Game Boy chime or the Debugger thump loses something. The sound modules
are small and already sit behind a flag, so there is no RAM or comptime
cost to keeping them live.

### 4.3 Carts still to get sound

Their SPECs carry the rule (bugs section 11 and 16, reflections section 8,
lynx section 9, genesis section 9), and the root `CLAUDE.md` hardware
bullet states it for new carts.

## 5. Files touched

- `build.zig` (root), `build/common.zig`: the option.
- `carts/{snoutenstein,snouty-boy,snouty-gear,snouty-genesis}/build.zig`:
  pass it through `build_options`.
- The four flag initialisations of section 4.2; genesis `main.zig` (A
  toggle, banner line, `debug_sound_on` export).
- Docs: this file; root `CLAUDE.md`; `docs/RUNNING.md`; `README.md` (Boy
  and Gear rows); `carts/snouty-gear/docs/RUNNING.md` and `PLAN.md`;
  `carts/snouty-genesis/docs/RUNNING.md`; SPECs of snoutenstein (12),
  snouty-boy (18 item 6), snouty-genesis (9), snouty-bugs (11, 16),
  snouty-reflections (8), snouty-lynx (9).
- No host test reads the sound flags, so no test changes.

## 6. Verification

1. `zig build` (all carts, RAM), `zig build -Dcart-mode=xip` and
   `zig build -Dsound=true -Dcart=snoutenstein,snouty-boy,snouty-gear`
   build; `zig build test` passes.
2. Simulator, default build: snouty-gear's headless preview
   `--dump-exports debug_settings` has bit 0 clear, and set with
   `-Dsound=true`; snouty-genesis `debug_sound_on` likewise, and 1 after a
   Select hold plus A.
3. Snoutenstein's title reads "SELECT: SOUND OFF" and Select toggles it.
4. Show day, one badge: each sounding cart boots silent; its toggle brings
   sound back; leaving and re-entering the cart is silent again.

## 7. The newer firmware: carts stream their own samples (2026-10-04)

The show badges run the newer upstream firmware (sycl-badge 97c093e
"Streaming Audio, v1 Mixer", checked at 3392a1b). It ignores `CART_TONE`:
`cart.tone2` plays nothing, and the IPC words it writes (0x2003509C..) are
now the ring a cart streams 44.1 kHz u8 mono samples through
(`audio_buffer_ptr/len/head/tail`). So on the badge no cart may call
`cart.tone2` any more; the ABI is in `lib/stream_audio.zig`'s header.

- `lib/tone_stream.zig`: `tone2` rebuilt in the cart (one voice, each
  `play` cancels the last, square/triangle/saw, sine as triangle,
  major/minor chords), rendered into the ring while a tone sounds and
  idle otherwise; plus an optional held `drone` mixed under the tones
  (snouty-zero's engine). snouty-zero and snoutenstein use it on the badge and
  keep `cart.tone2` / the `tone` import for the wasm simulator; their
  `update` calls `tone_stream.update()` once per frame.
- `lib/audio_feed.zig`: for emulators, which render their sound chip's
  real output per stepped frame; rate control against the OS's clock.
  Plan and status: docs/EMU_SOUND.md.
- Old firmware: the start word reads as its CART_VOLUME and nothing plays.
  The defaults of section 4 are unchanged (off, `-Dsound`, runtime toggle).
- badge-bench consumes the ring like the newer OS (`--wav` writes it);
  gaps between effects show as "underruns" there by design.

## 8. The streaming-audio ABI in detail

The badges now run newer OS firmware (sycl-badge upstream from 97c093e
"Streaming Audio, v1 Mixer", checked at 3392a1b). It drops the `tone`
voice (our carts' `tone2` calls are ignored there, docs/INSTALL.md) and
instead plays a ring of samples the cart owns. The pinned SDK (a6ce19f)
has no API for it, so `lib/stream_audio.zig` speaks the ABI itself
(`start(buf)`, `queued()`, `free()`, `push(samples)`); section 7 lists the
helpers built on it. Snouty Lynx (M5, `carts/snouty-lynx/PLAN.md` "M5
Sound: contract") feeds it directly from its own `frontend/audio.zig`.

- Format: unsigned 8-bit mono at 44,100 Hz, 128 = silence (the mixer,
  `drivers/audio.zig` `mix_audio_samples`, maps 0..255 to -volume..+volume;
  the volume is the OS's, set in its Start+Select settings box).
- The ring: a cart buffer, `align(8)`, described by four u32 words of the
  IPC block (base `0x20020000`, the same in both firmwares), where the old
  firmware had `tone_freq/duration/volume/flags`:

  | Address      | Word                | Written by | Meaning                              |
  |--------------|---------------------|------------|--------------------------------------|
  | `0x2003509C` | `audio_buffer_ptr`  | cart       | the buffer's address                 |
  | `0x200350A0` | `audio_buffer_len`  | cart       | its length in samples                |
  | `0x200350A4` | `audio_buffer_head` | cart       | the next sample the cart will write  |
  | `0x200350A8` | `audio_buffer_tail` | OS         | the next sample the OS will read     |

  Empty when head == tail; the cart fills at most len - 1; indices wrap at
  len.
- Start: write ptr, len, head = 0, tail = 0, `dmb`, then the SIO FIFO word
  `0x29000002` (CART_START_AUDIO): wait for FIFO_ST (`0xD0000050`) bit 1
  (RDY), write FIFO_WR (`0xD0000054`), `sev`, as the pinned runtime sends
  its words. Submit: write samples at head, `dmb`, store the new head.
- The OS fills one 512-sample DMA buffer at a time (~11.6 ms, two
  ping-pong), pads an underrun with silence, and stops audio itself when
  the cart exits. Because it reads 512 samples at a time the queue a cart
  sees jumps by up to 512 between frames; Snouty Lynx smooths it before
  its rate control (`frontend/audio.zig`).
- Never send CART_STOP_AUDIO (`0x29000001`): the OS answers with a FIFO
  word (`0x29000003`) the pinned runtime does not expect. To go quiet, stop
  submitting (Snouty Lynx pushes a 64-sample ramp to 128 first, no click).
- Old firmware: `0x29000002` has the type byte 0x29 of its CART_VOLUME,
  which re-applies `global_volume` (`0x200350AC`, never written) and plays
  nothing; the ring words land on the unused `tone_*` words. Harmless, no
  firmware detection needed.
- The pinned web simulator has no streaming audio: wasm builds stay
  silent.
