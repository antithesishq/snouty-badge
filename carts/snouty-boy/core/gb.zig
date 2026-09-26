//! Snouty Boy core: the whole Game Boy in one struct, badge-agnostic.
//! No cart-api, no floats, no allocator, no clock, no randomness: the only
//! input is the joypad byte given to `step_frame`. See SPEC.md sections 3,
//! 4, 7 and 10.3. PLAN.md has the M1 file ownership and interface contract.
const std = @import("std");

pub const cpu = @import("cpu.zig");
pub const mmu = @import("mmu.zig");
pub const ppu = @import("ppu.zig");
pub const timer = @import("timer.zig");
pub const apu = @import("apu.zig");
pub const serial = @import("serial.zig");
pub const joypad = @import("joypad.zig");
pub const ring = @import("ring.zig");

pub const screen_w = 160;
pub const screen_h = 144;
/// M-cycles in one Game Boy frame (70,224 T-cycles / 4).
pub const frame_m_cycles: u32 = 17_556;

/// Interrupt bits in IF (0xFF0F) and IE (0xFFFF).
pub const Irq = struct {
    pub const vblank: u8 = 1 << 0;
    pub const stat: u8 = 1 << 1;
    pub const timer: u8 = 1 << 2;
    pub const serial: u8 = 1 << 3;
    pub const joypad: u8 = 1 << 4;
};

/// I/O register offsets from 0xFF00 (index into `Gb.io`).
pub const Reg = struct {
    pub const p1: u8 = 0x00;
    pub const sb: u8 = 0x01;
    pub const sc: u8 = 0x02;
    pub const div: u8 = 0x04;
    pub const tima: u8 = 0x05;
    pub const tma: u8 = 0x06;
    pub const tac: u8 = 0x07;
    pub const if_: u8 = 0x0F;
    pub const nr10: u8 = 0x10;
    pub const nr52: u8 = 0x26;
    pub const lcdc: u8 = 0x40;
    pub const stat: u8 = 0x41;
    pub const scy: u8 = 0x42;
    pub const scx: u8 = 0x43;
    pub const ly: u8 = 0x44;
    pub const lyc: u8 = 0x45;
    pub const dma: u8 = 0x46;
    pub const bgp: u8 = 0x47;
    pub const obp0: u8 = 0x48;
    pub const obp1: u8 = 0x49;
    pub const wy: u8 = 0x4A;
    pub const wx: u8 = 0x4B;
};

/// One rendered scanline: 160 final DMG shades, 0 = lightest, 3 = darkest
/// (BGP/OBP already applied). Delivered by the PPU as each visible line is
/// rendered, in order 0..143, once per frame while the LCD is on.
pub const LineSink = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, ly: u8, line: *const [screen_w]u8) void,

    pub fn emit(self: LineSink, ly: u8, line: *const [screen_w]u8) void {
        self.func(self.ctx, ly, line);
    }
};

/// Joypad byte fed to `step_frame`: bit set = pressed.
pub const Pad = struct {
    pub const right: u8 = 1 << 0;
    pub const left: u8 = 1 << 1;
    pub const up: u8 = 1 << 2;
    pub const down: u8 = 1 << 3;
    pub const a: u8 = 1 << 4;
    pub const b: u8 = 1 << 5;
    pub const select: u8 = 1 << 6;
    pub const start: u8 = 1 << 7;
};

pub const Gb = struct {
    // ---- CPU (owner: core/cpu.zig) ----
    cpu: cpu.Cpu = .{},

    // ---- Memory (owner: core/mmu.zig) ----
    rom: []const u8,
    mbc: mmu.Mbc = .{},
    vram: [0x2000]u8 = @splat(0),
    wram: [0x2000]u8 = @splat(0),
    oam: [0xA0]u8 = @splat(0),
    hram: [0x7F]u8 = @splat(0),
    /// External cart RAM; at most 8 KB is supported (SPEC.md section 11).
    cart_ram: [0x2000]u8 = @splat(0),
    /// Raw I/O registers 0xFF00..0xFF7F. Subsystems keep their register
    /// values here so that snapshot/restore is a plain struct copy.
    io: [0x80]u8 = @splat(0),
    ie: u8 = 0,

    // ---- Subsystems ----
    ppu: ppu.Ppu = .{},
    timer: timer.Timer = .{},
    apu: apu.Apu = .{},
    serial: serial.Serial = .{},
    /// Current joypad state (Pad bits), set by `step_frame`.
    pad: u8 = 0,

    // ---- Frame bookkeeping (owner: core/gb.zig) ----
    /// M-cycles run so far in the current `step_frame` call.
    frame_cycles: u32 = 0,
    /// Set by the PPU when it enters VBlank; cleared by `step_frame`.
    vblank_hit: bool = false,
    /// Total frames stepped since reset (wraps).
    frame_count: u32 = 0,

    /// Where rendered lines go. Not part of the console state: excluded
    /// from keyframes by `snapshot`, set once by the frontend.
    line_sink: ?LineSink = null,

    /// Construct a console around a ROM image and reset it to the post-boot
    /// DMG state (SPEC.md section 3). `rom` must outlive the Gb.
    pub fn init(rom: []const u8) Gb {
        var gb: Gb = .{ .rom = rom };
        gb.reset();
        return gb;
    }

    /// Post-boot DMG state. Memory is zeroed (SPEC.md 10.3).
    pub fn reset(gb: *Gb) void {
        const rom = gb.rom;
        const sink = gb.line_sink;
        gb.* = .{ .rom = rom, .line_sink = sink };
        gb.mbc = mmu.Mbc.from_header(rom);
        cpu.reset(gb);
        mmu.reset_io(gb);
        ppu.reset(gb);
        timer.reset(gb);
        apu.reset(gb);
    }

    /// Run one frame: until the PPU enters VBlank, or, with the LCD off,
    /// for `frame_m_cycles` M-cycles. Exactly one call per badge frame.
    pub fn step_frame(gb: *Gb, pad: u8) void {
        gb.pad = pad;
        joypad.update(gb);
        gb.frame_cycles = 0;
        gb.vblank_hit = false;
        while (!gb.vblank_hit and gb.frame_cycles < frame_m_cycles * 2) {
            const m = cpu.step(gb);
            gb.tick(m);
            if (!ppu.lcd_on(gb) and gb.frame_cycles >= frame_m_cycles) break;
        }
        gb.frame_count +%= 1;
    }

    /// Advance every subsystem by `m` M-cycles after an instruction.
    pub inline fn tick(gb: *Gb, m: u8) void {
        gb.frame_cycles += m;
        timer.tick(gb, m);
        ppu.tick(gb, m);
        mmu.tick_dma(gb, m);
        apu.tick(gb, m);
        serial.tick(gb, m);
    }

    pub inline fn request_irq(gb: *Gb, bit: u8) void {
        gb.io[Reg.if_] |= bit;
    }

    pub inline fn read8(gb: *Gb, addr: u16) u8 {
        return mmu.read8(gb, addr);
    }

    pub inline fn write8(gb: *Gb, addr: u16, v: u8) void {
        mmu.write8(gb, addr, v);
    }

    // ---- Keyframes (SPEC.md section 10) ----

    /// Everything but `rom` (immutable) and `line_sink` (not console state).
    /// Cart RAM is stored in full (8 KB); see `KeyframeWith` for a smaller
    /// keyframe when the ROM header declares no cart RAM.
    pub const Keyframe = KeyframeWith(0x2000);

    /// A keyframe holding the first `ram_len` bytes of cart RAM. The
    /// frontend knows the ROM at compile time and uses
    /// `KeyframeWith(mmu.cart_ram_len(rom))`: a game without RAM never
    /// touches `cart_ram` (`Mbc.ram_active` needs `has_ram`) and a 2 KB RAM
    /// is mirrored (`Mbc.ram_mask`), so the bytes past `ram_len` never
    /// change and up to 8 KB per keyframe is saved (SPEC.md 13). `restore`
    /// leaves bytes past `ram_len` untouched.
    ///
    /// Auto-layout struct: padding bytes are undefined, so compare two
    /// keyframes field by field (`std.meta.eql`), never as raw bytes.
    pub fn KeyframeWith(comptime ram_len: usize) type {
        if (ram_len > 0x2000) @compileError("cart RAM is at most 8 KB");
        return struct {
            pub const cart_ram_len = ram_len;

            cpu: cpu.Cpu,
            mbc: mmu.Mbc,
            vram: [0x2000]u8,
            wram: [0x2000]u8,
            oam: [0xA0]u8,
            hram: [0x7F]u8,
            cart_ram: [ram_len]u8,
            io: [0x80]u8,
            ie: u8,
            ppu: ppu.Ppu,
            timer: timer.Timer,
            apu: apu.Apu,
            serial: serial.Serial,
            pad: u8,
            frame_count: u32,
        };
    }

    /// Copy the console into `out`, a `*Keyframe` or `*KeyframeWith(n)`.
    pub fn snapshot(gb: *const Gb, out: anytype) void {
        const K = @typeInfo(@TypeOf(out)).pointer.child;
        out.* = .{
            .cpu = gb.cpu,
            .mbc = gb.mbc,
            .vram = gb.vram,
            .wram = gb.wram,
            .oam = gb.oam,
            .hram = gb.hram,
            .cart_ram = gb.cart_ram[0..K.cart_ram_len].*,
            .io = gb.io,
            .ie = gb.ie,
            .ppu = gb.ppu,
            .timer = gb.timer,
            .apu = gb.apu,
            .serial = gb.serial,
            .pad = gb.pad,
            .frame_count = gb.frame_count,
        };
    }

    /// Put a keyframe (`*const Keyframe` or `*const KeyframeWith(n)`) back.
    pub fn restore(gb: *Gb, k: anytype) void {
        const K = @typeInfo(@TypeOf(k)).pointer.child;
        gb.cpu = k.cpu;
        gb.mbc = k.mbc;
        gb.vram = k.vram;
        gb.wram = k.wram;
        gb.oam = k.oam;
        gb.hram = k.hram;
        gb.cart_ram[0..K.cart_ram_len].* = k.cart_ram;
        gb.io = k.io;
        gb.ie = k.ie;
        gb.ppu = k.ppu;
        gb.timer = k.timer;
        gb.apu = k.apu;
        gb.serial = k.serial;
        gb.pad = k.pad;
        gb.frame_count = k.frame_count;
        gb.frame_cycles = 0;
        gb.vblank_hit = false;
    }
};

test "keyframe round trip is exact" {
    const rom: [0x8000]u8 = @splat(0);
    var gb = Gb.init(&rom);
    var k: Gb.Keyframe = undefined;
    gb.snapshot(&k);
    var gb2 = Gb.init(&rom);
    gb2.wram[5] = 0xAA;
    gb2.restore(&k);
    try std.testing.expectEqual(@as(u8, 0), gb2.wram[5]);
}
