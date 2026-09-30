//! cpu65: SingleStepTests 65x02 rockwell65c02/v1 (SPEC.md section 16).
//!
//! M0: loads and checks every file in tests/roms/65c02/ (fetched by
//! tools/fetch_test_roms.sh; skipped when absent) so M1 only has to plug
//! core/cpu65.zig into `run_case`. `LYNX_SST_DIR` overrides the directory
//! (the --all batches).
const std = @import("std");

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

pub const Summary = struct { files: u32 = 0, cases: u64 = 0 };

/// Parses one file and checks its shape. M1 runs each case here.
pub fn check_file(gpa: std.mem.Allocator, text: []const u8, name: []const u8) !u64 {
    const parsed = try std.json.parseFromSlice([]const Case, gpa, text, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const want_op = try std.fmt.parseInt(u8, name[0..2], 16);
    for (parsed.value) |c| {
        try std.testing.expect(c.cycles.len >= 1 and c.cycles.len <= 8);
        // The first byte read is the opcode, at the initial PC.
        var op: ?u32 = null;
        for (c.initial.ram) |kv| {
            if (kv[0] == c.initial.pc) op = kv[1];
        }
        try std.testing.expectEqual(@as(?u32, want_op), op);
    }
    return parsed.value.len;
}

const default_dirs = [_][]const u8{ "carts/snouty-lynx/tests/roms/65c02", "tests/roms/65c02", "../tests/roms/65c02" };

test "cpu65: SingleStepTests rockwell65c02 files parse (tests/roms/65c02/*.json)" {
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
    var sum: Summary = .{};
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const text = try dir.readFileAlloc(io, entry.name, gpa, .limited(16 << 20));
        defer gpa.free(text);
        sum.cases += try check_file(gpa, text, entry.name);
        sum.files += 1;
    }
    std.debug.print("cpu65: {d} SingleStepTests files, {d} cases parsed (M1 runs them on core/cpu65.zig)\n", .{ sum.files, sum.cases });
    try std.testing.expect(sum.files > 0);
}
