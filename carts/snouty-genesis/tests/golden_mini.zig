//! Golden run of Miniplanets (`roms/miniplanets.bin`, Sik, zlib): 600
//! Genesis frames (300 badge updates, 60/30) through the title screen and
//! into the first level, with the Z80 sound driver running. Prints one
//! hash over every rendered row, one over the `tone()` changes and one
//! over the console's memories and registers at the end. Print only: it
//! guards performance work (the frames and the state must not change),
//! so compare the `golden-mini:` lines before and after. Skips if the ROM
//! is absent.
const std = @import("std");
const core = @import("core");
const Md = core.Md;
const Pad = core.Pad;

const updates = 300;
const per_update = 2;

/// Input per update: Start through the title and the menus, then a walk
/// (`tools/scripts/m1_mini300.json` presses the same for badge-bench).
pub fn pad_at(u: u32) u16 {
    var p: u16 = 0;
    if ((u >= 100 and u <= 102) or (u >= 130 and u <= 132)) p |= Pad.start;
    if (u >= 180 and u <= 220) p |= Pad.right;
    if (u >= 200 and u <= 205) p |= Pad.b;
    if (u >= 225 and u <= 260) p |= Pad.left | Pad.c;
    if (u >= 265) p |= Pad.up;
    return p;
}

const Hasher = struct {
    hash: u64 = 0,
    rows: u32 = 0,

    fn on_line(ctx: *anyopaque, row: u8, line: [*]const u8, width: u16, cram: *const [64]u16) void {
        const h: *Hasher = @ptrCast(@alignCast(ctx));
        h.rows += 1;
        var w = std.hash.Wyhash.init(h.hash);
        w.update(&.{row});
        w.update(line[0..width]);
        w.update(std.mem.sliceAsBytes(cram));
        h.hash = w.final();
    }
};

const prefixes = [_][]const u8{ "", "carts/snouty-genesis/", "../", "../../" };
var rom_buf: [0x80000]u8 = undefined;

fn read_any(rel: []const u8, buf: []u8) ?[]u8 {
    for (prefixes) |pre| {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ pre, rel }) catch continue;
        return std.Io.Dir.cwd().readFile(std.testing.io, path, buf) catch continue;
    }
    return null;
}

fn state_hash(md: *const Md) u64 {
    var w = std.hash.Wyhash.init(0);
    w.update(&md.work_ram);
    w.update(&md.z80_ram);
    w.update(&md.vdp.vram);
    w.update(std.mem.sliceAsBytes(&md.vdp.cram));
    w.update(std.mem.sliceAsBytes(&md.vdp.vsram));
    w.update(&md.vdp.regs);
    w.update(std.mem.sliceAsBytes(&md.cpu.d));
    w.update(std.mem.sliceAsBytes(&md.cpu.a));
    const c = md.cpu;
    const z = md.z80;
    const words = [_]u32{
        c.pc,          c.get_sr(),             c.other_sp,  @intFromBool(c.stopped),
        z.pc,          z.sp,                   z.ix,        z.iy,
        z.a,           z.f,                    z.b,         z.c,
        z.d,           z.e,                    z.h,         z.l,
        z.r,           @intFromBool(z.halted), md.z80_bank, md.frame_count,
        md.m68k_carry, md.z80_carry,           md.vdp.line, md.dma_stall,
    };
    w.update(std.mem.sliceAsBytes(&words));
    return w.final();
}

test "golden-mini: Miniplanets 600 frames, frame, tone and state hashes" {
    const rom = read_any("roms/miniplanets.bin", &rom_buf) orelse return error.SkipZigTest;
    const md = try std.testing.allocator.create(Md);
    defer std.testing.allocator.destroy(md);
    md.init_in_place(core.RomSource.from_slice(rom));
    var h: Hasher = .{};
    md.line_sink = .{ .ctx = &h, .func = &Hasher.on_line };

    var tone_hash: u64 = 0;
    var tone_changes: u32 = 0;
    var last: ?core.Tone = md.tone();
    var u: u32 = 0;
    while (u < updates) : (u += 1) {
        var f: u32 = 0;
        while (f < per_update) : (f += 1) {
            md.step_frame(pad_at(u), f == per_update - 1);
            const t = md.tone();
            if (!std.meta.eql(t, last)) {
                last = t;
                tone_changes += 1;
                var w = std.hash.Wyhash.init(tone_hash);
                const rec = [_]u32{ md.frame_count, if (t) |x| x.hz else 0, if (t) |x| x.level else 0xFF };
                w.update(std.mem.sliceAsBytes(&rec));
                tone_hash = w.final();
            }
        }
    }
    try std.testing.expectEqual(@as(u32, updates * core.out_h), h.rows);
    std.debug.print("\ngolden-mini: frames 0x{X:0>16}, {d} tone changes 0x{X:0>16}, state 0x{X:0>16}\n", .{ h.hash, tone_changes, tone_hash, state_hash(md) });
    std.debug.print("golden-mini: 68000 pc {X:0>6} sr {X:0>4}, z80 pc {X:0>4}\n", .{ md.cpu.pc, md.cpu.get_sr(), md.z80.pc });
}
