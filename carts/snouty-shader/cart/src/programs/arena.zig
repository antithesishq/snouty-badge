//! One shared 40 KB block for the programs' big state: only one program
//! runs at a time, so ECHO's two frame buffers, KALEIDO's angle/depth
//! tables and RIPPLE's distance table take turns (each `enter` rebuilds its
//! own). Keeps the cart's RAM well under the 307 KB window.
pub const size = 40 * 1024;
pub var bytes: [size]u8 align(4) = undefined;

pub fn as(comptime T: type) *T {
    comptime if (@sizeOf(T) > size) @compileError("arena too small");
    return @ptrCast(@alignCast(&bytes));
}
