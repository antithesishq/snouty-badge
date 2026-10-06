//! Where a sender's image bytes come from: a UF2 flattened on the fly
//! (lib/beam_slot.zig `Uf2`) or an image that is already flat (the
//! received slot, mapped at 0x11000000 on the badge).
const slot = @import("beam_slot");

pub fn Source(comptime File: type) type {
    return union(enum) {
        uf2: slot.Uf2(File),
        flat: []const u8,

        pub fn read(s: *const @This(), offset: u32, dst: []u8) void {
            switch (s.*) {
                .uf2 => |*u| u.read(offset, dst),
                .flat => |bytes| @memcpy(dst, bytes[offset..][0..dst.len]),
            }
        }
    };
}
