# Snouty NES: notes

Status: notes only (2026-09-30). Not a spec, not scheduled. Written after
the "what is left" reflection: NES was item 2 in the 2026-09-27 next-cart
order and was skipped for Snouty Boy Color and Snouty Genesis. This file
collects what we already know so a SPEC.md can be written quickly if
Adrian picks it. Facts about the NES are from public docs (nesdev wiki)
and marked "check" where they drive a design decision.

## 1. Why

- The most recognizable console at any booth. Everyone knows what a
  Mario or Zelda screen looks like, so the badge gets judged in the first
  second, and this one wins that second.
- Cheapest emulator we have not built: 6502 at 1.79 MHz (29,780 CPU
  cycles per frame, about the same order as the Game Boy's 17,556
  M-cycles that badge-bench models at 8.6 ms mean). The work is the PPU
  and the mappers, both well understood.
- Reuses everything the other emulators built: drive ROM path
  (`lib/romfs.zig`, `docs/ROM_DRIVE.md`), Iris splash (`lib/iris_mark.zig`),
  menu and time-scrub model (Snouty Boy section 10, Gear delta keyframes),
  the preview harness and badge-bench flow. The 6502 core is also the
  first step of Snouty Lynx (65SC02) and any 2600 or C64 cart.

## 2. Hard numbers that shape the design

| NES | Badge |
|---|---|
| 256x240 picture (224 visible on most TVs) | 160x128 |
| 2 KB CPU RAM, 2 KB VRAM nametables, 256 B OAM, 32 B palette | 307 KB RAM (XIP) or ~200 KB (RAM cart) |
| PRG ROM 16 KB to 512 KB, CHR ROM/RAM 8 KB to 256 KB | read in place from the drive |
| APU: 2 pulse, triangle, noise, DMC | one tone2 voice with a shape |
| 60.1 Hz, 262 lines x 341 dots | 60 Hz LCD |

State is tiny: about 4.5 KB without PRG RAM or CHR RAM, ~13 KB with 8 KB
PRG RAM, up to ~21 KB with CHR RAM. Keyframes are cheap, so the scrubber
gets deep history (30+ s uncompressed) without the Gear delta store.

## 3. The screen: the one real design problem

256x240 onto 160x128 is 1.6:1 wide and 1.875:1 tall, worse than any
console so far. Three modes, all selectable in the menu, one default:

1. **Fit (default candidate)**: LUT-based row and column selection, the
   "render only output lines/columns" trick from the survey. Only 128 of
   240 scanlines are run through the PPU pixel pipeline (the others still
   advance sprite evaluation and timing but skip pixel output), and only
   160 of 256 dots produce pixels. Cuts PPU pixel work to about 33% of a
   full render, which is where the budget goes. Text gets uneven but
   playable; try 2:1 averaging on columns (128 wide, 16 px side bars)
   as a variant if the LUT drop reads badly.
2. **Half**: 2x2 box average to 128x120, centered with 16 px bars left and
   right and 4 px top and bottom. Every pixel of the original is
   represented, text stays legible. Costs a full-resolution PPU render,
   so it is the perf worst case; measure first.
3. **Window**: a 160x128 crop that follows the scroll registers (what the
   Game Gear did in hardware for Master System games). Perfect pixels,
   loses the edges. Good for single-screen and vertically scrolling
   games, bad for platformers where the player sits near an edge.

Decision for the spec: measure mode 2 in badge-bench on the scaffold; if it
fits under ~12 ms with the CPU, make it the default because it is the
honest picture. Otherwise mode 1.

## 4. Sound

Badge V2 has one tone2 voice (frequency, volume, shape: square, triangle,
sawtooth, sine, major, minor). It is not the four-channel V1 API. So NES
sound is the same priority-voice scheme as Snouty Gear's PSG and Snouty
Genesis: model the APU registers, and each frame pick one channel to send
to tone2. Rule of thumb from the Gear work: newest note-on wins, pulse
channels over triangle, noise only when nothing else plays (noise has no
shape here; skip it or map to a low sawtooth burst). Duty from the pulse
register maps to nothing in tone2 (no duty control), so all pulses are
square. Triangle maps to `.triangle`. If the OS gains a PCM path (the
"real audio" item from the reflection), the APU becomes a proper mixer and
this section is replaced.

The simulator tone shim caveat applies (drive `tone` directly, see the
badge-simulator-tone-shim note).

## 5. Mappers

Coverage by library share: NROM (0), MMC1 (1), UxROM (2), CNROM (3),
MMC3 (4) cover roughly 80% of licensed titles and nearly all homebrew.
Ship those five. MMC3's scanline IRQ counts PPU A12 rises; a scanline
approximation (fire at dot 260 of rendered lines when enabled) is what
most small emulators do and is fine for the games we would show. AxROM (7)
is a cheap sixth if a chosen ROM needs it.

## 6. Accuracy target and tests

- CPU: Tom Harte's ProcessorTests 6502 JSON (per-instruction, ideal for
  Zig host tests; sparse fetch like the Lynx plan), then `nestest.nes`
  with the reference log.
- PPU: Blargg's `ppu_vbl_nmi`, `sprite_hit_tests`, `sprite_overflow`;
  no need for dot-accurate mid-scanline register changes at first, but
  the vblank/NMI timing and sprite-0 hit must be right or scrolling games
  break (Mario status bar splits use sprite 0).
- Scanline renderer, not a dot renderer: render each visible line at the
  end of the line from the registers as they were. Cheaper and sufficient
  for the target library. Games that change scroll mid-line (rare) will
  glitch; accept.
- The Snouty Boy determinism test (restore keyframe k, replay 30 inputs,
  byte-equal to k+1) is mandatory from M1.

## 7. ROMs

Nothing commercial ships. Candidates to license-check for the embedded
fallback and the demo drive: Nova the Squirrel (open source), Alter Ego
(Shiru, freeware), Böbl, Blade Buster, Lizard demo, NESdev compo entries,
Micro Mages demo build (commercial, ask). Users copy their own `.nes`
onto the drive per `docs/ROM_DRIVE.md`. iNES header parsing only (NES 2.0
fields read where present).

## 8. Budget guess (to be replaced by badge-bench numbers)

- CPU: ~30k cycles per frame, Zig switch interpreter, expect 3 to 5 ms.
- PPU fit mode: 128 lines x 160 px background plus sprites, expect 3 to
  5 ms. Half mode maybe 8 to 10 ms.
- APU register model plus tone2: under 0.2 ms.
- Total 7 to 11 ms of the 16.7 ms frame; no frame skip needed. If it
  comes in high, the LUT trick has more room (drop more lines from
  rendering, never from timing).

## 9. Layout and reuse

Scaffold from `carts/snouty-gear` (the cleanest emulator layout: core/,
cart/src/frontend/, tests/, tools/). RAM cart by default; XIP only if
code plus CHR RAM plus keyframes will not fit, which is unlikely.

## 10. Open questions for Adrian

1. Default screen mode (section 3): honest half-size picture or filled
   screen with dropped lines? Best decided from two GIFs.
2. Ship with the priority-voice sound, or wait for the PCM OS change?
3. Which homebrew ROM is the embedded fallback (license first)?
4. Does this come before or after Snouty Lynx (they share the 6502 core;
   NES is the cheaper first outing for it)?

## 11. Milestone sketch

- M0 scaffold + 6502 core against ProcessorTests + nestest log.
- M1 PPU scanline renderer, NROM, fit and half modes, plays the fallback
  ROM in the preview; badge-bench numbers.
- M2 mappers 1-4, drive loading, Iris splash, menu, sound, screen modes.
- M3 scrub (Boy model), determinism test, attract from a replay.
