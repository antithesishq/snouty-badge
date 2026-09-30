//! Scrubber sizing (SPEC.md sections 10 and 13, PLAN.md "M3 Scrub" Track
//! A): how much history the page store holds in the ~69 KB run-time arena
//! at page sizes 64, 128 and 256 B, on Waternet and (when present) Sonic.
//!
//! The run is played once per ROM and its keyframes (frame 0, then every 30
//! frames) captured; each store layout then takes them in order, the store
//! evicting the oldest itself. A layout is 69 KB of memory, a keyframe
//! limit, and as many pool pages as fit next to that many page tables
//! (`kstore.pages_fitting`). History at the end is (count - 1) / 2 seconds.
//! The limit the frontend picks (`split_keyframes`) must hold at least 3 s
//! at every page size (SPEC.md 10 target); the fixed 64-table layout and a
//! sweep of other limits are printed to show what the tables cost (at 64 B
//! pages, 64 tables alone fill the arena).
//! Per-keyframe copied/shared/zero page counts and `pages_in_use` are
//! printed for every run (and before a failure), so the numbers can go into
//! SPEC.md and the page size choice.
//!
//! Inputs: Waternet (roms/waternet.gg) plays tools/scripts/m1_play.json for
//! 600 frames, then keeps poking the pipe grid by looping that script's
//! play section (frames 210..599) to 1800 frames. Sonic (`$HOME/sonic.gg`,
//! Adrian's own ROM, read in place, never copied; skipped when missing)
//! gets Start at 200, 320 and 440, then Right held with a jump (button 1)
//! every 45 frames, for 2400 frames.
const std = @import("std");
const core = @import("core");
const Gg = core.Gg;
const Pad = core.Pad;
const kstore = core.kstore;

const interval = 30;
const arena_bytes = 69 * 1024;
const max_keyframes = 64;
const lens = [kstore.region_count]usize{ @sizeOf(Gg.Small), 0x2000, 0x4000, core.cart_ram_size };
/// SPEC.md 10: at least 3 s of history for any ROM from the drive.
const min_history_halves = 6;

const prefixes = [_][]const u8{ "", "carts/snouty-gear/", "../", "../../" };

fn read_any(rel: []const u8, buf: []u8) ?[]u8 {
    for (prefixes) |pre| {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ pre, rel }) catch continue;
        return std.Io.Dir.cwd().readFile(std.testing.io, path, buf) catch continue;
    }
    return null;
}

const Hold = struct { from: u32, to: u32, hold: []const []const u8 };

fn button(name: []const u8) !u8 {
    const map = [_]struct { []const u8, u8 }{
        .{ "UP", Pad.up },       .{ "DOWN", Pad.down }, .{ "LEFT", Pad.left },
        .{ "RIGHT", Pad.right }, .{ "B", Pad.b1 },      .{ "A", Pad.b2 },
        .{ "START", Pad.start }, .{ "SELECT", 0 },
    };
    for (map) |m| if (std.mem.eql(u8, m[0], name)) return m[1];
    return error.UnknownButton;
}

/// Pad byte per frame from a preview script (tests/golden.zig's format).
fn script_pads(json: []const u8, pads: []u8) !void {
    const parsed = try std.json.parseFromSlice([]const Hold, std.testing.allocator, json, .{});
    defer parsed.deinit();
    @memset(pads, 0);
    for (parsed.value) |h| {
        var bits: u8 = 0;
        for (h.hold) |name| bits |= try button(name);
        var f = h.from;
        while (f <= h.to and f < pads.len) : (f += 1) pads[f] |= bits;
    }
}

const waternet_frames = 1800;
const sonic_frames = 2400;

fn waternet_pads(pads: *[waternet_frames]u8) !void {
    var script_buf: [0x4000]u8 = undefined;
    const json = read_any("tools/scripts/m1_play.json", &script_buf) orelse return error.FileNotFound;
    try script_pads(json, pads[0..600]);
    const loop_from = 210;
    for (pads[600..], 0..) |*p, i| p.* = pads[loop_from + i % (600 - loop_from)];
}

fn sonic_pads(pads: *[sonic_frames]u8) void {
    @memset(pads, 0);
    for ([_]usize{ 200, 320, 440 }) |at| @memset(pads[at..][0..6], Pad.start);
    for (pads[460..], 460..) |*p, f| {
        p.* = Pad.right;
        if ((f - 460) % 45 < 8) p.* |= Pad.b1;
    }
}

/// The console state at every keyframe of a run (frame 0, 30, 60, ...),
/// as the four `Gg.state_regions` byte regions, captured once per ROM so
/// every store layout sees the same states.
const Capture = struct {
    const State = struct {
        small: [@sizeOf(Gg.Small)]u8,
        ram: [0x2000]u8,
        vram: [0x4000]u8,
        cart_ram: [core.cart_ram_size]u8,

        fn regions(s: *const State) kstore.Store(64).ConstRegions {
            return .{ &s.small, &s.ram, &s.vram, &s.cart_ram };
        }
    };
    states: []State,

    fn init(rom: []const u8, pads: []const u8) !Capture {
        const gpa = std.testing.allocator;
        const states = try gpa.alloc(State, pads.len / interval + 1);
        errdefer gpa.free(states);
        const gg = try gpa.create(Gg);
        defer gpa.destroy(gg);
        gg.init_in_place(core.Rom.from_slice(rom));
        var small: Gg.Small = undefined;
        var k: usize = 0;
        for (0..pads.len + 1) |f| {
            if (f % interval == 0) {
                gg.save_small(&small);
                const r = gg.state_regions(&small);
                const st = &states[k];
                @memcpy(&st.small, r[0]);
                @memcpy(&st.ram, r[1]);
                @memcpy(&st.vram, r[2]);
                @memcpy(&st.cart_ram, r[3]);
                k += 1;
            }
            if (f < pads.len) gg.step_frame(pads[f]);
        }
        return .{ .states = states[0..k] };
    }

    fn deinit(c: Capture) void {
        std.testing.allocator.free(c.states);
    }
};

/// What one store layout measured. Counts per keyframe `put` after the
/// first.
const Stats = struct {
    page_size: usize,
    max_keyframes: usize,
    n_pages: usize,
    pool_pages: usize,
    /// Even an empty store cannot take a first keyframe (the tables alone
    /// fill the arena).
    no_room: bool = false,
    puts: usize = 0,
    copied_sum: usize = 0,
    copied_max: usize = 0,
    shared_sum: usize = 0,
    zero_sum: usize = 0,
    in_use_max: usize = 0,
    in_use_end: usize = 0,
    count_end: usize = 0,
    /// Smallest count over the second half of the run (after warm-up).
    count_min_late: usize = std.math.maxInt(usize),
    pool_resets: usize = 0,

    fn table_bytes(s: *const Stats) usize {
        return s.n_pages * @sizeOf(u16);
    }
    /// Mean pages copied per keyframe, in tenths.
    fn copied_mean10(s: *const Stats) usize {
        return s.copied_sum * 10 / @max(s.puts, 1);
    }
    /// Mean bytes per keyframe: copied pages plus its reference table.
    fn bytes_per_keyframe(s: *const Stats) usize {
        return s.copied_sum * s.page_size / @max(s.puts, 1) + s.table_bytes();
    }
    /// History held at the end, in half seconds.
    fn halves(s: *const Stats) usize {
        return if (s.count_end == 0) 0 else s.count_end - 1;
    }
    fn halves_late(s: *const Stats) usize {
        return if (s.count_min_late == 0 or s.count_min_late == std.math.maxInt(usize)) 0 else s.count_min_late - 1;
    }

    fn print(s: *const Stats, label: []const u8) void {
        if (s.no_room) {
            std.debug.print("scrub_sizing: {s} page {d} B, max {d} keyframes: {d} pages/keyframe (table {d} B), pool {d} pages: no room for one keyframe\n", .{ label, s.page_size, s.max_keyframes, s.n_pages, s.table_bytes(), s.pool_pages });
            return;
        }
        const m = s.copied_mean10();
        const n = @max(s.puts, 1);
        std.debug.print(
            "scrub_sizing: {s} page {d} B, max {d} keyframes: {d} pages/keyframe (table {d} B), pool {d} pages; " ++
                "copied mean {d}.{d} max {d}, shared mean {d}, zero mean {d}; " ++
                "{d} B/keyframe incl. table; pages_in_use end {d} max {d}; " ++
                "keyframes end {d} (late min {d}) = {d}.{d} s (late min {d}.{d} s); pool resets {d}\n",
            .{
                label,            s.page_size,            s.max_keyframes,    s.n_pages,           s.table_bytes(),
                s.pool_pages,     m / 10,                 m % 10,             s.copied_max,        s.shared_sum / n,
                s.zero_sum / n,   s.bytes_per_keyframe(), s.in_use_end,       s.in_use_max,        s.count_end,
                s.count_min_late, s.halves() / 2,         s.halves() % 2 * 5, s.halves_late() / 2, s.halves_late() % 2 * 5,
                s.pool_resets,
            },
        );
    }
};

/// Put the captured keyframes through a `Store(page_size)` laid out in
/// 69 KB for `max_kf` keyframes, as cart/src/frontend/rewind.zig does.
fn run(comptime page_size: usize, cap: Capture, max_kf: usize) !Stats {
    const gpa = std.testing.allocator;
    const n_pages = kstore.pages_for(page_size, lens);
    const pool_pages = kstore.pages_fitting(page_size, arena_bytes, max_kf, n_pages);
    try std.testing.expect(kstore.bytes_for(page_size, pool_pages, max_kf, n_pages) <= arena_bytes);
    var st: Stats = .{ .page_size = page_size, .max_keyframes = max_kf, .n_pages = n_pages, .pool_pages = pool_pages };
    const mem = try gpa.alignedAlloc(u8, .@"4", arena_bytes);
    defer gpa.free(mem);
    var store = kstore.Store(page_size).init(mem, pool_pages, max_kf, n_pages);
    store.put(cap.states[0].regions()) catch {
        st.no_room = true;
        return st;
    };
    const late_from = cap.states.len / 2;
    for (cap.states[1..], 1..) |*state, k| {
        store.put(state.regions()) catch {
            // The frontend's fallback: forget history, keep only now.
            st.pool_resets += 1;
            store.reset();
            store.put(state.regions()) catch {
                st.no_room = true;
                return st;
            };
        };
        st.puts += 1;
        st.copied_sum += store.last_copied;
        st.copied_max = @max(st.copied_max, store.last_copied);
        st.shared_sum += store.last_shared;
        st.zero_sum += store.last_zero;
        st.in_use_max = @max(st.in_use_max, store.pages_in_use());
        if (k >= late_from) st.count_min_late = @min(st.count_min_late, store.count);
    }
    try std.testing.expect(store.check());
    st.in_use_end = store.pages_in_use();
    st.count_end = store.count;
    return st;
}

/// Keyframe limits tried besides the two layouts below, to show what the
/// tables cost.
const other_limits = [_]usize{ 8, 12, 16, 24, 32, 48 };

/// The keyframe count cart/src/frontend/rewind.zig picks (Snouty Boy's M7
/// split): per keyframe its table plus its typical copied pages, the pool
/// gets the rest. `tuning.typical_pages_per_keyframe` is 40 at 128 B (about
/// 5 KB); other page sizes use the same 5 KB in their own pages.
fn split_keyframes(page_size: usize) usize {
    const n_pages = kstore.pages_for(page_size, lens);
    const typical = 40 * 128 / page_size;
    const per_keyframe = n_pages * 2 + typical * (page_size + 3);
    return @min(arena_bytes / per_keyframe, max_keyframes);
}

fn size_all(label: []const u8, rom: []const u8, pads: []const u8) !void {
    const cap = try Capture.init(rom, pads);
    defer cap.deinit();
    std.debug.print("scrub_sizing: {s}: {d} keyframes captured, Small {d} B, arena {d} B\n", .{ label, cap.states.len, @sizeOf(Gg.Small), arena_bytes });
    var ok = true;
    inline for (.{ 64, 128, 256 }) |page_size| {
        // The frontend's layout: must hold 3 s (SPEC.md 10).
        const split = try run(page_size, cap, split_keyframes(page_size));
        std.debug.print("scrub_sizing: [frontend split] ", .{});
        split.print(label);
        if (split.no_room or split.halves() < min_history_halves) ok = false;
        // The fixed 64-table layout PLAN.md asked for, and the sweep.
        std.debug.print("scrub_sizing: [64 tables] ", .{});
        (try run(page_size, cap, max_keyframes)).print(label);
        for (other_limits) |lim| (try run(page_size, cap, lim)).print(label);
    }
    if (!ok) {
        std.debug.print("scrub_sizing: {s}: a page size holds less than 3 s of history in the frontend layout (numbers above)\n", .{label});
        return error.HistoryTooShort;
    }
}

var rom_buf: [0x80000]u8 = undefined;

test "scrub_sizing: waternet 1800 frames, 64/128/256 B pages, >= 3 s in 69 KB" {
    const rom = read_any("roms/waternet.gg", &rom_buf) orelse return error.SkipZigTest;
    var pads: [waternet_frames]u8 = undefined;
    try waternet_pads(&pads);
    try size_all("waternet", rom, &pads);
}

test "scrub_sizing: sonic 2400 frames, 64/128/256 B pages, >= 3 s in 69 KB" {
    const home = std.testing.environ.getPosix("HOME") orelse return error.SkipZigTest;
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/sonic.gg", .{home});
    const rom = std.Io.Dir.cwd().readFile(std.testing.io, path, &rom_buf) catch return error.SkipZigTest;
    var pads: [sonic_frames]u8 = undefined;
    sonic_pads(&pads);
    try size_all("sonic", rom, &pads);
}
