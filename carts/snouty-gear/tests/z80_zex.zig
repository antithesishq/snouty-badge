//! ZEXDOC and ZEXALL, Maxim's SMS port v0.21 (tests/roms/zexdoc.sms and
//! zexall.sms from tools/fetch_test_roms.sh; skipped (`error.SkipZigTest`)
//! with a note if absent).
//! They print through the SDSC debug console (port FD data, FC control),
//! so a minimal bus of our own captures that text: ROM 0000-BFFF straight
//! from the 64 KB file (no mapper; writes to FFFC-FFFF just land in RAM),
//! 8 KB RAM at C000-DFFF mirrored at E000-FFFF, every other port reads FF
//! and drops writes, no interrupts. The run ends at "Tests complete"; all
//! 79 test lines must end in OK and no line may say ERROR. (The SCF/CCF
//! table the port prints first has no verdict; the SingleStepTests check
//! the Q behaviour it probes.)
//!
//! ZEXALL is ~46 billion T-states (ZEXDOC about the same). A Debug test
//! binary takes minutes for that, so in Debug only ZEXDOC runs and ZEXALL is
//! skipped with a note unless `GEAR_ZEXALL=1`; any release test build
//! (`-Dtest-optimize=fast|safe|small`) runs both. `GEAR_ZEX=0` skips both.
//! With `SNOUTY_FIXTURES=required` (set by `zig build test-z80-strict`) an
//! absent ROM is `error.FixtureMissing`, ZEXALL runs in Debug too and
//! `GEAR_ZEX=0` is ignored.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");

const ZexBus = struct {
    rom: []const u8,
    ram: [0x2000]u8 = @splat(0),
    text: [8192]u8 = undefined,
    text_len: usize = 0,
    /// Set when a newline arrives, so the runner re-checks the text.
    line_done: bool = false,

    pub fn read(self: *ZexBus, addr: u16) u8 {
        if (addr < 0xC000) return if (addr < self.rom.len) self.rom[addr] else 0xFF;
        return self.ram[addr & 0x1FFF];
    }
    pub fn write(self: *ZexBus, addr: u16, v: u8) void {
        if (addr >= 0xC000) self.ram[addr & 0x1FFF] = v;
    }
    pub fn in(self: *ZexBus, port: u8) u8 {
        _ = self;
        _ = port;
        return 0xFF;
    }
    pub fn out(self: *ZexBus, port: u8, v: u8) void {
        if (port != 0xFD) return;
        if (self.text_len < self.text.len) {
            self.text[self.text_len] = v;
            self.text_len += 1;
        }
        if (v == '\n' or v == '\r') self.line_done = true;
    }
    pub fn irq_line(self: *ZexBus) bool {
        _ = self;
        return false;
    }
};

const Cpu = core.z80.Z80(ZexBus);

/// Test lines each ROM prints ("<name> OK", or "<name> ERROR ..." on a
/// CRC mismatch); both v0.21 ROMs run the same 79 tests.
const test_count = 79;

/// Generous cap: the longest of the two runs is ~46 billion T-states.
const t_cap: u64 = 80_000_000_000;

var rom_buf: [0x10000]u8 = undefined;

fn load(name: []const u8) ?[]const u8 {
    const io = std.testing.io;
    const dirs = [_][]const u8{ "carts/snouty-gear/tests/roms/", "tests/roms/" };
    var path_buf: [256]u8 = undefined;
    for (dirs) |d| {
        const p = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ d, name }) catch continue;
        return std.Io.Dir.cwd().readFile(io, p, &rom_buf) catch continue;
    }
    return null;
}

/// Runs one ZEX ROM to "Tests complete" and returns its OK line count;
/// skips (or, strict, fails) when the ROM is absent.
pub fn run_zex(name: []const u8) !u32 {
    const io = std.testing.io;
    const rom = load(name) orelse {
        if (fixtures_required()) {
            std.debug.print("z80: {s} FIXTURE MISSING: tests/roms/{s} absent (tools/fetch_test_roms.sh)\n", .{ name, name });
            return error.FixtureMissing;
        }
        std.debug.print("z80: {s} skipped: tests/roms/{s} absent (tools/fetch_test_roms.sh)\n", .{ name, name });
        return error.SkipZigTest;
    };
    const bus = try std.testing.allocator.create(ZexBus);
    defer std.testing.allocator.destroy(bus);
    bus.* = .{ .rom = rom };
    var cpu: Cpu = .{};
    cpu.reset();

    const start = std.Io.Timestamp.now(io, .awake);
    var t: u64 = 0;
    var complete = false;
    while (t < t_cap) {
        // Batches keep the text check off the per-instruction path.
        var n: u32 = 0;
        while (n < 4096) : (n += 1) t += cpu.step(bus);
        if (bus.line_done) {
            bus.line_done = false;
            if (std.mem.indexOf(u8, bus.text[0..bus.text_len], "Tests complete") != null) {
                complete = true;
                break;
            }
        }
    }
    const ms = start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
    const text = bus.text[0..bus.text_len];

    var ok_lines: u32 = 0;
    var bad = !complete or std.mem.indexOf(u8, text, "ERROR") != null;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        if (std.mem.endsWith(u8, std.mem.trimEnd(u8, line, " "), " OK")) ok_lines += 1;
    }
    if (ok_lines != test_count) bad = true;
    std.debug.print("z80: {s}: {d} tests OK, {d} T-states, {d} ms ({s})\n", .{ name, ok_lines, t, ms, @tagName(builtin.mode) });
    if (bad) {
        std.debug.print("z80: {s} FAILED ({s}), console text:\n{s}\n", .{ name, if (complete) "complete" else "T-state cap reached", text });
        return error.ZexFailed;
    }
    return ok_lines;
}

fn env(name: []const u8) ?[]const u8 {
    return std.testing.environ.getPosix(name);
}

/// True when `SNOUTY_FIXTURES=required` (the strict oracle step).
pub fn fixtures_required() bool {
    const v = env("SNOUTY_FIXTURES") orelse return false;
    return std.mem.eql(u8, v, "required");
}

fn zex_disabled() bool {
    if (fixtures_required()) return false;
    const v = env("GEAR_ZEX") orelse return false;
    if (!std.mem.eql(u8, v, "0")) return false;
    std.debug.print("z80: ZEX skipped: GEAR_ZEX=0\n", .{});
    return true;
}

test "z80: zexdoc.sms" {
    if (zex_disabled()) return error.SkipZigTest;
    _ = try run_zex("zexdoc.sms");
}

test "z80: zexall.sms" {
    if (zex_disabled()) return error.SkipZigTest;
    if (builtin.mode == .debug and env("GEAR_ZEXALL") == null and !fixtures_required()) {
        std.debug.print("z80: zexall.sms skipped in a Debug build (GEAR_ZEXALL=1 or -Dtest-optimize=fast runs it)\n", .{});
        return error.SkipZigTest;
    }
    _ = try run_zex("zexall.sms");
}
