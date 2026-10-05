//! Forked from snouty-zero/cart/src/tuning.zig at f8f6962.
//! Every tunable constant in one place (SPEC 4.2, 5). Zero's hover values
//! are retuned for wheels (SPEC 5.2); thermal, Overclock, traffic and the
//! rewind are gone. Adrian's play test sets the numbers.

// --- Screen and camera (Zero SPEC 6.1, 6.2) ----------------------------------

/// Horizon row: the strip covers rows 0..horizon_y, the floor rows below.
pub const horizon_y: i32 = 32;
/// Camera height over the floor in world pixels.
pub const cam_height: i32 = 64;
/// Focal length in screen pixels: half FOV = atan(80 / focal).
pub const focal: i32 = 128;
/// Distance of the camera behind the followed car, world px: with
/// cam_height 64 and focal 128 the car sits at row 32 + 64*128/95 = 118.
pub const cam_behind: i32 = 95;
/// Fog bank thresholds on the row distance z (world px): bank 1, 2, 3.
pub const fog_z = [3]i32{ 160, 320, 640 };
/// Camera yaw lag: 1/8 of the heading difference per tick.
pub const cam_lag_shift: u5 = 3;

// --- Driving model (SPEC 5.1, 5.2), Q16.16 unless noted ------------------------

/// Thrust, always on while racing (auto-throttle), px/tick^2 (0.036).
pub const accel: i32 = 2359;
/// Drag: v *= (1 - drag) per tick; 0.012 -> terminal speed accel / drag = 3.0 px/tick.
/// A chassis' accel multiplier scales the drag as well (sim.chassis_keep),
/// so it changes how fast the car reaches its top speed, not the top speed.
pub const drag: i32 = 786;
/// Top speed for a WORKSTATION, Q16 (accel / drag = 3.0 px/tick).
pub const top_speed: i32 = 196608;
/// Brake: v -= v * brake per tick (0.04). With the throttle on, holding the
/// brake settles near accel / (drag + brake) = 0.69 px/tick.
pub const brake: i32 = 2621;
/// Lateral velocity kept per tick (SPEC 5.2): normal, powerslide, coolant.
pub const grip: i32 = 45875; // 0.70
pub const grip_slide: i32 = 57672; // 0.88
pub const grip_coolant: i32 = 63570; // 0.97
/// Yaw per tick at low speed, turn units; a powerslide multiplies by 1.6.
pub const steer_rate: i32 = 300;
pub const steer_slide_num: i32 = 8;
pub const steer_slide_den: i32 = 5;
/// Steering falls from 100% below 40% of top speed to 55% at top speed.
pub const steer_full_below: i32 = top_speed * 2 / 5;
pub const steer_min_pct: i32 = 55;
/// BURST (Up, SPEC 5.1): thrust x1.35 for burst_ticks (+35% top speed,
/// about 4.0 px/tick), one charge per lap (garage BURST BUFFER L0).
pub const burst_thrust_q8: i32 = 346;
pub const burst_ticks: u8 = 60;
pub const burst_per_lap: u8 = 1;
/// Car footprint half extents (world px): along heading, lateral.
pub const half_len: i32 = 12;
pub const half_wid: i32 = 6;
/// Wall: normal velocity reflected with this restitution (1/256), speed loss.
pub const wall_restitution: i32 = 77; // 0.3
pub const wall_speed_keep: i32 = 58982; // 0.9
/// Ramp: airborne ticks (projectiles pass under from M1).
pub const ramp_ticks: u8 = 40;
/// Wreck (a fall into a pit in M0; armor at 0 from M1): the car is out for
/// the WATCHDOG delay (SPEC 5.3, garage L0), then respawns on the
/// centerline with this much immunity.
pub const watchdog_ticks: u8 = 120;
pub const respawn_immune: u8 = 60;
/// A car further than its sample's half width + this from the centerline
/// is off its leg (pushed through a wall): a fall, and the WATCHDOG
/// brings it back.
pub const off_leg_px: i32 = 32;
/// Per-car message display, ticks.
pub const message_ticks: u8 = 45;
/// Countdown: four steps of this many ticks.
pub const countdown_step: u16 = 50;
pub const laps: u8 = 3;
/// Height of the car body over its shadow, world px.
pub const ride_height: i32 = 1;

// --- Chassis (SPEC 4.2): multipliers in 1/256 of the base values --------------

pub const Chassis = struct {
    top_q8: u16,
    accel_q8: u16,
    grip_q8: u16,
    /// Base armor (M1 wires damage).
    armor: u8,
    /// Ram mass: the contact response weights the velocity exchange by it.
    mass_q8: u16,
};
pub const thin_client = Chassis{ .top_q8 = 276, .accel_q8 = 307, .grip_q8 = 243, .armor = 80, .mass_q8 = 179 };
pub const workstation = Chassis{ .top_q8 = 256, .accel_q8 = 256, .grip_q8 = 256, .armor = 100, .mass_q8 = 256 };
pub const mainframe = Chassis{ .top_q8 = 230, .accel_q8 = 205, .grip_q8 = 269, .armor = 140, .mass_q8 = 410 };

// --- Field: contacts, rank, grid, AI (Zero SPEC 5.3) --------------------------

/// Car circle radius for car-against-car contact, world px (SPEC 6).
pub const car_radius: i32 = 10;
/// Share of the relative normal velocity exchanged on contact (0.3, 1/256),
/// split by mass.
pub const collision_exchange: i32 = 77;
/// Shake ticks after a contact closing faster than this (Q16 px/tick).
pub const collision_shake_speed: i32 = 1 << 15;
/// Rubber band (Zero SPEC 5.3), keyed on the leading human: target scale
/// 1 + clamp(gap / 1500, -8%, +10%), in 1/1000.
pub const rubber_px: i32 = 1500;
pub const rubber_min_permille: i32 = -80;
pub const rubber_max_permille: i32 = 100;
/// Grid: rows behind the start line, px; first row distance; column offset.
pub const grid_first_row: i32 = 20;
pub const grid_row_gap: i32 = 30;
pub const grid_side: i32 = 18;
/// AI passing (ai.avoid): look this far ahead (px) within this lateral
/// band for a slower car; pass it this far to its side, keeping this
/// margin from the edge; ease off to its speed when this close behind.
pub const avoid_ahead: i32 = 64;
pub const avoid_width: i32 = 22;
pub const avoid_pass: i32 = 26;
pub const avoid_margin: i32 = 16;
pub const avoid_brake: i32 = 30;
pub const avoid_brake_width: i32 = 14;

// --- Combat: armor, ramming, wrecks (SPEC 5.3) -------------------------------
// Balance errs on the dangerous side (SPEC 17.12): a careless player can be
// wrecked by about six PING bursts or two LOGIC BOMBs and a wall.

/// Kill credit: a wreck within this many ticks of the last hit by a rival
/// counts as that rival's kill (a fall too); later, it is uncredited.
pub const credit_ticks: u8 = 180;
/// Hit flash on the armor bar / sprite, ticks. A hit event is logged for
/// every hit of at least `hit_event_min` damage, and for smaller ones (a
/// FIREWALL's 1 per tick) only when no flash is running, so damage over
/// time does not flood the 16-slot ring.
pub const hit_flash_ticks: u8 = 8;
pub const hit_event_min: u8 = 2;
/// Per-car hit-stop of a wrecked car (the world never stops, M1.0).
pub const hitstop_ticks: u8 = 12;
/// A wrecked car is a burning hulk that blocks like a wall for the first
/// `hulk_ticks` of its WATCHDOG delay, then vanishes until the respawn.
pub const hulk_ticks: u8 = 90;
/// Explosion radius reported for a wrecked car (render-side size).
pub const wreck_blast_px: u8 = 24;
/// Ramming (SPEC 5.3): damage = closing normal speed (px/tick) x ram_dmg x
/// attacker mass / victim mass; contacts closing slower than
/// `ram_min_speed` (pack grinding) deal nothing. MAINFRAME's plough doubles
/// it when the victim is in its front quarter (within +-45 degrees of the
/// heading: cos 45 = 0.7071 in Q16).
pub const ram_dmg: i32 = 6;
pub const ram_min_speed: i32 = 1 << 14; // 0.25 px/tick
pub const plough_cos: i32 = 46341;
pub const plough_mul: i32 = 2;
/// Walls (SPEC 3.3): damage scaled by impact, `wall_dmg` per px/tick of
/// normal speed above `wall_dmg_min` (a 3 px/tick head-on costs 8). Hulks
/// are walls.
pub const wall_dmg: i32 = 4;
pub const wall_dmg_min: i32 = 1 << 16;

// --- Front weapons (SPEC 6.1), indexed by world.Front -----------------------

/// Ammo per lap (refilled on the start line) by Front: ping, broadcast,
/// lance, phish; and by Rear: leak, bomb, rot, firewall (SPEC 6.1, 6.2).
pub const front_ammo = [4]u8{ 40, 10, 6, 3 };
pub const rear_ammo = [4]u8{ 3, 3, 4, 2 };
/// Shot collision radius against the car circle, world px.
pub const shot_radius: i32 = 2;
/// PING: twin pellets `ping_gap` px apart every `ping_cd` ticks while A is
/// held, +5 px/tick muzzle speed, 160 px range (relative to the shooter).
pub const ping_cd: u8 = 6;
pub const ping_speed: i32 = 5 << 16;
pub const ping_ttl: u8 = 160 / 5;
pub const ping_gap: i32 = 3;
pub const ping_dmg: u8 = 4;
/// BROADCAST: 5 pellets fanned over +-20 degrees (10 degrees = 1820 turns
/// apart), 80 px range; each pellet knocks the victim 0.4 px/tick sideways.
pub const broadcast_cd: u8 = 24;
pub const broadcast_speed: i32 = 5 << 16;
pub const broadcast_ttl: u8 = 80 / 5;
pub const broadcast_pellets: u8 = 5;
pub const broadcast_step: i32 = 1820;
pub const broadcast_dmg: u8 = 3;
pub const broadcast_knock: i32 = 26214;
/// FIBER LANCE: hold A `lance_charge` ticks, release to fire a hitscan
/// beam along the heading: 300 px, the first car in a 4-degree line
/// (half width car radius + along x tan 2 degrees = along x 9 / 256); an
/// early release fizzles at no ammo cost. Walls stop the beam (sampled
/// every `lance_step` px).
pub const lance_charge: u8 = 30;
pub const lance_range: i32 = 300;
pub const lance_spread_q8: i32 = 9;
pub const lance_step: i32 = 6;
pub const lance_dmg: u8 = 25;
pub const lance_cd: u8 = 20;
/// SPEAR PHISH: the lock is the nearest car in a 24-degree cone (half
/// width along x tan 12 degrees = along x 54 / 256) within 400 px; A fires
/// a missile at the car's speed + 3 px/tick that homes at 600 turns/tick
/// for 180 ticks; with no lock it flies straight.
pub const phish_spread_q8: i32 = 54;
pub const phish_range: i32 = 400;
pub const phish_speed: i32 = 3 << 16;
pub const phish_turn: i32 = 600;
pub const phish_ttl: u8 = 180;
pub const phish_dmg: u8 = 30;
pub const phish_cd: u8 = 40;

// --- Rear weapons (SPEC 6.2), Down + A on the press edge ---------------------

/// Ticks between two rear drops (Down+A press edges).
pub const rear_cd: u8 = 30;
/// Drops land this far behind the car's centre, px.
pub const drop_behind: i32 = half_len + 6;
/// A drop ignores its owner while younger than this (it is laid behind a
/// car driving away); after that it hits anyone, owner included.
pub const drop_owner_grace: u16 = 60;
/// MEMORY LEAK: a puddle growing from radius 6 to 18 px over 180 ticks,
/// gone at tick 600; a car whose centre is on it gets coolant grip and a
/// yaw kick of up to `leak_yaw` turns a tick from the world PRNG.
pub const leak_r0: i32 = 6;
pub const leak_r1: i32 = 18;
pub const leak_grow: u16 = 180;
pub const leak_life: u16 = 600;
pub const leak_yaw: u32 = 700;
/// LOGIC BOMB: arms after 30 ticks, triggers when a car centre comes within
/// 14 px, 35 damage to every car within the 24 px blast and a push of
/// 1.5 px/tick away from it. Unexploded bombs clear after 30 s.
pub const bomb_arm: u16 = 30;
pub const bomb_trigger: i32 = 14;
pub const bomb_blast: i32 = 24;
pub const bomb_dmg: u8 = 35;
pub const bomb_push: i32 = 98304;
pub const bomb_life: u16 = 1800;
/// BIT ROT: `rot_count` caltrops `rot_gap` px apart across the lane (48 px
/// with their radius); each hit deals 5 and takes 20% off the top speed for
/// 60 ticks, and is consumed. Untouched caltrops clear after 20 s.
pub const rot_count: u8 = 6;
pub const rot_gap: i32 = 8;
pub const rot_hit: i32 = car_radius + 2;
pub const rot_dmg: u8 = 5;
pub const rot_ticks: u8 = 60;
pub const rot_top_q8: i32 = 205;
pub const rot_life: u16 = 1200;
/// FIREWALL: a flame strip 64 px across the heading (half 32) and
/// 2 x `firewall_depth` px deep behind the car for 120 ticks; 1 damage per
/// tick to a car whose centre is inside (within the half width + 4).
pub const firewall_half: u8 = 32;
pub const firewall_depth: i32 = 12;
pub const firewall_life: u16 = 120;
pub const firewall_dmg: u8 = 1;

// --- AI combat (SPEC 6.5) ------------------------------------------------------

/// Drop the rear weapon when a car is within this far behind and within
/// `ai_drop_lat` px of the line (a `drop_wide` crew: `ai_drop_wide_lat`).
pub const ai_drop_behind: i32 = 120;
pub const ai_drop_lat: i32 = 16;
pub const ai_drop_wide_lat: i32 = 40;
/// A `drop_corners` crew (SNOUTY's mines) also drops into a corner whose
/// heading change over the next 8 samples exceeds this, with any car
/// within `ai_drop_behind`.
pub const ai_drop_corner: i32 = 9000;
/// A LANCE crew starts charging only when the curvature over the burst
/// window ahead is under this.
pub const ai_lance_straight: i32 = 8000;
/// Firewall avoidance: look this far ahead, pass this far outside its end
/// (the car's half width + 2), keeping this far from the road's edge.
pub const ai_firewall_ahead: i32 = 140;
pub const ai_firewall_pass: i32 = 8;
pub const ai_firewall_margin: i32 = 8;
/// A `rammer` (LEGACY) steers into a car within this far along and this
/// far beside it.
pub const ai_ram_along: i32 = 24;
pub const ai_ram_lat: i32 = 34;
/// A `stalk` crew (ROOTKIT) sits behind a target ahead within this range.
pub const ai_stalk_range: i32 = 110;

// --- Pickups (SPEC 6.3, 6.4), M2 ---------------------------------------------

/// RMA crate rows (SPEC 3.3): crates `crate_gap` px apart across the track,
/// 4 in a row where the sample's half width is at least `crate_row4_half`,
/// else 3. A car whose centre comes within `crate_touch` px of a crate
/// takes it; it respawns `crate_respawn` ticks later.
pub const crate_gap: i32 = 20;
pub const crate_row4_half: u8 = 56;
pub const crate_touch: i32 = car_radius + 6;
pub const crate_respawn: u8 = 180;
/// RUBBER DUCK: bobs this far behind its car on the tether, world px.
pub const duck_behind: i32 = 18;
/// The roulette (`FETCHING...`) runs this long before the pickup is usable.
pub const roll_ticks: u8 = 45;
/// Tier odds A, B, C in percent by rank 1..6 (SPEC 6.4).
pub const roll_odds = [6][3]u8{
    .{ 80, 20, 0 },
    .{ 50, 45, 5 },
    .{ 30, 55, 15 },
    .{ 20, 55, 25 },
    .{ 10, 50, 40 },
    .{ 5, 40, 55 },
};
/// HONEYPOT and SPAGHETTI fly this far ahead when thrown (B); Down+B drops
/// them behind like a rear weapon.
pub const throw_dist: i32 = 60;
/// Pickup drops left untouched clear after 30 s (SPEC silent, as the bombs).
pub const pickup_drop_life: u16 = 1800;
/// PREFETCH: +40% top speed (thrust x1.40) for 90 ticks; wall damage halved.
pub const prefetch_ticks: u8 = 90;
pub const prefetch_q8: i32 = 358;
/// PREFETCH is instant: a kick of 1 px/tick along the heading on use.
pub const prefetch_kick: i32 = 1 << 16;
/// HONEYPOT: touching the fake crate deals 30 and spins the car for 30
/// ticks (no steering, the heading turns about a full circle, speed bleeds).
pub const honeypot_dmg: u8 = 30;
pub const spin_ticks: u8 = 30;
pub const spin_rate: u16 = 2200;
pub const spin_keep: i32 = 60293; // 0.92 a tick
/// RUBBER DUCK on its tether for 600 ticks.
pub const duck_ticks: u16 = 600;
/// HOT PATCH: 40 armor over 60 ticks, `patch_step` every `patch_every`.
pub const patch_ticks: u8 = 60;
pub const patch_every: u8 = 3;
pub const patch_step: u8 = 2;
/// SPAGHETTI CODE: a 24 px tangle (radius 12); a car whose centre comes
/// within the radius + its half width is held to 40% for 60 ticks, then
/// drags a strand for 180 ticks at -10% top speed.
pub const spaghetti_touch: i32 = 12 + half_wid;
pub const tangle_ticks: u8 = 60;
pub const tangle_pct: i32 = 40;
pub const strand_ticks: u8 = 180;
pub const strand_q8: i32 = 230;
/// FORK BOMB: every 60 ticks each `&` forks in two, `fork_gens` times
/// (1, 2, 4, 8); the pair drift apart across the track over `fork_drift`
/// ticks, `fork_spread >> (generation - 1)` px each; 15 a hit on contact
/// (centre within `fork_touch`), gone at age 480.
pub const fork_every: u16 = 60;
pub const fork_gens: u8 = 3;
pub const fork_drift: i32 = 30;
pub const fork_spread: i32 = 24;
pub const fork_touch: i32 = car_radius + 4;
pub const fork_dmg: u8 = 15;
pub const fork_blast: u8 = 8;
pub const fork_life: u16 = 480;
/// BIT FLIP and DEADLOCK reach the nearest car(s) ahead within this much
/// race progress, px.
pub const ahead_range: i32 = 400;
pub const bit_flip_ticks: u8 = 180;
/// DEADLOCK: speed held to 30% for 150 ticks or until the pair touch; the
/// chain pulls them together at 0.08 px/tick^2.
pub const deadlock_ticks: u8 = 150;
pub const deadlock_pct: i32 = 30;
pub const chain_pull: i32 = 5243;
/// DDOS: 8 drones fly at 7 px/tick to the nearest car ahead, then orbit it
/// (radius 16 px, 8/256 of a turn a tick) for 180 ticks: 2 damage a drone
/// every 30, top speed -20%. A shot within its radius + 3 px downs one.
pub const ddos_ticks: u8 = 180;
pub const ddos_every: u8 = 30;
pub const ddos_dmg: u8 = 2;
pub const ddos_q8: i32 = 205;
pub const drone_speed: i32 = 7 << 16;
pub const drone_orbit: i32 = 16;
pub const drone_spin: u8 = 8;
pub const drone_radius: i32 = 3;
/// HEISENBUG: unobservable for 240 ticks.
pub const heisen_ticks: u8 = 240;
/// RACE CONDITION: the next car ahead within 300 px of progress; 6 ticks of
/// tearing, then the swap.
pub const race_range: i32 = 300;
pub const race_ticks: u8 = 6;
/// KERNEL PANIC: the packet runs at twice the top speed and homes once
/// within `panic_home` px; 40 damage and 90 ticks frozen.
pub const panic_speed: i32 = 2 * top_speed;
pub const panic_home: i32 = 64;
pub const panic_dmg: u8 = 40;
pub const panic_freeze: u8 = 90;
/// CAPTCHA: every other car held to 10% until solved; a human's board has
/// `captcha_lights` lit cells of nine and frees after 120 ticks at the
/// latest; the cursor steps a cell every `captcha_step` ticks (a sweep in
/// 45). AIs wait their crew's `captcha_solve` ticks.
pub const captcha_human: u8 = 120;
pub const captcha_lights: u32 = 3;
pub const captcha_step: u8 = 5;
pub const captcha_pct: i32 = 10;
/// SUDO: root for 300 ticks: no damage, +20% top speed, a ram deals 40 and
/// bounces the victim away at 1.5 px/tick.
pub const sudo_ticks: u16 = 300;
pub const sudo_q8: i32 = 307;
pub const sudo_ram: u8 = 40;
pub const sudo_bounce: i32 = 98304;

// --- AI pickups (SPEC 4.3, 6.5 item 3) ---------------------------------------

/// HOT PATCH below this armor percent; RACE CONDITION within this many px
/// of the next car on the last lap; FORK BOMB with a car this far behind;
/// HONEYPOT / SPAGHETTI thrown at a car this far ahead and this close to
/// the line.
pub const ai_patch_pct: u32 = 40;
pub const ai_race_px: i32 = 60;
pub const ai_fork_behind: i32 = 200;
pub const ai_throw_min: i32 = 30;
pub const ai_throw_max: i32 = 140;
pub const ai_throw_lat: i32 = 24;
/// BIT FLIP: of every 32 ticks the AI steers the wrong way for this many.
pub const ai_flip_lag: u8 = 6;

// --- Track hazards, service bays, modes (SPEC 3.3, 8.2, 19.4), M3 ------------
// The hazards' own numbers (period, damage, push, size, speed) are track
// data (tools/build_tracks.py VENT_DEFAULTS, SWEEPER_DEFAULTS: SPEC 3.3's
// 240-tick vent firing 30 ticks for 20 and a shove; the Sweeper's 60 and a
// shove), so a track pack can set its own.

/// A car is in a firing vent's lane when its centre is within the lane's
/// half width plus this (half a car's width).
pub const hazard_reach: i32 = half_wid;
/// Service bay (SPEC 3.3): 1 armor every `bay_every` ticks on a bay tile.
pub const bay_every: u32 = 4;
/// GARBAGE COLLECTION: the marked car may pass the mark on (tag) only
/// after carrying it this long, so two cars side by side cannot bat it
/// back and forth every PING volley.
pub const gc_tag_grace: u16 = 45;
/// Attract: the scripted KERNEL PANIC is handed to the last car when the
/// leader reaches this sample of lap 2.
pub const attract_panic_sample: i32 = 48;
/// AI hazard sense (SPEC 3.3 "AIs avoid an active blast or mover where
/// they can"): look this far ahead along the heading; keep this much
/// clearance (px) from a mover's body and this many ticks from a vent's
/// firing; never plan slower than `ai_hazard_min_q8` of the top speed
/// (it brakes to a stop only right at the lane).
pub const ai_hazard_ahead: i32 = 150;
pub const ai_hazard_clear: i32 = 14;
pub const ai_hazard_margin: u32 = 6;
pub const ai_hazard_min_q8: i32 = 40;
/// Braking distance per px/tick of speed to shed (the brake takes about
/// 4% a tick against the throttle).
pub const ai_hazard_brake_px: i32 = 20;
