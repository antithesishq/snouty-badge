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
//! Renderer layout (SPEC.md section 8: 4 ms for 128 rows): per line, plane
//! B, plane A and the sprites go into word-aligned byte buffers indexed by
//! badge column, then one pass resolves priority four pixels at a time
//! (SWAR on u32). H40 draws a tile per step: its 8 pixels hold exactly the
//! four even screen columns, so one tile row word becomes one four-pixel
//! store; plane A and the window merge straight over B when they do not
//! share the line. H32 draws the 256-pixel line through the `spread`
//! tables and gathers the badge columns 8 in, 5 out. The sprite link list
//! is walked once per change of the table (`walk_sat`) into a cache plus
//! per-8-line band masks, so a line only visits the sprites of its band.
//! Shadow/highlight takes a per-pixel final pass. The tests check every
//! path against a per-pixel reference on random states.
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
    /// A14-A15 as the last second word set them: a first word keeps these,
    /// not the auto-incremented address's.
    addr_hi: u16 = 0,
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
    /// `irq_level()` as of the last change of the pending flags or of
    /// registers 0 and 1 (`sync_irq`): what the 68000 samples before every
    /// instruction, one load instead of four. Code that pokes the flags or
    /// registers directly (tests) calls `sync_irq`.
    irq: u3 = 0,
    /// 68000 cycles into the current line, for the interpolated HV counter
    /// and the H-blank bit. The frame loop keeps it current.
    line_cycles: u16 = 0,
    /// HV counter latched by register 0 bit 1 (returned while it is set).
    hv_latch: u16 = 0,

    // ---- Sprite table cache (see `walk_sat`). Port and DMA writes keep
    // it current; code writing `vram` directly sets `spr_dirty`. ----
    spr_cache: [80]u32 = @splat(0),
    spr_count: u8 = 0,
    /// Per 8-line band of the screen, bit k set when cache entry k covers
    /// a line of the band.
    spr_band: [28][3]u32 = @splat(@splat(0)),
    spr_dirty: bool = true,

    // ---- Presentation (a menu setting, not VDP state) ----
    line_mode: LineMode = .squeeze,

    /// 64 KB video RAM, bytes at their VDP addresses (big-endian words).
    /// Declared last: Zig keeps declaration order among same-aligned
    /// fields, so the registers and flags above stay near the struct's
    /// start (short offsets on the badge).
    vram: [0x10000]u8 = @splat(0),

    /// Power-on state. The arrays are cleared with `@memset` and the rest
    /// assigned field by field: `v.* = .{}` would put a 64 KB default
    /// image in flash and copy it. `line_mode` goes back to squeeze (the
    /// frontend re-applies its menu setting after a reset).
    pub fn reset(v: *Vdp) void {
        @memset(&v.vram, 0);
        @memset(&v.cram, 0);
        @memset(&v.vsram, 0);
        @memset(&v.regs, 0);
        v.pending = false;
        v.code = 0;
        v.addr = 0;
        v.addr_hi = 0;
        v.fill_pending = false;
        v.status = 0;
        v.line = 0;
        v.hint_counter = 0;
        v.vint_pending = false;
        v.hint_pending = false;
        v.irq = 0;
        v.line_cycles = 0;
        v.hv_latch = 0;
        v.line_mode = .squeeze;
        @memset(&v.spr_cache, 0);
        v.spr_count = 0;
        @memset(&v.spr_band, @splat(0));
        v.spr_dirty = true;
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
            v.addr = v.addr_hi | (w & 0x3FFF);
            v.code = (v.code & 0x3C) | @as(u8, @intCast(w >> 14));
            if (w & 0xC000 == 0x8000) {
                v.write_reg(@intCast((w >> 8) & 0x1F), @truncate(w));
            } else {
                v.pending = true;
            }
            return 0;
        }
        v.pending = false;
        v.addr_hi = (w & 3) << 14;
        v.addr = (v.addr & 0x3FFF) | v.addr_hi;
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
        if (r == 5 or r == 12) v.spr_dirty = true;
        v.regs[r] = val;
        if (r <= 1) v.sync_irq();
    }

    /// Status read (C00004/C00006): clears the command latch and the
    /// sprite overflow and collision bits. DMA busy reads 0 except while a
    /// fill waits for its data word (DMA is instant otherwise).
    pub fn read_status(v: *Vdp) u16 {
        v.pending = false;
        var s: u16 = st_fixed | st_fifo_empty | v.status;
        if (v.vint_pending) s |= st_vint;
        // A fill is busy from its command until its data write.
        if (v.fill_pending) s |= st_dma;
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
                // Within 1 KB of the table base covers H40 and H32.
                if (i -% (@as(u16, v.regs[5] & 0x7E) << 9) < 0x400) v.spr_dirty = true;
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
    ///
    /// Fast path: a VRAM write at an even address with auto-increment 2
    /// from memory the bus can hand out as bytes (`bus.dma_source`, when it
    /// has one: ROM and work RAM) copies straight across, run by run; the
    /// result is the word-by-word loop's (tests/bus_unit.zig compares).
    fn dma_68k(v: *Vdp, bus: anytype) u32 {
        const n = v.dma_length();
        const hi: u32 = @as(u32, v.regs[23] & 0x7F) << 17;
        var src: u16 = @as(u16, v.regs[22]) << 8 | v.regs[21];
        var k: u32 = 0;
        if (comptime @hasDecl(@typeInfo(@TypeOf(bus)).pointer.child, "dma_source")) {
            if (v.code & 0x0F == 0x01 and v.regs[15] == 2 and v.addr & 1 == 0) {
                const sat: u16 = @as(u16, v.regs[5] & 0x7E) << 9;
                var a = v.addr;
                var sat_hit = false;
                while (k < n) {
                    // A run ends where the 128 KB source window wraps.
                    const want = @min(n - k, 0x10000 - @as(u32, src));
                    const span = bus.dma_source(@intCast(hi | @as(u32, src) << 1), want) orelse break;
                    var j: u32 = 0;
                    while (j < span.words) : (j += 1) {
                        v.vram[a] = span.ptr[2 * j];
                        v.vram[a + 1] = span.ptr[2 * j + 1];
                        if (a -% sat < 0x400) sat_hit = true;
                        a +%= 2;
                    }
                    k += span.words;
                    src +%= @truncate(span.words);
                }
                v.addr = a;
                if (sat_hit) v.spr_dirty = true;
            }
        }
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
        v.spr_dirty = true;
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
        v.spr_dirty = true;
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
        v.sync_irq();
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
        v.sync_irq();
    }

    /// Recompute `irq` from the pending flags and registers 0 and 1.
    pub fn sync_irq(v: *Vdp) void {
        v.irq = v.irq_level();
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
        const pa: PlaneLine = .{
            .nt = @as(u16, r[2] & 0x38) << 10,
            .shift = shift,
            .cmask = cmask,
            .rmask = rmask,
            .wmask = cmask * 8 + 7,
            .hs = be16(&v.vram, hs_at) & 0x3FF,
            .per_col = r[11] & 0x04 != 0,
            .which = 0,
            .line = line,
        };
        var pb = pa;
        pb.nt = @as(u16, r[4] & 0x07) << 13;
        pb.hs = be16(&v.vram, hs_at +% 2) & 0x3FF;
        pb.which = 1;

        // Window region (registers 17-18): whole line or a column span
        // replacing plane A.
        const wv: u16 = @as(u16, r[18] & 0x1F) << 3;
        var w_lo: usize = 0;
        var w_hi: usize = out_w;
        const a_shown = if (r[18] & 0x80 != 0) line < wv else line >= wv;
        if (a_shown) {
            const hp: u16 = @min(@as(u16, r[17] & 0x1F) << 4, screen_w);
            const split: usize = first[hp];
            // Width 0: plane A across the whole line either way.
            if (hp == 0) w_hi = 0 else if (r[17] & 0x80 != 0) w_lo = split else w_hi = split;
        }

        // Layer buffers, badge column i at `pad + i`, word aligned so the
        // final pass takes four pixels at a time. Pixel bytes: color index
        // in bits 0-5 (color 0 = transparent), the tile's priority in bit 6.
        // H40 without shadow/highlight, when plane A and the window do not
        // share the line, merges A (or the window) over B as it is drawn
        // (`merged`); otherwise A has its own buffer and the final pass
        // merges.
        var ba: LayerBuf align(4) = undefined;
        var bb: LayerBuf align(4) = undefined;
        const merged = wide and r[12] & 0x08 == 0 and !(a_shown and w_lo < w_hi);
        const la = if (merged) &bb else &ba;
        v.plane(wide, &bb, pb, cols, false);
        if (a_shown) v.plane(wide, la, pa, cols, merged);
        if (w_lo < w_hi) {
            const nt_w: u16 = if (wide) @as(u16, r[3] & 0x3C) << 10 else @as(u16, r[3] & 0x3E) << 10;
            const stride: u16 = if (wide) 128 else 64;
            v.window(wide, la, w_lo, w_hi, cols, nt_w +% (line >> 3) * stride, (line & 7) * 4, merged);
        }

        // Sprites, badge column i at `spr[pad + i]` (0 = none).
        var spr: LayerBuf align(4) = undefined;
        const any = v.sprites(wide, line, &spr, cols, first);

        const bd: u8 = r[7] & 0x3F;
        if (r[12] & 0x08 == 0) {
            if (merged) final_pass(true, &ba, &bb, &spr, any, bd, out) else final_pass(false, &ba, &bb, &spr, any, bd, out);
        } else {
            final_sh(&ba, &bb, &spr, any, bd, out);
        }

        // Register 0 bit 5: the leftmost 8 screen columns show the backdrop.
        if (r[0] & 0x20 != 0) {
            for (out[0..first[8]]) |*o| o.* = bd;
        }
    }

    /// One plane's line into `buf` (all 160 columns). H40 goes a tile at a
    /// time: each 8-pixel tile holds exactly four badge columns (the even
    /// screen columns), at nibble positions of the scroll's parity, so a
    /// tile row word becomes one four-pixel store (merged over plane B
    /// when `merge`). H32 draws the full 256 pixels and samples the badge
    /// columns through the column table.
    fn plane(v: *const Vdp, comptime wide: bool, buf: *align(4) LayerBuf, pl: PlaneLine, cols: *const [out_w]u16, merge: bool) void {
        // The column left of the first whole 2-cell column (hscroll not a
        // multiple of 16) under per-column vertical scroll: H40 uses A's
        // and B's column 19 ANDed, H32 0.
        const vs_part: u16 = if (wide) v.vsram[38] & v.vsram[39] else 0;
        var row: u16 = 0;
        var r4: u16 = 0;
        if (!pl.per_col) {
            const y = (pl.line + v.vsram[pl.which]) & pl.rmask;
            row = pl.nt +% ((@as(u16, y >> 3) << pl.shift) & 0x1FC0);
            r4 = (y & 7) * 4;
        }
        if (wide) {
            switch (@as(u2, @intFromBool(pl.per_col)) << 1 | @intFromBool(merge)) {
                0 => v.plane40(false, false, buf, pl, row, r4, vs_part),
                1 => v.plane40(false, true, buf, pl, row, r4, vs_part),
                2 => v.plane40(true, false, buf, pl, row, r4, vs_part),
                else => v.plane40(true, true, buf, pl, row, r4, vs_part),
            }
        } else {
            // H32: the plane at full width, then the badge columns sampled.
            var full: FullBuf align(4) = undefined;
            if (pl.per_col) v.plane32(true, &full, pl, row, r4, vs_part) else v.plane32(false, &full, pl, row, r4, vs_part);
            gather(buf, &full, cols, 0, out_w);
        }
    }

    /// H32 plane line at full width into `full` (screen x at `8 + x`), a
    /// tile row (8 pixel bytes) per step through the spread tables.
    fn plane32(v: *const Vdp, comptime per_col: bool, full: *align(4) FullBuf, pl: PlaneLine, row_full: u16, r4_full: u16, vs_part: u16) void {
        const vram = &v.vram;
        const hs = pl.hs;
        const fine: u16 = hs & 15;
        var row = row_full;
        var r4 = r4_full;
        const f: u16 = hs & 7;
        const x0: i16 = if (f == 0) 0 else @as(i16, @intCast(f)) - 8;
        var at: usize = @intCast(8 + x0);
        var col: u16 = ((@as(u16, @bitCast(x0)) -% hs) & pl.wmask) >> 3;
        const n: u16 = if (f == 0) 32 else 33;
        var xs: i16 = x0;
        var m: u16 = 0;
        while (m < n) : (m += 1) {
            if (per_col) {
                var vs = vs_part;
                if (xs >= @as(i16, @intCast(fine))) {
                    const c: u16 = @intCast((xs - @as(i16, @intCast(fine))) >> 4);
                    vs = v.vsram[c * 2 + pl.which];
                }
                const y = (pl.line + vs) & pl.rmask;
                row = pl.nt +% ((@as(u16, y >> 3) << pl.shift) & 0x1FC0);
                r4 = (y & 7) * 4;
                xs += 8;
            }
            const e = be16(vram, row +% col * 2);
            col = (col + 1) & pl.cmask;
            row8(vram, e, r4, full[at..][0..8]);
            at += 8;
        }
    }

    /// H40 plane line, a tile at a time (see `plane`); `row` and `r4` are
    /// the name table row and pattern row offset without per-column scroll.
    fn plane40(v: *const Vdp, comptime per_col: bool, comptime merge: bool, buf: *align(4) LayerBuf, pl: PlaneLine, row_full: u16, r4_full: u16, vs_part: u16) void {
        const vram = &v.vram;
        const hs = pl.hs;
        const fine: u16 = hs & 15;
        var row = row_full;
        var r4 = r4_full;
        // First tile: the one holding screen column 0 (starting at
        // screen x0 = (hs & 7) - 8, or 0); its first even column is
        // badge column ceil(x0 / 2) = -3..0.
        const f: u16 = hs & 7;
        const x0: i16 = if (f == 0) 0 else @as(i16, @intCast(f)) - 8;
        var at: usize = @intCast(@as(i16, pad) + @divFloor(x0 + 1, 2));
        var col: u16 = ((@as(u16, @bitCast(x0)) -% hs) & pl.wmask) >> 3;
        // Even screen columns are the high nibbles of the row word's
        // bytes when hs is even, the low ones when it is odd.
        const sh: u5 = if (hs & 1 != 0) 0 else 4;
        const n: u16 = if (f == 0) 40 else 41;
        var xs: i16 = x0;
        var m: u16 = 0;
        while (m < n) : (m += 1) {
            if (per_col) {
                var vs = vs_part;
                if (xs >= @as(i16, @intCast(fine))) {
                    const c: u16 = @intCast((xs - @as(i16, @intCast(fine))) >> 4);
                    vs = v.vsram[c * 2 + pl.which];
                }
                const y = (pl.line + vs) & pl.rmask;
                row = pl.nt +% ((@as(u16, y >> 3) << pl.shift) & 0x1FC0);
                r4 = (y & 7) * 4;
                xs += 8;
            }
            const e = be16(vram, row +% col * 2);
            col = (col + 1) & pl.cmask;
            const four = tile4(vram, e, r4, sh);
            st32(buf[at..][0..4], if (merge) over(four, ld32(buf[at..][0..4])) else four);
            at += 4;
        }
    }

    /// The window for badge columns `from .. to` into `buf`: no scroll, one
    /// name table row at `row`, pattern row offset `r4`. In H40 `from` and
    /// `to` are multiples of 8 (16-pixel steps), so whole tiles.
    fn window(v: *const Vdp, comptime wide: bool, buf: *align(4) LayerBuf, from: usize, to: usize, cols: *const [out_w]u16, row: u16, r4: u16, merge: bool) void {
        const vram = &v.vram;
        if (wide) {
            var m: usize = from >> 2;
            while (m < to >> 2) : (m += 1) {
                const e = be16(vram, row +% @as(u16, @intCast(m)) * 2);
                const four = tile4(vram, e, r4, 4);
                const q = buf[pad + m * 4 ..][0..4];
                st32(q, if (merge) over(four, ld32(q)) else four);
            }
            return;
        }
        var full: FullBuf align(4) = undefined;
        var cx: u16 = cols[from] >> 3;
        while (cx <= cols[to - 1] >> 3) : (cx += 1) {
            row8(vram, be16(vram, row +% cx * 2), r4, full[8 + @as(usize, cx) * 8 ..][0..8]);
        }
        gather(buf, &full, cols, from, to);
    }

    /// Walk the sprite link list from sprite 0 (stops at link 0, at a link
    /// past the last entry, or after 80 / 64 entries) into `spr_cache`:
    /// per entry its Y (bits 0-8), height in pixels (bits 16-23) and
    /// index (bits 24-31), and `spr_band`. Hardware keeps the same fields
    /// (not the bands) in an internal
    /// copy of the table; here it is rebuilt when a write touches the
    /// table or registers 5 and 12 change (`spr_dirty`).
    fn walk_sat(v: *Vdp, comptime wide: bool) void {
        const vram = &v.vram;
        const max_total: u16 = if (wide) 80 else 64;
        const sat: u16 = @as(u16, v.regs[5] & (if (wide) @as(u8, 0x7E) else 0x7F)) << 9;
        var link: u16 = 0;
        var n: u8 = 0;
        @memset(&v.spr_band, @splat(0));
        while (true) {
            const e = sat +% link * 8;
            const y: u32 = be16(vram, e) & 0x1FF;
            const hgt: u32 = (@as(u32, vram[e +% 2] & 3) + 1) * 8;
            v.spr_cache[n] = y | hgt << 16 | @as(u32, link) << 24;
            // Screen lines y - 128 .. + hgt, clipped to 0..223.
            const top: u32 = @max(y, 128) - 128;
            const bot: u32 = @min(y + hgt, 128 + active_lines) -| 128;
            if (top < bot) {
                var b = top >> 3;
                while (b <= (bot - 1) >> 3) : (b += 1) v.spr_band[b][n >> 5] |= @as(u32, 1) << @intCast(n & 31);
            }
            n += 1;
            link = vram[e +% 3] & 0x7F;
            if (link == 0 or link >= max_total or n >= max_total) break;
        }
        v.spr_count = n;
        v.spr_dirty = false;
    }

    /// Sprites on `line` into `spr` (badge column i at `pad + i`; color
    /// index bits 0-5, priority bit 6, 0 = none), front to back in link
    /// order: up to 20 / 16 sprites on the line (the next one sets the
    /// overflow bit), 320 / 256 pixels (the sprite that crosses the limit
    /// is cut, later ones are dropped), an X = 0 sprite after one with
    /// X != 0 masks the rest of the line; an opaque pixel over an earlier
    /// opaque one sets the collision bit (badge columns only). False when
    /// no sprite is on the line.
    fn sprites(v: *Vdp, comptime wide: bool, line: u16, spr: *align(4) LayerBuf, cols: *const [out_w]u16, first: []const u8) bool {
        const vram = &v.vram;
        const max_line: u16 = if (wide) 20 else 16;
        const max_px: u16 = if (wide) 320 else 256;
        const screen_w: i32 = if (wide) 320 else 256;
        const sat: u16 = @as(u16, v.regs[5] & (if (wide) @as(u8, 0x7E) else 0x7F)) << 9;
        if (v.spr_dirty) v.walk_sat(wide);

        // Pass 1: the sprites on this line.
        var list: [20]u16 = undefined; // SAT entry address
        var rows: [20]u8 = undefined; // line within the sprite
        var n: usize = 0;
        const ly: u32 = line + 128;
        const band = &v.spr_band[line >> 3];
        scan: for (band, 0..) |word, wi| {
            var bits = word;
            while (bits != 0) : (bits &= bits - 1) {
                const c = v.spr_cache[wi * 32 + @ctz(bits)];
                const d = ly -% (c & 0x1FF);
                if (d < (c >> 16) & 0xFF) {
                    if (n == max_line) {
                        v.status |= st_overflow;
                        break :scan;
                    }
                    list[n] = sat +% @as(u16, @intCast(c >> 24)) * 8;
                    rows[n] = @intCast(d);
                    n += 1;
                }
            }
        }
        if (n == 0) return false;

        // Pass 2: draw.
        @memset(spr, 0);
        var pixels: u16 = 0;
        var nonzero_x = false;
        var collide: u32 = 0;
        for (list[0..n], rows[0..n]) |e, d| {
            const xpos = be16(vram, e +% 6) & 0x1FF;
            if (xpos != 0) nonzero_x = true else if (nonzero_x) break;
            const size = vram[e +% 2];
            const hc: u16 = @as(u16, size & 3) + 1;
            const wc: u16 = @as(u16, (size >> 2) & 3) + 1;
            pixels += wc * 8;
            const cut: u16 = if (pixels > max_px) (pixels - max_px) >> 3 else 0;
            const sx: i32 = @as(i32, xpos) - 128;
            const attr = be16(vram, e +% 4);
            const hf = attr & 0x0800 != 0;
            var r: u16 = d;
            if (attr & 0x1000 != 0) r = hc * 8 - 1 - r;
            const tile0 = (attr & 0x7FF) + (r >> 3);
            const r4 = (r & 7) * 4;
            if (wide) {
                // A cell at a time: its even screen columns are four badge
                // columns at nibbles of the cell's X parity, merged under
                // the sprites already drawn (four bytes per step).
                var cx: u16 = 0;
                while (cx < wc - cut) : (cx += 1) {
                    const xc = sx + @as(i32, cx) * 8;
                    if (xc + 8 <= 0 or xc >= screen_w) continue;
                    const tcol = if (hf) wc - 1 - cx else cx;
                    const t = (tile0 + tcol * hc) & 0x7FF;
                    const four = tile4(vram, (attr & 0xE800) | t, r4, if (xc & 1 != 0) 0 else 4);
                    const at: usize = @intCast(pad + @divFloor(xc + 1, 2));
                    const cur = ld32(spr[at..][0..4]);
                    const nzn = nonzero(four);
                    const nzc = nonzero(cur);
                    collide |= nzn & nzc;
                    const m = expand(nzn & ~nzc);
                    st32(spr[at..][0..4], (cur & ~m) | (four & m));
                }
            } else {
                const draw_w: i32 = @as(i32, wc - cut) * 8;
                const wd: u16 = wc * 8;
                if (sx + draw_w > 0 and sx < screen_w) {
                    const hi: u8 = tile_attr(attr);
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
                            w = be32(vram, t * 32 + r4);
                        }
                        const c: u8 = @truncate((w >> @intCast(28 - (dx & 7) * 4)) & 0xF);
                        if (c == 0) continue;
                        if (spr[pad + i] != 0) {
                            collide = 1;
                            continue;
                        }
                        spr[pad + i] = hi | c;
                    }
                }
            }
            if (pixels >= max_px) break;
        }
        if (collide != 0) v.status |= st_collision;
        return true;
    }
};

/// One plane's per-line setup: name table base, register 16 geometry
/// (row shift in bytes log2, column mask in cells, row and width masks in
/// pixels), its horizontal scroll, per-column vertical scroll, which VSRAM
/// half (0 A, 1 B) and the line.
const PlaneLine = struct {
    nt: u16,
    shift: u4,
    cmask: u16,
    rmask: u16,
    wmask: u16,
    hs: u16,
    per_col: bool,
    which: u1,
    line: u16,
};

/// Left padding of a layer buffer: H40's first tile starts up to three
/// badge columns left of column 0, and its last spills up to 3 past 159.
const pad = 4;
const LayerBuf = [pad + out_w + 8]u8;

const ones: u32 = 0x01010101;
const highs: u32 = 0x80808080;

/// A plane line at full H32 width: screen x at `8 + x`, with room for
/// the partial tiles at both ends.
const FullBuf = [8 + 256 + 8]u8;

/// Entry `e`'s pattern row (offset `r4`, flips applied) as eight pixel
/// bytes at `dst`.
inline fn row8(vram: *const [0x10000]u8, e: u16, r4: u16, dst: *[8]u8) void {
    const r = if (e & 0x1000 != 0) r4 ^ 28 else r4;
    const w = be32(vram, (e & 0x7FF) * 32 + r);
    const a4 = @as(u32, tile_attr(e)) * ones;
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    if (e & 0x0800 != 0) {
        const t = &tables.spread_rev;
        lo = t[w & 0xFF] | @as(u32, t[(w >> 8) & 0xFF]) << 16;
        hi = t[(w >> 16) & 0xFF] | @as(u32, t[w >> 24]) << 16;
    } else {
        const t = &tables.spread;
        lo = t[w >> 24] | @as(u32, t[(w >> 16) & 0xFF]) << 16;
        hi = t[(w >> 8) & 0xFF] | @as(u32, t[w & 0xFF]) << 16;
    }
    st32(dst[0..4], lo | a4);
    st32(dst[4..8], hi | a4);
}

/// Badge columns `from .. to` of a full-width line into a layer buffer.
/// Badge columns 5g .. 5g + 4 show screen columns 8g + 0, 1, 3, 4, 6 (the
/// H32 column table), so whole groups go eight bytes in, five out.
inline fn gather(buf: *align(4) LayerBuf, full: *align(4) const FullBuf, cols: *const [out_w]u16, from: usize, to: usize) void {
    if (from == 0 and to == out_w) {
        var g: usize = 0;
        while (g < out_w / 5) : (g += 1) {
            const lo = ld32(full[8 + g * 8 ..][0..4]);
            const hi = ld32(full[12 + g * 8 ..][0..4]);
            st32(buf[pad + g * 5 ..][0..4], (lo & 0xFFFF) | ((lo >> 8) & 0xFF0000) | (hi << 24));
            buf[pad + g * 5 + 4] = @truncate(hi >> 16);
        }
        return;
    }
    for (from..to) |i| buf[pad + i] = full[8 + cols[i]];
}

/// Four plane A pixels over four plane B pixels: A wins where it is
/// opaque and either has priority or B is not opaque with priority.
inline fn over(a: u32, b: u32) u32 {
    const hib = nonzero(b) & (b << 1);
    const ma = expand(nonzero(a) & ((a << 1) | ~hib));
    return (a & ma) | (b & ~ma);
}

/// The final pass outside shadow/highlight, four pixels per step: plane A
/// over B (unless `merged` did it while drawing), then a sprite wins where
/// it is opaque and either has priority or the plane pixel is not opaque
/// with priority; transparent is the backdrop.
fn final_pass(comptime merged: bool, ba: *align(4) const LayerBuf, bb: *align(4) const LayerBuf, spr: *align(4) const LayerBuf, any: bool, bd: u8, out: *[out_w]u8) void {
    const bd4: u32 = @as(u32, bd) * ones;
    var k: usize = 0;
    while (k < out_w) : (k += 4) {
        const b = ld32(bb[pad + k ..][0..4]);
        var p = if (merged) b else over(ld32(ba[pad + k ..][0..4]), b);
        var nzp = nonzero(p);
        if (any) {
            const s = ld32(spr[pad + k ..][0..4]);
            if (s != 0) {
                const wins = nonzero(s) & ((s << 1) | ~(nzp & (p << 1)));
                const ms = expand(wins);
                p = (s & ms) | (p & ~ms);
                nzp |= wins;
            }
        }
        const mt = expand(~nzp & highs);
        st32(out[k..][0..4], (p & 0x3F3F3F3F & ~mt) | (bd4 & mt));
    }
}

/// The final pass under shadow/highlight, four pixels per step. A pixel is
/// normal when either plane's tile has priority, else shadowed (the
/// backdrop too). Sprite palette 3 color 14 highlights what is under it
/// (a shadowed pixel becomes normal), color 15 shadows it; color 14 of
/// palettes 0-2 is always normal; other sprite pixels are normal with
/// priority, else take the plane's intensity.
fn final_sh(ba: *align(4) const LayerBuf, bb: *align(4) const LayerBuf, spr: *align(4) const LayerBuf, any: bool, bd: u8, out: *[out_w]u8) void {
    const bd4: u32 = @as(u32, bd) * ones;
    var k: usize = 0;
    while (k < out_w) : (k += 4) {
        const a = ld32(ba[pad + k ..][0..4]);
        const b = ld32(bb[pad + k ..][0..4]);
        const p = over(a, b);
        const nzp = nonzero(p);
        const mt = expand(~nzp & highs);
        const base = (p & 0x3F3F3F3F & ~mt) | (bd4 & mt);
        // Bit 7 where the pixel is at normal intensity.
        const normal = ((a | b) << 1) & highs;
        var q = base | ((~normal & highs) >> 1);
        if (any) {
            const s = ld32(spr[pad + k ..][0..4]);
            const wins = nonzero(s) & ((s << 1) | ~(nzp & (p << 1)));
            if (wins != 0) {
                const sc = s & 0x3F3F3F3F;
                const hl = wins & zero_byte(sc ^ 0x3E3E3E3E);
                const sd = wins & zero_byte(sc ^ 0x3F3F3F3F);
                const c14 = wins & zero_byte((sc & 0x0F0F0F0F) ^ 0x0E0E0E0E) & ~hl;
                const other = wins & ~(hl | sd | c14);
                const lit = ((s << 1) | normal) & highs;
                const m_hl = expand(hl);
                const m_sd = expand(sd);
                const m_c14 = expand(c14);
                const m_o = expand(other);
                q = (q & ~(m_hl | m_sd | m_c14 | m_o)) |
                    ((base | normal) & m_hl) |
                    ((base | 0x40404040) & m_sd) |
                    (sc & m_c14) |
                    ((sc | ((~lit & highs) >> 1)) & m_o);
            }
        }
        st32(out[k..][0..4], q);
    }
}

/// Bit 7 of each byte set where that byte is 0 (bytes at most 0x7F).
inline fn zero_byte(x: u32) u32 {
    return ~(x + 0x7F7F7F7F) & highs;
}

/// Bit 7 of each byte set where that pixel byte's color (bits 0-3) is not 0.
inline fn nonzero(x: u32) u32 {
    return ((x & 0x0F0F0F0F) + 0x7F7F7F7F) & highs;
}

/// Per-byte bit 7 to a 00/FF byte mask (other bits must be clear).
inline fn expand(m: u32) u32 {
    return ((m & highs) >> 7) * 0xFF;
}

inline fn ld32(p: *const [4]u8) u32 {
    return std.mem.readInt(u32, p, .little);
}

inline fn st32(p: *[4]u8, x: u32) void {
    std.mem.writeInt(u32, p, x, .little);
}

/// Palette (bits 4-5) and priority (bit 6) of a name table entry, as a
/// pixel byte's upper bits.
inline fn tile_attr(e: u16) u8 {
    return @truncate((e >> 9) & 0x70);
}

/// Four pixels of entry `e`'s pattern row (offset `r4` = fine row * 4,
/// the entry's vertical flip applied) as four pixel bytes, leftmost in the
/// low byte: the high nibbles of the row word's bytes (`sh` 4, pixels 0,
/// 2, 4, 6) or the low ones (`sh` 0, pixels 1, 3, 5, 7). With the
/// horizontal flip, the other nibble of each byte in the other byte order.
inline fn tile4(vram: *const [0x10000]u8, e: u16, r4: u16, sh: u5) u32 {
    const r = if (e & 0x1000 != 0) r4 ^ 28 else r4;
    const w = be32(vram, (e & 0x7FF) * 32 + r);
    const four = if (e & 0x0800 != 0) (w >> (4 - sh)) & 0x0F0F0F0F else @byteSwap((w >> sh) & 0x0F0F0F0F);
    return four | @as(u32, tile_attr(e)) * ones;
}

/// The big-endian word at even address `a`.
inline fn be16(vram: *const [0x10000]u8, a: u16) u16 {
    return std.mem.readInt(u16, vram[a..][0..2], .big);
}

inline fn be32(vram: *const [0x10000]u8, a: u16) u32 {
    return std.mem.readInt(u32, vram[a..][0..4], .big);
}

/// The eight pixels of a row word in reverse order (horizontal flip).
inline fn nibble_reverse(w: u32) u32 {
    const b = @byteSwap(w);
    return ((b >> 4) & 0x0F0F0F0F) | ((b & 0x0F0F0F0F) << 4);
}
