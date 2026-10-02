//! boot: cross-check against the real boot ROM (SPEC.md 18.2, docs/BOOT.md).
//!
//! `tools/bootrom_crosscheck.py` runs Adrian's local boot ROM image on a
//! host 6502 against a cart and writes tests/roms/boot/<name>.boot.json
//! (gitignored). This test runs `post_boot` and `decrypt_frame` on the same
//! cart and compares: registers, MAPCTL, IODIR/IODAT/SYSCTL1, the cart
//! block and counter, the Mikey register values, the loader bytes at $0200
//! and the zero-page bytes $00-$07; and, for every later pass through the
//! ROM's frame decryptor ($FE4A), the bytes it wrote, the cart position and
//! the flags. Skipped when the JSON or the cart is absent.
//!
//! Not compared (not reproduced, docs/BOOT.md): the ROM's work buffers in
//! zero page ($08-$FF), the stack page, and the copy of its multiply
//! routine at $5000-$50FF.
const std = @import("std");
const boot = @import("core").boot;
const files = @import("testfiles.zig");

const JRegs = struct {
    a: u8,
    x: u8,
    y: u8,
    p: u8,
    sp: u8,
    pc: u16,
    mapctl: u8,
    iodir: u8,
    iodat: u8,
    sysctl1: u8,
    block: u8,
    counter: u32,
};

const JFirst = struct {
    regs: JRegs,
    mikey: std.json.Value,
    ram: []const std.json.Value,
};

const JFrame = struct {
    dest: u16,
    zp02: u8,
    entry: JRegs,
    exit: JRegs,
    bytes: []const u8,
};

const JBoot = struct {
    cart: []const u8,
    block_size: u32,
    first: JFirst,
    frames: []const JFrame,
    handover: ?JRegs,
};

var json_buf: [1 << 20]u8 = undefined;
var file_buf: [512 * 1024 + 64]u8 = undefined;
var ram: [65536]u8 = undefined;
var want_ram: [65536]u8 = undefined;

fn excluded(a: usize) bool {
    return (a >= 0x08 and a < 0x200) or (a >= 0x5000 and a < 0x5100);
}

fn hex_into(dst: []u8, hex: []const u8) !void {
    _ = try std.fmt.hexToBytes(dst, hex);
}

fn cross_check(name: []const u8) !void {
    var rel_buf: [128]u8 = undefined;
    const json_rel = try std.fmt.bufPrint(&rel_buf, "tests/roms/boot/{s}.boot.json", .{name});
    const text = files.read_cart_file(json_rel, &json_buf) orelse {
        std.debug.print("boot: cross-check {s} skipped: run tools/bootrom_crosscheck.py (docs/BOOT.md)\n", .{name});
        return error.SkipZigTest;
    };
    var cart_rel_buf: [128]u8 = undefined;
    const cart_rel = try std.fmt.bufPrint(&cart_rel_buf, "roms/lynx/{s}.lnx", .{name});
    const file = files.read_home_file(cart_rel, &file_buf) orelse return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(JBoot, gpa, text, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const j = parsed.value;

    const lay = boot.cart.parse(file, @intCast(file.len));
    try std.testing.expectEqual(boot.cart.Refusal.ok, lay.verdict);
    try std.testing.expectEqual(j.block_size, lay.block_size);
    const cart = boot.cart.Cart.from_slice(&lay, file);
    var first_reader: boot.CartReader = .{ .cart = &cart };
    const st = try boot.post_boot(&first_reader, &ram);
    try std.testing.expectEqual(st.cart_counter, first_reader.counter);

    // Registers and chip state at the first JMP $0200.
    const r = j.first.regs;
    try std.testing.expectEqual(r.pc, st.regs.pc);
    try std.testing.expectEqual(r.a, st.regs.a);
    try std.testing.expectEqual(r.x, st.regs.x);
    try std.testing.expectEqual(r.y, st.regs.y);
    try std.testing.expectEqual(r.p, st.regs.p);
    try std.testing.expectEqual(r.sp, st.regs.sp);
    try std.testing.expectEqual(r.mapctl, st.mapctl);
    try std.testing.expectEqual(r.iodir, st.iodir);
    try std.testing.expectEqual(r.iodat, st.iodat);
    try std.testing.expectEqual(r.sysctl1, st.sysctl1);
    try std.testing.expectEqual(r.block, st.cart_block);
    try std.testing.expectEqual(r.counter, st.cart_counter);

    // Mikey: the last value written per register, and the same set.
    var last: [256]?u8 = @splat(null);
    for (st.mikey_writes) |w| last[w.addr - 0xFD00] = w.value;
    var it = j.first.mikey.object.iterator();
    var n_regs: u32 = 0;
    while (it.next()) |e| {
        const addr = try std.fmt.parseInt(u16, e.key_ptr.*, 16);
        const v: u8 = @intCast(e.value_ptr.*.integer);
        try std.testing.expectEqual(@as(?u8, v), last[addr - 0xFD00]);
        n_regs += 1;
    }
    var n_ours: u32 = 0;
    for (last) |l| n_ours += @intFromBool(l != null);
    try std.testing.expectEqual(n_regs, n_ours);

    // RAM.
    @memset(&want_ram, 0);
    for (j.first.ram) |run| {
        const addr: usize = @intCast(run.array.items[0].integer);
        const hex = run.array.items[1].string;
        try hex_into(want_ram[addr .. addr + hex.len / 2], hex);
    }
    const end = 0x200 + @as(usize, st.frame.len);
    try std.testing.expectEqualSlices(u8, want_ram[0x200..end], ram[0x200..end]);
    try std.testing.expectEqualSlices(u8, want_ram[0..8], ram[0..8]);
    var skipped_nonzero: u32 = 0;
    for (0..65536) |a| {
        if (a >= 0x200 and a < end) continue;
        if (excluded(a)) {
            skipped_nonzero += @intFromBool(want_ram[a] != 0);
            continue;
        }
        if (want_ram[a] != ram[a]) {
            std.debug.print("boot: {s}: RAM {x:0>4} ROM {x:0>2} ours {x:0>2}\n", .{ name, a, want_ram[a], ram[a] });
            return error.TestUnexpectedResult;
        }
    }

    // Later passes through $FE4A.
    for (j.frames) |f| {
        @memset(&ram, 0);
        ram[boot.zp_transition] = f.zp02;
        ram[boot.zp_dest_lo] = @truncate(f.dest);
        ram[boot.zp_dest_hi] = @truncate(f.dest >> 8);
        var reader: boot.CartReader = .{ .cart = &cart, .block = f.entry.block, .counter = f.entry.counter };
        const res = try boot.decrypt_frame(&reader, &ram);
        // The host tool's counter is unmasked; the cart wires only the
        // block-size bits (Blue Lightning's second frame ends at 512 = 0).
        try std.testing.expectEqual(f.exit.counter & (cart.block_size - 1), reader.counter);
        try std.testing.expectEqual(f.exit.a, res.a);
        try std.testing.expectEqual(f.exit.x, res.x);
        try std.testing.expectEqual(f.exit.y, res.y);
        const mask = boot.flag_n | boot.flag_v | boot.flag_z | boot.flag_c;
        try std.testing.expectEqual(f.exit.p & mask, res.nvzc);
        try std.testing.expectEqual(f.exit.iodat, boot.frame_mikey_writes[2].value);
        var want: [256]u8 = undefined;
        const len = f.bytes.len / 2;
        try hex_into(want[0..len], f.bytes);
        try std.testing.expectEqual(res.len, @as(u16, @intCast(len)));
        const page = f.dest & 0xFF00;
        for (0..len) |i| {
            const a = page | ((f.dest + i) & 0xFF);
            try std.testing.expectEqual(want[i], ram[a]);
        }
    }
    std.debug.print("boot: {s}: matches the boot ROM (first frame {d} blocks, {d} later frame(s); {d} ROM work bytes in $08-$1FF/$5000 not compared; handover to {x:0>4})\n", .{ name, st.frame.blocks, j.frames.len, skipped_nonzero, if (j.handover) |h| h.pc else 0 });
}

test "boot: cross-check Hard Drivin' against the boot ROM (local)" {
    try cross_check("hard_drivin");
}

test "boot: cross-check Blue Lightning against the boot ROM (local)" {
    try cross_check("blue_lightning");
}
