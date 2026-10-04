//! New for Snouty GC (M1 Track B): the race's cosmetic effects and the
//! notices the HUD shows, all render-side (SPEC 10: outside the World).
//! Once per race tick `tick` reads the World's event ring from its own
//! cursor (`last_seq`; it never writes the World) and turns `hit`,
//! `wreck`, `lance`, `explode` and `respawn` into particles (explosions,
//! sparks, smoke, muzzle flashes), FIBER LANCE beams, the kill feed, the
//! taunt pop-up, `ACK`s, the armor-bar flash, the wreck message and the
//! render-side shake of the followed car. Smoke from damaged cars and
//! burning hulks and the muzzle flashes (an ammo count going down) come
//! from the cars' state. Everything here depends on the World and `follow`
//! alone, so a link race shows each badge its own car's notices.
const cart = @import("cart-api");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const world = @import("world.zig");
const camera = @import("camera.zig");
const sprites = @import("sprites.zig");
const sim = @import("sim.zig");

const no_car = world.no_car;

// --- Particles (world-anchored, drawn through the sprites depth list) ---------------

pub const PKind = enum(u8) { none, explosion, spark, smoke, black_smoke, muzzle };
pub const Particle = struct {
    kind: PKind = .none,
    /// World position, Q16.16.
    x: i32 = 0,
    y: i32 = 0,
    /// Height over the floor, world px.
    lift: i16 = 0,
    age: u8 = 0,
    /// Diameter, world px.
    size: u8 = 0,
};
pub const particle_count = 48;
pub var particles: [particle_count]Particle = @splat(.{});
var next_particle: usize = 0;

fn life(k: PKind) u8 {
    return switch (k) {
        .none => 0,
        // Four frames of about four ticks (ASSETS.md fx.png 0..3).
        .explosion => 16,
        .spark => 6,
        .smoke, .black_smoke => 24,
        .muzzle => 3,
    };
}

pub fn spawn(kind: PKind, x: i32, y: i32, lift: i16, size: u8) void {
    particles[next_particle] = .{ .kind = kind, .x = x, .y = y, .lift = lift, .size = size };
    next_particle = (next_particle + 1) % particle_count;
}

// --- FIBER LANCE beams --------------------------------------------------------------------

/// SPEC 6.1: the beam is drawn for 6 ticks.
pub const beam_ticks: u8 = 6;
pub const Beam = struct { owner: u8 = no_car, x: i32 = 0, y: i32 = 0, age: u8 = 255 };
pub var beams: [4]Beam = @splat(.{});
var next_beam: usize = 0;

// --- Notices (the HUD draws them) ---------------------------------------------------------

/// SPEC 5.3: the kill feed line shows for 60 ticks.
pub const feed_ticks: u8 = 60;
/// SPEC 10: the taunt pop-up shows for 90 ticks.
pub const popup_ticks: u8 = 90;
pub const ack_ticks: u8 = 30;
/// The followed car's own wreck message (WRECKED BY SYSADMIN, ZERO-DAY).
pub const wreck_note_ticks: u8 = 90;

pub const Feed = struct { ticks: u8 = 0, killer: u8 = no_car, victim: u8 = 0, cause: world.Wreck = .none };
pub var feed: Feed = .{};
/// `wrecked`: the racer's wrecked line (the followed car made the kill),
/// else their taunt (they wrecked the followed car).
pub const Popup = struct { ticks: u8 = 0, racer: u8 = 0, wrecked: bool = false };
pub var popup: Popup = .{};
pub const Ack = struct { car: u8 = 0, ticks: u8 = 0 };
pub var acks: [4]Ack = @splat(.{});
var next_ack: usize = 0;
pub const WreckNote = struct { ticks: u8 = 0, killer: u8 = no_car, cause: world.Wreck = .none };
pub var wreck_note: WreckNote = .{};
/// Ticks the armor bar flashes after a hit on the followed car.
pub var armor_flash: u8 = 0;
/// Render-side shake of the followed car (SPEC 5.3: on the victim's own screen).
pub var shake: u8 = 0;
pub const wreck_shake: u8 = 12;

/// The event cursor: the next seq this badge has not shown.
var last_seq: u16 = 0;
var prev_ammo: [world.car_count]u8 = @splat(0);

/// At race start (and after a restart): forget everything, start the
/// cursor at the World's current seq.
pub fn begin(w: *const world.World) void {
    particles = @splat(.{});
    beams = @splat(.{});
    acks = @splat(.{});
    feed = .{};
    popup = .{};
    wreck_note = .{};
    armor_flash = 0;
    shake = 0;
    last_seq = w.event_seq;
    for (&w.cars, 0..) |*c, i| prev_ammo[i] = c.ammo_front;
}

/// Once per race tick, after `sim.simulate`.
pub fn tick(w: *const world.World, follow: u8, frame: u32) void {
    age_all();
    read_events(w, follow);
    for (&w.cars, 0..) |*c, i| {
        car_effects(c, i, frame);
        prev_ammo[i] = c.ammo_front;
    }
}

fn age_all() void {
    for (&particles) |*p| {
        if (p.kind == .none) continue;
        p.age +|= 1;
        switch (p.kind) {
            .smoke, .black_smoke => {
                if (p.age % 2 == 0) p.lift += 1;
            },
            else => {},
        }
        if (p.age >= life(p.kind)) p.kind = .none;
    }
    for (&beams) |*b| b.age +|= 1;
    for (&acks) |*a| a.ticks -|= 1;
    feed.ticks -|= 1;
    popup.ticks -|= 1;
    wreck_note.ticks -|= 1;
    armor_flash -|= 1;
    shake -|= 1;
}

fn px_q(v: u16) i32 {
    return @as(i32, v) << fixed.Q;
}

fn read_events(w: *const world.World, follow: u8) void {
    var pending: u16 = w.event_seq -% last_seq;
    // The ring holds the last `event_count`; older ones are gone.
    if (pending > world.event_count) {
        last_seq = w.event_seq -% world.event_count;
        pending = world.event_count;
    }
    while (last_seq != w.event_seq) : (last_seq +%= 1) {
        const e = &w.events[last_seq % world.event_count];
        if (e.seq != last_seq) continue;
        on_event(w, e, follow);
    }
}

fn valid_car(i: u8) bool {
    return i < world.car_count;
}

fn wreck_cause(c: u8) world.Wreck {
    return switch (c) {
        1 => .fall,
        2 => .armor,
        3 => .zero_day,
        else => .none,
    };
}

/// An if-chain rather than a switch, so event kinds added later (M2's
/// pickups) are simply ignored here until they get a look.
fn on_event(w: *const world.World, e: *const world.Event, follow: u8) void {
    const kind = e.kind;
    if (kind == .hit) {
            if (!valid_car(e.b)) return;
            const v = &w.cars[e.b];
            spawn(.spark, v.x, v.y, 6, 12);
            if (e.a == follow and e.b != follow) {
                acks[next_ack] = .{ .car = e.b, .ticks = ack_ticks };
                next_ack = (next_ack + 1) % acks.len;
            }
            if (e.b == follow) armor_flash = 12;
    } else if (kind == .wreck) {
            if (!valid_car(e.a)) return;
            const v = &w.cars[e.a];
            const cause = wreck_cause(e.c);
            // The sim's own `explode` (radius 24) follows for the blast.
            feed = .{ .ticks = feed_ticks, .killer = e.b, .victim = e.a, .cause = cause };
            if (e.a == follow) {
                shake = wreck_shake;
                // A fall shows the sim's own SEGMENT FAULT message.
                if (cause != .fall) wreck_note = .{ .ticks = wreck_note_ticks, .killer = e.b, .cause = cause };
                if (valid_car(e.b) and e.b != follow) popup = .{ .ticks = popup_ticks, .racer = w.cars[e.b].racer, .wrecked = false };
            } else if (e.b == follow) {
                popup = .{ .ticks = popup_ticks, .racer = v.racer, .wrecked = true };
            }
    } else if (kind == .lance) {
            if (!valid_car(e.a)) return;
            beams[next_beam] = .{ .owner = e.a, .x = px_q(e.x), .y = px_q(e.y), .age = 0 };
            next_beam = (next_beam + 1) % beams.len;
            if (valid_car(e.b)) {
                const t = &w.cars[e.b];
                spawn(.spark, t.x, t.y, 6, 14);
            }
    } else if (kind == .explode) {
            const x = px_q(e.x);
            const y = px_q(e.y);
            // Radius 0 is a projectile dying on a wall: a spark.
            if (e.b == 0) spawn(.spark, x, y, 4, 10) else spawn(.explosion, x, y, 0, @intCast(@min(255, @as(u32, e.b) * 3 / 2 + 8)));
    } else if (kind == .respawn) {
            if (!valid_car(e.a)) return;
            const c = &w.cars[e.a];
            // Respawn flicker: a ring of sparks where the car comes back.
            var k: u16 = 0;
            while (k < 4) : (k += 1) {
                const a: fixed.Turn = k *% 16384 +% 8192;
                spawn(.spark, c.x +% fixed.cos(a) * 10, c.y +% fixed.sin(a) * 10, 4, 12);
            }
    }
}

/// Smoke states (SPEC 5.3): grey puffs below 50% armor, black smoke and
/// sparks below 25%, black smoke from a burning hulk; a muzzle flash when
/// the front ammo count drops.
fn car_effects(c: *const world.Car, i: usize, frame: u32) void {
    if (!c.active) return;
    const phase = frame +% @as(u32, @intCast(i)) * 3;
    // Behind the car, along its heading.
    const bx = c.x -% fixed.cos(c.heading) * 6;
    const by = c.y -% fixed.sin(c.heading) * 6;
    if (c.wreck != .none) {
        if (sim.is_hulk(c) and phase % 6 == 0) spawn(.black_smoke, c.x, c.y, 8, 14);
        return;
    }
    if (c.ammo_front < prev_ammo[i]) {
        spawn(.muzzle, c.x +% fixed.cos(c.heading) * 14, c.y +% fixed.sin(c.heading) * 14, 3, 12);
    }
    const max: u32 = @max(1, c.armor_max);
    const pct: u32 = @as(u32, c.armor) * 100 / max;
    if (pct < 25) {
        if (phase % 4 == 0) spawn(.black_smoke, bx, by, 6, 10);
        if (phase % 14 == 0) spawn(.spark, bx, by, 6, 8);
    } else if (pct < 50) {
        if (phase % 8 == 0) spawn(.smoke, bx, by, 6, 9);
    }
}

const smoke_black: cart.Pixel = .from_color(.rgb(0x1A1620));

/// One particle at its projected floor point (the sprites depth list).
pub fn draw_particle(i: usize, p: camera.Projected) void {
    const pt = &particles[i];
    const dw: i32 = @max(2, @divTrunc(@as(i32, pt.size) * tuning.focal, @max(p.zf, 1)));
    const bottom = p.sy - sprites.lift_px(pt.lift, p);
    const s = &sprites.effects;
    switch (pt.kind) {
        .none => {},
        .explosion => {
            const f: u32 = sprites.f_explosion + @min(3, pt.age / 4);
            sprites.blit_sized(s, f, p.sx, bottom + @divTrunc(dw, 6), dw, dw, .{});
        },
        .spark => sprites.blit_sized(s, sprites.f_spark + @as(u32, @intFromBool(pt.age >= 3)), p.sx, bottom + @divTrunc(dw, 2), dw, dw, .{}),
        .smoke, .black_smoke => {
            const grow: i32 = @divTrunc(dw * (8 + @as(i32, pt.age)), 24);
            const cell: u32 = sprites.f_smoke + @as(u32, @intFromBool(pt.age >= 12));
            sprites.blit_sized(s, cell, p.sx, bottom, grow, grow, .{
                .flat = if (pt.kind == .black_smoke) smoke_black else null,
                .skip_odd = pt.age >= 18,
            });
        },
        .muzzle => sprites.blit_sized(s, sprites.f_muzzle, p.sx, bottom, dw, dw, .{}),
    }
}

// --- Beams (screen lines after the sprites) ---------------------------------------------

const beam_core: cart.Pixel = .from_color(.rgb(0xFFFFFF));
const beam_glow: cart.Pixel = .from_color(.rgb(0x4FD8F0));
const beam_fade: cart.Pixel = .from_color(.rgb(0x2A7890));
/// The beam leaves the car at this height, world px.
const beam_lift: i32 = 6;
const beam_steps: i32 = 12;

/// FIBER LANCE beams (SPEC 10): a 1 to 2 px line from the firing car to
/// the end point, through a dozen projected points so it follows the
/// floor's perspective (and a crest), clipped to the screen.
pub fn draw_beams(w: *const world.World) void {
    for (&beams) |*b| {
        if (b.age >= beam_ticks or !valid_car(b.owner)) continue;
        const c = &w.cars[b.owner];
        var dx = (b.x -% c.x) & ((1024 << fixed.Q) - 1);
        var dy = (b.y -% c.y) & ((1024 << fixed.Q) - 1);
        if (dx >= 512 << fixed.Q) dx -= 1024 << fixed.Q;
        if (dy >= 512 << fixed.Q) dy -= 1024 << fixed.Q;
        const core = if (b.age < 3) beam_core else beam_glow;
        const glow = if (b.age < 3) beam_glow else beam_fade;
        var have_prev = false;
        var px0: i32 = 0;
        var py0: i32 = 0;
        var k: i32 = 0;
        while (k <= beam_steps) : (k += 1) {
            const x = c.x +% @divTrunc(dx, beam_steps) * k;
            const y = c.y +% @divTrunc(dy, beam_steps) * k;
            const p = camera.project(x, y) orelse {
                have_prev = false;
                continue;
            };
            const sy = p.sy - sprites.lift_px(beam_lift, p);
            if (have_prev) {
                line(px0, py0 + 1, p.sx, sy + 1, glow);
                line(px0, py0, p.sx, sy, core);
            }
            px0 = p.sx;
            py0 = sy;
            have_prev = true;
        }
    }
}

/// Bresenham, clipped per pixel to the screen (beams are short).
pub fn line(x0_: i32, y0_: i32, x1: i32, y1: i32, px: cart.Pixel) void {
    // Reject segments wholly off one side.
    if ((x0_ < 0 and x1 < 0) or (x0_ >= 160 and x1 >= 160) or (y0_ < 0 and y1 < 0) or (y0_ >= 128 and y1 >= 128)) return;
    var x0 = x0_;
    var y0 = y0_;
    const dx: i32 = @intCast(@abs(x1 - x0));
    const dy: i32 = -@as(i32, @intCast(@abs(y1 - y0)));
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;
    var n: u32 = 0;
    while (n < 400) : (n += 1) {
        if (x0 >= 0 and x0 < 160 and y0 >= 0 and y0 < 128) cart.framebuffer[@intCast(x0)][@intCast(y0)] = px;
        if (x0 == x1 and y0 == y1) break;
        const e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x0 += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y0 += sy;
        }
    }
}
