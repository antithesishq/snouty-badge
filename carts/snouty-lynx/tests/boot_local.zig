//! boot: post_boot on Adrian's local commercial dumps (~/roms/lynx/, never
//! in the repo; skipped when absent). Checks the decrypted loader is
//! plausible 65SC02 code: its length matches the block-count byte, and a
//! straight-line walk from $0200 meets only defined opcodes and ends in a
//! JMP to the ROM's frame decryptor or into RAM.
const std = @import("std");
const boot = @import("boot");
const files = @import("testfiles.zig");

var file_buf: [512 * 1024 + 64]u8 = undefined;
var ram: [65536]u8 = undefined;

fn check(rel: []const u8, want_blocks: u8, want_jmp: u16) !void {
    const file = files.read_home_file(rel, &file_buf) orelse return error.SkipZigTest;
    const cart = try boot.Cart.from_file(file);
    try std.testing.expect(cart.header == null);
    try std.testing.expectEqual(@as(u32, 512), cart.block_size);
    const st = try boot.post_boot(&cart, &ram);
    const count = file[0];
    try std.testing.expectEqual(@as(u8, 0) -% count, st.frame.blocks);
    try std.testing.expectEqual(want_blocks, st.frame.blocks);
    try std.testing.expectEqual(@as(u16, st.frame.blocks) * 50, st.frame.len);
    try std.testing.expectEqual(1 + @as(u32, st.frame.blocks) * 51, st.cart_counter);
    // Walk the code.
    var pc: u16 = 0x200;
    var n: u32 = 0;
    const end: u16 = 0x200 + st.frame.len;
    while (true) : (n += 1) {
        try std.testing.expect(pc < end);
        const op = ram[pc];
        const len = files.op_len(op) orelse {
            std.debug.print("{s}: undefined opcode {x:0>2} at {x:0>4}\n", .{ rel, op, pc });
            return error.TestUnexpectedResult;
        };
        if (op == 0x4C) {
            const target = @as(u16, ram[pc + 1]) | @as(u16, ram[pc + 2]) << 8;
            try std.testing.expectEqual(want_jmp, target);
            break;
        }
        try std.testing.expect(op != 0x00 and op != 0x60 and op != 0x40); // no BRK/RTS/RTI first
        pc += len;
    }
    try std.testing.expect(n >= 4);
}

test "boot: Hard Drivin' loader (local dump)" {
    // 3 blocks; the stage sets $05/$06 to $0300 and jumps back into the ROM's
    // frame decryptor for the second frame.
    try check("roms/lynx/hard_drivin.lnx", 3, boot.entry_decrypt_frame);
}

test "boot: Blue Lightning loader (local dump)" {
    try check("roms/lynx/blue_lightning.lnx", 5, boot.entry_decrypt_frame);
}
