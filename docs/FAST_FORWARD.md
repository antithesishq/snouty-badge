# Fast forward in the emulators

Adrian, 2026-10-04: "add hold-to-fast-forward to Snouty Boy (and the other
emulators), the typical emulator feature, if technically feasible."

## Feasible?

Yes, with a speed that depends on headroom. Calibrated badge-bench busy
ms per update (mean), from each cart's PLAN.md:

| Cart | Budget | Mean | Rough FF speed |
|---|---:|---:|---|
| Gear | 16.7 ms (60 Hz) | 3.1 | 4x cap |
| Boy | 16.7 ms (60 Hz) | 4.0 (2048), 4.3 (Tetris DX), 8.5 (Tetris) | 2-4x |
| Lynx | 16.7 ms (60 Hz) | ~6 (M4) | 2-3x |
| Genesis | 33.3 ms (30 Hz, 2 frames/update) | 20.7 (Miniplanets) | ~1.5-2x |

Skipped frames do no pixel work (Boy's `lines_wanted`, Genesis already
renders only the last frame of an update), so they cost less than the
means above.

## Behaviour (Adrian decided the trigger 2026-10-04; the rest are defaults)

- **Trigger: tap Select, then press and hold it** (a double tap whose second
  press is held). Fast forward runs from that second press while Select is
  held; letting go returns to 1x and delivers nothing to the game. The
  second press never starts the 500 ms menu timer. A single long hold still
  opens the menu. There is no free badge button, and the first chord
  (hold Select, then Right) was dropped because holding Select brings up
  the menu; A+B was rejected because games press it.
- **The first tap is held back** for `ff_tap_window` (12 frames, 200 ms)
  after its release: a second Select press inside the window turns it into
  fast forward and the tap is dropped; otherwise the tap is delivered as
  before, 200 ms later than it used to be. Adrian: (b) "across the board",
  so Genesis (Select tap = a Genesis button) and Lynx (Option 1) take the
  same delay. Gear's Select tap does nothing, so it needs only the window.
- Start pressed during the window or during fast forward is the OS exit
  chord: cancel everything, deliver nothing (as the Select hold does now).
- **Speed: time-boxed, capped at 4x.** In a fast-forward update the cart steps
  game frames with rendering off until either `ff_max_frames` (4 per 60 Hz
  update; Genesis 8 per 30 Hz update) have run or `ff_budget_us` of the
  update's time is used. Then it steps one last rendered frame. Leave headroom
  for the update after it (target about 13 ms of a 16.7 ms update, 28 ms of a
  33.3 ms one). In wasm `micros_since_boot` is a stub, so use the fixed frame
  count there.
- **Pad:** every frame of a fast-forward update gets the same pad byte, with
  Select masked out; the d-pad and the other buttons go to the game as usual.
- **Sound:** silent while fast forwarding (ramp out the same way the menu
  does), and resume on release. Samples from skipped frames are not rendered
  (`audio_render = false` or equivalent), so fast forward costs nothing in
  sound.
- **Rewind:** every frame stepped goes through the usual `record_frame` /
  keyframe path, so the scrubber holds the fast-forwarded history (fewer
  wall-clock seconds, the same game frames). The rewind determinism self-check
  must stay clean.
- **Indicator:** a small `>>` (with the measured speed, e.g. `>>3x`, if it
  fits) in a corner while fast forwarding, drawn like the debug overlay. It
  must not leave a stale rectangle on the LCD (dirty rect, see
  emulator-scrub-dirty-rect: badge-bench `--lcd`).
- **Hints:** the play hint strip and the menu's help/controls text mention
  "2x Sel+hold: fast" (or similar).

## Tracks

Each cart is its own Opus track in its own worktree off `emu-ff`, merged
back here, then to main and pushed as soon as that cart is verified (Adrian
is at the show flashing from main).

| Track | Worktree / branch | When |
|---|---|---|
| Boy | /home/exedev/emu-ff/boy, `emu-ff-boy` | now |
| Gear | /home/exedev/emu-ff/gear, `emu-ff-gear` | now |
| Genesis | later | after its streaming sound lands on main |
| Lynx | later | after Lynx M5 sound lands on main |

## Verification per cart

- `zig build`, `zig build test`, `zig build check-float` green; other carts'
  UF2s byte-identical.
- Host tests for the input state machine (chord starts and stops FF, no tap,
  no menu, Start+Select chord still cancels) and for determinism (N frames at
  FF give the same console as N frames at 1x with the same pads).
- badge-bench with a script doing the double tap and hold: 0 updates over budget,
  reported frames per update (the achieved speed), no regression at 1x.
- Preview (wasm) contact sheet or GIF showing the `>>` indicator.
- Cart PLAN.md gets a short "Fast forward" status section with the numbers.

## Status

- 2026-10-04: plan written; Boy and Gear tracks started.
- 2026-10-04: Gear shipped with Select+Right (origin/main 0b4ae62, tag
  snouty-gear/ff). Adrian then switched the trigger to the double tap and
  hold above; Boy and Gear are being changed to it.
