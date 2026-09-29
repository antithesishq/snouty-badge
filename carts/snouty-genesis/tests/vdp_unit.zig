//! VDP unit tests from synthetic states (PLAN.md M1 Track B, SPEC.md
//! section 16): ports, DMA, counters and interrupts, the screen mapping
//! tables and the line renderer.
const std = @import("std");
const core = @import("core");
const vdp = core.vdp;
const Vdp = vdp.Vdp;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

// ---- Helpers ----

fn make() !*Vdp {
    const v = try std.testing.allocator.create(Vdp);
    v.reset();
    v.line_mode = .squeeze;
    return v;
}

fn free(v: *Vdp) void {
    std.testing.allocator.destroy(v);
}

/// A 68000 bus for DMA: 128 KB of words at `base`, open bus elsewhere.
const FakeBus = struct {
    base: u32 = 0,
    mem: [0x10000]u16 = @splat(0),
    reads: u32 = 0,

    pub fn read16(b: *FakeBus, addr: u24) u16 {
        b.reads += 1;
        const a: u32 = addr;
        if (a < b.base or a >= b.base + 0x20000) return 0xFFFF;
        return b.mem[(a - b.base) >> 1];
    }
};

var no_bus: FakeBus = .{};

fn ctl(v: *Vdp, w: u16) void {
    _ = v.write_control(w, &no_bus);
}

/// A two-word command: code CD5-CD0 and a 16-bit address.
fn cmd(v: *Vdp, code: u8, addr: u16) void {
    const c: u16 = code;
    ctl(v, (c & 3) << 14 | (addr & 0x3FFF));
    ctl(v, (c & 0x3C) << 2 | addr >> 14);
}

fn cmd_bus(v: *Vdp, code: u8, addr: u16, bus: *FakeBus) u32 {
    const c: u16 = code;
    _ = v.write_control((c & 3) << 14 | (addr & 0x3FFF), bus);
    return v.write_control((c & 0x3C) << 2 | addr >> 14, bus);
}

fn reg(v: *Vdp, r: u5, val: u8) void {
    ctl(v, 0x8000 | @as(u16, r) << 8 | val);
}

const code_vram_w: u8 = 0x01;
const code_cram_w: u8 = 0x03;
const code_vsram_w: u8 = 0x05;
const code_vram_r: u8 = 0x00;
const code_cram_r: u8 = 0x08;
const code_vsram_r: u8 = 0x04;

fn vram16(v: *const Vdp, a: u16) u16 {
    return @as(u16, v.vram[a]) << 8 | v.vram[a + 1];
}

fn poke16(v: *Vdp, a: u16, w: u16) void {
    v.vram[a] = @truncate(w >> 8);
    v.vram[a + 1] = @truncate(w);
}

/// Name tables and tables used by the render tests (H40, V28).
const nt_a: u16 = 0xC000;
const nt_w: u16 = 0xB000;
const nt_b: u16 = 0xE000;
const sat: u16 = 0xD800;
const hscroll: u16 = 0xDC00;

/// Display on, mode 5, H40, planes 32x32, full scroll, no window.
fn setup(v: *Vdp) void {
    v.regs[0] = 0x04;
    v.regs[1] = 0x44;
    v.regs[2] = nt_a >> 10;
    v.regs[3] = nt_w >> 10;
    v.regs[4] = nt_b >> 13;
    v.regs[5] = sat >> 9;
    v.regs[7] = 0;
    v.regs[11] = 0;
    v.regs[12] = 0x81;
    v.regs[13] = hscroll >> 10;
    v.regs[15] = 2;
    v.regs[16] = 0;
}

fn h32(v: *Vdp) void {
    v.regs[12] = 0x00;
}

/// Tile `t`: the same 8-pixel row word (pixel 0 in the top nibble) on
/// every row.
fn tile_rows(v: *Vdp, t: u16, row: u32) void {
    for (0..8) |y| tile_row(v, t, @intCast(y), row);
}

fn tile_row(v: *Vdp, t: u16, y: u16, row: u32) void {
    std.mem.writeInt(u32, v.vram[t * 32 + y * 4 ..][0..4], row, .big);
}

fn solid(v: *Vdp, t: u16, c: u4) void {
    tile_rows(v, t, @as(u32, c) * 0x11111111);
}

/// Name table entry: priority, palette, flips, tile.
fn ent(prio: bool, pal: u2, vf: bool, hf: bool, t: u11) u16 {
    return (if (prio) @as(u16, 0x8000) else 0) | @as(u16, pal) << 13 |
        (if (vf) @as(u16, 0x1000) else 0) | (if (hf) @as(u16, 0x0800) else 0) | t;
}

/// Put `e` at cell (cx, cy) of the plane at `base`, `w` cells wide.
fn cell(v: *Vdp, base: u16, w: u16, cx: u16, cy: u16, e: u16) void {
    poke16(v, base + (cy * w + cx) * 2, e);
}

/// Fill a whole plane (w x h cells) with `e`.
fn fill_plane(v: *Vdp, base: u16, w: u16, h: u16, e: u16) void {
    var cy: u16 = 0;
    while (cy < h) : (cy += 1) {
        var cx: u16 = 0;
        while (cx < w) : (cx += 1) cell(v, base, w, cx, cy, e);
    }
}

/// Sprite `n` of the table: screen position (x, y), size in cells,
/// link, attribute word (as a name table entry).
fn sprite(v: *Vdp, n: u16, x: i32, y: i32, wc: u8, hc: u8, link: u8, attr: u16) void {
    const e = sat + n * 8;
    poke16(v, e, @intCast(y + 128));
    v.vram[e + 2] = (wc - 1) << 2 | (hc - 1);
    v.vram[e + 3] = link;
    poke16(v, e + 4, attr);
    poke16(v, e + 6, @intCast(x + 128));
}

fn render(v: *Vdp, line: u16) [160]u8 {
    var out: [160]u8 = undefined;
    v.compose_line(line, &out);
    return out;
}

fn all(out: [160]u8, want: u8) bool {
    for (out) |p| if (p != want) return false;
    return true;
}

// ---- Control port ----

test "vdp: register write sets the register and leaves no command pending" {
    const v = try make();
    defer free(v);
    reg(v, 15, 0x02);
    reg(v, 7, 0x2A);
    reg(v, 23, 0x80);
    try expectEqual(@as(u8, 2), v.regs[15]);
    try expectEqual(@as(u8, 0x2A), v.regs[7]);
    try expectEqual(@as(u8, 0x80), v.regs[23]);
    try expect(!v.pending);
}

test "vdp: registers 24-31 are ignored" {
    const v = try make();
    defer free(v);
    ctl(v, 0x9F55); // register 31
    ctl(v, 0x9812); // register 24
    for (v.regs) |r| try expectEqual(@as(u8, 0), r);
    try expect(!v.pending);
}

test "vdp: two-word command latches code and address" {
    const v = try make();
    defer free(v);
    ctl(v, 0x4123); // CD1-0 = 01, A13-0 = 0123
    try expect(v.pending);
    ctl(v, 0x0003); // A15-14 = 11, CD5-2 = 0
    try expect(!v.pending);
    try expectEqual(@as(u16, 0xC123), v.addr);
    try expectEqual(@as(u8, 0x01), v.code);
    cmd(v, code_vsram_w, 0x0010);
    try expectEqual(@as(u8, 0x05), v.code);
    try expectEqual(@as(u16, 0x0010), v.addr);
    cmd(v, code_cram_r, 0x0040);
    try expectEqual(@as(u8, 0x08), v.code);
}

test "vdp: a status read clears the pending first word" {
    const v = try make();
    defer free(v);
    ctl(v, 0x4000);
    try expect(v.pending);
    _ = v.read_status();
    try expect(!v.pending);
    // So the next 8xxx word is a register write, not a second word.
    reg(v, 10, 0x33);
    try expectEqual(@as(u8, 0x33), v.regs[10]);
}

test "vdp: a data port write or read clears the pending first word" {
    const v = try make();
    defer free(v);
    ctl(v, 0x4000);
    v.write_data(0);
    try expect(!v.pending);
    ctl(v, 0x4000);
    _ = v.read_data();
    try expect(!v.pending);
}

test "vdp: the first word of a register write also sets the address low bits" {
    const v = try make();
    defer free(v);
    cmd(v, code_vram_w, 0xC000);
    reg(v, 15, 2); // 8F02: A13-0 = 0F02, CD1-0 = 10
    try expectEqual(@as(u16, 0xCF02), v.addr);
    try expectEqual(@as(u8, 0x02), v.code & 3);
}

// ---- Data port ----

test "vdp: VRAM word writes, big-endian, auto-increment and read-back" {
    const v = try make();
    defer free(v);
    reg(v, 15, 2);
    cmd(v, code_vram_w, 0x1000);
    v.write_data(0x1234);
    v.write_data(0xABCD);
    try expectEqual(@as(u8, 0x12), v.vram[0x1000]);
    try expectEqual(@as(u8, 0x34), v.vram[0x1001]);
    try expectEqual(@as(u16, 0xABCD), vram16(v, 0x1002));
    try expectEqual(@as(u16, 0x1004), v.addr);
    cmd(v, code_vram_r, 0x1000);
    try expectEqual(@as(u16, 0x1234), v.read_data());
    try expectEqual(@as(u16, 0xABCD), v.read_data());
}

test "vdp: VRAM write at an odd address swaps the bytes" {
    const v = try make();
    defer free(v);
    reg(v, 15, 2);
    cmd(v, code_vram_w, 0x2001);
    v.write_data(0x1234);
    try expectEqual(@as(u16, 0x3412), vram16(v, 0x2000));
}

test "vdp: auto-increment follows register 15, the address wraps at 64 K" {
    const v = try make();
    defer free(v);
    reg(v, 15, 0x80);
    cmd(v, code_vram_w, 0xFF80);
    v.write_data(0x1111);
    try expectEqual(@as(u16, 0x0000), v.addr);
    v.write_data(0x2222);
    try expectEqual(@as(u16, 0x1111), vram16(v, 0xFF80));
    try expectEqual(@as(u16, 0x2222), vram16(v, 0x0000));
    reg(v, 15, 0);
    cmd(v, code_vram_w, 0x0100);
    v.write_data(1);
    v.write_data(2);
    try expectEqual(@as(u16, 2), vram16(v, 0x0100));
}

test "vdp: CRAM writes keep the 9 color bits and wrap at 64 entries" {
    const v = try make();
    defer free(v);
    reg(v, 15, 2);
    cmd(v, code_cram_w, 0x0000);
    v.write_data(0xFFFF);
    v.write_data(0x0E02);
    try expectEqual(@as(u16, 0x0EEE), v.cram[0]);
    try expectEqual(@as(u16, 0x0E02), v.cram[1]);
    cmd(v, code_cram_w, 0x007E);
    v.write_data(0x0222);
    v.write_data(0x0444); // wraps to entry 0
    try expectEqual(@as(u16, 0x0222), v.cram[63]);
    try expectEqual(@as(u16, 0x0444), v.cram[0]);
    cmd(v, code_cram_r, 0x0002);
    try expectEqual(@as(u16, 0x0E02), v.read_data());
}

test "vdp: VSRAM writes keep 10 bits, entries past 39 are dropped" {
    const v = try make();
    defer free(v);
    reg(v, 15, 2);
    cmd(v, code_vsram_w, 0x0000);
    v.write_data(0xFFFF);
    v.write_data(0x0123);
    try expectEqual(@as(u16, 0x03FF), v.vsram[0]);
    try expectEqual(@as(u16, 0x0123), v.vsram[1]);
    cmd(v, code_vsram_w, 0x004E);
    v.write_data(0x0077); // entry 39
    v.write_data(0x0055); // entry 40: no such entry
    try expectEqual(@as(u16, 0x0077), v.vsram[39]);
    cmd(v, code_vsram_r, 0x0002);
    try expectEqual(@as(u16, 0x0123), v.read_data());
    cmd(v, code_vsram_r, 0x0050);
    try expectEqual(@as(u16, 0x03FF), v.read_data()); // past the end reads entry 0
}

// ---- Status and HV counter ----

test "vdp: status reads the fixed bits and an empty FIFO, never full" {
    const v = try make();
    defer free(v);
    setup(v);
    v.line = 10;
    v.line_cycles = 300;
    const s = v.read_status();
    try expectEqual(vdp.st_fixed | vdp.st_fifo_empty, s);
    try expectEqual(@as(u16, 0), s & vdp.st_fifo_full);
}

test "vdp: status V-blank from line 224 to 260 and while the display is off" {
    const v = try make();
    defer free(v);
    setup(v);
    v.line = 223;
    try expectEqual(@as(u16, 0), v.read_status() & vdp.st_vblank);
    v.line = 224;
    try expect(v.read_status() & vdp.st_vblank != 0);
    v.line = 260;
    try expect(v.read_status() & vdp.st_vblank != 0);
    v.line = 261;
    try expectEqual(@as(u16, 0), v.read_status() & vdp.st_vblank);
    v.line = 100;
    v.regs[1] = 0x04;
    try expect(v.read_status() & vdp.st_vblank != 0);
}

test "vdp: status H-blank follows the cycle offset in the line" {
    const v = try make();
    defer free(v);
    setup(v);
    v.line = 5;
    v.line_cycles = 0;
    try expectEqual(@as(u16, 0), v.read_status() & vdp.st_hblank);
    v.line_cycles = 60;
    try expect(v.read_status() & vdp.st_hblank != 0);
    v.line_cycles = 200;
    try expectEqual(@as(u16, 0), v.read_status() & vdp.st_hblank);
}

test "vdp: status V-int pending bit, sprite bits cleared by the read" {
    const v = try make();
    defer free(v);
    setup(v);
    v.vint_pending = true;
    v.status = vdp.st_overflow | vdp.st_collision;
    const s = v.read_status();
    try expect(s & vdp.st_vint != 0);
    try expect(s & vdp.st_overflow != 0);
    try expect(s & vdp.st_collision != 0);
    const s2 = v.read_status();
    try expectEqual(@as(u16, 0), s2 & (vdp.st_overflow | vdp.st_collision));
    try expect(s2 & vdp.st_vint != 0); // cleared by the acknowledge, not the read
    v.ack_irq(6);
    try expectEqual(@as(u16, 0), v.read_status() & vdp.st_vint);
}

test "vdp: HV counter at the start and end of a line, H40 and H32" {
    const v = try make();
    defer free(v);
    setup(v);
    v.line = 0;
    v.line_cycles = 0;
    try expectEqual(@as(u16, 0x00A5), v.hv_counter());
    v.line_cycles = 488;
    try expectEqual(@as(u16, 0x00A4), v.hv_counter());
    h32(v);
    v.line_cycles = 0;
    try expectEqual(@as(u16, 0x0085), v.hv_counter());
    v.line_cycles = 488;
    try expectEqual(@as(u16, 0x0084), v.hv_counter());
}

test "vdp: HV counter H jumps B6 to E4 (H40) and 93 to E9 (H32)" {
    const v = try make();
    defer free(v);
    setup(v);
    v.line = 3;
    // H40: 18 steps from A5 reach B6/B7; the next value after B6 is E4.
    var prev: u8 = 0xA5;
    var c: u16 = 0;
    var saw_jump = false;
    while (c < 489) : (c += 1) {
        v.line_cycles = c;
        const h: u8 = @truncate(v.hv_counter());
        if (h != prev) {
            if (prev == 0xB6) {
                try expectEqual(@as(u8, 0xE4), h);
                saw_jump = true;
            } else if (prev == 0xFF) {
                try expectEqual(@as(u8, 0x00), h);
            } else try expectEqual(prev + 1, h);
            prev = h;
        }
        try expect(!(h > 0xB6 and h < 0xE4));
    }
    try expect(saw_jump);
    h32(v);
    prev = 0x85;
    saw_jump = false;
    c = 0;
    while (c < 489) : (c += 1) {
        v.line_cycles = c;
        const h: u8 = @truncate(v.hv_counter());
        if (h != prev) {
            if (prev == 0x93) {
                try expectEqual(@as(u8, 0xE9), h);
                saw_jump = true;
            }
            prev = h;
        }
        try expect(!(h > 0x93 and h < 0xE9));
    }
    try expect(saw_jump);
    // Mid-line values within 2 of the hardware tables (cycle 200: H40 26, H32 20).
    v.line_cycles = 200;
    try expect(near(v.hv_counter(), 0x20));
    setup(v);
    try expect(near(v.hv_counter(), 0x26));
    v.line_cycles = 300;
    try expect(near(v.hv_counter(), 0x52));
}

fn near(hv: u16, h: u8) bool {
    const d: i16 = @as(i16, @as(u8, @truncate(hv))) - h;
    return @abs(d) <= 2;
}

test "vdp: HV counter V jumps EA to E5 in NTSC V28" {
    const v = try make();
    defer free(v);
    setup(v);
    v.line_cycles = 0;
    v.line = 0xEA;
    try expectEqual(@as(u16, 0xEA), v.hv_counter() >> 8);
    v.line = 0xEB;
    try expectEqual(@as(u16, 0xE5), v.hv_counter() >> 8);
    v.line = 261;
    try expectEqual(@as(u16, 0xFF), v.hv_counter() >> 8);
    v.line = 224;
    try expectEqual(@as(u16, 0xE0), v.hv_counter() >> 8);
}

test "vdp: register 0 bit 1 latches the HV counter" {
    const v = try make();
    defer free(v);
    setup(v);
    v.line = 50;
    v.line_cycles = 0;
    reg(v, 0, 0x06);
    const latched = v.hv_counter();
    try expectEqual(@as(u16, 0x32A5), latched);
    v.line = 60;
    v.line_cycles = 300;
    try expectEqual(latched, v.hv_counter());
    reg(v, 0, 0x04);
    try expectEqual(@as(u16, 60), v.hv_counter() >> 8);
}

// ---- DMA ----

test "vdp: VRAM fill writes the high byte at addr ^ 1 (increment 1)" {
    const v = try make();
    defer free(v);
    reg(v, 1, 0x14); // DMA enabled
    reg(v, 15, 1);
    reg(v, 19, 4);
    reg(v, 20, 0);
    reg(v, 23, 0x80); // fill
    cmd(v, code_vram_w | 0x20, 0x1000);
    try expect(v.fill_pending);
    v.write_data(0xAB77);
    try expect(!v.fill_pending);
    // The data write itself (AB77 at 1000), then 4 bytes of AB at
    // addresses 1001..1004, each stored at address ^ 1 (Genesis Plus GX's
    // behaviour): 1000, 1003, 1002, 1005.
    try expectEqual(@as(u8, 0xAB), v.vram[0x1000]);
    try expectEqual(@as(u8, 0x77), v.vram[0x1001]);
    try expectEqual(@as(u8, 0xAB), v.vram[0x1002]);
    try expectEqual(@as(u8, 0xAB), v.vram[0x1003]);
    try expectEqual(@as(u8, 0x00), v.vram[0x1004]);
    try expectEqual(@as(u8, 0xAB), v.vram[0x1005]);
    try expectEqual(@as(u8, 0x00), v.vram[0x1006]);
    try expectEqual(@as(u8, 0x00), v.vram[0x0FFF]);
    try expectEqual(@as(u8, 0), v.regs[19]);
    try expectEqual(@as(u8, 0), v.regs[20]);
    try expectEqual(@as(u16, 0x1005), v.addr);
}

test "vdp: VRAM fill with increment 2 fills every other byte" {
    const v = try make();
    defer free(v);
    reg(v, 1, 0x14);
    reg(v, 15, 2);
    reg(v, 19, 8);
    reg(v, 23, 0x80);
    cmd(v, code_vram_w | 0x20, 0x2000);
    v.write_data(0x5500);
    // Word write 5500 at 2000; fill from 2002: bytes 2003, 2005, ... get 55.
    try expectEqual(@as(u16, 0x5500), vram16(v, 0x2000));
    var a: u16 = 0x2002;
    while (a < 0x2012) : (a += 2) try expectEqual(@as(u16, 0x0055), vram16(v, a));
    try expectEqual(@as(u16, 0x0000), vram16(v, 0x2012));
}

test "vdp: DMA needs register 1 bit 4; without it CD5 is a plain command" {
    const v = try make();
    defer free(v);
    reg(v, 1, 0x04);
    reg(v, 15, 2);
    reg(v, 19, 16);
    reg(v, 23, 0x80);
    cmd(v, code_vram_w | 0x20, 0x3000);
    try expect(!v.fill_pending);
    v.write_data(0x1234);
    try expectEqual(@as(u16, 0x1234), vram16(v, 0x3000));
    try expectEqual(@as(u16, 0), vram16(v, 0x3002));
    try expectEqual(@as(u8, 16), v.regs[19]);
}

test "vdp: VRAM copy moves bytes and advances the source registers" {
    const v = try make();
    defer free(v);
    for (0..16) |i| v.vram[0x4000 + i] = @intCast(0x10 + i);
    reg(v, 1, 0x14);
    reg(v, 15, 1);
    reg(v, 19, 16);
    reg(v, 20, 0);
    reg(v, 21, 0x00);
    reg(v, 22, 0x40);
    reg(v, 23, 0xC0); // copy
    const stall = v.write_control(0x0000 | (0x5000 & 0x3FFF), &no_bus);
    try expectEqual(@as(u32, 0), stall);
    const stall2 = v.write_control(0x00C0 | (0x5000 >> 14), &no_bus); // CD5 + CD4, VRAM read
    try expectEqual(@as(u32, 0), stall2);
    for (0..16) |i| try expectEqual(@as(u8, @intCast(0x10 + i)), v.vram[0x5000 + i]);
    try expectEqual(@as(u8, 0x10), v.regs[21]);
    try expectEqual(@as(u8, 0x40), v.regs[22]);
    try expectEqual(@as(u8, 0), v.regs[19]);
}

test "vdp: 68000 memory to VRAM through the bus callback, with a stall" {
    const v = try make();
    defer free(v);
    const bus = try std.testing.allocator.create(FakeBus);
    defer std.testing.allocator.destroy(bus);
    bus.* = .{ .base = 0xFF0000 };
    for (0..64) |i| bus.mem[i] = @intCast(0x100 + i);
    reg(v, 1, 0x54); // display on, DMA
    reg(v, 12, 0x81);
    reg(v, 15, 2);
    reg(v, 19, 64);
    reg(v, 20, 0);
    // Source FF0000 >> 1 = 7F8000.
    reg(v, 21, 0x00);
    reg(v, 22, 0x80);
    reg(v, 23, 0x7F);
    v.line = 230; // V-blank
    _ = v.write_control(0x4000 | 0x0200, bus);
    const stall = v.write_control(0x0080, bus);
    for (0..64) |i| try expectEqual(@as(u16, @intCast(0x100 + i)), vram16(v, @intCast(0x0200 + i * 2)));
    try expectEqual(@as(u32, 64), bus.reads);
    // 64 words at 102 per line in H40 blank: 64 * 489 / 102, rounded up.
    try expectEqual(@as(u32, (64 * 489 + 101) / 102), stall);
    try expectEqual(@as(u8, 0x40), v.regs[21]);
    try expectEqual(@as(u8, 0x80), v.regs[22]);
    try expectEqual(@as(u8, 0), v.regs[19]);
    try expectEqual(@as(u16, 0x0280), v.addr);
}

test "vdp: DMA stall is larger during active display" {
    const v = try make();
    defer free(v);
    setup(v);
    v.code = code_vram_w;
    v.line = 100;
    try expectEqual(@as(u32, (90 * 489 + 8) / 9), v.dma_stall(90));
    v.regs[1] = 0x04; // display off: blank rate
    try expectEqual(@as(u32, (90 * 489 + 101) / 102), v.dma_stall(90));
    v.code = code_cram_w;
    try expectEqual(@as(u32, (90 * 489 + 197) / 198), v.dma_stall(90));
}

test "vdp: DMA source wraps inside its 128 KB window" {
    const v = try make();
    defer free(v);
    const bus = try std.testing.allocator.create(FakeBus);
    defer std.testing.allocator.destroy(bus);
    bus.* = .{ .base = 0x020000 };
    bus.mem[0xFFFF] = 0xAAAA; // 03FFFE
    bus.mem[0] = 0xBBBB; // 020000
    reg(v, 1, 0x14);
    reg(v, 15, 2);
    reg(v, 19, 2);
    // Source 03FFFE: word address 01FFFF.
    reg(v, 21, 0xFF);
    reg(v, 22, 0xFF);
    reg(v, 23, 0x01);
    _ = cmd_bus(v, code_vram_w | 0x20, 0x0000, bus);
    try expectEqual(@as(u16, 0xAAAA), vram16(v, 0));
    try expectEqual(@as(u16, 0xBBBB), vram16(v, 2));
    // Source word address 1FFFF + 2 = 0001 in the window (23 unchanged).
    try expectEqual(@as(u8, 0x01), v.regs[21]);
    try expectEqual(@as(u8, 0x00), v.regs[22]);
    try expectEqual(@as(u8, 0x01), v.regs[23]);
}

test "vdp: 68000 memory to CRAM and VSRAM" {
    const v = try make();
    defer free(v);
    const bus = try std.testing.allocator.create(FakeBus);
    defer std.testing.allocator.destroy(bus);
    bus.* = .{ .base = 0 };
    for (0..64) |i| bus.mem[0x100 + i] = @intCast(i * 2);
    reg(v, 1, 0x14);
    reg(v, 15, 2);
    reg(v, 19, 64);
    reg(v, 21, 0x00);
    reg(v, 22, 0x01); // source 000200
    reg(v, 23, 0x00);
    _ = cmd_bus(v, code_cram_w | 0x20, 0, bus);
    for (0..64) |i| try expectEqual(@as(u16, @intCast((i * 2) & 0x0EEE)), v.cram[i]);
    reg(v, 19, 40);
    reg(v, 21, 0x00);
    reg(v, 22, 0x01);
    _ = cmd_bus(v, code_vsram_w | 0x20, 0, bus);
    for (0..40) |i| try expectEqual(@as(u16, @intCast(i * 2)), v.vsram[i]);
}

test "vdp: DMA length 0 means 64 K" {
    const v = try make();
    defer free(v);
    reg(v, 1, 0x14);
    reg(v, 15, 1);
    reg(v, 19, 0);
    reg(v, 20, 0);
    reg(v, 23, 0x80);
    cmd(v, code_vram_w | 0x20, 0x0000);
    v.write_data(0x9900);
    for (v.vram) |b| try expectEqual(@as(u8, 0x99), b);
}

// ---- Counters and interrupts ----

fn run_lines(v: *Vdp, n: u32) void {
    var k: u32 = 0;
    while (k < n) : (k += 1) v.end_line();
}

test "vdp: line counter runs 0..261 and wraps" {
    const v = try make();
    defer free(v);
    run_lines(v, 261);
    try expectEqual(@as(u16, 261), v.line);
    v.line_cycles = 100;
    v.end_line();
    try expectEqual(@as(u16, 0), v.line);
    try expectEqual(@as(u16, 0), v.line_cycles);
}

test "vdp: V-int pending at line 224, level 6 only when enabled" {
    const v = try make();
    defer free(v);
    run_lines(v, 223);
    try expect(!v.vint_pending);
    v.end_line();
    try expectEqual(@as(u16, 224), v.line);
    try expect(v.vint_pending);
    try expectEqual(@as(u3, 0), v.irq_level());
    reg(v, 1, 0x64); // enable V-int now: the pending one is presented
    try expectEqual(@as(u3, 6), v.irq_level());
    v.ack_irq(6);
    try expectEqual(@as(u3, 0), v.irq_level());
    try expect(!v.vint_pending);
}

test "vdp: H-int every register 10 + 1 lines, after lines 111 and 223" {
    const v = try make();
    defer free(v);
    reg(v, 10, 111);
    reg(v, 0, 0x14); // H-int enabled
    // Frame 0 starts with a counter of 0; run a frame so the counter is
    // reloaded in V-blank as on hardware.
    run_lines(v, 262);
    v.hint_pending = false;
    var fired: [4]u16 = undefined;
    var n: usize = 0;
    var k: u16 = 0;
    while (k < 262) : (k += 1) {
        const l = v.line;
        v.end_line();
        if (v.hint_pending) {
            if (n < 4) fired[n] = l;
            n += 1;
            try expectEqual(@as(u3, 4), v.irq_level());
            v.ack_irq(4);
        }
    }
    try expectEqual(@as(usize, 2), n);
    try expectEqual(@as(u16, 111), fired[0]);
    try expectEqual(@as(u16, 223), fired[1]);
}

test "vdp: H-int counter reloads on V-blank lines, register 10 = 0 fires every line" {
    const v = try make();
    defer free(v);
    reg(v, 10, 0);
    v.line = 230;
    v.hint_counter = 5;
    v.end_line();
    try expectEqual(@as(u8, 0), v.hint_counter);
    try expect(!v.hint_pending);
    v.line = 0;
    v.end_line();
    try expect(v.hint_pending);
    v.hint_pending = false;
    v.end_line();
    try expect(v.hint_pending);
}

test "vdp: irq_level masks H-int with register 0 bit 4; V-int wins" {
    const v = try make();
    defer free(v);
    v.hint_pending = true;
    try expectEqual(@as(u3, 0), v.irq_level());
    reg(v, 0, 0x10);
    try expectEqual(@as(u3, 4), v.irq_level());
    reg(v, 1, 0x20);
    v.vint_pending = true;
    try expectEqual(@as(u3, 6), v.irq_level());
    v.ack_irq(6);
    try expectEqual(@as(u3, 4), v.irq_level());
    v.ack_irq(4);
    try expectEqual(@as(u3, 0), v.irq_level());
}

// ---- Screen mapping tables ----

test "vdp: squeeze and crop line tables and their inverse" {
    const v = try make();
    defer free(v);
    try expectEqual(@as(u16, 0), vdp.line_for_row(.squeeze, 0));
    try expectEqual(@as(u16, 1), vdp.line_for_row(.squeeze, 1));
    try expectEqual(@as(u16, 3), vdp.line_for_row(.squeeze, 2));
    try expectEqual(@as(u16, 222), vdp.line_for_row(.squeeze, 127));
    try expectEqual(@as(u16, 48), vdp.line_for_row(.crop, 0));
    try expectEqual(@as(u16, 175), vdp.line_for_row(.crop, 127));
    for ([_]vdp.LineMode{ .squeeze, .crop }) |m| {
        v.line_mode = m;
        var shown: u32 = 0;
        var l: u16 = 0;
        while (l < 262) : (l += 1) {
            if (v.row_for_line(l)) |r| {
                try expectEqual(l, vdp.line_for_row(m, r));
                shown += 1;
            }
        }
        try expectEqual(@as(u32, 128), shown);
    }
    v.line_mode = .squeeze;
    try expectEqual(@as(?u8, null), v.row_for_line(2));
    try expectEqual(@as(?u8, null), v.row_for_line(223));
    try expectEqual(@as(?u8, null), v.row_for_line(224));
    v.line_mode = .crop;
    try expectEqual(@as(?u8, null), v.row_for_line(47));
    try expectEqual(@as(?u8, 0), v.row_for_line(48));
    try expectEqual(@as(?u8, null), v.row_for_line(176));
}

test "vdp: H40 and H32 column tables" {
    // Through the renderer: a ramp of 1-pixel columns (pixel x has color
    // x mod 8 + 8 via tiles) shows which Genesis columns each badge
    // column samples.
    const v = try make();
    defer free(v);
    setup(v);
    tile_rows(v, 1, 0x89ABCDEF);
    fill_plane(v, nt_b, 32, 32, ent(false, 0, false, false, 1));
    var out = render(v, 0);
    for (out, 0..) |p, i| try expectEqual(@as(u8, @intCast(8 + (2 * i) % 8)), p);
    h32(v);
    out = render(v, 0);
    for (out, 0..) |p, i| try expectEqual(@as(u8, @intCast(8 + (i * 8 / 5) % 8)), p);
    try expectEqual(@as(u8, 8 + 254 % 8), out[159]);
}

// ---- Rendering: basics ----

test "vdp: display off renders the backdrop" {
    const v = try make();
    defer free(v);
    setup(v);
    solid(v, 1, 5);
    fill_plane(v, nt_b, 32, 32, ent(true, 0, false, false, 1));
    v.regs[7] = 0x23;
    v.regs[1] = 0x04;
    try expect(all(render(v, 10), 0x23));
}

test "vdp: empty planes show the backdrop color of register 7" {
    const v = try make();
    defer free(v);
    setup(v);
    v.regs[7] = 0x3A;
    try expect(all(render(v, 0), 0x3A));
    try expect(all(render(v, 223), 0x3A));
}

test "vdp: plane B solid tile with palette selection" {
    const v = try make();
    defer free(v);
    setup(v);
    solid(v, 1, 5);
    fill_plane(v, nt_b, 32, 32, ent(false, 2, false, false, 1));
    try expect(all(render(v, 7), 0x25));
    fill_plane(v, nt_b, 32, 32, ent(false, 3, false, false, 1));
    try expect(all(render(v, 7), 0x35));
}

test "vdp: 1-pixel vertical stripes render solid in H40 column dropping" {
    const v = try make();
    defer free(v);
    setup(v);
    tile_rows(v, 2, 0x23232323); // even x red (2), odd x green (3)
    fill_plane(v, nt_a, 32, 32, ent(false, 0, false, false, 2));
    try expect(all(render(v, 40), 0x02));
    poke16(v, hscroll, 1); // plane A scrolled right one pixel: the odd columns
    try expect(all(render(v, 40), 0x03));
}

test "vdp: 1-pixel vertical stripes in H32 follow the x * 8 / 5 table" {
    const v = try make();
    defer free(v);
    setup(v);
    h32(v);
    tile_rows(v, 2, 0x23232323);
    fill_plane(v, nt_a, 32, 32, ent(false, 0, false, false, 2));
    const out = render(v, 40);
    for (out, 0..) |p, i| try expectEqual(@as(u8, if ((i * 8 / 5) % 2 == 0) 2 else 3), p);
}

test "vdp: horizontal stripes are sampled per line" {
    const v = try make();
    defer free(v);
    setup(v);
    var y: u16 = 0;
    while (y < 8) : (y += 1) tile_row(v, 3, y, if (y % 2 == 0) 0x44444444 else 0x55555555);
    fill_plane(v, nt_a, 32, 32, ent(false, 0, false, false, 3));
    try expect(all(render(v, 80), 0x04));
    try expect(all(render(v, 81), 0x05));
}

test "vdp: tile H flip and V flip" {
    const v = try make();
    defer free(v);
    setup(v);
    // Row y: pixel x = x + 1 on row 0, rows 1-7 color 15.
    tile_row(v, 4, 0, 0x12345678);
    var y: u16 = 1;
    while (y < 8) : (y += 1) tile_row(v, 4, y, 0xFFFFFFFF);
    cell(v, nt_b, 32, 0, 0, ent(false, 0, false, false, 4));
    cell(v, nt_b, 32, 1, 0, ent(false, 0, false, true, 4));
    cell(v, nt_b, 32, 2, 0, ent(false, 0, true, false, 4));
    var out = render(v, 0);
    try expectEqual([4]u8{ 1, 3, 5, 7 }, out[0..4].*);
    try expectEqual([4]u8{ 8, 6, 4, 2 }, out[4..8].*);
    try expectEqual([4]u8{ 15, 15, 15, 15 }, out[8..12].*);
    out = render(v, 7);
    try expectEqual([4]u8{ 1, 3, 5, 7 }, out[8..12].*);
}

// ---- Rendering: priority ----

test "vdp: plane A over plane B by priority" {
    const v = try make();
    defer free(v);
    setup(v);
    solid(v, 1, 1);
    solid(v, 2, 2);
    // Columns 0-7 (cell 0): A low over B low; cell 1: A low, B high;
    // cell 2: A high, B high; cell 3: A transparent, B low.
    cell(v, nt_b, 32, 0, 0, ent(false, 1, false, false, 1));
    cell(v, nt_a, 32, 0, 0, ent(false, 2, false, false, 2));
    cell(v, nt_b, 32, 1, 0, ent(true, 1, false, false, 1));
    cell(v, nt_a, 32, 1, 0, ent(false, 2, false, false, 2));
    cell(v, nt_b, 32, 2, 0, ent(true, 1, false, false, 1));
    cell(v, nt_a, 32, 2, 0, ent(true, 2, false, false, 2));
    cell(v, nt_b, 32, 3, 0, ent(false, 1, false, false, 1));
    cell(v, nt_a, 32, 3, 0, ent(true, 2, false, false, 0));
    const out = render(v, 0);
    try expectEqual(@as(u8, 0x22), out[0]); // cell 0: badge columns 0-3
    try expectEqual(@as(u8, 0x11), out[4]); // cell 1
    try expectEqual(@as(u8, 0x22), out[8]); // cell 2
    try expectEqual(@as(u8, 0x11), out[12]); // cell 3
}

test "vdp: sprites between the priority layers" {
    const v = try make();
    defer free(v);
    setup(v);
    solid(v, 1, 1);
    solid(v, 2, 2);
    solid(v, 3, 3);
    // Planes: cells 0-1 B low, cells 2-3 B high, cells 4-5 A high over B
    // low, cell 6 B low.
    fill_plane(v, nt_b, 32, 1, ent(false, 0, false, false, 1));
    cell(v, nt_b, 32, 2, 0, ent(true, 0, false, false, 1));
    cell(v, nt_b, 32, 3, 0, ent(true, 0, false, false, 1));
    cell(v, nt_a, 32, 4, 0, ent(true, 0, false, false, 2));
    cell(v, nt_a, 32, 5, 0, ent(true, 0, false, false, 2));
    // Low sprites at x 0, 16, 32; a high sprite at 8, 24, 40.
    sprite(v, 0, 0, 0, 1, 1, 1, ent(false, 1, false, false, 3));
    sprite(v, 1, 8, 0, 1, 1, 2, ent(true, 1, false, false, 3));
    sprite(v, 2, 16, 0, 1, 1, 3, ent(false, 1, false, false, 3));
    sprite(v, 3, 24, 0, 1, 1, 4, ent(true, 1, false, false, 3));
    sprite(v, 4, 32, 0, 1, 1, 5, ent(false, 1, false, false, 3));
    sprite(v, 5, 40, 0, 1, 1, 0, ent(true, 1, false, false, 3));
    const out = render(v, 0);
    try expectEqual(@as(u8, 0x13), out[0]); // low sprite over low plane
    try expectEqual(@as(u8, 0x13), out[4]); // high sprite over low plane
    try expectEqual(@as(u8, 0x01), out[8]); // low sprite under high plane B
    try expectEqual(@as(u8, 0x13), out[12]); // high sprite over high plane B
    try expectEqual(@as(u8, 0x02), out[16]); // low sprite under high plane A
    try expectEqual(@as(u8, 0x13), out[20]); // high sprite over high plane A
    try expectEqual(@as(u8, 0x01), out[24]); // no sprite
}

test "vdp: a transparent high-priority tile does not hide a low sprite" {
    const v = try make();
    defer free(v);
    setup(v);
    solid(v, 3, 3);
    fill_plane(v, nt_a, 32, 32, ent(true, 0, false, false, 0));
    fill_plane(v, nt_b, 32, 32, ent(true, 0, false, false, 0));
    sprite(v, 0, 0, 0, 1, 1, 0, ent(false, 1, false, false, 3));
    const out = render(v, 0);
    try expectEqual(@as(u8, 0x13), out[0]);
}

// ---- Rendering: scroll and plane sizes ----

test "vdp: 32-cell plane wraps at 256 pixels in H40" {
    const v = try make();
    defer free(v);
    setup(v);
    solid(v, 1, 7);
    cell(v, nt_b, 32, 0, 0, ent(false, 0, false, false, 1));
    const out = render(v, 0);
    try expectEqual(@as(u8, 7), out[0]);
    try expectEqual(@as(u8, 0), out[4]);
    try expectEqual(@as(u8, 7), out[128]); // screen x 256 is plane x 0 again
    try expectEqual(@as(u8, 7), out[131]);
    try expectEqual(@as(u8, 0), out[132]);
}

test "vdp: 64-cell plane: cell 40 is on screen at x 320 - scroll" {
    const v = try make();
    defer free(v);
    setup(v);
    v.regs[16] = 0x01; // 64 x 32
    solid(v, 1, 9);
    cell(v, nt_b, 64, 40, 0, ent(false, 0, false, false, 1));
    cell(v, nt_b, 64, 0, 1, ent(false, 0, false, false, 1)); // row 1 is 128 bytes on
    var out = render(v, 0);
    try expectEqual(@as(u8, 0), out[159]);
    poke16(v, hscroll + 2, 0x3FF & (0 -% @as(u16, 16))); // B scrolled left 16
    out = render(v, 0);
    try expectEqual(@as(u8, 9), out[152]); // screen 304 = plane 320
    try expectEqual(@as(u8, 9), out[155]);
    try expectEqual(@as(u8, 0), out[156]);
    poke16(v, hscroll + 2, 0);
    out = render(v, 8);
    try expectEqual(@as(u8, 9), out[0]);
}

test "vdp: 128-cell plane and 64-line height with vertical scroll" {
    const v = try make();
    defer free(v);
    setup(v);
    v.regs[16] = 0x03; // 128 x 32
    solid(v, 1, 4);
    cell(v, nt_b, 128, 100, 2, ent(false, 0, false, false, 1));
    poke16(v, hscroll + 2, 0x3FF & (0 -% @as(u16, 800))); // plane x = screen x + 800
    var out = render(v, 16);
    try expectEqual(@as(u8, 4), out[0]);
    try expectEqual(@as(u8, 0), out[4]);
    // 32 x 64: row 40 at vscroll 256.
    v.regs[16] = 0x10;
    poke16(v, hscroll + 2, 0);
    cell(v, nt_b, 32, 0, 40, ent(false, 0, false, false, 1));
    v.vsram[1] = 256;
    out = render(v, 64);
    try expectEqual(@as(u8, 4), out[0]);
    // Height 32 wraps at 256: the same scroll lands on row 8.
    v.regs[16] = 0x00;
    cell(v, nt_b, 32, 0, 8, ent(false, 0, false, false, 1));
    try expectEqual(@as(u8, 4), render(v, 64)[0]);
}

test "vdp: horizontal scroll per line, per 8 lines and full screen" {
    const v = try make();
    defer free(v);
    setup(v);
    tile_rows(v, 1, 0x12345678);
    fill_plane(v, nt_a, 32, 32, ent(false, 0, false, false, 1));
    // Entries: line l has A scroll l (per line table).
    var l: u16 = 0;
    while (l < 224) : (l += 1) poke16(v, hscroll + l * 4, l);
    v.regs[11] = 0x03; // per line
    // Line 3: plane x = 2i - 3; badge column 2 = screen 4 -> plane 1 -> color 2.
    try expectEqual(@as(u8, 2), render(v, 3)[2]);
    v.regs[11] = 0x02; // per 8 lines: line 13 uses line 8's entry
    try expectEqual(@as(u8, (16 - 8) % 8 + 1), render(v, 13)[8]);
    v.regs[11] = 0x00; // full: line 0's entry (0)
    try expectEqual(@as(u8, 1), render(v, 13)[0]);
    v.regs[11] = 0x01; // invalid: line & 7, line 13 uses line 5's entry
    try expectEqual(@as(u8, (16 - 5) % 8 + 1), render(v, 13)[8]);
}

test "vdp: vertical scroll full screen and per 2-cell column" {
    const v = try make();
    defer free(v);
    setup(v);
    solid(v, 1, 1);
    solid(v, 2, 2);
    // Plane A rows: row r has tile 1 on even rows, 2 on odd.
    var cy: u16 = 0;
    while (cy < 32) : (cy += 1) {
        var cx: u16 = 0;
        while (cx < 32) : (cx += 1) cell(v, nt_a, 32, cx, cy, ent(false, 0, false, false, if (cy % 2 == 0) 1 else 2));
    }
    try expect(all(render(v, 0), 1));
    v.vsram[0] = 8; // full: A moves up one row
    try expect(all(render(v, 0), 2));
    // Per column: column c (16 px = 8 badge columns) scrolled by 8 * c.
    v.regs[11] = 0x04;
    var c: u16 = 0;
    while (c < 20) : (c += 1) v.vsram[c * 2] = c * 8;
    const out = render(v, 0);
    c = 0;
    while (c < 20) : (c += 1) {
        const want: u8 = if (c % 2 == 0) 1 else 2;
        for (out[c * 8 .. c * 8 + 8]) |p| try expectEqual(want, p);
    }
}

// ---- Rendering: window ----

test "vdp: window over whole lines from register 18" {
    const v = try make();
    defer free(v);
    setup(v);
    solid(v, 1, 1);
    solid(v, 2, 2);
    fill_plane(v, nt_a, 32, 32, ent(false, 0, false, false, 1));
    fill_plane(v, nt_w, 64, 32, ent(false, 0, false, false, 2));
    v.regs[18] = 0x02; // window above line 16
    try expect(all(render(v, 15), 2));
    try expect(all(render(v, 16), 1));
    v.regs[18] = 0x82; // window from line 16 down
    try expect(all(render(v, 15), 1));
    try expect(all(render(v, 16), 2));
}

test "vdp: window column split in H40 and H32" {
    const v = try make();
    defer free(v);
    setup(v);
    solid(v, 1, 1);
    solid(v, 2, 2);
    fill_plane(v, nt_a, 32, 32, ent(false, 0, false, false, 1));
    fill_plane(v, nt_w, 64, 32, ent(false, 0, false, false, 2));
    v.regs[18] = 0x00; // no whole-line window
    v.regs[17] = 0x05; // window left of x 80
    var out = render(v, 50);
    for (out, 0..) |p, i| try expectEqual(@as(u8, if (i < 40) 2 else 1), p);
    v.regs[17] = 0x85; // window right of x 80
    out = render(v, 50);
    for (out, 0..) |p, i| try expectEqual(@as(u8, if (i < 40) 1 else 2), p);
    // H32: 32-cell window rows; x 80 is badge column 50.
    h32(v);
    fill_plane(v, nt_w, 32, 32, ent(false, 0, false, false, 2));
    v.regs[17] = 0x05;
    out = render(v, 50);
    for (out, 0..) |p, i| try expectEqual(@as(u8, if (i < 50) 2 else 1), p);
    // Width beyond the screen: all window.
    v.regs[17] = 0x1F;
    try expect(all(render(v, 50), 2));
}

test "vdp: window tiles are not scrolled and use the window table" {
    const v = try make();
    defer free(v);
    setup(v);
    tile_rows(v, 1, 0x12345678);
    cell(v, nt_w, 64, 0, 3, ent(false, 1, false, false, 1));
    v.regs[18] = 0x1F; // window above line 248: every line
    poke16(v, hscroll, 5);
    v.vsram[0] = 40;
    const out = render(v, 24);
    try expectEqual([4]u8{ 0x11, 0x13, 0x15, 0x17 }, out[0..4].*);
    try expectEqual(@as(u8, 0), out[4]);
}

// ---- Rendering: sprites ----

test "vdp: sprite link list stops at link 0" {
    const v = try make();
    defer free(v);
    setup(v);
    solid(v, 1, 6);
    sprite(v, 0, 0, 10, 1, 1, 1, ent(false, 0, false, false, 1));
    sprite(v, 1, 16, 10, 1, 1, 0, ent(false, 0, false, false, 1));
    sprite(v, 2, 32, 10, 1, 1, 0, ent(false, 0, false, false, 1)); // not linked
    const out = render(v, 12);
    try expectEqual(@as(u8, 6), out[0]);
    try expectEqual(@as(u8, 6), out[8]);
    try expectEqual(@as(u8, 0), out[16]);
    try expectEqual(@as(u8, 0), render(v, 9)[0]);
    try expectEqual(@as(u8, 0), render(v, 18)[0]);
}

test "vdp: sprite link list walks in link order, not table order" {
    const v = try make();
    defer free(v);
    setup(v);
    solid(v, 1, 1);
    for (4..8) |t| solid(v, @intCast(t), if (t < 6) 2 else 1);
    // 0 -> 5 -> 3; 5 is in front of 3 where they overlap.
    sprite(v, 0, 100, 0, 1, 1, 5, ent(false, 0, false, false, 1));
    sprite(v, 5, 0, 0, 2, 1, 3, ent(false, 0, false, false, 4));
    sprite(v, 3, 8, 0, 2, 1, 0, ent(false, 0, false, false, 6));
    const out = render(v, 0);
    try expectEqual(@as(u8, 2), out[4]); // x 8: sprite 5 wins
    try expectEqual(@as(u8, 1), out[8]); // x 16: only sprite 3
    try expectEqual(@as(u8, 1), out[50]);
    try expect(v.read_status() & vdp.st_collision != 0);
    try expectEqual(@as(u16, 0), v.read_status() & vdp.st_collision);
}

test "vdp: 20 sprites per line in H40, the 21st sets overflow" {
    const v = try make();
    defer free(v);
    setup(v);
    solid(v, 1, 3);
    var n: u16 = 0;
    while (n < 21) : (n += 1) sprite(v, n, n * 8, 0, 1, 1, @intCast(if (n == 20) 0 else n + 1), ent(false, 0, false, false, 1));
    const out = render(v, 0);
    try expectEqual(@as(u8, 3), out[19 * 4]);
    try expectEqual(@as(u8, 0), out[20 * 4]);
    try expect(v.read_status() & vdp.st_overflow != 0);
}

test "vdp: 16 sprites per line in H32" {
    const v = try make();
    defer free(v);
    setup(v);
    h32(v);
    solid(v, 1, 3);
    var n: u16 = 0;
    while (n < 17) : (n += 1) sprite(v, n, n * 10, 0, 1, 1, @intCast(if (n == 16) 0 else n + 1), ent(false, 0, false, false, 1));
    const out = render(v, 0);
    try expectEqual(@as(u8, 3), out[vdp_first32(150)]);
    try expectEqual(@as(u8, 0), out[vdp_first32(160)]);
    try expect(v.read_status() & vdp.st_overflow != 0);
}

fn vdp_first32(x: u16) usize {
    // First badge column showing Genesis column >= x in H32.
    var i: usize = 0;
    while (i * 8 / 5 < x) i += 1;
    return i;
}

test "vdp: 320 sprite pixels per line in H40, the crossing sprite is cut" {
    const v = try make();
    defer free(v);
    setup(v);
    for (1..5) |t| solid(v, @intCast(t), 3);
    // Nine 4-cell-wide sprites (288 px) stacked at x 0, then one at x 200
    // (320 px reached: its first 32 pixels are drawn), then one at x 260.
    var n: u16 = 0;
    while (n < 9) : (n += 1) sprite(v, n, 0, 0, 4, 1, @intCast(n + 1), ent(false, 0, false, false, 1));
    sprite(v, 9, 200, 0, 4, 1, 10, ent(false, 0, false, false, 1));
    sprite(v, 10, 260, 0, 1, 1, 0, ent(false, 0, false, false, 1));
    var out = render(v, 0);
    try expectEqual(@as(u8, 3), out[100]);
    try expectEqual(@as(u8, 3), out[115]);
    try expectEqual(@as(u8, 0), out[130]); // dropped
    // Ten 32-px sprites exactly: the 10th crosses 288 -> 320 and is cut
    // to 0 pixels of excess, drawn whole.
    sprite(v, 8, 0, 0, 3, 1, 9, ent(false, 0, false, false, 1)); // now 8*32 + 24 = 280
    sprite(v, 9, 200, 0, 4, 1, 10, ent(false, 0, false, false, 1)); // 312
    sprite(v, 10, 260, 0, 2, 1, 0, ent(false, 0, false, false, 1)); // 328: cut to 8 px
    out = render(v, 0);
    try expectEqual(@as(u8, 3), out[115]);
    try expectEqual(@as(u8, 3), out[133]); // x 266
    try expectEqual(@as(u8, 0), out[134]); // x 268: cut
}

test "vdp: an X = 0 sprite masks later sprites only after one with X != 0" {
    const v = try make();
    defer free(v);
    setup(v);
    solid(v, 1, 3);
    // Mask first in the list: no effect.
    sprite(v, 0, -128, 0, 1, 1, 1, ent(false, 0, false, false, 1)); // X = 0
    sprite(v, 1, 40, 0, 1, 1, 0, ent(false, 0, false, false, 1));
    try expectEqual(@as(u8, 3), render(v, 0)[20]);
    // Visible sprite, then the mask, then another: the last is masked.
    sprite(v, 0, 0, 0, 1, 1, 1, ent(false, 0, false, false, 1));
    sprite(v, 1, -128, 0, 1, 1, 2, ent(false, 0, false, false, 1));
    sprite(v, 2, 40, 0, 1, 1, 0, ent(false, 0, false, false, 1));
    const out = render(v, 0);
    try expectEqual(@as(u8, 3), out[0]);
    try expectEqual(@as(u8, 0), out[20]);
    // The mask applies on its line only.
    sprite(v, 1, -128, 8, 1, 1, 2, ent(false, 0, false, false, 1));
    try expectEqual(@as(u8, 3), render(v, 0)[20]);
}

test "vdp: sprite cells are column-major; H flip and V flip" {
    const v = try make();
    defer free(v);
    setup(v);
    // Tiles 10..15 solid colors 1..6: a 2 x 3 sprite at tile 10 has
    // columns (10, 11, 12) and (13, 14, 15).
    for (0..6) |k| solid(v, @intCast(10 + k), @intCast(1 + k));
    sprite(v, 0, 0, 0, 2, 3, 0, ent(false, 0, false, false, 10));
    var out = render(v, 0);
    try expectEqual(@as(u8, 1), out[0]);
    try expectEqual(@as(u8, 4), out[4]);
    out = render(v, 17);
    try expectEqual(@as(u8, 3), out[0]);
    try expectEqual(@as(u8, 6), out[4]);
    try expectEqual(@as(u8, 0), out[8]);
    try expectEqual(@as(u8, 0), render(v, 24)[0]);
    sprite(v, 0, 0, 0, 2, 3, 0, ent(false, 0, true, true, 10));
    out = render(v, 0);
    try expectEqual(@as(u8, 6), out[0]);
    try expectEqual(@as(u8, 3), out[4]);
}

test "vdp: sprite pixels flip within the tile, off-screen left clips" {
    const v = try make();
    defer free(v);
    setup(v);
    tile_rows(v, 1, 0x12345678);
    sprite(v, 0, 0, 0, 1, 1, 1, ent(false, 1, false, true, 1));
    sprite(v, 1, -4, 8, 1, 1, 0, ent(false, 1, false, false, 1));
    var out = render(v, 0);
    try expectEqual([4]u8{ 0x18, 0x16, 0x14, 0x12 }, out[0..4].*);
    out = render(v, 8);
    try expectEqual([2]u8{ 0x15, 0x17 }, out[0..2].*);
    try expectEqual(@as(u8, 0), out[2]);
}

// ---- Rendering: shadow/highlight ----

test "vdp: shadow/highlight shades low-priority planes and the backdrop" {
    const v = try make();
    defer free(v);
    setup(v);
    v.regs[12] = 0x89;
    v.regs[7] = 0x01;
    solid(v, 1, 5);
    cell(v, nt_b, 32, 0, 0, ent(false, 0, false, false, 1)); // low: shadow
    cell(v, nt_b, 32, 1, 0, ent(true, 0, false, false, 1)); // high: normal
    cell(v, nt_a, 32, 2, 0, ent(true, 0, false, false, 0)); // transparent high tile over the backdrop
    const out = render(v, 0);
    try expectEqual(@as(u8, 0x05 | vdp.tag_shadow), out[0]);
    try expectEqual(@as(u8, 0x05), out[4]);
    try expectEqual(@as(u8, 0x01), out[8]);
    try expectEqual(@as(u8, 0x01 | vdp.tag_shadow), out[12]);
}

test "vdp: shadow/highlight sprite operators and sprite intensity" {
    const v = try make();
    defer free(v);
    setup(v);
    v.regs[12] = 0x89;
    solid(v, 1, 5);
    solid(v, 2, 14);
    solid(v, 3, 15);
    solid(v, 4, 7);
    fill_plane(v, nt_b, 32, 32, ent(false, 0, false, false, 1)); // low everywhere
    cell(v, nt_b, 32, 4, 0, ent(true, 0, false, false, 1)); // cells 4-5 high
    cell(v, nt_b, 32, 5, 0, ent(true, 0, false, false, 1));
    sprite(v, 0, 0, 0, 1, 1, 1, ent(false, 3, false, false, 2)); // highlight op over shadowed: normal
    sprite(v, 1, 8, 0, 1, 1, 2, ent(false, 3, false, false, 3)); // shadow op
    sprite(v, 2, 16, 0, 1, 1, 3, ent(false, 1, false, false, 4)); // low sprite: takes the shadow
    sprite(v, 3, 24, 0, 1, 1, 4, ent(true, 1, false, false, 4)); // high sprite: normal
    sprite(v, 4, 32, 0, 1, 1, 5, ent(true, 3, false, false, 2)); // highlight op over normal: highlight
    sprite(v, 5, 40, 0, 1, 1, 6, ent(true, 3, false, false, 3)); // shadow op over normal: shadow
    sprite(v, 6, 48, 0, 1, 1, 0, ent(false, 1, false, false, 2)); // palette 1 color 14: always normal
    const out = render(v, 0);
    try expectEqual(@as(u8, 0x05), out[0]);
    try expectEqual(@as(u8, 0x05 | vdp.tag_shadow), out[4]);
    try expectEqual(@as(u8, 0x17 | vdp.tag_shadow), out[8]);
    try expectEqual(@as(u8, 0x17), out[12]);
    try expectEqual(@as(u8, 0x05 | vdp.tag_highlight), out[16]);
    try expectEqual(@as(u8, 0x05 | vdp.tag_shadow), out[20]);
    try expectEqual(@as(u8, 0x1E), out[24]);
    try expectEqual(@as(u8, 0x05 | vdp.tag_shadow), out[28]); // no sprite, low plane
}

test "vdp: without shadow/highlight, palette 3 colors 14 and 15 are plain" {
    const v = try make();
    defer free(v);
    setup(v);
    solid(v, 2, 14);
    sprite(v, 0, 0, 0, 1, 1, 0, ent(false, 3, false, false, 2));
    try expectEqual(@as(u8, 0x3E), render(v, 0)[0]);
}

// ---- Rendering: misc ----

test "vdp: register 0 bit 5 blanks the leftmost 8 columns" {
    const v = try make();
    defer free(v);
    setup(v);
    v.regs[7] = 0x02;
    solid(v, 1, 9);
    fill_plane(v, nt_b, 32, 32, ent(false, 0, false, false, 1));
    sprite(v, 0, 0, 0, 1, 1, 0, ent(true, 0, false, false, 1));
    v.regs[0] = 0x24;
    const out = render(v, 0);
    try expectEqual([4]u8{ 2, 2, 2, 2 }, out[0..4].*);
    try expectEqual(@as(u8, 9), out[4]);
}

const Sink = struct {
    rows: u32 = 0,
    last_row: u8 = 0,
    px: [160]u8 = undefined,
    c0: u16 = 0,

    fn on_line(ctx: *anyopaque, row: u8, line: *const [160]u8, cram: *const [64]u16) void {
        const s: *Sink = @ptrCast(@alignCast(ctx));
        s.rows += 1;
        s.last_row = row;
        s.px = line.*;
        s.c0 = cram[0];
    }
};

test "vdp: render_line composes the current line and calls the sink" {
    const v = try make();
    defer free(v);
    setup(v);
    solid(v, 1, 4);
    cell(v, nt_b, 32, 0, 12, ent(false, 1, false, false, 1));
    v.cram[0] = 0x0E00;
    var s: Sink = .{};
    const sink: vdp.LineSink = .{ .ctx = &s, .func = &Sink.on_line };
    v.line = 96;
    const r = v.row_for_line(v.line) orelse return error.NotShown;
    v.render_line(r, sink);
    try expectEqual(@as(u32, 1), s.rows);
    try expectEqual(r, s.last_row);
    try expectEqual(@as(u8, 0x14), s.px[0]);
    try expectEqual(@as(u8, 0), s.px[4]);
    try expectEqual(@as(u16, 0x0E00), s.c0);
}

test "vdp: a frame of rendered rows through the line table" {
    const v = try make();
    defer free(v);
    setup(v);
    var s: Sink = .{};
    const sink: vdp.LineSink = .{ .ctx = &s, .func = &Sink.on_line };
    var l: u16 = 0;
    while (l < vdp.lines_per_frame) : (l += 1) {
        if (v.row_for_line(v.line)) |r| v.render_line(r, sink);
        v.end_line();
    }
    try expectEqual(@as(u32, vdp.out_h), s.rows);
    try expectEqual(@as(u8, vdp.out_h - 1), s.last_row);
}
