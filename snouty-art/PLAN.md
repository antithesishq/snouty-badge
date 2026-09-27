# Snouty art pipeline: plan

Owner: Adrian Hatch (Antithesis). Started 2026-09-26.
Consumers: `../snouty-badge` (run + jump strips, 96x96 cells, origin (48,88)),
later `../snouty-bugs` and the other carts.

## Goal

Replace the chat-thread sprite workflow with a repeatable, code-driven one that
keeps the approved Snouty design (Run Study 05) and produces every derived
asset on-palette by construction. First deliverables: an alternative 16-frame
run cycle and a 12-frame jump sheet, drop-in compatible with the badge cart.

## Styles: several looks for the same requirements

Adrian wants to keep and compare multiple visual takes on the same animation
requirements. Each look is a directory `styles/<name>/` holding `rig.json`
(parts, pivots, joints, limb lengths), `palette.json` (up to 15 colours bound
to role names: FUR, SHIRT, NET, OUTLINE ...), `parts/`, and optional
`anim/<cycle>.py` overrides. The shared animations in `snoutyart/anim/` are
written against roles and joints only, so a new style renders with them
unchanged; a style overrides a cycle when its proportions need different keys.
Output is `out/<style>/<cycle>/`; `tools/compare_styles.py` renders all styles
side by side for review. Adding a style must never change another's output.

Styles so far:
- `study05`: the approved ChatGPT Study 05 Snouty (carved parts).
- `glean` (scrapped 2026-09-27): the lavender, big-headed Snouty from Claude's
  Glean test render. Adrian reviewed it in motion and rejected it: the arms
  did not work and the character was less cute than Study 05. Removed from the
  tree; recoverable from git history (commits efa066e..c701f36) if a similar
  approach is wanted later. Lessons kept: the resample-to-true-grid carve and
  the redraw-the-tee approach both worked mechanically.

## Approach: parts rig + procedural limbs

The Study 04/05 frames were built the same way, so we own that process here:

1. `rig/parts/` holds the canonical pixel parts cut from the reference
   (head, torso with Iris emblem, tail, net, two hands). `rig/rig.json` gives
   each part a pivot in reference coordinates and a default z-order.
2. `snoutyart/rig.py` composes a pose: integer translation per part, small
   nearest-neighbour rotations about the pivot (net, head, tail), z-sorted.
3. `snoutyart/limbs.py` draws legs and arms as outlined capsules through
   hip/knee/ankle/toe points, with a 2-bone IK helper, in the run palette
   (mid purple fill, dark rim on the lower-left, near-black outline).
4. `snoutyart/anim/*.py` are the animations: one Python file per cycle, each
   frame a small dict of joint positions and part offsets. These are the
   "source files" of the art and are meant to be edited and re-rendered.
5. `snoutyart/export.py` writes the Study-pack layout the badge repo already
   consumes: `frames/*.png`, horizontal strip, grid sheet, 4-bit indexed strip
   (index 0 transparent), `.json` metadata (origin, timing, feet rows, gait),
   `.gpl` palette, contact sheet and preview GIFs (isolated and scrolling ground).
6. `snoutyart/validate.py` fails the build if any frame is off-palette, has
   soft alpha, leaves the cell, or if planted toes do not travel exactly the
   gait step. Validation output is committed with the pack.

Rendering is deterministic: `python3 tools/build.py all` regenerates `out/`.

## Constraints (from the cart)

- Cell 96x96, origin (48,88), ground baseline y=88, facing right.
- 15 opaque colours from `ref/snouty_palette.gpl` plus transparency; alpha 0/255.
- Run: 16 frames, forward loop, near-foot contact at 0, far-foot contact at 8,
  flight at 6-7 and 14-15, planted toe travels 6 px per frame.
- Jump: 12 frames with the Study 04 semantics the cart relies on:
  0 stand, 1 dip, 2 crouch, 3 coil, 4 takeoff, 5 rise, 6 apex, 7 late apex,
  8 descent, 9 reach, 10 land, 11 recover. Per-frame feet rows go in the JSON;
  the cart's `jump_feet_rows` table is updated from it.

## Milestones

- M0: repo, references, rig parts, plan. Done 2026-09-26.
- M1: core library (palette, rig, limbs, export, validate, preview) and a
  first-pass run cycle that renders and validates. Done 2026-09-26.
- M2: run cycle polished as an alternative to Study 05 (more lean, stride and
  follow-through on tail/net), and the jump sheet, developed in parallel by
  two agents. Done 2026-09-26; awaiting Adrian's review of `out/`.
  Open taste questions: both run legs emerge from under the shirt (Study 05
  crosses the near thigh in front); head nod is only +-1 degree because
  larger nearest-neighbour rotations break up the pixels.
- M2b: multi-style refactor (kept) and a `glean` style with its own run and
  jump (2026-09-27, reviewed and scrapped; see Styles). Decision: the
  `study05` revision is the version to carry forward.
- M3 (next): hand-off. `python3 tools/install_badge.py` copies `out/run` and `out/jump` into `snouty-badge/assets/` as
  study packs, point `tools/prepare_assets.py` at them, update feet tables,
  verify in the simulator.

## Later

Idle, slide, land-hard, hurt cycles. Small enemies and bullets for snouty-bugs
(authored directly in code). Palette swaps. Left-facing variants (flip at
export, the emblem is symmetric enough).

## Maze pack (2026-09-27)

Adrian's art guidance for `../snouty-maze`: Snouty from the study05 run
frames (with the net), a Zig mark where the original had the OpenGL word,
the Start button with the Iris mark in place of the Windows flag, and a
pixel version of the Iris mark itself (`ref/iris-logo-ref.png`, placed by
Adrian). Everything is a downscale of an existing image, so the pipeline
gains a generic downscaler rather than new rig work:

- `snoutyart/downscale.py`: crop to the opaque bounding box (optionally
  keying a white background), fit inside a box preserving aspect, area
  average with the alpha resized separately, threshold alpha at 0.5, then
  snap every opaque pixel to the nearest colour of a given palette (the
  style palette for Snouty, the mark's own colour for the flat logos) or
  median-cut to at most 15 colours; the palette is RGB565-snapped so the
  cart sees the same count we validate.
- `tools/build_maze.py` writes `out/maze/`: `snouty.png` (128x32, frames
  0,1 face left = mirror, 2,3 face right, from run frames 0 and 8),
  `logo.png` (Zig mark, 32x32), `iris.png` (Iris mark, 32x32),
  `start.png` (Start button with the flag region repainted and the Iris
  mark composited at source resolution before the downscale), plus a 4x
  contact sheet. All cells keep a 1 px empty border as the maze validator
  requires. Sources: `ref/zig-mark.svg` (ziglang/logo, CC BY-SA 4.0,
  rasterised with ImageMagick), `ref/iris-logo-ref.png`,
  `../snouty-maze/assets/src/w95/start2.png`, `out/study05/run/frames/`.
- The maze's `prepare_assets.py --from-w95 ... --art ../snouty-art/out/maze`
  takes these sheets instead of its procedural Snouty and Iris mark.
