//! VDP unit tests on synthetic VRAM/CRAM/register states, programmed
//! through the port functions the way a game would, then run with `tick`
//! (collecting lines from a test sink) or `render_line` directly. Owner in
//! M1: Track B. Test names start with `vdp:`.
const std = @import("std");
const core = @import("core");
const vdp = core.vdp;
const Vdp = vdp.Vdp;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

const W = vdp.screen_w;
const nt_base: u16 = 0x3800; // register 2 = 0xFF
const sat_base: u16 = 0x3F00; // register 5 = 0xFF

// ---- Port helpers ----

fn command(v: *Vdp, word: u16) void {
    v.write_control(@truncate(word));
    v.write_control(@truncate(word >> 8));
}

fn set_reg(v: *Vdp, r: u4, val: u8) void {
    command(v, 0x8000 | (@as(u16, r) << 8) | val);
}

fn vram_write(v: *Vdp, addr: u16, bytes: []const u8) void {
    command(v, 0x4000 | addr);
    for (bytes) |b| v.write_data(b);
}

fn cram_write(v: *Vdp, index: u8, color: u16) void {
    command(v, 0xC000 | (@as(u16, index) * 2));
    v.write_data(@truncate(color));
    v.write_data(@truncate(color >> 8));
}

/// Display on, name table 0x3800, SAT 0x3F00, sprite patterns 0..255,
/// backdrop colour 16 + 5, no scroll. VRAM zero (tile 0 transparent).
fn setup(v: *Vdp) void {
    v.reset();
    set_reg(v, 0, 0x06);
    set_reg(v, 1, 0x40);
    set_reg(v, 2, 0xFF);
    set_reg(v, 5, 0xFF);
    set_reg(v, 6, 0xFB);
    set_reg(v, 7, 0x05);
    set_reg(v, 8, 0);
    set_reg(v, 9, 0);
    // Empty sprite list.
    vram_write(v, sat_base, &.{0xD0});
}

/// Row `r` of pattern `tile` from eight 4-bit pixels (left to right).
fn tile_row(v: *Vdp, tile: u16, r: u16, px: [8]u4) void {
    var planes: [4]u8 = @splat(0);
    for (px, 0..) |c, i| {
        for (0..4) |k| {
            if ((c >> @intCast(k)) & 1 != 0) planes[k] |= @as(u8, 0x80) >> @intCast(i);
        }
    }
    vram_write(v, tile * 32 + r * 4, &planes);
}

fn solid_tile(v: *Vdp, tile: u16, c: u4) void {
    for (0..8) |r| tile_row(v, tile, @intCast(r), @splat(c));
}

/// Pattern `tile` with pixel i = colour i + 1 on every row.
fn ramp_tile(v: *Vdp, tile: u16) void {
    for (0..8) |r| tile_row(v, tile, @intCast(r), .{ 1, 2, 3, 4, 5, 6, 7, 8 });
}

/// Pattern `tile` whose row r is colour r + 1 across.
fn rows_tile(v: *Vdp, tile: u16) void {
    for (0..8) |r| tile_row(v, tile, @intCast(r), @splat(@intCast(r + 1)));
}

fn set_name(v: *Vdp, col: u16, row: u16, entry: u16) void {
    vram_write(v, nt_base + row * 64 + col * 2, &.{ @truncate(entry), @truncate(entry >> 8) });
}

fn fill_names(v: *Vdp, entry: u16) void {
    for (0..28) |r| for (0..32) |c| set_name(v, @intCast(c), @intCast(r), entry);
}

fn sprite(v: *Vdp, n: u16, y: u8, x: u8, pat: u8) void {
    vram_write(v, sat_base + n, &.{y});
    vram_write(v, sat_base + 128 + n * 2, &.{ x, pat });
}

fn render(v: *Vdp, line: u8) [W]u5 {
    var out: [W]u5 = undefined;
    v.render_line(line, vdp.window_x0, &out);
    return out;
}

fn render_at(v: *Vdp, line: u8, x0: u8) [W]u5 {
    var out: [W]u5 = undefined;
    v.render_line(line, x0, &out);
    return out;
}

/// Game Gear window column of VDP column `c`.
fn gx(c: usize) usize {
    return c - vdp.window_x0;
}

/// Advance to the start of `line` (from anywhere), running the lines between.
fn run_to_line(v: *Vdp, line: u16, sink: ?vdp.LineSink) void {
    while (v.line != line or v.line_tstates != 0) {
        _ = v.tick(vdp.tstates_per_line - v.line_tstates, sink);
    }
}

const Capture = struct {
    frame: [vdp.screen_h][W]u5 = undefined,
    count: u32 = 0,
    next_y: u32 = 0,
    in_order: bool = true,

    fn emit(ctx: *anyopaque, y: u8, px: *const [W]u5, cram: *const [32]u16) void {
        _ = cram;
        const self: *Capture = @ptrCast(@alignCast(ctx));
        if (y != self.next_y % vdp.screen_h) self.in_order = false;
        self.next_y += 1;
        self.frame[y] = px.*;
        self.count += 1;
    }

    fn sink(self: *Capture) vdp.LineSink {
        return .{ .ctx = self, .func = emit };
    }
};

// ---- Ports ----

test "vdp: control latch and register writes" {
    var v: Vdp = .{};
    v.write_control(0x12);
    try expect(v.latch_pending);
    v.write_control(0x87); // register 7 = 0x12
    try expect(!v.latch_pending);
    try expectEqual(@as(u8, 0x12), v.regs[7]);
    try expectEqual(@as(u2, 2), v.code);
    // Bits 5-4 of the second byte are ignored; 11..15 have no effect.
    v.write_control(0x34);
    v.write_control(0xB8);
    try expectEqual(@as(u8, 0x34), v.regs[8]);
    const before = v.regs;
    for (11..16) |r| {
        v.write_control(0xEE);
        v.write_control(0x80 | @as(u8, @intCast(r)));
    }
    try expectEqual(before, v.regs);
    // A register write also sets the address (low byte = data).
    try expectEqual(@as(u16, 0x0FEE), v.addr);
}

test "vdp: first control byte sets the low address, data access clears the latch" {
    var v: Vdp = .{};
    command(&v, 0x4000 | 0x1234);
    try expectEqual(@as(u16, 0x1234), v.addr);
    v.write_control(0x56);
    try expectEqual(@as(u16, 0x1256), v.addr);
    try expect(v.latch_pending);
    v.write_data(0xAA); // clears the latch, writes VRAM (code still 1)
    try expect(!v.latch_pending);
    try expectEqual(@as(u8, 0xAA), v.vram[0x1256]);
    // The next control byte is a first byte again.
    v.write_control(0x00);
    try expect(v.latch_pending);
    _ = v.read_data();
    try expect(!v.latch_pending);
    v.write_control(0x00);
    _ = v.read_status();
    try expect(!v.latch_pending);
}

test "vdp: VRAM writes, read-ahead buffer, wrap at 3FFF" {
    var v: Vdp = .{};
    vram_write(&v, 0x3FFE, &.{ 0x11, 0x22, 0x33 });
    try expectEqual(@as(u8, 0x11), v.vram[0x3FFE]);
    try expectEqual(@as(u8, 0x22), v.vram[0x3FFF]);
    try expectEqual(@as(u8, 0x33), v.vram[0x0000]);
    try expectEqual(@as(u16, 1), v.addr);
    // Writing loads the buffer with the written byte.
    try expectEqual(@as(u8, 0x33), v.read_buffer);

    // Code 0 prefetches and increments; reads return the buffer, then refill.
    command(&v, 0x3FFE);
    try expectEqual(@as(u16, 0x3FFF), v.addr);
    try expectEqual(@as(u8, 0x11), v.read_data());
    try expectEqual(@as(u8, 0x22), v.read_data());
    try expectEqual(@as(u8, 0x33), v.read_data());
    try expectEqual(@as(u16, 2), v.addr);

    // Data writes in code 0 and 2 go to VRAM too.
    command(&v, 0x0100);
    v.write_data(0x44);
    try expectEqual(@as(u8, 0x44), v.vram[0x0101]); // prefetch moved the address
    command(&v, 0x8000 | 0x0000); // register 0 = 0 (code 2, address 0x0000)
    v.write_data(0x55);
    try expectEqual(@as(u8, 0x55), v.vram[0x0000]);
}

test "vdp: CRAM byte pairs" {
    var v: Vdp = .{};
    // Even byte only: CRAM unchanged.
    command(&v, 0xC000);
    v.write_data(0xFF);
    try expectEqual(@as(u16, 0), v.cram[0]);
    try expectEqual(@as(u8, 0xFF), v.cram_latch);
    // msvdp.txt example: odd address 0x21 writes entry 0x10 with the latch.
    command(&v, 0xC021);
    v.write_data(0x0F);
    try expectEqual(@as(u16, 0x0FFF), v.cram[0x10]);
    try expectEqual(@as(u16, 0), v.cram[0]);
    // Upper nibble of the high byte is dropped; address wraps at 0x3F.
    command(&v, 0xC000 | 0x7E);
    v.write_data(0x34);
    v.write_data(0xF2);
    try expectEqual(@as(u16, 0x0234), v.cram[31]);
    // A full palette in one stream.
    command(&v, 0xC000);
    for (0..32) |i| {
        v.write_data(@intCast(i));
        v.write_data(0x0A);
    }
    for (0..32) |i| try expectEqual(@as(u16, 0x0A00 | @as(u16, @intCast(i))), v.cram[i]);
    // CRAM writes do not touch VRAM or the read buffer.
    try expectEqual(@as(u8, 0), v.vram[0]);
}

test "vdp: status read returns and clears the flags, the line IRQ and the latch" {
    var v: Vdp = .{};
    v.status = vdp.status_frame | vdp.status_overflow | vdp.status_collision;
    v.line_irq_pending = true;
    v.write_control(0x00);
    const s = v.read_status();
    try expectEqual(@as(u8, 0xFF), s);
    try expectEqual(@as(u8, 0), v.status);
    try expect(!v.line_irq_pending);
    try expect(!v.latch_pending);
    try expectEqual(@as(u8, 0x1F), v.read_status());
}

// ---- Timing and interrupts ----

test "vdp: frame IRQ flag at the start of line 193, gated by register 1 bit 5" {
    var v: Vdp = .{};
    setup(&v);
    run_to_line(&v, 192, null);
    _ = v.tick(227, null);
    try expectEqual(@as(u8, 0), v.status & vdp.status_frame);
    _ = v.tick(1, null);
    try expectEqual(@as(u16, 193), v.line);
    try expect(v.status & vdp.status_frame != 0);
    try expect(!v.irq_line()); // register 1 bit 5 clear
    set_reg(&v, 1, 0x60);
    try expect(v.irq_line());
    set_reg(&v, 1, 0x40);
    try expect(!v.irq_line());
    set_reg(&v, 1, 0x60);
    _ = v.read_status();
    try expect(!v.irq_line());
    // Once per frame.
    run_to_line(&v, 192, null);
    try expect(!v.irq_line());
    run_to_line(&v, 193, null);
    try expect(v.irq_line());
}

test "vdp: line counter underflow timing, reload and register 10 changes" {
    var v: Vdp = .{};
    setup(&v);
    set_reg(&v, 0, 0x16); // line IRQ enabled
    set_reg(&v, 10, 3);
    // Reloaded on 193..261: from the next frame, lines 0,1,2 count 2,1,0
    // and line 3 underflows; then every 4 lines.
    run_to_line(&v, 261, null);
    try expectEqual(@as(u8, 3), v.line_counter);
    var raised: [8]u16 = undefined;
    var n: usize = 0;
    var line: u16 = 0;
    while (line < 30) : (line += 1) {
        run_to_line(&v, line, null);
        if (v.irq_line()) {
            if (n < raised.len) raised[n] = line;
            n += 1;
            _ = v.read_status();
        }
    }
    try expectEqual(@as(usize, 7), n); // lines 3, 7, 11, 15, 19, 23, 27
    for (0..7) |i| try expectEqual(@as(u16, @intCast(3 + 4 * i)), raised[i]);

    // A register 10 change during the active area waits for the underflow.
    set_reg(&v, 10, 0);
    // Counter now 1 at line 29 (27 reloaded to 3, 28 -> 2, 29 -> 1).
    try expectEqual(@as(u8, 1), v.line_counter);
    run_to_line(&v, 31, null);
    try expect(v.irq_line()); // old value 3 still counted down: 30 -> 0, 31 underflows
    try expectEqual(@as(u8, 0), v.line_counter); // reloaded with the new 0
    _ = v.read_status();
    run_to_line(&v, 32, null);
    try expect(v.irq_line()); // every line now
    _ = v.read_status();

    // Line 192 still decrements (can raise), 193..261 reload, no IRQ there.
    run_to_line(&v, 192, null);
    try expect(v.line_irq_pending);
    _ = v.read_status();
    set_reg(&v, 10, 0x40);
    run_to_line(&v, 250, null);
    try expect(!v.line_irq_pending);
    try expectEqual(@as(u8, 0x40), v.line_counter); // change during 193..261 took effect
    // IRQ disabled by register 0 bit 4: pending but not asserted.
    set_reg(&v, 10, 0);
    set_reg(&v, 0, 0x06);
    run_to_line(&v, 1, null);
    try expect(v.line_irq_pending);
    try expect(!v.irq_line());
    set_reg(&v, 0, 0x16);
    try expect(v.irq_line());
}

test "vdp: V counter jump and H counter sequence" {
    var v: Vdp = .{};
    var line: u16 = 0;
    while (line < vdp.lines_per_frame) : (line += 1) {
        v.line = line;
        const want: u8 = if (line <= 0xDA) @intCast(line) else @intCast(line - 6);
        try expectEqual(want, v.v_counter());
    }
    v.line = 0xDA;
    try expectEqual(@as(u8, 0xDA), v.v_counter());
    v.line = 0xDB;
    try expectEqual(@as(u8, 0xD5), v.v_counter());
    v.line = 261;
    try expectEqual(@as(u8, 0xFF), v.v_counter());

    // H counter: monotonic 00..93, then E9..FF, 171 distinct values.
    var seen: [256]bool = @splat(false);
    var prev: u8 = 0;
    var t: u16 = 0;
    while (t < vdp.tstates_per_line) : (t += 1) {
        v.line_tstates = t;
        const h = v.h_counter();
        try expect((h <= 0x93) or (h >= 0xE9));
        if (t > 0) try expect(h >= prev);
        prev = h;
        seen[h] = true;
    }
    var count: u32 = 0;
    for (seen) |s| count += @intFromBool(s);
    try expectEqual(@as(u32, 171), count);
    v.line_tstates = 0;
    try expectEqual(@as(u8, 0), v.h_counter());
    v.line_tstates = 227;
    try expectEqual(@as(u8, 0xFF), v.h_counter());
}

test "vdp: a frame is 262 x 228 T-states with the leftover carried" {
    var v: Vdp = .{};
    setup(&v);
    var cap: Capture = .{};
    // Irregular steps like Z80 instructions.
    const steps = [_]u32{ 4, 7, 11, 23, 10, 13, 5, 17 };
    var total: u64 = 0;
    var frames: u32 = 0;
    var i: usize = 0;
    var frame_ends: [3]u64 = undefined;
    while (frames < 3) : (i += 1) {
        const t = steps[i % steps.len];
        total += t;
        if (v.tick(t, cap.sink())) {
            frame_ends[frames] = total;
            frames += 1;
            // Leftover beyond the end of line 261 is in line 0.
            try expectEqual(@as(u16, 0), v.line);
            try expectEqual(total - @as(u64, frames) * 262 * 228, v.line_tstates);
        }
    }
    for (0..3) |f| {
        const end = @as(u64, @intCast(f + 1)) * 262 * 228;
        try expect(frame_ends[f] >= end and frame_ends[f] < end + 23);
    }
    try expectEqual(@as(u32, 3 * 144), cap.count);
    try expect(cap.in_order);

    // One huge tick finishes the frame once.
    var w: Vdp = .{};
    try expect(w.tick(262 * 228 + 5, null));
    try expectEqual(@as(u16, 0), w.line);
    try expectEqual(@as(u16, 5), w.line_tstates);
    try expect(!w.tick(262 * 228 - 6, null));
    try expect(w.tick(1, null));
}

test "vdp: sink receives 144 lines y = 0..143 in order, one per visible line" {
    var v: Vdp = .{};
    setup(&v);
    rows_tile(&v, 1);
    fill_names(&v, 1);
    var cap: Capture = .{};
    // Frame 1 then frame 2: lines emitted as each line starts.
    while (!v.tick(228, cap.sink())) {
        if (v.line >= vdp.window_y0 and v.line < vdp.window_y0 + vdp.screen_h)
            try expectEqual(@as(u32, v.line - vdp.window_y0 + 1), cap.count);
    }
    try expectEqual(@as(u32, 144), cap.count);
    try expect(cap.in_order);
    // Game Gear y 0 is VDP line 24: tile row 0, colour 1.
    for (0..vdp.screen_h) |y| {
        const want: u5 = @intCast(((y + 24) & 7) + 1);
        try expectEqual(want, cap.frame[y][0]);
        try expectEqual(want, cap.frame[y][W - 1]);
    }
}

test "vdp: vertical scroll latched at the start of the frame" {
    var v: Vdp = .{};
    setup(&v);
    rows_tile(&v, 1);
    fill_names(&v, 1);
    var cap: Capture = .{};
    run_to_line(&v, 100, cap.sink());
    set_reg(&v, 9, 3);
    try expectEqual(@as(u8, 0), v.vscroll);
    run_to_line(&v, 0, cap.sink());
    try expectEqual(@as(u8, 3), v.vscroll);
    // Line 24 now shows tile row (24 + 3) & 7 = 3 -> colour 4.
    run_to_line(&v, 25, cap.sink());
    try expectEqual(@as(u5, 4), cap.frame[0][0]);
}

// ---- Background ----

test "vdp: display disabled shows the backdrop" {
    var v: Vdp = .{};
    setup(&v);
    solid_tile(&v, 1, 9);
    fill_names(&v, 1);
    sprite(&v, 0, 49, 100, 1);
    sprite(&v, 1, 49, 100, 1);
    vram_write(&v, sat_base + 2, &.{0xD0});
    set_reg(&v, 1, 0x00);
    const out = render(&v, 50);
    for (out) |p| try expectEqual(@as(u5, 16 + 5), p);
    try expectEqual(@as(u8, 0), v.status & (vdp.status_collision | vdp.status_overflow));
    set_reg(&v, 1, 0x40);
    try expectEqual(@as(u5, 9), render(&v, 60)[0]);
}

test "vdp: tile pixels, palette select, flips, name table base" {
    var v: Vdp = .{};
    setup(&v);
    ramp_tile(&v, 1);
    rows_tile(&v, 2);
    // Column 6 is the first visible column (VDP columns 48..55).
    set_name(&v, 6, 3, 0x0001); // plain
    set_name(&v, 7, 3, 0x0201); // hflip
    set_name(&v, 8, 3, 0x0801); // sprite palette
    set_name(&v, 9, 3, 0x0002); // rows
    set_name(&v, 10, 3, 0x0402); // vflip
    set_name(&v, 11, 3, 0x0601); // h+v flip of tile 1
    const line: u8 = 3 * 8 + 2; // tile row 2
    const out = render(&v, line);
    for (0..8) |i| {
        try expectEqual(@as(u5, @intCast(i + 1)), out[i]);
        try expectEqual(@as(u5, @intCast(8 - i)), out[8 + i]);
        try expectEqual(@as(u5, @intCast(16 + i + 1)), out[16 + i]);
        try expectEqual(@as(u5, 3), out[24 + i]);
        try expectEqual(@as(u5, 6), out[32 + i]); // row 7 - 2 = 5 -> colour 6
        try expectEqual(@as(u5, @intCast(8 - i)), out[40 + i]);
    }
    // Pattern index bit 8 (tile 0x101).
    solid_tile(&v, 0x101, 12);
    set_name(&v, 12, 3, 0x0101);
    try expectEqual(@as(u5, 12), render(&v, line)[48]);
    // Name table at 0x1000 (register 2 = 0x05: bit 0 ignored).
    set_reg(&v, 2, 0x05);
    vram_write(&v, 0x1000 + 3 * 64 + 6 * 2, &.{ 0x02, 0x00 });
    const o2 = render(&v, line);
    try expectEqual(@as(u5, 3), o2[0]);
    try expectEqual(@as(u5, 0), o2[8]);
}

test "vdp: horizontal scroll, coarse and fine" {
    var v: Vdp = .{};
    setup(&v);
    ramp_tile(&v, 1);
    solid_tile(&v, 2, 10);
    // Name column 6 = ramp, the rest solid 10.
    fill_names(&v, 2);
    for (0..28) |r| set_name(&v, 6, @intCast(r), 1);
    // Scroll 3 right: VDP column c shows background column c - 3.
    set_reg(&v, 8, 3);
    var out = render(&v, 40);
    try expectEqual(@as(u5, 10), out[2]);
    for (0..8) |i| try expectEqual(@as(u5, @intCast(i + 1)), out[3 + i]);
    try expectEqual(@as(u5, 10), out[11]);
    // Scroll 256 - 21: background column c + 21; column 6 lands at 48 - 21 = 27.
    set_reg(&v, 8, 256 - 21);
    out = render(&v, 40);
    try expectEqual(@as(u5, 10), out[0]);
    // Name column 6 is then at VDP 27..34, left of the window: all solid.
    for (out) |p| try expectEqual(@as(u5, 10), p);
    // Scroll 256 - 5: ramp at VDP 43..50, window sees pixels 5..7 of it.
    set_reg(&v, 8, 256 - 5);
    out = render(&v, 40);
    try expectEqual(@as(u5, 6), out[0]);
    try expectEqual(@as(u5, 7), out[1]);
    try expectEqual(@as(u5, 8), out[2]);
    try expectEqual(@as(u5, 10), out[3]);
    // Fine scroll leaves the backdrop left of the first column counter.
    set_reg(&v, 8, 5);
    const full = render_at(&v, 40, 0);
    for (0..5) |x| try expectEqual(@as(u5, 16 + 5), full[x]);
    try expectEqual(@as(u5, 10), full[5]);
}

test "vdp: vertical scroll wraps at 224 and fine scroll moves rows" {
    var v: Vdp = .{};
    setup(&v);
    rows_tile(&v, 1);
    solid_tile(&v, 2, 11);
    fill_names(&v, 1);
    for (0..32) |c| set_name(&v, @intCast(c), 27, 2); // last row solid 11
    v.vscroll = 5;
    try expectEqual(@as(u5, ((40 + 5) & 7) + 1), render(&v, 40)[0]);
    // Line 30 + 186 = 216 -> row 27.
    v.vscroll = 186;
    try expectEqual(@as(u5, 11), render(&v, 30)[0]);
    // 224 wraps to row 0: line 30 + 202 = 232 - 224 = 8 -> row 1, fine 0.
    v.vscroll = 202;
    try expectEqual(@as(u5, 1), render(&v, 30)[0]);
    // Values above 223 act as 0..31: 240 at line 0 = row 2 (16).
    v.vscroll = 240;
    try expectEqual(@as(u5, 1), render(&v, 0)[0]);
    v.vscroll = 243;
    try expectEqual(@as(u5, 4), render(&v, 0)[0]);
    // Largest sum: line 191 + 255 = 446 - 224 = 222 -> row 27, fine 6.
    v.vscroll = 255;
    try expectEqual(@as(u5, 11), render(&v, 191)[0]);
}

test "vdp: top-two-rows horizontal lock and right-columns vertical lock" {
    var v: Vdp = .{};
    setup(&v);
    ramp_tile(&v, 1);
    rows_tile(&v, 3);
    solid_tile(&v, 2, 10);
    fill_names(&v, 2);
    for (0..28) |r| set_name(&v, 0, @intCast(r), 1);
    set_reg(&v, 8, 16); // column 0 at VDP 16
    set_reg(&v, 0, 0x46); // lock rows 0-1 (lines 0..15)
    var out = render_at(&v, 15, 0);
    try expectEqual(@as(u5, 1), out[0]);
    out = render_at(&v, 16, 0);
    try expectEqual(@as(u5, 10), out[0]);
    try expectEqual(@as(u5, 1), out[16]);
    set_reg(&v, 0, 0x06);
    try expectEqual(@as(u5, 10), render_at(&v, 15, 0)[0]);

    // Vertical lock: column counters 24..31 ignore the vertical scroll.
    set_reg(&v, 8, 0);
    fill_names(&v, 3);
    v.vscroll = 2;
    set_reg(&v, 0, 0x86);
    out = render(&v, 40); // row 0 of tile row 5; scrolled -> row 2
    try expectEqual(@as(u5, 3), out[gx(191)]);
    try expectEqual(@as(u5, 1), out[gx(192)]);
    try expectEqual(@as(u5, 1), out[gx(207)]);
    set_reg(&v, 0, 0x06);
    out = render(&v, 40);
    try expectEqual(@as(u5, 3), out[gx(192)]);
    // With fine scroll the lock follows the column counter: counter 24
    // starts at VDP 192 + 3.
    set_reg(&v, 0, 0x86);
    set_reg(&v, 8, 3);
    out = render(&v, 40);
    try expectEqual(@as(u5, 3), out[gx(194)]);
    try expectEqual(@as(u5, 1), out[gx(195)]);
}

test "vdp: left-column blank masks columns 0..7 with the backdrop" {
    var v: Vdp = .{};
    setup(&v);
    solid_tile(&v, 1, 9);
    fill_names(&v, 1);
    set_reg(&v, 0, 0x26);
    sprite(&v, 0, 9, 0, 1); // a sprite in column 0..7 is masked too
    vram_write(&v, sat_base + 1, &.{0xD0});
    const out = render_at(&v, 10, 0);
    for (0..8) |x| try expectEqual(@as(u5, 16 + 5), out[x]);
    try expectEqual(@as(u5, 9), out[8]);
    // The Game Gear window never shows it.
    try expectEqual(@as(u5, 9), render(&v, 10)[0]);
}

// ---- Sprites ----

test "vdp: sprite position, transparency and Y+1" {
    var v: Vdp = .{};
    setup(&v);
    solid_tile(&v, 2, 10);
    fill_names(&v, 2);
    // Sprite tile 1: left half colour 3, right half transparent.
    for (0..8) |r| tile_row(&v, 1, @intCast(r), .{ 3, 3, 3, 3, 0, 0, 0, 0 });
    sprite(&v, 0, 49, 60, 1); // top line 50
    vram_write(&v, sat_base + 1, &.{0xD0});
    try expectEqual(@as(u5, 10), render(&v, 49)[gx(60)]);
    for (50..58) |l| {
        const out = render(&v, @intCast(l));
        try expectEqual(@as(u5, 10), out[gx(59)]);
        for (60..64) |c| try expectEqual(@as(u5, 16 + 3), out[gx(c)]);
        for (64..68) |c| try expectEqual(@as(u5, 10), out[gx(c)]);
    }
    try expectEqual(@as(u5, 10), render(&v, 58)[gx(60)]);
    // Clipped at the window edges, no wrap past column 255.
    sprite(&v, 0, 49, 46, 1); // opaque at VDP 46..49
    const edge = render(&v, 50);
    try expectEqual(@as(u5, 16 + 3), edge[0]);
    try expectEqual(@as(u5, 16 + 3), edge[1]);
    try expectEqual(@as(u5, 10), edge[2]);
    sprite(&v, 0, 49, 254, 1); // opaque at 254..257: 256, 257 dropped
    try expectEqual(@as(u5, 16 + 3), render_at(&v, 50, 96)[W - 1]);
    try expectEqual(@as(u5, 10), render_at(&v, 50, 0)[0]);
    try expectEqual(@as(u5, 10), render_at(&v, 50, 0)[1]);
    // Y wraps: Y = 0xFA puts the top at line 251 = -5, rows 5..7 on lines 0..2.
    rows_tile(&v, 4);
    sprite(&v, 0, 0xFA, 100, 4);
    const top = render_at(&v, 0, 0);
    try expectEqual(@as(u5, 16 + 6), top[100]);
    try expectEqual(@as(u5, 16 + 8), render_at(&v, 2, 0)[100]);
    try expectEqual(@as(u5, 10), render_at(&v, 3, 0)[100]);
}

test "vdp: background priority over sprites" {
    var v: Vdp = .{};
    setup(&v);
    // Tile 2: pixels 0..3 colour 0 (transparent index), 4..7 colour 5.
    for (0..8) |r| tile_row(&v, 2, @intCast(r), .{ 0, 0, 0, 0, 5, 5, 5, 5 });
    solid_tile(&v, 1, 7);
    fill_names(&v, 0x1002); // priority
    set_name(&v, 7, 6, 0x1202); // priority + hflip at VDP 56..63
    sprite(&v, 0, 47, 48, 1); // lines 48..55, VDP 48..55
    sprite(&v, 1, 47, 56, 1);
    vram_write(&v, sat_base + 2, &.{0xD0});
    const out = render(&v, 50);
    for (0..4) |i| try expectEqual(@as(u5, 16 + 7), out[i]); // BG colour 0: sprite shows
    for (4..8) |i| try expectEqual(@as(u5, 5), out[i]); // opaque priority BG wins
    for (8..12) |i| try expectEqual(@as(u5, 5), out[i]); // flipped: opaque on the left
    for (12..16) |i| try expectEqual(@as(u5, 16 + 7), out[i]);
    // Priority with the sprite palette select: BG colour 0 of palette 1 is still "transparent".
    fill_names(&v, 0x1802);
    try expectEqual(@as(u5, 16 + 7), render(&v, 50)[0]);
    // Without the priority bit, sprites cover the BG.
    fill_names(&v, 0x0002);
    try expectEqual(@as(u5, 16 + 7), render(&v, 50)[5]);
    // Priority survives fine horizontal scroll.
    fill_names(&v, 0x1002);
    set_reg(&v, 8, 3); // BG pixels 4..7 of column counter 6 at VDP 55..58
    const s = render(&v, 50);
    try expectEqual(@as(u5, 16 + 7), s[gx(54)]);
    try expectEqual(@as(u5, 5), s[gx(55)]);
}

test "vdp: sprite order, 8 per line and the overflow flag" {
    var v: Vdp = .{};
    setup(&v);
    for (1..11) |t| solid_tile(&v, @intCast(t), @intCast(t));
    // Ten sprites on lines 60..67, 12 columns apart; sprite 0 and 1 overlap.
    for (0..10) |n| sprite(&v, @intCast(n), 59, @intCast(50 + n * 12), @intCast(n + 1));
    sprite(&v, 1, 59, 54, 2);
    vram_write(&v, sat_base + 10, &.{0xD0});
    const out = render(&v, 62);
    try expectEqual(@as(u5, 16 + 1), out[gx(54)]); // entry 0 on top of entry 1
    try expectEqual(@as(u5, 16 + 2), out[gx(58)]);
    for (2..8) |n| try expectEqual(@as(u5, @intCast(16 + n + 1)), out[gx(50 + n * 12)]);
    try expectEqual(@as(u5, 0), out[gx(50 + 8 * 12)]); // ninth not drawn
    try expect(v.status & vdp.status_overflow != 0);
    _ = v.read_status();
    // Exactly eight: no overflow.
    vram_write(&v, sat_base + 8, &.{0xD0});
    _ = render(&v, 62);
    try expectEqual(@as(u8, 0), v.status & vdp.status_overflow);
    // Off-screen, transparent sprites still count.
    vram_write(&v, sat_base + 8, &.{ 59, 59 });
    for (0..10) |n| vram_write(&v, sat_base + 128 + @as(u16, @intCast(n)) * 2 + 1, &.{0}); // tile 0: transparent
    _ = render(&v, 62);
    try expect(v.status & vdp.status_overflow != 0);
    _ = v.read_status();
    // Not on that line: no overflow.
    _ = render(&v, 70);
    try expectEqual(@as(u8, 0), v.status & vdp.status_overflow);
    // Y = 0xD0 ends the list even before sprites that would be on the line.
    vram_write(&v, sat_base + 4, &.{0xD0});
    _ = render(&v, 62);
    try expectEqual(@as(u8, 0), v.status & vdp.status_overflow);
}

test "vdp: 8x16 sprites ignore pattern bit 0" {
    var v: Vdp = .{};
    setup(&v);
    solid_tile(&v, 4, 4);
    solid_tile(&v, 5, 5);
    set_reg(&v, 1, 0x42);
    sprite(&v, 0, 99, 80, 5); // pattern 5 -> 4 on top, 5 below
    vram_write(&v, sat_base + 1, &.{0xD0});
    try expectEqual(@as(u5, 16 + 4), render(&v, 100)[gx(80)]);
    try expectEqual(@as(u5, 16 + 4), render(&v, 107)[gx(80)]);
    try expectEqual(@as(u5, 16 + 5), render(&v, 108)[gx(80)]);
    try expectEqual(@as(u5, 16 + 5), render(&v, 115)[gx(80)]);
    try expectEqual(@as(u5, 0), render(&v, 116)[gx(80)]);
    // Sprite pattern base: register 6 bit 2 adds 256 patterns.
    solid_tile(&v, 0x104, 9);
    set_reg(&v, 6, 0xFF);
    try expectEqual(@as(u5, 16 + 9), render(&v, 100)[gx(80)]);
}

test "vdp: zoomed sprites are doubled both ways" {
    var v: Vdp = .{};
    setup(&v);
    ramp_tile(&v, 1);
    rows_tile(&v, 2);
    set_reg(&v, 1, 0x41);
    sprite(&v, 0, 99, 80, 1);
    vram_write(&v, sat_base + 1, &.{0xD0});
    const out = render(&v, 100);
    for (0..16) |i| try expectEqual(@as(u5, @intCast(16 + i / 2 + 1)), out[gx(80 + i)]);
    try expectEqual(@as(u5, 0), out[gx(96)]);
    try expectEqual(@as(u5, 16 + 1), render(&v, 115)[gx(80)]);
    try expectEqual(@as(u5, 0), render(&v, 116)[gx(80)]);
    // Vertical: rows 0,0,1,1,...
    sprite(&v, 0, 99, 80, 2);
    for (0..16) |d| try expectEqual(@as(u5, @intCast(16 + d / 2 + 1)), render(&v, @intCast(100 + d))[gx(80)]);
    // 8x16 zoomed is 16x32; all eight sprites on a line are zoomed.
    set_reg(&v, 1, 0x43);
    solid_tile(&v, 6, 6);
    solid_tile(&v, 7, 7);
    for (0..8) |n| sprite(&v, @intCast(n), 99, @intCast(48 + n * 16), 6);
    vram_write(&v, sat_base + 8, &.{0xD0});
    try expectEqual(@as(u5, 16 + 7), render(&v, 131)[gx(48 + 7 * 16 + 15)]);
    try expectEqual(@as(u5, 16 + 6), render(&v, 115)[gx(48 + 3 * 16 + 15)]);
    try expectEqual(@as(u5, 0), render(&v, 132)[gx(48)]);
}

test "vdp: shift-left-8" {
    var v: Vdp = .{};
    setup(&v);
    solid_tile(&v, 1, 3);
    sprite(&v, 0, 99, 80, 1);
    vram_write(&v, sat_base + 1, &.{0xD0});
    set_reg(&v, 0, 0x0E);
    const out = render(&v, 100);
    try expectEqual(@as(u5, 0), out[gx(71)]);
    try expectEqual(@as(u5, 16 + 3), out[gx(72)]);
    try expectEqual(@as(u5, 16 + 3), out[gx(79)]);
    try expectEqual(@as(u5, 0), out[gx(80)]);
    // X = 4 shifted: columns -4..3, the visible part at 0..3.
    sprite(&v, 0, 99, 4, 1);
    const full = render_at(&v, 100, 0);
    for (0..4) |c| try expectEqual(@as(u5, 16 + 3), full[c]);
    try expectEqual(@as(u5, 0), full[4]);
}

test "vdp: collision flag, opaque overlap only, off the window too" {
    var v: Vdp = .{};
    setup(&v);
    for (0..8) |r| tile_row(&v, 1, @intCast(r), .{ 3, 3, 0, 0, 0, 0, 0, 0 });
    sprite(&v, 0, 99, 100, 1);
    sprite(&v, 1, 99, 102, 1); // transparent parts overlap only
    vram_write(&v, sat_base + 2, &.{0xD0});
    _ = render(&v, 100);
    try expectEqual(@as(u8, 0), v.status & vdp.status_collision);
    sprite(&v, 1, 99, 101, 1); // opaque pixel at column 101
    _ = render(&v, 100);
    try expect(v.status & vdp.status_collision != 0);
    _ = v.read_status();
    // Off the Game Gear window (columns 10..), still counted.
    sprite(&v, 0, 99, 10, 1);
    sprite(&v, 1, 99, 11, 1);
    _ = render(&v, 100);
    try expect(v.status & vdp.status_collision != 0);
    _ = v.read_status();
    // The last column counts; nothing wraps to column 0.
    sprite(&v, 0, 99, 255, 1);
    sprite(&v, 1, 99, 254, 1); // 254,255 vs 255: overlap at 255
    _ = render(&v, 100);
    try expect(v.status & vdp.status_collision != 0);
    _ = v.read_status();
    // On an active line outside the window (line 10), through tick with no sink.
    var w: Vdp = .{};
    setup(&w);
    for (0..8) |r| tile_row(&w, 1, @intCast(r), .{ 3, 3, 0, 0, 0, 0, 0, 0 });
    sprite(&w, 0, 9, 100, 1);
    sprite(&w, 1, 9, 101, 1);
    vram_write(&w, sat_base + 2, &.{0xD0});
    run_to_line(&w, 9, null);
    try expectEqual(@as(u8, 0), w.status & vdp.status_collision);
    run_to_line(&w, 10, null);
    try expect(w.status & vdp.status_collision != 0);
    // And the overflow flag on a visible line with a sink.
    _ = w.read_status();
    for (0..9) |n| sprite(&w, @intCast(n), 99, 20, 0);
    vram_write(&w, sat_base + 9, &.{0xD0});
    var cap: Capture = .{};
    run_to_line(&w, 101, cap.sink());
    try expect(w.status & vdp.status_overflow != 0);
    try expectEqual(@as(u8, 0), w.status & vdp.status_collision); // transparent
}

test "vdp: Vdp stays plain data and fits the keyframe" {
    var a: Vdp = .{};
    setup(&a);
    a.vram[123] = 7;
    const b = a;
    try expect(std.meta.eql(a, b));
    try expect(@sizeOf(Vdp) < 0x4000 + 256);
}
