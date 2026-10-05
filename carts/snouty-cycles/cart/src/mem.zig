//! The badge build's `memcpy` and `memset`. The cart builds ReleaseSmall (RAM headroom,
//! PLAN M2.1 Track F), and so does compiler_rt, whose ReleaseSmall
//! `memcpy` copies a byte at a time: the cart API's `.copy_forward`
//! present copies the 40 KB framebuffer with it every frame (2.6 ms of
//! a 3 ms frame; `memset` clears the History and the AI scratch). These
//! strong symbols (and the AEABI entry points LLVM calls on this target)
//! replace compiler_rt's weak ones: eight words a step when the pointers
//! are word aligned (the framebuffers, Worlds, keyframes), bytes
//! otherwise.
//!
//! The empty asm with a memory clobber in each loop keeps LLVM from
//! recognising the loop as a copy and calling `memcpy` from inside it.
const builtin = @import("builtin");

comptime {
    if (builtin.cpu.arch.isThumb()) {
        // LLVM lowers a copy to the AEABI entry points on this target.
        @export(&aeabi_memcpy, .{ .name = "__aeabi_memcpy", .linkage = .strong });
        @export(&aeabi_memcpy, .{ .name = "__aeabi_memcpy4", .linkage = .strong });
        @export(&aeabi_memcpy, .{ .name = "__aeabi_memcpy8", .linkage = .strong });
        @export(&memcpy, .{ .name = "memcpy", .linkage = .strong });
        @export(&aeabi_memset, .{ .name = "__aeabi_memset", .linkage = .strong });
        @export(&aeabi_memset, .{ .name = "__aeabi_memset4", .linkage = .strong });
        @export(&aeabi_memset, .{ .name = "__aeabi_memset8", .linkage = .strong });
        @export(&aeabi_memclr, .{ .name = "__aeabi_memclr", .linkage = .strong });
        @export(&aeabi_memclr, .{ .name = "__aeabi_memclr4", .linkage = .strong });
        @export(&aeabi_memclr, .{ .name = "__aeabi_memclr8", .linkage = .strong });
        @export(&memset, .{ .name = "memset", .linkage = .strong });
    }
}

fn aeabi_memcpy(noalias dest: [*]u8, noalias src: [*]const u8, len: usize) callconv(.{ .arm_aapcs = .{} }) void {
    _ = memcpy(dest, src, len);
}

fn memcpy(noalias dest: ?[*]u8, noalias src: ?[*]const u8, len: usize) callconv(.c) ?[*]u8 {
    @setRuntimeSafety(false);
    var d = dest.?;
    var s = src.?;
    var n = len;
    if ((@intFromPtr(d) | @intFromPtr(s)) & 3 == 0) {
        while (n >= 32) {
            const dw: [*]u32 = @ptrCast(@alignCast(d));
            const sw: [*]const u32 = @ptrCast(@alignCast(s));
            const w0 = sw[0];
            const w1 = sw[1];
            const w2 = sw[2];
            const w3 = sw[3];
            const w4 = sw[4];
            const w5 = sw[5];
            const w6 = sw[6];
            const w7 = sw[7];
            dw[0] = w0;
            dw[1] = w1;
            dw[2] = w2;
            dw[3] = w3;
            dw[4] = w4;
            dw[5] = w5;
            dw[6] = w6;
            dw[7] = w7;
            d += 32;
            s += 32;
            n -= 32;
            asm volatile ("" ::: .{ .memory = true });
        }
        while (n >= 4) {
            @as(*u32, @ptrCast(@alignCast(d))).* = @as(*const u32, @ptrCast(@alignCast(s))).*;
            d += 4;
            s += 4;
            n -= 4;
            asm volatile ("" ::: .{ .memory = true });
        }
    }
    while (n != 0) {
        d[0] = s[0];
        d += 1;
        s += 1;
        n -= 1;
        asm volatile ("" ::: .{ .memory = true });
    }
    return dest;
}

fn aeabi_memset(dest: [*]u8, len: usize, c: i32) callconv(.{ .arm_aapcs = .{} }) void {
    _ = memset(dest, c, len);
}

fn aeabi_memclr(dest: [*]u8, len: usize) callconv(.{ .arm_aapcs = .{} }) void {
    _ = memset(dest, 0, len);
}

fn memset(dest: ?[*]u8, c: i32, len: usize) callconv(.c) ?[*]u8 {
    @setRuntimeSafety(false);
    var d = dest.?;
    var n = len;
    const b: u8 = @truncate(@as(u32, @bitCast(c)));
    while (n != 0 and @intFromPtr(d) & 3 != 0) {
        d[0] = b;
        d += 1;
        n -= 1;
        asm volatile ("" ::: .{ .memory = true });
    }
    const v: u32 = @as(u32, b) * 0x01010101;
    while (n >= 16) {
        const dw: [*]u32 = @ptrCast(@alignCast(d));
        dw[0] = v;
        dw[1] = v;
        dw[2] = v;
        dw[3] = v;
        d += 16;
        n -= 16;
        asm volatile ("" ::: .{ .memory = true });
    }
    while (n != 0) {
        d[0] = b;
        d += 1;
        n -= 1;
        asm volatile ("" ::: .{ .memory = true });
    }
    return dest;
}
