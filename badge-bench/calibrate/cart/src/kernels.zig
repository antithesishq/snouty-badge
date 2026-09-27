//! Calibration micro-kernels K0..K19 (SPEC.md section 3, PLAN.md). Each is a
//! `noinline` function, so it is one sized symbol `kernels.k<id>_<name>` in
//! the ELF and badge-bench's per-function tables are its instruction mix.
//!
//! How the bodies stay what they say:
//! - Inputs come from `volatile` loads before the loop, results go to a
//!   `volatile` sink after it, so nothing folds to a constant.
//! - Every loop contains one empty `asm volatile`. LLVM's ARM loop unroller
//!   refuses loops that contain a call, and inline asm counts as one, so the
//!   x16 body written here is the body that runs (no extra x2/x4 unroll).
//! - Memory kernels use volatile pointers: every access is one LDR/STR with
//!   an immediate offset, never merged into LDM/STM/LDRD.
//! - Float mode is the default (strict): no reassociation, no contraction
//!   of `a*k + c` into VFMA.
//! The listing of every kernel was checked after building (see the report
//! in PLAN.md status); the fit uses the emulator's counts, not these notes.
const std = @import("std");
const cart = @import("cart-api");

pub const Kernel = struct {
    name: []const u8,
    /// Short name for the 20-column results pages.
    short: []const u8,
    run: *const fn () void,
    /// Loop iterations per run.
    n: u32,
    /// Operations per iteration (16 for the x16 bodies).
    ops_per_iter: u32,
};

pub const count = 20;

pub const list: [count]Kernel = .{
    .{ .name = "empty", .short = "empty", .run = &k0_empty, .n = n0, .ops_per_iter = 16 },
    .{ .name = "vmul_indep", .short = "vmulI", .run = &k1_vmul_indep, .n = n1, .ops_per_iter = 16 },
    .{ .name = "vmul_dep", .short = "vmulD", .run = &k2_vmul_dep, .n = n2, .ops_per_iter = 16 },
    .{ .name = "vadd_vmul_mix", .short = "vmMix", .run = &k3_vadd_vmul_mix, .n = n3, .ops_per_iter = 16 },
    .{ .name = "vdiv", .short = "vdiv", .run = &k4_vdiv, .n = n4, .ops_per_iter = 16 },
    .{ .name = "vsqrt", .short = "vsqrt", .run = &k5_vsqrt, .n = n5, .ops_per_iter = 16 },
    .{ .name = "vdiv_indep", .short = "vdivI", .run = &k6_vdiv_indep, .n = n6, .ops_per_iter = 16 },
    .{ .name = "ldr_seq", .short = "ldrSq", .run = &k7_ldr_seq, .n = n7, .ops_per_iter = 16 },
    .{ .name = "ldr_stride", .short = "ldrSt", .run = &k8_ldr_stride, .n = n8, .ops_per_iter = 16 },
    .{ .name = "str_seq", .short = "strSq", .run = &k9_str_seq, .n = n9, .ops_per_iter = 16 },
    .{ .name = "vldr_vstr", .short = "vlvs", .run = &k10_vldr_vstr, .n = n10, .ops_per_iter = 16 },
    .{ .name = "ldrh_strh_fb", .short = "fbh", .run = &k11_ldrh_strh_fb, .n = n11, .ops_per_iter = 16 },
    .{ .name = "branch_taken", .short = "brTkn", .run = &k12_branch_taken, .n = n12, .ops_per_iter = 1 },
    .{ .name = "branch_pattern", .short = "brPat", .run = &k13_branch_pattern, .n = n13, .ops_per_iter = 16 },
    .{ .name = "udiv", .short = "udiv", .run = &k14_udiv, .n = n14, .ops_per_iter = 16 },
    .{ .name = "nop_fetch", .short = "nop", .run = &k15_nop_fetch, .n = n15, .ops_per_iter = 16 },
    .{ .name = "nop_fetch_w", .short = "nop.w", .run = &k16_nop_fetch_w, .n = n16, .ops_per_iter = 16 },
    .{ .name = "vcmp_vmrs", .short = "vcmp", .run = &k17_vcmp_vmrs, .n = n17, .ops_per_iter = 16 },
    .{ .name = "table_lerp", .short = "tblLp", .run = &k18_table_lerp, .n = n18, .ops_per_iter = 16 },
    .{ .name = "mixed_tracer", .short = "mixed", .run = &k19_mixed_tracer, .n = n19, .ops_per_iter = k19_ops },
};

// Iterations per run, sized so one idle run is 300 k to 500 k modelled
// cycles (badge-bench) and the busy run ends well inside the DMA window
// on hardware (main.zig checks it at run time).
const n0 = 131072;
const n1 = 20480;
const n2 = 20480;
const n3 = 20480;
const n4 = 1664;
const n5 = 1536;
const n6 = 1664;
const n7 = 10240;
const n8 = 10240;
const n9 = 10240;
const n10 = 10240;
const n11 = 10240;
const n12 = 98304;
const n13 = 8192;
const n14 = 3584;
const n15 = 20480;
const n16 = 20480;
const n17 = 5120;
const n18 = 1792;
const n19 = 4096;

/// Instructions in K19's loop body without the loop's own ADDS + BLO,
/// counted from the listing (fit.py divides by ops, so for K19 "per op" is
/// per instruction of the mix).
const k19_ops = 60;

/// Each kernel's result after its last run, reported as `sink=` (proof the
/// body ran and computed something).
pub var sinks: [count]u32 = @splat(0);

// ---------------------------------------------------------------------------
// Opaque inputs.

var src_f: [20]f32 = .{
    1.0000001, 0.9999999, 1.5,  2.25, 0.75, 1.125, 3.0,  0.5,
    1.0,       0.25,      -0.5, 0.33, 0.66, 0.1,   0.02, 0.9,
    1.75,      2.5,       0.4,  0.6,
};
var src_u: [4]u32 = .{ 1, 0xDEAD_BEEF, 0xAAAA_AAAA, 7 };

inline fn vf(i: usize) f32 {
    return @as(*volatile f32, &src_f[i]).*;
}
inline fn vu(i: usize) u32 {
    return @as(*volatile u32, &src_u[i]).*;
}
inline fn sink_f(id: usize, x: f32) void {
    @as(*volatile u32, &sinks[id]).* = @bitCast(x);
}
inline fn sink_u(id: usize, x: u32) void {
    @as(*volatile u32, &sinks[id]).* = x;
}
/// No instruction. Keeps the loop from being unrolled further (see top).
inline fn barrier() void {
    asm volatile ("");
}

// ---------------------------------------------------------------------------
// Static data for the memory kernels (cart SRAM, never SRAM8/9).

var words_4k: [1024]u32 align(64) = @splat(0);
var words_32k: [8192]u32 align(64) = @splat(0);
var copy_src: [1024]f32 align(64) = @splat(0);
var copy_dst: [1024]f32 align(64) = @splat(0);

// ---------------------------------------------------------------------------
// K0..K6: loop overhead and FP arithmetic.

/// K0: loop overhead only (SUBS + taken BNE per iteration) and the counter
/// reads around it.
pub noinline fn k0_empty() void {
    var i: u32 = n0;
    while (i != 0) : (i -= 1) barrier();
    sink_u(0, i);
}

/// K1: VMUL.F32 throughput, 4 independent chains, 16 multiplies.
pub noinline fn k1_vmul_indep() void {
    const k = vf(0);
    var a0 = vf(2);
    var a1 = vf(3);
    var a2 = vf(4);
    var a3 = vf(5);
    var i: u32 = n1;
    while (i != 0) : (i -= 1) {
        inline for (0..4) |_| {
            a0 *= k;
            a1 *= k;
            a2 *= k;
            a3 *= k;
        }
        barrier();
    }
    sink_f(1, a0 + a1 + a2 + a3);
}

/// K2: VMUL.F32 latency, one dependent chain of 16.
pub noinline fn k2_vmul_dep() void {
    const k = vf(0);
    var a = vf(2);
    var i: u32 = n2;
    while (i != 0) : (i -= 1) {
        inline for (0..16) |_| a *= k;
        barrier();
    }
    sink_f(2, a);
}

/// K3: VMUL and VADD interleaved on 2 chains, `a = a*k + c` as two ops.
pub noinline fn k3_vadd_vmul_mix() void {
    const k = vf(1);
    const c = vf(13);
    var a = vf(2);
    var b = vf(3);
    var i: u32 = n3;
    while (i != 0) : (i -= 1) {
        inline for (0..4) |_| {
            a *= k;
            b *= k;
            a += c;
            b += c;
        }
        barrier();
    }
    sink_f(3, a + b);
}

/// K4: VDIV.F32, one dependent chain of 16.
pub noinline fn k4_vdiv() void {
    const k = vf(0);
    var a = vf(2);
    var i: u32 = n4;
    while (i != 0) : (i -= 1) {
        inline for (0..16) |_| a /= k;
        barrier();
    }
    sink_f(4, a);
}

/// K5: VSQRT.F32 dependent, `a = sqrt(a) + 1` (16 of each; converges to
/// the golden ratio squared, so the value stays normal).
pub noinline fn k5_vsqrt() void {
    const one = vf(8);
    var a = vf(6);
    var i: u32 = n5;
    while (i != 0) : (i -= 1) {
        inline for (0..16) |_| a = @sqrt(a) + one;
        barrier();
    }
    sink_f(5, a);
}

/// K6: VDIV.F32, 4 independent chains (shows whether VDIV pipelines).
pub noinline fn k6_vdiv_indep() void {
    const k = vf(0);
    var a0 = vf(2);
    var a1 = vf(3);
    var a2 = vf(4);
    var a3 = vf(5);
    var i: u32 = n6;
    while (i != 0) : (i -= 1) {
        inline for (0..4) |_| {
            a0 /= k;
            a1 /= k;
            a2 /= k;
            a3 /= k;
        }
        barrier();
    }
    sink_f(6, a0 + a1 + a2 + a3);
}

// ---------------------------------------------------------------------------
// K7..K11: memory.

/// K7: 16 sequential LDR (stride 4) per iteration, walking a 4 KB array.
/// The loaded values are discarded (volatile loads still issue).
pub noinline fn k7_ldr_seq() void {
    const base: [*]volatile u32 = &words_4k;
    var j: u32 = 0;
    var i: u32 = n7;
    while (i != 0) : (i -= 1) {
        const p = base + j;
        inline for (0..16) |w| _ = p[w];
        j = (j + 16) & (words_4k.len - 1);
        barrier();
    }
    sink_u(7, base[j]);
}

/// K8: 16 LDR with a 64-byte stride per iteration, walking 32 KB.
pub noinline fn k8_ldr_stride() void {
    const base: [*]volatile u32 = &words_32k;
    var j: u32 = 0;
    var i: u32 = n8;
    while (i != 0) : (i -= 1) {
        const p = base + j;
        inline for (0..16) |w| _ = p[w * 16];
        j = (j + 256) & (words_32k.len - 1);
        barrier();
    }
    sink_u(8, base[j]);
}

/// K9: 16 sequential STR per iteration, filling a 4 KB array.
pub noinline fn k9_str_seq() void {
    const base: [*]volatile u32 = &words_4k;
    const v = vu(1);
    var j: u32 = 0;
    var i: u32 = n9;
    while (i != 0) : (i -= 1) {
        const p = base + j;
        inline for (0..16) |w| p[w] = v;
        j = (j + 16) & (words_4k.len - 1);
        barrier();
    }
    sink_u(9, base[3]);
}

/// K10: 8 VLDR + 8 VSTR per iteration, copying 4 KB of f32. Written in asm
/// because LLVM moves an f32 that is only copied through core registers
/// (LDR/STR), which would test K7/K9 again.
pub noinline fn k10_vldr_vstr() void {
    const src: [*]f32 = &copy_src;
    const dst: [*]f32 = &copy_dst;
    var j: u32 = 0;
    var i: u32 = n10;
    while (i != 0) : (i -= 1) {
        const s = src + j;
        const d = dst + j;
        asm volatile (
            \\vldr s0, [%[s], #0]
            \\vstr s0, [%[d], #0]
            \\vldr s1, [%[s], #4]
            \\vstr s1, [%[d], #4]
            \\vldr s2, [%[s], #8]
            \\vstr s2, [%[d], #8]
            \\vldr s3, [%[s], #12]
            \\vstr s3, [%[d], #12]
            \\vldr s0, [%[s], #16]
            \\vstr s0, [%[d], #16]
            \\vldr s1, [%[s], #20]
            \\vstr s1, [%[d], #20]
            \\vldr s2, [%[s], #24]
            \\vstr s2, [%[d], #24]
            \\vldr s3, [%[s], #28]
            \\vstr s3, [%[d], #28]
            :
            : [s] "r" (s),
              [d] "r" (d),
            : .{ .s0 = true, .s1 = true, .s2 = true, .s3 = true, .memory = true });
        j = (j + 8) & (copy_src.len - 1);
    }
    sink_u(10, @bitCast(@as(*volatile f32, &copy_dst[5]).*));
}

/// K11: 8 LDRH + 8 STRH per iteration into the back framebuffer (the one
/// the cart draws; the LCD DMA reads the other): each iteration copies 8
/// pixels 8 pixels forward, walking all 160 x 128.
pub noinline fn k11_ldrh_strh_fb() void {
    const px_count = cart.screen_width * cart.screen_height;
    const base: [*]volatile u16 = @ptrCast(cart.framebuffer);
    var j: u32 = 0;
    var i: u32 = n11;
    while (i != 0) : (i -= 1) {
        const p = base + j;
        inline for (0..8) |w| p[w + 8] = p[w];
        j += 16;
        if (j == px_count) j = 0;
        barrier();
    }
    sink_u(11, base[9]);
}

// ---------------------------------------------------------------------------
// K12..K16: branches, integer divide, instruction fetch.

/// K12: taken conditional branch: a countdown loop whose body is one ADD.
/// The asm makes `acc` opaque so the add cannot become a closed form.
pub noinline fn k12_branch_taken() void {
    const step = vu(0);
    var acc: u32 = 0;
    var i: u32 = n12;
    while (i != 0) : (i -= 1) {
        acc = asm volatile (""
            : [o] "=r" (-> u32),
            : [x] "0" (acc +% step),
        );
    }
    sink_u(12, acc);
}

/// K13: alternating taken / not-taken branches: 16 `tst; beq` tests of
/// successive bits of the volatile pattern 0xAAAAAAAA, each skipping a NOP
/// when its bit is clear (bit 0 clear: taken, bit 1 set: falls through to
/// the NOP, ...). In asm: written in Zig, LLVM hoists the 16 bit tests out
/// of the loop, spills them, and lays the NOPs out of line so every branch
/// ends up taken.
pub noinline fn k13_branch_pattern() void {
    const pattern = vu(2);
    var i: u32 = n13;
    while (i != 0) : (i -= 1) {
        inline for (0..16) |b| {
            asm volatile (std.fmt.comptimePrint(
                    \\tst %[p], #{d}
                    \\beq 1f
                    \\nop
                    \\1:
                , .{@as(u32, 1) << b})
                :
                : [p] "r" (pattern),
                : .{ .cpsr = true });
        }
    }
    sink_u(13, pattern);
}

/// K14: UDIV, one dependent chain of 16, `a = a / k` with k = 1 from a
/// volatile, dividend 0xDEADBEEF (a 32-bit quotient: the slow end of the
/// M33's 2..12 cycle range, if its divider terminates early).
pub noinline fn k14_udiv() void {
    const k = vu(0);
    var a = vu(1);
    var i: u32 = n14;
    while (i != 0) : (i -= 1) {
        inline for (0..16) |_| a /= k;
        barrier();
    }
    sink_u(14, a);
}

/// K15: instruction fetch: 16 2-byte NOPs.
pub noinline fn k15_nop_fetch() void {
    var i: u32 = n15;
    while (i != 0) : (i -= 1) {
        inline for (0..16) |_| asm volatile ("nop");
    }
    sink_u(15, i);
}

/// K16: instruction fetch: 16 4-byte NOP.W.
pub noinline fn k16_nop_fetch_w() void {
    var i: u32 = n16;
    while (i != 0) : (i -= 1) {
        inline for (0..16) |_| asm volatile ("nop.w");
    }
    sink_u(16, i);
}

// ---------------------------------------------------------------------------
// K17..K19: FP compares, the sine table, a tracer-shaped mix.

/// K17: VCMP + VMRS + IT + ADD: `if (a > b_k) c += 1` against 16
/// thresholds held in registers; `a` advances once per iteration (one
/// VADD) so the compares cannot be hoisted.
pub noinline fn k17_vcmp_vmrs() void {
    var b: [16]f32 = undefined;
    inline for (0..16) |t| b[t] = vf(t + 2);
    const d = vf(14);
    var a = vf(9);
    var c: u32 = 0;
    var i: u32 = n17;
    while (i != 0) : (i -= 1) {
        a += d;
        inline for (0..16) |t| {
            if (a > b[t]) c += 1;
        }
        barrier();
    }
    sink_u(17, c);
}

pub const sin_table_len = 1024;

/// Paired sine table like snouty-reflections' math.zig: entry i is
/// { sin(i/N turns), sin((i+1)/N) - sin(i/N) }. Filled by `init()` at
/// start() with a runtime loop (no comptime table; see the root CLAUDE.md).
pub var sin_table: [sin_table_len][2]f32 align(8) = undefined;

pub fn init() void {
    // Rotation recurrence in f32: good to ~1e-5, plenty for a timing table.
    const step = 2.0 * 3.14159265358979 / @as(f32, sin_table_len);
    const cs: f32 = @cos(step);
    const sn: f32 = @sin(step);
    var s: f32 = 0;
    var c: f32 = 1;
    var prev: f32 = 0;
    for (0..sin_table_len + 1) |i| {
        if (i > 0) sin_table[i - 1] = .{ prev, s - prev };
        prev = s;
        const s2 = s * cs + c * sn;
        c = c * cs - s * sn;
        s = s2;
    }
    for (&copy_src, 0..) |*v, i| v.* = @floatFromInt(i);
}

inline fn sin_steps(steps: f32) f32 {
    const fl = @floor(steps);
    const i: i32 = @intFromFloat(fl);
    const e = sin_table[@as(u32, @bitCast(i)) & (sin_table_len - 1)];
    return e[0] + e[1] * (steps - fl);
}

/// K18: the tracer's interpolated sine lookup (floor, convert, mask, two
/// loads, sub, mul, add), 16 per iteration on an advancing argument.
pub noinline fn k18_table_lerp() void {
    const dx = vf(10); // 0.25 steps
    var x = vf(7);
    var acc: f32 = 0;
    var i: u32 = n18;
    while (i != 0) : (i -= 1) {
        inline for (0..16) |_| {
            acc += sin_steps(x);
            x += dx;
        }
        barrier();
    }
    sink_f(18, acc);
}

/// K19: one water-shading sample in the shape of snouty-reflections'
/// trace.zig (self-contained, not a copy): a wave normal from two table
/// lookups, a normalised view ray (one reciprocal square root as VSQRT +
/// VDIV), N.V, a Schlick term (1-c)^5, sky/water lerp per channel,
/// accumulate. Constants live in registers.
pub noinline fn k19_mixed_tracer() void {
    const vx = vf(11);
    const vy = vf(12);
    const vz = vf(9);
    const f0 = vf(14);
    const one = vf(8);
    const sky_r = vf(16);
    const sky_g = vf(17);
    const sky_b = vf(18);
    const wat_r = vf(19);
    const wat_g = vf(13);
    const wat_b = vf(10);
    const dx = vf(15);
    var x = vf(7);
    var ar: f32 = 0;
    var ag: f32 = 0;
    var ab: f32 = 0;
    var i: u32 = n19;
    while (i != 0) : (i -= 1) {
        // wave normal
        const nx = sin_steps(x) * f0;
        const nz = sin_steps(x * vx + vz) * f0;
        const ny = one;
        // ray direction, normalised
        const rx = vx + x * dx;
        const len2 = rx * rx + vy * vy + vz * vz;
        const inv = one / @sqrt(len2);
        // N.V and Schlick
        var c = (nx * rx + ny * vy + nz * vz) * inv;
        if (c < 0) c = -c;
        if (c > one) c = one;
        const m = one - c;
        const m2 = m * m;
        const fres = f0 + (one - f0) * (m2 * m2 * m);
        // lerp water -> sky by the Fresnel term
        ar += wat_r + (sky_r - wat_r) * fres;
        ag += wat_g + (sky_g - wat_g) * fres;
        ab += wat_b + (sky_b - wat_b) * fres;
        x += dx;
        barrier();
    }
    sink_f(19, ar + ag + ab);
}
