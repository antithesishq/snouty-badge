//! PPU unit tests on synthetic VRAM/OAM. Owner in M1: track B.
//! Each test builds a `Gb` around a zeroed 32 KB ROM, pokes VRAM/OAM/IO
//! directly and ticks the PPU alone (no CPU involved).
const std = @import("std");
const core = @import("core");
const Gb = core.Gb;
const Reg = core.Reg;
const Irq = core.Irq;
const ppu = core.ppu;
const expectEqual = std.testing.expectEqual;

const zero_rom: [0x8000]u8 = @splat(0);

const Capture = struct {
    frame: [core.screen_h][core.screen_w]u8 = @splat(@splat(0xFF)),
    count: u32 = 0,
    last_ly: ?u8 = null,

    fn emit(ctx: *anyopaque, ly: u8, line: *const [core.screen_w]u8) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        self.frame[ly] = line.*;
        self.count += 1;
        self.last_ly = ly;
    }

    fn sink(self: *Capture) core.LineSink {
        return .{ .ctx = self, .func = emit };
    }
};

/// LCD on, BG on, 0x8000 tile data, 0x9800 BG map, identity palettes.
fn setup(gb: *Gb, cap: *Capture) void {
    gb.* = Gb.init_slice(&zero_rom, .dmg, &.{});
    gb.line_sink = cap.sink();
    ppu.write_reg(gb, Reg.lcdc, 0x91);
    gb.io[Reg.bgp] = 0xE4;
    gb.io[Reg.obp0] = 0xE4;
    gb.io[Reg.obp1] = 0xE4;
    gb.io[Reg.if_] = 0;
}

/// Tile `i` in the 0x8000 area with every row = (lo, hi).
fn tile_rows(gb: *Gb, i: usize, lo: u8, hi: u8) void {
    for (0..8) |r| tile_row(gb, i, r, lo, hi);
}

fn tile_row(gb: *Gb, i: usize, r: usize, lo: u8, hi: u8) void {
    gb.vram[i * 16 + r * 2] = lo;
    gb.vram[i * 16 + r * 2 + 1] = hi;
}

/// Tile `i` filled with color index `c`.
fn solid(gb: *Gb, i: usize, c: u2) void {
    tile_rows(gb, i, if (c & 1 != 0) 0xFF else 0, if (c & 2 != 0) 0xFF else 0);
}

fn fill_map(gb: *Gb, base: usize, tile: u8) void {
    @memset(gb.vram[base .. base + 0x400], tile);
}

fn sprite(gb: *Gb, i: usize, y: u8, x: u8, tile: u8, attr: u8) void {
    gb.oam[i * 4 + 0] = y;
    gb.oam[i * 4 + 1] = x;
    gb.oam[i * 4 + 2] = tile;
    gb.oam[i * 4 + 3] = attr;
}

/// Tick until line `ly` is emitted (again).
fn run_to_line(gb: *Gb, cap: *Capture, ly: u8) !void {
    cap.last_ly = null;
    var guard: u32 = 0;
    while (cap.last_ly != ly) : (guard += 1) {
        if (guard > core.frame_m_cycles * 2) return error.LineNeverRendered;
        ppu.tick(gb, 4);
    }
}

fn run_frame(gb: *Gb, cap: *Capture) !void {
    try run_to_line(gb, cap, core.screen_h - 1);
}

fn expect_span(line: []const u8, x0: usize, x1: usize, shade: u8) !void {
    for (x0..x1) |x| {
        if (line[x] != shade) {
            std.debug.print("x={d}: expected shade {d}, got {d}\n", .{ x, shade, line[x] });
            return error.TestExpectedEqual;
        }
    }
}

test "ppu bg pixel order and SCX/SCY wrap" {
    var gb: Gb = undefined;
    var cap: Capture = .{};
    setup(&gb, &cap);
    // Tile 2: pixels 0,1,2,3,0,1,2,3 left to right.
    tile_rows(&gb, 2, 0x55, 0x33);
    solid(&gb, 1, 3);
    gb.vram[0x1800] = 2; // map (0,0)
    gb.vram[0x1800 + 31 * 32 + 31] = 1; // map (31,31)
    try run_frame(&gb, &cap);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 0, 1, 2, 3, 0 }, cap.frame[0][0..9]);

    // SCX=252, SCY=250: line 0 shows map row 31 (fine y 2); x 0..3 are
    // the right half of column 31, then column 0 (wrapped).
    gb.io[Reg.scx] = 252;
    gb.io[Reg.scy] = 250;
    try run_frame(&gb, &cap);
    try expect_span(&cap.frame[0], 0, 4, 3);
    try expect_span(&cap.frame[0], 4, 160, 0);
    try expect_span(&cap.frame[5], 0, 4, 3);
    // Line 6 is BG y 0: map row 0, tile 2 starts at x 4.
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 1, 2, 3 }, cap.frame[6][0..8]);

    // Fine SCX within a tile.
    gb.io[Reg.scx] = 2;
    gb.io[Reg.scy] = 0;
    try run_frame(&gb, &cap);
    try std.testing.expectEqualSlices(u8, &.{ 2, 3, 0, 1, 2, 3, 0 }, cap.frame[0][0..7]);
}

test "ppu bg signed tile addressing, map select, palette, disable" {
    var gb: Gb = undefined;
    var cap: Capture = .{};
    setup(&gb, &cap);
    // 0x8800 mode: index 0 -> 0x9000, index 0x80 -> 0x8800.
    solid(&gb, 0x100, 1); // 0x9000
    solid(&gb, 0x80, 2); // 0x8800
    solid(&gb, 0, 3); // 0x8000, used in unsigned mode only
    fill_map(&gb, 0x1C00, 0);
    gb.vram[0x1C01] = 0x80;
    ppu.write_reg(&gb, Reg.lcdc, 0x89); // LCD, 9C00 map, 8800 data, BG
    gb.io[Reg.bgp] = 0x1B; // reversed: color c -> shade 3 - c
    try run_frame(&gb, &cap);
    try expect_span(&cap.frame[0], 0, 8, 2);
    try expect_span(&cap.frame[0], 8, 16, 1);
    try expect_span(&cap.frame[0], 16, 160, 2);

    // BG disabled: every pixel is color 0 through BGP.
    ppu.write_reg(&gb, Reg.lcdc, 0x80);
    try run_frame(&gb, &cap);
    try expect_span(&cap.frame[77], 0, 160, 3);
}

test "ppu window cut-in and internal line counter" {
    var gb: Gb = undefined;
    var cap: Capture = .{};
    setup(&gb, &cap);
    solid(&gb, 0, 0);
    // Tile 3: rows 0..4 color 3, rows 5..7 color 1.
    for (0..8) |r| tile_row(&gb, 3, r, 0xFF, if (r < 5) 0xFF else 0);
    fill_map(&gb, 0x1800, 0);
    fill_map(&gb, 0x1C00, 3);
    ppu.write_reg(&gb, Reg.lcdc, 0xF1); // window on, window map 9C00
    gb.io[Reg.wy] = 10;
    gb.io[Reg.wx] = 7 + 80;
    try run_to_line(&gb, &cap, 14);
    try expect_span(&cap.frame[9], 0, 160, 0);
    try expect_span(&cap.frame[10], 0, 80, 0);
    try expect_span(&cap.frame[10], 80, 160, 3);
    // Hide the window (WX off screen) for lines 15..30: the counter stops.
    gb.io[Reg.wx] = 200;
    try run_to_line(&gb, &cap, 30);
    try expect_span(&cap.frame[20], 0, 160, 0);
    gb.io[Reg.wx] = 7 + 80;
    try run_to_line(&gb, &cap, 31);
    // Window line 5 (not 21): tile 3 row 5 -> color 1.
    try expect_span(&cap.frame[31], 0, 80, 0);
    try expect_span(&cap.frame[31], 80, 160, 1);
    // Next frame the counter restarts from 0.
    try run_to_line(&gb, &cap, 10);
    try expect_span(&cap.frame[10], 80, 160, 3);

    // WX < 7: window starts left of the screen, clipped.
    gb.io[Reg.wx] = 3;
    gb.io[Reg.wy] = 0;
    tile_rows(&gb, 3, 0x0F, 0x00); // pixels 4..7 color 1
    try run_frame(&gb, &cap); // finish the current frame
    try run_frame(&gb, &cap);
    try expect_span(&cap.frame[0], 0, 4, 1); // window x 4..7 at screen 0..3
    try expect_span(&cap.frame[0], 4, 8, 0);
}

test "ppu sprite over bg, transparency and palettes" {
    var gb: Gb = undefined;
    var cap: Capture = .{};
    setup(&gb, &cap);
    solid(&gb, 0, 1);
    tile_rows(&gb, 2, 0xF0, 0xF0); // left half color 3, right half transparent
    ppu.write_reg(&gb, Reg.lcdc, 0x93);
    sprite(&gb, 0, 16 + 20, 8 + 30, 2, 0x00);
    sprite(&gb, 1, 16 + 20, 8 + 60, 2, 0x10); // OBP1
    gb.io[Reg.obp1] = 0x6C; // color 3 -> shade 1
    gb.io[Reg.obp0] = 0xE4;
    try run_frame(&gb, &cap);
    try expect_span(&cap.frame[19], 0, 160, 1);
    try expect_span(&cap.frame[20], 0, 30, 1);
    try expect_span(&cap.frame[20], 30, 34, 3);
    try expect_span(&cap.frame[20], 34, 60, 1);
    try expect_span(&cap.frame[27], 30, 34, 3);
    try expect_span(&cap.frame[28], 30, 34, 1);
    try expect_span(&cap.frame[20], 60, 64, 1);
    gb.io[Reg.obp1] = 0x9C; // color 3 -> shade 2
    try run_frame(&gb, &cap);
    try expect_span(&cap.frame[20], 60, 64, 2);

    // Partially off screen at the left and right edges.
    sprite(&gb, 0, 16 + 20, 4, 2, 0x00); // screen x -4: nothing visible
    sprite(&gb, 1, 16 + 20, 8 + 158, 2, 0x00); // screen x 158..159 visible
    try run_frame(&gb, &cap);
    try expect_span(&cap.frame[20], 0, 158, 1);
    try expect_span(&cap.frame[20], 158, 160, 3);

    // Sprites disabled.
    ppu.write_reg(&gb, Reg.lcdc, 0x91);
    try run_frame(&gb, &cap);
    try expect_span(&cap.frame[20], 0, 160, 1);
}

test "ppu bg-over-obj priority uses bg color index" {
    var gb: Gb = undefined;
    var cap: Capture = .{};
    setup(&gb, &cap);
    tile_rows(&gb, 1, 0x0F, 0x00); // pixels 0..3 color 0, 4..7 color 1
    solid(&gb, 2, 3);
    fill_map(&gb, 0x1800, 1);
    gb.io[Reg.bgp] = 0xE7; // color 0 -> shade 3, color 1 -> shade 1
    gb.io[Reg.obp0] = 0x80; // color 3 -> shade 2
    ppu.write_reg(&gb, Reg.lcdc, 0x93);
    sprite(&gb, 0, 16, 8 + 16, 2, 0x80);
    try run_frame(&gb, &cap);
    try expect_span(&cap.frame[0], 16, 20, 2); // over BG color 0: sprite
    try expect_span(&cap.frame[0], 20, 24, 1); // over BG color 1: BG
    try expect_span(&cap.frame[0], 8, 12, 3);

    // A hidden higher-priority sprite still masks a lower-priority one.
    gb.io[Reg.obp1] = 0x00; // every color -> shade 0
    sprite(&gb, 1, 16, 8 + 17, 2, 0x10); // x 17..24, no BG priority, OBP1
    try run_frame(&gb, &cap);
    try expect_span(&cap.frame[0], 16, 20, 2);
    try expect_span(&cap.frame[0], 20, 24, 1); // sprite 0 wins, hidden by BG
    try expect_span(&cap.frame[0], 24, 25, 0); // only sprite 1 covers x 24
}

test "ppu sprite x and y flips" {
    var gb: Gb = undefined;
    var cap: Capture = .{};
    setup(&gb, &cap);
    tile_row(&gb, 4, 0, 0x80, 0x00); // only pixel (0,0) is set, color 1
    ppu.write_reg(&gb, Reg.lcdc, 0x93);
    sprite(&gb, 0, 16 + 10, 8 + 10, 4, 0x00);
    sprite(&gb, 1, 16 + 10, 8 + 30, 4, 0x20);
    sprite(&gb, 2, 16 + 10, 8 + 50, 4, 0x40);
    sprite(&gb, 3, 16 + 10, 8 + 70, 4, 0x60);
    try run_frame(&gb, &cap);
    const top = &cap.frame[10];
    const bot = &cap.frame[17];
    try expectEqual(@as(u8, 1), top[10]);
    try expect_span(top, 11, 30, 0);
    try expectEqual(@as(u8, 1), top[37]);
    try expect_span(top, 30, 37, 0);
    try expect_span(top, 50, 80, 0);
    try expect_span(bot, 0, 50, 0);
    try expectEqual(@as(u8, 1), bot[50]);
    try expect_span(bot, 51, 77, 0);
    try expectEqual(@as(u8, 1), bot[77]);
}

test "ppu 10 sprites per line by OAM order, x priority" {
    var gb: Gb = undefined;
    var cap: Capture = .{};
    setup(&gb, &cap);
    solid(&gb, 2, 3);
    ppu.write_reg(&gb, Reg.lcdc, 0x93);
    // 12 sprites on line 0; OAM entries 10 and 11 have the lowest X but are
    // dropped because selection is by OAM order.
    for (0..12) |i| sprite(&gb, i, 16, @intCast(8 + 10 * (11 - i)), 2, 0);
    try run_frame(&gb, &cap);
    try expect_span(&cap.frame[0], 0, 20, 0);
    for (0..10) |k| {
        const x = 20 + 10 * k;
        try expect_span(&cap.frame[0], x, x + 8, 3);
        try expect_span(&cap.frame[0], x + 8, x + 10, 0);
    }
    // A sprite at X=0 (hidden) still counts toward the limit.
    @memset(&gb.oam, 0);
    sprite(&gb, 0, 16, 0, 2, 0);
    for (1..11) |i| sprite(&gb, i, 16, @intCast(8 + 10 * i), 2, 0);
    try run_frame(&gb, &cap);
    try expect_span(&cap.frame[0], 10, 18, 3);
    try expect_span(&cap.frame[0], 90, 98, 3);
    try expect_span(&cap.frame[0], 100, 108, 0); // 11th candidate dropped

    // Overlap: lower X wins even with a higher OAM index; ties go to the
    // lower OAM index.
    @memset(&gb.oam, 0);
    gb.io[Reg.obp1] = 0x40; // color 3 -> shade 1
    sprite(&gb, 0, 16, 8 + 20, 2, 0x00); // shade 3, x 20..27
    sprite(&gb, 1, 16, 8 + 16, 2, 0x10); // shade 1, x 16..23
    sprite(&gb, 2, 16 + 8, 8 + 40, 2, 0x00); // line 8: shade 3 at x 40
    sprite(&gb, 3, 16 + 8, 8 + 40, 2, 0x10); // same X, loses the tie
    try run_frame(&gb, &cap);
    try expect_span(&cap.frame[0], 16, 24, 1);
    try expect_span(&cap.frame[0], 24, 28, 3);
    try expect_span(&cap.frame[8], 40, 48, 3);
}

test "ppu 8x16 sprites ignore tile low bit" {
    var gb: Gb = undefined;
    var cap: Capture = .{};
    setup(&gb, &cap);
    solid(&gb, 4, 1);
    solid(&gb, 5, 2);
    ppu.write_reg(&gb, Reg.lcdc, 0x97);
    sprite(&gb, 0, 16 + 40, 8 + 10, 5, 0x00);
    sprite(&gb, 1, 16 + 40, 8 + 30, 4, 0x40); // Y flip swaps halves
    try run_frame(&gb, &cap);
    try expect_span(&cap.frame[39], 0, 160, 0);
    try expect_span(&cap.frame[40], 10, 18, 1);
    try expect_span(&cap.frame[47], 10, 18, 1);
    try expect_span(&cap.frame[48], 10, 18, 2);
    try expect_span(&cap.frame[55], 10, 18, 2);
    try expect_span(&cap.frame[56], 0, 160, 0);
    try expect_span(&cap.frame[40], 30, 38, 2);
    try expect_span(&cap.frame[48], 30, 38, 1);
}

fn stat_mode(gb: *Gb) u8 {
    return ppu.read_reg(gb, Reg.stat) & 3;
}

test "ppu mode timing, LY and vblank interrupt" {
    var gb: Gb = undefined;
    var cap: Capture = .{};
    setup(&gb, &cap);
    var t: u32 = 0;
    // One line, sampled every M-cycle.
    while (t < 456) : (t += 4) {
        const want: u8 = if (t < 80) 2 else if (t < 252) 3 else 0;
        if (stat_mode(&gb) != want) {
            std.debug.print("t={d}: mode {d}, want {d}\n", .{ t, stat_mode(&gb), want });
            return error.TestExpectedEqual;
        }
        try expectEqual(@as(u8, 0), gb.io[Reg.ly]);
        ppu.tick(&gb, 4);
    }
    try expectEqual(@as(u8, 1), ppu.read_reg(&gb, Reg.ly));
    try expectEqual(@as(u8, 2), stat_mode(&gb));
    try expectEqual(@as(u32, 1), cap.count);

    // LY advances every 456 T with mixed tick sizes.
    var sizes: u32 = 0;
    while (t < 143 * 456) {
        const m: u8 = @intCast(1 + sizes % 6);
        sizes += 1;
        ppu.tick(&gb, @as(u16, m) * 4);
        t += @as(u32, m) * 4;
        try expectEqual(@as(u8, @intCast(t / 456)), gb.io[Reg.ly]);
    }
    try expect(!gb.vblank_hit);
    try expectEqual(@as(u8, 0), gb.io[Reg.if_] & Irq.vblank);
    while (t < 144 * 456) : (t += 4) ppu.tick(&gb, 4);
    try expectEqual(@as(u8, 144), gb.io[Reg.ly]);
    try expect(gb.vblank_hit);
    try expectEqual(Irq.vblank, gb.io[Reg.if_] & Irq.vblank);
    try expectEqual(@as(u8, 1), stat_mode(&gb));
    try expectEqual(@as(u32, 144), cap.count);
    // Stays in mode 1 through line 153, then wraps to line 0 mode 2.
    while (t < 154 * 456 - 4) : (t += 4) {
        ppu.tick(&gb, 4);
        try expectEqual(@as(u8, 1), stat_mode(&gb));
    }
    try expectEqual(@as(u8, 153), gb.io[Reg.ly]);
    ppu.tick(&gb, 4);
    try expectEqual(@as(u8, 0), gb.io[Reg.ly]);
    try expectEqual(@as(u8, 2), stat_mode(&gb));
    try expectEqual(@as(u32, 144), cap.count);
}

const expect = std.testing.expect;

/// Tick one M-cycle at a time until LY == ly; return how many times
/// Irq.stat was requested on the way (IF cleared after each).
fn count_stat_irqs_until(gb: *Gb, ly: u8, extra_t: u32) u32 {
    var n: u32 = 0;
    while (gb.io[Reg.ly] != ly) {
        ppu.tick(gb, 4);
        if (gb.io[Reg.if_] & Irq.stat != 0) n += 1;
        gb.io[Reg.if_] = 0;
    }
    var t: u32 = 0;
    while (t < extra_t) : (t += 4) {
        ppu.tick(gb, 4);
        if (gb.io[Reg.if_] & Irq.stat != 0) n += 1;
        gb.io[Reg.if_] = 0;
    }
    return n;
}

test "ppu STAT LYC interrupt on rising edge only" {
    var gb: Gb = undefined;
    var cap: Capture = .{};
    setup(&gb, &cap);
    ppu.write_reg(&gb, Reg.lyc, 5);
    ppu.write_reg(&gb, Reg.stat, 0x40);
    try expectEqual(@as(u8, 0xC2), ppu.read_reg(&gb, Reg.stat));
    try expectEqual(@as(u32, 0), count_stat_irqs_until(&gb, 4, 0));
    try expectEqual(@as(u32, 1), count_stat_irqs_until(&gb, 5, 0));
    try expect(ppu.read_reg(&gb, Reg.stat) & 0x04 != 0);
    // No second request while LY stays at LYC.
    try expectEqual(@as(u32, 0), count_stat_irqs_until(&gb, 6, 0));
    try expect(ppu.read_reg(&gb, Reg.stat) & 0x04 == 0);

    // Writing LYC to the current LY raises the line immediately.
    gb.io[Reg.if_] = 0;
    ppu.write_reg(&gb, Reg.lyc, 6);
    try expectEqual(Irq.stat, gb.io[Reg.if_] & Irq.stat);
    // Writes to LY and to the read-only STAT bits are ignored.
    ppu.write_reg(&gb, Reg.ly, 99);
    try expectEqual(@as(u8, 6), ppu.read_reg(&gb, Reg.ly));
    ppu.write_reg(&gb, Reg.stat, 0x07);
    try expectEqual(@as(u8, 0x80 | 0x04), ppu.read_reg(&gb, Reg.stat) & 0xFC);

    // STAT blocking: with HBlank enabled too, line 4's HBlank holds the
    // line high into line 5's LY=LYC, so there is no new edge at line 5.
    setup(&gb, &cap);
    ppu.write_reg(&gb, Reg.lyc, 5);
    ppu.write_reg(&gb, Reg.stat, 0x48);
    gb.io[Reg.if_] = 0;
    _ = count_stat_irqs_until(&gb, 4, 300); // into line 4 HBlank
    try expectEqual(@as(u32, 0), count_stat_irqs_until(&gb, 5, 0));
    // Line 5 HBlank: still high (LYC), no edge; line 6 HBlank: edge.
    try expectEqual(@as(u32, 0), count_stat_irqs_until(&gb, 6, 0));
    try expectEqual(@as(u32, 1), count_stat_irqs_until(&gb, 7, 0));

    // Mode 2 and mode 1 sources.
    setup(&gb, &cap);
    ppu.write_reg(&gb, Reg.stat, 0x20);
    gb.io[Reg.if_] = 0;
    try expectEqual(@as(u32, 10), count_stat_irqs_until(&gb, 10, 0));
    setup(&gb, &cap);
    ppu.write_reg(&gb, Reg.stat, 0x10);
    gb.io[Reg.if_] = 0;
    try expectEqual(@as(u32, 1), count_stat_irqs_until(&gb, 150, 0));
}

test "ppu LCD off and on" {
    var gb: Gb = undefined;
    var cap: Capture = .{};
    setup(&gb, &cap);
    try run_to_line(&gb, &cap, 20);
    ppu.write_reg(&gb, Reg.lcdc, 0x11);
    try expect(!ppu.lcd_on(&gb));
    try expectEqual(@as(u8, 0), ppu.read_reg(&gb, Reg.ly));
    try expectEqual(@as(u8, 0), stat_mode(&gb));
    const seen = cap.count;
    for (0..core.frame_m_cycles) |_| ppu.tick(&gb, 4);
    try expectEqual(seen, cap.count);
    try expectEqual(@as(u8, 0), ppu.read_reg(&gb, Reg.ly));
    try expect(!gb.vblank_hit);

    ppu.write_reg(&gb, Reg.lcdc, 0x91);
    try expectEqual(@as(u8, 2), stat_mode(&gb));
    try run_to_line(&gb, &cap, 0);
    try expectEqual(@as(u8, 0), ppu.read_reg(&gb, Reg.ly));
    try run_frame(&gb, &cap);
    try expectEqual(seen + 144, cap.count);
}

// ---- CGB mode (SPEC.md 19.1, 19.2): lines are colour indices ----

/// CGB model, LCD on, BG on, 0x8000 tile data, 0x9800 BG map.
fn setup_cgb(gb: *Gb, cap: *Capture) void {
    gb.* = Gb.init_slice(&zero_rom, .cgb, &.{});
    gb.line_sink = cap.sink();
    ppu.write_reg(gb, Reg.lcdc, 0x91);
    gb.io[Reg.if_] = 0;
}

/// Tile `i` of VRAM bank `bank` filled with color index `c`.
fn solid_bank(gb: *Gb, bank: usize, i: usize, c: u2) void {
    const base = bank * 0x2000 + i * 16;
    for (0..8) |r| {
        gb.vram[base + r * 2] = if (c & 1 != 0) 0xFF else 0;
        gb.vram[base + r * 2 + 1] = if (c & 2 != 0) 0xFF else 0;
    }
}

test "cgb palette registers: auto-increment, read-back, pal_dirty" {
    var gb = Gb.init_slice(&zero_rom, .cgb, &.{});
    // Boot state: every colour white (0x7FFF little endian).
    for (0..32) |i| {
        try expectEqual(@as(u8, 0xFF), gb.ppu.bg_pal[i * 2]);
        try expectEqual(@as(u8, 0x7F), gb.ppu.bg_pal[i * 2 + 1]);
        try expectEqual(@as(u8, 0xFF), gb.ppu.obj_pal[i * 2]);
        try expectEqual(@as(u8, 0x7F), gb.ppu.obj_pal[i * 2 + 1]);
    }

    // Auto-increment wraps from 63 to 0 and keeps bit 7.
    gb.write8(0xFF68, 0x80 | 62);
    gb.pal_dirty = false;
    gb.write8(0xFF69, 0x11);
    try expect(gb.pal_dirty);
    gb.write8(0xFF69, 0x22);
    gb.write8(0xFF69, 0x33);
    try expectEqual(@as(u8, 0x11), gb.ppu.bg_pal[62]);
    try expectEqual(@as(u8, 0x22), gb.ppu.bg_pal[63]);
    try expectEqual(@as(u8, 0x33), gb.ppu.bg_pal[0]);
    try expectEqual(@as(u8, 0xC1), gb.read8(0xFF68)); // bit 6 reads 1
    // BCPD reads the byte at the index and does not advance it.
    try expectEqual(@as(u8, 0x7F), gb.read8(0xFF69));
    try expectEqual(@as(u8, 0x7F), gb.read8(0xFF69));
    try expectEqual(@as(u8, 0xC1), gb.read8(0xFF68));

    // Without bit 7 the index stays put; bit 6 is not stored.
    gb.write8(0xFF68, 0x40 | 5);
    try expectEqual(@as(u8, 0x45), gb.read8(0xFF68));
    gb.write8(0xFF69, 0xAA);
    gb.write8(0xFF69, 0xBB);
    try expectEqual(@as(u8, 0xBB), gb.ppu.bg_pal[5]);
    try expectEqual(@as(u8, 0xFF), gb.ppu.bg_pal[6]);
    try expectEqual(@as(u8, 0xBB), gb.read8(0xFF69));

    // OBJ palettes, independent index.
    gb.write8(0xFF6A, 0x80 | 8);
    gb.pal_dirty = false;
    gb.write8(0xFF6B, 0x12);
    gb.write8(0xFF6B, 0x34);
    try expect(gb.pal_dirty);
    try expectEqual(@as(u8, 0x12), gb.ppu.obj_pal[8]);
    try expectEqual(@as(u8, 0x34), gb.ppu.obj_pal[9]);
    try expectEqual(@as(u8, 0xCA), gb.read8(0xFF6A));
    gb.write8(0xFF6A, 8);
    try expectEqual(@as(u8, 0x12), gb.read8(0xFF6B));
    try expectEqual(@as(u8, 0x45), gb.read8(0xFF68));

    // OPRI: bit 0 stored, the rest read 1. CGB boot leaves 0 (OAM order).
    try expectEqual(@as(u8, 0xFE), gb.read8(0xFF6C));
    gb.write8(0xFF6C, 0xFF);
    try expectEqual(@as(u8, 0xFF), gb.read8(0xFF6C));

    // DMG mode: the registers do not exist.
    var dmg = Gb.init_slice(&zero_rom, .dmg, &.{});
    dmg.pal_dirty = false;
    dmg.write8(0xFF68, 0x80);
    dmg.write8(0xFF69, 0x00);
    try expectEqual(@as(u8, 0xFF), dmg.read8(0xFF68));
    try expectEqual(@as(u8, 0xFF), dmg.read8(0xFF69));
    try expectEqual(@as(u8, 0xFF), dmg.ppu.bg_pal[0]);
    try expect(!dmg.pal_dirty);
}

test "cgb bg attributes: palette, tile bank, x and y flip" {
    var gb: Gb = undefined;
    var cap: Capture = .{};
    setup_cgb(&gb, &cap);
    // Tile 2, bank 0: only pixel (0,0) set, colour 1. Bank 1: solid 3.
    gb.vram[2 * 16] = 0x80;
    solid_bank(&gb, 1, 2, 3);
    const attr = 0x3800;
    gb.vram[0x1800 + 0] = 2;
    gb.vram[0x1800 + 1] = 2;
    gb.vram[attr + 1] = 0x20 | 3; // X flip, palette 3
    gb.vram[0x1800 + 2] = 2;
    gb.vram[attr + 2] = 0x40 | 5; // Y flip, palette 5
    gb.vram[0x1800 + 3] = 2;
    gb.vram[attr + 3] = 0x08 | 7; // bank 1, palette 7
    try run_frame(&gb, &cap);
    const l0 = &cap.frame[0];
    const l7 = &cap.frame[7];
    try expectEqual(@as(u8, 1), l0[0]);
    try expect_span(l0, 1, 8, 0);
    try expect_span(l0, 8, 15, 12);
    try expectEqual(@as(u8, 13), l0[15]);
    try expect_span(l0, 16, 24, 20);
    try expectEqual(@as(u8, 21), l7[16]);
    try expect_span(l7, 17, 24, 20);
    try expect_span(l7, 0, 8, 0);
    try expect_span(l7, 8, 15, 12);
    try expect_span(l0, 24, 32, 31);
    try expect_span(l7, 24, 32, 31);
    try expect_span(l0, 32, 160, 0);
}

test "cgb bg priority bit, obj priority bit and LCDC.0 master priority" {
    var gb: Gb = undefined;
    var cap: Capture = .{};
    setup_cgb(&gb, &cap);
    gb.vram[16..32].* = @splat(0);
    for (0..8) |r| gb.vram[16 + r * 2] = 0x0F; // tile 1: pixels 4..7 colour 1
    solid_bank(&gb, 0, 2, 3);
    fill_map(&gb, 0x1800, 1);
    gb.vram[0x3800 + 2] = 0x80; // map column 2 (x 16..23): BG priority
    ppu.write_reg(&gb, Reg.lcdc, 0x93);
    sprite(&gb, 0, 16, 8 + 16, 2, 0x02); // palette 2 -> 32 + 8 + 3
    sprite(&gb, 1, 16, 8 + 40, 2, 0x02);
    sprite(&gb, 2, 16, 8 + 64, 2, 0x82); // OBJ-behind-BG
    try run_frame(&gb, &cap);
    const l = &cap.frame[0];
    try expect_span(l, 16, 20, 43); // BG colour 0 always loses
    try expect_span(l, 20, 24, 1); // BG attribute priority wins
    try expect_span(l, 40, 48, 43);
    try expect_span(l, 64, 68, 43);
    try expect_span(l, 68, 72, 1); // OAM priority bit
    try expect_span(l, 0, 4, 0);
    try expect_span(l, 4, 8, 1);

    // LCDC.0 = 0: sprites always on top, BG still drawn.
    ppu.write_reg(&gb, Reg.lcdc, 0x92);
    try run_frame(&gb, &cap);
    try expect_span(l, 16, 24, 43);
    try expect_span(l, 64, 72, 43);
    try expect_span(l, 0, 4, 0);
    try expect_span(l, 4, 8, 1);
    try expect_span(l, 28, 32, 1);
}

test "cgb window ignores LCDC.0 and uses bank 1 attributes" {
    var gb: Gb = undefined;
    var cap: Capture = .{};
    setup_cgb(&gb, &cap);
    solid_bank(&gb, 0, 3, 2);
    fill_map(&gb, 0x1C00, 3);
    @memset(gb.vram[0x3C00..0x4000], 4); // window map attributes: palette 4
    ppu.write_reg(&gb, Reg.lcdc, 0xF0); // window on, map 9C00, BG bit clear
    gb.io[Reg.wy] = 0;
    gb.io[Reg.wx] = 7 + 80;
    try run_frame(&gb, &cap);
    try expect_span(&cap.frame[0], 0, 80, 0);
    try expect_span(&cap.frame[0], 80, 160, 18);
}

test "cgb sprite priority by OAM order unless OPRI is set" {
    var gb: Gb = undefined;
    var cap: Capture = .{};
    setup_cgb(&gb, &cap);
    solid_bank(&gb, 0, 2, 3);
    ppu.write_reg(&gb, Reg.lcdc, 0x93);
    sprite(&gb, 0, 16, 8 + 20, 2, 0x01); // 32 + 4 + 3 = 39, x 20..27
    sprite(&gb, 1, 16, 8 + 16, 2, 0x02); // 43, x 16..23
    try run_frame(&gb, &cap);
    try expect_span(&cap.frame[0], 16, 20, 43);
    try expect_span(&cap.frame[0], 20, 28, 39); // OAM 0 wins the overlap

    ppu.write_reg(&gb, Reg.opri, 1); // DMG coordinate priority
    try run_frame(&gb, &cap);
    try expect_span(&cap.frame[0], 16, 24, 43); // lower X wins
    try expect_span(&cap.frame[0], 24, 28, 39);

    // Still 10 sprites per line, chosen in OAM order.
    ppu.write_reg(&gb, Reg.opri, 0);
    @memset(&gb.oam, 0);
    for (0..12) |i| sprite(&gb, i, 16, @intCast(8 + 10 * (11 - i)), 2, 0);
    try run_frame(&gb, &cap);
    try expect_span(&cap.frame[0], 0, 20, 0);
    try expect_span(&cap.frame[0], 20, 28, 35);
    try expect_span(&cap.frame[0], 110, 118, 35);
}

test "cgb obj tile bank and palette bits, DMG palette bit ignored" {
    var gb: Gb = undefined;
    var cap: Capture = .{};
    setup_cgb(&gb, &cap);
    solid_bank(&gb, 0, 4, 1);
    solid_bank(&gb, 1, 4, 2);
    solid_bank(&gb, 1, 5, 3);
    ppu.write_reg(&gb, Reg.lcdc, 0x93);
    sprite(&gb, 0, 16, 8 + 10, 4, 0x10); // bank 0, palette 0: 33
    sprite(&gb, 1, 16, 8 + 30, 4, 0x08 | 6); // bank 1, palette 6: 32 + 24 + 2
    try run_frame(&gb, &cap);
    try expect_span(&cap.frame[0], 10, 18, 33);
    try expect_span(&cap.frame[0], 30, 38, 58);
    try expect_span(&cap.frame[0], 18, 30, 0);

    // 8x16 from bank 1 with Y flip: the halves swap within the bank.
    ppu.write_reg(&gb, Reg.lcdc, 0x97);
    sprite(&gb, 1, 16 + 40, 8 + 30, 5, 0x48 | 1);
    try run_frame(&gb, &cap);
    try expect_span(&cap.frame[40], 30, 38, 32 + 4 + 3);
    try expect_span(&cap.frame[48], 30, 38, 32 + 4 + 2);
}
