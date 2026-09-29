//! Snouty Genesis core: the whole Sega Genesis (Mega Drive, NTSC model 1)
//! in one struct, badge-agnostic. No cart-api, no floats, no allocator, no
//! clock, no randomness: the only input is the pad word given to
//! `step_frame`. SPEC.md sections 3, 7, 10; PLAN.md "Frozen for M1:
//! core/md.zig" is the interface contract.
//!
//! `step_frame` is the frame loop of the PLAN.md timing contract: 262
//! lines; per line the badge row is rendered at the line's start (when
//! asked and when the line is in the line table), the 68000 runs until it
//! has consumed the line's 488 or 489 cycles (scaled by
//! `tunables.cpu_scale`; the overrun, DMA stalls included, is carried into
//! the next line), then the Z80 runs its 228 cycles (scaled by
//! `tunables.z80_scale`, remainder carried) unless BUSREQ or RESET holds it,
//! then `vdp.end_line()`. The Z80's INT is asserted for line 224 (V-int).
//! `tone()` is computed once at the end of each frame and cached.
//!
//! Byte order per array: `work_ram`, `z80_ram`, `sram` and `vdp.vram` hold
//! bytes at their bus addresses (the 68000's big-endian word order); CRAM
//! and VSRAM are native u16 words.

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
    /// Cartridge SRAM (SPEC.md section 11, up to 16 KB, in RAM, not saved):
    /// byte `addr - sram_map.lo` of the header-declared range. Console
    /// state (in keyframes). Unused when the header declares none.
    sram: [rom.sram_max]u8 = @splat(0),
    /// The SRAM range the bus decodes now: the declared one while visible,
    /// else empty. A ROM that ends at or below the SRAM's start sees it
    /// from reset; a larger one only after A130F1 bit 0 is set (the SRAM
    /// control register of 2-4 MB SRAM cartridges).
    sram_active: rom.SramMap = .{},
    /// 68000 cycles owed to DMA (the VDP's charge, SPEC.md section 4),
    /// taken out of the 68000's budget by the frame loop.
    dma_stall: u32 = 0,

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
    /// The SRAM range the header declares (derived from `rom` by `reset`).
    sram_map: rom.SramMap = .{},
    /// `tone()`'s answer, recomputed at the end of every frame and on
    /// `reset`/`restore` (derived from `ym` and `psg`).
    tone_cache: ?Tone = null,

    /// Build the console around `src` in place, reset to power-on. The
    /// console is ~153 KB: always a static, never a stack temporary (32 KB
    /// stack on the badge, 14.7 KB in wasm).
    pub fn init_in_place(md: *Md, src: RomSource) void {
        md.rom = src;
        md.line_sink = null;
        md.reset();
    }

    /// Power-on state: memory zeroed, the 68000 at the reset vector (SSP
    /// from 000000, PC from 000004), the VDP, YM2612 and PSG reset, the Z80
    /// held in reset with the bus not requested (the 68000 must request the
    /// bus to load Z80 RAM and release the reset to start it, as on
    /// hardware). Field by field so no console-sized temporary is built.
    /// Keeps `rom` and `line_sink`.
    pub fn reset(md: *Md) void {
        @memset(&md.work_ram, 0);
        md.vdp.reset();
        md.io = .{};
        md.pad = 0;
        @memset(&md.sram, 0);
        const h = rom.parse_header(&md.rom);
        md.sram_map = if (md.rom.size >= rom.header_end) rom.sram_map(&h) else .{};
        md.sram_active = if (md.sram_map.present() and md.rom.size <= md.sram_map.lo) md.sram_map else .{};
        md.dma_stall = 0;
        z80bus.reset_genesis(&md.z80);
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
        md.tone_cache = md.pick_tone();
    }

    /// One Genesis frame (262 lines). `pad` is held for the whole frame;
    /// `render` false skips all line rendering (the first frame of a 60/30
    /// pair).
    pub fn step_frame(md: *Md, pad: u16, render: bool) void {
        md.pad = pad;
        const sink: ?LineSink = if (render) md.line_sink else null;
        var b = md.bus_for();
        var zb = md.z80bus_for();
        const scaled_frame: u32 = vdp.m68k_cycles_per_frame * tunables.cpu_scale / tunables.scale_one;
        var line: u32 = 0;
        while (line < vdp.lines_per_frame) : (line += 1) {
            if (sink) |s| if (md.vdp.row_for_line(@intCast(line))) |row| md.vdp.render_line(row, s);
            if (line == vdp.vint_line) md.z80_int = true;
            md.run_m68k(&b, line_share(line, scaled_frame));
            md.run_z80(&zb);
            md.z80_int = false;
            // The YM2612 timers count real 68000 cycles (its clock), unscaled.
            md.ym.tick(line_share(line, vdp.m68k_cycles_per_frame));
            md.vdp.end_line();
        }
        md.frame_count +%= 1;
        md.tone_cache = md.pick_tone();
    }

    /// 68000 cycles of line `line` when the frame has `total`: the frame's
    /// cycles spread evenly with no running sum (488 or 489 at full speed).
    inline fn line_share(line: u32, total: u32) u32 {
        return (line + 1) * total / vdp.lines_per_frame - line * total / vdp.lines_per_frame;
    }

    /// Run the 68000 until it has consumed `share` cycles of this line,
    /// counting DMA stalls, and carry the overrun into the next line. A
    /// STOPped 68000 with no interrupt above its mask sleeps the rest of
    /// the line (interrupts change only between lines or by the 68000's
    /// own writes). `vdp.line_cycles` follows the position in the line for
    /// the HV counter.
    fn run_m68k(md: *Md, b: *bus.Bus, share: u32) void {
        var used: u32 = md.m68k_carry;
        while (used < share) {
            if (md.dma_stall != 0) {
                used += md.dma_stall;
                md.dma_stall = 0;
                continue;
            }
            if (md.cpu.stopped and md.vdp.irq_level() <= md.cpu.mask()) {
                used = share;
                break;
            }
            used += @call(.always_inline, Cpu.step, .{ &md.cpu, b });
            md.vdp.line_cycles = @truncate(@min(used, 0xFFFF));
        }
        md.m68k_carry = used - share;
    }

    /// The Z80's slice of this line, in `scale_one` units so a scaled
    /// clock carries its fraction. Held by BUSREQ or RESET (or switched
    /// off) it does not run and its carry waits.
    fn run_z80(md: *Md, zb: *z80bus.Z80Bus) void {
        if (!tunables.z80_enabled or md.arbiter.busreq or md.arbiter.z80_reset) return;
        const share: u32 = vdp.z80_cycles_per_line * tunables.z80_scale;
        var used: u32 = md.z80_carry;
        while (used < share) {
            // Cycles left in this slice, so a halted Z80 sleeps to its end.
            zb.left = (share - used + tunables.scale_one - 1) / tunables.scale_one;
            used += @call(.always_inline, Z80.step, .{ &md.z80, zb }) * tunables.scale_one;
        }
        zb.left = 0;
        md.z80_carry = used - share;
    }

    /// The note the badge should play now (SPEC.md section 9), as computed
    /// at the end of the last frame.
    pub fn tone(md: *const Md) ?Tone {
        return md.tone_cache;
    }

    /// SPEC.md section 9: the FM pick against the PSG pick, the louder
    /// wins, FM on a tie (`ym2612.pick_tone`).
    fn pick_tone(md: *const Md) ?Tone {
        return ym2612.pick_tone(&md.ym, &md.psg);
    }

    pub fn bus_for(md: *Md) bus.Bus {
        return .{ .md = md };
    }

    pub fn z80bus_for(md: *Md) z80bus.Z80Bus {
        return .{ .md = md };
    }

    // ---- Keyframes (SPEC.md section 10) ----

    /// The console minus `rom`, `line_sink` (not console state),
    /// `sram_map` and `tone_cache` (derived). M3 replaces the full copy
    /// with delta keyframes; the shape (`snapshot`/`restore`) stays. Auto
    /// layout: compare field by field (`std.meta.eql`), never as raw bytes.
    pub const Keyframe = struct {
        cpu: Cpu,
        work_ram: [0x10000]u8,
        vdp: vdp.Vdp,
        io: Io,
        pad: u16,
        sram: [rom.sram_max]u8,
        sram_active: rom.SramMap,
        dma_stall: u32,
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
        out.sram = md.sram;
        out.sram_active = md.sram_active;
        out.dma_stall = md.dma_stall;
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
        md.sram = k.sram;
        md.sram_active = k.sram_active;
        md.dma_stall = k.dma_stall;
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
        md.tone_cache = md.pick_tone();
    }
};
