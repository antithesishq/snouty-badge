//! mikey/bus/lynx: Mikey's timers and interrupts, the bus map and the cart
//! port, the boot traps and CPUSLEEP (PLAN.md M1 Track C). They drive the
//! machine through registers and `step_one`, never through instructions, so
//! they hold with the M1 CPU stub as with the real CPU.
const std = @import("std");
const core = @import("core");
const files = @import("testfiles.zig");
const mikey = core.mikey;
const bus = core.bus;
const boot = core.boot;
const Mikey = mikey.Mikey;
const Lynx = core.Lynx;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

// Timer register offsets for timer i.
fn bkup(i: u8) u8 {
    return i * 4;
}
fn ctla(i: u8) u8 {
    return i * 4 + 1;
}
fn cnt(i: u8) u8 {
    return i * 4 + 2;
}
fn ctlb(i: u8) u8 {
    return i * 4 + 3;
}
const C = mikey.Ctla;

/// Advance `m` event by event (exactly to each timer event) for `ticks`.
fn run_events_for(m: *Mikey, ticks: u64) void {
    const end = m.now + ticks;
    while (true) {
        const next = @min(m.next_event, end);
        m.advance(next - m.now);
        if (m.now >= end) return;
    }
}

/// The tick of timer i's next interrupt from now, stepping event by event.
fn next_irq_tick(m: *Mikey, i: u3, limit: u64) ?u64 {
    const bit = @as(u8, 1) << i;
    const end = m.now + limit;
    while (m.now < end) {
        if (m.intset & bit != 0) return m.now;
        const next = @min(m.next_event, end);
        m.advance(next - m.now);
    }
    return if (m.intset & bit != 0) m.now else null;
}

test "mikey: timer period at each clock select (backup + 1) x 16 << sel ticks" {
    for (0..7) |sel| {
        var m: Mikey = .{};
        m.write(bkup(6), 9);
        m.write(cnt(6), 9);
        m.write(ctla(6), C.irq_enable | C.reload | C.count | @as(u8, @intCast(sel)));
        const period: u64 = 10 * (@as(u64, 16) << @intCast(sel));
        const first = next_irq_tick(&m, 6, 4 * period).?;
        // First use: between backup and backup + 1 source periods.
        try expect(first > 9 * (@as(u64, 16) << @intCast(sel)) and first <= period);
        m.write(mikey.Reg.intrst, 0x40);
        const second = next_irq_tick(&m, 6, 4 * period).?;
        try expectEqual(period, second - first);
    }
}

test "mikey: clock edges are global (count read, first borrow, CNT write keeps phase)" {
    var m: Mikey = .{};
    m.advance(3);
    m.write(cnt(6), 5);
    m.write(ctla(6), C.irq_enable | C.count); // one-shot, 1 us
    try expectEqual(@as(u8, 5), m.read(cnt(6)));
    m.advance(16 - 3); // the first edge at tick 16
    try expectEqual(@as(u8, 4), m.read(cnt(6)));
    try expectEqual(@as(?u64, 96), next_irq_tick(&m, 6, 1000)); // 16 + 5 x 16
    try expectEqual(@as(u8, 0), m.read(cnt(6)));
    try expectEqual(mikey.Ctlb.done, m.read(ctlb(6)));
}

test "mikey: linking 0 -> 2 -> 4 and 1 -> 3 -> 5 -> 7" {
    var m: Mikey = .{};
    // Chain A: timer 0 every 2 x 16 ticks, timer 2 every 3 of those, timer 4
    // counts timer 2's borrows.
    m.write(bkup(0), 1);
    m.write(cnt(0), 1);
    m.write(bkup(2), 2);
    m.write(cnt(2), 2);
    m.write(ctla(2), C.irq_enable | C.reload | C.count | C.linked);
    m.write(bkup(4), 200);
    m.write(cnt(4), 200);
    m.write(ctla(4), C.reload | C.count | C.linked);
    m.write(ctla(0), C.reload | C.count);
    const t2a = next_irq_tick(&m, 2, 10_000).?;
    m.write(mikey.Reg.intrst, 0xFF);
    const t2b = next_irq_tick(&m, 2, 10_000).?;
    try expectEqual(@as(u64, 2 * 3 * 16), t2b - t2a);
    try expectEqual(@as(u8, 198), m.read(cnt(4)));
    // Chain B: 1 -> 3 -> 5 -> 7, each linked stage dividing by 2.
    var n: Mikey = .{};
    for ([_]u8{ 3, 5, 7 }) |i| {
        n.write(bkup(i), 1);
        n.write(cnt(i), 1);
        n.write(ctla(i), C.reload | C.count | C.linked | if (i == 7) C.irq_enable else 0);
    }
    n.write(bkup(1), 0);
    n.write(cnt(1), 0);
    n.write(ctla(1), C.reload | C.count);
    const a = next_irq_tick(&n, 7, 10_000).?;
    n.write(mikey.Reg.intrst, 0x80);
    const b = next_irq_tick(&n, 7, 10_000).?;
    try expectEqual(@as(u64, 16 * 2 * 2 * 2), b - a);
    // Timer 1 underflows also reached timer 3 (no IRQ asked of 1, 3, 5).
    try expectEqual(@as(u8, 0x80), n.intset);
}

test "mikey: one-shot stops with DONE, CTLB clear restarts, RESET_DONE is a level" {
    var m: Mikey = .{};
    m.write(cnt(6), 1);
    m.write(ctla(6), C.irq_enable | C.count);
    _ = next_irq_tick(&m, 6, 1000).?;
    m.write(mikey.Reg.intrst, 0x40);
    // Stopped at 0 with DONE: no more interrupts.
    try expectEqual(@as(?u64, null), next_irq_tick(&m, 6, 2000));
    try expectEqual(mikey.Ctlb.done, m.read(ctlb(6)));
    // Clearing DONE rearms the borrow at 0: one more interrupt.
    m.write(ctlb(6), 0);
    try expect(next_irq_tick(&m, 6, 100) != null);
    m.write(mikey.Reg.intrst, 0x40);
    try expectEqual(@as(?u64, null), next_irq_tick(&m, 6, 2000));
    // RESET_DONE held: an interrupt every source clock.
    m.write(ctla(6), C.irq_enable | C.reset_done | C.count);
    var k: u32 = 0;
    while (k < 4) : (k += 1) {
        const t0 = m.now;
        const t = next_irq_tick(&m, 6, 100).?;
        try expect(t - t0 <= 16);
        m.write(mikey.Reg.intrst, 0x40);
    }
    try expectEqual(@as(u8, 0), m.read(ctlb(6)));
}

test "mikey: CTLB borrow-in write clocks once (lynx-tests timers CTLB RD/WR)" {
    var m: Mikey = .{};
    try expectEqual(@as(u8, 0), m.read(ctlb(3)));
    m.write(cnt(3), 0x80);
    m.write(ctlb(3), 0x0A);
    try expectEqual(@as(u8, 0x08), m.read(ctlb(3)));
    try expectEqual(@as(u8, 0x7F), m.read(cnt(3)));
    m.write(ctlb(3), 0);
    try expectEqual(@as(u8, 0), m.read(ctlb(3)));
    // A borrow from a software clock reaches the linked successor.
    m.write(cnt(5), 1);
    m.write(ctla(5), C.irq_enable | C.count | C.linked);
    m.write(cnt(3), 0);
    m.write(ctlb(3), 0x02);
    try expectEqual(@as(u8, 0), m.read(cnt(5)));
    m.write(ctlb(3), 0x02);
    try expectEqual(@as(u8, 0x20), m.intset);
}

test "mikey: INTSET/INTRST and the IRQ line (UART level on TXINTEN)" {
    var m: Mikey = .{};
    try expect(!m.irq_line());
    m.write(mikey.Reg.intset, 0x41);
    try expect(m.irq_line());
    try expectEqual(@as(u8, 0x41), m.read(mikey.Reg.intrst));
    try expectEqual(@as(u8, 0x41), m.read(mikey.Reg.intset));
    m.write(mikey.Reg.intrst, 0x01);
    try expectEqual(@as(u8, 0x40), m.read(mikey.Reg.intset));
    m.write(mikey.Reg.intrst, 0x40);
    try expect(!m.irq_line());
    // A disabled timer interrupt never sets its bit.
    m.write(cnt(6), 0);
    m.write(ctla(6), C.reload | C.count);
    run_events_for(&m, 1000);
    try expect(!m.irq_line());
    // The UART transmitter is always ready: TXINTEN holds bit 4 on.
    try expectEqual(mikey.serctl_idle, m.read(mikey.Reg.serctl));
    m.write(mikey.Reg.serctl, 0x80);
    m.write(mikey.Reg.intrst, 0x10);
    try expectEqual(@as(u8, 0x10), m.read(mikey.Reg.intset));
    m.write(mikey.Reg.serctl, 0);
    try expect(!m.irq_line());
    try expectEqual(@as(u8, 0x01), m.read(mikey.Reg.mikeyhrev));
}

test "mikey: registers (palette widths, DISPADR, IODAT inputs)" {
    var m: Mikey = .{};
    m.write(0xA3, 0xFF);
    m.write(0xB3, 0xFF);
    try expectEqual(@as(u8, 0x0F), m.read(0xA3));
    try expectEqual(@as(u8, 0xFF), m.read(0xB3));
    m.write(mikey.Reg.dispadrl, 0x23);
    m.write(mikey.Reg.dispadrh, 0x45);
    try expectEqual(@as(u16, 0x4523), m.dispadr);
    // IODIR 3 (bits 0-1 out), IODAT 2: bit 1 reads back, bit 0 is an output now.
    m.write(mikey.Reg.iodir, 0x03);
    m.write(mikey.Reg.iodat, 0x02);
    try expectEqual(@as(u8, 0x02), m.read(mikey.Reg.iodat));
    m.write(mikey.Reg.iodir, 0x02);
    try expectEqual(@as(u8, 0x03), m.read(mikey.Reg.iodat)); // external power input high
    // Audio registers are stored and read back.
    m.write(0x25, 0x5A);
    try expectEqual(@as(u8, 0x5A), m.read(0x25));
}

/// Mikey with the boot ROM's writes applied.
fn booted_mikey() Mikey {
    var m: Mikey = .{};
    for (boot.boot_mikey_writes) |w| m.write(@truncate(w.addr), w.value);
    m.dispadr_latched = m.dispadr; // as Lynx.reset leaves it
    return m;
}

test "mikey: vertical blank cadence from the boot values (105 lines x 159 us)" {
    var m = booted_mikey();
    var last: ?u64 = null;
    var seen = m.vblank_count;
    var intervals: u32 = 0;
    const end: u64 = 5 * 267_120 + 10;
    while (m.now < end) {
        m.advance(m.next_event - m.now);
        if (m.vblank_count != seen) {
            seen = m.vblank_count;
            if (last) |prev| {
                try expectEqual(@as(u64, 105 * 159 * 16), m.now - prev);
                intervals += 1;
            }
            last = m.now;
        }
    }
    try expect(intervals >= 3);
    // 16,695 us: 59.90 Hz.
    try expectEqual(@as(u64, 267_120), 105 * 159 * 16);
}

test "mikey: DISPADR latch on the third blank line, DMA and refresh steal per frame" {
    var m = booted_mikey();
    // Run to a vertical blank.
    const v0 = m.vblank_count;
    while (m.vblank_count == v0) m.advance(m.next_event - m.now);
    m.steal = 0;
    m.write(mikey.Reg.dispadrl, 0x00);
    m.write(mikey.Reg.dispadrh, 0x80);
    try expectEqual(@as(u16, 0x2000), m.dispadr_latched);
    // Two lines later it is still the old address; the third line latches.
    var lines: u32 = 0;
    var last_t2 = m.timers[2].value;
    while (lines < 3) {
        m.advance(m.next_event - m.now);
        if (m.timers[2].value != last_t2) {
            last_t2 = m.timers[2].value;
            lines += 1;
            if (lines < 2) try expectEqual(@as(u16, 0x2000), m.dispadr_latched);
        }
    }
    try expectEqual(@as(u16, 0x8000), m.dispadr_latched);
    // A whole frame of steal: 102 visible lines of 10 bursts plus the top
    // line's prefetch, 3 blank lines of refresh (2544 / 64 ticks).
    const v1 = m.vblank_count;
    while (m.vblank_count == v1) m.advance(m.next_event - m.now);
    m.steal = 0;
    const v2 = m.vblank_count;
    while (m.vblank_count == v2) m.advance(m.next_event - m.now);
    try expectEqual(@as(u32, 102 * mikey.dma_ticks_per_line + mikey.dma_ticks_per_burst + 3 * (2544 / 64)), m.steal);
}

test "mikey: a quiet fast timer (UART baud) costs no events and reads right" {
    var m: Mikey = .{};
    m.write(bkup(4), 1);
    m.write(cnt(4), 1);
    m.write(ctla(4), C.reload | C.count); // every 32 ticks
    try expectEqual(mikey.ticks_never, m.next_event);
    m.advance(10_000);
    try expectEqual(mikey.Ctlb.done, m.read(ctlb(4)));
    // 10,000 = 312 x 32 + 16: the count is 1 - (16 >> 4) % 2 ... read it.
    const c = m.read(cnt(4));
    try expect(c <= 1);
    m.advance(16);
    try expect(m.read(cnt(4)) != c);
}

// ---------------------------------------------------------------------------
// The bus and the machine

var l: Lynx = undefined;
var rom_buf: [64 * 1024]u8 = undefined;

/// The shipped raycaster, booted (always in the repository).
fn boot_raycast() !void {
    const file = files.read_cart_file("roms/raycast.lnx", &rom_buf) orelse return error.SkipZigTest;
    const lay = core.cart.parse(file, @intCast(file.len));
    try expectEqual(core.cart.Refusal.ok, lay.verdict);
    l.init_in_place(core.Cart.from_slice(&lay, file));
}

test "bus: MAPCTL overlays (vectors, ROM space, $FFF8, $FFF9, Suzy and Mikey off)" {
    try boot_raycast();
    try expectEqual(@as(u8, 0), l.mapctl);
    l.ram[0xFE10] = 0x77;
    l.ram[0xFFFC] = 0x11;
    l.ram[0xFFF8] = 0x42;
    l.ram[0xFD88] = 0x99;
    l.ram[0xFC88] = 0x98;
    try expectEqual(@as(u8, 0x00), l.read(0xFE10)); // never ROM bytes
    try expectEqual(@as(u8, 0x80), l.read(0xFFFC)); // reset vector $FF80
    try expectEqual(@as(u8, 0xFF), l.read(0xFFFD));
    try expectEqual(@as(u8, 0x00), l.read(0xFFFA)); // NMI $3000
    try expectEqual(@as(u8, 0x30), l.read(0xFFFB));
    try expectEqual(@as(u8, 0x80), l.read(0xFFFE)); // IRQ $FF80
    try expectEqual(@as(u8, 0x42), l.read(0xFFF8));
    try expectEqual(@as(u8, 0x01), l.read(0xFD88)); // MIKEYHREV
    // Writes to ROM space land in RAM.
    l.write(0xFE11, 0x66);
    try expectEqual(@as(u8, 0x66), l.ram[0xFE11]);
    l.write(0xFFF9, 0x0F);
    try expectEqual(@as(u8, 0x0F), l.read(0xFFF9));
    try expectEqual(@as(u8, 0x77), l.read(0xFE10));
    try expectEqual(@as(u8, 0x11), l.read(0xFFFC));
    try expectEqual(@as(u8, 0x99), l.read(0xFD88));
    try expectEqual(@as(u8, 0x98), l.read(0xFC88));
    l.write(0xFFF9, 0x00);
}

test "bus: tick costs (page mode stream, data cycles, Mikey timers, Suzy, RCART)" {
    try boot_raycast();
    const t0 = l.ticks;
    _ = l.fetch(0x0201); // stream closed after boot: 5
    _ = l.fetch(0x0202); // 4
    _ = l.fetch(0x0210); // boundary: 5, stays open
    _ = l.fetch(0x0211); // 4
    try expectEqual(@as(u64, 18), l.ticks - t0);
    _ = l.read(0x1234); // 5, closes
    _ = l.fetch(0x0212); // 5
    try expectEqual(@as(u64, 28), l.ticks - t0);
    _ = l.read(0xFD80); // Mikey 5
    _ = l.read(0xFD02); // Mikey timer 18
    _ = l.read(0xFC92); // Suzy 9
    _ = l.read(0xFCB2); // RCART 15
    l.write(0xFC92, 0); // Suzy write 5
    try expectEqual(@as(u64, 28 + 5 + 18 + 9 + 15 + 5), l.ticks - t0);
    // MAPCTL bit 7: no page-mode fetch.
    l.write(0xFFF9, 0x80);
    const t1 = l.ticks;
    _ = l.fetch(0x0300);
    _ = l.fetch(0x0301);
    try expectEqual(@as(u64, 10), l.ticks - t1);
    l.write(0xFFF9, 0x00);
}

test "bus: JOYSTICK, SWITCHES and LEFTHAND" {
    try boot_raycast();
    l.pad = core.Pad.up | core.Pad.right | core.Pad.a | core.Pad.pause;
    try expectEqual(@as(u8, 0x80 | 0x10 | 0x01), l.read(0xFCB0));
    try expectEqual(@as(u8, 0x01 | bus.switches_cart_inactive), l.read(0xFCB1));
    try expectEqual(@as(u8, 0x40 | 0x20 | 0x01), bus.joystick_byte(l.pad, true));
    l.pad = 0;
    try expectEqual(@as(u8, bus.switches_cart_inactive), l.read(0xFCB1));
}

test "bus: the cart port (block 7 by strobes, counter wrap, strobe high clears)" {
    try boot_raycast();
    // 1 KB blocks. Select block 7: eight strobes, MSB first, IODAT bit 1 data.
    const block: u8 = 7;
    var k: u3 = 7;
    while (true) : (k -= 1) {
        const bit = (block >> k) & 1;
        l.write(0xFD8B, if (bit != 0) 0x02 else 0x00); // IODAT
        l.write(0xFD87, 0x03); // strobe high (power on)
        l.write(0xFD87, 0x02); // low
        if (k == 0) break;
    }
    try expectEqual(block, l.port.block);
    try expectEqual(@as(u32, 0), l.port.counter);
    for (0..4) |i| try expectEqual(l.cart.read(7, @intCast(i)), l.read(0xFCB2));
    // Counter wraps at the block size.
    l.port.counter = 1023;
    try expectEqual(l.cart.read(7, 1023), l.read(0xFCB2));
    try expectEqual(@as(u32, 0), l.port.counter);
    // While the strobe is high the counter is held at 0.
    _ = l.read(0xFCB2);
    l.write(0xFD87, 0x03);
    try expectEqual(@as(u32, 0), l.port.counter);
    _ = l.read(0xFCB2);
    try expectEqual(@as(u32, 0), l.port.counter);
    l.write(0xFD87, 0x02);
    // That rising edge shifted one more bit in (IODAT bit 1 still 1).
    try expectEqual(@as(u8, (block << 1) | 1), l.port.block);
    // RCART1 (no bank 1) reads $FF and advances the counter.
    try expectEqual(@as(u8, 0xFF), l.read(0xFCB3));
    try expectEqual(@as(u32, 1), l.port.counter);
}

test "lynx: boot lands at $0200 with the post-boot state (raycast loader)" {
    try boot_raycast();
    try expect(!l.halted);
    try expectEqual(@as(u16, 0x0200), l.cpu.regs.pc);
    try expectEqual(@as(u8, 0), l.cpu.regs.a);
    try expectEqual(@as(u8, 2), l.cpu.regs.y);
    try expectEqual(@as(u8, 0x01), l.cpu.regs.s);
    try expectEqual(@as(u8, 0), l.port.block);
    try expectEqual(@as(u32, 52), l.port.counter);
    try expectEqual(@as(u16, 0x2000), l.mikey.dispadr);
    try expectEqual(@as(u8, 0x0D), l.mikey.dispctl);
    try expectEqual(@as(u8, 0x9E), l.mikey.timers[0].backup);
    try expectEqual(@as(u8, 0x1F), l.mikey.timers[2].ctla);
    try expectEqual(@as(u8, 0x03), l.mikey.iodir);
    try expectEqual(@as(u8, 0x02), l.mikey.iodat);
}

test "lynx: the $FE00 trap selects a block and returns; $FE4A decrypts a frame" {
    try boot_raycast();
    // JSR $FE00 from $1230 with A = 5: the stack holds $1232.
    const r = &l.cpu.regs;
    r.s = 0xF0;
    l.ram[0x1F0] = 0x12;
    l.ram[0x1EF] = 0x32;
    r.s = 0xEE;
    r.a = 5;
    r.p = 0x80 | 0x20 | 0x04; // N set
    r.pc = 0xFE00;
    l.step_one();
    try expectEqual(@as(u8, 5), l.port.block);
    try expectEqual(@as(u32, 0), l.port.counter);
    try expectEqual(@as(u16, 0x1233), r.pc);
    try expectEqual(@as(u8, 0xF0), r.s);
    try expectEqual(@as(u8, 0), r.a);
    try expectEqual(@as(u8, 2), r.x);
    try expect(r.p & 0x80 == 0 and r.p & 0x03 == 0x03);
    // Back to block 0 and decrypt the first frame again, to $0400.
    r.s = 0xF0;
    l.ram[0x1F0] = 0x12;
    l.ram[0x1EF] = 0x32;
    r.s = 0xEE;
    r.a = 0;
    r.pc = 0xFE00;
    l.step_one();
    l.ram[boot.zp_dest_lo] = 0x00;
    l.ram[boot.zp_dest_hi] = 0x04;
    l.ram[boot.zp_transition] = 0;
    r.pc = 0xFE4A;
    l.step_one();
    try expect(!l.halted);
    try expectEqual(@as(u16, 0x0200), r.pc);
    try expectEqual(@as(u8, 2), r.y);
    try expectEqualSlices(l.ram[0x0200..0x0232], l.ram[0x0400..0x0432]);
    try expectEqual(@as(u32, 52), l.port.counter);
}

fn expectEqualSlices(a: []const u8, b: []const u8) !void {
    try std.testing.expectEqualSlices(u8, a, b);
}

test "lynx: a PC elsewhere in ROM space re-runs the boot; not with the ROM unmapped" {
    try boot_raycast();
    l.cpu.regs.pc = 0xFF80;
    const first = l.ram[0x0200];
    l.ram[0x0200] ^= 0xFF;
    l.step_one();
    try expectEqual(@as(u32, 1), l.rom_resets);
    try expectEqual(@as(u16, 0x0200), l.cpu.regs.pc);
    try expect(!l.halted);
    // The loader was decrypted again.
    try expectEqual(first, l.ram[0x0200]);
    // With MAPCTL bit 2 set, $FE00 is RAM: no trap.
    l.write(0xFFF9, 0x04);
    l.cpu.regs.pc = 0xFE00;
    const block = l.port.block;
    l.cpu.regs.a = 9;
    l.step_one();
    try expectEqual(block, l.port.block);
    try expectEqual(@as(u32, 1), l.rom_resets);
}

test "lynx: CPUSLEEP with and without pending sprites, SDONEACK, pending IRQs" {
    try boot_raycast();
    // Nothing pending: the CPU does not sleep (sleep is broken in Mikey).
    l.write(0xFD91, 0);
    try expect(!l.sleeping);
    try expectEqual(@as(u32, 0), l.sprite_runs);
    // A sprite list (empty: SCBNEXT = 0) with the bus enabled: drawn at once.
    l.write(0xFC90, 0x01); // SUZYBUSEN
    l.write(0xFC91, 0x01); // SPRGO
    try expect(l.suzy.sprites_pending());
    l.write(0xFD90, 0); // SDONEACK
    l.write(0xFD91, 0);
    try expectEqual(@as(u32, 1), l.sprite_runs);
    try expect(!l.suzy.sprites_pending());
    try expect(l.mikey.suzy_done);
    // Without SDONEACK the next CPUSLEEP does nothing.
    l.write(0xFC91, 0x01);
    l.write(0xFD91, 0);
    try expectEqual(@as(u32, 1), l.sprite_runs);
    // A pending interrupt (even masked) keeps the CPU awake.
    l.write(0xFD90, 0);
    l.write(0xFD81, 0x40);
    l.write(0xFD91, 0);
    try expectEqual(@as(u32, 1), l.sprite_runs);
    l.write(0xFD80, 0xFF);
    l.write(0xFD91, 0);
    try expectEqual(@as(u32, 2), l.sprite_runs);
    // The contract's idle sleep: asleep until the next interrupt.
    l.write(0xFD90, 0);
    l.idle_sleep = true;
    l.write(0xFD91, 0);
    try expect(l.sleeping);
    const t = l.ticks;
    l.frame_end = l.ticks + 100_000;
    l.step_one();
    try expect(l.sleeping); // no interrupt enabled: time passed asleep
    try expect(l.ticks > t);
    try expect(l.sleep_ticks > 0);
    l.write(0xFD81, 0x01);
    l.step_one();
    try expect(!l.sleeping);
    l.idle_sleep = false;
}

test "lynx: frames advance 266,667 ticks (fraction carried) and copy the display at vertical blank" {
    try boot_raycast();
    // A recognisable byte in the boot display buffer ($2000).
    l.ram[0x2000] = 0xAB;
    l.ram[0x2000 + core.frame_bytes - 1] = 0xCD;
    l.mikey.green[3] = 0x7;
    var k: u32 = 0;
    while (k < 3) : (k += 1) l.step_frame(0);
    try expect(l.ticks >= 800_000 and l.ticks < 800_000 + 400);
    try expect(l.display_frames >= 2);
    // With the M1 CPU stub nothing overwrites the buffer; with a real CPU
    // the loader may, so only check the copy when RAM still holds the bytes.
    if (l.ram[0x2000] == 0xAB) {
        const f = l.frame();
        try expectEqual(@as(u8, 0xAB), f.pixels[0]);
        try expectEqual(@as(u8, 0xCD), f.pixels[core.frame_bytes - 1]);
        try expectEqual(@as(u8, 0x7), f.green[3]);
    }
    try expect(l.dma_ticks > 0);
}
