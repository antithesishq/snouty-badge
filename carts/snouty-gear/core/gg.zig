//! Snouty Gear core: the whole Game Gear in one struct, badge-agnostic.
//! No cart-api, no floats, no allocator, no clock, no randomness: the only
//! input is the pad byte given to `step_frame`. SPEC.md sections 3, 4, 7;
//! PLAN.md "Frozen for M1: core/gg.zig" is the interface contract.
//!
//! M0: the struct and its subsystems have their final shape, but
//! `step_frame` does not emulate yet. It draws a moving test pattern
//! through `line_sink` so the frontend's video path is exercised; M1
//! replaces it with the Z80/VDP loop.
const std = @import("std");

pub const z80 = @import("z80.zig");
pub const bus = @import("bus.zig");
pub const vdp = @import("vdp.zig");
pub const psg = @import("psg.zig");
pub const rom = @import("rom.zig");

pub const Rom = rom.Rom;
pub const LineSink = vdp.LineSink;
pub const Cpu = z80.Z80(bus.Bus);

pub const screen_w = vdp.screen_w;
pub const screen_h = vdp.screen_h;
/// T-states in one NTSC frame (262 lines x 228).
pub const frame_tstates: u32 = vdp.lines_per_frame * vdp.tstates_per_line;

/// Pad byte fed to `step_frame`: bit set = pressed (SPEC.md section 5).
/// Button 1 is the badge's B, button 2 its A (physical position).
pub const Pad = struct {
    pub const up: u8 = 1 << 0;
    pub const down: u8 = 1 << 1;
    pub const left: u8 = 1 << 2;
    pub const right: u8 = 1 << 3;
    pub const b1: u8 = 1 << 4;
    pub const b2: u8 = 1 << 5;
    pub const start: u8 = 1 << 6;
};

/// Cartridge RAM in slot 2. 8 KB covers every ROM section 11 accepts; M1
/// grows it to 32 KB only if romcheck.py shows a target ROM needs more.
pub const cart_ram_size = 0x2000;

pub const Gg = struct {
    // ---- CPU (core/z80.zig) ----
    cpu: Cpu = .{},

    // ---- Memory (core/bus.zig) ----
    /// C000-DFFF, mirrored at E000-FFFF.
    ram: [0x2000]u8 = @splat(0),
    cart_ram: [cart_ram_size]u8 = @splat(0),
    mapper: bus.Mapper = .{},
    /// Port 3E (memory control) and 3F (I/O control): stored, mostly ignored.
    mem_control: u8 = 0,
    io_control: u8 = 0xFF,

    // ---- Subsystems ----
    vdp: vdp.Vdp = .{},
    psg: psg.Psg = .{},
    /// Current pad (Pad bits), set by `step_frame`.
    pad: u8 = 0,

    // ---- Frame bookkeeping ----
    /// T-states run so far in the current `step_frame`.
    frame_t: u32 = 0,
    /// Frames stepped since reset (wraps).
    frame_count: u32 = 0,

    /// Not console state: excluded from keyframes, kept by `reset`.
    rom: Rom,
    /// Where rendered lines go; set once by the frontend.
    line_sink: ?LineSink = null,

    /// A console around `r`, reset to the post-BIOS state. The console is
    /// about 33 KB: on the badge (32 KB stack) use `init_in_place` on a
    /// static instead, so no temporary lands on the stack.
    pub fn init(r: Rom) Gg {
        var gg: Gg = .{ .rom = r };
        gg.reset();
        return gg;
    }

    pub fn init_in_place(gg: *Gg, r: Rom) void {
        gg.rom = r;
        gg.line_sink = null;
        gg.reset();
    }

    /// Post-BIOS state (SPEC.md section 3): SP DFF0, IM 1, mapper slots
    /// 0/1/2, VDP registers as the BIOS leaves them, memory zeroed. Field by
    /// field so no console-sized temporary is built. Keeps `rom` and
    /// `line_sink`.
    pub fn reset(gg: *Gg) void {
        gg.cpu.reset();
        @memset(&gg.ram, 0);
        @memset(&gg.cart_ram, 0);
        gg.mapper = .{};
        gg.mem_control = 0;
        gg.io_control = 0xFF;
        gg.vdp.reset();
        gg.psg.reset();
        gg.pad = 0;
        gg.frame_t = 0;
        gg.frame_count = 0;
    }

    /// One Game Gear frame, exactly one call per badge frame.
    /// M0: the test pattern (`pattern_frame`), no emulation.
    pub fn step_frame(gg: *Gg, pad: u8) void {
        gg.pad = pad;
        pattern_frame(gg);
        gg.frame_t = frame_tstates;
        gg.frame_count +%= 1;
    }

    pub fn bus_for(gg: *Gg) bus.Bus {
        return .{ .gg = gg };
    }

    // ---- Keyframes (SPEC.md section 10) ----

    /// The console minus `rom` (immutable, not ours) and `line_sink` (not
    /// console state). M2 replaces this full copy with deltas; the shape
    /// (`snapshot`/`restore`) stays. Auto layout: compare field by field
    /// (`std.meta.eql`), never as raw bytes.
    pub const Keyframe = struct {
        cpu: Cpu,
        ram: [0x2000]u8,
        cart_ram: [cart_ram_size]u8,
        mapper: bus.Mapper,
        mem_control: u8,
        io_control: u8,
        vdp: vdp.Vdp,
        psg: psg.Psg,
        pad: u8,
        frame_count: u32,
    };

    pub fn snapshot(gg: *const Gg, out: *Keyframe) void {
        out.cpu = gg.cpu;
        out.ram = gg.ram;
        out.cart_ram = gg.cart_ram;
        out.mapper = gg.mapper;
        out.mem_control = gg.mem_control;
        out.io_control = gg.io_control;
        out.vdp = gg.vdp;
        out.psg = gg.psg;
        out.pad = gg.pad;
        out.frame_count = gg.frame_count;
    }

    pub fn restore(gg: *Gg, k: *const Keyframe) void {
        gg.cpu = k.cpu;
        gg.ram = k.ram;
        gg.cart_ram = k.cart_ram;
        gg.mapper = k.mapper;
        gg.mem_control = k.mem_control;
        gg.io_control = k.io_control;
        gg.vdp = k.vdp;
        gg.psg = k.psg;
        gg.pad = k.pad;
        gg.frame_count = k.frame_count;
        gg.frame_t = 0;
    }
};

// ---- M0 test pattern ----

/// 32 test colors, 12-bit ----BBBBGGGGRRRR. Background palette: a rainbow
/// then white, two greys, black; sprite palette: the same at half level.
const test_cram = [32]u16{
    0x00F, 0x08F, 0x0FF, 0x0F8, 0x0F0, 0x8F0, 0xFF0, 0xF80,
    0xF00, 0xF08, 0xF0F, 0x80F, 0xFFF, 0xAAA, 0x555, 0x000,
    0x007, 0x047, 0x077, 0x074, 0x070, 0x470, 0x770, 0x740,
    0x700, 0x704, 0x707, 0x407, 0x777, 0x555, 0x222, 0x000,
};

/// Index of the white and black entries used by the stripe and the box.
const white: u5 = 12;
const black: u5 = 15;
const box_size = 16;

/// Deterministic moving pattern from `frame_count` and `pad`:
/// - 32 vertical bars of 5 px, one per CRAM entry, scrolling left 1 px per
///   frame (4 with Start held);
/// - white diagonal stripes (x + y + 2 * frame) moving up-left;
/// - a 16x16 black box moved by the d-pad (position kept in RAM bytes 0/1,
///   so it is console state and survives snapshot/restore);
/// - button 1 inverts the palette, button 2 rotates it (CRAM changes, so
///   the frontend's Pixel cache rebuild is exercised).
fn pattern_frame(gg: *Gg) void {
    const f = gg.frame_count;
    const pad = gg.pad;

    // Box position.
    var bx = gg.ram[0];
    var by = gg.ram[1];
    if (pad & Pad.left != 0 and bx > 0) bx -= 2;
    if (pad & Pad.right != 0 and bx < screen_w - box_size) bx += 2;
    if (pad & Pad.up != 0 and by > 0) by -= 2;
    if (pad & Pad.down != 0 and by < screen_h - box_size) by += 2;
    gg.ram[0] = bx;
    gg.ram[1] = by;

    // Scroll accumulates in RAM bytes 2/3 so Start speeds it up from here on.
    var scroll: u16 = @as(u16, gg.ram[2]) | @as(u16, gg.ram[3]) << 8;
    scroll +%= if (pad & Pad.start != 0) 4 else 1;
    gg.ram[2] = @truncate(scroll);
    gg.ram[3] = @truncate(scroll >> 8);

    // CRAM.
    const rot: u32 = if (pad & Pad.b2 != 0) f / 4 else 0;
    const inv: u16 = if (pad & Pad.b1 != 0) 0x0FFF else 0;
    for (&gg.vdp.cram, 0..) |*c, i| c.* = test_cram[(i + rot) % 32] ^ inv;

    const sink = gg.line_sink orelse return;
    var line: [screen_w]u5 = undefined;
    const s: u32 = scroll % screen_w;
    for (0..screen_h) |yi| {
        const y: u32 = @intCast(yi);
        for (&line, 0..) |*px, xi| {
            const x: u32 = @intCast(xi);
            var idx: u5 = @intCast(((x + s) / 5) % 32);
            if ((x + y + 2 * f) % 32 < 3) idx = white;
            if (x >= bx and x < @as(u32, bx) + box_size and y >= by and y < @as(u32, by) + box_size) idx = black;
            px.* = idx;
        }
        gg.vdp.line = @intCast(y + 24);
        sink.emit(@intCast(y), &line, &gg.vdp.cram);
    }
    gg.vdp.line = 0;
}

test "keyframe round trip" {
    const data: [0x8000]u8 = @splat(0);
    var gg = Gg.init(Rom.from_slice(&data));
    gg.step_frame(Pad.right);
    var k: Gg.Keyframe = undefined;
    gg.snapshot(&k);
    var gg2 = Gg.init(Rom.from_slice(&data));
    gg2.ram[5] = 0xAA;
    gg2.restore(&k);
    try std.testing.expectEqual(@as(u8, 0), gg2.ram[5]);
    try std.testing.expectEqual(gg.ram[0], gg2.ram[0]);
    try std.testing.expectEqual(gg.frame_count, gg2.frame_count);
}
