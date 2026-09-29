//! VDP (315-5313) state, ports, counters and the line renderer (SPEC.md
//! sections 3, 4, 6). PLAN.md M1 Track B owns this file.
//!
//! M0 scaffold: every piece of VDP state at its real size, the port and
//! counter functions the bus and the frame loop will call, as stubs, and
//! the `LineSink` contract with the frontend.
//!
//! Output (PLAN.md "Frozen for M1"): each rendered badge row goes to the
//! `LineSink` as 160 bytes, each a 6-bit CRAM index (palette << 4 | color)
//! with the shadow/highlight tag in bits 6-7 (`tag_*`), plus the current
//! 9-bit CRAM, so the frontend owns the color conversion.
//!
//! Byte order: `vram` holds the bytes at their VDP addresses (as the
//! 68000 wrote them, big-endian words); M1 may keep it word-swapped for
//! the renderer and must say so here.

/// Badge row width: the renderer emits 160 pixels (every second H40
/// column, or the H32 column table).
pub const out_w = 160;
/// Badge rows rendered per frame (the line table picks 128 of 224 lines).
pub const out_h = 128;

pub const lines_per_frame: u16 = 262;
pub const active_lines: u16 = 224;
/// V-int (68000 level 6) is raised at the start of this line.
pub const vint_line: u16 = 224;
/// 68000 cycles per frame (262 lines x 3420 master clocks / 7).
pub const m68k_cycles_per_frame: u32 = 128_008;
/// Z80 cycles per line (3420 / 15).
pub const z80_cycles_per_line: u32 = 228;

/// Shadow/highlight tag in bits 6-7 of a rendered pixel: normal, shadow
/// (half intensity) or highlight (half plus half). 3 is never emitted.
pub const tag_normal: u8 = 0x00;
pub const tag_shadow: u8 = 0x40;
pub const tag_highlight: u8 = 0x80;

/// Where rendered rows go. `row` is the badge row (0..127), `line` its 160
/// tagged indices, `cram` the CRAM as the row was rendered (64 words,
/// ----BBB-GGG-RRR-).
pub const LineSink = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, row: u8, line: *const [out_w]u8, cram: *const [64]u16) void,

    pub inline fn emit(s: LineSink, row: u8, line: *const [out_w]u8, cram: *const [64]u16) void {
        s.func(s.ctx, row, line, cram);
    }
};

pub const Vdp = struct {
    /// 64 KB video RAM.
    vram: [0x10000]u8 = @splat(0),
    /// 64 colors, 9 bits each (----BBB-GGG-RRR-).
    cram: [64]u16 = @splat(0),
    /// 40 vertical scroll entries, 10 bits each (20 columns x planes A, B).
    vsram: [40]u16 = @splat(0),
    /// Registers 0-23.
    regs: [24]u8 = @splat(0),

    // ---- Control port latch ----
    /// First word of a two-word command seen, waiting for the second.
    pending: bool = false,
    /// Command code (CD5-CD0): target (VRAM/CRAM/VSRAM), read/write, DMA.
    code: u8 = 0,
    /// Access address (17 bits across the two command words).
    addr: u32 = 0,
    /// Read-ahead word for data port reads.
    read_buf: u16 = 0,
    /// A VRAM fill DMA is armed and waits for its data port write.
    fill_pending: bool = false,

    // ---- Status and counters ----
    /// Status register bits (FIFO, V-int pending, sprite overflow and
    /// collision, odd frame, V/H blank, DMA busy, PAL).
    status: u16 = 0x3400,
    /// Current line, 0..261.
    line: u16 = 0,
    /// H-int line counter (reloaded from register 10).
    hint_counter: u8 = 0,
    /// Pending interrupts not yet taken by the 68000.
    vint_pending: bool = false,
    hint_pending: bool = false,
    /// 68000 cycles into the current line, for the interpolated HV counter.
    line_cycles: u16 = 0,

    /// Power-on state. The arrays are cleared with `@memset` and the rest
    /// assigned field by field: `v.* = .{}` would put a 64 KB default
    /// image in flash and copy it.
    pub fn reset(v: *Vdp) void {
        @memset(&v.vram, 0);
        @memset(&v.cram, 0);
        @memset(&v.vsram, 0);
        @memset(&v.regs, 0);
        v.pending = false;
        v.code = 0;
        v.addr = 0;
        v.read_buf = 0;
        v.fill_pending = false;
        v.status = 0x3400;
        v.line = 0;
        v.hint_counter = 0;
        v.vint_pending = false;
        v.hint_pending = false;
        v.line_cycles = 0;
    }

    // ---- Ports (the 68000 at C00000-C0000F, the Z80 at 7F00-7F1F) ----
    // M0 stubs: M1 Track B implements them.

    pub fn write_data(v: *Vdp, w: u16) void {
        _ = v;
        _ = w;
    }

    pub fn read_data(v: *Vdp) u16 {
        return v.read_buf;
    }

    pub fn write_control(v: *Vdp, w: u16) void {
        _ = v;
        _ = w;
    }

    /// Status read (clears the command latch on hardware).
    pub fn read_status(v: *Vdp) u16 {
        v.pending = false;
        return v.status;
    }

    /// HV counter (C00008): V in the high byte, H in the low.
    pub fn hv_counter(v: *const Vdp) u16 {
        return @as(u16, @as(u8, @truncate(v.line))) << 8;
    }

    // ---- Frame loop hooks (md.zig) ----

    /// End of the current line: advance the line, reload or count down the
    /// H-int counter, raise V-int at `vint_line`. M0: advances the line only.
    pub fn end_line(v: *Vdp) void {
        v.line = if (v.line + 1 >= lines_per_frame) 0 else v.line + 1;
        v.line_cycles = 0;
    }

    /// The interrupt level the VDP presents to the 68000 (6 V-int, 4 H-int,
    /// 0 none), masked by the enable bits in registers 0 and 1.
    pub fn irq_level(v: *const Vdp) u3 {
        if (v.vint_pending) return 6;
        if (v.hint_pending) return 4;
        return 0;
    }

    /// The 68000 took the interrupt at `level`.
    pub fn ack_irq(v: *Vdp, level: u3) void {
        switch (level) {
            6 => v.vint_pending = false,
            4 => v.hint_pending = false,
            else => {},
        }
    }

    /// Render the current line as badge row `row` into `out`. M0 stub: the
    /// backdrop color (register 7) everywhere.
    pub fn render_line(v: *const Vdp, row: u8, out: *[out_w]u8) void {
        _ = row;
        @memset(out, v.regs[7] & 0x3F);
    }
};
