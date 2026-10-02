//! Serial port unit tests: the stub answers an internal-clock transfer at
//! once and leaves an external-clock one pending forever (no cable).
//! Tetris and Tetris DX probe the link port with SC=0x80 on the title
//! screen and ignore the joypad while they believe a peer answered.
const std = @import("std");
const core = @import("core");
const Gb = core.Gb;

const expectEqual = std.testing.expectEqual;

var test_ram: [Gb.max_cart_ram]u8 = undefined;
var dmg_rom: [0x8000]u8 = @splat(0);
var cgb_rom: [0x8000]u8 = @splat(0);

fn new_gb(model: core.Model) !*Gb {
    const rom = if (model == .cgb) &cgb_rom else &dmg_rom;
    rom[0x143] = if (model == .cgb) 0x80 else 0x00;
    // Gb is ~60 KB; keep it off the test thread's stack.
    const gb = try std.testing.allocator.create(Gb);
    gb.* = Gb.init_slice(rom, model, &test_ram);
    return gb;
}

fn free_gb(gb: *Gb) void {
    std.testing.allocator.destroy(gb);
}

test "serial: internal clock completes at once with 0xFF and an interrupt" {
    const gb = try new_gb(.dmg);
    defer free_gb(gb);
    gb.write8(0xFF0F, 0x00);
    gb.write8(0xFF01, 0x42);
    gb.write8(0xFF02, 0x81);
    try expectEqual(@as(u8, 0xFF), gb.read8(0xFF01));
    try expectEqual(@as(u8, 0x7F), gb.read8(0xFF02)); // bit 7 clear: done
    try expectEqual(@as(u8, core.Irq.serial), gb.read8(0xFF0F) & 0x1F);
    try std.testing.expectEqualStrings("\x42", gb.serial.text());
}

test "serial: external clock never completes and raises no interrupt" {
    inline for (.{ core.Model.dmg, core.Model.cgb }) |model| {
        const gb = try new_gb(model);
        defer free_gb(gb);
        gb.write8(0xFF0F, 0x00);
        gb.write8(0xFF01, 0x55);
        gb.write8(0xFF02, 0x80);
        for (0..8) |_| gb.step_frame(0);
        try expectEqual(@as(u8, 0x55), gb.read8(0xFF01));
        try expectEqual(@as(u8, 0x80), gb.read8(0xFF02) & 0x81); // still pending
        try expectEqual(@as(u8, 0), gb.read8(0xFF0F) & core.Irq.serial);
        try expectEqual(@as(usize, 0), gb.serial.text().len);
    }
}
