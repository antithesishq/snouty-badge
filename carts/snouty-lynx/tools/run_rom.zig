//! Host tool: run a Lynx ROM headless through the real core.
//!
//!     zig build run-lynx -- <rom> <script.json|-> <updates> <outdir>
//!         [--every N] [--at U,U,...] [--idle-sleep] [--quiet] [--wav FILE]
//!
//! from the repository root (paths are relative to it). `<updates>` badge
//! updates are run with the preview/badge-bench input script (`-`: none,
//! the splash then runs out by itself at update 72) through the cart's
//! input model (tests/runner.zig: splash skip, Select tap = Option 1).
//! Every update prints a line `update U frame F hash H pad P` plus the
//! diagnostics (ticks, instructions, IRQs taken, Suzy pixels, sleep ticks,
//! display frames, PC); `<outdir>/frame_UUUU.ppm` is written every `N`
//! updates (default 30), at each `--at` update and at the last one.
//! `--idle-sleep` selects the contract's CPUSLEEP model (core/lynx.zig).
//! `--quiet` prints only the updates that write an image and the summary.
//! `--wav FILE` writes the sound of the run (`Lynx.audio_out` after every
//! update, `core.audio.samples_per_frame` samples each; silence for the
//! splash updates that do not step the core) as an 8-bit unsigned mono
//! WAV at `core.audio.sample_rate` (docs/AUDIO.md).
//!
//! The hashes are the golden test's (tests/golden.zig), so a run here
//! gives the values to pin there.
const std = @import("std");
const core = @import("core");
const runner = @import("runner");

var io_mem: std.Io.Threaded = .init_single_threaded;
const io = io_mem.io();

var lynx: core.Lynx = undefined;
var rom_buf: [512 * 1024 + 64]u8 = undefined;
var script_buf: [1 << 16]u8 = undefined;
var ppm_buf: [runner.ppm_size]u8 = undefined;

fn usage() noreturn {
    std.debug.print("usage: zig build run-lynx -- <rom> <script.json|-> <updates> <outdir> [--every N] [--at U,U,...] [--idle-sleep] [--quiet] [--wav FILE]\n", .{});
    std.process.exit(2);
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("run-lynx: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var args = try init.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    const rom_path = args.next() orelse usage();
    const script_path = args.next() orelse usage();
    const updates_s = args.next() orelse usage();
    const out_dir = args.next() orelse usage();
    var every: u32 = 30;
    var at: std.ArrayList(u32) = .empty;
    var idle_sleep = false;
    var quiet = false;
    var wav_path: ?[]const u8 = null;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--every")) {
            every = std.fmt.parseInt(u32, args.next() orelse usage(), 10) catch usage();
        } else if (std.mem.eql(u8, a, "--at")) {
            var it = std.mem.splitScalar(u8, args.next() orelse usage(), ',');
            while (it.next()) |u| try at.append(gpa, std.fmt.parseInt(u32, u, 10) catch usage());
        } else if (std.mem.eql(u8, a, "--idle-sleep")) {
            idle_sleep = true;
        } else if (std.mem.eql(u8, a, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, a, "--wav")) {
            wav_path = args.next() orelse usage();
        } else usage();
    }
    const updates = std.fmt.parseInt(u32, updates_s, 10) catch usage();

    const cwd = std.Io.Dir.cwd();
    const rom = cwd.readFile(io, rom_path, &rom_buf) catch |e| die("cannot read {s}: {s}", .{ rom_path, @errorName(e) });
    const controls = try gpa.alloc(u16, updates);
    if (std.mem.eql(u8, script_path, "-")) {
        @memset(controls, 0);
    } else {
        const json = cwd.readFile(io, script_path, &script_buf) catch |e| die("cannot read {s}: {s}", .{ script_path, @errorName(e) });
        runner.parse_script(gpa, json, controls) catch |e| die("{s}: {s}", .{ script_path, @errorName(e) });
    }
    const cart = switch (runner.cart_from_file(rom)) {
        .ok => |c| c,
        .refused => |r| die("{s}: refused: {s}", .{ rom_path, r.text() }),
    };
    cwd.createDirPath(io, out_dir) catch |e| die("cannot create {s}: {s}", .{ out_dir, @errorName(e) });

    var run = runner.Run.init(&lynx, cart, controls);
    lynx.idle_sleep = idle_sleep;
    const lay = core.cart.parse(rom, @intCast(rom.len));
    std.debug.print("run-lynx: {s}: \"{s}\" {d} B, {d} B blocks, {s}; boot {s}\n", .{
        rom_path,                                         lay.title(), rom.len, lay.block_size, if (lay.headered) "headered" else "headerless",
        if (lynx.boot_error) |e| @errorName(e) else "ok",
    });

    const spf = core.audio.samples_per_frame;
    const wav: ?[]u8 = if (wav_path != null) try gpa.alloc(u8, wav_header_size + @as(usize, updates) * spf) else null;

    var out_buf: [4096]u8 = undefined;
    var ow = std.Io.File.stdout().writer(io, &out_buf);
    const w = &ow.interface;
    var images: u32 = 0;
    while (!run.done()) {
        const st = run.step();
        const last = st.update + 1 == updates;
        var want = last or (every != 0 and st.update % every == 0);
        for (at.items) |u| want = want or u == st.update;
        if (!quiet or want) {
            try w.print("update {d} frame {d} hash {X:0>16} pad {X:0>3} ticks {d} instr {d} irqs {d} px {d} sleep {d} dframes {d} pc {X:0>4}{s}\n", .{
                st.update,      lynx.frame_count,    st.hash,          st.pad,              lynx.time(),      lynx.instr_count(),
                lynx.irq_count, lynx.pixels_drawn(), lynx.sleep_ticks, lynx.display_frames, lynx.cpu.regs.pc, if (st.stepped) "" else " (splash)",
            });
        }
        if (wav) |buf| {
            const dst = buf[wav_header_size + @as(usize, st.update) * spf ..][0..spf];
            if (st.stepped) @memcpy(dst, &lynx.audio_out) else @memset(dst, core.audio.silence);
        }
        if (want) {
            runner.ppm(lynx.frame(), &ppm_buf);
            var name_buf: [512]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "{s}/frame_{d:0>4}.ppm", .{ out_dir, st.update });
            cwd.writeFile(io, .{ .sub_path = name, .data = &ppm_buf }) catch |e| die("cannot write {s}: {s}", .{ name, @errorName(e) });
            images += 1;
        }
    }
    if (wav) |buf| {
        wav_header(buf[0..wav_header_size], @intCast(buf.len - wav_header_size));
        cwd.writeFile(io, .{ .sub_path = wav_path.?, .data = buf }) catch |e| die("cannot write {s}: {s}", .{ wav_path.?, @errorName(e) });
        std.debug.print("run-lynx: wrote {s}: {d} samples, {d} Hz, 8-bit unsigned mono\n", .{ wav_path.?, buf.len - wav_header_size, core.audio.sample_rate });
    }
    try w.print("summary: {d} updates, {d} frames stepped, {d} images in {s}, boot {s}, instr {d}, irqs {d}, sprite runs {d}, px {d}, sleep ticks {d}, display frames {d}, rom resets {d}\n", .{
        updates,                                          lynx.frame_count,   images,              out_dir,
        if (lynx.boot_error) |e| @errorName(e) else "ok", lynx.instr_count(), lynx.irq_count,      lynx.sprite_runs,
        lynx.pixels_drawn(),                              lynx.sleep_ticks,   lynx.display_frames, lynx.rom_resets,
    });
    try w.flush();
}

const wav_header_size = 44;

/// A canonical 44-byte RIFF/WAVE header for `data_len` bytes of 8-bit
/// unsigned mono PCM at `core.audio.sample_rate`.
fn wav_header(h: *[wav_header_size]u8, data_len: u32) void {
    const rate = core.audio.sample_rate;
    @memcpy(h[0..4], "RIFF");
    std.mem.writeInt(u32, h[4..8], 36 + data_len, .little);
    @memcpy(h[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, h[16..20], 16, .little); // fmt chunk size
    std.mem.writeInt(u16, h[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, h[22..24], 1, .little); // mono
    std.mem.writeInt(u32, h[24..28], rate, .little);
    std.mem.writeInt(u32, h[28..32], rate, .little); // byte rate: 1 byte per sample
    std.mem.writeInt(u16, h[32..34], 1, .little); // block align
    std.mem.writeInt(u16, h[34..36], 8, .little); // bits per sample
    @memcpy(h[36..40], "data");
    std.mem.writeInt(u32, h[40..44], data_len, .little);
}
