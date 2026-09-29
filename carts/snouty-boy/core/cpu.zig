//! SM83 interpreter. Owner in M1: track A. `step` executes one instruction
//! (or an interrupt dispatch) and returns the M-cycles it took; `Gb.tick`
//! advances everything else by that amount afterwards.
//!
//! Decode is one `switch` on the opcode with `inline` prongs for the regular
//! groups, so each opcode gets its own specialised body behind a jump table.
//! No function pointers, no allocation, no floats.
const gb_mod = @import("gb.zig");
const Gb = gb_mod.Gb;
const Reg = gb_mod.Reg;
const timer = @import("timer.zig");

const FZ: u8 = 0x80;
const FN: u8 = 0x40;
const FH: u8 = 0x20;
const FC: u8 = 0x10;

pub const Cpu = struct {
    a: u8 = 0,
    f: u8 = 0,
    b: u8 = 0,
    c: u8 = 0,
    d: u8 = 0,
    e: u8 = 0,
    h: u8 = 0,
    l: u8 = 0,
    sp: u16 = 0,
    pc: u16 = 0,
    ime: bool = false,
    /// EI takes effect after the next instruction.
    ei_pending: bool = false,
    halted: bool = false,
    /// HALT with IME=0 and a pending interrupt: the next opcode byte is
    /// fetched without incrementing PC, so it is read twice.
    halt_bug: bool = false,
};

/// Post-boot register values (SPEC.md sections 3 and 19.1): A = 0x11 is how
/// games detect a Game Boy Color.
pub fn reset(gb: *Gb) void {
    if (gb.is_cgb()) {
        gb.cpu = .{ .a = 0x11, .f = 0x80, .b = 0x00, .c = 0x00, .d = 0xFF, .e = 0x56, .h = 0x00, .l = 0x0D, .sp = 0xFFFE, .pc = 0x0100 };
        return;
    }
    gb.cpu = .{
        .a = 0x01,
        .f = 0xB0,
        .b = 0x00,
        .c = 0x13,
        .d = 0x00,
        .e = 0xD8,
        .h = 0x01,
        .l = 0x4D,
        .sp = 0xFFFE,
        .pc = 0x0100,
    };
}

/// Execute one instruction or interrupt dispatch; return M-cycles (1..6).
pub fn step(gb: *Gb) u8 {
    const c = &gb.cpu;
    if (c.halted) {
        // Nothing can change until a subsystem raises an interrupt, so skip
        // ahead 4 M-cycles per step. Timer and PPU handle batched ticks
        // exactly; interrupt latency out of HALT grows by at most 3 M-cycles.
        if ((gb.ie & gb.io[Reg.if_] & 0x1F) == 0) return 4;
        c.halted = false;
    }
    if (c.ime) {
        const pending = gb.ie & gb.io[Reg.if_] & 0x1F;
        if (pending != 0) {
            // Lowest set bit wins: VBlank > STAT > Timer > Serial > Joypad.
            const n: u3 = @intCast(@ctz(pending));
            gb.io[Reg.if_] &= ~(@as(u8, 1) << n);
            c.ime = false;
            push16(gb, c.pc);
            c.pc = 0x40 + @as(u16, n) * 8;
            return 5;
        }
    }
    if (c.ei_pending) {
        c.ei_pending = false;
        c.ime = true;
    }
    const op = gb.read8(c.pc);
    if (c.halt_bug) {
        c.halt_bug = false;
    } else {
        c.pc +%= 1;
    }
    return execute(gb, op);
}

// ---- helpers ----

inline fn fetch8(gb: *Gb) u8 {
    const c = &gb.cpu;
    const v = gb.read8(c.pc);
    c.pc +%= 1;
    return v;
}

inline fn fetch16(gb: *Gb) u16 {
    const lo = fetch8(gb);
    const hi = fetch8(gb);
    return (@as(u16, hi) << 8) | lo;
}

inline fn hl(c: *const Cpu) u16 {
    return (@as(u16, c.h) << 8) | c.l;
}

inline fn set_hl(c: *Cpu, v: u16) void {
    c.h = @truncate(v >> 8);
    c.l = @truncate(v);
}

/// 16-bit register pair by index: 0 BC, 1 DE, 2 HL, 3 SP.
inline fn get_rr(c: *const Cpu, comptime i: u2) u16 {
    return switch (i) {
        0 => (@as(u16, c.b) << 8) | c.c,
        1 => (@as(u16, c.d) << 8) | c.e,
        2 => (@as(u16, c.h) << 8) | c.l,
        3 => c.sp,
    };
}

inline fn set_rr(c: *Cpu, comptime i: u2, v: u16) void {
    const hi: u8 = @truncate(v >> 8);
    const lo: u8 = @truncate(v);
    switch (i) {
        0 => {
            c.b = hi;
            c.c = lo;
        },
        1 => {
            c.d = hi;
            c.e = lo;
        },
        2 => {
            c.h = hi;
            c.l = lo;
        },
        3 => c.sp = v,
    }
}

/// 8-bit operand by index: B C D E H L (HL) A.
inline fn get_r(gb: *Gb, comptime i: u3) u8 {
    const c = &gb.cpu;
    return switch (i) {
        0 => c.b,
        1 => c.c,
        2 => c.d,
        3 => c.e,
        4 => c.h,
        5 => c.l,
        6 => gb.read8(hl(c)),
        7 => c.a,
    };
}

inline fn set_r(gb: *Gb, comptime i: u3, v: u8) void {
    const c = &gb.cpu;
    switch (i) {
        0 => c.b = v,
        1 => c.c = v,
        2 => c.d = v,
        3 => c.e = v,
        4 => c.h = v,
        5 => c.l = v,
        6 => gb.write8(hl(c), v),
        7 => c.a = v,
    }
}

inline fn push16(gb: *Gb, v: u16) void {
    const c = &gb.cpu;
    c.sp -%= 1;
    gb.write8(c.sp, @truncate(v >> 8));
    c.sp -%= 1;
    gb.write8(c.sp, @truncate(v));
}

inline fn pop16(gb: *Gb) u16 {
    const c = &gb.cpu;
    const lo = gb.read8(c.sp);
    c.sp +%= 1;
    const hi = gb.read8(c.sp);
    c.sp +%= 1;
    return (@as(u16, hi) << 8) | lo;
}

/// Condition by index: NZ, Z, NC, C.
inline fn cond(c: *const Cpu, comptime i: u2) bool {
    return switch (i) {
        0 => (c.f & FZ) == 0,
        1 => (c.f & FZ) != 0,
        2 => (c.f & FC) == 0,
        3 => (c.f & FC) != 0,
    };
}

inline fn zf(v: u8) u8 {
    return if (v == 0) FZ else 0;
}

inline fn sext(e: u8) u16 {
    return @bitCast(@as(i16, @as(i8, @bitCast(e))));
}

/// ALU op by index: ADD ADC SUB SBC AND XOR OR CP.
inline fn alu(c: *Cpu, comptime op: u3, v: u8) void {
    const a = c.a;
    switch (op) {
        0, 1 => {
            const cy: u8 = if (op == 1) (c.f >> 4) & 1 else 0;
            const sum: u16 = @as(u16, a) + v + cy;
            const r: u8 = @truncate(sum);
            c.f = zf(r) |
                (if ((a & 0xF) + (v & 0xF) + cy > 0xF) FH else 0) |
                (if (sum > 0xFF) FC else 0);
            c.a = r;
        },
        2, 3, 7 => {
            const cy: u8 = if (op == 3) (c.f >> 4) & 1 else 0;
            const r = a -% v -% cy;
            c.f = zf(r) | FN |
                (if ((a & 0xF) < (v & 0xF) + cy) FH else 0) |
                (if (@as(u16, a) < @as(u16, v) + cy) FC else 0);
            if (op != 7) c.a = r;
        },
        4 => {
            c.a = a & v;
            c.f = zf(c.a) | FH;
        },
        5 => {
            c.a = a ^ v;
            c.f = zf(c.a);
        },
        6 => {
            c.a = a | v;
            c.f = zf(c.a);
        },
    }
}

/// SP + signed e8 with the flags of ADD SP,e8 and LD HL,SP+e8: H and C come
/// from the unsigned low-byte add, Z and N are cleared.
inline fn sp_plus_e8(c: *Cpu, e: u8) u16 {
    const sp = c.sp;
    c.f = (if ((sp & 0xF) + (e & 0xF) > 0xF) FH else 0) |
        (if ((sp & 0xFF) + @as(u16, e) > 0xFF) FC else 0);
    return sp +% sext(e);
}

/// CGB speed switch: STOP with KEY1 bit 0 armed toggles double speed. The
/// CPU does not halt; it pauses for 2050 M-cycles (Pan Docs), ticked away by
/// the frame loop at the new speed. STOP also resets DIV.
fn speed_switch(gb: *Gb) void {
    gb.dot_shift = if (gb.dot_shift == 2) 1 else 2;
    gb.io[Reg.key1] = if (gb.dot_shift == 1) 0x80 else 0x00;
    timer.write_div(gb);
    gb.stall_m += 2050;
}

// ---- decode ----

fn execute(gb: *Gb, op: u8) u8 {
    const c = &gb.cpu;
    switch (op) {
        0x00 => return 1,
        inline 0x01, 0x11, 0x21, 0x31 => |o| {
            set_rr(c, o >> 4, fetch16(gb));
            return 3;
        },
        0x02 => {
            gb.write8(get_rr(c, 0), c.a);
            return 2;
        },
        0x12 => {
            gb.write8(get_rr(c, 1), c.a);
            return 2;
        },
        0x22 => {
            const a = hl(c);
            gb.write8(a, c.a);
            set_hl(c, a +% 1);
            return 2;
        },
        0x32 => {
            const a = hl(c);
            gb.write8(a, c.a);
            set_hl(c, a -% 1);
            return 2;
        },
        0x0A => {
            c.a = gb.read8(get_rr(c, 0));
            return 2;
        },
        0x1A => {
            c.a = gb.read8(get_rr(c, 1));
            return 2;
        },
        0x2A => {
            const a = hl(c);
            c.a = gb.read8(a);
            set_hl(c, a +% 1);
            return 2;
        },
        0x3A => {
            const a = hl(c);
            c.a = gb.read8(a);
            set_hl(c, a -% 1);
            return 2;
        },
        inline 0x03, 0x13, 0x23, 0x33 => |o| {
            set_rr(c, o >> 4, get_rr(c, o >> 4) +% 1);
            return 2;
        },
        inline 0x0B, 0x1B, 0x2B, 0x3B => |o| {
            set_rr(c, o >> 4, get_rr(c, o >> 4) -% 1);
            return 2;
        },
        inline 0x04, 0x0C, 0x14, 0x1C, 0x24, 0x2C, 0x34, 0x3C => |o| {
            const r = o >> 3;
            const v = get_r(gb, r);
            const res = v +% 1;
            c.f = (c.f & FC) | zf(res) | (if ((v & 0xF) == 0xF) FH else 0);
            set_r(gb, r, res);
            return if (r == 6) 3 else 1;
        },
        inline 0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x35, 0x3D => |o| {
            const r = o >> 3;
            const v = get_r(gb, r);
            const res = v -% 1;
            c.f = (c.f & FC) | zf(res) | FN | (if ((v & 0xF) == 0) FH else 0);
            set_r(gb, r, res);
            return if (r == 6) 3 else 1;
        },
        inline 0x06, 0x0E, 0x16, 0x1E, 0x26, 0x2E, 0x36, 0x3E => |o| {
            const r = o >> 3;
            set_r(gb, r, fetch8(gb));
            return if (r == 6) 3 else 2;
        },
        0x07 => { // RLCA
            const cy = c.a >> 7;
            c.a = (c.a << 1) | cy;
            c.f = cy << 4;
            return 1;
        },
        0x0F => { // RRCA
            const cy = c.a & 1;
            c.a = (c.a >> 1) | (cy << 7);
            c.f = cy << 4;
            return 1;
        },
        0x17 => { // RLA
            const cy = c.a >> 7;
            c.a = (c.a << 1) | ((c.f >> 4) & 1);
            c.f = cy << 4;
            return 1;
        },
        0x1F => { // RRA
            const cy = c.a & 1;
            c.a = (c.a >> 1) | ((c.f & FC) << 3);
            c.f = cy << 4;
            return 1;
        },
        0x08 => { // LD (a16),SP
            const a = fetch16(gb);
            gb.write8(a, @truncate(c.sp));
            gb.write8(a +% 1, @truncate(c.sp >> 8));
            return 5;
        },
        inline 0x09, 0x19, 0x29, 0x39 => |o| { // ADD HL,rr
            const x = hl(c);
            const y = get_rr(c, o >> 4);
            const sum: u32 = @as(u32, x) + y;
            c.f = (c.f & FZ) |
                (if ((x & 0xFFF) + (y & 0xFFF) > 0xFFF) FH else 0) |
                (if (sum > 0xFFFF) FC else 0);
            set_hl(c, @truncate(sum));
            return 2;
        },
        0x10 => { // STOP (skips its padding byte)
            c.pc +%= 1;
            if (gb.is_cgb() and (gb.io[Reg.key1] & 1) != 0) {
                speed_switch(gb);
            } else {
                c.halted = true; // treated as HALT
            }
            return 1;
        },
        0x18 => { // JR e8
            const e = fetch8(gb);
            c.pc +%= sext(e);
            return 3;
        },
        inline 0x20, 0x28, 0x30, 0x38 => |o| { // JR cc,e8
            const e = fetch8(gb);
            if (cond(c, (o >> 3) & 3)) {
                c.pc +%= sext(e);
                return 3;
            }
            return 2;
        },
        0x27 => { // DAA
            var a = c.a;
            var cy = (c.f & FC) != 0;
            if ((c.f & FN) == 0) {
                var adj: u8 = 0;
                if ((c.f & FH) != 0 or (a & 0xF) > 9) adj |= 0x06;
                if (cy or a > 0x99) {
                    adj |= 0x60;
                    cy = true;
                }
                a +%= adj;
            } else {
                var adj: u8 = 0;
                if ((c.f & FH) != 0) adj |= 0x06;
                if (cy) adj |= 0x60;
                a -%= adj;
            }
            c.a = a;
            c.f = zf(a) | (c.f & FN) | (if (cy) FC else 0);
            return 1;
        },
        0x2F => { // CPL
            c.a = ~c.a;
            c.f |= FN | FH;
            return 1;
        },
        0x37 => { // SCF
            c.f = (c.f & FZ) | FC;
            return 1;
        },
        0x3F => { // CCF
            c.f = ((c.f & (FZ | FC)) ^ FC);
            return 1;
        },
        0x76 => { // HALT
            if (!c.ime and (gb.ie & gb.io[Reg.if_] & 0x1F) != 0) {
                c.halt_bug = true;
            } else {
                c.halted = true;
            }
            return 1;
        },
        inline 0x40...0x75, 0x77...0x7F => |o| { // LD r,r'
            const dst = (o >> 3) & 7;
            const src = o & 7;
            set_r(gb, dst, get_r(gb, src));
            return if (dst == 6 or src == 6) 2 else 1;
        },
        inline 0x80...0xBF => |o| { // ALU A,r
            const src = o & 7;
            alu(c, (o >> 3) & 7, get_r(gb, src));
            return if (src == 6) 2 else 1;
        },
        inline 0xC6, 0xCE, 0xD6, 0xDE, 0xE6, 0xEE, 0xF6, 0xFE => |o| { // ALU A,d8
            alu(c, (o >> 3) & 7, fetch8(gb));
            return 2;
        },
        inline 0xC0, 0xC8, 0xD0, 0xD8 => |o| { // RET cc
            if (cond(c, (o >> 3) & 3)) {
                c.pc = pop16(gb);
                return 5;
            }
            return 2;
        },
        0xC9 => {
            c.pc = pop16(gb);
            return 4;
        },
        0xD9 => { // RETI: IME set immediately
            c.pc = pop16(gb);
            c.ime = true;
            return 4;
        },
        inline 0xC1, 0xD1, 0xE1 => |o| {
            set_rr(c, (o >> 4) & 3, pop16(gb));
            return 3;
        },
        0xF1 => { // POP AF
            const v = pop16(gb);
            c.a = @truncate(v >> 8);
            c.f = @as(u8, @truncate(v)) & 0xF0;
            return 3;
        },
        inline 0xC5, 0xD5, 0xE5 => |o| {
            push16(gb, get_rr(c, (o >> 4) & 3));
            return 4;
        },
        0xF5 => {
            push16(gb, (@as(u16, c.a) << 8) | c.f);
            return 4;
        },
        inline 0xC2, 0xCA, 0xD2, 0xDA => |o| { // JP cc,a16
            const a = fetch16(gb);
            if (cond(c, (o >> 3) & 3)) {
                c.pc = a;
                return 4;
            }
            return 3;
        },
        0xC3 => {
            c.pc = fetch16(gb);
            return 4;
        },
        0xE9 => { // JP HL
            c.pc = hl(c);
            return 1;
        },
        inline 0xC4, 0xCC, 0xD4, 0xDC => |o| { // CALL cc,a16
            const a = fetch16(gb);
            if (cond(c, (o >> 3) & 3)) {
                push16(gb, c.pc);
                c.pc = a;
                return 6;
            }
            return 3;
        },
        0xCD => {
            const a = fetch16(gb);
            push16(gb, c.pc);
            c.pc = a;
            return 6;
        },
        inline 0xC7, 0xCF, 0xD7, 0xDF, 0xE7, 0xEF, 0xF7, 0xFF => |o| { // RST
            push16(gb, c.pc);
            c.pc = o & 0x38;
            return 4;
        },
        0xCB => return execute_cb(gb),
        0xE0 => { // LDH (a8),A
            const a = fetch8(gb);
            gb.write8(0xFF00 | @as(u16, a), c.a);
            return 3;
        },
        0xF0 => { // LDH A,(a8)
            const a = fetch8(gb);
            c.a = gb.read8(0xFF00 | @as(u16, a));
            return 3;
        },
        0xE2 => {
            gb.write8(0xFF00 | @as(u16, c.c), c.a);
            return 2;
        },
        0xF2 => {
            c.a = gb.read8(0xFF00 | @as(u16, c.c));
            return 2;
        },
        0xEA => {
            gb.write8(fetch16(gb), c.a);
            return 4;
        },
        0xFA => {
            c.a = gb.read8(fetch16(gb));
            return 4;
        },
        0xE8 => { // ADD SP,e8
            const e = fetch8(gb);
            c.sp = sp_plus_e8(c, e);
            return 4;
        },
        0xF8 => { // LD HL,SP+e8
            const e = fetch8(gb);
            set_hl(c, sp_plus_e8(c, e));
            return 3;
        },
        0xF9 => {
            c.sp = hl(c);
            return 2;
        },
        0xF3 => { // DI
            c.ime = false;
            c.ei_pending = false;
            return 1;
        },
        0xFB => { // EI
            c.ei_pending = true;
            return 1;
        },
        // D3 DB DD E3 E4 EB EC ED F4 FC FD: the real CPU locks up. Spin in
        // place so the machine keeps ticking deterministically.
        else => {
            c.pc -%= 1;
            return 1;
        },
    }
}

fn execute_cb(gb: *Gb) u8 {
    const c = &gb.cpu;
    const op = fetch8(gb);
    switch (op) {
        inline else => |o| {
            const r = o & 7;
            const y = (o >> 3) & 7;
            const v = get_r(gb, r);
            switch (o >> 6) {
                0 => {
                    var res: u8 = undefined;
                    var cy: u8 = undefined;
                    switch (y) {
                        0 => { // RLC
                            cy = v >> 7;
                            res = (v << 1) | cy;
                        },
                        1 => { // RRC
                            cy = v & 1;
                            res = (v >> 1) | (cy << 7);
                        },
                        2 => { // RL
                            cy = v >> 7;
                            res = (v << 1) | ((c.f >> 4) & 1);
                        },
                        3 => { // RR
                            cy = v & 1;
                            res = (v >> 1) | ((c.f & FC) << 3);
                        },
                        4 => { // SLA
                            cy = v >> 7;
                            res = v << 1;
                        },
                        5 => { // SRA
                            cy = v & 1;
                            res = (v >> 1) | (v & 0x80);
                        },
                        6 => { // SWAP
                            cy = 0;
                            res = (v << 4) | (v >> 4);
                        },
                        7 => { // SRL
                            cy = v & 1;
                            res = v >> 1;
                        },
                        else => unreachable,
                    }
                    c.f = zf(res) | (cy << 4);
                    set_r(gb, r, res);
                },
                1 => { // BIT
                    c.f = (c.f & FC) | FH | (if ((v & (1 << y)) == 0) FZ else 0);
                    return if (r == 6) 3 else 2;
                },
                2 => set_r(gb, r, v & ~@as(u8, 1 << y)),
                3 => set_r(gb, r, v | (1 << y)),
                else => unreachable,
            }
            return if (r == 6) 4 else 2;
        },
    }
}
