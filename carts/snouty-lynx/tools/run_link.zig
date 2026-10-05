//! Host tool: 2-8 Lynx consoles on one ComLynx bus, headless
//! (core/comlynx_virtual.zig; docs/COMLYNX.md).
//!
//!     zig build run-lynx-link -- <rom> <consoles> <updates> <outdir>
//!         [--mode wire|relay|timestamped] [--latency-us N] [--jitter-us N]
//!         [--delay-us N] [--slice-us N] [--batch frame|burst|slice]
//!         [--script I FILE] [--rom I FILE] [--every N] [--at U,U,...]
//!         [--quiet] [--seed N] [--stagger F]
//!
//! from the repository root. Every console runs `<rom>` (or `--rom I` its
//! own) with its own input script (`--script I`, console I, 0-based; the
//! same JSON as run-lynx; default none) through the cart's input model.
//! The cart's splash is skipped (each console starts in its game). Prints a line
//! per update and console and the bus counters; writes
//! `<outdir>/cI_UUUU.ppm` every N updates (default 60), at `--at` updates
//! and at the end. `--stagger F`: console i is switched on F x i frames
//! after console 0 (default 7: consoles started together mirror each
//! other).
const std = @import("std");
const core = @import("core");
const runner = @import("runner");
const virt = core.comlynx_virtual;

var io_mem: std.Io.Threaded = .init_single_threaded;
const io = io_mem.io();

var consoles: [virt.max_consoles]core.Lynx = undefined;
var roms: [virt.max_consoles][512 * 1024 + 64]u8 = undefined;
var script_buf: [1 << 16]u8 = undefined;
var ppm_buf: [runner.ppm_size]u8 = undefined;
var bus: virt.VirtualBus = undefined;

fn usage() noreturn {
    std.debug.print("usage: zig build run-lynx-link -- <rom> <consoles> <updates> <outdir> [--mode wire|relay|timestamped] [--latency-us N] [--jitter-us N] [--delay-us N] [--slice-us N] [--batch frame|burst|slice] [--script I FILE] [--rom I FILE] [--every N] [--at U,U,...] [--quiet] [--seed N]\n", .{});
    std.process.exit(2);
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("run-lynx-link: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn int(s: ?[]const u8) u64 {
    return std.fmt.parseInt(u64, s orelse usage(), 10) catch usage();
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var args = try init.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    const rom_path = args.next() orelse usage();
    const n: usize = @intCast(int(args.next()));
    if (n < 1 or n > virt.max_consoles) usage();
    const updates: u32 = @intCast(int(args.next()));
    const out_dir = args.next() orelse usage();
    var cfg: virt.Config = .{};
    var every: u32 = 60;
    var at: std.ArrayList(u32) = .empty;
    var quiet = false;
    var stagger: u32 = 7;
    var scripts: [virt.max_consoles]?[]const u8 = @splat(null);
    var rom_paths: [virt.max_consoles][]const u8 = @splat(rom_path);
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--mode")) {
            cfg.mode = std.meta.stringToEnum(virt.Mode, args.next() orelse usage()) orelse usage();
        } else if (std.mem.eql(u8, a, "--batch")) {
            cfg.batch = std.meta.stringToEnum(virt.Batch, args.next() orelse usage()) orelse usage();
        } else if (std.mem.eql(u8, a, "--latency-us")) {
            cfg.latency = int(args.next()) * 16;
        } else if (std.mem.eql(u8, a, "--jitter-us")) {
            cfg.jitter = int(args.next()) * 16;
        } else if (std.mem.eql(u8, a, "--delay-us")) {
            cfg.delay = int(args.next()) * 16;
        } else if (std.mem.eql(u8, a, "--slice-us")) {
            cfg.slice = @intCast(int(args.next()) * 16);
        } else if (std.mem.eql(u8, a, "--seed")) {
            cfg.seed = int(args.next());
        } else if (std.mem.eql(u8, a, "--script")) {
            const i = int(args.next());
            if (i >= n) usage();
            scripts[i] = args.next() orelse usage();
        } else if (std.mem.eql(u8, a, "--rom")) {
            const i = int(args.next());
            if (i >= n) usage();
            rom_paths[i] = args.next() orelse usage();
        } else if (std.mem.eql(u8, a, "--every")) {
            every = @intCast(int(args.next()));
        } else if (std.mem.eql(u8, a, "--at")) {
            var it = std.mem.splitScalar(u8, args.next() orelse usage(), ',');
            while (it.next()) |u| try at.append(gpa, std.fmt.parseInt(u32, u, 10) catch usage());
        } else if (std.mem.eql(u8, a, "--stagger")) {
            stagger = @intCast(int(args.next()));
        } else if (std.mem.eql(u8, a, "--quiet")) {
            quiet = true;
        } else usage();
    }

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, out_dir) catch |e| die("cannot create {s}: {s}", .{ out_dir, @errorName(e) });
    var controls: [virt.max_consoles][]u16 = undefined;
    var fes: [virt.max_consoles]runner.Frontend = @splat(.{ .running = true });
    var ptrs: [virt.max_consoles]*core.Lynx = undefined;
    for (0..n) |i| {
        const rom = cwd.readFile(io, rom_paths[i], &roms[i]) catch |e| die("cannot read {s}: {s}", .{ rom_paths[i], @errorName(e) });
        const cart = switch (runner.cart_from_file(rom)) {
            .ok => |c| c,
            .refused => |r| die("{s}: refused: {s}", .{ rom_paths[i], r.text() }),
        };
        consoles[i].init_in_place(cart);
        ptrs[i] = &consoles[i];
        controls[i] = try gpa.alloc(u16, updates);
        if (scripts[i]) |s| {
            const json = cwd.readFile(io, s, &script_buf) catch |e| die("cannot read {s}: {s}", .{ s, @errorName(e) });
            runner.parse_script(gpa, json, controls[i]) catch |e| die("{s}: {s}", .{ s, @errorName(e) });
        } else @memset(controls[i], 0);
    }
    bus.init(cfg, ptrs[0..n]);
    for (0..n) |i| bus.power_on_at(i, stagger * @as(u32, @intCast(i)));
    std.debug.print("run-lynx-link: {d} consoles, mode {s}, latency {d} us, jitter {d} us, delay {d} us, slice {d} us, batch {s}\n", .{
        n, @tagName(cfg.mode), cfg.latency / 16, cfg.jitter / 16, cfg.delay / 16, cfg.slice / 16, @tagName(cfg.batch),
    });

    var out_buf: [4096]u8 = undefined;
    var ow = std.Io.File.stdout().writer(io, &out_buf);
    const w = &ow.interface;
    var pads: [virt.max_consoles]u16 = @splat(0);
    var u: u32 = 0;
    while (u < updates) : (u += 1) {
        // Console i's script counts from its own power-on; the cart's
        // splash is skipped (the consoles start in the game).
        for (0..n) |i| {
            const k = stagger * @as(u32, @intCast(i));
            if (u < k) continue;
            pads[i] = fes[i].update(controls[i][u - k]) orelse 0;
        }
        bus.step_frame(pads[0..n]);
        const all = true;
        const last = u + 1 == updates;
        var want = last or (every != 0 and u % every == 0);
        for (at.items) |x| want = want or x == u;
        if (!quiet or want) {
            for (0..n) |i| {
                const l = &consoles[i];
                const p = &bus.ports[i];
                try w.print("update {d} c{d} hash {X:0>16} pad {X:0>3} pc {X:0>4} sent {d} latched {d} ferr {d} perr {d} ovr {d}{s}\n", .{
                    u, i, runner.frame_hash(l.frame()), pads[i], l.cpu.regs.pc, p.sent, p.latched, p.framing_errors, p.parity_errors, p.overruns, if (all) "" else " (splash)",
                });
            }
        }
        if (want) {
            for (0..n) |i| {
                runner.ppm(consoles[i].frame(), &ppm_buf);
                var name_buf: [512]u8 = undefined;
                const name = try std.fmt.bufPrint(&name_buf, "{s}/c{d}_{d:0>4}.ppm", .{ out_dir, i, u });
                cwd.writeFile(io, .{ .sub_path = name, .data = &ppm_buf }) catch |e| die("cannot write {s}: {s}", .{ name, @errorName(e) });
            }
        }
    }
    const s = bus.stats;
    try w.print("summary: sent {d} delivered {d} late {d} (worst {d} us) refused {d} dropped {d} batches {d}\n", .{ s.sent, s.delivered, s.late, s.worst_late / 16, s.refused, s.dropped, s.batches });
    try w.flush();
}
