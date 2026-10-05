# Snouty Morph: design

A demoscene toy for the SYCL Badge V2 and the TMF8820 time-of-flight
breakout (docs/TOF.md): a shaded 3D mesh floats over a moving demo
backdrop, follows your hand in six degrees of freedom and deforms with it.
Bring your hand close and the surface reaches for it; whip it sideways and
the mesh wobbles like jelly; turn or circle it and the mesh twists; punch
toward the sensor and a shockwave ripples through the vertices with a
palette flash. With no hand (or no sensor) a ghost hand flies the same
pipeline, so the cart is never still. Binary `snouty-morph`.

## 1. What a 3x3 depth sensor can and cannot tell us

The 8820 gives nine zones (3x3, about 33x32 degrees in total with SPAD
map 1, so ~11 degrees per zone), each with up to two targets {mm,
confidence}, 30 frames a second at the default 550 k iterations. Optional
10x128-bin photon histograms (~57 mm per bin). At 150 mm a zone is ~29 mm
wide on the hand, at 300 mm ~58 mm: an open hand covers the whole grid up
close and two or three zones at arm's length.

| DoF | Source | Quality |
|---|---|---|
| present | any zone with a valid target clearly in front of the learned background | very good |
| z | robust weighted mean of hand-zone distances (or the plane at the centroid) | very good: 1 mm steps, ~2 mm noise, +-3 % |
| x, y | coverage-weighted centroid of hand zones, sub-zone shift for partly covered zones | fair: three cells, made continuous by partial coverage; best with histograms |
| pitch, roll | weighted least-squares plane through the hand points | good with >= 3 non-collinear hand zones (close range); one axis with a row/column; none with 1-2 zones |
| yaw | orientation of the coverage blob's second moments (long axis), mod 180 degrees | weak: needs an elongated blob over >= 3 zones; reported with a confidence the cart uses to de-emphasise it |
| swirl | angular momentum of the centroid about the grid centre (x vy - y vx) | good: circling the hand is easy to see even when yaw is not |
| velocities | One Euro filter derivatives per DoF | z velocity is excellent (a punch is unmistakable) |

What it cannot do: tell a flat hand from a fist (both are one blob), see
fingers, resolve x/y finer than partial coverage allows, or measure yaw
when the hand covers all nine zones (no elongation) or only one. Partial
coverage without histograms is inferred from confidences, which is rough;
with histograms the near and far peaks' heights (compensated by distance
squared) give the covered fraction properly. The library reports a
confidence per DoF and the cart scales each effect by it, so a weak DoF
fades out instead of jittering.

## 2. The pose library (`lib/tof_pose.zig`, pure, host-tested)

`Estimator.update(frame, histograms_or_null, orientation) -> Pose`, run
once per sensor frame (not per pixel), f32 throughout (the M33 FPU is
single precision), no allocation, ~10 us.

1. **Zone geometry.** The orientation maps device zones to screen cells
   (col 0 left, row 0 top). Cell centre angles `ax = (col-1) * fov_x/3`,
   `ay = (1-row) * fov_y/3`; a zone's point is `d * unit(tan ax, tan ay, 1)`
   (the device reports path length along the zone's ray).
2. **Background model** per zone. Starts empty ("nothing within range").
   A target farther than the background (or none at all) for a few frames
   pushes the background back at once; one within a margin of it nudges it
   (EMA); one clearly nearer (margin = max(50 mm, 8 %)) is a hand
   candidate, and one that stays perfectly still for `absorb_s` (8 s) is
   absorbed into the background (a box put in front of the badge stops
   being a hand). `relearn()` takes the current frame as background.
   Nothing beyond `max_mm` (600) is ever a hand.
3. **Hand zones and coverage.** A zone is hand when its near target is a
   candidate. Coverage c in (0, 1]: with histograms, the near and far peak
   areas weighted by distance squared, `c = a_near / (a_near + a_far)`;
   without, `c = conf_near / (conf_near + conf_far)` when the far target is
   the background, else `conf_near / conf_full` against a running
   reference of a fully covered zone. Clamped to [0.15, 1].
4. **Centroid with sub-zone shift.** First pass: coverage-weighted mean of
   cell centres. Second pass: every partly covered cell's point moves
   toward the first-pass centroid by `(1-c) * cell/2` on each axis where
   the centroid is offset (the hand enters a zone from the side its
   neighbours are on), so a hand sliding from one cell to the next moves
   x continuously instead of in three steps.
5. **z**: weighted mean of hand-zone distances, weights coverage x
   confidence, zones more than `outlier_mm` (120) from the first estimate
   dropped and the mean recomputed.
6. **Tilt**: weighted least squares `z = a + b x + c y` over the hand
   points (3x3 normal equations by Cramer's rule). Conditioning decides
   confidence: a well-spread set gives both axes; a set spread along one
   axis only gives that axis; otherwise none. pitch = atan(c) (positive:
   top of the hand farther from the sensor), roll = atan(b) (positive:
   right side farther). Unmeasured tilt relaxes toward 0.
7. **Yaw**: second moments of the (shifted) coverage blob in angle space;
   `theta = atan2(2 Sxy, Sxx - Syy) / 2`, elongation `(l1 - l2)/(l1 + l2)`
   as confidence (zero below three zones); unwrapped mod pi to the
   nearest of the previous value so it does not flip.
8. **Filtering**: a One Euro filter per DoF (min cutoff and beta per DoF,
   dt from the frames' `time_us`), so a still hand is steady and a fast
   one is not laggy; velocities from the filters' derivative stage, plus a
   lightly filtered z velocity for punches. Presence has hysteresis
   (`lost_frames` = 4 absent frames before the hand is gone; the pose holds
   meanwhile) and the filters restart from the first measurement of a new
   hand.

`Pose { present, zones (hand-zone count), coverage[9], x, y (fraction of
the half field of view, -1..1), x_mm, y_mm, z_mm, pitch, roll, yaw
(radians), conf_xy, conf_z, conf_pitch, conf_roll, conf_yaw (0..1), vx,
vy, vz_mm_s, vpitch, vroll, vyaw, swirl }`.

`lib/tof_synth.zig` is the inverse: a hand (a tilted, rotated ellipse with
centre, semi-axes, pitch/roll/yaw) over a per-zone background, rendered
into a `Frame` (and optional `Histograms`) by casting an 8x8 ray bundle per
zone. It is what the host tests check the estimator against, and the
cart's ghost hand uses it too, so attract mode runs the real estimator.

## 3. The cart

### Meshes (Start cycles; generated at `start()` in code, light comptime)

| Mesh | Geometry | Shading | Backdrop |
|---|---|---|---|
| KNOT | (2,3) torus knot tube, 64 x 8 = 512 vertices, 1024 faces, rainbow along its length | Gouraud | copper bars + stars |
| BLOB | icosphere, 3 subdivisions: 642 vertices, 1280 faces, Snouty purple | Gouraud | plasma |
| SNOUTY | demosnout's low-poly head (74 vertices, 93 faces, 8 materials), one midpoint subdivision | flat | dithered gradient + starfield |
| IRIS | the Antithesis Iris mark in 3D: two extruded ring arcs and a diamond | flat | copper bars (cool palette) |

### Transform (6DoF)

The cart's hand input `Hand { x, y in -1..1, z 0 (far) .. 1 (near),
pitch, roll, yaw, swirl, velocities, weight }` is followed by the mesh
through critically damped springs (60 Hz, smooth between 30 Hz sensor
frames and across source switches): screen position from x/y (the mesh
moves about 60 % of the way to the hand, so the hand leads it, which
gives the reach effect a direction), distance from z (closer hand,
closer mesh), pitch and roll from the hand's tilt (x1.5), yaw from the
hand's yaw (x confidence) on top of a slow autonomous spin.

### Deformations (the weird part; four, made to read at 160x128)

1. **REACH**: vertices bulge along their normal toward the hand point,
   `amp * max(0, n . h)^6`, amp growing with proximity squared: the mesh
   grows a soft spike that points wherever your hand is and stretches as
   you come closer.
2. **JELLY**: a 2D spring-damper (low damping) driven by the mesh's
   lateral acceleration shears it (top against bottom), and a scalar spring
   driven by z acceleration squashes and stretches it (volume roughly
   kept). Whip the hand and it wobbles for a second.
3. **TWIST**: a torsional spring driven by the hand's yaw velocity and
   swirl rotates each vertex about the mesh's axis by `twist * height`.
   Circle your hand and the knot wrings itself.
4. **SHOCKWAVE**: a punch (z velocity past `punch_mm_s` toward the
   sensor, or A) launches a ripple from the point facing the hand that
   runs over the surface (by angular distance) and decays in ~1 s, with
   a squash kick, a palette flash, a backdrop flash and a 3 px screen
   shake. Up to three at once.

### Sources and controls

- **HAND** (sensor present and a hand seen): the pose drives everything;
  a 3x3 mini map bottom-right shows the zones (coverage as brightness).
- **STICK**: the joystick moves the virtual hand (x/y); B + stick: up/down
  pushes/pulls (z), left/right yaws. Tilt leans into stick motion. A
  punches. Stick input takes over at once and hands back 6 s after the
  last input.
- **GHOST** (attract, the default): a scripted Lissajous hand (drift,
  approach, circle, punch) rendered into synthetic sensor frames by
  tof_synth and run through the real estimator; its mini map is shown too.
- Start: next mesh. Select: sound on/off (boots off unless `-Dsound=true`,
  a toast says which). Nothing reacts while Start and Select are both held
  (the OS chord). Joystick click is never bound.
- The source is shown bottom-left (HAND / STICK / GHOST), the mesh name as
  a toast on change; a greetings scroller runs along the bottom in GHOST.

### Sound (optional, off at boot)

A drone through `lib/tone_stream.zig` (badge) or the simulator's `tone`
import (wasm): pitch from z (closer = higher, 55..220 Hz), level from the
deformation energy; a punch is a short low square thump. Never `cart.tone2`
on badge builds.

## 4. Rendering

- Backdrop first, full frame (`.no_copy_full_frame`): copper bars are one
  column built and copied 160 times (column-major framebuffer), stars are
  points, plasma is 80x64 indices upscaled 2x through a palette.
- Mesh per frame, all f32 then integer: deform in object space (REACH and
  SHOCKWAVE along base normals, then TWIST), rotate and translate into
  view space, JELLY in view space, project (28.4 fixed point). Face
  normals from the deformed view-space positions (cross products),
  accumulated into vertex normals (Gouraud meshes) and normalised; light
  = ambient + diffuse + a sharp specular `(n . h)^16` + rim, quantised to
  a 64-entry ramp per material (dark, base colour, white highlight), plus
  the flash offset.
- Back-face cull on the integer screen winding, painter's order by a
  256-bucket sort on mean view depth (O(faces), no z buffer), column fill
  with 16.16 edge stepping as demosnout's head; Gouraud interpolates the
  ramp index with a per-triangle constant gradient (one add per pixel) and
  a 4x4 ordered dither on its fraction.

## 5. Budget

60 fps, worst frame under 12 ms calibrated busy in badge-bench (72 % of
16.7 ms, demosnout's rule). Estimate for the 1280-face blob: vertices
~0.8 ms, normals ~0.6 ms, ~600 visible faces ~1.5 ms setup + ~15 k pixels
~1 ms, backdrop 0.5..1.2 ms, pose 0.05 ms: ~5 ms. Knobs in
`cart/src/config.zig` (tube segments and sides, sphere level, dither,
plasma on/off, ripple count). RAM: all four meshes generated at start
(~60 KB) plus ~40 KB of per-frame vertex buffers.

## 6. Risks

- The 3x3 pose is coarse; the cart must look good with the confidences
  it actually gets. Mitigation: per-DoF confidence scaling, springs, and
  deformations driven by what is robust (z, z velocity, coverage centroid,
  swirl) rather than by yaw.
- Confidence semantics of the real device are unknown until a badge
  capture: the no-histogram coverage estimate may need retuning (all
  thresholds live in `tof_pose.Config`).
- Painter's order glitches where a deformed mesh self-intersects; small
  triangles keep it subtle.
- Sensor frames reach the cart through a single integration point,
  `sensor.sensor_frame() ?Frame` (null until the lead wires lib/tof.zig);
  the driver and this cart must share one module for lib/tof_types.zig.
