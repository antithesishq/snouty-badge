# Sound off by default across all carts

Status: decided by Adrian 2026-09-30 (section 4), implemented on branch
`sound-off` the same day. Companion to docs/NEOPIXELS.md, which this
follows in shape.

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
| snouty-boy | yes, APU voice + boot chime | `frontend/menu.zig` `sound_enabled`, copied into `audio.enabled` each frame | `-Dsound` (off) | menu row "Sound: On/Off" |
| snouty-gear | yes, PSG voice + boot chime | same shape as Boy; the wasm build drives the simulator's `tone` import itself | `-Dsound` (off) | menu row "Sound: On/Off"; `debug_settings` bit 0 |
| snouty-genesis | yes, PSG/YM2612 tone voice | `frontend/audio.zig` `enabled` | `-Dsound` (off) | badge A in the menu placeholder ("A: sound on/off"); the M2 menu's Sound row takes over; `debug_sound_on` |
| snouty-bugs | not yet (SPEC section 11, M6/M7) | | `-Dsound` (off) | Select |
| snouty-reflections | not yet (SPEC section 8, M4 arpeggio) | | `-Dsound` (off) | Select |
| snouty-lynx | not yet (spec only, section 9) | | `-Dsound` (off) | menu |
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
