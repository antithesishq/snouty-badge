//! golden: scripted runs of the shipped ROM and of drhelius's lynx-tests
//! carts (PLAN.md M1 Track C), frame hashes through tests/runner.zig (the
//! core `zig build run-lynx` uses too, so a hash printed here is the one
//! run-lynx prints for the same update).
//!
//! - `roms/raycast.lnx` under `tools/scripts/m1_play.json` (300 updates:
//!   the splash skipped at 40, then moves and turns), checked at a few
//!   updates; plus a second run from reset giving the same hashes.
//! - `tests/roms/lynx-tests/<name>.lnx` (fetched by tools/fetch_test_roms.sh,
//!   gitignored; skipped when absent), no input but A at update 0 to skip
//!   the splash, the hash of the result screen at the end of each run.
//!
//! The tables start empty: the test then PRINTS the hashes and integration
//! fills them after looking at the run-lynx images. With the M1 CPU and Suzy
//! stubbed every frame is black (all-zero pixels and palette), expected.
//! The ROMs and the script are read at run time (outside this module's
//! directory, so `@embedFile` cannot reach them).
const std = @import("std");
const core = @import("core");
const runner = @import("runner.zig");
const files = @import("testfiles.zig");

test {
    _ = runner;
}

const Case = struct {
    name: []const u8,
    rom: []const u8,
    /// Repo-relative script (cart directory), or null: the splash skipped
    /// with A at update 0 and nothing else.
    script: ?[]const u8,
    updates: u32,
    /// Updates (0-based) whose frame hash is checked.
    checkpoints: []const u32,
    /// Hashes at `checkpoints` from a reviewed run (empty: print only).
    hashes: []const u64,
};

const raycast_checkpoints = [_]u32{ 40, 60, 100, 160, 220, 299 };
/// The lynx-tests carts run their tests once and then show the results:
/// the last update is the result screen (the sprite suites need about 250
/// frames on hardware timing, the others under 100).
const short_checkpoints = [_]u32{299};
const long_checkpoints = [_]u32{449};

/// Reviewed 2026-10-01 (M1 integration): the splash skipped at 40, textured
/// walls at 60/100, the cyan face sprite at 160, turned at 220 and 299.
const raycast_hashes = [_]u64{ 0xD93F4954963F0B8E, 0xB6906AFCC0ED0BB2, 0xB6906AFCC0ED0BB2, 0x0C3234C137852C37, 0x29AD2D8A1D68CA31, 0xDA90F351DAF97040 };

const cases = [_]Case{
    .{ .name = "raycast", .rom = "roms/raycast.lnx", .script = "tools/scripts/m1_play.json", .updates = 300, .checkpoints = &raycast_checkpoints, .hashes = &raycast_hashes },
    lynx_test("cpu", false, 0xDC1EBB73A036794B),
    lynx_test("memio", false, 0x30B48D4732846926),
    lynx_test("page-mode", false, 0x24C85B7AB030EE00),
    lynx_test("math", false, 0xE82C94EAFE5F4C4B),
    lynx_test("timers", false, 0x192ADDEB04EA9C99),
    lynx_test("timers2", false, 0x52146A8577186BC8),
    lynx_test("sprites1", true, 0x07C1F6B3882205D7),
    lynx_test("sprites2", true, 0xEF1A2DB317A8AFE6),
    lynx_test("sprites3", true, 0x8C8B982E26744612),
    lynx_test("sprites4", true, 0x80A5C72314739C23),
    lynx_test("sprites5", true, 0x5CA6BFDBB9972A6B),
    lynx_test("sdoneack", false, 0xA2822F2D55562AB1),
    lynx_test("refresh-rate", false, 0xCC8D35132DF73857),
};

/// `hash`: the result screen reviewed 2026-10-01 (every row PASS except
/// sprites4 DMA EXP W24, code 3: PLAN.md M1 integration).
fn lynx_test(comptime name: []const u8, long: bool, comptime hash: u64) Case {
    const cp: []const u32 = if (long) &long_checkpoints else &short_checkpoints;
    return .{ .name = name, .rom = "tests/roms/lynx-tests/" ++ name ++ ".lnx", .script = null, .updates = cp[cp.len - 1] + 1, .checkpoints = cp, .hashes = &.{hash} };
}

var lynx: core.Lynx = undefined;
var rom_buf: [512 * 1024 + 64]u8 = undefined;
var script_buf: [0x4000]u8 = undefined;
var controls: [1024]u16 = undefined;

/// Run `c`, returning the hashes at its checkpoints, or null when the ROM is
/// absent.
fn run_case(c: *const Case, out: []u64) !?void {
    const file = files.read_cart_file(c.rom, &rom_buf) orelse return null;
    const ctl = controls[0..c.updates];
    if (c.script) |s| {
        const json = files.read_cart_file(s, &script_buf) orelse return error.FileNotFound;
        try runner.parse_script(std.testing.allocator, json, ctl);
    } else {
        @memset(ctl, 0);
        ctl[0] = runner.Btn.a;
    }
    const cart = switch (runner.cart_from_file(file)) {
        .ok => |x| x,
        .refused => |r| {
            std.debug.print("golden: {s}: refused ({s})\n", .{ c.name, r.text() });
            return error.TestUnexpectedResult;
        },
    };
    var run = runner.Run.init(&lynx, cart, ctl);
    var k: usize = 0;
    while (!run.done()) {
        const st = run.step();
        if (k < c.checkpoints.len and st.update == c.checkpoints[k]) {
            out[k] = st.hash;
            k += 1;
        }
    }
    try std.testing.expectEqual(c.checkpoints.len, k);
    return {};
}

fn check(c: *const Case) !void {
    var got: [8]u64 = undefined;
    const h = got[0..c.checkpoints.len];
    if (try run_case(c, h) == null) {
        std.debug.print("golden: {s} skipped ({s} absent)\n", .{ c.name, c.rom });
        return error.SkipZigTest;
    }
    if (c.hashes.len == 0) {
        std.debug.print("golden: {s}: {d} updates, boot {s}, instr {d}, irqs {d}, sprites px {d}, display frames {d}; hashes (fill the table after review):\n", .{
            c.name, c.updates, if (lynx.boot_error) |e| @errorName(e) else "ok", lynx.instr_count(), lynx.irq_count, lynx.pixels_drawn(), lynx.display_frames,
        });
        for (c.checkpoints, h) |u, x| std.debug.print("  update {d}: 0x{X:0>16}\n", .{ u, x });
        return;
    }
    try std.testing.expectEqualSlices(u64, c.hashes, h);
}

test "golden: raycast.lnx scripted run (and a second run gives the same hashes)" {
    try check(&cases[0]);
    var a: [raycast_checkpoints.len]u64 = undefined;
    var b: [raycast_checkpoints.len]u64 = undefined;
    _ = (try run_case(&cases[0], &a)).?;
    _ = (try run_case(&cases[0], &b)).?;
    try std.testing.expectEqualSlices(u64, &a, &b);
}

test "golden: lynx-tests carts (cpu, memio, page-mode, math, timers, timers2, sprites1-5, sdoneack, refresh-rate)" {
    var ran: u32 = 0;
    for (cases[1..]) |*c| {
        check(c) catch |e| switch (e) {
            error.SkipZigTest => continue,
            else => return e,
        };
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}
