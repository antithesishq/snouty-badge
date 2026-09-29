# Neopixels off across all carts

Status: spec approved by Adrian 2026-09-29 (design in section 4, decisions in
section 8). Execution waits for Adrian's go.

## 1. Why

A coworker with a physical SYCL Badge V2 reports the five neopixels are
unusably bright: even at 1% (about 2 or 3 of 255 per channel) they are too
strong to look at. Every cart so far follows the root `CLAUDE.md` rule
"keep channels at or below 10/255" (about 4%), which is above that. The
decision is to turn the neopixels off in every cart rather than chase a
lower cap. The rule becomes: **carts never write a non-zero neopixel
value.**

## 2. How the LEDs get lit today (what we control)

- The cart API exposes `cart.neopixels`, five GRB bytes triples in shared
  RAM (`sycl-badge/src/os/cart/api.zig`).
- The OS kernel (Core 0) copies those 15 bytes to the WS2812 PIO on every
  `present()`, unconditionally (`sycl-badge/src/os/kernel.zig`, "push
  neopixels on every present"). It zeroes them when a cart starts and
  resets the strip when a cart stops. The OS menu itself never lights
  them.
- So a cart that never writes non-zero values leaves the strip dark. No OS
  change is needed for the fix; see section 6 for an optional OS-side belt
  and braces.

## 3. Current writers, per cart (monorepo `main` at 53eaae2)

| Cart | Writes `cart.neopixels`? | Where | Default | Toggle |
|---|---|---|---|---|
| snouty-run | no | (PLAN "deferred v6+": coral foot pulse) | off | none |
| snouty-bugs | not yet | SPEC section 11 fuel meter, planned M6/M7; `main.zig` has the `// audio/neopixel effects (M6)` hook | off | Select (sound + LEDs) |
| snoutenstein | yes | `cart/src/audio.zig`: `write_leds` (HP bar, key flash, dead), `rewind_tick` (purple pulse) | off (`enabled = false`) | Select on title (sound + LEDs) |
| snouty-reflections | not yet | SPEC section 8 bias lighting, planned M4 | on (spec) | Select |
| snouty-boy | yes | `cart/src/frontend/menu.zig`: `set_leds` history meter while the menu is open; `close()` clears | on in menu, no toggle | none |
| snouty-maze | yes | `cart/src/leds.zig` (brick, purple pulse, white teleport, breathing, amber MANUAL) | off | Select (LEDs only) |
| snouty-gear | not yet | SPEC: ring depth meter in the menu (M1 in flight, worktree `snouty-badge-gear`) | | |
| snouty-genesis | not yet | SPEC: ring depth meter in the menu | | |
| snouty-lynx | not yet | SPEC section: ring depth meter in the menu | | |

Read-only users of `cart.neopixels` (keep, they become "assert zero"):
`debug_leds` / `debug_led_max` exports in snouty-boy `main.zig` and
snouty-maze `main.zig`.

The standalone repos `/home/exedev/snouty-bugs` and `/home/exedev/snouty-boy`
are superseded by the monorepo (last commits 2026-09-26/27) and are not
changed.

## 4. Design

### 4.1 One build option, off by default

Add `neopixels: bool` to the shared options in `build/common.zig`, exposed
as `-Dneopixels=true` in the root `build.zig` (help text: "Allow carts to
light the neopixels. Default off: the LEDs are painfully bright on
hardware"). Each cart that has LED code passes it through its
`build_options` module exactly as `debug_overlay` is passed today
(`carts/snouty-maze/build.zig` is the template).

Every LED module keeps its logic but funnels all writes through one
function that is a comptime no-op when the option is false:

```zig
const build_options = @import("build_options");

/// The only place in the cart that writes cart.neopixels.
fn write_pixels(c: [5]cart.NeopixelColor) void {
    if (!build_options.neopixels) return; // OS zeroes the strip at cart start
    for (c, 0..) |p, i| cart.neopixels[i] = p;
}
```

Rationale for a build gate rather than deleting the code: snoutenstein,
snouty-maze and snouty-boy each carry a working, reviewed LED module with
tests. A comptime-false branch compiles to nothing (zero cost on the badge,
no comptime load for the Mac build), and the effects stay available for a
future badge revision or a diffuser. Rationale for off-by-default rather
than a runtime Select toggle: the runtime toggles already exist and are not
enough, because one press of Select lights the strip at 10/255.

### 4.2 Per-cart changes

- **snoutenstein** `audio.zig`: route `write_leds` and `rewind_tick`'s final
  loop through `write_pixels`. Select keeps toggling sound; "and LEDs"
  drops out of the title hint text if it is printed anywhere.
- **snouty-maze** `leds.zig`: `update()` writes through `write_pixels`.
  `leds.toggle()` still flips `enabled` so the F test's `debug_leds == 1`
  stays meaningful; document Select as a no-op for the player unless built
  with `-Dneopixels=true`. (Alternative, Adrian's call: repurpose Select
  in the screensaver states. Not part of this change.)
- **snouty-boy** `menu.zig`: `set_leds` writes through `write_pixels`. Keep
  the `led_on <= 10` compileError as-is; it only matters when the option
  is on. Touch only `set_leds` to keep the diff tiny, because `menu.zig`
  and `main.zig` are also modified on the in-flight `boy/rom-loader` and
  `snouty-boy-color` branches.
- **snouty-bugs**, **snouty-reflections**, **snouty-gear**,
  **snouty-genesis**, **snouty-lynx**: no code yet. Their planned LED
  features (fuel meter, bias lighting, ring-depth meters) are dropped from
  the specs outright, not kept dormant: they were never built, so there
  is nothing to preserve. These carts do not take the build option.
- **snouty-run**: nothing to do; strike the deferred coral pulse from
  `PLAN.md`.

### 4.3 Regression guard in badge-bench

`badge_bench/run.py` already reads the neopixels after every update and
`report.py` prints "neopixels/user LED: N distinct states". Add a warning
to `res.warnings` (surfaced in the report and `bench.json` like the
"unmodelled register" warnings) when any frame has a non-zero neopixel
byte: `neopixels written: frame F, max channel V`. Every cart's normal
bench run then fails loudly if an LED write sneaks back in. This is a
small Python change and costs nothing on the badge.

### 4.4 Tests and debug exports

- snouty-maze `tools/check_cycle.mjs` test F: expectations become
  `debug_leds == 1`, `debug_led_max == 0` (the toggle flips, the strip
  stays dark). Update the comment on line 30 and `docs/RUNNING.md` lines
  300 and 301.
- snouty-boy `docs/RUNNING.md` line 261: `--at "330 debug_leds == 5"`
  becomes `debug_leds == 0`; describe `debug_led_max` as "must be 0".
- snoutenstein: no LED test exists; its determinism harness is
  unaffected (LEDs are render-side).
- Host `zig build test` for every cart must still pass; the LED modules
  are compiled in both states, so also build once with
  `-Dneopixels=true` to keep that path from rotting (a one-line addition
  to whatever CI-style check script each cart has, or a note in
  `RUNNING.md`).

## 5. Documentation edits

Replace every "at or below 10/255" rule with "neopixels are off; carts
never write non-zero values; `-Dneopixels=true` re-enables the dormant
effects for development".

- Root `CLAUDE.md` line 54.
- Cart `CLAUDE.md`: snouty-bugs 35, snouty-maze 42, snouty-reflections 33,
  snouty-run 25, snoutenstein 46.
- `SPEC.md`: snouty-bugs (30, 51, 58, 179, section 11 at 355 to 378, 439,
  471, 483, M7 at 539), snouty-boy 296, snouty-reflections (47, section 8
  at 220 to 230, M4 at 326), snouty-genesis (283, M3 at 388), snouty-gear
  (312, 458), snouty-lynx 259, snouty-maze (48, section 9 at 294 to 302,
  358), snoutenstein (40, 298, section 12 at 327 to 350, 416). For the
  three carts with LED code (snoutenstein, snouty-maze, snouty-boy) keep
  the effect descriptions under a "Dormant, behind -Dneopixels" heading.
  For every other cart delete the neopixel text; Select in snouty-bugs
  and snouty-reflections becomes a sound-only toggle.
- `PLAN.md`: snouty-run 287, snouty-bugs 15 and 205, snouty-maze 500 to
  547 and 687 to 699, snoutenstein 535 to 590 and 677, snouty-boy 117 and
  126.
- `docs/RUNNING.md` for snouty-boy (174, 238, 261) and snouty-maze (80,
  99, 273, 300).
- `badge-bench/README.md`: mention the new warning next to the neopixels
  column (line 78) and in the "None of the carts wrote neopixels" note
  (486).

## 6. Optional: OS-side kill switch (not in this change)

The fork branch `fix/core1-dwt-trcena-pinned` of `sycl-badge` could zero
the strip in `drivers/neopixel.zig::set_neopixels` behind a build flag.
That protects against third-party carts too, but only on badges flashed
with our OS, so it does nothing for the coworker's badge or attendees.
Upstream is `ZigEmbeddedGroup/sycl-badge`; a brightness scaler in the OS
driver would be a reasonable upstream PR later if the hardware is this
bright for everyone. Decision: cart-side change first; revisit the OS only
if Adrian wants it.

## 7. Landing plan

1. `build/common.zig` + root `build.zig`: the option (one commit).
2. snoutenstein, snouty-maze, snouty-boy code + tests (one commit per
   cart; all three can run in parallel, they touch disjoint files).
3. badge-bench warning + README (one commit).
4. Docs sweep from section 5 (one commit).
5. Rebase the five worktrees (`gear/m0`, `reflections-m2`,
   `snouty-boy-color`, `boy/rom-loader`, `snoutenstein-m4`) onto main.
   Only `snouty-boy-color` and `boy/rom-loader` overlap
   (`menu.zig`/`main.zig`); the `set_leds`-only diff keeps that trivial.
6. Verify: `zig build` (all carts, ram and xip), `zig build test`, each
   cart's check script, then `badge-bench` runs of snoutenstein,
   snouty-maze and snouty-boy with Select pressed / menu open showing
   zero neopixel states and no warning. Hardware: flash one cart, open
   the boy menu and press Select in maze, confirm the strip stays dark.

Estimated size: about 60 lines of Zig, 30 lines of Python, and a large
but mechanical docs diff. One Opus agent per cart in step 2, one for
steps 3 and 4.

## 8. Decisions (Adrian, 2026-09-29)

- Design in section 4 approved as written.
- Future carts (bugs, reflections, gear, genesis, lynx): drop the
  neopixel features from their specs entirely, no dormant copy.
- snouty-maze: Select is not repurposed for now; it stays a no-op toggle.
- OS-side kill switch (section 6): not asked for; stays optional.
- Execution starts when Adrian says so.
