//! `zig build marquee-lynx -- <out.ppm> [--frame N] [--file] <title>...`:
//! the drawn marquee (frontend/marquee_art.zig) for each title, stacked
//! top to bottom with a black row between, as a binary PPM at 1:1. Titles
//! go through the same clean-up as on the badge (`--file`: as file names,
//! `-` read as a space). `--frame N` picks the glint's moment (frame 12 is
//! mid-sweep; the default, 100, shows none).
const std = @import("std");
const art = @import("marquee_art");
const os_font = @import("os_font");

var io_mem: std.Io.Threaded = .init_single_threaded;
const io = io_mem.io();

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var it = try init.args.iterateAllocator(gpa);
    defer it.deinit();
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    while (it.next()) |a| try args.append(gpa, a);
    if (args.items.len < 3) {
        std.debug.print("usage: marquee-lynx <out.ppm> [--frame N] [--file] <title>...\n", .{});
        return error.Usage;
    }
    const argv = args.items;
    const glyphs = art.glyphs_from_rows(os_font.font[0..art.glyph_count]);
    var frame: u32 = 100;
    var from_file = false;
    var titles: std.ArrayList([]const u8) = .empty;
    defer titles.deinit(gpa);
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--frame") and i + 1 < argv.len) {
            i += 1;
            frame = try std.fmt.parseInt(u32, argv[i], 10);
        } else if (std.mem.eql(u8, argv[i], "--file")) {
            from_file = true;
        } else try titles.append(gpa, argv[i]);
    }

    const n = titles.items.len;
    const out_h = n * (art.h + 1);
    var pixels = try gpa.alloc(u8, art.w * out_h * 3);
    defer gpa.free(pixels);
    @memset(pixels, 0);
    for (titles.items, 0..) |t, k| {
        var buf: [art.max_title]u8 = undefined;
        const title = art.clean_title(t, from_file, &buf);
        const l = art.layout(title, &glyphs);
        const c = art.colors(art.schemes[art.scheme_index(title)], &l);
        var img: [art.h][art.w]u32 = undefined;
        art.render_rgb(&l, &c, frame, &img);
        for (0..art.h) |y| for (0..art.w) |x| {
            const o = ((k * (art.h + 1) + y) * art.w + x) * 3;
            const v = img[y][x];
            pixels[o] = @truncate(v >> 16);
            pixels[o + 1] = @truncate(v >> 8);
            pixels[o + 2] = @truncate(v);
        };
        std.debug.print("{s} -> \"{s}\" scheme {d}, {d} line(s)\n", .{ t, title, art.scheme_index(title), l.lines });
    }

    const head = try std.fmt.allocPrint(gpa, "P6\n{d} {d}\n255\n", .{ art.w, out_h });
    const ppm = try std.mem.concat(gpa, u8, &.{ head, pixels });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = argv[1], .data = ppm });
}
