//! New for Snouty GC (M1 Track B): the roster's words and looks (SPEC 4.1),
//! render-side only: bios for the racer select, the taunt a racer pops on
//! a kill, the line they pop when wrecked, the weapon names, the livery
//! colours of the HUD (minimap dots, the select's name and bars; ASSETS.md
//! "Minimap colour") and the select's stat bars. Indexed by racer id 0..5
//! in SPEC 4.1 order (racers.zig). No cart API, so the host tests check it.
const world = @import("world.zig");

pub const count = 6;

pub const Text = struct {
    /// Four lines of at most 19 characters (the 8x8 font across 152 px).
    bio: [4][]const u8,
    /// Popped (with the racer's half-scale portrait) when they wreck the
    /// car this badge follows.
    taunt: []const u8,
    /// Popped when the followed car wrecks them.
    wrecked: []const u8,
};

pub const roster = [count]Text{
    .{
        .bio = .{ "ATE BUGS. NOW HUNTS", "THEM. LOST AN EYE", "TO A HEISENBUG IN", "PROD. IT KNOWS." },
        .taunt = "FOUND YOU.",
        .wrecked = "CAN'T REPRO...",
    },
    .{
        .bio = .{ "RACING SINCE THE", "MAINFRAMES. HAS", "DECLINED EVERY", "UPDATE. EVERY ONE." },
        .taunt = "BACK IN MY DAY.",
        .wrecked = "WORKS ON MY BOX.",
    },
    .{
        .bio = .{ "COPIED EVERY GUN", "FROM A FORUM. READ", "NONE OF THE DOCS.", "9 OF 10 FINGERS." },
        .taunt = "GG EZ",
        .wrecked = "LAG!!",
    },
    .{
        .bio = .{ "NO SLEEP SINCE THE", "MACHINES WOKE UP.", "RUNS ON SPITE AND", "RECYCLED COFFEE." },
        .taunt = "TICKET CLOSED.",
        .wrecked = "WHO TOUCHED PROD?",
    },
    .{
        .bio = .{ "NOBODY SAW ROOTKIT", "GET IN THE CAR.", "ROOTKIT WAS ALWAYS", "IN THE CAR." },
        .taunt = "I WAS HERE FIRST.",
        .wrecked = "...I PERSIST.",
    },
    .{
        .bio = .{ "14 COUSINS, ONE", "BUS, A MAJORITY", "VOTE ON EVERY TURN.", "TURNS ARE LATE." },
        .taunt = "WE ARE MANY.",
        .wrecked = "WHO VOTED LEFT?",
    },
};

/// Livery colours (0xRRGGBB) for the HUD: distinct on the minimap (purple,
/// blue, lime, red, green, yellow), and the select's name, frame and bars.
/// They match the art track's car sheets (ASSETS.md); racers.zig keeps
/// its M0 placeholder liveries for the sim side.
pub const color = [count]u32{ 0x8E42DE, 0x4A7AD0, 0x7CD040, 0xE04040, 0x40F070, 0xF0C030 };

/// The select's stat bars, 0..8 (SPEC 8.1): SPD and ARM follow the chassis
/// (SPEC 4.2: THIN CLIENT fast and fragile, MAINFRAME slow and armored),
/// DMG is a feel for the loadout. For show only; tuning.zig rules.
pub const Stats = struct { spd: u8, arm: u8, dmg: u8 };
pub const stats = [count]Stats{
    .{ .spd = 6, .arm = 5, .dmg = 7 }, // SNOUTY, WORKSTATION, SPEAR PHISH + LOGIC BOMB
    .{ .spd = 4, .arm = 8, .dmg = 6 }, // LEGACY, MAINFRAME, BROADCAST + FIREWALL
    .{ .spd = 8, .arm = 3, .dmg = 4 }, // KIDDIE, THIN CLIENT, PING + MEMORY LEAK
    .{ .spd = 6, .arm = 5, .dmg = 6 }, // SYSADMIN, WORKSTATION, FIBER LANCE + BIT ROT
    .{ .spd = 8, .arm = 3, .dmg = 5 }, // ROOTKIT, THIN CLIENT, FIBER LANCE + MEMORY LEAK
    .{ .spd = 4, .arm = 8, .dmg = 4 }, // BOTNET, MAINFRAME, PING + BIT ROT
};

pub fn front_name(f: world.Front) []const u8 {
    return switch (f) {
        .ping => "PING",
        .broadcast => "BROADCAST",
        .lance => "FIBER LANCE",
        .phish => "SPEAR PHISH",
    };
}

pub fn rear_name(r: world.Rear) []const u8 {
    return switch (r) {
        .leak => "MEMORY LEAK",
        .bomb => "LOGIC BOMB",
        .rot => "BIT ROT",
        .firewall => "FIREWALL",
    };
}

/// Splits `line` for a pop-up `width` characters wide: the first part ends
/// at the last space that fits (or is the whole line). Returns the split
/// index; the second part starts after the space.
pub fn wrap(line: []const u8, width: usize) usize {
    if (line.len <= width) return line.len;
    var i: usize = width;
    while (i > 0) : (i -= 1) {
        if (line[i] == ' ') return i;
    }
    return width;
}

test "bios fit four lines of 19 characters, pop-up lines wrap in two" {
    const std = @import("std");
    for (roster) |r| {
        for (r.bio) |line| try std.testing.expect(line.len <= 19);
        for ([_][]const u8{ r.taunt, r.wrecked }) |line| {
            const k = wrap(line, 15);
            try std.testing.expect(k <= 15);
            const rest = if (k < line.len) line[k + 1 ..] else "";
            try std.testing.expect(rest.len <= 15);
        }
    }
    try std.testing.expectEqual(@as(usize, 11), wrap("WHO TOUCHED PROD?", 15));
    try std.testing.expectEqual(@as(usize, 5), wrap("GG EZ", 15));
}
