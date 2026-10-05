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
//!
//! M2 (pickups): `roll` pops the crate, `use` draws the ZERO-DAY dart,
//! `effect` gives the cosmic ray of a BIT FLIP, the `<honey>` tags of a
//! HONEYPOT, the popped RUBBER DUCK (`QUACK`), sparks and the pickup feed
//! lines (`KERNEL PANIC > KIDDIE`), `swap` the RACE CONDITION glitch; the
//! KERNEL PANIC packet trails ghosts; the followed car's roulette landing
//! shows the pickup's name, and a ZERO-DAY on it flashes the screen.
//!
//! M3 (GARBAGE COLLECTION, hazards): `mark` gives the feed's MARKED and
//! TAGGED lines, a `TAGGED!` tag over the newly marked car and the bar
//! notes on the badge that drives it (`gc_note`); `collect` starts a claw
//! (`claws`: the GC claw lowers over the car, closes and lifts it out,
//! drawn by sprites.zig from what is kept here, since the World has taken
//! the car out of the race) and the feed's `GC: freed KIDDIE`, and keeps
//! the sweep it went out at for the results; `blast` puffs at a vent's
//! mouth; `hazard_hit` sparks, flashes the armor bar and names the hazard
//! in the feed. The attract demo reads `panic_target` to cut its camera.
//!
//! M6 (BATTLE, `KILL -9`): `eliminated` gives the feed's `SNOUTY kill -9
//! KIDDIE`; `out` the claw on the hulk of a car out of lives and `REAPED`;
//! `stack_smash` sparks, `SMASH!` over the victim, the feed's `SMASHED`
//! line and the STACK SMASH! pop on either car's badge; `clean_landing`
//! the CLEAN LANDING pop on the lander's badge (`stunt`).
const std = @import("std");
const cart = @import("cart-api");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const world = @import("world.zig");
const camera = @import("camera.zig");
const sprites = @import("sprites.zig");
const sim = @import("sim.zig");
const font = @import("font.zig");
const track = @import("track.zig");

const no_car = world.no_car;

// --- Particles (world-anchored, drawn through the sprites depth list) ---------------

/// M2: `pop` (a crate taken), `text` (a `<honey>` tag or `QUACK`, `size`
/// is the `texts` index), `duck` (a popped RUBBER DUCK tumbling up), `ray`
/// (BIT FLIP's cosmic ray), `ghost` (the KERNEL PANIC packet's trail).
pub const PKind = enum(u8) { none, explosion, spark, smoke, black_smoke, muzzle, pop, text, duck, ray, ghost };
pub const Particle = struct {
    kind: PKind = .none,
    /// World position, Q16.16.
    x: i32 = 0,
    y: i32 = 0,
    /// Height over the floor, world px.
    lift: i16 = 0,
    age: u8 = 0,
    /// Diameter, world px (`text`: the string).
    size: u8 = 0,
    /// Drift, world px per tick (the honey tags fly apart).
    dx: i8 = 0,
    dy: i8 = 0,
};
const texts = [_][]const u8{ "<honey>", "</honey>", "<honey/>", "QUACK", "TAGGED!", "+10", "SMASH!" };
const text_quack: u8 = 3;
const text_tagged: u8 = 4;
const text_chip: u8 = 5;
const text_smash: u8 = 6;
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
        .pop => 12,
        .text => 40,
        .duck => 36,
        .ray => 10,
        .ghost => 8,
    };
}

pub fn spawn(kind: PKind, x: i32, y: i32, lift: i16, size: u8) void {
    particles[next_particle] = .{ .kind = kind, .x = x, .y = y, .lift = lift, .size = size };
    next_particle = (next_particle + 1) % particle_count;
}

// --- FIBER LANCE beams --------------------------------------------------------------------

/// SPEC 6.1: the beam is drawn for 6 ticks.
pub const beam_ticks: u8 = 6;
/// `dart`: the ZERO-DAY's hitscan dart (red), not a FIBER LANCE.
pub const Beam = struct { owner: u8 = no_car, x: i32 = 0, y: i32 = 0, age: u8 = 255, dart: bool = false };
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

/// What a feed line says. `wreck`: `KILLER > VICTIM` (or the victim and
/// the cause); `pickup`: `KERNEL PANIC > KIDDIE` (`pickup` hit `victim`);
/// `swap`: a RACE CONDITION, `killer <> victim`; M3: `marked` (a sweep
/// marked `victim`), `tagged` (`killer` passed the mark to `victim`),
/// `freed` (`GC: freed VICTIM`), `hazard` (`VENT > VICTIM`). Wreck, mark
/// and collect lines are not overwritten by pickup, swap and hazard lines.
/// M6: `kill9` (`killer kill -9 victim`, a battle elimination; `reaped`
/// set when it took the victim's last life), `reaped` (`VICTIM REAPED`:
/// out of lives with nobody credited), `smash` (`killer SMASHED victim`,
/// a STACK SMASH, minor).
pub const FeedKind = enum(u8) { wreck, pickup, swap, marked, tagged, freed, hazard, kill9, reaped, smash };
pub const Feed = struct {
    ticks: u8 = 0,
    kind: FeedKind = .wreck,
    killer: u8 = no_car,
    victim: u8 = 0,
    cause: world.Wreck = .none,
    pickup: world.Pickup = .none,
    hazard: world.HazardKind = .none,
    /// kill9: that was the victim's last life (the claw comes for it).
    reaped: bool = false,

    fn minor(f: *const Feed) bool {
        return f.kind == .pickup or f.kind == .swap or f.kind == .hazard or f.kind == .smash;
    }
};
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
/// The followed car's roulette just landed: the pickup's name shows by the box.
pub var land_ticks: u8 = 0;
pub const land_show: u8 = 60;
/// A ZERO-DAY struck or hit the followed car: the screen flashes.
pub var zero_flash: u8 = 0;
pub const zero_flash_ticks: u8 = 8;
/// A RACE CONDITION swapped the followed car: the screen glitches.
pub var glitch: u8 = 0;
pub const glitch_ticks: u8 = 10;
var prev_roll: u8 = 0;
/// The CAPTCHA board was cleared by a miss (A on an unlit cell): `TRY AGAIN`.
pub var captcha_fail: u8 = 0;
var prev_done: u16 = 0;
/// The followed car solved its CAPTCHA (freed before the wait ran out).
pub var verified: u8 = 0;
var prev_captcha: u8 = 0;
/// Who sent the KERNEL PANIC that hit the followed car (the stop code).
pub var panic_source: u8 = no_car;
/// The car the last KERNEL PANIC struck (main.zig's attract camera cuts to
/// it for the blue screen, takes it and puts back `no_car`).
pub var panic_target: u8 = no_car;
pub var panic_from: u8 = no_car;

// --- GARBAGE COLLECTION (M3) ---------------------------------------------------------

/// The bar note on the badge whose car a `mark` or `collect` concerns:
/// a sweep marked it, a tag passed the mark to it, it passed the mark on,
/// it was collected.
pub const GcNote = enum(u8) { none, marked, tagged, passed, collected };
pub var gc_note: GcNote = .none;
pub var gc_note_ticks: u8 = 0;
pub const gc_note_show: u8 = 90;

/// The claw lifting a collected car out (SPEC 8.2): lowered for
/// `claw_down` ticks, closed until `claw_grab`, then lifting until
/// `claw_ticks`. The car is out of the World's race, so its racer, place
/// and heading are kept here.
pub const Claw = struct {
    car: u8 = no_car,
    racer: u8 = 0,
    wrecked: bool = false,
    heading: fixed.Turn = 0,
    x: i32 = 0,
    y: i32 = 0,
    age: u8 = 0,
};
pub const claw_down: u8 = 24;
pub const claw_grab: u8 = 34;
pub const claw_ticks: u8 = 90;
pub var claws: [2]Claw = @splat(.{});
var next_claw: usize = 0;
/// Per car: the sweep it was collected at (0 = still running) and how
/// (the results' GC table).
pub var freed_sweep: [world.car_count]u8 = @splat(0);
pub var freed_cause: [world.car_count]world.GcCause = @splat(.sweep);

/// M6: a stunt pop on this badge's car (the HUD's bar): it landed a STACK
/// SMASH, was smashed, or made a CLEAN LANDING.
pub const StuntKind = enum(u8) { none, smash, smashed, landing };
pub const Stunt = struct { kind: StuntKind = .none, ticks: u8 = 0 };
pub var stunt: Stunt = .{};
pub const stunt_show: u8 = 50;

/// Hazards: ticks each slot has been `active` (a vent's blast grows from
/// its mouth and thins before it stops), for sprites.zig.
pub var blast_age: [world.hazard_max]u16 = @splat(0);
var prev_hazard: [world.hazard_max]world.HazardState = @splat(.idle);

/// A claw is still busy with car `i`.
pub fn claw_on(i: u8) bool {
    for (&claws) |*k| {
        if (k.car == i and k.age < claw_ticks) return true;
    }
    return false;
}

/// The event cursor: the next seq this badge has not shown.
var last_seq: u16 = 0;
var prev_ammo: [world.car_count]u8 = @splat(0);

/// At race start (and after a restart): forget everything, start the
/// cursor at the World's current seq.
pub fn begin(w: *const world.World) void {
    track.crust_look(&w.hazards);
    particles = @splat(.{});
    beams = @splat(.{});
    acks = @splat(.{});
    feed = .{};
    popup = .{};
    wreck_note = .{};
    armor_flash = 0;
    shake = 0;
    land_ticks = 0;
    zero_flash = 0;
    glitch = 0;
    prev_roll = 0;
    captcha_fail = 0;
    prev_done = 0;
    verified = 0;
    prev_captcha = 0;
    panic_source = no_car;
    panic_target = no_car;
    gc_note = .none;
    gc_note_ticks = 0;
    stunt = .{};
    claws = @splat(.{});
    freed_sweep = @splat(0);
    blast_age = @splat(0);
    prev_hazard = @splat(.idle);
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
    // The KERNEL PANIC packet leaves ghosts.
    if (frame % 3 == 0) {
        for (&w.projs) |*pr| {
            if (pr.kind == .panic) spawn(.ghost, pr.x, pr.y, 5, 16);
        }
    }
    // M7: breakable crust shows its state (the map copy's crust tiles).
    track.crust_look(&w.hazards);
    // Hazards: the blast clocks, and steam wisps from a vent about to fire.
    for (track.hazard_specs[0..track.hazard_n], 0..) |*h, k| {
        const hz = &w.hazards[k];
        blast_age[k] = if (hz.state == .active and prev_hazard[k] == .active) blast_age[k] +| 1 else 0;
        prev_hazard[k] = hz.state;
        if (h.kind == .blast and hz.state == .warn and frame % 4 == 0) {
            const d: i32 = @intCast(4 + (frame / 4) % 3 * 6);
            spawn(.smoke, (h.x0 << fixed.Q) +% h.ux * d, (h.y0 << fixed.Q) +% h.uy * d, 2, 10);
        }
    }
    const me = &w.cars[follow % world.car_count];
    if (prev_roll > 0 and me.roll_ticks == 0 and me.pickup != .none) land_ticks = land_show;
    prev_roll = me.roll_ticks;
    if (me.captcha > 0 and prev_done != 0 and me.captcha_done == 0) captcha_fail = 30;
    if (me.captcha_done != 0) captcha_fail = 0;
    if (prev_captcha > 1 and me.captcha == 0 and me.wreck == .none and me.human != world.no_human) verified = 45;
    prev_captcha = me.captcha;
    prev_done = if (me.captcha > 0) me.captcha_done else 0;
}

fn age_all() void {
    for (&particles) |*p| {
        if (p.kind == .none) continue;
        p.age +|= 1;
        p.x +%= @as(i32, p.dx) << (fixed.Q - 2);
        p.y +%= @as(i32, p.dy) << (fixed.Q - 2);
        switch (p.kind) {
            .smoke, .black_smoke => {
                if (p.age % 2 == 0) p.lift += 1;
            },
            .pop => p.lift += 1,
            .text => p.lift += if (p.size == text_tagged) @as(i16, @intFromBool(p.age % 2 == 0)) else 1,
            .duck => p.lift += @max(0, 4 - @as(i16, p.age / 6)),
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
    land_ticks -|= 1;
    zero_flash -|= 1;
    glitch -|= 1;
    captcha_fail -|= 1;
    verified -|= 1;
    gc_note_ticks -|= 1;
    stunt.ticks -|= 1;
    for (&claws) |*k| {
        if (k.car != no_car and k.age < claw_ticks) k.age += 1;
    }
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
    if (kind == .chip) {
        // M5: a cycle chip taken: a pop, and `+10` over it for this
        // badge's own car (10 CYCLES in the career).
        spawn(.spark, px_q(e.x), px_q(e.y), 3, 8);
        if (e.a == follow) spawn_text(px_q(e.x), px_q(e.y), text_chip, 0, 0);
    } else if (kind == .hit) {
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
        feed = .{ .ticks = feed_ticks, .kind = .wreck, .killer = e.b, .victim = e.a, .cause = cause };
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
    } else if (kind == .roll) {
        // A crate taken: it pops up and away with a spark.
        spawn(.pop, px_q(e.x), px_q(e.y), 0, 16);
        spawn(.spark, px_q(e.x), px_q(e.y), 6, 14);
    } else if (kind == .use) {
        on_use(w, e, follow);
    } else if (kind == .effect) {
        on_effect(w, e, follow);
    } else if (kind == .swap) {
        if (!valid_car(e.a) or !valid_car(e.b)) return;
        spawn(.spark, w.cars[e.a].x, w.cars[e.a].y, 6, 16);
        spawn(.spark, w.cars[e.b].x, w.cars[e.b].y, 6, 16);
        if (e.a == follow or e.b == follow) glitch = glitch_ticks;
        minor_feed(.{ .ticks = feed_ticks, .kind = .swap, .killer = e.a, .victim = e.b });
    } else if (kind == .mark) {
        on_mark(w, e, follow);
    } else if (kind == .collect) {
        on_collect(w, e, follow);
    } else if (kind == .eliminated) {
        // `SNOUTY kill -9 KIDDIE` over the wreck line the same tick wrote.
        if (!valid_car(e.a) or !valid_car(e.b)) return;
        feed = .{ .ticks = feed_ticks, .kind = .kill9, .killer = e.a, .victim = e.b };
    } else if (kind == .out) {
        on_out(w, e);
    } else if (kind == .stack_smash) {
        if (!valid_car(e.a) or !valid_car(e.b)) return;
        const x = px_q(e.x);
        const y = px_q(e.y);
        spawn(.explosion, x, y, 0, 14);
        spawn(.spark, x, y, 8, 16);
        spawn_text(x, y, text_smash, 0, 0);
        if (e.a == follow) stunt = .{ .kind = .smash, .ticks = stunt_show };
        if (e.b == follow) {
            stunt = .{ .kind = .smashed, .ticks = stunt_show };
            shake = 8;
            armor_flash = 12;
        }
        minor_feed(.{ .ticks = feed_ticks, .kind = .smash, .killer = e.a, .victim = e.b });
    } else if (kind == .clean_landing) {
        if (!valid_car(e.a)) return;
        if (e.a == follow) stunt = .{ .kind = .landing, .ticks = stunt_show };
        spawn(.spark, px_q(e.x), px_q(e.y), 2, 10);
    } else if (kind == .blast) {
        // A vent starts firing: a burst at its mouth (the Sweeper's
        // crossing shows in its beacon).
        if (e.b == @backingInt(world.HazardKind.blast)) spawn(.explosion, px_q(e.x), px_q(e.y), 0, 22);
        // M7: a crust region gives way: dust over its middle.
        if (e.b == @backingInt(world.HazardKind.crust)) spawn(.smoke, px_q(e.x), px_q(e.y), 0, 24);
    } else if (kind == .hazard_hit) {
        if (!valid_car(e.b)) return;
        const x = px_q(e.x);
        const y = px_q(e.y);
        spawn(.spark, x, y, 6, 16);
        spawn(.explosion, x, y, 0, 14);
        if (e.b == follow) {
            armor_flash = 12;
            shake = 8;
        }
        const hk: world.HazardKind = if (e.a < track.hazard_n) track.hazard_specs[e.a].kind else .none;
        minor_feed(.{ .ticks = feed_ticks, .kind = .hazard, .victim = e.b, .hazard = hk });
    }
}

/// A `mark`: the feed line, `TAGGED!` over a tagged car, the bar notes.
fn on_mark(w: *const world.World, e: *const world.Event, follow: u8) void {
    if (!valid_car(e.a)) return;
    const tag = e.c == @backingInt(world.GcCause.tag) and valid_car(e.b);
    const c = &w.cars[e.a];
    if (tag) {
        feed = .{ .ticks = feed_ticks, .kind = .tagged, .killer = e.b, .victim = e.a };
        spawn_text(c.x, c.y, text_tagged, 0, 0);
        spawn(.spark, c.x, c.y, 8, 16);
    } else {
        feed = .{ .ticks = feed_ticks, .kind = .marked, .victim = e.a };
    }
    if (e.a == follow) {
        gc_note = if (tag) .tagged else .marked;
        gc_note_ticks = gc_note_show;
    } else if (tag and e.b == follow) {
        gc_note = .passed;
        gc_note_ticks = gc_note_show;
    }
}

/// A `collect`: the claw, the feed line, the results' record.
fn on_collect(w: *const world.World, e: *const world.Event, follow: u8) void {
    if (!valid_car(e.a)) return;
    const c = &w.cars[e.a];
    claws[next_claw] = .{
        .car = e.a,
        .racer = c.racer,
        .wrecked = c.wreck != .none,
        .heading = c.heading,
        .x = px_q(e.x),
        .y = px_q(e.y),
    };
    next_claw = (next_claw + 1) % claws.len;
    feed = .{ .ticks = feed_ticks, .kind = .freed, .victim = e.a };
    freed_sweep[e.a] = @max(1, w.gc.sweeps);
    freed_cause[e.a] = if (e.c <= @backingInt(world.GcCause.wreck)) @fromBackingInt(@intCast(e.c)) else .sweep;
    if (e.a == follow) {
        gc_note = .collected;
        gc_note_ticks = gc_note_show;
    }
}

/// M6 `out`: a car is out of lives. The GC claw takes its hulk (SPEC 8.3:
/// "reaped"); the feed's kill -9 line for it says so, or `VICTIM REAPED`
/// when nobody was credited.
fn on_out(w: *const world.World, e: *const world.Event) void {
    if (!valid_car(e.a)) return;
    const c = &w.cars[e.a];
    claws[next_claw] = .{
        .car = e.a,
        .racer = c.racer,
        .wrecked = true,
        .heading = c.heading,
        .x = px_q(e.x),
        .y = px_q(e.y),
    };
    next_claw = (next_claw + 1) % claws.len;
    if (feed.ticks > 0 and feed.kind == .kill9 and feed.victim == e.a) {
        feed.reaped = true;
        feed.ticks = feed_ticks;
    } else {
        feed = .{ .ticks = feed_ticks, .kind = .reaped, .victim = e.a };
    }
}

fn pickup_of(v: u8) world.Pickup {
    return if (v <= @backingInt(world.Pickup.prompt_injection)) @fromBackingInt(@intCast(v)) else .none;
}

/// A pickup feed line, unless a wreck line is showing.
fn pickup_feed(p: world.Pickup, a: u8, victim: u8) void {
    minor_feed(.{ .ticks = feed_ticks, .kind = .pickup, .killer = a, .victim = victim, .pickup = p });
}

/// A pickup, swap or hazard line, unless a wreck, mark or collect line is showing.
fn minor_feed(f: Feed) void {
    if (!valid_car(f.victim)) return;
    if (feed.ticks > 0 and !feed.minor()) return;
    feed = f;
}

fn on_use(w: *const world.World, e: *const world.Event, follow: u8) void {
    if (!valid_car(e.a)) return;
    if (pickup_of(e.b) == .zero_day) {
        // The ZERO-DAY's dart: a red hitscan line to where it struck.
        beams[next_beam] = .{ .owner = e.a, .x = px_q(e.x), .y = px_q(e.y), .age = 0, .dart = true };
        next_beam = (next_beam + 1) % beams.len;
        if (e.a == follow or e.c == follow) zero_flash = zero_flash_ticks;
    }
    _ = w;
}

fn on_effect(w: *const world.World, e: *const world.Event, follow: u8) void {
    if (!valid_car(e.b)) return;
    const x = px_q(e.x);
    const y = px_q(e.y);
    const p = pickup_of(e.c);
    switch (p) {
        .kernel_panic => {
            if (e.b == follow) panic_source = e.a;
            panic_target = e.b;
            panic_from = e.a;
            spawn(.spark, x, y, 8, 18);
            spawn(.ghost, x, y, 6, 24);
            pickup_feed(p, e.a, e.b);
        },
        .bit_flip => {
            spawn(.ray, x, y, 0, 12);
            spawn(.spark, x, y, 4, 14);
            pickup_feed(p, e.a, e.b);
        },
        .deadlock, .ddos, .spaghetti => {
            spawn(.spark, x, y, 5, 12);
            pickup_feed(p, e.a, e.b);
        },
        .honeypot => {
            // The fake crate bursts into `<honey>` tags.
            spawn(.explosion, x, y, 0, 20);
            spawn_text(x, y, 0, -3, 2);
            spawn_text(x, y, 1, 3, 1);
            spawn_text(x, y, 2, 0, -3);
            pickup_feed(p, e.a, e.b);
        },
        .duck => {
            // The duck took the hit: it tumbles up, QUACK.
            const c = &w.cars[e.b];
            const bx = c.x -% fixed.cos(c.heading) * 18;
            const by = c.y -% fixed.sin(c.heading) * 18;
            spawn(.duck, bx, by, 2, 12);
            spawn(.spark, bx, by, 4, 12);
            spawn_text(bx, by, text_quack, 0, 0);
        },
        .zero_day => {
            if (e.a == follow or e.b == follow) zero_flash = zero_flash_ticks;
            spawn(.spark, x, y, 6, 20);
        },
        else => spawn(.spark, x, y, 5, 10),
    }
}

fn spawn_text(x: i32, y: i32, id: u8, dx: i8, dy: i8) void {
    particles[next_particle] = .{ .kind = .text, .x = x, .y = y, .lift = 10, .size = id, .dx = dx, .dy = dy };
    next_particle = (next_particle + 1) % particle_count;
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
        .pop => {
            const grow: i32 = @divTrunc(dw * (8 + @as(i32, pt.age)), 8);
            sprites.blit_sized(&sprites.pickups, sprites.p_crate, p.sx, bottom, grow, grow, .{ .skip_odd = pt.age >= 5 });
        },
        .ghost => sprites.blit_sized(&sprites.weapons, sprites.w_panic, p.sx, bottom, @divTrunc(dw, 2), @divTrunc(dw, 2), .{ .skip_odd = true }),
        .duck => {
            const flip = (pt.age / 4) % 2 == 1;
            sprites.blit_sized(&sprites.weapons, sprites.w_duck, p.sx, bottom, dw, dw, .{ .flip = flip });
        },
        .text => {
            const str = texts[pt.size % texts.len];
            if (pt.age > 30 and pt.age % 2 == 0) return;
            const color: cart.Pixel = if (pt.size == text_quack) honey_white else if (pt.size == text_tagged or pt.size == text_smash) (if (pt.age % 4 < 2) tagged_red else honey_white) else if (pt.size == text_chip) chip_green else honey_orange;
            // M5: kept whole on screen (TAGGED! over a car at the edge was
            // cut off), 2 px from either side.
            const wpx: i32 = @intCast(str.len * 8);
            const x = std.math.clamp(p.sx - @divTrunc(wpx, 2), 2, 158 - wpx);
            font.draw(str, x, bottom - 8, color, honey_shadow);
        },
        .ray => draw_ray(p.sx, bottom, pt.age),
    }
}

const honey_orange: cart.Pixel = .from_color(.rgb(0xF59A3C));
const tagged_red: cart.Pixel = .from_color(.rgb(0xE83838));
const chip_green: cart.Pixel = .from_color(.rgb(0x4CE070));
const honey_white: cart.Pixel = .from_color(.rgb(0xFCFBF9));
const honey_shadow: cart.Pixel = .from_color(.rgb(0x16031B));
const ray_core: cart.Pixel = .from_color(.rgb(0xFFFFFF));
const ray_glow: cart.Pixel = .from_color(.rgb(0xB070FF));

/// BIT FLIP's cosmic ray: a jagged bolt from the top of the screen down to
/// the struck car, for the first frames of the particle.
fn draw_ray(x: i32, y: i32, age: u8) void {
    if (age >= 7) return;
    const jag = [_]i32{ 0, 5, -3, 4, -4, 2, 0 };
    var prev_x = x + jag[0];
    var prev_y: i32 = 0;
    var k: usize = 1;
    while (k < jag.len) : (k += 1) {
        const ny = @divTrunc(y * @as(i32, @intCast(k)), @as(i32, @intCast(jag.len - 1)));
        const nx = x + jag[k] * @as(i32, @intFromBool(k + 1 < jag.len));
        line(prev_x + 1, prev_y, nx + 1, ny, ray_glow, false);
        line(prev_x - 1, prev_y, nx - 1, ny, ray_glow, false);
        line(prev_x, prev_y, nx, ny, ray_core, false);
        prev_x = nx;
        prev_y = ny;
    }
}

// --- Beams (screen lines after the sprites) ---------------------------------------------

const beam_core: cart.Pixel = .from_color(.rgb(0xFFFFFF));
const beam_glow: cart.Pixel = .from_color(.rgb(0x4FD8F0));
const beam_fade: cart.Pixel = .from_color(.rgb(0x2A7890));
const dart_red: cart.Pixel = .from_color(.rgb(0xE83838));
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
        var core = if (b.age < 3) beam_core else beam_glow;
        var glow = if (b.age < 3) beam_glow else beam_fade;
        if (b.dart) {
            core = if (b.age < 3) beam_core else dart_red;
            glow = dart_red;
        }
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
                line(px0, py0 + 1, p.sx, sy + 1, glow, false);
                line(px0, py0, p.sx, sy, core, false);
            }
            px0 = p.sx;
            py0 = sy;
            have_prev = true;
        }
    }
}

/// Bresenham, clipped per pixel to the screen (beams are short). `dashed`
/// leaves every other pair of pixels out (a chain's links).
pub fn line(x0_: i32, y0_: i32, x1: i32, y1: i32, px: cart.Pixel, dashed: bool) void {
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
        if (x0 >= 0 and x0 < 160 and y0 >= 0 and y0 < 128 and !(dashed and (n / 2) % 2 == 1)) cart.framebuffer[@intCast(x0)][@intCast(y0)] = px;
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
