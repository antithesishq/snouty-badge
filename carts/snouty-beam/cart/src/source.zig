//! Where a sender's bytes come from: a UF2 flattened on the fly into its
//! RAM image (lib/beam_slot.zig `Uf2`, slot mode), an image that is already
//! flat (the received slot, mapped at 0x11000000 on the badge), or a file
//! byte for byte (file mode). `File` gives `size()` and `block(i)`, the
//! i-th 512 bytes (a UF2 file is whole 512-byte blocks).
const slot = @import("beam_slot");

pub fn Source(comptime File: type) type {
    return union(enum) {
        uf2: slot.Uf2(File),
        flat: []const u8,
        file: File,

        pub fn read(s: *const @This(), offset: u32, dst: []u8) void {
            switch (s.*) {
                .uf2 => |*u| u.read(offset, dst),
                .flat => |bytes| @memcpy(dst, bytes[offset..][0..dst.len]),
                .file => |*f| {
                    var at = offset;
                    var n: usize = 0;
                    while (n < dst.len) {
                        const off = at % slot.uf2_block_size;
                        const take = @min(slot.uf2_block_size - off, dst.len - n);
                        @memcpy(dst[n..][0..take], f.block(at / slot.uf2_block_size)[off..][0..take]);
                        n += take;
                        at += @intCast(take);
                    }
                },
            }
        }
    };
}
