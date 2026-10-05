//! The engine side of the oracle (SPEC section 6): reads an answer script,
//! plays it through the `game` module and prints the transcript.
//!
//!   raspberry-trail-oracle SCRIPT
//!
//! Script: a first line `seed <u64>`, then one answer per line: YES, NO,
//! an integer (number and choice prompts) or `SHOOT <0|1> <seconds>`.
//! Blank lines and lines starting with `#` are ignored.
//!
//! Transcript (stdout):
//!   T <text>        every printed line, whitespace runs collapsed to one
//!                   space and trimmed; empty lines skipped
//!   P <line> <kind> at every INPUT, then
//!   V A=.. B=..     all of `Vars` in declaration order (integral values
//!                   with |x| < 2^53 as integers, others as h + 16 hex
//!                   digits of the IEEE bits)
//!   I <answer>      the script's answer as written (single spaces)
//!   E <outcome>     at the STOP, exit 0
//!   X eof           the script ran out first, exit 0
//!   X mismatch <line>  an answer of the wrong kind, exit 2
const std = @import("std");
const G = @import("game");

var io_mem: std.Io.Threaded = .init_single_threaded;
const io = io_mem.io();

fn usage() noreturn {
    std.debug.print("usage: raspberry-trail-oracle SCRIPT\n", .{});
    std.process.exit(2);
}

fn die(comptime f: []const u8, args: anytype) noreturn {
    std.debug.print("raspberry-trail-oracle: " ++ f ++ "\n", args);
    std.process.exit(1);
}

var g: G.Game = .{};

fn write_text(w: *std.Io.Writer, s: []const u8) !void {
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n");
    const first = it.next() orelse return;
    try w.writeAll("T ");
    try w.writeAll(first);
    while (it.next()) |tok| {
        try w.writeByte(' ');
        try w.writeAll(tok);
    }
    try w.writeByte('\n');
}

fn write_value(w: *std.Io.Writer, x: f64) !void {
    if (x == @floor(x) and @abs(x) < 0x1p53) {
        const i: i64 = @intFromFloat(x);
        try w.print("{d}", .{i});
    } else {
        try w.print("h{x:0>16}", .{@as(u64, @bitCast(x))});
    }
}

fn write_vars(w: *std.Io.Writer) !void {
    try w.writeAll("V");
    inline for (@typeInfo(G.Vars).@"struct".field_names) |name| {
        try w.print(" {s}=", .{name});
        try write_value(w, @field(g.v, name));
    }
    try w.writeByte('\n');
}

fn flush_lines(w: *std.Io.Writer) !void {
    for (g.printed()) |l| try write_text(w, l.text);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var args = try init.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse usage();
    if (args.next() != null) usage();

    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20)) catch |e| die("cannot read {s}: {s}", .{ path, @errorName(e) });

    var out_buf: [1 << 16]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &out_buf);
    const w = &fw.interface;

    // The script's meaningful lines.
    var lines = std.mem.splitScalar(u8, text, '\n');
    const next_line = struct {
        fn f(it: *std.mem.SplitIterator(u8, .scalar)) ?[]const u8 {
            while (it.next()) |raw| {
                const l = std.mem.trim(u8, raw, " \t\r");
                if (l.len == 0 or l[0] == '#') continue;
                return l;
            }
            return null;
        }
    }.f;

    const head = next_line(&lines) orelse die("{s}: empty script", .{path});
    var ht = std.mem.tokenizeAny(u8, head, " \t");
    const kw = ht.next() orelse "";
    if (!std.mem.eql(u8, kw, "seed")) die("{s}: first line must be `seed <u64>`", .{path});
    const seed = std.fmt.parseInt(u64, ht.next() orelse die("{s}: no seed", .{path}), 10) catch die("{s}: bad seed", .{path});

    G.init(&g, seed);
    G.start(&g);

    while (true) {
        try flush_lines(w);
        if (g.prompt.kind == .game_over) {
            try w.print("E {s}\n", .{@tagName(g.prompt.outcome)});
            break;
        }
        try w.print("P {d} {s}\n", .{ g.prompt.line, @tagName(g.prompt.kind) });
        try write_vars(w);

        const l = next_line(&lines) orelse {
            try w.writeAll("X eof\n");
            break;
        };
        var toks: [4][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, l, " \t");
        while (it.next()) |t| {
            if (n == toks.len) break;
            toks[n] = t;
            n += 1;
        }
        const ans = parse_answer(toks[0..n]) orelse {
            try w.print("X mismatch {d}\n", .{g.prompt.line});
            try w.flush();
            std.process.exit(2);
        };
        try w.writeAll("I");
        for (toks[0..n]) |t| try w.print(" {s}", .{t});
        try w.writeByte('\n');
        switch (ans) {
            .answer => |a| G.answer(&g, a),
            .value => |x| G.answer_value(&g, x),
        }
    }
    try w.flush();
}

const Parsed = union(enum) { answer: G.Answer, value: f64 };

/// The script answer for the current prompt, or null if it is the wrong kind.
fn parse_answer(t: []const []const u8) ?Parsed {
    if (t.len == 0) return null;
    switch (g.prompt.kind) {
        .yes_no => {
            if (t.len != 1) return null;
            if (std.mem.eql(u8, t[0], "YES")) return .{ .answer = .{ .yes_no = true } };
            if (std.mem.eql(u8, t[0], "NO")) return .{ .answer = .{ .yes_no = false } };
            return null;
        },
        .number, .choice => {
            if (t.len != 1) return null;
            const i = std.fmt.parseInt(i64, t[0], 10) catch {
                // An integer beyond i64: the INPUT still reads it as a number.
                for (t[0], 0..) |c, k| if (!(std.ascii.isDigit(c) or (k == 0 and (c == '-' or c == '+')))) return null;
                return .{ .value = std.fmt.parseFloat(f64, t[0]) catch return null };
            };
            if (g.prompt.kind == .number) {
                if (std.math.cast(i32, i)) |n| return .{ .answer = .{ .number = n } };
            } else {
                if (std.math.cast(u8, i)) |c| return .{ .answer = .{ .choice = c } };
            }
            return .{ .value = std.fmt.parseFloat(f64, t[0]) catch return null };
        },
        .shoot => {
            if (t.len != 3 or !std.mem.eql(u8, t[0], "SHOOT")) return null;
            const correct = if (std.mem.eql(u8, t[1], "1")) true else if (std.mem.eql(u8, t[1], "0")) false else return null;
            const secs = std.fmt.parseFloat(f64, t[2]) catch return null;
            return .{ .answer = .{ .shoot = .{ .correct = correct, .seconds = secs } } };
        },
        .game_over => return null,
    }
}
