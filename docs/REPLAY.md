# Deterministic replay as a first-class feature (parked)

Status: 2026-09-30, parked by Adrian. Not scheduled, no milestone. Kept
so the idea is not lost; the reasoning for parking it is in section 5.

## 1. What we already have

Every rewind-capable cart uses the same machinery:

- A keyframe ring plus an input log, in RAM. Snouty Boy and Snouty Gear
  snapshot every 30 frames and log the pad byte per frame (Boy SPEC
  section 10, Gear section 10). Snoutenstein and Snouty Bugs keep a ring
  of whole-state structs and a controls ring (Snoutenstein SPEC 9.2, Bugs
  SPEC 13.1).
- Determinism self-checks: restore keyframe k, replay the logged inputs,
  require byte equality with keyframe k+1 (`tests/determinism.zig` in
  Boy and Gear; Snoutenstein counts desyncs at every keyframe and the
  harness asserts zero).
- Determinism rules: no `rand`, no clock, no floats inside the
  simulation. Snoutenstein's sim is 16.16 fixed-point so wasm and the
  Cortex-M33 agree bit for bit.
- One consumer beyond rewind: Snoutenstein's attract demo is a keyframe
  plus an input log, embedded at build time.

All of it serves scrubbing a few seconds backwards during play. It is
volatile, bounded to 5 to 10 seconds, visible only as a scrubber, and
never leaves the badge.

## 2. What first-class replay would add

Portability and proof, not new simulation machinery. A replay becomes a
small file with a defined format that starts from a canonical reset,
covers a whole session, carries its own checkpoints, and moves between
the badge, the web simulator and badge-bench with identical results.

1. **Format and shared library.** `lib/replay.zig`: header, cart id,
   content identity (ROM or level hash, so a replay refuses the wrong
   file), run-length coded inputs (one byte per frame is 3.6 KB per
   minute raw, far less coded), and a state hash every N frames so a
   player verifies as it goes. Each cart supplies `reset()`,
   `step(input)` and `hash(state)`.
2. **Whole-session recording from reset.** The log starts at power-on or
   an explicit reset and grows for the session (minutes fit in RAM).
   Rewinding truncates the log, as the rings already do.
3. **Cross-platform identity.** `tools/preview.mjs` already scripts
   inputs into the wasm build, so host recording is nearly free. New:
   run the same file in badge-bench's emulated M33 and on hardware and
   compare checkpoint hashes. Three-way agreement (wasm, cycle-emulated
   M33, real chip) is the Antithesis sentence in one demo. Emulator cores
   are pure integer and qualify already; Bugs and Maze call the badge's
   `rand()` and would need the Snoutenstein treatment.
4. **Off the badge.** The hard part. Carts cannot write anywhere: the
   SDK save-flash calls are stubs returning zero and the drive is
   read-only from the cart. Two exits without an OS change: `trace()`
   over the debug console (proven by the calibration capture), or a QR
   code drawn on the LCD. A one-minute Game Boy run coded to a few
   hundred bytes fits a QR version that renders at two pixels per module
   inside 128 pixels. Scan it, and the badge-manager station writes it
   onto any badge's drive.
5. **Onto the badge.** Solved: the drive path reads files in place, so
   replays sit next to ROMs and the menu lists them.
6. **Consumers.** Attract modes become replay files instead of embedded
   build artifacts. Determinism tests become "play this file, expect
   this hash". Show-day hardware verification becomes "run the replay
   pack, all green".

## 3. Milestones, if ever

- R0 library, host recorder in the preview tool, badge-bench playback
  with hash output.
- R1 one emulator (Snouty Boy) with on-screen verification.
- R2 QR export and the trace fallback.
- R3 roll to Gear, Genesis, Snoutenstein, Bugs; convert attract modes.

## 4. Decisions that would be Adrian's

Which cart first; whether QR export earns its code or trace alone
suffices; whether replays ship embedded as well as on the drive.

## 5. Why it is parked (Adrian, 2026-09-30)

The idea is cool, and the QR-on-LCD export especially, but it is unclear
what anyone would do with a replay once they have it. Time and
implementation effort are better spent on things people can do on the
cart. Revisit only if a concrete use appears (for example a show-day
verification pack, section 2 item 6, if hardware verification of many
carts becomes the bottleneck).
