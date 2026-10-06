//! The Sonic 1 DAC oracle and its check (PLAN.md "Sonic 1 DAC fake"):
//! runs Sonic 1 for a fixed script and writes `<out>/<name>.log` (every
//! trace point of core/probe.zig, one line each: event, frame, master
//! clock in the frame, address, value) and `<name>.wav` (the streamed
//! sound, u8 mono 44.1 kHz, core/sound.zig). Built by
//! `zig build s1dac-trace -Dcart=snouty-genesis`, which runs it:
//!
//! - `s1dac-oracle`: the full core (the real Z80 runs the game's driver)
//!   with the RAM cart's synthesis, Z80 writes placed at the Z80's time.
//!
//! The script: the
//! SEGA screen and the title (the chant, then the title music), Start at
//! frame 800 into Green Hill Zone, Sonic left standing; from frame 1700
//! every music id $81-$93 is queued in turn through the sound driver's
//! queue byte (work RAM F00A, what the game's PlaySound writes) for 480
//! frames each, then the SEGA sound ($E1) once more.
//!
//!     zig build s1dac-trace -Dcart=snouty-genesis -- ~/roms/genesis/sonic1.bin <out-dir>
//!
//! The ROM is read at run time and never copied; the outputs are derived
//! from it, so keep them out of the repository (a scratch directory). A
//! missing ROM prints a note and exits 0.
const std = @import("std");
const core = @import("core");
const name = @import("trace_options").name;
const Md = core.Md;
const probe = core.probe;
const sound = core.sound;

var io_mem: std.Io.Threaded = .init_single_threaded;
const io = io_mem.io();

var rom_buf: [1 << 20]u8 = undefined;
var md: Md = undefined;
var snd: sound.Sound = undefined;
var out_buf: [sound.max_samples]u8 = undefined;

/// Frames run; music ids queued from `music_from`, one per `music_len`.
const music_from: u32 = 1700;
const music_len: u32 = 480;
const music_ids = [_]u8{ 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0x8B, 0x8C, 0x8D, 0x8E, 0x8F, 0x90, 0x91, 0x92, 0x93, 0xE1 };
const frames: u32 = music_from + music_ids.len * music_len;
/// Work RAM index of the sound driver's queue byte (FFF00A).
const queue_byte: u16 = 0xF00A;

fn pad(frame: u32) u16 {
    return if (frame >= 800 and frame < 806) core.Pad.start else 0;
}

var log_w: *std.Io.Writer = undefined;

fn on_event(ev: probe.Event, frame: u32, t: u32, a: u32, v: u32) void {
    log_w.print("{s} {d} {d} {d} {d}\n", .{ @tagName(ev), frame, t, a, v }) catch @panic("log write");
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = try init.args.iterateAllocator(std.heap.page_allocator);
    defer args.deinit();
    _ = args.next();
    const rom_path = args.next() orelse usage();
    const out_dir = args.next() orelse usage();
    const cwd = std.Io.Dir.cwd();
    const rom = cwd.readFile(io, rom_path, &rom_buf) catch |err| {
        std.debug.print("{s}: {s}: {s}, skipped\n", .{ name, rom_path, @errorName(err) });
        return;
    };
    cwd.createDirPath(io, out_dir) catch {};
    var path_buf: [1024]u8 = undefined;

    const log_f = try cwd.createFile(io, try std.fmt.bufPrint(&path_buf, "{s}/{s}.log", .{ out_dir, name }), .{});
    defer log_f.close(io);
    var lbuf: [1 << 16]u8 = undefined;
    var lw = log_f.writer(io, &lbuf);
    log_w = &lw.interface;

    const wav_f = try cwd.createFile(io, try std.fmt.bufPrint(&path_buf, "{s}/{s}.wav", .{ out_dir, name }), .{});
    defer wav_f.close(io);
    var wbuf: [1 << 16]u8 = undefined;
    var ww = wav_f.writer(io, &wbuf);
    const w = &ww.interface;
    // The header's sizes are patched at the end.
    try write_wav_header(w, 0);

    md.init_in_place(core.RomSource.from_slice(rom));
    snd.init();
    md.snd = &snd;
    snd.set_render(&md, true);
    probe.hook = &on_event;

    var total: u32 = 0;
    var f: u32 = 0;
    while (f < frames) : (f += 2) {
        snd.begin_update(&out_buf);
        for (0..2) |i| {
            const fr = f + @as(u32, @intCast(i));
            if (fr >= music_from and (fr - music_from) % music_len == 0) {
                md.work_ram[queue_byte] = music_ids[(fr - music_from) / music_len];
            }
            md.step_frame(pad(fr), i == 1);
        }
        const s = snd.take();
        try w.writeAll(s);
        total += @intCast(s.len);
    }
    try w.flush();
    try log_w.flush();
    try ww.seekTo(0);
    try write_wav_header(w, total);
    try w.flush();
    std.debug.print("{s}: {d} frames, {d} samples, state hash {x:0>8}\n", .{ name, frames, total, md.state_hash() });
}

fn write_wav_header(w: *std.Io.Writer, samples: u32) !void {
    try w.writeAll("RIFF");
    try w.writeInt(u32, 36 + samples, .little);
    try w.writeAll("WAVEfmt ");
    try w.writeInt(u32, 16, .little);
    try w.writeInt(u16, 1, .little);
    try w.writeInt(u16, 1, .little);
    try w.writeInt(u32, 44100, .little);
    try w.writeInt(u32, 44100, .little);
    try w.writeInt(u16, 1, .little);
    try w.writeInt(u16, 8, .little);
    try w.writeAll("data");
    try w.writeInt(u32, samples, .little);
}

fn usage() noreturn {
    std.debug.print("usage: zig build s1dac-trace -Dcart=snouty-genesis -- <sonic1.bin> <out-dir>\n", .{});
    std.process.exit(1);
}
