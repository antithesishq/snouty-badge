//! Pixel processing unit: mode timing, STAT/LY/LYC, scanline renderer.
//! Owner in M1: track B. Registers live in `Gb.io` (0xFF40..0xFF4B); this
//! file owns their side effects via `write_reg` / `read_reg`.
const gb_mod = @import("gb.zig");
const Gb = gb_mod.Gb;
const Reg = gb_mod.Reg;

pub const Mode = enum(u2) { hblank = 0, vblank = 1, oam_scan = 2, drawing = 3 };

pub const Ppu = struct {
    mode: Mode = .oam_scan,
    /// T-cycles elapsed in the current line (0..455).
    line_t: u16 = 0,
    /// Internal window line counter.
    window_line: u8 = 0,
    /// Previous STAT interrupt line, for rising-edge detection.
    stat_line: bool = false,
    /// Scratch for the line being rendered (final shades 0..3).
    line: [gb_mod.screen_w]u8 = @splat(0),
};

pub fn reset(gb: *Gb) void {
    gb.ppu = .{};
    gb.io[Reg.ly] = 0;
}

pub inline fn lcd_on(gb: *const Gb) bool {
    return (gb.io[Reg.lcdc] & 0x80) != 0;
}

/// Advance `m` M-cycles (4 T each). STUB: emits a test pattern once per
/// frame so the frontend has something to show; track B replaces it.
pub fn tick(gb: *Gb, m: u8) void {
    const p = &gb.ppu;
    p.line_t += @as(u16, m) * 4;
    while (p.line_t >= 456) {
        p.line_t -= 456;
        const ly = gb.io[Reg.ly];
        if (ly < gb_mod.screen_h) {
            if (gb.line_sink) |sink| {
                for (&p.line, 0..) |*px, x| px.* = @intCast(((x / 8) + (ly / 8) + gb.frame_count / 16) & 3);
                sink.emit(ly, &p.line);
            }
        }
        if (ly == gb_mod.screen_h - 1) {
            gb.vblank_hit = true;
            gb.request_irq(gb_mod.Irq.vblank);
        }
        gb.io[Reg.ly] = if (ly >= 153) 0 else ly + 1;
    }
}

/// Write to an LCD register (offset 0x40..0x4B). STUB stores the value;
/// track B adds the side effects (LCDC off resets LY, STAT bits, LYC, DMA).
pub fn write_reg(gb: *Gb, reg: u8, v: u8) void {
    gb.io[reg] = v;
}

pub fn read_reg(gb: *Gb, reg: u8) u8 {
    return gb.io[reg];
}
