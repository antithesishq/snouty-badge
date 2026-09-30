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
pub const ring = @import("ring.zig");
pub const kstore = @import("kstore.zig");

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
    /// Direct ROM pointer for each 1 KB page of 0000-BFFF as the mapper has
    /// it now, null where the bus must take its slow path (cart RAM in slot
    /// 2, a bank without a direct pointer). Derived from `mapper` and `rom`
    /// by `sync_map` (reset, restore, every mapper write); not in keyframes.
    read_map: [48]?[*]const u8 = @splat(null),
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
        gg.sync_map();
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
        // T-states run, from the VDP position: the loop ends on the first
        // wrap to line 0 (a step never crosses two lines), so it ran from
        // (line0, lt0) to (262, lt1). Saves a running sum per instruction.
        const line0: u32 = gg.vdp.line;
        const lt0: u32 = gg.vdp.line_tstates;
        while (true) {
            const iff1 = gg.cpu.iff1;
            const t = @call(.always_inline, Cpu.step, .{ &gg.cpu, &b });
            // Acceptance clears IFF1 and lands on RST 38h (IM 1). A DI at
            // 0037 would be miscounted; nothing does that.
            if (iff1 and !gg.cpu.iff1 and gg.cpu.pc == 0x0038) gg.count_irq();
            if (gg.vdp.tick(t, sink)) break;
        }
        gg.frame_t = (vdp.lines_per_frame - line0) * vdp.tstates_per_line + gg.vdp.line_tstates - lt0;
        gg.frame_count +%= 1;
    }

    /// Rebuild `read_map` from `mapper` and `rom`.
    pub fn sync_map(gg: *Gg) void {
        for (0..3) |s| gg.sync_slot(@intCast(s));
    }

    /// Rebuild the 16 `read_map` pages of slot `s` (0..2). Page 0 is always
    /// bank 0 (the fixed first 1 KB).
    pub fn sync_slot(gg: *Gg, s: u2) void {
        const pages = gg.read_map[@as(usize, s) * 16 ..][0..16];
        const bank = gg.rom.banks[gg.mapper.bank[s]];
        for (pages, 0..) |*page, k| {
            page.* = if (s == 2 and gg.mapper.control & 0x08 != 0)
                null
            else if (bank) |p| p + k * 0x400 else null;
        }
        if (s == 0) gg.read_map[0] = gg.rom.banks[0];
    }

    fn count_irq(gg: *Gg) void {
        if (gg.vdp.status & 0x80 != 0) gg.irq_frame_count +%= 1 else gg.irq_line_count +%= 1;
    }

    pub fn bus_for(gg: *Gg) bus.Bus {
        return .{ .gg = gg };
    }

    // ---- Keyframes (SPEC.md section 10) ----

    /// The console state that is neither RAM, VRAM nor cart RAM, packed for
    /// the page store (`kstore`): CPU, mapper, memory/IO control, the VDP
    /// minus VRAM, PSG, pad and the frame counters. Padding is zeroed by
    /// `save_small` so equal states compare equal byte for byte (the store
    /// relies on that for page sharing, not for correctness). Compare two
    /// `Small`s field by field in tests (`std.meta.eql`), never as bytes.
    pub const Small = struct {
        cpu: Cpu,
        mapper: bus.Mapper,
        mem_control: u8,
        io_control: u8,
        vdp: vdp.Vdp.State,
        psg: psg.Psg,
        pad: u8,
        frame_count: u32,
        irq_frame_count: u32,
        irq_line_count: u32,
    };

    pub fn save_small(gg: *const Gg, out: *Small) void {
        @memset(std.mem.asBytes(out), 0);
        inline for (@typeInfo(Small).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "vdp")) gg.vdp.save_state(&out.vdp) else @field(out, name) = @field(gg, name);
        }
    }

    /// Apply a `Small`; the caller has already written RAM, VRAM and cart
    /// RAM (`state_regions`). Rebuilds `read_map`, like `restore`.
    pub fn load_small(gg: *Gg, k: *const Small) void {
        inline for (@typeInfo(Small).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "vdp")) gg.vdp.load_state(&k.vdp) else @field(gg, name) = @field(k, name);
        }
        gg.frame_t = 0;
        gg.sync_map();
    }

    /// The console state as byte regions for the page store, in a fixed
    /// order: the packed `small` (caller-owned, filled by `save_small`
    /// before a snapshot and applied with `load_small` after a restore),
    /// RAM, VRAM, cart RAM. `kstore.region_count` regions.
    pub fn state_regions(gg: *Gg, small: *Small) [kstore.region_count][]u8 {
        return .{ std.mem.asBytes(small), &gg.ram, &gg.vdp.vram, &gg.cart_ram };
    }

    /// The console minus `rom` (immutable, not ours), `read_map` (derived),
    /// `line_sink` and `console_sink` (not console state) and `frame_t`
    /// (diagnostic). M2 replaces this full copy with deltas; the shape
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
        gg.sync_map();
    }
};

test "small state round trip through state_regions" {
    const data: [0x8000]u8 = @splat(0);
    var gg = Gg.init(Rom.from_slice(&data));
    gg.step_frame(Pad.right);
    gg.vdp.vram[0x123] = 0x45;
    var small: Gg.Small = undefined;
    gg.save_small(&small);
    var full: Gg.Keyframe = undefined;
    gg.snapshot(&full);
    const src = gg.state_regions(&small);

    var gg2 = Gg.init(Rom.from_slice(&data));
    var small2: Gg.Small = undefined;
    const dst = gg2.state_regions(&small2);
    for (src, dst) |a, b| @memcpy(b, a);
    gg2.load_small(&small2);
    var full2: Gg.Keyframe = undefined;
    gg2.snapshot(&full2);
    inline for (@typeInfo(Gg.Keyframe).@"struct".field_names) |name| {
        try std.testing.expect(std.meta.eql(@field(full, name), @field(full2, name)));
    }
    try std.testing.expectEqual(@as(u8, 0x45), gg2.vdp.vram[0x123]);
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
