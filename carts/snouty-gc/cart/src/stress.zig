//! New for Snouty GC (M1 Track B): the render stress scene (PLAN M1 Track B
//! item 8, SPEC 18's 64-object question). A debug path that fills the
//! World directly, without the sim: six cars in view ahead of SNOUTY (one
//! a burning hulk, one hit-flashing, one charging a FIBER LANCE, SNOUTY
//! smoking with a SPEAR PHISH lock), all 48 projectile slots (PING,
//! BROADCAST, SPEAR PHISH) streaming up the road, all 32 drop slots (MEMORY
//! LEAK, LOGIC BOMB, BIT ROT, FIREWALL), and every 30 ticks two explosions,
//! a lance beam, a hit and a wreck event for the feed and pop-up. The view
//! sweeps +-14 degrees so the list changes every frame. main.zig runs it
//! instead of `sim.simulate` when `gc_stress` is set (badge-bench
//! `--poke gc_stress=1`, or the wasm `debug_stress` export).
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const world = @import("world.zig");
const weapons = @import("weapons.zig");
const sim = @import("sim.zig");

const World = world.World;

var base_heading: fixed.Turn = 0;
var base_x: i32 = 0;
var base_y: i32 = 0;

/// A point `d` px ahead of the base and `lat` px to its right, Q16.16.
fn ahead(d: i32, lat: i32) [2]i32 {
    const c = fixed.cos(base_heading);
    const s = fixed.sin(base_heading);
    return .{ base_x +% c * d -% s * lat, base_y +% s * d +% c * lat };
}

/// Set the scene up on a freshly reset World (car `follow` is the camera's).
pub fn fill(w: *World, follow: u8) void {
    const me = &w.cars[follow];
    base_heading = me.heading;
    base_x = me.x;
    base_y = me.y;
    w.phase = .racing;
    w.msg = .none;
    w.msg_ticks = 0;
    w.countdown = 0;
    // The five rivals ahead, spread over the road.
    const spots = [5][3]i32{ .{ 45, -22, 0 }, .{ 75, 18, 9000 }, .{ 110, -4, 0 }, .{ 150, 26, -14000 }, .{ 210, -30, 3000 } };
    var k: usize = 0;
    for (&w.cars, 0..) |*c, i| {
        c.armor = c.armor_max;
        if (i == follow) continue;
        const s = spots[k];
        k += 1;
        const p = ahead(s[0], s[1]);
        c.x = p[0];
        c.y = p[1];
        c.heading = base_heading +% @as(u16, @bitCast(@as(i16, @intCast(s[2]))));
        c.vx = 0;
        c.vy = 0;
    }
    // A hulk, a smoker, a charger; SNOUTY damaged with a lock.
    const hulk = &w.cars[(follow + 2) % world.car_count];
    hulk.wreck = .armor;
    hulk.wreck_ticks = tuning.watchdog_ticks;
    w.cars[(follow + 4) % world.car_count].armor = 10;
    me.armor = me.armor_max / 4;
    me.lock = (follow + 1) % world.car_count;
    me.ammo_front = 3;
    me.ammo_rear = 3;
    // Drops: 8 of each kind over 40..360 px ahead.
    for (&w.drops, 0..) |*d, i| {
        const kind: world.DropKind = switch (i % 4) {
            0 => .leak,
            1 => .bomb,
            2 => .caltrop,
            else => .firewall,
        };
        const ii: i32 = @intCast(i);
        const p = ahead(40 + ii * 10, @mod(ii * 23, 70) - 35);
        d.* = .{ .x = p[0], .y = p[1], .kind = kind, .owner = @intCast(i % world.car_count), .age = @intCast(i * 20), .size = if (kind == .firewall) 32 else 6 + @as(u8, @intCast(i % 13)), .dir = @intCast(base_heading >> 8) };
    }
    step(w, follow, 0);
}

/// One frame of the scene (replaces `sim.simulate`).
pub fn step(w: *World, follow: u8, frame: u32) void {
    w.tick +%= 1;
    const me = &w.cars[follow];
    const sweep: fixed.Turn = @truncate(frame *% 300);
    me.heading = base_heading +% @as(u16, @bitCast(@as(i16, @intCast((fixed.sin(sweep) * 2500) >> fixed.Q))));
    // Projectiles: lanes up the road, 5 px/tick, recomputed from the frame.
    const c = fixed.cos(base_heading);
    const s = fixed.sin(base_heading);
    for (&w.projs, 0..) |*pr, i| {
        const ii: i32 = @intCast(i);
        const d: i32 = 24 + @mod(ii * 37 + @as(i32, @intCast(frame % 4096)) * 5, 380);
        const p = ahead(d, @mod(ii * 17, 60) - 30);
        const kind: world.ProjKind = switch (i % 3) {
            0 => .ping,
            1 => .broadcast,
            else => .phish,
        };
        pr.* = .{ .x = p[0], .y = p[1], .vx = @intCast((c * 5) >> 8), .vy = @intCast((s * 5) >> 8), .kind = kind, .owner = @intCast(i % world.car_count), .ttl = 100 };
    }
    for (&w.drops) |*d| {
        d.age +%= 1;
        if (d.kind == .leak) d.size = 6 + @as(u8, @intCast((d.age / 10) % 13));
    }
    // A hit-flasher and a lance charger.
    const flasher = &w.cars[(follow + 1) % world.car_count];
    flasher.hit_flash = if (frame % 40 < 10) @intCast(10 - frame % 40) else 0;
    const charger = &w.cars[(follow + 3) % world.car_count];
    charger.charge = @intCast(frame % 45);
    // SNOUTY fires: the front ammo ticks down (a muzzle flash), refilled.
    if (frame % 12 == 0) me.ammo_front = if (me.ammo_front == 0) 3 else me.ammo_front - 1;
    if (frame % 30 == 0) {
        const e1 = ahead(90, -20);
        const e2 = ahead(160, 24);
        weapons.emit(w, .explode, world.no_car, 24, 0, e1[0], e1[1]);
        weapons.emit(w, .explode, world.no_car, 24, 0, e2[0], e2[1]);
        const lancer: u8 = (follow + 3) % world.car_count;
        const end = ahead(420, 0);
        weapons.emit(w, .lance, lancer, world.no_car, 255, end[0], end[1]);
        weapons.emit(w, .hit, follow, flasher_index(follow), 4, flasher.x, flasher.y);
    }
    if (frame % 90 == 45) {
        const victim: u8 = (follow + 5) % world.car_count;
        weapons.emit(w, .wreck, victim, follow, @backingInt(world.Wreck.armor), w.cars[victim].x, w.cars[victim].y);
    }
}

fn flasher_index(follow: u8) u8 {
    return (follow + 1) % world.car_count;
}

// --- Pickup gags forced onto a car (M2 preview hooks) ------------------------------

/// What `force_effect` puts on a car (the wasm `debug_effect` export). A
/// debug path like the scene above: it writes the World directly so the
/// preview scripts can show each gag on a chosen frame; the sim then runs
/// the state on (`simulate` stays pure, nothing here is in a race).
pub const Effect = enum(u8) {
    none,
    kernel_panic,
    bit_flip,
    captcha,
    ddos,
    deadlock,
    heisenbug,
    sudo,
    race_condition,
    spaghetti,
    duck,
    prefetch,
    honeypot,
    zero_day,
    duck_pop,
    hot_patch,
    crate_pop,
};

/// The car right ahead of `i` in progress (or the next index), for the
/// effects that need a second car.
fn other_of(w: *const World, i: usize) usize {
    var best: usize = (i + 1) % world.car_count;
    var best_d: i32 = 1 << 30;
    const me = &w.cars[i];
    for (&w.cars, 0..) |*o, j| {
        if (j == i or !o.active or o.wreck != .none) continue;
        const dx = (o.x -% me.x) >> fixed.Q;
        const dy = (o.y -% me.y) >> fixed.Q;
        const d = dx * dx + dy * dy;
        if (d < best_d) {
            best_d = d;
            best = j;
        }
    }
    return best;
}

pub fn force_effect(w: *World, i_: usize, e: Effect) void {
    const i = i_ % world.car_count;
    const c = &w.cars[i];
    const ci: u8 = @intCast(i);
    const src: u8 = @intCast(other_of(w, i));
    const o = &w.cars[src];
    switch (e) {
        .none => {},
        .kernel_panic => {
            c.frozen = 90;
            c.frozen_by = .panic;
            c.vx = 0;
            c.vy = 0;
            weapons.emit(w, .effect, src, ci, @intFromEnum(world.Pickup.kernel_panic), c.x, c.y);
        },
        .bit_flip => {
            c.bit_flip = 180;
            weapons.emit(w, .effect, src, ci, @intFromEnum(world.Pickup.bit_flip), c.x, c.y);
        },
        .captcha => {
            c.captcha = 120;
            c.captcha_cursor = 0;
            c.captcha_done = 0;
            // Three lit cells of the nine from the World's own seed.
            var lit: u16 = 0;
            var r: u32 = w.rng | 1;
            var n: u32 = 0;
            while (n < 3) {
                r ^= r << 13;
                r ^= r >> 17;
                r ^= r << 5;
                const bit = @as(u16, 1) << @intCast(r % 9);
                if (lit & bit == 0) {
                    lit |= bit;
                    n += 1;
                }
            }
            c.captcha_lit = lit;
            weapons.emit(w, .effect, src, ci, @intFromEnum(world.Pickup.captcha), c.x, c.y);
        },
        .ddos => {
            for (&w.drones, 0..) |*d, k| {
                const a: fixed.Turn = @intCast(k * 8192);
                d.* = .{ .x = c.x +% fixed.cos(a) * 16, .y = c.y +% fixed.sin(a) * 16, .state = .orbit, .owner = src, .target = ci, .ttl = 180, .angle = @intCast(k * 32) };
            }
            weapons.emit(w, .effect, src, ci, @intFromEnum(world.Pickup.ddos), c.x, c.y);
        },
        .deadlock => {
            c.chain = src;
            c.chain_ticks = 150;
            o.chain = ci;
            o.chain_ticks = 150;
            weapons.emit(w, .effect, world.no_car, ci, @intFromEnum(world.Pickup.deadlock), c.x, c.y);
        },
        .heisenbug => c.heisen = 240,
        .sudo => c.sudo = 300,
        .race_condition => {
            c.swap_with = src;
            c.swap_ticks = 6;
            o.swap_with = ci;
            o.swap_ticks = 6;
        },
        .spaghetti => {
            c.tangle = 60;
            c.strand = 180;
            weapons.emit(w, .effect, src, ci, @intFromEnum(world.Pickup.spaghetti), c.x, c.y);
        },
        .duck => c.duck = 600,
        .prefetch => c.prefetch = 90,
        .honeypot => {
            c.spin = 30;
            weapons.emit(w, .effect, src, ci, @intFromEnum(world.Pickup.honeypot), c.x, c.y);
        },
        .zero_day => {
            weapons.emit(w, .use, src, @intFromEnum(world.Pickup.zero_day), ci, c.x, c.y);
            weapons.emit(w, .effect, src, ci, @intFromEnum(world.Pickup.zero_day), c.x, c.y);
            c.last_hit_by = src;
            c.last_hit_ticks = 0;
            sim.wreck(w, i, .zero_day);
        },
        .duck_pop => {
            c.duck = 0;
            weapons.emit(w, .effect, src, ci, @intFromEnum(world.Pickup.duck), c.x, c.y);
        },
        .hot_patch => c.patch = 60,
        .crate_pop => weapons.emit(w, .roll, ci, @intFromEnum(world.Pickup.sudo), 0, c.x +% fixed.cos(c.heading) * 30, c.y +% fixed.sin(c.heading) * 30),
    }
}
