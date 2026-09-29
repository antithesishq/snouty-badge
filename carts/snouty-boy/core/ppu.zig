//! Pixel processing unit: mode timing, STAT/LY/LYC, scanline renderer.
//! Owner in M1: track B. Registers live in `Gb.io` (0xFF40..0xFF4B); this
//! file owns their side effects via `write_reg` / `read_reg`.
//!
//! Scanline accuracy (SPEC.md section 4): each visible line is rendered in
//! one go when it enters mode 3, with the registers as they are then.
//! `io[Reg.stat]` is kept fully composed (bit 7 set, enables, coincidence,
//! mode) so a raw read of `gb.io` is also correct.
const gb_mod = @import("gb.zig");
const Gb = gb_mod.Gb;
const Reg = gb_mod.Reg;
const Irq = gb_mod.Irq;
const mmu = @import("mmu.zig");

pub const Mode = enum(u2) { hblank = 0, vblank = 1, oam_scan = 2, drawing = 3 };

/// T-cycle positions within a 456 T line.
const t_drawing: u16 = 80;
const t_hblank: u16 = 80 + 172;
const t_line: u16 = 456;

pub const Ppu = struct {
    mode: Mode = .oam_scan,
    /// T-cycles elapsed in the current line (0..455).
    line_t: u16 = 0,
    /// `line_t` at which the next mode change happens (fast path in `tick`).
    next_t: u16 = t_drawing,
    /// Internal window line counter: reset per frame, incremented only on
    /// lines where the window was drawn.
    window_line: u8 = 0,
    /// LY == WY has been seen this frame (the window can start).
    wy_hit: bool = false,
    /// Previous STAT interrupt line, for rising-edge detection.
    stat_line: bool = false,
    /// Scratch for the line being rendered (final shades 0..3, or CGB
    /// colour indices, see `gb_mod.LineSink`).
    line: [gb_mod.screen_w]u8 = @splat(0),
    /// CGB palette RAM, 8 palettes x 4 colours x RGB555 little endian
    /// (BCPD / OCPD), indexed by BCPS / OCPS bits 0..5. The CGB boot ROM
    /// leaves every BG colour white (0x7FFF); OBJ palette RAM is undefined
    /// after boot, white here too.
    bg_pal: [64]u8 = white_pal,
    obj_pal: [64]u8 = white_pal,
};

/// 32 colours of 0x7FFF, little endian.
const white_pal: [64]u8 = blk: {
    var t: [64]u8 = undefined;
    for (0..32) |i| {
        t[i * 2] = 0xFF;
        t[i * 2 + 1] = 0x7F;
    }
    break :blk t;
};

// ---- STAT register bits ----
const stat_coinc: u8 = 1 << 2;
const stat_en_hblank: u8 = 1 << 3;
const stat_en_vblank: u8 = 1 << 4;
const stat_en_oam: u8 = 1 << 5;
const stat_en_lyc: u8 = 1 << 6;
const stat_writable: u8 = 0x78;

pub fn reset(gb: *Gb) void {
    gb.ppu = .{};
    gb.io[Reg.ly] = 0;
    if (!lcd_on(gb)) {
        gb.ppu.mode = .hblank;
        gb.ppu.next_t = t_line;
    }
    compose_stat(gb);
    gb.ppu.stat_line = stat_line(gb);
}

pub inline fn lcd_on(gb: *const Gb) bool {
    return (gb.io[Reg.lcdc] & 0x80) != 0;
}

/// Advance `dots` dots (4 per M-cycle at normal speed, 2 in double speed).
/// Inlined into the per-instruction tick: only a mode change calls out.
pub inline fn tick(gb: *Gb, dots: u16) void {
    if (!lcd_on(gb)) return;
    const p = &gb.ppu;
    p.line_t += dots;
    if (p.line_t >= p.next_t) advance(gb);
}

/// The mode changes `tick` has passed (at least one).
fn advance(gb: *Gb) void {
    const p = &gb.ppu;
    while (p.line_t >= p.next_t) {
        switch (p.mode) {
            .oam_scan => {
                set_mode(gb, .drawing, t_hblank);
                if (gb.is_cgb()) render_line_cgb(gb, gb.io[Reg.ly]) else render_line(gb, gb.io[Reg.ly]);
            },
            .drawing => {
                // Mode 3 only happens on visible lines 0..143.
                set_mode(gb, .hblank, t_line);
                if (gb.is_cgb()) mmu.hdma_hblank(gb);
            },
            .hblank, .vblank => next_line(gb),
        }
    }
}

fn set_mode(gb: *Gb, mode: Mode, next_t: u16) void {
    gb.ppu.mode = mode;
    gb.ppu.next_t = next_t;
    compose_stat(gb);
    update_stat_irq(gb);
}

fn next_line(gb: *Gb) void {
    const p = &gb.ppu;
    p.line_t -= t_line;
    var ly = gb.io[Reg.ly] + 1;
    if (ly == gb_mod.screen_h) {
        p.mode = .vblank;
        p.next_t = t_line;
        gb.vblank_hit = true;
        gb.request_irq(Irq.vblank);
    } else if (ly > 153) {
        ly = 0;
        p.window_line = 0;
        p.wy_hit = false;
        p.mode = .oam_scan;
        p.next_t = t_drawing;
    } else if (ly < gb_mod.screen_h) {
        p.mode = .oam_scan;
        p.next_t = t_drawing;
    } else {
        p.next_t = t_line;
    }
    gb.io[Reg.ly] = ly;
    compose_stat(gb);
    update_stat_irq(gb);
}

/// Rewrite the read-only STAT bits (mode, coincidence) and bit 7.
fn compose_stat(gb: *Gb) void {
    const coinc: u8 = if (gb.io[Reg.ly] == gb.io[Reg.lyc]) stat_coinc else 0;
    gb.io[Reg.stat] = 0x80 | (gb.io[Reg.stat] & stat_writable) | coinc | @backingInt(gb.ppu.mode);
}

/// The shared STAT interrupt line: OR of the enabled conditions.
fn stat_line(gb: *const Gb) bool {
    const s = gb.io[Reg.stat];
    const hit = switch (gb.ppu.mode) {
        .hblank => s & stat_en_hblank,
        .vblank => s & stat_en_vblank,
        .oam_scan => s & stat_en_oam,
        .drawing => 0,
    };
    return hit != 0 or (s & stat_en_lyc != 0 and s & stat_coinc != 0);
}

/// Request Irq.stat on a rising edge of the STAT line only (STAT blocking).
fn update_stat_irq(gb: *Gb) void {
    const now = stat_line(gb);
    if (now and !gb.ppu.stat_line) gb.request_irq(Irq.stat);
    gb.ppu.stat_line = now;
}

/// Write to an LCD register (offset 0x40..0x4B). DMA (0x46) is handled by
/// the MMU; if it reaches here it is only stored.
pub fn write_reg(gb: *Gb, reg: u8, v: u8) void {
    switch (reg) {
        Reg.lcdc => {
            const was_on = lcd_on(gb);
            gb.io[Reg.lcdc] = v;
            const p = &gb.ppu;
            if (was_on and v & 0x80 == 0) {
                // LCD off: LY=0, mode 0, nothing rendered until it is back.
                gb.io[Reg.ly] = 0;
                p.line_t = 0;
                p.mode = .hblank;
                p.next_t = t_line;
                p.window_line = 0;
                p.wy_hit = false;
                compose_stat(gb);
                p.stat_line = false;
            } else if (!was_on and v & 0x80 != 0) {
                // LCD on: restart at line 0 in mode 2 (simplified).
                gb.io[Reg.ly] = 0;
                p.line_t = 0;
                p.mode = .oam_scan;
                p.next_t = t_drawing;
                p.window_line = 0;
                p.wy_hit = false;
                compose_stat(gb);
                update_stat_irq(gb);
            }
        },
        Reg.stat => {
            gb.io[Reg.stat] = (gb.io[Reg.stat] & ~stat_writable) | (v & stat_writable);
            compose_stat(gb);
            if (lcd_on(gb)) update_stat_irq(gb);
        },
        Reg.ly => {},
        Reg.lyc => {
            gb.io[Reg.lyc] = v;
            compose_stat(gb);
            if (lcd_on(gb)) update_stat_irq(gb);
        },
        // CGB palette registers (the MMU only dispatches these in CGB
        // mode). Real hardware ignores BCPD/OCPD access during mode 3; the
        // core does not model that lock (the scanline renderer has already
        // drawn the line by then).
        Reg.bcps, Reg.ocps => gb.io[reg] = v & 0xBF,
        Reg.bcpd => pal_write(gb, Reg.bcps, &gb.ppu.bg_pal, v),
        Reg.ocpd => pal_write(gb, Reg.ocps, &gb.ppu.obj_pal, v),
        Reg.opri => gb.io[Reg.opri] = v & 1,
        else => gb.io[reg] = v,
    }
}

pub fn read_reg(gb: *Gb, reg: u8) u8 {
    return switch (reg) {
        Reg.stat => gb.io[Reg.stat] | 0x80,
        Reg.bcps, Reg.ocps => gb.io[reg] | 0x40,
        Reg.bcpd => gb.ppu.bg_pal[gb.io[Reg.bcps] & 0x3F],
        Reg.ocpd => gb.ppu.obj_pal[gb.io[Reg.ocps] & 0x3F],
        Reg.opri => gb.io[Reg.opri] | 0xFE,
        else => gb.io[reg],
    };
}

/// BCPD/OCPD write: store at the index in the spec register, then advance
/// the index (bits 0..5, wrapping) if its auto-increment bit 7 is set.
fn pal_write(gb: *Gb, spec_reg: u8, pal: *[64]u8, v: u8) void {
    const s = gb.io[spec_reg];
    pal[s & 0x3F] = v;
    if (s & 0x80 != 0) gb.io[spec_reg] = 0x80 | ((s + 1) & 0x3F);
    gb.pal_dirty = true;
}

// ---- Renderer ----

/// `spread[b]` puts bit i of b at bit 2i, so a tile row (lo, hi) becomes one
/// u16 of 2-bit color indices: `spread[lo] | spread[hi] << 1`, leftmost
/// pixel (bit 7) in bits 15..14.
const spread: [256]u16 = blk: {
    @setEvalBranchQuota(10_000);
    var t: [256]u16 = undefined;
    for (0..256) |b| {
        var v: u16 = 0;
        for (0..8) |i| {
            if ((b >> i) & 1 != 0) v |= 1 << (2 * i);
        }
        t[b] = v;
    }
    break :blk t;
};

/// Color-index buffers hold screen x at index x + 8, with slack on both
/// sides so partial tiles and off-screen sprites need no bounds checks.
const buf_off = 8;
const buf_len = gb_mod.screen_w + 16;

inline fn row_word(gb: *const Gb, addr: usize) u16 {
    return spread[gb.vram[addr]] | (spread[gb.vram[addr + 1]] << 1);
}

/// VRAM offset of a BG/window tile, LCDC.4 selecting 0x8000 unsigned or
/// 0x8800 signed (tile 0 at 0x9000).
inline fn bg_tile_addr(idx: u8, lcdc: u8) usize {
    if (lcdc & 0x10 != 0) return @as(usize, idx) * 16;
    return 0x800 + @as(usize, idx ^ 0x80) * 16;
}

inline fn put8(buf: *[buf_len]u8, pos: usize, w: u16) void {
    inline for (0..8) |k| buf[pos + k] = @truncate((w >> (14 - 2 * k)) & 3);
}

fn render_line(gb: *Gb, ly: u8) void {
    if (ly >= gb_mod.screen_h) return;
    const p = &gb.ppu;
    const io = &gb.io;
    const lcdc = io[Reg.lcdc];
    if (ly == io[Reg.wy]) p.wy_hit = true;

    // Background and window color indices.
    var ci: [buf_len]u8 = undefined;
    if (lcdc & 0x01 != 0) {
        const scx = io[Reg.scx];
        const y = ly +% io[Reg.scy];
        const map: usize = (if (lcdc & 0x08 != 0) @as(usize, 0x1C00) else 0x1800) + @as(usize, y >> 3) * 32;
        const fine_y: usize = @as(usize, y & 7) * 2;
        const col0: usize = scx >> 3;
        const start: usize = buf_off - @as(usize, scx & 7);
        for (0..21) |t| {
            const idx = gb.vram[map + ((col0 + t) & 31)];
            put8(&ci, start + t * 8, row_word(gb, bg_tile_addr(idx, lcdc) + fine_y));
        }

        const wx = io[Reg.wx];
        if (lcdc & 0x20 != 0 and p.wy_hit and wx <= 166) {
            const wl = p.window_line;
            const wmap: usize = (if (lcdc & 0x40 != 0) @as(usize, 0x1C00) else 0x1800) + @as(usize, wl >> 3) * 32;
            const wfine: usize = @as(usize, wl & 7) * 2;
            // Screen x = wx - 7, buffer index = x + 8.
            var pos: usize = @as(usize, wx) + 1;
            var t: usize = 0;
            while (pos < buf_off + gb_mod.screen_w) : ({
                pos += 8;
                t += 1;
            }) {
                const idx = gb.vram[wmap + t];
                put8(&ci, pos, row_word(gb, bg_tile_addr(idx, lcdc) + wfine));
            }
            p.window_line = wl + 1;
        }
    } else {
        @memset(&ci, 0);
    }

    const bgp = io[Reg.bgp];
    const bg_pal = [4]u8{ bgp & 3, (bgp >> 2) & 3, (bgp >> 4) & 3, bgp >> 6 };

    if (lcdc & 0x02 == 0) {
        for (&p.line, ci[buf_off..][0..gb_mod.screen_w]) |*px, c| px.* = bg_pal[c];
    } else {
        var obj: [buf_len]u8 = @splat(0);
        draw_sprites(gb, ly, lcdc, &obj);
        // obj byte: 0 = none, else 4 | (8 if BG-over-OBJ) | shade.
        for (&p.line, ci[buf_off..][0..gb_mod.screen_w], obj[buf_off..][0..gb_mod.screen_w]) |*px, c, o| {
            px.* = if (o != 0 and (o & 8 == 0 or c == 0)) o & 3 else bg_pal[c];
        }
    }

    if (gb.line_sink) |sink| sink.emit(ly, &p.line);
}

fn draw_sprites(gb: *const Gb, ly: u8, lcdc: u8, obj: *[buf_len]u8) void {
    const h: u8 = if (lcdc & 0x04 != 0) 16 else 8;

    // OAM scan: first 10 sprites covering this line, in OAM order.
    var sel: [10]u8 = undefined;
    var n: usize = 0;
    for (0..40) |i| {
        const row = ly +% 16 -% gb.oam[i * 4];
        if (row < h) {
            sel[n] = @intCast(i);
            n += 1;
            if (n == 10) break;
        }
    }
    // Stable insertion sort by X: lower X first, ties keep OAM order.
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const s = sel[i];
        const sx = gb.oam[@as(usize, s) * 4 + 1];
        var j = i;
        while (j > 0 and gb.oam[@as(usize, sel[j - 1]) * 4 + 1] > sx) : (j -= 1) sel[j] = sel[j - 1];
        sel[j] = s;
    }

    // Highest priority first; a pixel belongs to the first opaque sprite.
    for (sel[0..n]) |s| {
        const o = @as(usize, s) * 4;
        const sx = gb.oam[o + 1];
        if (sx == 0 or sx >= 168) continue;
        const attr = gb.oam[o + 3];
        var row = ly +% 16 -% gb.oam[o];
        if (attr & 0x40 != 0) row = h - 1 - row;
        var tile = gb.oam[o + 2];
        if (h == 16) tile &= 0xFE;
        const addr = @as(usize, tile) * 16 + @as(usize, row) * 2;
        var lo = gb.vram[addr];
        var hi = gb.vram[addr + 1];
        if (attr & 0x20 != 0) {
            lo = @bitReverse(lo);
            hi = @bitReverse(hi);
        }
        const w = spread[lo] | (spread[hi] << 1);
        if (w == 0) continue;
        const pal = gb.io[if (attr & 0x10 != 0) Reg.obp1 else Reg.obp0];
        const flags: u8 = 4 | (if (attr & 0x80 != 0) @as(u8, 8) else 0);
        // Buffer index of screen x = sx - 8 is sx.
        const dst = obj[sx..][0..8];
        inline for (0..8) |k| {
            const c: u8 = @truncate((w >> (14 - 2 * k)) & 3);
            if (c != 0 and dst[k] == 0) dst[k] = flags | ((pal >> @intCast(c * 2)) & 3);
        }
    }
}

// ---- CGB renderer (SPEC.md 19.1, 19.2) ----
//
// BG/window buffer byte: bit 7 = BG-to-OAM priority (map attribute bit 7),
// bits 4..2 = palette, bits 1..0 = colour, so `b & 0x1F` is the output
// index. OBJ buffer byte: 0 = none, else bit 7 = OBJ-behind-BG (OAM
// attribute bit 7) and bits 5..0 = 32 + palette * 4 + colour (never 0).

/// Eight pixels of a tile row, each `base | colour`.
inline fn put8_attr(buf: *[buf_len]u8, pos: usize, w: u16, base: u8) void {
    inline for (0..8) |k| buf[pos + k] = base | @as(u8, @truncate((w >> (14 - 2 * k)) & 3));
}

/// One BG/window tile row: `map_off` is the map entry's offset in bank 0;
/// its attributes sit at the same offset in bank 1 (+0x2000).
inline fn cgb_tile_row(gb: *const Gb, map_off: usize, lcdc: u8, fine_y: u8, base: *u8) u16 {
    const idx = gb.vram[map_off];
    const attr = gb.vram[map_off + 0x2000];
    const row: usize = if (attr & 0x40 != 0) 7 - fine_y else fine_y;
    const bank: usize = @as(usize, attr & 0x08) << 10; // bit 3 -> 0x2000
    const addr = bank + bg_tile_addr(idx, lcdc) + row * 2;
    var lo = gb.vram[addr];
    var hi = gb.vram[addr + 1];
    if (attr & 0x20 != 0) {
        lo = @bitReverse(lo);
        hi = @bitReverse(hi);
    }
    base.* = (attr & 0x80) | ((attr & 7) << 2);
    return spread[lo] | (spread[hi] << 1);
}

fn render_line_cgb(gb: *Gb, ly: u8) void {
    if (ly >= gb_mod.screen_h) return;
    const p = &gb.ppu;
    const io = &gb.io;
    const lcdc = io[Reg.lcdc];
    if (ly == io[Reg.wy]) p.wy_hit = true;

    // Background: always drawn in CGB mode (LCDC.0 is master priority).
    var ci: [buf_len]u8 = undefined;
    {
        const scx = io[Reg.scx];
        const y = ly +% io[Reg.scy];
        const map: usize = (if (lcdc & 0x08 != 0) @as(usize, 0x1C00) else 0x1800) + @as(usize, y >> 3) * 32;
        const col0: usize = scx >> 3;
        const start: usize = buf_off - @as(usize, scx & 7);
        for (0..21) |t| {
            var base: u8 = 0;
            const w = cgb_tile_row(gb, map + ((col0 + t) & 31), lcdc, y & 7, &base);
            put8_attr(&ci, start + t * 8, w, base);
        }
    }

    // Window: LCDC.5 alone enables it in CGB mode.
    const wx = io[Reg.wx];
    if (lcdc & 0x20 != 0 and p.wy_hit and wx <= 166) {
        const wl = p.window_line;
        const wmap: usize = (if (lcdc & 0x40 != 0) @as(usize, 0x1C00) else 0x1800) + @as(usize, wl >> 3) * 32;
        var pos: usize = @as(usize, wx) + 1;
        var t: usize = 0;
        while (pos < buf_off + gb_mod.screen_w) : ({
            pos += 8;
            t += 1;
        }) {
            var base: u8 = 0;
            const w = cgb_tile_row(gb, wmap + t, lcdc, wl & 7, &base);
            put8_attr(&ci, pos, w, base);
        }
        p.window_line = wl + 1;
    }

    if (lcdc & 0x02 == 0) {
        for (&p.line, ci[buf_off..][0..gb_mod.screen_w]) |*px, c| px.* = c & 0x1F;
    } else {
        var obj: [buf_len]u8 = @splat(0);
        draw_sprites_cgb(gb, ly, lcdc, &obj);
        // LCDC.0 = 0: sprites always win. Otherwise BG colour 0 loses to
        // any sprite, BG colours 1..3 win if either priority bit is set.
        const pm: u8 = if (lcdc & 0x01 != 0) 0x80 else 0;
        for (&p.line, ci[buf_off..][0..gb_mod.screen_w], obj[buf_off..][0..gb_mod.screen_w]) |*px, c, o| {
            px.* = if (o != 0 and (c & 3 == 0 or (c | o) & pm == 0)) o & 0x3F else c & 0x1F;
        }
    }

    if (gb.line_sink) |sink| sink.emit(ly, &p.line);
}

fn draw_sprites_cgb(gb: *const Gb, ly: u8, lcdc: u8, obj: *[buf_len]u8) void {
    const h: u8 = if (lcdc & 0x04 != 0) 16 else 8;

    // OAM scan: first 10 sprites covering this line, in OAM order.
    var sel: [10]u8 = undefined;
    var n: usize = 0;
    for (0..40) |i| {
        const row = ly +% 16 -% gb.oam[i * 4];
        if (row < h) {
            sel[n] = @intCast(i);
            n += 1;
            if (n == 10) break;
        }
    }
    // OPRI bit 0 = 0 (CGB default): OAM order is the priority, as selected.
    // OPRI bit 0 = 1: DMG coordinate priority, stable sort by X.
    if (gb.io[Reg.opri] & 1 != 0) {
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const s = sel[i];
            const sx = gb.oam[@as(usize, s) * 4 + 1];
            var j = i;
            while (j > 0 and gb.oam[@as(usize, sel[j - 1]) * 4 + 1] > sx) : (j -= 1) sel[j] = sel[j - 1];
            sel[j] = s;
        }
    }

    for (sel[0..n]) |s| {
        const o = @as(usize, s) * 4;
        const sx = gb.oam[o + 1];
        if (sx == 0 or sx >= 168) continue;
        const attr = gb.oam[o + 3];
        var row = ly +% 16 -% gb.oam[o];
        if (attr & 0x40 != 0) row = h - 1 - row;
        var tile = gb.oam[o + 2];
        if (h == 16) tile &= 0xFE;
        const bank: usize = @as(usize, attr & 0x08) << 10;
        const addr = bank + @as(usize, tile) * 16 + @as(usize, row) * 2;
        var lo = gb.vram[addr];
        var hi = gb.vram[addr + 1];
        if (attr & 0x20 != 0) {
            lo = @bitReverse(lo);
            hi = @bitReverse(hi);
        }
        const w = spread[lo] | (spread[hi] << 1);
        if (w == 0) continue;
        const base: u8 = (attr & 0x80) | 32 | ((attr & 7) << 2);
        const dst = obj[sx..][0..8];
        inline for (0..8) |k| {
            const c: u8 = @truncate((w >> (14 - 2 * k)) & 3);
            if (c != 0 and dst[k] == 0) dst[k] = base | c;
        }
    }
}
