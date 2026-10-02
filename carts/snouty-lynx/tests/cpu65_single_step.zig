//! cpu65: SingleStepTests 65x02 rockwell65c02/v1 (SPEC.md section 16) on
//! core/cpu65.zig, plus the IRQ sequence (the suite has no interrupts).
//!
//! Every case runs on a flat 64 KB `TestBus` that logs each bus call
//! (`fetch`, `read` and `dummy` all log "read", as the suite does) and is compared
//! on the final registers, every `final.ram` entry, the cycle count and
//! each cycle's address, value and kind. P is compared with bits 4 and 5
//! forced set on both sides: the suite stores bit 5 set and bit 4 as the
//! generator left it (clear in most files, set throughout 0f/f1/ff, and
//! PLP/RTI clear it), while `Regs.p` always reads both set (docs/CPU.md).
//!
//! Data: tests/roms/65c02/*.json (tools/fetch_test_roms.sh; the test skips
//! when absent). `LYNX_SST_DIR` overrides the directory (the --all
//! batches). One `PASS name cases` / `FAIL name why` line per file goes to
//! stderr, which tools/fetch_test_roms.sh --all collects via LYNX_SST_CMD.
const std = @import("std");
const core = @import("core");
const cpu65 = core.cpu65;

pub const State = struct {
    pc: u16,
    s: u8,
    a: u8,
    x: u8,
    y: u8,
    p: u8,
    ram: []const [2]u32,
};

pub const Case = struct {
    name: []const u8,
    initial: State,
    final: State,
    /// [address, value, "read"|"write"] per bus cycle.
    cycles: []const std.json.Value,
};

pub const Summary = struct {
    files: u32 = 0,
    cases: u64 = 0,
    failed: u64 = 0,
    fetches: u64 = 0,
    reads: u64 = 0,
    writes: u64 = 0,
};

const Cycle = struct { addr: u16, val: u8, write: bool };

/// Flat 64 KB RAM that logs every bus cycle.
pub const TestBus = struct {
    ram: [0x10000]u8 = @splat(0),
    log: [16]Cycle = undefined,
    n: usize = 0,
    irq: bool = false,
    fetches: u64 = 0,
    reads: u64 = 0,
    writes: u64 = 0,

    fn rec(b: *TestBus, addr: u16, val: u8, is_write: bool) void {
        if (b.n < b.log.len) b.log[b.n] = .{ .addr = addr, .val = val, .write = is_write };
        b.n += 1;
    }

    pub fn fetch(b: *TestBus, addr: u16) u8 {
        b.fetches += 1;
        b.rec(addr, b.ram[addr], false);
        return b.ram[addr];
    }

    pub fn read(b: *TestBus, addr: u16) u8 {
        b.reads += 1;
        b.rec(addr, b.ram[addr], false);
        return b.ram[addr];
    }

    /// An internal cycle: the suite lists it as a read of `addr`.
    pub fn dummy(b: *TestBus, addr: u16) void {
        b.reads += 1;
        b.rec(addr, b.ram[addr], false);
    }

    pub fn write(b: *TestBus, addr: u16, v: u8) void {
        b.writes += 1;
        b.rec(addr, v, true);
        b.ram[addr] = v;
    }

    pub fn irq_line(b: *TestBus) bool {
        return b.irq;
    }
};

const Cpu = cpu65.Cpu(TestBus);

/// Runs one case; returns a description of the first mismatch, or null.
fn run_case(bus: *TestBus, c: *const Case, why: []u8) ?[]const u8 {
    for (c.initial.ram) |kv| bus.ram[@intCast(kv[0])] = @intCast(kv[1]);
    var cpu: Cpu = .{ .regs = .{
        .a = c.initial.a,
        .x = c.initial.x,
        .y = c.initial.y,
        .s = c.initial.s,
        .p = c.initial.p,
        .pc = c.initial.pc,
    } };
    bus.n = 0;
    cpu.step(bus);
    defer {
        for (c.initial.ram) |kv| bus.ram[@intCast(kv[0])] = 0;
        for (c.final.ram) |kv| bus.ram[@intCast(kv[0])] = 0;
    }
    const f = c.final;
    const r = cpu.regs;
    if (r.pc != f.pc or r.s != f.s or r.a != f.a or r.x != f.x or r.y != f.y or (r.p | 0x30) != (f.p | 0x30))
        return std.fmt.bufPrint(why, "{s}: regs pc={x:0>4} s={x:0>2} a={x:0>2} x={x:0>2} y={x:0>2} p={x:0>2}, want pc={x:0>4} s={x:0>2} a={x:0>2} x={x:0>2} y={x:0>2} p={x:0>2}", .{ c.name, r.pc, r.s, r.a, r.x, r.y, r.p, f.pc, f.s, f.a, f.x, f.y, f.p }) catch "regs";
    for (f.ram) |kv| {
        const got = bus.ram[@intCast(kv[0])];
        if (got != kv[1]) return std.fmt.bufPrint(why, "{s}: ram[{x:0>4}]={x:0>2}, want {x:0>2}", .{ c.name, kv[0], got, kv[1] }) catch "ram";
    }
    if (bus.n != c.cycles.len) return std.fmt.bufPrint(why, "{s}: {d} cycles, want {d}", .{ c.name, bus.n, c.cycles.len }) catch "cycles";
    for (c.cycles, 0..) |cv, i| {
        const it = cv.array.items;
        const addr: u16 = @intCast(it[0].integer);
        const val: u8 = @intCast(it[1].integer);
        const is_write = std.mem.eql(u8, it[2].string, "write");
        const g = bus.log[i];
        if (g.addr != addr or g.val != val or g.write != is_write)
            return std.fmt.bufPrint(why, "{s}: cycle {d} {x:0>4}:{x:0>2} {s}, want {x:0>4}:{x:0>2} {s}", .{ c.name, i, g.addr, g.val, if (g.write) "write" else "read", addr, val, it[2].string }) catch "cycle";
    }
    return null;
}

/// Parses one file and runs every case; prints one PASS/FAIL line.
pub fn check_file(gpa: std.mem.Allocator, bus: *TestBus, text: []const u8, name: []const u8, sum: *Summary) !void {
    const parsed = try std.json.parseFromSlice([]const Case, gpa, text, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var failed: u64 = 0;
    var why_buf: [256]u8 = undefined;
    var first: ?[]const u8 = null;
    var first_buf: [256]u8 = undefined;
    for (parsed.value) |*c| {
        if (run_case(bus, c, &why_buf)) |why| {
            if (failed < 3) std.debug.print("cpu65: {s}: {s}\n", .{ name, why });
            if (first == null) {
                @memcpy(first_buf[0..why.len], why);
                first = first_buf[0..why.len];
            }
            failed += 1;
        }
    }
    if (failed == 0) {
        std.debug.print("PASS {s} {d}\n", .{ name, parsed.value.len });
    } else {
        std.debug.print("FAIL {s} {d}/{d} cases, first: {s}\n", .{ name, failed, parsed.value.len, first.? });
    }
    sum.cases += parsed.value.len;
    sum.failed += failed;
    sum.files += 1;
}

const default_dirs = [_][]const u8{ "carts/snouty-lynx/tests/roms/65c02", "tests/roms/65c02", "../tests/roms/65c02" };

test "cpu65: SingleStepTests rockwell65c02 (tests/roms/65c02/*.json)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var dir: std.Io.Dir = undefined;
    var found = false;
    if (std.testing.environ.getPosix("LYNX_SST_DIR")) |p| {
        dir = try std.Io.Dir.cwd().openDir(io, p, .{ .iterate = true });
        found = true;
    } else for (default_dirs) |p| {
        dir = std.Io.Dir.cwd().openDir(io, p, .{ .iterate = true }) catch continue;
        found = true;
        break;
    }
    if (!found) {
        std.debug.print("cpu65: SingleStepTests skipped: tests/roms/65c02 absent (tools/fetch_test_roms.sh)\n", .{});
        return error.SkipZigTest;
    }
    defer dir.close(io);
    const bus = try gpa.create(TestBus);
    defer gpa.destroy(bus);
    bus.* = .{};
    // Own line first: the test runner's "n/m name..." prefix has no newline.
    std.debug.print("cpu65: running SingleStepTests\n", .{});
    var sum: Summary = .{};
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const text = try dir.readFileAlloc(io, entry.name, gpa, .limited(16 << 20));
        defer gpa.free(text);
        try check_file(gpa, bus, text, entry.name, &sum);
    }
    if (sum.cases > 0) {
        // Bus calls per instruction, x100, for the tick-model sanity check.
        std.debug.print("cpu65: {d} files, {d} cases, {d} failed; per instruction x100: fetch {d}, read {d}, write {d}\n", .{
            sum.files,                     sum.cases,                   sum.failed,
            bus.fetches * 100 / sum.cases, bus.reads * 100 / sum.cases, bus.writes * 100 / sum.cases,
        });
    }
    try std.testing.expect(sum.files > 0);
    try std.testing.expectEqual(@as(u64, 0), sum.failed);
}

test "cpu65: IRQ sequence (7 cycles, B clear, I set, D clear, vector $FFFE)" {
    const gpa = std.testing.allocator;
    const bus = try gpa.create(TestBus);
    defer gpa.destroy(bus);
    bus.* = .{};
    bus.ram[0xFFFE] = 0x34;
    bus.ram[0xFFFF] = 0x12;
    bus.ram[0x0400] = 0xEA;
    var cpu: Cpu = .{ .regs = .{ .pc = 0x0400, .s = 0xF0, .p = 0x20 | cpu65.Flag.d | cpu65.Flag.c }, .irq_ok = true };
    bus.irq = true;
    cpu.step(bus);
    try std.testing.expectEqual(@as(usize, 7), bus.n);
    try std.testing.expectEqual(@as(u16, 0x1234), cpu.regs.pc);
    try std.testing.expectEqual(@as(u8, 0xED), cpu.regs.s);
    try std.testing.expectEqual(@as(u8, 0x04), bus.ram[0x01F0]);
    try std.testing.expectEqual(@as(u8, 0x00), bus.ram[0x01EF]);
    // P pushed with B clear, bit 5 set; D was set and is cleared after.
    try std.testing.expectEqual(@as(u8, 0x20 | cpu65.Flag.d | cpu65.Flag.c), bus.ram[0x01EE]);
    try std.testing.expect(cpu.regs.p & cpu65.Flag.i != 0);
    try std.testing.expect(cpu.regs.p & cpu65.Flag.d == 0);
    try std.testing.expectEqual(@as(u32, 0), cpu.instr_count);
    // Masked: I set, the next step runs the NOP at $1234 instead.
    bus.ram[0x1234] = 0xEA;
    bus.n = 0;
    cpu.step(bus);
    try std.testing.expectEqual(@as(usize, 2), bus.n);
    try std.testing.expectEqual(@as(u16, 0x1235), cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 1), cpu.instr_count);
    // RTI returns to $0400 with the pushed P (I clear again).
    bus.ram[0x1235] = 0x40;
    bus.irq = false;
    cpu.step(bus);
    try std.testing.expectEqual(@as(u16, 0x0400), cpu.regs.pc);
    try std.testing.expect(cpu.regs.p & cpu65.Flag.i == 0);
    try std.testing.expectEqual(@as(u8, 0x30 | cpu65.Flag.d | cpu65.Flag.c), cpu.regs.p);
}

test "cpu65: interrupt poll (CLI/SEI/PLP one instruction late, RTI at once, 1-cycle NOPs never)" {
    const gpa = std.testing.allocator;
    const bus = try gpa.create(TestBus);
    defer gpa.destroy(bus);
    bus.* = .{};
    bus.ram[0xFFFE] = 0x00;
    bus.ram[0xFFFF] = 0x30;
    const I = cpu65.Flag.i;
    // CLI; INX with the line high: INX runs, then the IRQ.
    @memcpy(bus.ram[0x0400..][0..2], &[_]u8{ 0x58, 0xE8 });
    var cpu: Cpu = .{ .regs = .{ .pc = 0x0400, .p = 0x30 | I } };
    bus.irq = true;
    cpu.step(bus);
    try std.testing.expectEqual(@as(u16, 0x0401), cpu.regs.pc);
    cpu.step(bus);
    try std.testing.expectEqual(@as(u16, 0x0402), cpu.regs.pc);
    try std.testing.expectEqual(@as(u8, 1), cpu.regs.x);
    cpu.step(bus);
    try std.testing.expectEqual(@as(u16, 0x3000), cpu.regs.pc);
    // CLI; $03 $0B $F3 $FB; INX: the 1-cycle NOPs do not poll, INX does.
    @memcpy(bus.ram[0x0500..][0..6], &[_]u8{ 0x58, 0x03, 0x0B, 0xF3, 0xFB, 0xE8 });
    cpu = .{ .regs = .{ .pc = 0x0500, .p = 0x30 | I } };
    for (0..5) |_| {
        cpu.step(bus);
        try std.testing.expect(!cpu.takes_irq(true));
    }
    try std.testing.expectEqual(@as(u16, 0x0505), cpu.regs.pc);
    cpu.step(bus);
    try std.testing.expectEqual(@as(u16, 0x0506), cpu.regs.pc);
    cpu.step(bus);
    try std.testing.expectEqual(@as(u16, 0x3000), cpu.regs.pc);
    // SEI with the line high and I clear: the IRQ comes right after SEI,
    // with I set in the pushed P.
    bus.ram[0x0600] = 0x78;
    cpu = .{ .regs = .{ .pc = 0x0600, .s = 0xFF, .p = 0x30 }, .irq_ok = false };
    cpu.step(bus);
    try std.testing.expect(cpu.takes_irq(true));
    cpu.step(bus);
    try std.testing.expectEqual(@as(u16, 0x3000), cpu.regs.pc);
    try std.testing.expect(bus.ram[0x01FD] & I != 0);
    // RTI restoring I clear: polled at once.
    @memcpy(bus.ram[0x01FD..][0..3], &[_]u8{ 0x20, 0x00, 0x07 });
    bus.ram[0x3000] = 0x40;
    cpu = .{ .regs = .{ .pc = 0x3000, .s = 0xFC, .p = 0x30 | I } };
    cpu.step(bus);
    try std.testing.expectEqual(@as(u16, 0x0700), cpu.regs.pc);
    try std.testing.expect(cpu.takes_irq(true));
}

/// TestBus with the Lynx's $CB/$DB (`cpu_lynx_nops`).
const LynxNopBus = struct {
    pub const cpu_lynx_nops = true;
    t: TestBus = .{},
    pub fn fetch(b: *LynxNopBus, addr: u16) u8 {
        return b.t.fetch(addr);
    }
    pub fn read(b: *LynxNopBus, addr: u16) u8 {
        return b.t.read(addr);
    }
    pub fn dummy(b: *LynxNopBus, addr: u16) void {
        b.t.dummy(addr);
    }
    pub fn write(b: *LynxNopBus, addr: u16, v: u8) void {
        b.t.write(addr, v);
    }
    pub fn irq_line(b: *LynxNopBus) bool {
        return b.t.irq;
    }
};

test "cpu65: Lynx $CB/$DB are 1-byte 1-cycle NOPs that do not poll" {
    const gpa = std.testing.allocator;
    const bus = try gpa.create(LynxNopBus);
    defer gpa.destroy(bus);
    bus.* = .{};
    @memcpy(bus.t.ram[0x0400..][0..4], &[_]u8{ 0x58, 0xCB, 0xDB, 0xE8 });
    var cpu: cpu65.Cpu(LynxNopBus) = .{ .regs = .{ .pc = 0x0400, .p = 0x30 | cpu65.Flag.i } };
    bus.t.irq = true;
    cpu.step(bus);
    bus.t.n = 0;
    cpu.step(bus);
    try std.testing.expectEqual(@as(usize, 1), bus.t.n);
    try std.testing.expect(!cpu.takes_irq(true));
    cpu.step(bus);
    try std.testing.expectEqual(@as(usize, 2), bus.t.n);
    try std.testing.expectEqual(@as(u16, 0x0403), cpu.regs.pc);
    try std.testing.expect(!cpu.takes_irq(true));
    cpu.step(bus);
    try std.testing.expectEqual(@as(u8, 1), cpu.regs.x);
    try std.testing.expect(cpu.takes_irq(true));
}
