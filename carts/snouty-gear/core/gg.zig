//! Snouty Gear core: the whole Game Gear in one struct, badge-agnostic.
//! No cart-api, no floats, no allocator, no clock, no randomness: the only
//! input is the pad byte given to `step_frame`. SPEC.md sections 3, 4, 7;
//! PLAN.md "Frozen for M1: core/gg.zig" is the interface contract.
//!
//!
//! `step_frame` runs the Z80 one instruction at a time and lets the VDP
//! catch up after each (it renders every visible line at the line's start
//! through `line_sink` and raises the interrupts), until the VDP reports
//! the end of line 261.
const std = @import("std");

pub const z80 = @import("z80.zig");
pub const bus = @import("bus.zig");
pub const vdp = @import("vdp.zig");
pub const psg = @import("psg.zig");
pub const rom = @import("rom.zig");

pub const Rom = rom.Rom;
pub const LineSink = vdp.LineSink;
pub const ByteSink = bus.ByteSink;
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
    /// T-states the last `step_frame` ran (about `frame_tstates`; the
    /// overshoot past line 261 stays in the VDP's line position, so the
    /// next frame starts that much in). Diagnostic only, not in keyframes.
    frame_t: u32 = 0,
    /// Frames stepped since reset (wraps).
    frame_count: u32 = 0,
    /// Interrupts the CPU accepted since reset, split by what the VDP was
    /// raising at the time (frame IRQ: status bit 7 set; otherwise the line
    /// IRQ). Diagnostics for the frontend's `debug_*` exports; console state
    /// because it is deterministic and cheap to copy.
    irq_frame_count: u32 = 0,
    irq_line_count: u32 = 0,

    /// Not console state: excluded from keyframes, kept by `reset`.
    rom: Rom,
    /// Where rendered lines go; set once by the frontend.
    line_sink: ?LineSink = null,
    /// Where SDSC debug console bytes (port FD writes) go; host tests only.
    /// Not console state: excluded from keyframes, kept by `reset`.
    console_sink: ?ByteSink = null,

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
        gg.console_sink = null;
        gg.reset();
    }

    /// Post-BIOS state (SPEC.md section 3): SP DFF0, IM 1, mapper slots
    /// 0/1/2 (wrapped to the ROM's size), VDP registers as the BIOS leaves
    /// them, memory zeroed. Field by field so no console-sized temporary is
    /// built. Keeps `rom`, `line_sink` and `console_sink`.
    pub fn reset(gg: *Gg) void {
        gg.cpu.reset();
        @memset(&gg.ram, 0);
        @memset(&gg.cart_ram, 0);
        gg.mapper = .{};
        gg.mapper.sync(&gg.rom);
        gg.mem_control = 0;
        gg.io_control = 0xFF;
        gg.vdp.reset();
        gg.psg.reset();
        gg.pad = 0;
        gg.frame_t = 0;
        gg.frame_count = 0;
        gg.irq_frame_count = 0;
        gg.irq_line_count = 0;
    }

    /// One Game Gear frame (262 lines), exactly one call per badge frame.
    /// `pad` is held for the whole frame.
    pub fn step_frame(gg: *Gg, pad: u8) void {
        gg.pad = pad;
        const sink = gg.line_sink;
        var b = gg.bus_for();
        var ft: u32 = 0;
        while (true) {
            const iff1 = gg.cpu.iff1;
            const t = gg.cpu.step(&b);
            ft += t;
            // Acceptance clears IFF1 and lands on RST 38h (IM 1). A DI at
            // 0037 would be miscounted; nothing does that.
            if (iff1 and !gg.cpu.iff1 and gg.cpu.pc == 0x0038) gg.count_irq();
            if (gg.vdp.tick(t, sink)) break;
        }
        gg.frame_t = ft;
        gg.frame_count +%= 1;
    }

    fn count_irq(gg: *Gg) void {
        if (gg.vdp.status & 0x80 != 0) gg.irq_frame_count +%= 1 else gg.irq_line_count +%= 1;
    }

    pub fn bus_for(gg: *Gg) bus.Bus {
        return .{ .gg = gg };
    }

    // ---- Keyframes (SPEC.md section 10) ----

    /// The console minus `rom` (immutable, not ours), `line_sink` and
    /// `console_sink` (not console state) and `frame_t` (diagnostic). M2 replaces this full copy with deltas; the shape
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
        irq_frame_count: u32,
        irq_line_count: u32,
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
        out.irq_frame_count = gg.irq_frame_count;
        out.irq_line_count = gg.irq_line_count;
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
        gg.irq_frame_count = k.irq_frame_count;
        gg.irq_line_count = k.irq_line_count;
        gg.frame_t = 0;
    }
};

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
