//! Build-time host tool (carts/snouty-genesis/build.zig, PLAN.md M5 cut 3):
//! copies a ROM without its zero padding, for the RAM cart's embedded test
//! ROM. `roms/snouty-test.bin` is 16 KB of which the first 2.9 KB are code
//! and data and the rest is zero padding; the copy keeps everything up to
//! the last nonzero byte rounded up to the next whole KB (3 KB), saving
//! 13 KB of the RAM window. The margin matters: data may end in zero
//! bytes the program reads (cut at the last nonzero byte, the test ROM's
//! picture differs from the first frame on), and the bus reads FF past a
//! ROM's end, not 00. So this is only valid for a ROM that never reads its
//! padding past the margin: the shipped test ROM, checked by
//! `tests/ram_variant.zig` (its M1 golden run gives the same frames from
//! the copy as from the full ROM). The cart's build only runs it on that
//! ROM.
//!
//!     zig run carts/snouty-genesis/tools/trim_rom.zig -- in.bin out.bin
const std = @import("std");

var io_mem: std.Io.Threaded = .init_single_threaded;
const io = io_mem.io();

var buf: [1 << 20]u8 = undefined;

pub fn main(init: std.process.Init.Minimal) !void {
    var args = try init.args.iterateAllocator(std.heap.page_allocator);
    defer args.deinit();
    _ = args.next();
    const in_path = args.next() orelse usage();
    const out_path = args.next() orelse usage();
    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFile(io, in_path, &buf) catch |err| {
        std.debug.print("trim_rom: cannot read {s}: {s}\n", .{ in_path, @errorName(err) });
        std.process.exit(1);
    };
    const n = trimmed_len(data);
    const out = try cwd.createFile(io, out_path, .{});
    defer out.close(io);
    var wbuf: [4096]u8 = undefined;
    var fw = out.writer(io, &wbuf);
    try fw.interface.writeAll(data[0..n]);
    try fw.interface.flush();
}

/// Bytes kept: up to the last nonzero byte, rounded up to a whole KB.
pub const margin = 1024;

pub fn trimmed_len(data: []const u8) usize {
    var n = data.len;
    while (n > 0 and data[n - 1] == 0) n -= 1;
    return @min(data.len, std.mem.alignForward(usize, n, margin));
}

fn usage() noreturn {
    std.debug.print("usage: zig run carts/snouty-genesis/tools/trim_rom.zig -- <in.bin> <out.bin>\n", .{});
    std.process.exit(1);
}
