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
//! `M68K_SST_SHOW` (failures printed per file, default 3). Skips cleanly
//! when the directory is absent or empty.
const std = @import("std");
const core = @import("core");
const m68k = core.m68k;

const TestBus = struct {
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
};

const Cpu = m68k.M68k(TestBus);

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

fn load(cpu: *Cpu, bus: *TestBus, s: *const State) void {
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

fn clear(bus: *TestBus, cs: *const Case) void {
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
fn compare_state(cpu: *const Cpu, bus: *const TestBus, want: *const State, msg: *std.ArrayList(u8), gpa: std.mem.Allocator) !u32 {
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

fn run_file(gpa: std.mem.Allocator, bus: *TestBus, text: []const u8, name: []const u8, show: u32) !Result {
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
        var cpu: Cpu = .{};
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

test "m68k: SingleStepTests (tests/roms/68000/*.json.gz)" {
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
    if (!found) {
        std.debug.print("m68k: SingleStepTests skipped: no test files (tools/fetch_test_roms.sh)\n", .{});
        return;
    }
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
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    if (names.items.len == 0) {
        std.debug.print("m68k: SingleStepTests skipped: no test files (tools/fetch_test_roms.sh)\n", .{});
        return;
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);

    const mem = try gpa.alloc(u8, 1 << 24);
    defer gpa.free(mem);
    @memset(mem, 0);
    var bus: TestBus = .{ .mem = mem };

    const start = std.Io.Timestamp.now(io, .awake);
    var total: Result = .{};
    // Families (file name before the size suffix), in file order.
    var fams: std.ArrayList(struct { []const u8, Result }) = .empty;
    defer fams.deinit(gpa);
    std.debug.print("m68k: file                 cases   pass  addr-err  state  cycles disputed\n", .{});
    for (names.items) |n| {
        const gz = try dir.readFileAlloc(io, n, gpa, .limited(64 << 20));
        defer gpa.free(gz);
        const text = try gunzip(gpa, gz);
        defer gpa.free(text);
        const r = try run_file(gpa, &bus, text, n, show);
        print_row(n[0 .. n.len - 8], r);
        total.add(r);
        const f = family(n);
        if (fams.items.len == 0 or !std.mem.eql(u8, fams.items[fams.items.len - 1][0], f)) {
            try fams.append(gpa, .{ f, .{} });
        }
        fams.items[fams.items.len - 1][1].add(r);
    }
    std.debug.print("m68k: family               cases   pass  addr-err  state  cycles disputed\n", .{});
    for (fams.items) |f| print_row(f[0], f[1]);
    const ms = start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
    std.debug.print("m68k: SingleStepTests {d} files, {d} cases: {d} pass, {d} address-error (skipped), {d} disputed, {d} state fail, {d} cycle-only fail; {d} ms\n", .{ names.items.len, total.total, total.pass, total.addr, total.disputed, total.state, total.cycles, ms });
    try std.testing.expectEqual(@as(u32, 0), total.state);
    try std.testing.expectEqual(@as(u32, 0), total.cycles);
}
