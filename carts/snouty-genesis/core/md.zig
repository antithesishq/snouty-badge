//! Snouty Genesis core: the whole Sega Genesis (Mega Drive, NTSC model 1)
//! in one struct, badge-agnostic. No cart-api, no floats, no allocator, no
//! clock, no randomness: the only input is the pad word given to
//! `step_frame`. SPEC.md sections 3, 7, 10; PLAN.md "Frozen for M1:
//! core/md.zig" is the interface contract.
//!
//! M0 scaffold: every piece of console state at its real size (SPEC.md
//! section 10), `reset`, `Keyframe` with `snapshot`/`restore`, and a stub
//! `step_frame` that steps the VDP line counter through a frame and, when
//! asked to render, pushes a test pattern through `line_sink`. M1 Track C
//! replaces the stub with the frame loop of the contract (68000 per line,
//! Z80 slice, `vdp.end_line`).
//!
//! Byte order per array: `work_ram`, `z80_ram` and `vdp.vram` hold bytes at
//! their bus addresses (the 68000's big-endian word order); CRAM and VSRAM
//! are native u16 words. M1 documents any change here.

pub const m68k = @import("m68k.zig");
pub const bus = @import("bus.zig");
pub const z80bus = @import("z80bus.zig");
pub const vdp = @import("vdp.zig");
pub const ym2612 = @import("ym2612.zig");
pub const psg = @import("psg.zig");
pub const rom = @import("rom.zig");
pub const tunables = @import("tunables.zig");

pub const RomSource = rom.RomSource;
pub const LineSink = vdp.LineSink;
pub const Cpu = m68k.M68k(bus.Bus);
pub const Z80 = z80bus.Cpu;

pub const out_w = vdp.out_w;
pub const out_h = vdp.out_h;

/// Pad word fed to `step_frame`: bit set = pressed (SPEC.md section 5).
/// Three-button pad; the frontend maps the badge's buttons onto it.
pub const Pad = struct {
    pub const up: u16 = 1 << 0;
    pub const down: u16 = 1 << 1;
    pub const left: u16 = 1 << 2;
    pub const right: u16 = 1 << 3;
    pub const a: u16 = 1 << 4;
    pub const b: u16 = 1 << 5;
    pub const c: u16 = 1 << 6;
    pub const start: u16 = 1 << 7;
};

/// The one voice the badge plays (SPEC.md section 9): frequency in Hz and
/// loudness, 0 quietest audible .. 15 loudest (a PSG channel's is
/// 15 - attenuation; the FM scale is Track D's call, documented in
/// ym2612.zig).
pub const Tone = struct { hz: u16, level: u4 };

/// Z80 bus arbiter (SPEC.md section 9).
pub const Arbiter = struct {
    /// A11100: the 68000 asked for the Z80's bus (the Z80 stops).
    busreq: bool = false,
    /// A11200: the Z80 and the YM2612 are held in reset. Asserted at power
    /// on until the 68000 releases it.
    z80_reset: bool = true,
};

/// Version register and the two pad ports (A10000-A1001F).
pub const Io = struct {
    /// A10003/5/7: data registers of ports 1, 2 and EXT (TH is bit 6).
    data: [3]u8 = @splat(0x7F),
    /// A10009/B/D: control registers (bit set = pin is an output).
    ctrl: [3]u8 = @splat(0),
};

pub const Md = struct {
    // ---- 68000 side ----
    cpu: Cpu = .{},
    /// FF0000-FFFFFF, mirrored from E00000.
    work_ram: [0x10000]u8 = @splat(0),
    vdp: vdp.Vdp = .{},
    io: Io = .{},
    /// Current pad (`Pad` bits), set by `step_frame`.
    pad: u16 = 0,

    // ---- Z80 side ----
    z80: Z80 = .{},
    /// A00000-A01FFF / Z80 0000-1FFF.
    z80_ram: [0x2000]u8 = @splat(0),
    /// 6000: the bank register, 9 bits shifted in one per write (address
    /// bits 15-23 of the 32 KB window at Z80 8000-FFFF).
    z80_bank: u16 = 0,
    arbiter: Arbiter = .{},
    /// Z80 INT, asserted for one line from V-int.
    z80_int: bool = false,
    ym: ym2612.Ym2612 = .{},
    psg: psg.Psg = .{},

    // ---- Frame bookkeeping ----
    /// Frames stepped since reset (wraps).
    frame_count: u32 = 0,
    /// 68000 cycles the last line overran its share by (carried into the
    /// next line, PLAN.md frame loop).
    m68k_carry: u32 = 0,
    /// Z80 cycles carried over, in `tunables.scale_one` units.
    z80_carry: u32 = 0,

    // ---- Not console state: excluded from keyframes, kept by `reset` ----
    rom: RomSource = .{},
    /// Where rendered rows go; set once by the frontend.
    line_sink: ?LineSink = null,
    // Cartridge SRAM (up to 16 KB, SPEC.md section 11) is not here yet: M1
    // Track C adds it (in `Md` and `Keyframe`) when the bus decodes 200000.

    /// Build the console around `src` in place, reset to power-on. The
    /// console is ~137 KB: always a static, never a stack temporary (32 KB
    /// stack on the badge, 14.7 KB in wasm).
    pub fn init_in_place(md: *Md, src: RomSource) void {
        md.rom = src;
        md.line_sink = null;
        md.reset();
    }

    /// Power-on state: memory zeroed, the 68000 at the reset vector, the
    /// Z80 held in reset. Field by field so no console-sized temporary is
    /// built. Keeps `rom` and `line_sink`.
    pub fn reset(md: *Md) void {
        @memset(&md.work_ram, 0);
        md.vdp.reset();
        md.io = .{};
        md.pad = 0;
        md.z80.reset();
        @memset(&md.z80_ram, 0);
        md.z80_bank = 0;
        md.arbiter = .{};
        md.z80_int = false;
        md.ym.reset();
        md.psg.reset();
        md.frame_count = 0;
        md.m68k_carry = 0;
        md.z80_carry = 0;
        var b = md.bus_for();
        md.cpu.reset(&b);
    }

    /// One Genesis frame (262 lines). `pad` is held for the whole frame;
    /// `render` false skips all line rendering (the first frame of a 60/30
    /// pair). M0 stub: steps the VDP's line counter and draws the test
    /// pattern (`test_pattern`) when `render` is set.
    pub fn step_frame(md: *Md, pad: u16, render: bool) void {
        md.pad = pad;
        var line: u16 = 0;
        while (line < vdp.lines_per_frame) : (line += 1) md.vdp.end_line();
        if (render) if (md.line_sink) |sink| md.test_pattern(sink);
        md.frame_count +%= 1;
    }

    /// The note the badge should play now (SPEC.md section 9): FM wins
    /// ties. M0: both pickers are stubs, so always null.
    pub fn tone(md: *const Md) ?Tone {
        return md.ym.pick() orelse md.psg.pick();
    }

    pub fn bus_for(md: *Md) bus.Bus {
        return .{ .md = md };
    }

    pub fn z80bus_for(md: *Md) z80bus.Z80Bus {
        return .{ .md = md };
    }

    /// The M0 test pattern, 128 rows through `sink`: rows 16-87 four bands
    /// of 16 color bars (palettes 0-3: grey, red, green, blue ramps, two
    /// entries per level), rows 88-95 palette 0 shadowed, 96-103
    /// highlighted, rows 104-111 a white block moving 2 px per emulated
    /// frame, the rest black (rows 0-15 and 112-127 sit under the overlay
    /// and the ROM report).
    fn test_pattern(md: *const Md, sink: LineSink) void {
        var cram: [64]u16 = undefined;
        for (&cram, 0..) |*c, i| {
            const l: u16 = @intCast((i & 15) / 2); // 0..7
            c.* = switch (i >> 4) {
                0 => l << 9 | l << 5 | l << 1,
                1 => l << 1,
                2 => l << 5,
                else => l << 9,
            };
        }
        const block_x: usize = (md.frame_count *% 2) % out_w;
        var px: [out_w]u8 = undefined;
        var r: u8 = 0;
        while (r < out_h) : (r += 1) {
            for (&px, 0..) |*p, x| {
                const bar: u8 = @intCast(x / 10);
                p.* = if (r < 16)
                    0
                else if (r < 88)
                    ((r - 16) / 18) << 4 | bar
                else if (r < 96)
                    vdp.tag_shadow | bar
                else if (r < 104)
                    vdp.tag_highlight | bar
                else if (r < 112 and (x + out_w - block_x) % out_w < 16)
                    15
                else
                    0;
            }
            sink.emit(r, &px, &cram);
        }
    }

    // ---- Keyframes (SPEC.md section 10) ----

    /// The console minus `rom` and `line_sink` (not console state). M3
    /// replaces the full copy with delta keyframes; the shape
    /// (`snapshot`/`restore`) stays. Auto layout: compare field by field
    /// (`std.meta.eql`), never as raw bytes.
    pub const Keyframe = struct {
        cpu: Cpu,
        work_ram: [0x10000]u8,
        vdp: vdp.Vdp,
        io: Io,
        pad: u16,
        z80: Z80,
        z80_ram: [0x2000]u8,
        z80_bank: u16,
        arbiter: Arbiter,
        z80_int: bool,
        ym: ym2612.Ym2612,
        psg: psg.Psg,
        frame_count: u32,
        m68k_carry: u32,
        z80_carry: u32,
    };

    pub fn snapshot(md: *const Md, out: *Keyframe) void {
        out.cpu = md.cpu;
        out.work_ram = md.work_ram;
        out.vdp = md.vdp;
        out.io = md.io;
        out.pad = md.pad;
        out.z80 = md.z80;
        out.z80_ram = md.z80_ram;
        out.z80_bank = md.z80_bank;
        out.arbiter = md.arbiter;
        out.z80_int = md.z80_int;
        out.ym = md.ym;
        out.psg = md.psg;
        out.frame_count = md.frame_count;
        out.m68k_carry = md.m68k_carry;
        out.z80_carry = md.z80_carry;
    }

    pub fn restore(md: *Md, k: *const Keyframe) void {
        md.cpu = k.cpu;
        md.work_ram = k.work_ram;
        md.vdp = k.vdp;
        md.io = k.io;
        md.pad = k.pad;
        md.z80 = k.z80;
        md.z80_ram = k.z80_ram;
        md.z80_bank = k.z80_bank;
        md.arbiter = k.arbiter;
        md.z80_int = k.z80_int;
        md.ym = k.ym;
        md.psg = k.psg;
        md.frame_count = k.frame_count;
        md.m68k_carry = k.m68k_carry;
        md.z80_carry = k.z80_carry;
    }
};
