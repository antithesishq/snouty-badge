//! VDP (315-5313) state, ports, DMA, counters and the line renderer
//! (SPEC.md sections 3, 4, 6). PLAN.md M1 Track B owns this file.
//!
//! Mode 5 only (the Genesis mode; the SMS mode 4 is not emulated), NTSC V28,
//! H40 and H32, no interlace, no 128 KB VRAM mode.
//!
//! Output (PLAN.md "Frozen for M1"): each rendered badge row goes to the
//! `LineSink` as 160 bytes, each a 6-bit CRAM index (palette << 4 | color)
//! with the shadow/highlight tag in bits 6-7 (`tag_*`), plus the current
//! 9-bit CRAM, so the frontend owns the color conversion.
//!
//! Byte order: `vram` holds the bytes at their VDP addresses (big-endian
//! words, as the 68000 wrote them): name table entries and the sprite
//! table are read as big-endian halfwords, a tile row as one big-endian
//! word whose top nibble is the leftmost pixel. `cram` and `vsram` are
//! native u16 words, `cram` as the bus wrote it masked to ----BBB-GGG-RRR-.
//!
//! Frame loop (md.zig, Track C), per line `v.line` = 0..261:
//!   1. if rendering and `row_for_line(v.line)` is a row, `render_line(row,
//!      sink)` (registers as they are at the start of the line);
//!   2. run the 68000 for the line, keeping `line_cycles` = the 68000
//!      cycles already spent in it (the HV counter and the H-blank status
//!      bit read it); `irq_level()` between instructions, `ack_irq(level)`
//!      when one is taken;
//!   3. `end_line()`: counts H-int, advances the line, raises V-int when the
//!      new line is `vint_line` (the Z80 INT is md.zig's: `v.line ==
//!      vint_line` right after `end_line`).
//!
//! Accuracy (SPEC.md section 4): DMA is instant and returns a 68000 stall;
//! the FIFO always reads empty; the HV counter is a linear interpolation
//! of the line (within 2 of the real H tables); sprites are evaluated only
//! on rendered lines, so collision and overflow come from those lines and
//! the sprite mask never carries from the previous line.

const std = @import("std");
const tables = @import("vdp_tables.zig");

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
/// 68000 cycles per line (3420 / 7, rounded up; the frame loop alternates
/// 488 and 489).
pub const m68k_cycles_per_line: u32 = 489;

/// Shadow/highlight tag in bits 6-7 of a rendered pixel: normal, shadow
/// (half intensity) or highlight (half plus half). 3 is never emitted.
pub const tag_normal: u8 = 0x00;
pub const tag_shadow: u8 = 0x40;
pub const tag_highlight: u8 = 0x80;

/// Status register bits (`read_status`).
pub const st_fifo_empty: u16 = 0x0200;
pub const st_fifo_full: u16 = 0x0100;
pub const st_vint: u16 = 0x0080;
pub const st_overflow: u16 = 0x0040;
pub const st_collision: u16 = 0x0020;
pub const st_odd: u16 = 0x0010;
pub const st_vblank: u16 = 0x0008;
pub const st_hblank: u16 = 0x0004;
pub const st_dma: u16 = 0x0002;
pub const st_pal: u16 = 0x0001;
/// Bits 15-10 are open bus on hardware (the next instruction's prefetch);
/// this is what a NOP-ish prefetch commonly reads.
pub const st_fixed: u16 = 0x3400;

/// Which 128 of the 224 lines reach the badge (SPEC.md section 6); a menu
/// setting. Squeeze: row r shows line r * 7 / 4. Crop: lines 48..175.
pub const LineMode = enum(u8) { squeeze, crop };

/// DMA stall model (68000 cycles charged for a 68000-to-VDP transfer):
/// words per line from the VDP's access slots, 68000 bus DMA to VRAM
/// taking two slots a word. Blank = V-blank or display off.
pub const dma_words_per_line = struct {
    pub const vram_active_h40: u32 = 9;
    pub const vram_active_h32: u32 = 8;
    pub const vram_blank_h40: u32 = 102;
    pub const vram_blank_h32: u32 = 83;
    pub const cram_active_h40: u32 = 18;
    pub const cram_active_h32: u32 = 16;
    pub const cram_blank_h40: u32 = 198;
    pub const cram_blank_h32: u32 = 161;
};

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

/// Genesis line shown in badge row `row` (0..127) under `mode`.
pub fn line_for_row(mode: LineMode, row: u8) u16 {
    return switch (mode) {
        .squeeze => tables.line_squeeze[row],
        .crop => tables.line_crop[row],
    };
}

pub const Vdp = struct {
    /// 64 KB video RAM, bytes at their VDP addresses (big-endian words).
    vram: [0x10000]u8 = @splat(0),
    /// 64 colors, 9 bits each (----BBB-GGG-RRR-).
    cram: [64]u16 = @splat(0),
    /// 40 vertical scroll entries, 10 bits each (20 columns x planes A, B:
    /// even entries plane A, odd plane B).
    vsram: [40]u16 = @splat(0),
    /// Registers 0-23.
    regs: [24]u8 = @splat(0),

    // ---- Control port latch ----
    /// First word of a two-word command seen, waiting for the second.
    pending: bool = false,
    /// Command code CD5-CD0: bits 0-3 target and direction (1 VRAM write,
    /// 3 CRAM write, 5 VSRAM write, 0 VRAM read, 8 CRAM read, 4 VSRAM
    /// read), bit 4 VRAM copy, bit 5 DMA.
    code: u8 = 0,
    /// Access address (16 bits; A14-A15 from the second command word).
    addr: u16 = 0,
    /// A VRAM fill DMA is armed and waits for its data port write.
    fill_pending: bool = false,

    // ---- Status and counters ----
    /// Sticky status bits: sprite overflow and collision (cleared by a
    /// status read). The rest of the status word is computed on read.
    status: u16 = 0,
    /// Current line, 0..261.
    line: u16 = 0,
    /// H-int line counter (reloaded from register 10).
    hint_counter: u8 = 0,
    /// Pending interrupts not yet taken by the 68000.
    vint_pending: bool = false,
    hint_pending: bool = false,
    /// 68000 cycles into the current line, for the interpolated HV counter
    /// and the H-blank bit. The frame loop keeps it current.
    line_cycles: u16 = 0,
    /// HV counter latched by register 0 bit 1 (returned while it is set).
    hv_latch: u16 = 0,

    // ---- Presentation (a menu setting, not VDP state) ----
    line_mode: LineMode = .squeeze,

    /// Power-on state. The arrays are cleared with `@memset` and the rest
    /// assigned field by field: `v.* = .{}` would put a 64 KB default
    /// image in flash and copy it. Keeps `line_mode`.
    pub fn reset(v: *Vdp) void {
        @memset(&v.vram, 0);
        @memset(&v.cram, 0);
        @memset(&v.vsram, 0);
        @memset(&v.regs, 0);
        v.pending = false;
        v.code = 0;
        v.addr = 0;
        v.fill_pending = false;
        v.status = 0;
        v.line = 0;
        v.hint_counter = 0;
        v.vint_pending = false;
        v.hint_pending = false;
        v.line_cycles = 0;
        v.hv_latch = 0;
    }

    inline fn h40(v: *const Vdp) bool {
        return v.regs[12] & 0x01 != 0;
    }

    inline fn display_on(v: *const Vdp) bool {
        return v.regs[1] & 0x40 != 0;
    }

    // ---- Ports (the 68000 at C00000-C0000F, the Z80 at 7F00-7F1F) ----
    // Word ports. A 68000 byte write puts the byte on both halves of the
    // bus: the caller passes `b << 8 | b`. A byte read takes the high byte
    // at the even address, the low byte at the odd one. A long word is two
    // word accesses, high word first.

    /// Data port write (C00000/C00002).
    pub fn write_data(v: *Vdp, w: u16) void {
        v.pending = false;
        v.bus_write(w);
        if (v.fill_pending) {
            v.fill_pending = false;
            v.dma_fill(w);
        }
    }

    /// Data port read (C00000/C00002): VRAM, CRAM or VSRAM at `addr` per
    /// the read code, then `addr` += register 15. Unused bits read 0.
    pub fn read_data(v: *Vdp) u16 {
        v.pending = false;
        const a = v.addr;
        const r: u16 = switch (v.code & 0x0F) {
            0x00 => be16(&v.vram, a & 0xFFFE),
            0x04 => blk: {
                const i = (a >> 1) & 0x3F;
                break :blk v.vsram[if (i < 40) i else 0];
            },
            0x08 => v.cram[(a >> 1) & 0x3F],
            // Undocumented 8-bit VRAM read: the byte at addr ^ 1 in the low half.
            0x0C => v.vram[a ^ 1],
            else => 0,
        };
        v.addr = a +% v.regs[15];
        return r;
    }

    /// Control port write (C00004/C00006): a register write (`100r rrrr
    /// vvvv vvvv` as the first word) or half of a two-word command. A
    /// second word with CD5 set and DMA enabled (register 1 bit 4) starts a
    /// DMA: 68000 memory to VRAM/CRAM/VSRAM (source words through
    /// `bus.read16(addr: u24) u16`, the 68000 map, so ROM reads go through
    /// `RomSource`) and VRAM copy run at once; a VRAM fill arms and runs on
    /// the next data port write. Returns the 68000 cycles the transfer
    /// stalls the 68000 for (0 for everything but 68000-memory DMA).
    pub fn write_control(v: *Vdp, w: u16, bus: anytype) u32 {
        if (!v.pending) {
            v.addr = (v.addr & 0xC000) | (w & 0x3FFF);
            v.code = (v.code & 0x3C) | @as(u8, @intCast(w >> 14));
            if (w & 0xC000 == 0x8000) {
                v.write_reg(@intCast((w >> 8) & 0x1F), @truncate(w));
            } else {
                v.pending = true;
            }
            return 0;
        }
        v.pending = false;
        v.addr = (v.addr & 0x3FFF) | ((w & 3) << 14);
        v.code = (v.code & 0x03) | @as(u8, @intCast((w >> 2) & 0x3C));
        if (v.code & 0x20 == 0 or v.regs[1] & 0x10 == 0) return 0;
        switch (v.regs[23] >> 6) {
            2 => v.fill_pending = true,
            3 => v.dma_copy(),
            else => return v.dma_68k(bus),
        }
        return 0;
    }

    /// Register write (registers 24-31 do not exist and are ignored).
    pub fn write_reg(v: *Vdp, r: u5, val: u8) void {
        if (r >= 24) return;
        if (r == 0 and val & 0x02 != 0 and v.regs[0] & 0x02 == 0) v.hv_latch = v.hv_now();
        v.regs[r] = val;
    }

    /// Status read (C00004/C00006): clears the command latch and the
    /// sprite overflow and collision bits.
    pub fn read_status(v: *Vdp) u16 {
        v.pending = false;
        var s: u16 = st_fixed | st_fifo_empty | v.status;
        if (v.vint_pending) s |= st_vint;
        if ((v.line >= vint_line and v.line < lines_per_frame - 1) or !v.display_on()) s |= st_vblank;
        const c = v.line_cycles;
        if (if (v.h40()) (c >= 33 and c < 125) else (c >= 40 and c < 123)) s |= st_hblank;
        v.status = 0;
        return s;
    }

    /// HV counter (C00008): V in the high byte, H in the low. Frozen at
    /// the value latched when register 0 bit 1 was set, while it is set.
    pub fn hv_counter(v: *const Vdp) u16 {
        if (v.regs[0] & 0x02 != 0) return v.hv_latch;
        return v.hv_now();
    }

    /// The live HV counter. V: the line, jumping from EA to E5 (NTSC V28).
    /// H: the line starts at H-blank (H40 A5, H32 85, where the V counter
    /// steps and H-int fires), counts to B6 (H40) / 93 (H32), jumps to
    /// E4 / E9, wraps through FF to 00; 211 / 171 values per line (H40's
    /// B6 and E4 share one slot) spread linearly over the 68000's 489
    /// cycles.
    fn hv_now(v: *const Vdp) u16 {
        const vc: u16 = if (v.line <= 0xEA) v.line else v.line - 6;
        const c: u32 = @min(v.line_cycles, m68k_cycles_per_line - 1);
        var h: u32 = undefined;
        if (v.h40()) {
            const i = (165 + c * 211 / m68k_cycles_per_line) % 211;
            h = if (i < 183) i else i - 183 + 0xE4;
        } else {
            const i = (133 + c * 171 / m68k_cycles_per_line) % 171;
            h = if (i < 148) i else i - 148 + 0xE9;
        }
        return (vc & 0xFF) << 8 | @as(u16, @intCast(h));
    }

    // ---- Internal bus and DMA ----

    /// One word into VRAM, CRAM or VSRAM at `addr` per the write code
    /// (byte-swapped into VRAM at an odd address), then `addr` += register
    /// 15. Read codes and invalid targets only advance the address.
    fn bus_write(v: *Vdp, w: u16) void {
        const a = v.addr;
        switch (v.code & 0x0F) {
            0x01 => {
                const d = if (a & 1 != 0) @byteSwap(w) else w;
                const i = a & 0xFFFE;
                v.vram[i] = @truncate(d >> 8);
                v.vram[i + 1] = @truncate(d);
            },
            0x03 => v.cram[(a >> 1) & 0x3F] = w & 0x0EEE,
            0x05 => {
                const i = (a >> 1) & 0x3F;
                if (i < 40) v.vsram[i] = w & 0x3FF;
            },
            else => {},
        }
        v.addr = a +% v.regs[15];
    }

    /// DMA length (registers 19-20; 0 means 64 K).
    inline fn dma_length(v: *const Vdp) u32 {
        const n: u32 = @as(u32, v.regs[20]) << 8 | v.regs[19];
        return if (n == 0) 0x10000 else n;
    }

    /// After a DMA: length counted down to 0, source registers advanced.
    inline fn dma_done(v: *Vdp, src: u16) void {
        v.regs[19] = 0;
        v.regs[20] = 0;
        v.regs[21] = @truncate(src);
        v.regs[22] = @truncate(src >> 8);
    }

    /// 68000 memory to VRAM/CRAM/VSRAM: source word address in registers
    /// 21-23 (bits 1-23 of the byte address); the low 17 bits wrap, so a
    /// transfer never leaves its 128 KB window.
    fn dma_68k(v: *Vdp, bus: anytype) u32 {
        const n = v.dma_length();
        const hi: u32 = @as(u32, v.regs[23] & 0x7F) << 17;
        var src: u16 = @as(u16, v.regs[22]) << 8 | v.regs[21];
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            const w = bus.read16(@intCast(hi | @as(u32, src) << 1));
            src +%= 1;
            v.bus_write(w);
        }
        v.dma_done(src);
        return v.dma_stall(n);
    }

    /// 68000 cycles a 68000-to-VDP transfer of `words` costs: the VDP's
    /// DMA slots per line (`dma_words_per_line`, blank when in V-blank or
    /// with the display off) over the 489-cycle line, rounded up.
    pub fn dma_stall(v: *const Vdp, words: u32) u32 {
        const blank = v.line >= vint_line or !v.display_on();
        const vram = v.code & 0x0F == 0x01;
        const r = dma_words_per_line;
        const rate: u32 = if (v.h40())
            (if (vram) (if (blank) r.vram_blank_h40 else r.vram_active_h40) else (if (blank) r.cram_blank_h40 else r.cram_active_h40))
        else
            (if (vram) (if (blank) r.vram_blank_h32 else r.vram_active_h32) else (if (blank) r.cram_blank_h32 else r.cram_active_h32));
        return (words * m68k_cycles_per_line + rate - 1) / rate;
    }

    /// VRAM fill, run by the data port write that followed the command
    /// (that write went through normally): `length` bytes of the word's
    /// high byte, each at `addr ^ 1`, `addr` += register 15. CRAM and VSRAM
    /// targets fill with the whole word.
    fn dma_fill(v: *Vdp, w: u16) void {
        const n = v.dma_length();
        var k: u32 = 0;
        switch (v.code & 0x0F) {
            0x01 => {
                const b: u8 = @truncate(w >> 8);
                while (k < n) : (k += 1) {
                    v.vram[v.addr ^ 1] = b;
                    v.addr +%= v.regs[15];
                }
            },
            0x03, 0x05 => while (k < n) : (k += 1) v.bus_write(w),
            else => v.addr +%= @truncate(n *% v.regs[15]),
        }
        const src: u16 = @as(u16, v.regs[22]) << 8 | v.regs[21];
        v.dma_done(src);
    }

    /// VRAM copy: `length` bytes from the source byte address (registers
    /// 21-22) to `addr`, both at `^ 1` as the fill; needs CD4 (a VRAM read
    /// code with the copy bit) or it does nothing.
    fn dma_copy(v: *Vdp) void {
        if (v.code & 0x10 == 0) return;
        const n = v.dma_length();
        var src: u16 = @as(u16, v.regs[22]) << 8 | v.regs[21];
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            v.vram[v.addr ^ 1] = v.vram[src ^ 1];
            src +%= 1;
            v.addr +%= v.regs[15];
        }
        v.dma_done(src);
    }

    // ---- Frame loop hooks (md.zig) ----

    /// End of the current line: the H-int counter counts down on lines
    /// 0..224 (fires on underflow, reloads from register 10) and reloads on
    /// every other line; the line advances; V-int is raised when the new
    /// line is `vint_line`.
    pub fn end_line(v: *Vdp) void {
        if (v.line <= active_lines) {
            if (v.hint_counter == 0) {
                v.hint_counter = v.regs[10];
                v.hint_pending = true;
            } else v.hint_counter -= 1;
        } else v.hint_counter = v.regs[10];
        v.line = if (v.line + 1 >= lines_per_frame) 0 else v.line + 1;
        v.line_cycles = 0;
        if (v.line == vint_line) v.vint_pending = true;
    }

    /// The interrupt level the VDP presents to the 68000 (6 V-int, 4 H-int,
    /// 0 none), masked by the enable bits (register 1 bit 5, register 0
    /// bit 4). A pending interrupt that is enabled later is presented then.
    pub fn irq_level(v: *const Vdp) u3 {
        if (v.vint_pending and v.regs[1] & 0x20 != 0) return 6;
        if (v.hint_pending and v.regs[0] & 0x10 != 0) return 4;
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

    /// The badge row that shows `line` under `line_mode`, or null when the
    /// line is not rendered.
    pub fn row_for_line(v: *const Vdp, line: u16) ?u8 {
        if (line >= active_lines) return null;
        const r = switch (v.line_mode) {
            .squeeze => tables.row_squeeze[line],
            .crop => tables.row_crop[line],
        };
        return if (r == 0xFF) null else r;
    }

    // ---- Rendering ----

    /// Render the current line (`line`) as badge row `row` and hand it to
    /// `sink` with the CRAM.
    pub fn render_line(v: *Vdp, row: u8, sink: LineSink) void {
        var buf: [out_w]u8 = undefined;
        v.compose_line(v.line, &buf);
        sink.emit(row, &buf, &v.cram);
    }

    /// Compose Genesis line `line` (0..223) into 160 tagged pixels: the
    /// badge columns of `tables.col_h40` / `col_h32`, layers backdrop,
    /// B low, A (or window) low, sprites low, B high, A high, sprites high;
    /// shadow/highlight when register 12 bit 3 is set. Sets the sprite
    /// overflow and collision status bits.
    pub fn compose_line(v: *Vdp, line: u16, out: *[out_w]u8) void {
        const bd: u8 = v.regs[7] & 0x3F;
        if (!v.display_on()) {
            @memset(out, bd);
            return;
        }
        if (v.h40()) v.compose(true, line, out) else v.compose(false, line, out);
    }

    fn compose(v: *Vdp, comptime wide: bool, line: u16, out: *[out_w]u8) void {
        const cols: *const [out_w]u16 = if (wide) &tables.col_h40 else &tables.col_h32;
        const first: []const u8 = if (wide) &tables.first_h40 else &tables.first_h32;
        const screen_w: u16 = if (wide) 320 else 256;
        const r = &v.regs;

        // Plane geometry (register 16; the invalid sizes as hardware).
        const shift: u4 = switch (r[16] & 3) {
            0 => 6,
            1 => 7,
            2 => 0,
            else => 8,
        };
        const cmask: u16 = switch (r[16] & 3) {
            1 => 63,
            3 => 127,
            else => 31,
        };
        const rmask: u16 = switch ((r[16] >> 4) & 3) {
            0 => 0x0FF,
            1 => 0x1FF,
            2 => 0x2FF,
            else => 0x3FF,
        };
        const geo: Plane = .{ .shift = shift, .cmask = cmask, .rmask = rmask, .wmask = cmask * 8 + 7 };

        // Horizontal scroll (register 11 bits 0-1: full, invalid = first 8
        // lines' entries, per 8 lines, per line).
        const hs_base: u16 = @as(u16, r[13] & 0x3F) << 10;
        const hs_line: u16 = switch (r[11] & 3) {
            0 => 0,
            1 => line & 7,
            2 => line & 0xFFF8,
            else => line,
        };
        const hs_at = hs_base +% hs_line * 4;
        const hs_a: u16 = be16(&v.vram, hs_at) & 0x3FF;
        const hs_b: u16 = be16(&v.vram, hs_at +% 2) & 0x3FF;
        const per_col = r[11] & 0x04 != 0;

        var bg: [out_w]u8 = undefined;

        // Plane B.
        const nt_b: u16 = @as(u16, r[4] & 0x07) << 13;
        v.plane(wide, false, &bg, 0, out_w, cols, nt_b, geo, hs_b, per_col, 1, line);

        // Window region (registers 17-18): whole line or a column span.
        const wv: u16 = @as(u16, r[18] & 0x1F) << 3;
        const w_line = if (r[18] & 0x80 != 0) line >= wv else line < wv;
        var a_lo: usize = 0;
        var a_hi: usize = out_w;
        var w_lo: usize = 0;
        var w_hi: usize = 0;
        if (w_line) {
            a_hi = 0;
            w_hi = out_w;
        } else {
            const hp: u16 = @min(@as(u16, r[17] & 0x1F) << 4, screen_w);
            const split: usize = first[hp];
            if (r[17] & 0x80 != 0) {
                a_hi = split;
                w_lo = split;
                w_hi = out_w;
            } else {
                w_hi = split;
                a_lo = split;
            }
        }
        const nt_a: u16 = @as(u16, r[2] & 0x38) << 10;
        if (a_lo < a_hi) v.plane(wide, true, &bg, a_lo, a_hi, cols, nt_a, geo, hs_a, per_col, 0, line);
        if (w_lo < w_hi) {
            const nt_w: u16 = if (wide) @as(u16, r[3] & 0x3C) << 10 else @as(u16, r[3] & 0x3E) << 10;
            const stride: u16 = if (wide) 128 else 64;
            v.window(&bg, w_lo, w_hi, cols, nt_w +% (line >> 3) * stride, line & 7);
        }

        // Sprites.
        var spr: [out_w]u8 = undefined;
        const any = v.sprites(wide, line, &spr, cols, first);

        const bd: u8 = r[7] & 0x3F;
        if (r[12] & 0x08 == 0) {
            if (any) {
                for (out, bg, spr) |*o, b, s| {
                    const bc = if (b & 0x0F != 0) b & 0x3F else bd;
                    o.* = if (s & 0x0F != 0 and (s & 0x40 != 0 or !hi_opaque(b))) s & 0x3F else bc;
                }
            } else {
                for (out, bg) |*o, b| o.* = if (b & 0x0F != 0) b & 0x3F else bd;
            }
        } else {
            for (out, bg, 0..) |*o, b, i| {
                const bc = if (b & 0x0F != 0) b & 0x3F else bd;
                const normal = b & 0x80 != 0;
                const s = if (any) spr[i] else 0;
                if (s & 0x0F != 0 and (s & 0x40 != 0 or !hi_opaque(b))) {
                    const sc = s & 0x3F;
                    o.* = if (sc == 0x3E)
                        bc | (if (normal) tag_highlight else tag_normal)
                    else if (sc == 0x3F)
                        bc | tag_shadow
                    else if (sc & 0x0F == 0x0E)
                        sc
                    else
                        sc | (if (s & 0x40 != 0 or normal) tag_normal else tag_shadow);
                } else o.* = bc | (if (normal) tag_normal else tag_shadow);
            }
        }

        // Register 0 bit 5: the leftmost 8 screen columns show the backdrop.
        if (r[0] & 0x20 != 0) {
            for (out[0..first[8]]) |*o| o.* = bd;
        }
    }

    /// Plane A or B for badge columns `from .. to` into `bg`. Plane pixel
    /// bytes: color index in bits 0-5 (color 0 = transparent), bit 6 the
    /// tile's priority when the pixel is opaque, bit 7 set when either
    /// plane's tile at the pixel has priority (normal intensity under
    /// shadow/highlight). B stores; A (`is_a`) merges over B: an opaque A
    /// pixel wins unless B's is opaque and high while A's is low.
    inline fn plane(
        v: *const Vdp,
        comptime wide: bool,
        comptime is_a: bool,
        bg: *[out_w]u8,
        from: usize,
        to: usize,
        cols: *const [out_w]u16,
        nt: u16,
        geo: Plane,
        hs: u16,
        per_col: bool,
        comptime which: u1,
        line: u16,
    ) void {
        const vram = &v.vram;
        const fine: u16 = hs & 15;
        // The column left of the first whole 2-cell column (hscroll not a
        // multiple of 16): H40 uses A's and B's column 19 ANDed, H32 0.
        const vs_part: u16 = if (wide) v.vsram[38] & v.vsram[39] else 0;
        var i = from;
        while (i < to) {
            const x = cols[i];
            var vs: u16 = v.vsram[which];
            var seg_end: u16 = 0xFFFF;
            if (per_col) {
                if (x < fine) {
                    vs = vs_part;
                    seg_end = fine;
                } else {
                    const c = (x - fine) >> 4;
                    vs = if (c < 20) v.vsram[c * 2 + which] else vs_part;
                    seg_end = fine + (c + 1) * 16;
                }
            }
            const y = (line + vs) & geo.rmask;
            const px = (x -% hs) & geo.wmask;
            const row_off = (@as(u16, y >> 3) << geo.shift) & 0x1FC0;
            const entry = be16(vram, nt +% row_off +% ((px >> 3) & geo.cmask) * 2);
            var fy: u16 = y & 7;
            if (entry & 0x1000 != 0) fy = 7 - fy;
            var w = be32(vram, (entry & 0x7FF) * 32 + fy * 4);
            if (entry & 0x0800 != 0) w = nibble_reverse(w);
            // Palette in bits 4-5, priority in bit 6, and bit 7 the S/H
            // "normal" mark of a priority tile.
            const attr: u8 = @truncate(((entry >> 9) & 0x70) | ((entry >> 8) & 0x80));
            const lim = @min(x + (8 - (px & 7)), seg_end);
            if (wide) {
                // Every second screen column: the nibble two pixels on is
                // eight bits further down the row word.
                const end: usize = @min(to, (@as(usize, lim) + 1) >> 1);
                w <<= @intCast((px & 7) * 4);
                while (i < end) : (i += 1) {
                    put(is_a, bg, i, attr, @truncate(w >> 28));
                    w <<= 8;
                }
            } else {
                while (i < to and cols[i] < lim) : (i += 1) {
                    const p: u5 = @intCast((cols[i] -% hs) & 7);
                    put(is_a, bg, i, attr, @truncate((w >> (28 - @as(u5, p) * 4)) & 0xF));
                }
            }
        }
    }

    /// The window plane for badge columns `from .. to`: no scroll, one name
    /// table row (`row`), fine row `fy`; replaces plane A (merges over B).
    fn window(v: *const Vdp, bg: *[out_w]u8, from: usize, to: usize, cols: *const [out_w]u16, row: u16, fy0: u16) void {
        const vram = &v.vram;
        var i = from;
        while (i < to) {
            const x = cols[i];
            const entry = be16(vram, row +% (x >> 3) * 2);
            var fy = fy0;
            if (entry & 0x1000 != 0) fy = 7 - fy;
            var w = be32(vram, (entry & 0x7FF) * 32 + fy * 4);
            if (entry & 0x0800 != 0) w = nibble_reverse(w);
            const attr: u8 = @truncate(((entry >> 9) & 0x70) | ((entry >> 8) & 0x80));
            const lim = (x | 7) + 1;
            while (i < to and cols[i] < lim) : (i += 1) {
                const p: u5 = @intCast(cols[i] & 7);
                put(true, bg, i, attr, @truncate((w >> (28 - p * 4)) & 0xF));
            }
        }
    }

    /// Sprites on `line` into `spr` (color index bits 0-5, priority bit
    /// 6, 0 = none), front to back: the link list from sprite 0 (stops at
    /// link 0 or past 80 / 64 entries), up to 20 / 16 sprites on the line
    /// (the next one sets the overflow bit), 320 / 256 pixels (the sprite
    /// that crosses the limit is cut, later ones are dropped), an X = 0
    /// sprite after one with X != 0 masks the rest of the line; an opaque
    /// pixel over an earlier opaque one sets the collision bit (badge
    /// columns only). False when nothing was drawn.
    fn sprites(v: *Vdp, comptime wide: bool, line: u16, spr: *[out_w]u8, cols: *const [out_w]u16, first: []const u8) bool {
        const vram = &v.vram;
        const max_total: u16 = if (wide) 80 else 64;
        const max_line: u16 = if (wide) 20 else 16;
        const max_px: u16 = if (wide) 320 else 256;
        const screen_w: i32 = if (wide) 320 else 256;
        const sat: u16 = @as(u16, v.regs[5] & (if (wide) @as(u8, 0x7E) else 0x7F)) << 9;

        // Pass 1: the sprites on this line, in link order.
        var list: [20]u16 = undefined; // SAT entry address
        var rows: [20]u8 = undefined; // line within the sprite
        var n: usize = 0;
        const ly: u16 = line + 128;
        var link: u16 = 0;
        var seen: u16 = 0;
        while (true) {
            const e = sat +% link * 8;
            const y = be16(vram, e) & 0x1FF;
            const size = vram[e +% 2];
            const hgt: u16 = (@as(u16, size & 3) + 1) * 8;
            if (ly >= y and ly - y < hgt) {
                if (n == max_line) {
                    v.status |= st_overflow;
                    break;
                }
                list[n] = e;
                rows[n] = @intCast(ly - y);
                n += 1;
            }
            link = vram[e +% 3] & 0x7F;
            seen += 1;
            if (link == 0 or link >= max_total or seen >= max_total) break;
        }
        if (n == 0) return false;

        // Pass 2: draw.
        @memset(spr, 0);
        var drawn = false;
        var pixels: u16 = 0;
        var nonzero_x = false;
        var collide = false;
        for (list[0..n], rows[0..n]) |e, d| {
            const xpos = be16(vram, e +% 6) & 0x1FF;
            if (xpos != 0) nonzero_x = true else if (nonzero_x) break;
            const size = vram[e +% 2];
            const hc: u16 = @as(u16, size & 3) + 1;
            const wd: u16 = (@as(u16, (size >> 2) & 3) + 1) * 8;
            pixels += wd;
            const cut = if (pixels > max_px) pixels - max_px else 0;
            const sx: i32 = @as(i32, xpos) - 128;
            const draw_w: i32 = @as(i32, wd) - cut;
            if (sx + draw_w > 0 and sx < screen_w) {
                const attr = be16(vram, e +% 4);
                const hf = attr & 0x0800 != 0;
                var r: u16 = d;
                if (attr & 0x1000 != 0) r = hc * 8 - 1 - r;
                const tile0 = (attr & 0x7FF) + (r >> 3);
                const hi: u8 = @truncate(((attr >> 9) & 0x70));
                const x_lo: u16 = @intCast(@max(sx, 0));
                const x_hi: u16 = @intCast(@min(sx + draw_w, screen_w));
                var i: usize = first[x_lo];
                var cell: u16 = 0xFFFF;
                var w: u32 = 0;
                while (i < out_w and cols[i] < x_hi) : (i += 1) {
                    var dx: u16 = @intCast(@as(i32, cols[i]) - sx);
                    if (hf) dx = wd - 1 - dx;
                    if (dx >> 3 != cell) {
                        cell = dx >> 3;
                        const t = (tile0 + cell * hc) & 0x7FF;
                        w = be32(vram, t * 32 + (r & 7) * 4);
                    }
                    const c: u8 = @truncate((w >> @intCast(28 - (dx & 7) * 4)) & 0xF);
                    if (c == 0) continue;
                    if (spr[i] != 0) {
                        collide = true;
                        continue;
                    }
                    spr[i] = hi | c;
                    drawn = true;
                }
            }
            if (pixels >= max_px) break;
        }
        if (collide) v.status |= st_collision;
        return drawn;
    }
};

/// Plane geometry of register 16: name table row shift (bytes, log2),
/// column mask (cells), row mask and width mask (pixels).
const Plane = struct { shift: u4, cmask: u16, rmask: u16, wmask: u16 };

/// A plane pixel into `bg[i]`: plane B stores, plane A merges (see `plane`).
inline fn put(comptime is_a: bool, bg: *[out_w]u8, i: usize, attr: u8, c: u8) void {
    if (!is_a) {
        bg[i] = attr | c;
        return;
    }
    const old = bg[i];
    const win = c != 0 and (attr & 0x40 != 0 or !hi_opaque(old));
    bg[i] = (if (win) (attr & 0x7F) | c | (old & 0x80) else old) | (attr & 0x80);
}

/// An opaque pixel with priority (it hides lower-priority layers).
inline fn hi_opaque(p: u8) bool {
    return p & 0x40 != 0 and p & 0x0F != 0;
}

inline fn be16(vram: *const [0x10000]u8, a: u16) u16 {
    return @as(u16, vram[a]) << 8 | vram[a +% 1];
}

inline fn be32(vram: *const [0x10000]u8, a: u16) u32 {
    return std.mem.readInt(u32, vram[a..][0..4], .big);
}

/// The eight pixels of a row word in reverse order (horizontal flip).
inline fn nibble_reverse(w: u32) u32 {
    const b = @byteSwap(w);
    return ((b >> 4) & 0x0F0F0F0F) | ((b & 0x0F0F0F0F) << 4);
}
