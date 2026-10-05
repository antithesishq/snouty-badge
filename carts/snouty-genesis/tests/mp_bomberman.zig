//! Mega Bomberman (Sega 1994, header serial "GM MK-1573-00", a Team Player
//! game) with four pads: the real-game check of the Team Player model.
//! Local ROM only (`tests/roms/genesis/MegaBomberman.md` or
//! `~/roms/genesis/MegaBomberman.md`, never committed); skipped when absent.
//!
//! The script (frames at 60 Hz, found by dumping frames): Start skips the
//! intro (1000), the title menu shows at ~1350, Down + Start picks BATTLE
//! GAME (1400, 1420), Down Down + Start picks 4 combatants (1750-1800)
//! with all four slots reading MAN (four pads seen through the tap), Start
//! keeps 3 games (2400), pad 1 walks the top-row cursor to OK and presses
//! C (2900-2980), C takes the first stage (3300); the battle runs from
//! ~3850. Then from one saved state each pad alone holds a direction for
//! 90 frames: all four players must move (four different states, none
//! equal to the idle run), so each pad reaches its own player.
//!
//! Imported by tests/all.zig (the full core, Z80 on) and
//! tests/ram_variant.zig (the RAM cart's core: the Z80 stub).
const std = @import("std");
const core = @import("core");
const Md = core.Md;
const Pad = core.Pad;
const mpd = @import("mp_determinism.zig");

const Step = struct { from: u32, to: u32, pad: u3, bits: u16 };

/// Menu inputs, pad 1 unless noted (see the top).
pub const script = [_]Step{
    .{ .from = 1000, .to = 1004, .pad = 0, .bits = Pad.start },
    .{ .from = 1400, .to = 1404, .pad = 0, .bits = Pad.down },
    .{ .from = 1420, .to = 1424, .pad = 0, .bits = Pad.start },
    .{ .from = 1750, .to = 1754, .pad = 0, .bits = Pad.down },
    .{ .from = 1770, .to = 1774, .pad = 0, .bits = Pad.down },
    .{ .from = 1800, .to = 1804, .pad = 0, .bits = Pad.start },
    .{ .from = 2400, .to = 2404, .pad = 0, .bits = Pad.start },
    .{ .from = 2900, .to = 2904, .pad = 0, .bits = Pad.right },
    .{ .from = 2920, .to = 2924, .pad = 0, .bits = Pad.right },
    .{ .from = 2940, .to = 2944, .pad = 0, .bits = Pad.right },
    .{ .from = 2960, .to = 2964, .pad = 0, .bits = Pad.right },
    .{ .from = 2980, .to = 2984, .pad = 0, .bits = Pad.c },
    .{ .from = 3300, .to = 3304, .pad = 0, .bits = Pad.c },
};

/// The battle is running from here.
pub const battle_frame = 3900;

pub fn pads_at(f: u32) core.Pads {
    var p: core.Pads = @splat(0);
    for (script) |s| {
        if (f >= s.from and f < s.to) p[s.pad] |= s.bits;
    }
    return p;
}

/// Each player's way out of its corner (pad 1 top left, pad 2 bottom
/// right, pad 3 top right, pad 4 bottom left).
const moves = [4]u16{ Pad.right, Pad.up, Pad.down, Pad.right };

pub fn load(a: std.mem.Allocator) ?[]u8 {
    return mpd.load(a, "tests/roms/genesis/MegaBomberman.md", "MegaBomberman.md");
}

test "mp-bomberman: Team Player detected, four human players each move their own bomber" {
    const a = std.testing.allocator;
    const rom = load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const md = try a.create(Md);
    defer a.destroy(md);
    md.init_in_place(core.RomSource.from_slice(rom));
    try std.testing.expectEqual(core.ports.Kind.tap1, md.setup.cfg.kind);

    var f: u32 = 0;
    while (f < battle_frame) : (f += 1) {
        const p = pads_at(f);
        md.step_frame_pads(&p, false);
    }
    const kf = try a.create(Md.Keyframe);
    defer a.destroy(kf);
    md.snapshot(kf);

    // The sprite table (VRAM, H32: register 5 bits 0-6) after each run: a
    // player that moved has its sprites elsewhere, which a pad byte merely
    // stored in work RAM would not do.
    var h: [5]u64 = undefined;
    for (0..5) |k| {
        md.restore(kf);
        var p: core.Pads = @splat(0);
        if (k < 4) p[k] = moves[k];
        for (0..90) |_| md.step_frame_pads(&p, false);
        const sat: usize = @as(usize, md.vdp.regs[5] & 0x7F) << 9;
        h[k] = std.hash.Wyhash.hash(0, md.vdp.vram[sat..][0..@min(64 * 8, 0x10000 - sat)]);
    }
    for (0..5) |i| for (i + 1..5) |j| {
        if (h[i] == h[j]) {
            std.debug.print("\nmp-bomberman: runs {d} and {d} (4 = idle) leave the sprites alike\n", .{ i, j });
            return error.TestUnexpectedResult;
        }
    };
    std.debug.print("\nmp-bomberman: battle with four MAN players at frame {d}, each pad moved its own bomber\n", .{battle_frame});
}
