# Snouty Shader: plan

`SPEC.md` is the design. Worktree `/home/exedev/snouty-badge-shader`,
branch `shader/m1` (the parent session reviews, merges and pushes).

## M1: the gallery

- Cart skeleton (build.zig, root build.zig entry, check-float, host
  tests, badge-bench toml, README/INSTALL/CLAUDE.md rows).
- sensor.zig and hand.zig from snouty-morph (sensor, stick, ghost).
- field.zig (3x3 to 80x64 Catmull-Rom), uniforms.zig (smoothing, punch,
  flash, kick), surface.zig (spread RGB565, 2x bilinear upscale),
  palette.zig (cosine palettes), noise.zig (tileable gradient noise).
- Six programs: INK, RIPPLE, LAVA, ECHO, CELLS, KALEIDO.
- app.zig: buttons to actions (program, palette, parameter, HUD, stick,
  sound on Start release, the Start+Select chord ignored), attract.
- hud.zig: inputs panel on B, toasts.
- sound.zig: drone, thump, blip; boots silent.
- Preview GIF, docs/RUNNING.md, badge-bench per program (normal and
  `-Dtof-fake=true`).

Acceptance: gate green (`zig build`, `zig build test`, `zig build
check-float`), every program under 12 ms worst busy in badge-bench, both
builds; the GIF shows several programs driven by the ghost.

## Status

(filled in at the end of M1)

## Deferred decisions (defaults taken; Adrian may flip any)

(filled in at the end of M1)
