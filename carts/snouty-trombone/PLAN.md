# Snouty Trombone: plan

## M1: playable trombone (branch trombone/m1, tag snouty-trombone/m1)

1. Cart skeleton from snouty-theremin's structure, registered in the root
   build (app letter, carts list, CI release list, README cart table).
2. horn.zig: slide + embouchure + lip-bend model, host tests (positions
   1..7 hit equal-tempered semitones, partial hysteresis, monotonic slide
   gliss, crack only at boundaries).
3. hand.zig on lib/tof_pose.zig centroid + distance median; stick fallback;
   demo hand.
4. voice.zig brass voice + plunger mute, integer DSP, audio CPU benched.
5. Pixel-art trombone (host generator), slide moves with the hand, position
   ruler, partial ladder, note readout, bell notes.
6. Gates: `zig build`, `zig build test`, `zig build check-float
   -Dcart=snouty-trombone`, badge-bench worst update under budget with the
   demo hand and with `-Dtof-fake=true`, preview GIF docs/preview_m1.gif,
   docs/RUNNING.md.
7. Merge to main + push (Adrian asked 2026-10-06), tag snouty-trombone/m1.

## Deferred questions (defaults taken)

1. Slide on hand height (distance), embouchure on hand left/right
   (centroid x). Default: as briefed, sensor facing up.
2. Blowing: AUTO (hand in range sounds) default; BLOW A option.
3. B = plunger mute (wah). Nothing displaced (new cart).
4. Sound boots ON like the theremin.
5. Badge check: hardware feel of the throw (100..450 mm) and the
   left/right partial spacing.

## Status

- 2026-10-06: SPEC + PLAN written; M1 in progress.
