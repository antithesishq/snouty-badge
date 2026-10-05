//! The oracle's Zig side (PLAN.md, track O): replays an action script
//! (tools/oracle/scripts/*.json) through the port's `game` module and dumps
//! the game state at the same checkpoints as tools/js_oracle.mjs, for
//! tools/compare.mjs.
//!
//!   paperclips-oracle SCRIPT.json [-o OUT.json] [--every MS] [--from MS] [--to MS]
//!
//! Script: {"name", "seed", "end_ms", "checkpoint_every", "checkpoints"?,
//! "actions": [[ms, "verb", arg?], ...]}. At each ms the timers due fire
//! first (`game.advance_ms`), then that ms's actions in order (applied when
//! `game.enabled`, like a click on an enabled button), then the snapshot.
//! Verbs are the `game.Action` tags; an enum payload is given by tag name
//! ("low", "speed"), an integer payload as a number.
//!
//! Output: {"side": "zig", "checkpoints": [{"ms", "fields": <every scalar,
//! array and struct field of Game by its snake_case name>, "active_projects",
//! "project_flags", "project_uses", "project_disabled", "msg_count"}],
//! "actions": [1|0 applied...], "messages": [text...]}. The welcome line
//! (`init`'s first message) is not counted: the JS oracle records
//! displayMessage calls and the welcome line is static HTML there.
const std = @import("std");
const game = @import("game");

var io_mem: std.Io.Threaded = .init_single_threaded;
const io = io_mem.io();

const Game = game.Game;
const Action = game.Action;

fn usage() noreturn {
    std.debug.print("usage: paperclips-oracle SCRIPT.json [-o OUT.json] [--every MS] [--from MS] [--to MS]\n", .{});
    std.process.exit(2);
}

fn die(comptime f: []const u8, args: anytype) noreturn {
    std.debug.print("paperclips-oracle: " ++ f ++ "\n", args);
    std.process.exit(1);
}

const Act = struct { ms: u64, action: Action };

// ---------------------------------------------------------------- script ----

fn json_u64(v: std.json.Value) ?u64 {
    return switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .float => |f| if (f >= 0 and f == @floor(f)) @intFromFloat(f) else null,
        .string => |s| std.fmt.parseInt(u64, s, 10) catch null,
        .number_string => |s| std.fmt.parseInt(u64, s, 10) catch null,
        else => null,
    };
}

fn parse_action(verb: []const u8, arg: ?std.json.Value) ?Action {
    const ui = @typeInfo(Action).@"union";
    inline for (ui.field_names, ui.field_types) |fname, T| {
        if (std.mem.eql(u8, fname, verb)) {
            if (T == void) return @unionInit(Action, fname, {});
            const a = arg orelse return null;
            switch (@typeInfo(T)) {
                .int => {
                    const n = json_u64(a) orelse return null;
                    return @unionInit(Action, fname, std.math.cast(T, n) orelse return null);
                },
                .@"enum" => {
                    const s = switch (a) {
                        .string => |s| s,
                        else => return null,
                    };
                    const e = std.meta.stringToEnum(T, s) orelse return null;
                    return @unionInit(Action, fname, e);
                },
                else => return null,
            }
        }
    }
    return null;
}

// Same as js_oracle.mjs checkpointTimes().
fn checkpoint_times(gpa: std.mem.Allocator, end: u64, every: u64, from: u64, to_opt: ?u64, extra: []const u64) ![]u64 {
    const to = @min(to_opt orelse end, end);
    var list: std.ArrayList(u64) = .empty;
    var t = (from + every - 1) / every * every;
    while (t <= to) : (t += every) if (t > 0) try list.append(gpa, t);
    for (extra) |e| if (e >= from and e <= to) try list.append(gpa, e);
    try list.append(gpa, to);
    std.mem.sort(u64, list.items, {}, std.sort.asc(u64));
    // unique
    var n: usize = 0;
    for (list.items) |x| {
        if (n == 0 or list.items[n - 1] != x) {
            list.items[n] = x;
            n += 1;
        }
    }
    return list.items[0..n];
}

// ------------------------------------------------------------------ JSON ----

fn write_string(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...8, 11, 12, 14...0x1f => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

fn write_f64(w: *std.Io.Writer, x: f64) !void {
    if (std.math.isNan(x)) return w.writeAll("\"NaN\"");
    if (std.math.isInf(x)) return w.writeAll(if (x > 0) "\"Infinity\"" else "\"-Infinity\"");
    if (x == 0) return w.writeAll("0");
    const a = @abs(x);
    // Shortest round-trip digits either way; JSON.parse gives the same f64.
    if (a >= 1e21 or a < 1e-6) try w.print("{e}", .{x}) else try w.print("{d}", .{x});
}

// Fields not dumped: RNG state (u64 beyond 2^53), internal buffers, the
// 400 combat ships (num_* counts are dumped).
const skip_fields = [_][]const u8{ "rng", "timers", "msg_buf", "msg_entries", "ships", "income_tracker" };

fn skipped(comptime name: []const u8) bool {
    @setEvalBranchQuota(20000);
    inline for (skip_fields) |s| if (comptime std.mem.eql(u8, s, name)) return true;
    return false;
}

fn write_value(w: *std.Io.Writer, comptime T: type, v: T) !void {
    switch (@typeInfo(T)) {
        .float => try write_f64(w, @floatCast(v)),
        .int, .comptime_int => try w.print("{d}", .{v}),
        .bool => try w.writeAll(if (v) "true" else "false"),
        .@"enum" => try write_string(w, @tagName(v)),
        .optional => if (v) |x| try write_value(w, @TypeOf(x), x) else try w.writeAll("null"),
        .array => |ai| {
            try w.writeByte('[');
            for (v, 0..) |x, i| {
                if (i > 0) try w.writeByte(',');
                try write_value(w, ai.child, x);
            }
            try w.writeByte(']');
        },
        .@"struct" => |si| {
            @setEvalBranchQuota(200000);
            try w.writeByte('{');
            var first = true;
            inline for (si.field_names, si.field_types) |fname, FT| {
                if (comptime skipped(fname)) continue;
                if (comptime !dumpable(FT)) continue;
                if (!first) try w.writeByte(',');
                first = false;
                try write_string(w, fname);
                try w.writeByte(':');
                try write_value(w, FT, @field(v, fname));
            }
            try w.writeByte('}');
        },
        else => try w.writeAll("null"),
    }
}

fn dumpable(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .float, .int, .bool, .@"enum" => true,
        .optional => |o| dumpable(o.child),
        .array => |a| a.len <= 128 and dumpable(a.child),
        .@"struct" => true,
        else => false,
    };
}

fn write_disabled(w: *std.Io.Writer, gs: *const Game) !void {
    try w.writeByte('{');
    const ei = @typeInfo(game.Btn).@"enum";
    inline for (ei.field_names, ei.field_values, 0..) |fname, fval, i| {
        if (i > 0) try w.writeByte(',');
        try write_string(w, fname);
        try w.writeByte(':');
        try w.writeAll(if (gs.is_disabled(@enumFromInt(fval))) "true" else "false");
    }
    try w.writeByte('}');
}

fn snapshot(w: *std.Io.Writer, gs: *const Game, ms: u64, msg_count: usize, first: bool) !void {
    if (!first) try w.writeAll(",\n");
    try w.print("{{\"ms\":{d},\"fields\":", .{ms});
    try write_value(w, Game, gs.*);
    try w.writeAll(",\"disabled\":");
    try write_disabled(w, gs);
    try w.writeAll(",\"active_projects\":[");
    for (gs.active[0..gs.active_len], 0..) |p, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{d}", .{p});
    }
    try w.writeAll("],\"project_flags\":");
    try write_value(w, @TypeOf(gs.proj_flag), gs.proj_flag);
    try w.writeAll(",\"project_uses\":");
    try write_value(w, @TypeOf(gs.proj_uses), gs.proj_uses);
    try w.writeAll(",\"project_disabled\":");
    try write_value(w, @TypeOf(gs.proj_disabled), gs.proj_disabled);
    try w.print(",\"msg_count\":{d}}}", .{msg_count});
}

// ------------------------------------------------------------------ main ----

var g: Game = undefined;

const Msgs = struct {
    list: std.ArrayList([]const u8) = .empty,
    seen: u64 = 0, // g.msg_count already taken
    restarts: u32 = 0,
    lost: u64 = 0,

    fn collect(m: *Msgs, gpa: std.mem.Allocator) !void {
        if (g.restarts != m.restarts) {
            // A reload: a new console whose oldest line is the welcome
            // line. Whatever the task printed before reloading is gone
            // (the JS side drops it too); the lines after the welcome
            // line are new, whether or not msg_count went on counting.
            m.restarts = g.restarts;
            const avail: u64 = g.messages_available();
            m.seen = @as(u64, g.msg_count) - (if (avail > 0) avail - 1 else 0);
            try m.list.append(gpa, "<reload>");
        }
        const total: u64 = g.msg_count;
        if (total <= m.seen) return;
        const new = total - m.seen;
        const avail = g.messages_available();
        if (new > avail) {
            m.lost += new - avail;
            var k: u64 = 0;
            while (k < new - avail) : (k += 1) try m.list.append(gpa, "<lost>");
        }
        var age: usize = @intCast(@min(new, avail));
        while (age > 0) {
            age -= 1;
            const s = g.message(age) orelse "<none>";
            try m.list.append(gpa, try gpa.dupe(u8, s));
        }
        m.seen = total;
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var args = try init.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    var script_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var every_opt: ?u64 = null;
    var from: u64 = 0;
    var to_opt: ?u64 = null;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "-o")) {
            out_path = args.next() orelse usage();
        } else if (std.mem.eql(u8, a, "--every")) {
            every_opt = std.fmt.parseInt(u64, args.next() orelse usage(), 10) catch usage();
        } else if (std.mem.eql(u8, a, "--from")) {
            from = std.fmt.parseInt(u64, args.next() orelse usage(), 10) catch usage();
        } else if (std.mem.eql(u8, a, "--to")) {
            to_opt = std.fmt.parseInt(u64, args.next() orelse usage(), 10) catch usage();
        } else if (script_path == null) {
            script_path = a;
        } else usage();
    }
    const path = script_path orelse usage();

    const cwd = std.Io.Dir.cwd();
    const text = cwd.readFileAlloc(io, path, gpa, .limited(256 << 20)) catch |e| die("cannot read {s}: {s}", .{ path, @errorName(e) });
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch |e| die("{s}: {s}", .{ path, @errorName(e) });
    const root = parsed.value.object;

    const name: []const u8 = if (root.get("name")) |v| switch (v) {
        .string => |s| s,
        else => "?",
    } else std.fs.path.stem(path);
    const seed_v = root.get("seed") orelse die("{s}: no seed", .{path});
    const seed = json_u64(seed_v) orelse die("{s}: bad seed", .{path});
    const end = json_u64(root.get("end_ms") orelse die("{s}: no end_ms", .{path})) orelse die("bad end_ms", .{});
    const every = every_opt orelse if (root.get("checkpoint_every")) |v| json_u64(v) orelse 1000 else 1000;
    if (every == 0) die("checkpoint_every must be > 0", .{});

    var extra: std.ArrayList(u64) = .empty;
    if (root.get("checkpoints")) |v| for (v.array.items) |x| try extra.append(gpa, json_u64(x) orelse die("bad checkpoint", .{}));

    var acts: std.ArrayList(Act) = .empty;
    if (root.get("actions")) |v| for (v.array.items, 0..) |x, i| {
        const t = x.array.items;
        if (t.len < 2) die("action {d}: want [ms, verb, arg?]", .{i});
        const ms = json_u64(t[0]) orelse die("action {d}: bad ms", .{i});
        const verb = switch (t[1]) {
            .string => |s| s,
            else => die("action {d}: verb not a string", .{i}),
        };
        const a = parse_action(verb, if (t.len > 2) t[2] else null) orelse die("action {d}: unknown verb or bad argument: {s}", .{ i, verb });
        try acts.append(gpa, .{ .ms = ms, .action = a });
    };

    const cps = try checkpoint_times(gpa, end, every, from, to_opt, extra.items);

    game.init(&g, seed);
    var msgs: Msgs = .{ .seen = g.msg_count, .restarts = g.restarts };
    var applied: std.ArrayList(u8) = .empty;

    var out_buf: [1 << 16]u8 = undefined;
    var file: ?std.Io.File = null;
    var fw = if (out_path) |p| blk: {
        file = cwd.createFile(io, p, .{}) catch |e| die("cannot create {s}: {s}", .{ p, @errorName(e) });
        break :blk file.?.writer(io, &out_buf);
    } else std.Io.File.stdout().writer(io, &out_buf);
    const w = &fw.interface;

    try w.writeAll("{\"side\":\"zig\",\"name\":");
    try write_string(w, name);
    try w.print(",\"seed\":\"{d}\",\"end_ms\":{d},\"checkpoints\":[\n", .{ seed, end });

    var now: u64 = 0;
    var ai: usize = 0;
    for (cps, 0..) |cp, ci| {
        while (ai < acts.items.len and acts.items[ai].ms <= cp) : (ai += 1) {
            const a = acts.items[ai];
            if (a.ms < now) die("action {d}: time goes backwards", .{ai});
            try advance_to(&now, a.ms, &msgs, gpa);
            const ok = game.enabled(&g, a.action);
            if (ok) game.act(&g, a.action);
            try applied.append(gpa, if (ok) 1 else 0);
            try msgs.collect(gpa);
        }
        try advance_to(&now, cp, &msgs, gpa);
        try snapshot(w, &g, cp, msgs.list.items.len, ci == 0);
    }
    try w.writeAll("\n],\"actions\":[");
    for (applied.items, 0..) |x, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{d}", .{x});
    }
    try w.writeAll("],\"messages\":[\n");
    for (msgs.list.items, 0..) |s, i| {
        if (i > 0) try w.writeAll(",\n");
        try write_string(w, s);
    }
    try w.print("\n],\"lost_messages\":{d}}}\n", .{msgs.lost});
    try w.flush();
    if (file) |f| f.close(io);
}

fn advance_to(now: *u64, ms: u64, msgs: *Msgs, gpa: std.mem.Allocator) !void {
    // In steps of at most 1 s so the 64-entry message ring never overflows.
    while (now.* < ms) {
        const d: u32 = @intCast(@min(ms - now.*, 1000));
        game.advance_ms(&g, d);
        now.* += d;
        try msgs.collect(gpa);
    }
}
