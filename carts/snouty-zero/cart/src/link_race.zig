//! The link race (M6, PLAN "M6 Link race"): Snouty Zero's game for the
//! shared two-badge lockstep (`lockstep.Lockstep(L, G)`, root
//! docs/LOCKSTEP.md). Both badges hold the same World; `sim.simulate_world`
//! is pure in (World, the two humans' input bytes), so the badges exchange
//! only those bytes. The host (higher link nonce) picks the track, both
//! pick a machine and ready up, the host's Start goes.
//!
//! No cart API here, so the host tests (`link_race_test.zig`) run it over
//! the virtual cable; main.zig draws the lobby (`link_ui.zig`) and runs the
//! race loop.
const world = @import("world.zig");
const sim = @import("sim.zig");
const track = @import("track.zig");
const ai = @import("ai.zig");
const lockstep = @import("lockstep");

const World = world.World;
const Buttons = world.Buttons;

/// Snouty Zero's HELLO app byte (`link.Badge.init(.., app_id, ..)`).
pub const app_id: u8 = 'Z';

/// The race input byte: A, B, Up, Down, Left, Right, Start in bits 0-6.
/// Bit 7 is never set, so a byte is never 0xC0 or 0xDB (SLIP specials).
/// Select is not sent (the OS chord; the cart's own Select is local).
pub const bit_a: u8 = 0x01;
pub const bit_b: u8 = 0x02;
pub const bit_up: u8 = 0x04;
pub const bit_down: u8 = 0x08;
pub const bit_left: u8 = 0x10;
pub const bit_right: u8 = 0x20;
pub const bit_start: u8 = 0x40;

/// The byte for a button word (Start and Select both held is the OS
/// chord: the race sees neither, as input.zig's callers do).
pub fn byte_of(b: Buttons) u8 {
    var x: u8 = 0;
    if (b.a) x |= bit_a;
    if (b.b) x |= bit_b;
    if (b.up) x |= bit_up;
    if (b.down) x |= bit_down;
    if (b.left) x |= bit_left;
    if (b.right) x |= bit_right;
    if (b.start and !b.select) x |= bit_start;
    return x;
}

/// The button word `simulate` gets for a byte (Start is the lockstep's
/// pause and never reaches the World's physics anyway).
pub fn buttons_of(x: u8) Buttons {
    return .{
        .a = x & bit_a != 0,
        .b = x & bit_b != 0,
        .up = x & bit_up != 0,
        .down = x & bit_down != 0,
        .left = x & bit_left != 0,
        .right = x & bit_right != 0,
        .start = x & bit_start != 0,
    };
}

/// The host's one rules byte: the track's index in `track.tracks` (any
/// track of any league).
pub fn track_of(rules: [1]u8) *const track.Track {
    return track.tracks[rules[0] % track.tracks.len];
}

/// Machine picks: `ai.player_machines` indices, 3 bits on the wire. Both
/// badges may pick the same machine.
pub const pick_count: u8 = ai.player_machines.len;

/// The game namespace the lockstep runs (`Lockstep(L, G)`).
pub const G = struct {
    pub const World = world.World;
    pub const rules_len = 1;
    pub const input_delay: u32 = 2;
    pub const check_every: u32 = 32;
    pub const pick_bits = 3;
    /// Start: both badges pause on the tick a Start press lands.
    pub const pause_bit: ?u8 = bit_start;

    pub fn simulate(w: *world.World, in: [2]u8) void {
        sim.simulate_world(w, .{ buttons_of(in[0]), buttons_of(in[1]) });
    }

    pub fn hash(w: *const world.World) u32 {
        return lockstep.hash_fields(world.World, w);
    }

    /// The partner left: the AI drives its machine to the finish (the
    /// only World write outside `simulate`; nobody is left to agree with).
    pub fn hand_over(w: *world.World, slot: u1) void {
        w.ai_drives[slot] = true;
    }

    pub fn picks_ok(host: u8, guest: u8) bool {
        return host < pick_count and guest < pick_count;
    }
};

/// The World for an agreed race: the host's track, the host's human in
/// machine 0 and the guest's in machine 1 on their picks, the lockstep's
/// seed in the World's rng (both badges derive the same one).
pub fn reset(w: *World, rules: [1]u8, picks: [2]u8, seed: u32) void {
    const saved = world.w;
    sim.reset_link(track_of(rules), picks);
    if (seed != 0) world.w.rng = seed;
    if (w != &world.w) {
        w.* = world.w;
        world.w = saved;
    }
}

/// The machine the badge on input slot `slot` follows.
pub fn machine_of(slot: u1) u8 {
    return if (slot == 0) world.player else world.guest;
}

// --- Tests -------------------------------------------------------------------

const std = @import("std");

test "input bytes round-trip and are never SLIP specials" {
    var k: u16 = 0;
    while (k < 512) : (k += 1) {
        const b: Buttons = @bitCast(k);
        const x = byte_of(b);
        try std.testing.expect(x & 0x80 == 0);
        try std.testing.expect(x != 0xC0 and x != 0xDB);
        const back = buttons_of(x);
        try std.testing.expectEqual(b.a, back.a);
        try std.testing.expectEqual(b.b, back.b);
        try std.testing.expectEqual(b.left, back.left);
        try std.testing.expectEqual(b.right, back.right);
        try std.testing.expectEqual(b.up, back.up);
        try std.testing.expectEqual(b.down, back.down);
        // The OS chord never reaches the race.
        try std.testing.expectEqual(b.start and !b.select, back.start);
    }
}

test "the link World: tracks by rules byte, machines by slot, hashes agree" {
    var a: World = undefined;
    var b: World = undefined;
    reset(&a, .{4}, .{ 2, 2 }, 99);
    reset(&b, .{4}, .{ 2, 2 }, 99);
    try std.testing.expect(track_of(.{4}) == &track.rack_row_7);
    try std.testing.expectEqual([2]u8{ world.player, world.guest }, a.humans);
    try std.testing.expectEqual(@as(u32, 99), a.rng);
    try std.testing.expectEqual(G.hash(&a), G.hash(&b));
    var k: u32 = 0;
    while (k < 400) : (k += 1) {
        const l: u8 = if (k % 50 < 20) bit_left else 0;
        const r: u8 = if (k % 70 < 9) bit_right else 0;
        const in = [2]u8{ bit_a | l, bit_a | r };
        G.simulate(&a, in);
        G.simulate(&b, in);
    }
    try std.testing.expect(sim.worlds_equal(&a, &b));
    try std.testing.expectEqual(G.hash(&a), G.hash(&b));
    b.machines[7].x +%= 1 << 16;
    try std.testing.expect(G.hash(&a) != G.hash(&b));
    G.hand_over(&a, 1);
    try std.testing.expect(a.ai_drives[1] and !a.ai_drives[0]);
    try std.testing.expect(G.picks_ok(0, 0) and G.picks_ok(4, 1) and !G.picks_ok(5, 0));
}
