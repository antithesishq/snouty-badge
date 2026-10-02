//! SingleStepTests 68000 (github.com/SingleStepTests/680x0, 68000/v1; no
//! licence, fetched by tools/fetch_test_roms.sh, never committed): every
//! `tests/roms/68000/*.json.gz` holds ~8,065 single-instruction cases with
//! the initial and final registers and RAM and the cycle count (docs/ROMS.md
//! section 3). Each case seeds a flat 16 MB bus, puts the two prefetch words
//! at `pc` and `pc + 2` (the JSON leaves them out of `ram`; the core has no
//! prefetch queue and fetches them from memory), runs one `step`, and checks
//! D0-D7, A0-A6, USP, SSP, SR, PC, every final RAM byte and the cycles
//! (`length`). The bus trace (`transactions`) is not checked (SPEC.md
//! section 4).
//!
//! Classes, counted separately per file:
//! - pass: state and cycles agree;
//! - addr: the case makes a word access at an odd address or ends with an
//!   odd PC, so the real 68000 took an address error (not emulated,
//!   SPEC.md section 4): skipped, whatever the core did;
//! - state: a register, SR or RAM byte differs (a real failure);
//! - cycles: the state agrees, the cycle count does not.
//!
//! Environment: `M68K_SST_DIR` (default tests/roms/68000 from the repo root
//! or the cart), `M68K_SST_FILTER` (substring of the file name),
//! `M68K_SST_SHOW` (failures printed per file, default 3). Skipped
//! (`error.SkipZigTest`, counted as a skip, not a pass) when the directory
//! is absent or empty; with `SNOUTY_FIXTURES=required` (set by
//! `zig build test-m68k-strict`) that is `error.FixtureMissing`, a failure.
const std = @import("std");
const core = @import("core");
const m68k = core.m68k;

/// Flat 16 MB bus; `window` adds `code_window` over the whole map, the
/// fetch path the cart uses (ROM and work RAM are windows there).
fn TestBusT(comptime window: bool) type {
    return struct {
        const TestBus = @This();
        mem: []u8,
        /// Addresses written (to clear between cases).
        dirty: [512]u32 = undefined,
        n_dirty: usize = 0,
        overflow: bool = false,
        /// A word access at an odd address happened.
        odd: bool = false,

        pub fn read8(self: *TestBus, addr: u24) u8 {
            return self.mem[addr];
        }
        pub fn read16(self: *TestBus, addr: u24) u16 {
            if (addr & 1 != 0) self.odd = true;
            return @as(u16, self.mem[addr]) << 8 | self.mem[addr +% 1];
        }
        pub fn write8(self: *TestBus, addr: u24, v: u8) void {
            self.mark(addr);
            self.mem[addr] = v;
        }
        pub fn write16(self: *TestBus, addr: u24, v: u16) void {
            if (addr & 1 != 0) self.odd = true;
            self.mark(addr);
            self.mark(addr +% 1);
            self.mem[addr] = @truncate(v >> 8);
            self.mem[addr +% 1] = @truncate(v);
        }
        pub fn irq_level(self: *TestBus) u3 {
            _ = self;
            return 0;
        }
        pub fn ack_irq(self: *TestBus, level: u3) void {
            _ = self;
            _ = level;
        }
        fn mark(self: *TestBus, addr: u24) void {
            if (self.n_dirty < self.dirty.len) {
                self.dirty[self.n_dirty] = addr;
                self.n_dirty += 1;
            } else self.overflow = true;
        }
        /// A function only with `window` (the CPU checks for a function).
        pub const code_window = if (window) window_all else {};
        fn window_all(self: *TestBus, addr: u24) ?m68k.CodeWindow {
            _ = addr;
            return .{ .ptr = self.mem.ptr, .base = 0, .len = 1 << 24 };
        }
    };
}

const State = struct {
    d0: u32,
    d1: u32,
    d2: u32,
    d3: u32,
    d4: u32,
    d5: u32,
    d6: u32,
    d7: u32,
    a0: u32,
    a1: u32,
    a2: u32,
    a3: u32,
    a4: u32,
    a5: u32,
    a6: u32,
    usp: u32,
    ssp: u32,
    sr: u16,
    pc: u32,
    prefetch: [2]u16,
    ram: []const [2]u32,
};

const Case = struct {
    name: []const u8,
    initial: State,
    final: State,
    length: u32,
};

fn load(cpu: anytype, bus: anytype, s: *const State) void {
    cpu.* = .{};
    cpu.d = .{ s.d0, s.d1, s.d2, s.d3, s.d4, s.d5, s.d6, s.d7 };
    cpu.a = .{ s.a0, s.a1, s.a2, s.a3, s.a4, s.a5, s.a6, 0 };
    // set_sr from user mode with the SSP parked in other_sp.
    cpu.sr = 0;
    cpu.a[7] = s.usp;
    cpu.other_sp = s.ssp;
    cpu.set_sr(s.sr);
    cpu.pc = s.pc;
    for (s.ram) |cell| bus.mem[cell[0] & 0xFFFFFF] = @intCast(cell[1]);
    // The prefetch queue holds the opcode and the next word; memory there
    // may be absent from `ram`.
    const pc: u24 = @truncate(s.pc);
    bus.mem[pc] = @truncate(s.prefetch[0] >> 8);
    bus.mem[pc +% 1] = @truncate(s.prefetch[0]);
    bus.mem[pc +% 2] = @truncate(s.prefetch[1] >> 8);
    bus.mem[pc +% 3] = @truncate(s.prefetch[1]);
}

fn clear(bus: anytype, cs: *const Case) void {
    for (cs.initial.ram) |cell| bus.mem[cell[0] & 0xFFFFFF] = 0;
    for (cs.final.ram) |cell| bus.mem[cell[0] & 0xFFFFFF] = 0;
    const pc: u24 = @truncate(cs.initial.pc);
    for (0..4) |i| bus.mem[pc +% @as(u24, @intCast(i))] = 0;
    for (bus.dirty[0..bus.n_dirty]) |a| bus.mem[a] = 0;
    if (bus.overflow) @memset(bus.mem, 0);
    bus.n_dirty = 0;
    bus.overflow = false;
    bus.odd = false;
}

/// Appends each state mismatch to `msg`; returns their count.
fn compare_state(cpu: anytype, bus: anytype, want: *const State, msg: *std.ArrayList(u8), gpa: std.mem.Allocator) !u32 {
    var bad: u32 = 0;
    const Pair = struct { []const u8, u32, u32 };
    const checks = [_]Pair{
        .{ "d0", cpu.d[0], want.d0 },    .{ "d1", cpu.d[1], want.d1 },
        .{ "d2", cpu.d[2], want.d2 },    .{ "d3", cpu.d[3], want.d3 },
        .{ "d4", cpu.d[4], want.d4 },    .{ "d5", cpu.d[5], want.d5 },
        .{ "d6", cpu.d[6], want.d6 },    .{ "d7", cpu.d[7], want.d7 },
        .{ "a0", cpu.a[0], want.a0 },    .{ "a1", cpu.a[1], want.a1 },
        .{ "a2", cpu.a[2], want.a2 },    .{ "a3", cpu.a[3], want.a3 },
        .{ "a4", cpu.a[4], want.a4 },    .{ "a5", cpu.a[5], want.a5 },
        .{ "a6", cpu.a[6], want.a6 },    .{ "usp", cpu.usp(), want.usp },
        .{ "ssp", cpu.ssp(), want.ssp }, .{ "sr", cpu.get_sr(), want.sr },
        .{ "pc", cpu.pc, want.pc },
    };
    for (checks) |c| {
        if (c[1] != c[2]) {
            bad += 1;
            try msg.print(gpa, " {s}={X} want {X};", .{ c[0], c[1], c[2] });
        }
    }
    for (want.ram) |cell| {
        const got = bus.mem[cell[0] & 0xFFFFFF];
        if (got != cell[1]) {
            bad += 1;
            try msg.print(gpa, " mem[{X:0>6}]={X:0>2} want {X:0>2};", .{ cell[0], got, cell[1] });
        }
    }
    return bad;
}

const Result = struct {
    total: u32 = 0,
    pass: u32 = 0,
    addr: u32 = 0,
    state: u32 = 0,
    cycles: u32 = 0,
    disputed: u32 = 0,

    fn add(r: *Result, o: Result) void {
        r.total += o.total;
        r.pass += o.pass;
        r.addr += o.addr;
        r.state += o.state;
        r.cycles += o.cycles;
        r.disputed += o.disputed;
    }
};

/// Cases whose expected result we believe is wrong, with the reason;
/// counted as `disputed`, not failed. Checked on 2026-09-29 against the
/// full 124-file set.
const disputed_cases = [_]struct { file: []const u8, case: []const u8 }{
    // ASL.b #2,D2 whose final D2 differs from the initial one in bits 8-31
    // (a byte shift cannot touch them): corrupt cases.
    .{ .file = "ASL.b.json.gz", .case = "e502 [ASL.b Q, D2] 1583" },
    .{ .file = "ASL.b.json.gz", .case = "e502 [ASL.b Q, D2] 1761" },
    // The only division by zero in DIVU.json: it stacks the instruction's
    // own address (000C00) as the return PC, where the 68000 manual and
    // every other emulator stack the next instruction's (000C04).
    .{ .file = "DIVU.json.gz", .case = "80ef [DIVU (d16, A7), D0] 5745" },
};

fn disputed(file: []const u8, case: []const u8) bool {
    for (disputed_cases) |d| {
        if (std.mem.eql(u8, d.file, file) and std.mem.eql(u8, d.case, case)) return true;
    }
    return false;
}

fn vector3(s: *const State) u32 {
    var v: u32 = 0;
    for (s.ram) |cell| {
        if (cell[0] >= 12 and cell[0] < 16) v |= cell[1] << @intCast(8 * (15 - cell[0]));
    }
    return v;
}

fn run_file(gpa: std.mem.Allocator, bus: anytype, text: []const u8, name: []const u8, show: u32) !Result {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scanner = std.json.Scanner.initCompleteInput(gpa, text);
    defer scanner.deinit();
    if (try scanner.next() != .array_begin) return error.NotAnArray;
    const opts: std.json.ParseOptions = .{
        .ignore_unknown_fields = true,
        .max_value_len = text.len,
        .allocate = .alloc_if_needed,
    };
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    var res: Result = .{};
    var shown: u32 = 0;
    while (try scanner.peekNextTokenType() != .array_end) {
        _ = arena_state.reset(.retain_capacity);
        const cs = try std.json.innerParse(Case, arena, &scanner, opts);
        res.total += 1;
        var cpu: m68k.M68k(@TypeOf(bus.*)) = .{};
        load(&cpu, bus, &cs.initial);
        const t = cpu.step(bus);
        msg.clearRetainingCapacity();
        const bad = try compare_state(&cpu, bus, &cs.final, &msg, gpa);
        if (bus.odd or cpu.pc & 1 != 0) {
            // The real chip must have taken an address error: it ends at
            // the vector 3 handler (its long at 00000C in the initial RAM).
            if (cs.final.pc != vector3(&cs.initial)) {
                res.state += 1;
                if (shown < show) {
                    shown += 1;
                    std.debug.print("  {s} \"{s}\": odd access but no address-error frame\n", .{ name, cs.name });
                }
            } else res.addr += 1;
        } else if (disputed(name, cs.name)) {
            res.disputed += 1;
        } else if (bad != 0) {
            res.state += 1;
            if (shown < show) {
                shown += 1;
                std.debug.print("  {s} \"{s}\": cycles {d}/{d};{s}\n", .{ name, cs.name, t, cs.length, msg.items });
            }
        } else if (t != cs.length) {
            res.cycles += 1;
            if (shown < show) {
                shown += 1;
                std.debug.print("  {s} \"{s}\": cycles {d} want {d}\n", .{ name, cs.name, t, cs.length });
            }
        } else res.pass += 1;
        clear(bus, &cs);
    }
    return res;
}

fn gunzip(gpa: std.mem.Allocator, gz: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(gz);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var dec: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
    _ = try dec.reader.streamRemaining(&aw.writer);
    return aw.toOwnedSlice();
}

const default_dirs = [_][]const u8{ "carts/snouty-genesis/tests/roms/68000", "tests/roms/68000" };

fn print_row(label: []const u8, r: Result) void {
    std.debug.print("m68k: {s:<20} {d:>6} {d:>6} {d:>9} {d:>6} {d:>7} {d:>8}\n", .{ label, r.total, r.pass, r.addr, r.state, r.cycles, r.disputed });
}

fn family(name: []const u8) []const u8 {
    const base = name[0 .. std.mem.indexOf(u8, name, ".json") orelse name.len];
    return base[0 .. std.mem.indexOfScalar(u8, base, '.') orelse base.len];
}

test "m68k: decode table and two-level decode agree on every opcode" {
    var op: u32 = 0;
    while (op < 0x10000) : (op += 1) {
        const o: u16 = @intCast(op);
        try std.testing.expectEqual(m68k.decode_table(o), m68k.decode_two_level(o));
    }
}

test "m68k: SingleStepTests (tests/roms/68000/*.json.gz), fetch window" {
    _ = try suite(true, null);
}

/// The files whose instructions fetch the most (branches, jumps, returns,
/// exceptions, long immediates), run again with the fetch going through
/// `read16` (a bus without `code_window`).
pub const bus_fetch_files = [_][]const u8{
    "Bcc.json.gz",     "BSR.json.gz",  "DBcc.json.gz",  "JMP.json.gz",
    "JSR.json.gz",     "RTS.json.gz",  "RTE.json.gz",   "RTR.json.gz",
    "TRAP.json.gz",    "CHK.json.gz",  "DIVU.json.gz",  "MOVE.l.json.gz",
    "MOVEM.w.json.gz", "LINK.json.gz", "ADD.l.json.gz",
};

test "m68k: SingleStepTests, bus fetch (subset)" {
    _ = try suite(false, &bus_fetch_files);
}

/// True when `SNOUTY_FIXTURES=required` (the strict oracle step): absent
/// fixtures fail instead of skipping.
pub fn fixtures_required() bool {
    const v = std.testing.environ.getPosix("SNOUTY_FIXTURES") orelse return false;
    return std.mem.eql(u8, v, "required");
}

fn no_fixtures() error{ FixtureMissing, SkipZigTest } {
    if (fixtures_required()) {
        std.debug.print("m68k: SingleStepTests FIXTURE MISSING: no test files in tests/roms/68000 (tools/fetch_test_roms.sh)\n", .{});
        return error.FixtureMissing;
    }
    std.debug.print("m68k: SingleStepTests skipped: no test files (tools/fetch_test_roms.sh)\n", .{});
    return error.SkipZigTest;
}

/// Runs the SingleStepTests files (all, or those in `only`) and returns the
/// number of cases executed; skips (or, strict, fails) without fixtures.
pub fn suite(comptime window: bool, only: ?[]const []const u8) !u32 {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const env = std.testing.environ;
    const filter = env.getPosix("M68K_SST_FILTER");
    const show: u32 = if (env.getPosix("M68K_SST_SHOW")) |s| try std.fmt.parseInt(u32, s, 10) else 3;
    var dir: std.Io.Dir = undefined;
    var found = false;
    if (env.getPosix("M68K_SST_DIR")) |p| {
        dir = try std.Io.Dir.cwd().openDir(io, p, .{ .iterate = true });
        found = true;
    } else for (default_dirs) |p| {
        dir = std.Io.Dir.cwd().openDir(io, p, .{ .iterate = true }) catch continue;
        found = true;
        break;
    }
    if (!found) return no_fixtures();
    defer dir.close(io);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json.gz")) continue;
        if (filter) |f| if (std.mem.indexOf(u8, entry.name, f) == null) continue;
        if (only) |list| {
            for (list) |o| {
                if (std.mem.eql(u8, o, entry.name)) break;
            } else continue;
        }
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    if (names.items.len == 0) return no_fixtures();
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);

    const mem = try gpa.alloc(u8, 1 << 24);
    defer gpa.free(mem);
    @memset(mem, 0);
    var bus: TestBusT(window) = .{ .mem = mem };
    const table = only == null;

    const start = std.Io.Timestamp.now(io, .awake);
    var total: Result = .{};
    // Families (file name before the size suffix), in file order.
    var fams: std.ArrayList(struct { []const u8, Result }) = .empty;
    defer fams.deinit(gpa);
    if (table) std.debug.print("m68k: file                 cases   pass  addr-err  state  cycles disputed\n", .{});
    for (names.items) |n| {
        const gz = try dir.readFileAlloc(io, n, gpa, .limited(64 << 20));
        defer gpa.free(gz);
        const text = try gunzip(gpa, gz);
        defer gpa.free(text);
        const r = try run_file(gpa, &bus, text, n, show);
        if (table) print_row(n[0 .. n.len - 8], r);
        total.add(r);
        const f = family(n);
        if (fams.items.len == 0 or !std.mem.eql(u8, fams.items[fams.items.len - 1][0], f)) {
            try fams.append(gpa, .{ f, .{} });
        }
        fams.items[fams.items.len - 1][1].add(r);
    }
    if (table) {
        std.debug.print("m68k: family               cases   pass  addr-err  state  cycles disputed\n", .{});
        for (fams.items) |f| print_row(f[0], f[1]);
    }
    const ms = start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
    std.debug.print("m68k: SingleStepTests ({s}) {d} files, {d} cases: {d} pass, {d} address-error (skipped), {d} disputed, {d} state fail, {d} cycle-only fail; {d} ms\n", .{ if (window) "fetch window" else "bus fetch", names.items.len, total.total, total.pass, total.addr, total.disputed, total.state, total.cycles, ms });
    try std.testing.expectEqual(@as(u32, 0), total.state);
    try std.testing.expectEqual(@as(u32, 0), total.cycles);
    return total.total;
}

// ---- Unit tests: what SingleStepTests does not cover (interrupts, STOP,
// user mode, reset) ----

/// 64 KB of RAM mirrored over the map, and an interrupt line.
const IrqBus = struct {
    mem: [0x10000]u8 = @splat(0),
    level: u3 = 0,
    acked: ?u3 = null,

    pub fn read8(self: *IrqBus, addr: u24) u8 {
        return self.mem[@as(u16, @truncate(addr))];
    }
    pub fn read16(self: *IrqBus, addr: u24) u16 {
        const a: u16 = @truncate(addr);
        return @as(u16, self.mem[a]) << 8 | self.mem[a +% 1];
    }
    pub fn write8(self: *IrqBus, addr: u24, v: u8) void {
        self.mem[@as(u16, @truncate(addr))] = v;
    }
    pub fn write16(self: *IrqBus, addr: u24, v: u16) void {
        const a: u16 = @truncate(addr);
        self.mem[a] = @truncate(v >> 8);
        self.mem[a +% 1] = @truncate(v);
    }
    pub fn irq_level(self: *IrqBus) u3 {
        return self.level;
    }
    pub fn ack_irq(self: *IrqBus, level: u3) void {
        self.acked = level;
        self.level = 0;
    }
    fn put16(self: *IrqBus, addr: u16, v: u16) void {
        self.write16(addr, v);
    }
    fn put32(self: *IrqBus, addr: u16, v: u32) void {
        self.write16(addr, @truncate(v >> 16));
        self.write16(addr + 2, @truncate(v));
    }
    fn get32(self: *IrqBus, addr: u16) u32 {
        return @as(u32, self.read16(addr)) << 16 | self.read16(addr + 2);
    }
};

const IrqCpu = m68k.M68k(IrqBus);

/// Reset vectors SSP 8000, PC 1000; every other vector points at 0x2000 +
/// 4 * n, where a NOP waits.
fn irq_setup(bus: *IrqBus, cpu: *IrqCpu) void {
    bus.put32(0, 0x8000);
    bus.put32(4, 0x1000);
    var v: u16 = 2;
    while (v < 64) : (v += 1) {
        bus.put32(v * 4, 0x2000 + @as(u32, v) * 4);
        bus.put16(0x2000 + v * 4, 0x4E71);
    }
    cpu.reset(bus);
}

test "m68k: reset loads SSP and PC, supervisor, mask 7" {
    var bus: IrqBus = .{};
    var cpu: IrqCpu = .{};
    irq_setup(&bus, &cpu);
    try std.testing.expectEqual(@as(u32, 0x8000), cpu.a[7]);
    try std.testing.expectEqual(@as(u32, 0x1000), cpu.pc);
    try std.testing.expectEqual(@as(u16, 0x2700), cpu.get_sr());
}

test "m68k: interrupt above the mask takes the autovector, 44 cycles" {
    var bus: IrqBus = .{};
    var cpu: IrqCpu = .{};
    irq_setup(&bus, &cpu);
    bus.put16(0x1000, 0x4E71); // NOP
    bus.put16(0x1002, 0x4E71);
    cpu.set_sr(0x2504); // mask 5, Z
    bus.level = 5; // not above the mask
    try std.testing.expectEqual(@as(u32, 4), cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0x1002), cpu.pc);
    bus.level = 6;
    try std.testing.expectEqual(@as(u32, 44), cpu.step(&bus));
    try std.testing.expectEqual(@as(?u3, 6), bus.acked);
    try std.testing.expectEqual(@as(u32, 0x2000 + 30 * 4), cpu.pc);
    try std.testing.expectEqual(@as(u16, 0x2604), cpu.get_sr()); // CCR kept
    try std.testing.expectEqual(@as(u32, 0x8000 - 6), cpu.a[7]);
    try std.testing.expectEqual(@as(u32, 0x2504), bus.read16(0x8000 - 6));
    try std.testing.expectEqual(@as(u32, 0x1002), bus.get32(0x8000 - 4));
}

test "m68k: STOP idles until an interrupt, which stacks the next PC" {
    var bus: IrqBus = .{};
    var cpu: IrqCpu = .{};
    irq_setup(&bus, &cpu);
    bus.put16(0x1000, 0x4E72); // STOP #2300
    bus.put16(0x1002, 0x2300);
    _ = cpu.step(&bus);
    try std.testing.expect(cpu.stopped);
    try std.testing.expectEqual(@as(u32, 0x1004), cpu.pc);
    try std.testing.expectEqual(@as(u32, 4), cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0x1004), cpu.pc);
    bus.level = 3; // masked by 3
    try std.testing.expectEqual(@as(u32, 4), cpu.step(&bus));
    bus.level = 4;
    try std.testing.expectEqual(@as(u32, 44), cpu.step(&bus));
    try std.testing.expect(!cpu.stopped);
    try std.testing.expectEqual(@as(u32, 0x1004), bus.get32(0x8000 - 4));
    try std.testing.expectEqual(@as(u16, 0x2400), cpu.get_sr());
}

test "m68k: user mode: privilege violation, TRAP, RTE back to user, USP" {
    var bus: IrqBus = .{};
    var cpu: IrqCpu = .{};
    irq_setup(&bus, &cpu);
    // MOVE #$1234,USP is privileged-only via MOVE An,USP: set USP = 0x6000.
    cpu.a[0] = 0x6000;
    bus.put16(0x1000, 0x4E60); // MOVE A0,USP
    bus.put16(0x1002, 0x46FC); // MOVE #$0000,SR (to user mode)
    bus.put16(0x1004, 0x0000);
    bus.put16(0x1006, 0x46FC); // MOVE #$2700,SR in user mode: privilege violation
    bus.put16(0x1008, 0x2700);
    _ = cpu.step(&bus);
    _ = cpu.step(&bus);
    try std.testing.expect(!cpu.supervisor());
    try std.testing.expectEqual(@as(u32, 0x6000), cpu.a[7]);
    try std.testing.expectEqual(@as(u32, 0x8000), cpu.ssp());
    try std.testing.expectEqual(@as(u32, 34), cpu.step(&bus));
    try std.testing.expect(cpu.supervisor());
    try std.testing.expectEqual(@as(u32, 0x2000 + 8 * 4), cpu.pc);
    try std.testing.expectEqual(@as(u32, 0x8000 - 6), cpu.a[7]);
    try std.testing.expectEqual(@as(u32, 0x6000), cpu.usp());
    try std.testing.expectEqual(@as(u32, 0x1006), bus.get32(0x8000 - 4)); // the opcode's own address
    // RTE from the handler returns to user mode at the stacked PC.
    bus.put16(0x2000 + 8 * 4, 0x4E73);
    try std.testing.expectEqual(@as(u32, 20), cpu.step(&bus));
    try std.testing.expect(!cpu.supervisor());
    try std.testing.expectEqual(@as(u32, 0x1006), cpu.pc);
    try std.testing.expectEqual(@as(u32, 0x6000), cpu.a[7]);
    try std.testing.expectEqual(@as(u32, 0x8000), cpu.ssp());
    // TRAP #5 from user mode: vector 37, stacks the next PC.
    bus.put16(0x1006, 0x4E45);
    try std.testing.expectEqual(@as(u32, 34), cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0x2000 + 37 * 4), cpu.pc);
    try std.testing.expectEqual(@as(u32, 0x1008), bus.get32(0x8000 - 4));
    try std.testing.expectEqual(@as(u16, 0x0000), bus.read16(0x8000 - 6));
}

test "m68k: line A and line F stack the opcode's address" {
    var bus: IrqBus = .{};
    var cpu: IrqCpu = .{};
    irq_setup(&bus, &cpu);
    bus.put16(0x1000, 0xA123);
    try std.testing.expectEqual(@as(u32, 34), cpu.step(&bus));
    try std.testing.expectEqual(@as(u32, 0x2000 + 10 * 4), cpu.pc);
    try std.testing.expectEqual(@as(u32, 0x1000), bus.get32(0x8000 - 4));
    bus.put16(0x2000 + 10 * 4, 0xF000);
    _ = cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 0x2000 + 11 * 4), cpu.pc);
    try std.testing.expectEqual(@as(u32, 0x2028), bus.get32(0x8000 - 10));
}
