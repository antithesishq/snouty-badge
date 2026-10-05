//! Thumb-2 fast paths for f64 add, subtract and multiply on the badge
//! (ARMv8-M Mainline with the DSP extension: UMAAL). Both operands normal:
//! done here, any result (normal, subnormal from exact cancellation,
//! overflow to infinity). Anything else (zeros, subnormal inputs,
//! infinities, NaNs, a product that underflows) goes to the Zig versions
//! in softfloat.zig, which tests.zig checks bit for bit against an IEEE
//! unit. The assembly itself is checked against those Zig versions on the
//! emulated badge (`--poke paperclips_bench=99`, main.zig).

const softfloat = @import("softfloat.zig");

const aapcs = softfloat.aapcs;

fn add_slow(a: f64, b: f64) callconv(aapcs) f64 {
    return @bitCast(softfloat.add_general(@bitCast(a), @bitCast(b)));
}
fn mul_slow(a: f64, b: f64) callconv(aapcs) f64 {
    return @bitCast(softfloat.mul(@bitCast(a), @bitCast(b)));
}

comptime {
    if (softfloat.export_on_target) {
        @export(&add_slow, .{ .name = "paperclips_sf_add_slow" });
        @export(&mul_slow, .{ .name = "paperclips_sf_mul_slow" });
        asm (asm_source);
    }
}

// Registers: a = r1:r0 (hi:lo), b = r3:r2, result r1:r0. r4-r8 saved.
const asm_source =
    \\  .syntax unified
    \\  .thumb
    \\  .text
    \\  .global __aeabi_dsub
    \\  .type __aeabi_dsub, %function
    \\  .thumb_func
    \\__aeabi_dsub:
    \\  eor r3, r3, #0x80000000
    \\  .global __aeabi_dadd
    \\  .type __aeabi_dadd, %function
    \\  .thumb_func
    \\__aeabi_dadd:
    \\  lsl r12, r1, #1             @ exponent field 1..0x7fe?
    \\  sub r12, r12, #0x200000
    \\  cmn r12, #0x400000
    \\  bcs .Ladd_slow_entry
    \\  lsl r12, r3, #1             @ exponent field 1..0x7fe?
    \\  sub r12, r12, #0x200000
    \\  cmn r12, #0x400000
    \\  bcs .Ladd_slow_entry
    \\  push {r4, r5, r6, r7, r8, lr}
    \\  @ |a| >= |b|, else swap
    \\  bic r6, r1, #0x80000000
    \\  bic r7, r3, #0x80000000
    \\  subs r8, r0, r2
    \\  sbcs r8, r6, r7
    \\  bcs 1f
    \\  mov r8, r0
    \\  mov r0, r2
    \\  mov r2, r8
    \\  mov r8, r1
    \\  mov r1, r3
    \\  mov r3, r8
    \\1:
    \\  ubfx r4, r1, #20, #11       @ ex
    \\  ubfx r5, r3, #20, #11       @ ey
    \\  eor lr, r1, r3              @ bit 31: signs differ
    \\  and r6, r1, #0x80000000     @ sign of the result
    \\  @ significands with the implicit bit, leading 1 at bit 61
    \\  bfc r1, #20, #12
    \\  orr r1, r1, #0x100000
    \\  lsl r1, r1, #9
    \\  orr r1, r1, r0, lsr #23
    \\  lsl r0, r0, #9
    \\  bfc r3, #20, #12
    \\  orr r3, r3, #0x100000
    \\  lsl r3, r3, #9
    \\  orr r3, r3, r2, lsr #23
    \\  lsl r2, r2, #9
    \\  @ align y: shift right by d = ex - ey, lost bits into bit 0
    \\  subs r7, r4, r5
    \\  beq 3f
    \\  cmp r7, #32
    \\  bhs 2f
    \\  rsb r8, r7, #32
    \\  lsl r12, r2, r8             @ the bits shifted out
    \\  lsr r2, r2, r7
    \\  lsl r8, r3, r8
    \\  orr r2, r2, r8
    \\  lsr r3, r3, r7
    \\  cmp r12, #0
    \\  it ne
    \\  orrne r2, r2, #1
    \\  b 3f
    \\2:
    \\  cmp r7, #64
    \\  bhs 4f
    \\  sub r7, r7, #32
    \\  rsb r8, r7, #32             @ 32 - k; a shift by 32 gives 0
    \\  lsl r12, r3, r8
    \\  orr r12, r12, r2
    \\  lsr r2, r3, r7
    \\  movs r3, #0
    \\  cmp r12, #0
    \\  it ne
    \\  orrne r2, r2, #1
    \\  b 3f
    \\4:
    \\  movs r2, #1
    \\  movs r3, #0
    \\3:
    \\  tst lr, #0x80000000
    \\  bne 5f
    \\  @ same signs: m = x + y, leading 1 at bit 61 or 62
    \\  adds r0, r0, r2
    \\  adc r1, r1, r3
    \\  tst r1, #0x40000000
    \\  itt ne
    \\  addne r4, r4, #1
    \\  bne .Lpack
    \\  adds r0, r0, r0
    \\  adc r1, r1, r1
    \\  b .Lpack
    \\5:
    \\  @ signs differ: m = x - y, normalise to the leading 1 at bit 62
    \\  subs r0, r0, r2
    \\  sbc r1, r1, r3
    \\  orrs r12, r0, r1
    \\  beq .Lzero
    \\  cmp r1, #0
    \\  ite ne
    \\  clzne r12, r1
    \\  clzeq r12, r0
    \\  it eq
    \\  addeq r12, r12, #32
    \\  add r4, r4, #2
    \\  sub r4, r4, r12             @ e = ex + 2 - z
    \\  sub r8, r12, #1             @ shift k = z - 1 >= 1
    \\  cmp r8, #32
    \\  bhs 6f
    \\  rsb r12, r8, #32
    \\  lsl r1, r1, r8
    \\  lsr r12, r0, r12
    \\  orr r1, r1, r12
    \\  lsl r0, r0, r8
    \\  b .Lpack
    \\6:
    \\  sub r12, r8, #32
    \\  lsl r1, r0, r12
    \\  movs r0, #0
    \\.Lpack:
    \\  @ m = r1:r0, leading 1 at bit 62; e = r4; sign = r6
    \\  sub r12, r4, #1
    \\  movw r5, #0x7fe
    \\  cmp r12, r5
    \\  bhs .Lout_of_range
    \\  ubfx r8, r0, #10, #1
    \\  addw r8, r8, #0x1ff
    \\  adds r0, r0, r8
    \\  adc r1, r1, #0
    \\  lsr r0, r0, #10
    \\  orr r0, r0, r1, lsl #22
    \\  lsr r1, r1, #10
    \\  add r1, r1, r12, lsl #20
    \\  orr r1, r1, r6
    \\  pop {r4, r5, r6, r7, r8, pc}
    \\.Lout_of_range:
    \\  cmp r4, #1
    \\  blt .Lsubnormal
    \\  @ overflow: infinity
    \\  movs r0, #0
    \\  orr r1, r6, #0x7f000000
    \\  orr r1, r1, #0x00f00000
    \\  pop {r4, r5, r6, r7, r8, pc}
    \\.Lsubnormal:
    \\  @ only from an exact cancellation: shift right by 11 - e, no rounding
    \\  rsb r8, r4, #11
    \\  cmp r8, #32
    \\  bhs 7f
    \\  rsb r12, r8, #32
    \\  lsr r0, r0, r8
    \\  lsl r12, r1, r12
    \\  orr r0, r0, r12
    \\  lsr r1, r1, r8
    \\  orr r1, r1, r6
    \\  pop {r4, r5, r6, r7, r8, pc}
    \\7:
    \\  sub r12, r8, #32
    \\  lsr r0, r1, r12
    \\  mov r1, r6
    \\  pop {r4, r5, r6, r7, r8, pc}
    \\.Lzero:
    \\  movs r0, #0
    \\  movs r1, #0
    \\  pop {r4, r5, r6, r7, r8, pc}
    \\.Ladd_slow_entry:
    \\  b paperclips_sf_add_slow
    \\
    \\  .global __aeabi_dmul
    \\  .type __aeabi_dmul, %function
    \\  .thumb_func
    \\__aeabi_dmul:
    \\  lsl r12, r1, #1             @ exponent field 1..0x7fe?
    \\  sub r12, r12, #0x200000
    \\  cmn r12, #0x400000
    \\  bcs .Lmul_slow_entry
    \\  lsl r12, r3, #1             @ exponent field 1..0x7fe?
    \\  sub r12, r12, #0x200000
    \\  cmn r12, #0x400000
    \\  bcs .Lmul_slow_entry
    \\  push {r4, r5, r6, r7, r8, r9, r10, r11, lr}
    \\  mov r9, r1                  @ the operands' words it changes, for the slow path
    \\  mov r10, r3
    \\  mov r11, r0
    \\  ubfx r4, r1, #20, #11
    \\  ubfx r5, r3, #20, #11
    \\  add r4, r4, r5
    \\  subw r4, r4, #1023          @ e = ea + eb - 1023
    \\  eor r6, r1, r3
    \\  and r6, r6, #0x80000000
    \\  bfc r1, #20, #12
    \\  orr r1, r1, #0x100000
    \\  bfc r3, #20, #12
    \\  orr r3, r3, #0x100000
    \\  @ (r1:r0) * (r3:r2) = w3:w2:w1:w0 = r8:r7:r5:r12
    \\  umull r12, r5, r0, r2
    \\  movs r7, #0
    \\  umaal r5, r7, r1, r2
    \\  movs r8, #0
    \\  umaal r5, r8, r0, r3
    \\  umaal r7, r8, r1, r3
    \\  @ m = P >> 42 with the 42 bits below as sticky
    \\  orr r12, r12, r5, lsl #22   @ the low 10 bits of w1 and all of w0
    \\  lsr r0, r5, #10
    \\  orr r0, r0, r7, lsl #22
    \\  lsr r1, r7, #10
    \\  orr r1, r1, r8, lsl #22
    \\  cmp r12, #0
    \\  it ne
    \\  orrne r0, r0, #1
    \\  @ leading 1 at bit 63: one more shift, the dropped bit into bit 0
    \\  tst r1, #0x80000000
    \\  beq 1f
    \\  and r12, r0, #1
    \\  lsr r0, r0, #1
    \\  orr r0, r0, r1, lsl #31
    \\  orr r0, r0, r12
    \\  lsr r1, r1, #1
    \\  add r4, r4, #1
    \\1:
    \\  sub r12, r4, #1
    \\  movw r5, #0x7fe
    \\  cmp r12, r5
    \\  bhs 2f
    \\  ubfx r8, r0, #10, #1
    \\  addw r8, r8, #0x1ff
    \\  adds r0, r0, r8
    \\  adc r1, r1, #0
    \\  lsr r0, r0, #10
    \\  orr r0, r0, r1, lsl #22
    \\  lsr r1, r1, #10
    \\  add r1, r1, r12, lsl #20
    \\  orr r1, r1, r6
    \\  pop {r4, r5, r6, r7, r8, r9, r10, r11, pc}
    \\2:
    \\  cmp r4, #1
    \\  blt 3f
    \\  movs r0, #0
    \\  orr r1, r6, #0x7f000000
    \\  orr r1, r1, #0x00f00000
    \\  pop {r4, r5, r6, r7, r8, r9, r10, r11, pc}
    \\3:
    \\  @ underflow: the Zig version rounds the subnormal
    \\  mov r1, r9
    \\  mov r3, r10
    \\  mov r0, r11
    \\  pop {r4, r5, r6, r7, r8, r9, r10, r11, lr}
    \\.Lmul_slow_entry:
    \\  b paperclips_sf_mul_slow
    \\
;
