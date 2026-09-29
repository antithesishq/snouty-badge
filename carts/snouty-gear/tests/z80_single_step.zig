//! SingleStepTests Z80 (github.com/SingleStepTests/z80, MIT): every JSON file
//! under `tests/roms/z80/v1/` holds 1000 single-instruction cases with the
//! initial and final register/RAM state, the port traffic and the bus
//! cycles. Each case runs one `step` on a flat 64 KB bus and checks every
//! register (incl. WZ, Q, IFF1/2, IM, R and the EI latch; not `p`, the
//! LD A,I/R marker, which only matters when an interrupt follows), RAM, port
//! reads and writes (low address byte and value; the bus interface only
//! passes the low byte), and the T-state count (`cycles.len`).
//!
//! The directory is optional: `tools/fetch_test_roms.sh --single-step`
//! leaves a representative subset on disk (36 files); the full suite
//! (1604 files, 1.2 GB) is streamed through in batches by
//! `tools/fetch_test_roms.sh --single-step-all`, which points this test at
//! each batch with `GEAR_SST_DIR` and collects the per-file lines it prints
//! (PASS lines only with `GEAR_SST_VERBOSE=1`; failures and the summary
//! always print).
const std = @import("std");
const core = @import("core");

const Port = struct { addr: u16, val: u8, write: bool };

const TestBus = struct {
    mem: [0x10000]u8 = @splat(0),
    ports: [8]Port = undefined,
    n_ports: usize = 0,
    next_read: usize = 0,
    writes: [8]Port = undefined,
    n_writes: usize = 0,
    bad_port: bool = false,

    pub fn read(self: *TestBus, addr: u16) u8 {
        return self.mem[addr];
    }
    pub fn write(self: *TestBus, addr: u16, v: u8) void {
        self.mem[addr] = v;
    }
    pub fn in(self: *TestBus, port: u8) u8 {
        // Serve the next "r" entry of the case's port list.
        while (self.next_read < self.n_ports) {
            const p = self.ports[self.next_read];
            self.next_read += 1;
            if (!p.write) {
                if (@as(u8, @truncate(p.addr)) != port) self.bad_port = true;
                return p.val;
            }
        }
        self.bad_port = true;
        return 0xFF;
    }
    pub fn out(self: *TestBus, port: u8, v: u8) void {
        if (self.n_writes < self.writes.len) {
            self.writes[self.n_writes] = .{ .addr = port, .val = v, .write = true };
            self.n_writes += 1;
        } else self.bad_port = true;
    }
    pub fn irq_line(self: *TestBus) bool {
        _ = self;
        return false;
    }
};

const Cpu = core.z80.Z80(TestBus);

const State = struct {
    pc: u16,
    sp: u16,
    a: u8,
    b: u8,
    c: u8,
    d: u8,
    e: u8,
    f: u8,
    h: u8,
    l: u8,
    i: u8,
    r: u8,
    ei: u8 = 0,
    wz: u16,
    ix: u16,
    iy: u16,
    af_: u16,
    bc_: u16,
    de_: u16,
    hl_: u16,
    im: u8,
    p: u8 = 0,
    q: u8 = 0,
    iff1: u8,
    iff2: u8,
    ram: []const [2]u32,
};

const Case = struct {
    name: []const u8,
    initial: State,
    final: State,
    cycles: []const std.json.Value,
    ports: ?[]const std.json.Value = null,
};

fn load(cpu: *Cpu, bus: *TestBus, s: *const State) void {
    cpu.* = .{
        .a = s.a,
        .f = s.f,
        .b = s.b,
        .c = s.c,
        .d = s.d,
        .e = s.e,
        .h = s.h,
        .l = s.l,
        .a_ = @truncate(s.af_ >> 8),
        .f_ = @truncate(s.af_),
        .b_ = @truncate(s.bc_ >> 8),
        .c_ = @truncate(s.bc_),
        .d_ = @truncate(s.de_ >> 8),
        .e_ = @truncate(s.de_),
        .h_ = @truncate(s.hl_ >> 8),
        .l_ = @truncate(s.hl_),
        .ix = s.ix,
        .iy = s.iy,
        .sp = s.sp,
        .pc = s.pc,
        .i = s.i,
        .r = s.r,
        .wz = s.wz,
        .iff1 = s.iff1 != 0,
        .iff2 = s.iff2 != 0,
        .im = @intCast(s.im & 3),
        .ei_delay = s.ei != 0,
        .q = s.q,
    };
    for (s.ram) |cell| bus.mem[@intCast(cell[0])] = @intCast(cell[1]);
}

/// Appends "name got/want" for each mismatch to `msg`; returns the count.
fn compare(cpu: *const Cpu, bus: *const TestBus, want: *const State, t: u32, want_t: usize, msg: *std.ArrayList(u8), gpa: std.mem.Allocator) !u32 {
    var bad: u32 = 0;
    const Pair = struct { []const u8, u32, u32 };
    const checks = [_]Pair{
        .{ "a", cpu.a, want.a },
        .{ "f", cpu.f, want.f },
        .{ "b", cpu.b, want.b },
        .{ "c", cpu.c, want.c },
        .{ "d", cpu.d, want.d },
        .{ "e", cpu.e, want.e },
        .{ "h", cpu.h, want.h },
        .{ "l", cpu.l, want.l },
        .{ "i", cpu.i, want.i },
        .{ "r", cpu.r, want.r },
        .{ "af_", (@as(u32, cpu.a_) << 8) | cpu.f_, want.af_ },
        .{ "bc_", (@as(u32, cpu.b_) << 8) | cpu.c_, want.bc_ },
        .{ "de_", (@as(u32, cpu.d_) << 8) | cpu.e_, want.de_ },
        .{ "hl_", (@as(u32, cpu.h_) << 8) | cpu.l_, want.hl_ },
        .{ "ix", cpu.ix, want.ix },
        .{ "iy", cpu.iy, want.iy },
        .{ "pc", cpu.pc, want.pc },
        .{ "sp", cpu.sp, want.sp },
        .{ "wz", cpu.wz, want.wz },
        .{ "iff1", @intFromBool(cpu.iff1), want.iff1 },
        .{ "iff2", @intFromBool(cpu.iff2), want.iff2 },
        .{ "im", cpu.im, want.im },
        .{ "ei", @intFromBool(cpu.ei_delay), want.ei },
        .{ "q", cpu.q, want.q },
        .{ "cycles", t, @intCast(want_t) },
    };
    for (checks) |c| {
        if (c[1] != c[2]) {
            bad += 1;
            try msg.print(gpa, " {s}={X} want {X};", .{ c[0], c[1], c[2] });
        }
    }
    for (want.ram) |cell| {
        const got = bus.mem[@intCast(cell[0])];
        if (got != cell[1]) {
            bad += 1;
            try msg.print(gpa, " mem[{X:0>4}]={X:0>2} want {X:0>2};", .{ cell[0], got, cell[1] });
        }
    }
    return bad;
}

fn port_of(v: std.json.Value) ?Port {
    if (v != .array or v.array.items.len != 3) return null;
    const it = v.array.items;
    if (it[0] != .integer or it[1] != .integer or it[2] != .string) return null;
    return .{
        .addr = @intCast(it[0].integer),
        .val = @intCast(it[1].integer),
        .write = std.mem.eql(u8, it[2].string, "w"),
    };
}

const FileResult = struct { total: u32, failed: u32 };

fn run_file(gpa: std.mem.Allocator, text: []const u8, name: []const u8, quiet: bool) !FileResult {
    const parsed = try std.json.parseFromSlice([]const Case, gpa, text, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const bus = try gpa.create(TestBus);
    defer gpa.destroy(bus);
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    var failed: u32 = 0;
    var shown: u32 = 0;
    for (parsed.value) |*cs| {
        bus.* = .{};
        var cpu: Cpu = .{};
        load(&cpu, bus, &cs.initial);
        if (cs.ports) |ports| {
            for (ports) |pv| {
                const p = port_of(pv) orelse continue;
                if (bus.n_ports < bus.ports.len) {
                    bus.ports[bus.n_ports] = p;
                    bus.n_ports += 1;
                }
            }
        }
        const t = cpu.step(bus);
        msg.clearRetainingCapacity();
        var bad = try compare(&cpu, bus, &cs.final, t, cs.cycles.len, &msg, gpa);
        // Port writes, in order (low address byte and value).
        var wi: usize = 0;
        for (bus.ports[0..bus.n_ports]) |p| {
            if (!p.write) continue;
            if (wi >= bus.n_writes or bus.writes[wi].val != p.val or bus.writes[wi].addr != (p.addr & 0xFF)) {
                bad += 1;
                try msg.print(gpa, " port write {d} want {X:0>4}={X:0>2};", .{ wi, p.addr, p.val });
            }
            wi += 1;
        }
        if (wi != bus.n_writes) {
            bad += 1;
            try msg.print(gpa, " {d} port writes, want {d};", .{ bus.n_writes, wi });
        }
        if (bus.bad_port) {
            bad += 1;
            try msg.appendSlice(gpa, " port read mismatch;");
        }
        if (bad != 0) {
            failed += 1;
            if (shown < 3) {
                shown += 1;
                std.debug.print("  {s} \"{s}\":{s}\n", .{ name, cs.name, msg.items });
            }
        }
    }
    const total: u32 = @intCast(parsed.value.len);
    if (failed != 0) {
        std.debug.print("FAIL {s} {d}/{d}\n", .{ name, failed, total });
    } else if (!quiet) {
        std.debug.print("PASS {s} {d}\n", .{ name, total });
    }
    return .{ .total = total, .failed = failed };
}

const default_dirs = [_][]const u8{ "carts/snouty-gear/tests/roms/z80/v1", "tests/roms/z80/v1" };

test "z80: SingleStepTests (tests/roms/z80/v1/*.json)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const env_dir = std.testing.environ.getPosix("GEAR_SST_DIR");
    const quiet = std.testing.environ.getPosix("GEAR_SST_VERBOSE") == null;
    var dir: std.Io.Dir = undefined;
    var found = false;
    if (env_dir) |p| {
        dir = try std.Io.Dir.cwd().openDir(io, p, .{ .iterate = true });
        found = true;
    } else for (default_dirs) |p| {
        dir = std.Io.Dir.cwd().openDir(io, p, .{ .iterate = true }) catch continue;
        found = true;
        break;
    }
    if (!found) {
        std.debug.print("z80: SingleStepTests skipped: tests/roms/z80/v1 absent (tools/fetch_test_roms.sh --single-step)\n", .{});
        return;
    }
    defer dir.close(io);

    // Sorted file list so the output order is stable.
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);

    const start = std.Io.Timestamp.now(io, .awake);
    var files_failed: u32 = 0;
    var cases: u64 = 0;
    var cases_failed: u64 = 0;
    for (names.items) |n| {
        const text = try dir.readFileAlloc(io, n, gpa, .limited(16 << 20));
        defer gpa.free(text);
        const res = try run_file(gpa, text, n, quiet);
        cases += res.total;
        cases_failed += res.failed;
        if (res.failed != 0) files_failed += 1;
    }
    const ms = start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
    std.debug.print("z80: SingleStepTests {d} files ({d} failed), {d} cases ({d} failed), {d} ms\n", .{ names.items.len, files_failed, cases, cases_failed, ms });
    try std.testing.expectEqual(@as(u64, 0), cases_failed);
}
