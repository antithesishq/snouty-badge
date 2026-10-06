//! `zig build beam-slot -- in.uf2 out.bin`: the slot area bytes Snouty Beam
//! writes for a cart (fork/CART_TRANSFER.md slot format v1): the 4 KB
//! header sector (96-byte header, then 0xFF) and the image. The fork's
//! host tests load the output as their fixture.
//!
//! `zig build beam-slot -- --info a.uf2 b.uf2 ...`: one line per UF2, its
//! image size against the 252 KB a slot holds, or why it cannot be beamed.
const std = @import("std");
const slot = @import("beam_slot");

var io_mem: std.Io.Threaded = .init_single_threaded;
const io = io_mem.io();

var uf2_buf: [4 * 1024 * 1024]u8 = undefined;
var area: [slot.default_area_size + 512 * 1024]u8 = undefined;

fn usage() noreturn {
    std.debug.print("usage: zig build beam-slot -- <in.uf2> <out.bin>\n       zig build beam-slot -- --info <a.uf2> [b.uf2 ...]\n", .{});
    std.process.exit(2);
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("beam-slot: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var args = try init.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    const first = args.next() orelse usage();
    const cwd = std.Io.Dir.cwd();
    const cap = slot.capacity(slot.default_area_size);

    if (std.mem.eql(u8, first, "--info")) {
        while (args.next()) |path| {
            const bytes = cwd.readFile(io, path, &uf2_buf) catch |e| die("cannot read {s}: {s}", .{ path, @errorName(e) });
            const base = std.fs.path.basename(path);
            const u = slot.Uf2(slot.SliceFile).open(.{ .bytes = bytes }) catch |e| {
                std.debug.print("{s:<28} {d:>5} KB uf2   -        {s}\n", .{ base, bytes.len / 1024, @errorName(e) });
                continue;
            };
            const kb = (u.info.image_len + 1023) / 1024;
            const verdict = if (u.info.image_len <= cap) "fits" else "TooBig";
            std.debug.print("{s:<28} {d:>5} KB uf2 {d:>4} KB image {s} (load 0x{X:0>8})\n", .{ base, bytes.len / 1024, kb, verdict, u.info.load_addr });
        }
        return;
    }

    const in_path = first;
    const out_path = args.next() orelse usage();
    const bytes = cwd.readFile(io, in_path, &uf2_buf) catch |e| die("cannot read {s}: {s}", .{ in_path, @errorName(e) });
    const u = slot.Uf2(slot.SliceFile).open(.{ .bytes = bytes }) catch |e| die("{s}: not beamable: {s}", .{ in_path, @errorName(e) });
    if (u.info.image_len > cap) die("{s}: image {d} bytes, a slot holds {d}", .{ in_path, u.info.image_len, cap });
    const n = slot.write_area(&u, std.fs.path.basename(in_path), &area) catch die("image too large", .{});
    // The bytes must be a valid, launchable slot by this file's own rules.
    var whole: [slot.default_area_size]u8 = @splat(0xFF);
    @memcpy(whole[0..n], area[0..n]);
    if (!slot.launchable(&whole)) die("internal: output is not a launchable slot", .{});
    cwd.writeFile(io, .{ .sub_path = out_path, .data = area[0..n] }) catch |e| die("cannot write {s}: {s}", .{ out_path, @errorName(e) });
    const h = slot.parse(area[0..slot.header_size], slot.default_area_size) catch unreachable;
    std.debug.print("{s}: \"{s}\" load 0x{X:0>8} image {d} bytes crc 0x{X:0>8} descriptor +0x{X} -> {s} ({d} bytes)\n", .{
        in_path, h.name(), h.load_addr, h.image_len, h.image_crc32, h.descriptor_offset, out_path, n,
    });
}
