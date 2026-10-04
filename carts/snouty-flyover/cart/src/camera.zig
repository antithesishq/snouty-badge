//! Flight model (SPEC.md 5.5, PLAN.md "Camera constants"): stick steering
//! with roll shear, bank-to-turn yaw, pitch, the altitude spring, boost.
//! All Q16 integer.
//!
//! Conventions shared with render.zig: yaw 0 flies along +y, positive yaw
//! turns toward +x (screen right), so the forward vector is
//! (sin yaw, cos yaw). Banking right lifts the right side of the horizon,
//! which is a negative `roll`.
const fixed = @import("fixed.zig");
const world = @import("world.zig");
const input = @import("input.zig");
const render = @import("render.zig");

// --- Flight constants -------------------------------------------------------

/// Cruise speed, 0.75 cells per frame.
const cruise: i32 = 3 * fixed.one / 4;
/// Speed while A is held, 1.875 cells per frame (2.5x cruise, PLAN.md M3 "Boost").
const boost: i32 = 15 * fixed.one / 8;
/// Speed eases toward its target by 1/2^speed_ease_shift of the gap per frame.
const speed_ease_shift = 3;
/// Start altitude above the terrain under the camera, cells.
const start_above = 48;
/// Clearance kept above the highest terrain ahead, cells.
const clear_above = 12;
/// Rows ahead of the camera scanned for it: ahead_base + ahead_per_speed *
/// speed / cruise (40 at cruise, 64 at boost: about 53 and 34 frames of
/// warning). Bounded by the rows the ring holds.
const ahead_base = 24;
const ahead_per_speed = 16;
/// Cells across the flight line scanned for it.
const ahead_width = 32;
/// Altitude spring: moves 1/2^spring_shift of the gap per frame (1/16), or
/// 1/2^spring_fast_shift (1/4) while the target is more than spring_fast_gap
/// cells above the camera (a wall ahead; descents keep the gentle rate).
const spring_shift = 4;
const spring_fast_shift = 2;
const spring_fast_gap = 16;
/// Hard floor above the terrain directly under the camera, cells.
const min_above = 4;
/// Pilot altitude limits (pitch moves the cruise altitude between them),
/// absolute cells; alt_high clears the Tree's floor + 185 = 205.
const alt_low = 12;
const alt_high = 208;
/// Cruise altitude change per frame at full pitch (24 rows), Q16 cells.
const climb_max: i32 = fixed.one / 2;
/// Largest roll, 20 rows of shear across the screen.
const roll_max: i32 = 20 * fixed.one;
/// Roll eases toward the stick over about this many frames (1/12 of the gap per frame).
const roll_ease = 12;
/// Yaw gained per frame per row of roll: 1 unit per 4 rows (Q16 units of 1/1024 turn).
const yaw_per_roll_div = 4;
/// Yaw cap either side of straight ahead, 1/16 turn.
const yaw_cap: i32 = 64;
/// With the stick centred the heading drifts back to straight ahead at this rate (units per frame).
const yaw_return: i32 = 1;
/// Level horizon row and the pitch range either side of it (rows).
const horizon_level = 64;
const pitch_range = 24;
/// Horizon eases toward the pitch target by 1/2^pitch_ease_shift of the gap per frame.
const pitch_ease_shift = 3;
/// Boost look (PLAN.md M3): the horizon drops this many rows while A is
/// held (eased like pitch, not counted as climb), and render.fog_pull
/// eases toward boost_fog_pull steps at boost_fog_in per frame and back
/// to 0 at boost_fog_out per frame (at most 32, render's table padding).
const boost_drop = 8;
const boost_fog_pull: u8 = 24;
const boost_fog_in: u8 = 2;
const boost_fog_out: u8 = 1;

// --- State ------------------------------------------------------------------

pub const Cam = struct {
    /// Position in Q16 cells; x wraps at world.W. y only increases and is
    /// i64 so it never wraps (an i32 Q16 y overflowed at row 32768, about
    /// 25 minutes of cruise or 128 Select skips); every row derived from it
    /// is an i32 (cam_row()), which lasts thousands of hours.
    x: i32 = 128 * fixed.one,
    y: i64 = 0,
    alt: i32 = 56 * fixed.one,
    /// 1/1024 turn, 0 = +y, positive toward +x.
    yaw: i32 = 0,
    /// Screen row of the horizon; 64 is level.
    horizon: i32 = 64,
    /// Q16 rows of horizon shear across the screen (positive = right side lower).
    roll: i32 = 0,
};

pub var cam: Cam = .{};

/// The world row under the camera (the integral part of cam.y). Every
/// consumer of the camera's row goes through this.
pub fn cam_row() i32 {
    return @intCast(cam.y >> fixed.Q);
}

/// Rows ahead of the camera where ground of height `h` (cells) shows on
/// screen row `sy` at the screen centre (the march's projection: row =
/// horizon + (alt - h) * view_scale / z, view_scale 32; roll ignored), at
/// least `near` and inside the ring window. A verb places its effect with
/// this so it lands in view whatever the altitude and pitch: the bottom of
/// the view is 20 rows ahead at the autopilot's Bus altitude and 40 rows at
/// a manual 72, and the anteater covers the centre of rows 66..118.
pub fn rows_ahead(sy: i32, h: i32, near: i32) i32 {
    const below = @max(sy - cam.horizon, 1);
    const above = @max((cam.alt >> fixed.Q) - h, 1);
    return @min(@max(@divTrunc(above * 32, below), near), world.gen_ahead - 1);
}

/// What the flight model flies with, from the player or the autopilot:
/// steer and pitch in Q16 (-1..1), boost = A held, verb = B pressed (edge).
pub const Stick = struct { steer: i32 = 0, pitch: i32 = 0, boost: bool = false, verb: world.Verb = .none };

/// Autopilot on (the default at boot); Start toggles, stick/A/B input takes over.
pub var autopilot: bool = true;
/// Frames without input before the autopilot resumes (15 s).
pub const idle_frames = 450;
var idle: u32 = 0;

// --- Autopilot knobs (PLAN.md M1 "Autopilot") -------------------------------

/// Flight line on a Bus, cells (the deck centre).
const ap_centre: i32 = 128;
/// Serpentine in a district: centre + ap_swing * sin(frame * ap_turn_rate),
/// sin in 1/1024 turns; rate 2 = one full turn per 512 frames.
const ap_swing: i32 = 16;
const ap_turn_rate: i32 = 2;
/// P controller: full stick at ap_gain_cells of predicted error, where the
/// prediction adds ap_lead frames of the current x drift (speed * sin yaw).
const ap_gain_cells: i32 = 12;
const ap_lead: i32 = 40;
/// Stick clamp, Q16 (1/3: roll at most 1/3 of roll_max, about 6 rows).
const ap_steer_max: i32 = fixed.one / 3;
/// Cruise altitude slew toward floor + the live district's alt_at, Q16
/// cells per frame (1; the Stack dive needs about 0.5).
const ap_climb: i32 = fixed.one;
/// Districts flown on an altitude track (the Stack dive, SPEC 5.5): the
/// autopilot flies the centre line there (no serpentine) and its clearance
/// scan narrows to ap_track_width cells around the flight line, so the
/// canyon walls beside the camera do not hold it up over the floor.
const ap_track_width = 8;
fn on_track(kind: world.Kind) bool {
    return kind == .stack;
}

/// Look-down in the districts read from altitude (alt >= ap_look_alt): the
/// stick pitch the autopilot holds there, Q16 (-1/2: horizon row 52, as in
/// docs/concept/sort.png). Autopilot pitch only tilts the view; it drives
/// cruise_alt itself.
const ap_look_alt: i32 = 80;
const ap_look_pitch: i32 = -fixed.one / 2;

/// A district's `verb_at` meaning "the autopilot never presses B". Any other
/// value, negative included, is the local row whose crossing presses B; a
/// negative row lies on the Bus before the district (the live district
/// there), so the verb can start before the camera arrives. The Bus's own
/// -1 is harmless: a Bus is never the live district.
pub const no_verb: i32 = -32768;

/// Index of the last segment the autopilot pressed B in, and the camera row
/// seen by the previous pilot() call (for the verb_at crossing).
var verb_index: u32 = 0xFFFF_FFFF;
var prev_row: i32 = 0;

/// Merge the player's buttons (input.zig, already updated this frame) with
/// the autopilot: Start (edge) toggles, any stick/A/B input switches to manual
/// and resets the idle counter, idle_frames without input returns to autopilot.
pub fn pilot(frame: u32) Stick {
    if (input.pressed(.start)) {
        autopilot = !autopilot;
        idle = 0;
    }
    const manual: Stick = .{
        .steer = (@as(i32, @intFromBool(input.held(.right))) - @intFromBool(input.held(.left))) * fixed.one,
        .pitch = (@as(i32, @intFromBool(input.held(.down))) - @intFromBool(input.held(.up))) * fixed.one,
        .boost = input.held(.a),
        .verb = if (input.pressed(.b)) world.Verb.player else .none,
    };
    const any = manual.steer != 0 or manual.pitch != 0 or manual.boost or input.held(.b);
    if (any) {
        autopilot = false;
        idle = 0;
    } else if (!autopilot) {
        idle += 1;
        if (idle >= idle_frames) autopilot = true;
    }
    const row = cam_row();
    defer prev_row = row;
    if (!autopilot) return manual;
    return auto_stick(frame, row);
}

/// The autopilot's stick: serpentine steering and the once-per-segment B.
fn auto_stick(frame: u32, row: i32) Stick {
    const under = world.segment_at(row);
    const swing = under.kind != .bus and !on_track(under.kind);
    const target = ap_centre * fixed.one +
        if (swing) ap_swing * sin(@as(i32, @intCast(frame & 1023)) * ap_turn_rate) else 0;
    // Error across the wrapping strip, in (-W/2, W/2] cells.
    const span = world.W * fixed.one;
    const err = @mod(target - cam.x + span / 2, span) - span / 2;
    const drift = fixed.mul(speed, sin(cam.yaw)); // Q16 cells per frame
    const want = @divTrunc(err - ap_lead * drift, ap_gain_cells);
    const steer = @max(-ap_steer_max, @min(ap_steer_max, want));

    const live = world.live();
    const at = world.info(live.kind).verb_at;
    var verb: world.Verb = .none;
    if (at != no_verb and live.index != verb_index) {
        const trigger = live.y0 + at;
        if (prev_row < trigger and row >= trigger) {
            verb = .pilot;
            verb_index = live.index;
        }
    }
    const pitch = if (world.info(under.kind).alt >= ap_look_alt) ap_look_pitch else 0;
    return .{ .steer = steer, .pitch = pitch, .verb = verb };
}

/// Q16 accumulators behind the integer fields of `cam`.
var yaw_q: i32 = 0;
var horizon_q: i32 = horizon_level * fixed.one;
/// The boost part of horizon_q, Q16 rows (0..boost_drop).
var drop_q: i32 = 0;
var speed: i32 = cruise;
/// Altitude the pilot asks for (pitch moves it); the spring target is the
/// higher of this and the terrain clearance.
var cruise_alt: i32 = 0;

/// Place the camera at the start altitude; call after world.advance_to at start().
pub fn init() void {
    cam = .{};
    yaw_q = 0;
    horizon_q = horizon_level * fixed.one;
    drop_q = 0;
    render.fog_pull = 0;
    speed = cruise;
    cam.alt = (@as(i32, ground(cam.x, cam_row())) + start_above) * fixed.one;
    cruise_alt = cam.alt;
    autopilot = true;
    idle = 0;
    verb_index = 0xFFFF_FFFF;
    prev_row = 0;
}

/// Select skip (PLAN.md M3): put the camera on `row` (x and altitude kept),
/// heading straight ahead with the wings level, and rearm the autopilot's
/// once-per-segment B so the next district's verb still fires. The
/// autopilot flag is left as it is.
pub fn jump_to(row: i32) void {
    cam.y = @as(i64, row) << fixed.Q;
    cam.yaw = 0;
    cam.roll = 0;
    yaw_q = 0;
    verb_index = 0xFFFF_FFFF;
    prev_row = row;
}

/// Terrain height of the cell under the camera (for the debug exports).
pub fn ground_under() u8 {
    return ground(cam.x, cam_row());
}

pub fn update(stick: Stick, frame: u32) void {
    _ = frame;
    const steer = stick.steer; // Q16, -1..1
    const pitch = stick.pitch;

    // Speed: boost while A is held.
    const want_speed = if (stick.boost) boost else cruise;
    speed += (want_speed - speed) >> speed_ease_shift;
    if (@abs(want_speed - speed) < 64) speed = want_speed;

    // Roll eases toward the stick; banking right lifts the right side (negative roll).
    const want_roll = -fixed.mul(steer, roll_max);
    const droll = @divTrunc(want_roll - cam.roll, roll_ease);
    cam.roll = if (droll == 0) want_roll else cam.roll + droll;

    // Bank to turn, capped; heading recentres when the stick is released.
    yaw_q -= @divTrunc(cam.roll, yaw_per_roll_div);
    if (steer == 0) {
        const r = yaw_return * fixed.one;
        if (yaw_q > r) yaw_q -= r else if (yaw_q < -r) yaw_q += r else yaw_q = 0;
    }
    yaw_q = @max(-yaw_cap * fixed.one, @min(yaw_cap * fixed.one, yaw_q));
    cam.yaw = yaw_q >> fixed.Q;

    // Move: forward is (sin yaw, cos yaw); x wraps across the strip.
    cam.x = (cam.x + fixed.mul(speed, sin(cam.yaw))) & (world.W * fixed.one - 1);
    cam.y += fixed.mul(speed, cos(cam.yaw));

    // Boost look: the fog pulls in and the horizon drops while A is held.
    const pull = render.fog_pull;
    render.fog_pull = if (stick.boost) @min(boost_fog_pull, pull + boost_fog_in) else pull -| boost_fog_out;
    const want_drop: i32 = if (stick.boost) boost_drop * fixed.one else 0;
    drop_q += (want_drop - drop_q) >> pitch_ease_shift;
    if (@abs(want_drop - drop_q) < 256) drop_q = want_drop;

    // Pitch: up dives (horizon rises), down climbs (horizon falls).
    const want_h = horizon_level * fixed.one + pitch * pitch_range + want_drop;
    horizon_q += (want_h - horizon_q) >> pitch_ease_shift;
    if (@abs(want_h - horizon_q) < 256) horizon_q = want_h;
    cam.horizon = (horizon_q + fixed.one / 2) >> fixed.Q;
    const tilt = horizon_q - drop_q - horizon_level * fixed.one; // Q16 rows, +-24
    if (autopilot) {
        // Hold floor + the live district's cruise altitude.
        const live_seg = world.live();
        const want_alt = (@as(i32, world.floor) + world.info(live_seg.kind).alt_at(cam_row() - live_seg.y0)) * fixed.one;
        cruise_alt += @max(-ap_climb, @min(ap_climb, want_alt - cruise_alt));
    } else {
        cruise_alt += @divTrunc(fixed.mul(tilt, climb_max), pitch_range);
    }
    cruise_alt = @max(alt_low * fixed.one, @min(alt_high * fixed.one, cruise_alt));

    // Altitude spring toward max(cruise, terrain ahead + clearance), then the hard floor.
    const width: i32 = if (autopilot and on_track(world.live().kind)) ap_track_width else ahead_width;
    const rows = ahead_base + @divTrunc(ahead_per_speed * speed, cruise);
    const target = @max(cruise_alt, (@as(i32, ahead_max(rows, width)) + clear_above) * fixed.one);
    const gap = target - cam.alt;
    cam.alt += gap >> if (gap > spring_fast_gap * fixed.one) spring_fast_shift else spring_shift;
    const floor = (@as(i32, ground(cam.x, cam_row())) + min_above) * fixed.one;
    cam.alt = @max(cam.alt, floor);
}

/// Terrain height under Q16 x on world row `row` (0 if the row is not in the ring).
fn ground(x: i32, row: i32) u8 {
    if (!world.generated_row(row)) return 0;
    const col: usize = @intCast((x >> fixed.Q) & (world.W - 1));
    return world.height[@intCast(row & (world.DEPTH - 1))][col];
}

/// Highest cell in the `rows` rows from the camera row, across `width`
/// cells centred on the flight line (which leans with the yaw). Only rows in
/// the ring are read (the scan stops at the first one it does not hold).
fn ahead_max(rows: i32, width: i32) u8 {
    const row0 = cam_row();
    const lean = sin(cam.yaw); // Q16 x cells per row
    var best: u8 = 0;
    var i: i32 = 0;
    while (i < rows) : (i += 1) {
        const row = row0 + i;
        if (!world.generated_row(row)) break;
        const line = &world.height[@intCast(row & (world.DEPTH - 1))];
        const centre = (cam.x + lean * i) >> fixed.Q;
        var c = centre - @divTrunc(width, 2);
        while (c < centre + @divTrunc(width, 2)) : (c += 1) {
            best = @max(best, line[@intCast(c & (world.W - 1))]);
        }
    }
    return best;
}

// --- Sine -------------------------------------------------------------------

/// sin over a quarter turn in 16 steps, Q16 (round(65536 * sin(i * pi / 32))).
const quarter = [17]i32{ 0, 6424, 12785, 19024, 25080, 30893, 36410, 41576, 46341, 50660, 54491, 57798, 60547, 62714, 64277, 65220, 65536 };

/// Q16 sine of an angle in 1/1024 turns, linear between 16-unit table steps
/// (error under 0.2%). Private to the flight model; render.zig keeps its own table.
pub fn sin(a: i32) i32 {
    const t = a & 1023;
    const q = t & 255; // position inside the quadrant
    const p = if (t & 256 != 0) 256 - q else q; // mirror the 2nd and 4th quadrants
    const i: usize = @intCast(p >> 4);
    const f = p & 15;
    const v = if (i == 16) quarter[16] else quarter[i] + (((quarter[i + 1] - quarter[i]) * f) >> 4);
    return if (t & 512 != 0) -v else v;
}

/// Q16 cosine of an angle in 1/1024 turns.
pub fn cos(a: i32) i32 {
    return sin(a + 256);
}
