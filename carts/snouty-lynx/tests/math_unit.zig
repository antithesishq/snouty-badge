//! math: Suzy math unit tests (M1 Track B): random operands against Zig
//! integer arithmetic, with the hardware's documented sign quirks
//! (docs/SUZY.md "Math unit").
const std = @import("std");
const core = @import("core");
const Suzy = core.suzy.Suzy;

const D = 0x52;
const C = 0x53;
const B = 0x54;
const A = 0x55;
const P = 0x56;
const N = 0x57;
const H = 0x60;
const G = 0x61;
const F = 0x62;
const E = 0x63;
const M = 0x6C;
const L = 0x6D;
const K = 0x6E;
const J = 0x6F;
const sprsys = 0x92;

fn mul(s: *Suzy, ab: u16, cd: u16) void {
    s.write(D, @truncate(cd));
    s.write(C, @truncate(cd >> 8));
    s.write(B, @truncate(ab));
    s.write(A, @truncate(ab >> 8));
}

fn div(s: *Suzy, dividend: u32, np: u16) void {
    s.write(P, @truncate(np));
    s.write(N, @truncate(np >> 8));
    s.write(H, @truncate(dividend));
    s.write(G, @truncate(dividend >> 8));
    s.write(F, @truncate(dividend >> 16));
    s.write(E, @truncate(dividend >> 24));
}

fn rd32(s: *const Suzy, lo: u8) u32 {
    return @as(u32, s.read(lo)) | (@as(u32, s.read(lo + 1)) << 8) |
        (@as(u32, s.read(lo + 2)) << 16) | (@as(u32, s.read(lo + 3)) << 24);
}

fn efgh(s: *const Suzy) u32 {
    return rd32(s, H);
}

fn jklm(s: *const Suzy) u32 {
    return rd32(s, M);
}

fn abcd(s: *const Suzy) u32 {
    return rd32(s, D);
}

fn warning(s: *const Suzy) bool {
    return s.read(sprsys) & 0x40 != 0;
}

/// The value the signed multiplier sees: two's complement, except that
/// $8000 counts as +32768 (the hardware tests bit 15 of value - 1).
fn hw_signed(v: u16) i64 {
    if (v == 0x8000) return 32768;
    return @as(i16, @bitCast(v));
}

/// Operands biased toward the edge cases.
fn operand(rng: std.Random) u16 {
    return switch (rng.uintLessThan(u8, 8)) {
        0 => 0,
        1 => 0x8000,
        2 => 0xFFFF,
        3 => 1,
        4 => rng.int(u8),
        else => rng.int(u16),
    };
}

test "math: unsigned multiply against Zig" {
    var s: Suzy = .{};
    var prng = std.Random.DefaultPrng.init(0x5512);
    const rng = prng.random();
    for (0..20000) |_| {
        const a = operand(rng);
        const c = operand(rng);
        mul(&s, a, c);
        try std.testing.expectEqual(@as(u32, a) * @as(u32, c), efgh(&s));
        // Inputs are not disturbed by an unsigned multiply.
        try std.testing.expectEqual(a, @as(u16, s.read(B)) | (@as(u16, s.read(A)) << 8));
        try std.testing.expect(!warning(&s));
        try std.testing.expectEqual(@as(u8, 0), s.read(sprsys) & 0x80);
    }
}

test "math: signed multiply against Zig, $8000 counted positive" {
    var s: Suzy = .{};
    s.write(sprsys, 0x80);
    var prng = std.Random.DefaultPrng.init(0x516);
    const rng = prng.random();
    for (0..20000) |_| {
        const a = operand(rng);
        const c = operand(rng);
        mul(&s, a, c);
        const want: i64 = hw_signed(a) * hw_signed(c);
        try std.testing.expectEqual(@as(u32, @truncate(@as(u64, @bitCast(want)))), efgh(&s));
    }
    // Plain cases.
    mul(&s, @bitCast(@as(i16, -3)), 7);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -21))), efgh(&s));
    mul(&s, @bitCast(@as(i16, -300)), @bitCast(@as(i16, -200)));
    try std.testing.expectEqual(@as(u32, 60000), efgh(&s));
    // $8000 x -1 = -32768 on this hardware (it is +32768 x -1).
    mul(&s, 0x8000, 0xFFFF);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -32768))), efgh(&s));
    // The operands are left as magnitudes in their registers.
    mul(&s, @bitCast(@as(i16, -5)), @bitCast(@as(i16, -6)));
    try std.testing.expectEqual(@as(u8, 5), s.read(B));
    try std.testing.expectEqual(@as(u8, 0), s.read(A));
    try std.testing.expectEqual(@as(u8, 6), s.read(D));
    try std.testing.expectEqual(@as(u8, 0), s.read(C));
}

test "math: signed multiply keeps a stale sign on a low-byte-only write" {
    var s: Suzy = .{};
    s.write(sprsys, 0x80);
    mul(&s, 3, @bitCast(@as(i16, -2)));
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -6))), efgh(&s));
    // Writing only D (C becomes 0) does not clear CD's saved sign, so 3 x 5
    // comes out negative (Epyx bug list: the auto-clear of the upper byte
    // does not clear the sign flag).
    s.write(D, 5);
    s.write(B, 3);
    s.write(A, 0);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -15))), efgh(&s));
    // Writing C again re-evaluates the sign.
    s.write(D, 5);
    s.write(C, 0);
    s.write(A, 0);
    try std.testing.expectEqual(@as(u32, 15), efgh(&s));
}

test "math: accumulate into JKLM with the overflow warning" {
    for ([_]u8{ 0x40, 0xC0 }) |mode| {
        var s: Suzy = .{};
        s.write(sprsys, mode);
        var prng = std.Random.DefaultPrng.init(0xACC0 + @as(u64, mode));
        const rng = prng.random();
        // Clear the accumulator: K and M (zeroing J and L).
        s.write(K, 0);
        s.write(M, 0);
        try std.testing.expectEqual(@as(u32, 0), jklm(&s));
        var acc: u32 = 0;
        var saw_warning = false;
        for (0..5000) |_| {
            const a = operand(rng);
            const c = operand(rng);
            mul(&s, a, c);
            const prod: u32 = if (mode & 0x80 != 0)
                @truncate(@as(u64, @bitCast(hw_signed(a) * hw_signed(c))))
            else
                @as(u32, a) * @as(u32, c);
            try std.testing.expectEqual(prod, efgh(&s));
            const old = acc;
            acc +%= prod;
            try std.testing.expectEqual(acc, jklm(&s));
            const ovf = (old ^ acc) & 0x8000_0000 != 0;
            try std.testing.expectEqual(ovf, warning(&s));
            try std.testing.expectEqual(ovf, s.read(sprsys) & 0x20 != 0);
            saw_warning = saw_warning or ovf;
        }
        try std.testing.expect(saw_warning);
        // The accumulator can be preset through all four bytes; writing M
        // clears the warning.
        s.write(M, 0xFF);
        s.write(L, 0xFF);
        s.write(K, 0xFF);
        s.write(J, 0x7F);
        try std.testing.expect(!warning(&s));
        mul(&s, 1, 1);
        try std.testing.expectEqual(@as(u32, 0x8000_0000), jklm(&s));
        try std.testing.expect(warning(&s));
        s.write(M, 0);
        try std.testing.expect(!warning(&s));
    }
}

test "math: no accumulate leaves JKLM alone" {
    var s: Suzy = .{};
    s.write(M, 0x34);
    s.write(L, 0x12);
    mul(&s, 100, 100);
    try std.testing.expectEqual(@as(u32, 10000), efgh(&s));
    try std.testing.expectEqual(@as(u32, 0x1234), jklm(&s));
}

test "math: unsigned divide against Zig" {
    var s: Suzy = .{};
    var prng = std.Random.DefaultPrng.init(0xD1F);
    const rng = prng.random();
    for (0..20000) |i| {
        const dividend: u32 = if (i % 4 == 0) rng.int(u16) else rng.int(u32);
        var divisor = operand(rng);
        if (divisor == 0) divisor = 7;
        div(&s, dividend, divisor);
        try std.testing.expectEqual(dividend / divisor, abcd(&s));
        try std.testing.expectEqual(dividend % divisor, jklm(&s));
        try std.testing.expect(!warning(&s));
    }
    // Signed mode does not change the divide (unsigned only).
    s.write(sprsys, 0x80);
    div(&s, 0xFFFF_FFF0, 0xFFFF);
    try std.testing.expectEqual(@as(u32, 0x1_0000), abcd(&s));
    try std.testing.expectEqual(@as(u32, 0xFFF0), jklm(&s));
}

test "math: divide by zero gives all ones and the warning" {
    var s: Suzy = .{};
    div(&s, 12345, 0);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), abcd(&s));
    try std.testing.expect(warning(&s));
    // The next good divide clears it.
    div(&s, 12345, 5);
    try std.testing.expectEqual(@as(u32, 2469), abcd(&s));
    try std.testing.expect(!warning(&s));
}

test "math: low-byte writes zero the partner high byte; only A and E start" {
    var s: Suzy = .{};
    for ([_][2]u8{ .{ B, A }, .{ D, C }, .{ P, N }, .{ H, G }, .{ F, E }, .{ M, L }, .{ K, J } }) |pair| {
        s.write(pair[1], 0x5A);
        s.write(pair[0], 0x11);
        try std.testing.expectEqual(@as(u8, 0x11), s.read(pair[0]));
        try std.testing.expectEqual(@as(u8, 0), s.read(pair[1]));
    }
    // Writing B, C, D does not multiply: EFGH keeps what was written.
    s.write(H, 0x78);
    s.write(G, 0x56);
    s.write(F, 0x34);
    s.write(sprsys, 0); // no divide either until E
    s.write(D, 2);
    s.write(C, 0);
    s.write(B, 3);
    try std.testing.expectEqual(@as(u8, 0x78), s.read(H));
    // Writing A does.
    s.write(A, 0);
    try std.testing.expectEqual(@as(u32, 6), efgh(&s));
    // Repetitive multiply: only the changed byte and A.
    s.write(B, 10);
    s.write(A, 0);
    try std.testing.expectEqual(@as(u32, 20), efgh(&s));
}
