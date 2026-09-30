//! Motorola 68000 interpreter, generic over the bus (SPEC.md sections 4
//! and 7; PLAN.md M1 Track A owns this file).
//!
//! `M68k(BusT)` is the register file plus `step`. The bus is a comptime
//! parameter (no function pointers on the hot path) and must provide, on
//! `*BusT`: `read8(addr: u24) u8`, `read16(addr: u24) u16`,
//! `write8(addr: u24, v: u8)`, `write16(addr: u24, v: u16)`,
//! `irq_level() u3` (sampled before every instruction) and
//! `ack_irq(level: u3)` (the CPU took an interrupt at that level); a bus
//! may also offer `irq_sample() u3`, the same value kept current by the
//! bus (cheaper), which `step` then samples instead. Longs
//! are two word accesses, high word first. Odd word addresses go to the bus
//! as they are (no address error, SPEC.md section 4).
//!
//! Decode: `decode_op` maps the opcode to a handler (`Op`) through
//! host-generated data (tools/gen_m68k.py -> core/m68k_tables.zig, no
//! comptime loops: Adrian's Mac Zig OOMs), then one `switch` calls the
//! handler. `decode_variant` picks the data: the 64 K x u8 table (one
//! load, 64 KB) or the two-level tables (two loads, 9.25 KB; PLAN.md asks
//! for both).
//!
//! Timing: every bus access charges 4 cycles as it happens (opcode, each
//! extension word, each data word; a long is 8) and handlers add the
//! internal cycles of the 68000 user manual's tables on top, so the
//! effective-address costs fall out of the accesses. The result is the
//! manual's count, and matches SingleStepTests' `length` on every case
//! (tests/m68k_single_step.zig). `cyc` is public: a bus access may add
//! wait or DMA stall cycles to it during `step`, and `step` returns them.
//!
//! Fetch: if the bus has `code_window` (see `CodeWindow`), opcodes and
//! extension words are read straight from ROM/RAM without a bus call.
//!
//! Wait loops: if the bus has `wait_loop(cpu: *Self)`, a taken short
//! branch back to what may be a wait loop's head calls it (`note_loop`);
//! the bus may skip whole iterations of the loop by adding their cycles to
//! `cyc`, leaving every register as stepping them would.
//!
//! The dummy reads the 68000 does before CLR, Scc and MOVE from SR to
//! memory, and MOVEM's extra word read, are charged but not performed (no
//! read side effects on I/O). TAS writes back (the Genesis bus drops the
//! write on real hardware; a bus may ignore it).
//!
//! Flags are kept apart from SR, in the cheapest form to produce: the
//! operands of a b/w/l operation are shifted left so their top bit is bit
//! 31 ("left-aligned"), then N is bit 31 of `f_n`, Z is `f_z == 0`, V is
//! bit 31 of `f_v`, C and X are bools. `get_sr`/`set_sr` convert.
//!
//! Not attempted (SPEC.md section 4): the prefetch queue, address and bus
//! errors, the trace exception (T is kept in SR but never traps), level 7
//! as an edge-triggered NMI (it is taken like the others, above the mask),
//! 68010+ opcodes (they decode as illegal).

const tables = @import("m68k_tables.zig");
pub const Op = tables.Op;

pub const DecodeVariant = enum { table64k, two_level };
/// Which decode data `step` uses (both are complete and equivalent; the
/// test suite checks they agree on every opcode). M1 measurement
/// (badge-bench, calibrated, gcc-built game-logic workload, stub bus with
/// `code_window`): two-level 98.8 host cycles per 68000 instruction and
/// 86.5 KB cart `.text`; the 64 K table 96.6 cycles and 141.3 KB. The
/// two-level shape costs ~2% for 55 KB of flash, so it is the default.
pub const decode_variant: DecodeVariant = .two_level;

/// Handler of `op` through the 64 K table.
pub inline fn decode_table(op: u16) Op {
    return @fromBackingInt(@intCast(tables.decode[op]));
}

/// Handler of `op` through the two-level tables: bits 15-6 pick a row of
/// 64 handler indices, bits 5-0 the entry.
pub inline fn decode_two_level(op: u16) Op {
    const row: u32 = tables.l1[op >> 6];
    return @fromBackingInt(@intCast(tables.l2[row * 64 + (op & 63)]));
}

pub inline fn decode_op(op: u16) Op {
    return switch (decode_variant) {
        .table64k => decode_table(op),
        .two_level => decode_two_level(op),
    };
}

/// Exception vector numbers.
pub const Vector = struct {
    pub const illegal = 4;
    pub const div_zero = 5;
    pub const chk = 6;
    pub const trapv = 7;
    pub const privilege = 8;
    pub const line_a = 10;
    pub const line_f = 11;
    pub const autovector = 24; // + level
    pub const trap = 32; // + n
};

/// A run of the 68000 map that instructions can be fetched from directly:
/// bytes `base .. base + len` of the map are `ptr[0 .. len]` (big-endian
/// words). Returned by the optional `BusT.code_window(addr: u24) ?CodeWindow`
/// for ROM and work RAM; the CPU then fetches opcodes and extension words
/// with one bounds check instead of a bus call, and asks again only when
/// the PC leaves the window. Only memory without read side effects may be
/// a window; a bus without `code_window` fetches through `read16`.
pub const CodeWindow = struct {
    ptr: [*]const u8,
    base: u32,
    len: u32,
};

const Sz = enum { b, w, l };

inline fn shift_of(comptime sz: Sz) u5 {
    return switch (sz) {
        .b => 24,
        .w => 16,
        .l => 0,
    };
}

inline fn mask_of(comptime sz: Sz) u32 {
    return switch (sz) {
        .b => 0xFF,
        .w => 0xFFFF,
        .l => 0xFFFF_FFFF,
    };
}

inline fn sext8(v: u8) u32 {
    return @bitCast(@as(i32, @as(i8, @bitCast(v))));
}

inline fn sext16(v: u16) u32 {
    return @bitCast(@as(i32, @as(i16, @bitCast(v))));
}

/// Sign-extends the `sz` part of `v` to 32 bits.
inline fn sext(comptime sz: Sz, v: u32) u32 {
    return switch (sz) {
        .b => sext8(@truncate(v)),
        .w => sext16(@truncate(v)),
        .l => v,
    };
}

const top: u32 = 0x8000_0000;

/// Two-operand ALU operations sharing the flag code.
const Alu = enum { add, sub, cmp, and_, or_, eor, addx, subx };

/// Register-shift families.
const Shift = enum { as, ls, rox, ro };

/// Exact DIVU cycles (Jorge Cwik's model of the microcode), excluding the
/// effective address; divisor != 0.
fn divu_cycles(dividend: u32, divisor: u16) u32 {
    if ((dividend >> 16) >= divisor) return 10;
    var mcycles: u32 = 38;
    const hdivisor: u32 = @as(u32, divisor) << 16;
    var dvd = dividend;
    var i: u32 = 0;
    while (i < 15) : (i += 1) {
        const temp = dvd;
        dvd <<= 1;
        if (temp & top != 0) {
            dvd -%= hdivisor;
        } else {
            mcycles += 2;
            if (dvd >= hdivisor) {
                dvd -%= hdivisor;
                mcycles -= 1;
            }
        }
    }
    return mcycles * 2;
}

/// Exact DIVS cycles (Jorge Cwik), excluding the effective address;
/// divisor != 0.
fn divs_cycles(dividend: i32, divisor: i16) u32 {
    var mcycles: u32 = 6;
    if (dividend < 0) mcycles += 1;
    const adend: u32 = @abs(dividend);
    const adsor: u32 = @abs(@as(i32, divisor));
    if ((adend >> 16) >= adsor) return (mcycles + 2) * 2;
    var aquot: u32 = adend / adsor;
    // A quotient past 15 bits ends as early as the absolute overflow
    // (SingleStepTests; Cwik's model runs the full loop).
    if (aquot > 0x7FFF) return (mcycles + 2) * 2;
    mcycles += 55;
    if (divisor >= 0) {
        if (dividend >= 0) mcycles -= 1 else mcycles += 1;
    }
    var i: u32 = 0;
    while (i < 15) : (i += 1) {
        if (aquot & 0x8000 == 0) mcycles += 1;
        aquot <<= 1;
    }
    return mcycles * 2;
}

pub fn M68k(comptime BusT: type) type {
    return struct {
        const Self = @This();
        pub const Bus = BusT;

        /// Data registers D0-D7.
        d: [8]u32 = @splat(0),
        /// Address registers A0-A7; `a[7]` is the stack pointer of the
        /// current mode (SSP in supervisor, USP in user).
        a: [8]u32 = @splat(0),
        /// The stack pointer of the other mode (USP while supervisor, SSP
        /// while user); swapped with `a[7]` on every S-bit change.
        other_sp: u32 = 0,
        pc: u32 = 0,
        /// System byte of SR: T (bit 15), S (13), interrupt mask (10-8).
        /// The CCR bits here are always 0: the live flags are the `f_*`
        /// fields; `get_sr()` is the whole register.
        sr: u16 = 0x2700,
        /// X and C flags.
        f_x: bool = false,
        f_c: bool = false,
        /// N is bit 31; V is bit 31; Z is set when `f_z == 0`.
        f_n: u32 = 0,
        f_z: u32 = 1,
        f_v: u32 = 0,
        /// STOP executed; waits for an interrupt above the mask.
        stopped: bool = false,
        /// Cycles of the instruction in progress (bus accesses charge 4).
        cyc: u32 = 0,
        /// Fetch window (`CodeWindow`); `win_len` is its length minus one
        /// (so a word at any offset below it is inside), 0 = none.
        win_ptr: [*]const u8 = @ptrCast(&no_window),
        win_base: u32 = 0,
        win_len: u32 = 0,

        const has_window = @hasDecl(BusT, "code_window") and
            @typeInfo(@TypeOf(BusT.code_window)) == .@"fn";
        const has_irq_sample = @hasDecl(BusT, "irq_sample") and
            @typeInfo(@TypeOf(BusT.irq_sample)) == .@"fn";
        const has_wait_hook = @hasDecl(BusT, "wait_loop") and
            @typeInfo(@TypeOf(BusT.wait_loop)) == .@"fn";
        const no_window = [2]u8{ 0, 0 };

        /// Power-on/RESET: supervisor, interrupts masked, SSP and PC from
        /// the vectors at 000000 and 000004 (40 cycles on the real chip,
        /// not charged: nothing runs before it).
        pub fn reset(self: *Self, bus: *BusT) void {
            self.* = .{};
            self.a[7] = read32(bus, 0);
            self.pc = read32(bus, 4);
        }

        /// Run one instruction (or take an interrupt, or idle 4 cycles in
        /// STOP) and return its 68000 cycles.
        pub fn step(self: *Self, bus: *BusT) u32 {
            const lvl = if (has_irq_sample) bus.irq_sample() else bus.irq_level();
            if (lvl > self.mask()) return self.interrupt(bus, lvl);
            if (self.stopped) return 4;
            self.cyc = 4;
            self.exec(bus, self.fetch(bus));
            return self.cyc;
        }

        /// Forget the fetch window (after the bus's memory map or backing
        /// storage changes, e.g. a restored snapshot into another console).
        pub fn flush_code_window(self: *Self) void {
            self.win_len = 0;
        }

        /// The word at PC, PC += 2 (no cycles: callers charge them).
        inline fn fetch(self: *Self, bus: *BusT) u16 {
            const pc = self.pc;
            self.pc = pc +% 2;
            if (has_window) {
                const off = (pc & 0xFF_FFFF) -% self.win_base;
                if (off < self.win_len) {
                    const p = self.win_ptr + off;
                    return @as(u16, p[0]) << 8 | p[1];
                }
                return self.fetch_slow(bus, pc);
            }
            return bus.read16(@truncate(pc));
        }

        fn fetch_slow(self: *Self, bus: *BusT, pc: u32) u16 {
            const a: u24 = @truncate(pc);
            if (bus.code_window(a)) |w| {
                if (w.len >= 2 and a -% w.base < w.len - 1) {
                    self.win_ptr = w.ptr;
                    self.win_base = w.base;
                    self.win_len = w.len - 1;
                }
            }
            return bus.read16(a);
        }

        /// Interrupt mask (SR bits 8-10).
        pub inline fn mask(self: *const Self) u3 {
            return @truncate(self.sr >> 8);
        }

        pub inline fn supervisor(self: *const Self) bool {
            return self.sr & 0x2000 != 0;
        }

        pub fn get_ccr(self: *const Self) u8 {
            return @as(u8, @intFromBool(self.f_x)) << 4 |
                @as(u8, @intFromBool(self.f_n & top != 0)) << 3 |
                @as(u8, @intFromBool(self.f_z == 0)) << 2 |
                @as(u8, @intFromBool(self.f_v & top != 0)) << 1 |
                @as(u8, @intFromBool(self.f_c));
        }

        pub fn get_sr(self: *const Self) u16 {
            return self.sr | self.get_ccr();
        }

        pub fn set_ccr(self: *Self, v: u16) void {
            self.f_x = v & 0x10 != 0;
            self.f_n = if (v & 8 != 0) top else 0;
            self.f_z = @intFromBool(v & 4 == 0);
            self.f_v = if (v & 2 != 0) top else 0;
            self.f_c = v & 1 != 0;
        }

        /// Whole SR; swaps A7 with the other stack pointer when S changes.
        pub fn set_sr(self: *Self, v: u16) void {
            const hi = v & 0xA700;
            if ((hi ^ self.sr) & 0x2000 != 0) self.swap_sp();
            self.sr = hi;
            self.set_ccr(v);
        }

        /// USP and SSP whatever the mode (for tests and debuggers).
        pub fn usp(self: *const Self) u32 {
            return if (self.supervisor()) self.other_sp else self.a[7];
        }
        pub fn ssp(self: *const Self) u32 {
            return if (self.supervisor()) self.a[7] else self.other_sp;
        }

        inline fn swap_sp(self: *Self) void {
            const t = self.a[7];
            self.a[7] = self.other_sp;
            self.other_sp = t;
        }

        fn read32(bus: *BusT, addr: u32) u32 {
            return @as(u32, bus.read16(@truncate(addr))) << 16 | bus.read16(@truncate(addr +% 2));
        }

        // ---- Bus access, 4 cycles per word ----

        inline fn ext16(self: *Self, bus: *BusT) u16 {
            self.cyc += 4;
            return self.fetch(bus);
        }

        inline fn ext32(self: *Self, bus: *BusT) u32 {
            const hi: u32 = self.ext16(bus);
            return hi << 16 | self.ext16(bus);
        }

        inline fn rd(self: *Self, bus: *BusT, comptime sz: Sz, addr: u32) u32 {
            switch (sz) {
                .b => {
                    self.cyc += 4;
                    return bus.read8(@truncate(addr));
                },
                .w => {
                    self.cyc += 4;
                    return bus.read16(@truncate(addr));
                },
                .l => {
                    self.cyc += 8;
                    return read32(bus, addr);
                },
            }
        }

        inline fn wr(self: *Self, bus: *BusT, comptime sz: Sz, addr: u32, v: u32) void {
            switch (sz) {
                .b => {
                    self.cyc += 4;
                    bus.write8(@truncate(addr), @truncate(v));
                },
                .w => {
                    self.cyc += 4;
                    bus.write16(@truncate(addr), @truncate(v));
                },
                .l => {
                    self.cyc += 8;
                    bus.write16(@truncate(addr), @truncate(v >> 16));
                    bus.write16(@truncate(addr +% 2), @truncate(v));
                },
            }
        }

        fn push32(self: *Self, bus: *BusT, v: u32) void {
            self.a[7] -%= 4;
            self.wr(bus, .l, self.a[7], v);
        }

        fn pop32(self: *Self, bus: *BusT) u32 {
            const v = self.rd(bus, .l, self.a[7]);
            self.a[7] +%= 4;
            return v;
        }

        fn pop16(self: *Self, bus: *BusT) u16 {
            const v = self.rd(bus, .w, self.a[7]);
            self.a[7] +%= 2;
            return @truncate(v);
        }

        // ---- Registers ----

        inline fn set_d(self: *Self, comptime sz: Sz, r: u3, v: u32) void {
            const m = mask_of(sz);
            self.d[r] = (self.d[r] & ~m) | (v & m);
        }

        /// Register 0-15: D0-D7 then A0-A7 (MOVEM, index words).
        inline fn reg_ptr(self: *Self, i: u4) *u32 {
            return if (i < 8) &self.d[@as(u3, @truncate(i))] else &self.a[@as(u3, @truncate(i))];
        }

        // ---- Flags ----

        /// N and Z from a left-aligned result, V and C cleared.
        inline fn logic_flags(self: *Self, r: u32) void {
            self.f_n = r;
            self.f_z = r;
            self.f_v = 0;
            self.f_c = false;
        }

        fn cond(self: *const Self, cc: u4) bool {
            const c = self.f_c;
            const z = self.f_z == 0;
            const n = self.f_n & top != 0;
            const v = self.f_v & top != 0;
            return switch (cc) {
                0 => true,
                1 => false,
                2 => !c and !z,
                3 => c or z,
                4 => !c,
                5 => c,
                6 => !z,
                7 => z,
                8 => !v,
                9 => v,
                10 => !n,
                11 => n,
                12 => n == v,
                13 => n != v,
                14 => !z and n == v,
                15 => z or n != v,
            };
        }

        /// `dst op src` at size `sz`, flags set; returns the result (the
        /// low `sz` bits, upper bits zero). `cmp` returns `dst`.
        inline fn alu(self: *Self, comptime k: Alu, comptime sz: Sz, src: u32, dst: u32) u32 {
            const sh = comptime shift_of(sz);
            const s = src << sh;
            const d = dst << sh;
            switch (k) {
                .add => {
                    const r = @addWithOverflow(d, s);
                    self.f_n = r[0];
                    self.f_z = r[0];
                    self.f_v = (s ^ r[0]) & (d ^ r[0]);
                    self.f_c = r[1] != 0;
                    self.f_x = self.f_c;
                    return r[0] >> sh;
                },
                .sub, .cmp => {
                    const r = @subWithOverflow(d, s);
                    self.f_n = r[0];
                    self.f_z = r[0];
                    self.f_v = (s ^ d) & (r[0] ^ d);
                    self.f_c = r[1] != 0;
                    if (k == .cmp) return dst;
                    self.f_x = self.f_c;
                    return r[0] >> sh;
                },
                .and_, .or_, .eor => {
                    const r = switch (k) {
                        .and_ => d & s,
                        .or_ => d | s,
                        else => d ^ s,
                    };
                    self.logic_flags(r);
                    return r >> sh;
                },
                .addx => {
                    const xin = @as(u32, @intFromBool(self.f_x)) << sh;
                    const r1 = @addWithOverflow(d, s);
                    const r2 = @addWithOverflow(r1[0], xin);
                    const r = r2[0];
                    self.f_n = r;
                    self.f_z |= r;
                    self.f_v = (s ^ r) & (d ^ r);
                    self.f_c = (r1[1] | r2[1]) != 0;
                    self.f_x = self.f_c;
                    return r >> sh;
                },
                .subx => {
                    const xin = @as(u32, @intFromBool(self.f_x)) << sh;
                    const r1 = @subWithOverflow(d, s);
                    const r2 = @subWithOverflow(r1[0], xin);
                    const r = r2[0];
                    self.f_n = r;
                    self.f_z |= r;
                    self.f_v = (s ^ d) & (r ^ d);
                    self.f_c = (r1[1] | r2[1]) != 0;
                    self.f_x = self.f_c;
                    return r >> sh;
                },
            }
        }

        // ---- Effective addresses ----

        /// Address of a memory mode (2-7, not immediate). `(An)+`/`-(An)`
        /// step by the size (A7 by 2 for bytes). `read` charges -(An)'s 2
        /// internal cycles (source and read-modify-write operands; MOVE's
        /// destination and MOVEM do not pay them).
        inline fn ea_addr(self: *Self, bus: *BusT, comptime sz: Sz, mode: u3, reg: u3, comptime read: bool) u32 {
            // (An) and (An)+ inline (most destinations), the rest out of
            // line: a call per operand cost ~20 cycles of push and pop.
            if (mode == 2 or mode == 3) return self.ea_addr_inl(bus, sz, mode, reg, read);
            return self.ea_addr_far(bus, sz, mode, reg, read);
        }

        noinline fn ea_addr_far(self: *Self, bus: *BusT, comptime sz: Sz, mode: u3, reg: u3, comptime read: bool) u32 {
            return self.ea_addr_inl(bus, sz, mode, reg, read);
        }

        inline fn ea_addr_inl(self: *Self, bus: *BusT, comptime sz: Sz, mode: u3, reg: u3, comptime read: bool) u32 {
            const step_n: u32 = switch (sz) {
                .b => if (reg == 7) 2 else 1,
                .w => 2,
                .l => 4,
            };
            switch (mode) {
                2 => return self.a[reg],
                3 => {
                    const a = self.a[reg];
                    self.a[reg] = a +% step_n;
                    return a;
                },
                4 => {
                    if (read) self.cyc += 2;
                    const a = self.a[reg] -% step_n;
                    self.a[reg] = a;
                    return a;
                },
                5 => {
                    const base = self.a[reg];
                    return base +% sext16(self.ext16(bus));
                },
                6 => return self.indexed(bus, self.a[reg]),
                else => switch (reg) {
                    0 => return sext16(self.ext16(bus)),
                    1 => return self.ext32(bus),
                    2 => {
                        const base = self.pc;
                        return base +% sext16(self.ext16(bus));
                    },
                    else => {
                        const base = self.pc;
                        return self.indexed(bus, base);
                    },
                },
            }
        }

        /// d8(base,Xn): brief extension word, 2 internal cycles.
        fn indexed(self: *Self, bus: *BusT, base: u32) u32 {
            const ext = self.ext16(bus);
            self.cyc += 2;
            const xr: u4 = @truncate(ext >> 12);
            const x = self.reg_ptr(xr).*;
            const xi = if (ext & 0x800 != 0) x else sext16(@truncate(x));
            return base +% xi +% sext8(@truncate(ext));
        }

        inline fn imm(self: *Self, bus: *BusT, comptime sz: Sz) u32 {
            return switch (sz) {
                .b => self.ext16(bus) & 0xFF,
                .w => self.ext16(bus),
                .l => self.ext32(bus),
            };
        }

        /// Source operand of any mode, low `sz` bits. Registers, (An) and
        /// (An)+ inline (the common cases pay no call; d16(An) inline too
        /// costs 22 KB of flash and was slower), the other memory modes and
        /// immediates out of line.
        inline fn read_ea(self: *Self, bus: *BusT, comptime sz: Sz, mode: u3, reg: u3) u32 {
            if (mode == 0) return self.d[reg] & mask_of(sz);
            if (mode == 1) return self.a[reg] & mask_of(sz);
            if (mode == 2 or mode == 3) return self.rd(bus, sz, self.ea_addr_inl(bus, sz, mode, reg, true));
            return self.read_ea_mem(bus, sz, mode, reg);
        }

        noinline fn read_ea_mem(self: *Self, bus: *BusT, comptime sz: Sz, mode: u3, reg: u3) u32 {
            if (mode == 7 and reg == 4) return self.imm(bus, sz);
            return self.rd(bus, sz, self.ea_addr_inl(bus, sz, mode, reg, true));
        }

        /// Destination write (MOVE, Scc, CLR): Dn or memory, no -(An) cost.
        fn write_ea(self: *Self, bus: *BusT, comptime sz: Sz, mode: u3, reg: u3, v: u32) void {
            if (mode == 0) return self.set_d(sz, reg, v);
            self.wr(bus, sz, self.ea_addr(bus, sz, mode, reg, false), v);
        }

        /// Control address (LEA, PEA, JMP, JSR, MOVEM): modes 2, 5, 6, 7.0-3.
        inline fn ctrl_addr(self: *Self, bus: *BusT, mode: u3, reg: u3) u32 {
            return self.ea_addr(bus, .l, mode, reg, false);
        }

        inline fn is_indexed(mode: u3, reg: u3) bool {
            return mode == 6 or (mode == 7 and reg == 3);
        }

        // ---- Exceptions ----

        fn enter_super(self: *Self) u16 {
            const old = self.get_sr();
            if (self.sr & 0x2000 == 0) self.swap_sp();
            self.sr = (self.sr | 0x2000) & 0x7FFF;
            return old;
        }

        /// Group 1/2 exception frame (PC, SR) and vector fetch: 20 cycles
        /// of accesses; the caller adds its internal cycles.
        fn exception(self: *Self, bus: *BusT, vector: u32, stacked_pc: u32) void {
            const old = self.enter_super();
            self.a[7] -%= 6;
            const sp = self.a[7];
            self.wr(bus, .w, sp +% 4, stacked_pc & 0xFFFF);
            self.wr(bus, .w, sp, old);
            self.wr(bus, .w, sp +% 2, stacked_pc >> 16);
            self.pc = self.rd(bus, .l, vector * 4);
        }

        /// ILLEGAL, line A/F, privilege violation: 34 cycles, the stacked PC
        /// is the opcode's.
        fn trap_here(self: *Self, bus: *BusT, vector: u32) void {
            self.exception(bus, vector, self.pc -% 2);
            self.cyc += 10;
        }

        fn interrupt(self: *Self, bus: *BusT, lvl: u3) u32 {
            self.stopped = false;
            self.cyc = 0;
            const old = self.enter_super();
            self.sr = (self.sr & ~@as(u16, 0x0700)) | @as(u16, lvl) << 8;
            self.a[7] -%= 6;
            const sp = self.a[7];
            self.wr(bus, .w, sp +% 4, self.pc & 0xFFFF);
            self.wr(bus, .w, sp, old);
            self.wr(bus, .w, sp +% 2, self.pc >> 16);
            bus.ack_irq(lvl);
            self.pc = self.rd(bus, .l, (Vector.autovector + @as(u32, lvl)) * 4);
            self.cyc += 24;
            return self.cyc;
        }

        // ---- Dispatch ----

        fn exec(self: *Self, bus: *BusT, op: u16) void {
            switch (decode_op(op)) {
                .illegal => self.trap_here(bus, Vector.illegal),
                .linea => self.trap_here(bus, Vector.line_a),
                .linef => self.trap_here(bus, Vector.line_f),

                .ori_b => self.op_imm(bus, .or_, .b, op),
                .ori_w => self.op_imm(bus, .or_, .w, op),
                .ori_l => self.op_imm(bus, .or_, .l, op),
                .andi_b => self.op_imm(bus, .and_, .b, op),
                .andi_w => self.op_imm(bus, .and_, .w, op),
                .andi_l => self.op_imm(bus, .and_, .l, op),
                .subi_b => self.op_imm(bus, .sub, .b, op),
                .subi_w => self.op_imm(bus, .sub, .w, op),
                .subi_l => self.op_imm(bus, .sub, .l, op),
                .addi_b => self.op_imm(bus, .add, .b, op),
                .addi_w => self.op_imm(bus, .add, .w, op),
                .addi_l => self.op_imm(bus, .add, .l, op),
                .eori_b => self.op_imm(bus, .eor, .b, op),
                .eori_w => self.op_imm(bus, .eor, .w, op),
                .eori_l => self.op_imm(bus, .eor, .l, op),
                .cmpi_b => self.op_imm(bus, .cmp, .b, op),
                .cmpi_w => self.op_imm(bus, .cmp, .w, op),
                .cmpi_l => self.op_imm(bus, .cmp, .l, op),
                .ori_ccr => self.op_ccr(bus, .or_),
                .andi_ccr => self.op_ccr(bus, .and_),
                .eori_ccr => self.op_ccr(bus, .eor),
                .ori_sr => self.op_sr(bus, .or_),
                .andi_sr => self.op_sr(bus, .and_),
                .eori_sr => self.op_sr(bus, .eor),

                .btst_reg => self.op_bit(bus, .tst, false, op),
                .bchg_reg => self.op_bit(bus, .chg, false, op),
                .bclr_reg => self.op_bit(bus, .clr, false, op),
                .bset_reg => self.op_bit(bus, .set, false, op),
                .btst_imm => self.op_bit(bus, .tst, true, op),
                .bchg_imm => self.op_bit(bus, .chg, true, op),
                .bclr_imm => self.op_bit(bus, .clr, true, op),
                .bset_imm => self.op_bit(bus, .set, true, op),
                .movep_mr_w => self.op_movep(bus, .w, false, op),
                .movep_mr_l => self.op_movep(bus, .l, false, op),
                .movep_rm_w => self.op_movep(bus, .w, true, op),
                .movep_rm_l => self.op_movep(bus, .l, true, op),

                .move_b => self.op_move(bus, .b, op),
                .move_w => self.op_move(bus, .w, op),
                .move_l => self.op_move(bus, .l, op),
                .move_b_dn => self.op_move_dn(bus, .b, op),
                .move_w_dn => self.op_move_dn(bus, .w, op),
                .move_l_dn => self.op_move_dn(bus, .l, op),
                .movea_w => self.op_movea(bus, .w, op),
                .movea_l => self.op_movea(bus, .l, op),

                .negx_b => self.op_unary(bus, .negx, .b, op),
                .negx_w => self.op_unary(bus, .negx, .w, op),
                .negx_l => self.op_unary(bus, .negx, .l, op),
                .clr_b => self.op_unary(bus, .clr, .b, op),
                .clr_w => self.op_unary(bus, .clr, .w, op),
                .clr_l => self.op_unary(bus, .clr, .l, op),
                .neg_b => self.op_unary(bus, .neg, .b, op),
                .neg_w => self.op_unary(bus, .neg, .w, op),
                .neg_l => self.op_unary(bus, .neg, .l, op),
                .not_b => self.op_unary(bus, .not_, .b, op),
                .not_w => self.op_unary(bus, .not_, .w, op),
                .not_l => self.op_unary(bus, .not_, .l, op),
                .tst_b => self.op_tst(bus, .b, op),
                .tst_w => self.op_tst(bus, .w, op),
                .tst_l => self.op_tst(bus, .l, op),

                .move_from_sr => self.op_move_from_sr(bus, op),
                .move_to_ccr => self.op_move_to_ccr(bus, op),
                .move_to_sr => self.op_move_to_sr(bus, op),
                .nbcd => self.op_nbcd(bus, op),
                .swap => self.op_swap(op),
                .pea => self.op_pea(bus, op),
                .ext_w => self.op_ext(.w, op),
                .ext_l => self.op_ext(.l, op),
                .movem_rm_w => self.op_movem_rm(bus, .w, op),
                .movem_rm_l => self.op_movem_rm(bus, .l, op),
                .movem_mr_w => self.op_movem_mr(bus, .w, op),
                .movem_mr_l => self.op_movem_mr(bus, .l, op),
                .tas => self.op_tas(bus, op),
                .trap => {
                    self.exception(bus, Vector.trap + @as(u32, op & 15), self.pc);
                    self.cyc += 10;
                },
                .link => self.op_link(bus, op),
                .unlk => self.op_unlk(bus, op),
                .move_to_usp => {
                    if (!self.supervisor()) return self.trap_here(bus, Vector.privilege);
                    self.other_sp = self.a[@as(u3, @truncate(op))];
                },
                .move_from_usp => {
                    if (!self.supervisor()) return self.trap_here(bus, Vector.privilege);
                    self.a[@as(u3, @truncate(op))] = self.other_sp;
                },
                .reset => {
                    if (!self.supervisor()) return self.trap_here(bus, Vector.privilege);
                    self.cyc += 128;
                },
                .nop => {},
                .stop => self.op_stop(bus),
                .rte => self.op_rte(bus),
                .rts => {
                    self.pc = self.pop32(bus);
                    self.cyc += 4;
                },
                .trapv => if (self.f_v & top != 0) {
                    self.exception(bus, Vector.trapv, self.pc);
                    self.cyc += 10;
                },
                .rtr => {
                    self.set_ccr(self.pop16(bus));
                    self.pc = self.pop32(bus);
                    self.cyc += 4;
                },
                .jsr => self.op_jump(bus, true, op),
                .jmp => self.op_jump(bus, false, op),
                .chk => self.op_chk(bus, op),
                .lea => self.op_lea(bus, op),

                .addq_b => self.op_quick(bus, .add, .b, op),
                .addq_w => self.op_quick(bus, .add, .w, op),
                .addq_l => self.op_quick(bus, .add, .l, op),
                .subq_b => self.op_quick(bus, .sub, .b, op),
                .subq_w => self.op_quick(bus, .sub, .w, op),
                .subq_l => self.op_quick(bus, .sub, .l, op),
                .addq_a => self.op_quick_a(false, op),
                .subq_a => self.op_quick_a(true, op),
                .scc => self.op_scc(bus, op),
                .dbcc => self.op_dbcc(bus, op),
                .bra => self.op_bra(bus, op),
                .bsr => self.op_bsr(bus, op),
                .bcc => self.op_bcc(bus, op),
                .moveq => {
                    const v = sext8(@truncate(op));
                    self.d[@as(u3, @truncate(op >> 9))] = v;
                    self.logic_flags(v);
                },

                .or_ea_dn_b => self.op_ea_dn(bus, .or_, .b, op),
                .or_ea_dn_w => self.op_ea_dn(bus, .or_, .w, op),
                .or_ea_dn_l => self.op_ea_dn(bus, .or_, .l, op),
                .or_dn_ea_b => self.op_dn_ea(bus, .or_, .b, op),
                .or_dn_ea_w => self.op_dn_ea(bus, .or_, .w, op),
                .or_dn_ea_l => self.op_dn_ea(bus, .or_, .l, op),
                .and_ea_dn_b => self.op_ea_dn(bus, .and_, .b, op),
                .and_ea_dn_w => self.op_ea_dn(bus, .and_, .w, op),
                .and_ea_dn_l => self.op_ea_dn(bus, .and_, .l, op),
                .and_dn_ea_b => self.op_dn_ea(bus, .and_, .b, op),
                .and_dn_ea_w => self.op_dn_ea(bus, .and_, .w, op),
                .and_dn_ea_l => self.op_dn_ea(bus, .and_, .l, op),
                .sub_ea_dn_b => self.op_ea_dn(bus, .sub, .b, op),
                .sub_ea_dn_w => self.op_ea_dn(bus, .sub, .w, op),
                .sub_ea_dn_l => self.op_ea_dn(bus, .sub, .l, op),
                .sub_dn_ea_b => self.op_dn_ea(bus, .sub, .b, op),
                .sub_dn_ea_w => self.op_dn_ea(bus, .sub, .w, op),
                .sub_dn_ea_l => self.op_dn_ea(bus, .sub, .l, op),
                .add_ea_dn_b => self.op_ea_dn(bus, .add, .b, op),
                .add_ea_dn_w => self.op_ea_dn(bus, .add, .w, op),
                .add_ea_dn_l => self.op_ea_dn(bus, .add, .l, op),
                .add_dn_ea_b => self.op_dn_ea(bus, .add, .b, op),
                .add_dn_ea_w => self.op_dn_ea(bus, .add, .w, op),
                .add_dn_ea_l => self.op_dn_ea(bus, .add, .l, op),
                .cmp_b => self.op_ea_dn(bus, .cmp, .b, op),
                .cmp_w => self.op_ea_dn(bus, .cmp, .w, op),
                .cmp_l => self.op_ea_dn(bus, .cmp, .l, op),
                .eor_b => self.op_eor(bus, .b, op),
                .eor_w => self.op_eor(bus, .w, op),
                .eor_l => self.op_eor(bus, .l, op),
                .suba_w => self.op_adda(bus, true, .w, op),
                .suba_l => self.op_adda(bus, true, .l, op),
                .adda_w => self.op_adda(bus, false, .w, op),
                .adda_l => self.op_adda(bus, false, .l, op),
                .cmpa_w => self.op_cmpa(bus, .w, op),
                .cmpa_l => self.op_cmpa(bus, .l, op),
                .subx_r_b => self.op_x_r(.subx, .b, op),
                .subx_r_w => self.op_x_r(.subx, .w, op),
                .subx_r_l => self.op_x_r(.subx, .l, op),
                .subx_m_b => self.op_x_m(bus, .subx, .b, op),
                .subx_m_w => self.op_x_m(bus, .subx, .w, op),
                .subx_m_l => self.op_x_m(bus, .subx, .l, op),
                .addx_r_b => self.op_x_r(.addx, .b, op),
                .addx_r_w => self.op_x_r(.addx, .w, op),
                .addx_r_l => self.op_x_r(.addx, .l, op),
                .addx_m_b => self.op_x_m(bus, .addx, .b, op),
                .addx_m_w => self.op_x_m(bus, .addx, .w, op),
                .addx_m_l => self.op_x_m(bus, .addx, .l, op),
                .cmpm_b => self.op_cmpm(bus, .b, op),
                .cmpm_w => self.op_cmpm(bus, .w, op),
                .cmpm_l => self.op_cmpm(bus, .l, op),
                .divu => self.op_divu(bus, op),
                .divs => self.op_divs(bus, op),
                .mulu => self.op_mul(bus, false, op),
                .muls => self.op_mul(bus, true, op),
                .abcd_r => self.op_bcd_r(false, op),
                .abcd_m => self.op_bcd_m(bus, false, op),
                .sbcd_r => self.op_bcd_r(true, op),
                .sbcd_m => self.op_bcd_m(bus, true, op),
                .exg_dd => {
                    const x: u3 = @truncate(op >> 9);
                    const y: u3 = @truncate(op);
                    const t = self.d[x];
                    self.d[x] = self.d[y];
                    self.d[y] = t;
                    self.cyc += 2;
                },
                .exg_aa => {
                    const x: u3 = @truncate(op >> 9);
                    const y: u3 = @truncate(op);
                    const t = self.a[x];
                    self.a[x] = self.a[y];
                    self.a[y] = t;
                    self.cyc += 2;
                },
                .exg_da => {
                    const x: u3 = @truncate(op >> 9);
                    const y: u3 = @truncate(op);
                    const t = self.d[x];
                    self.d[x] = self.a[y];
                    self.a[y] = t;
                    self.cyc += 2;
                },

                .asl_b => self.op_shift(.as, true, .b, op),
                .asl_w => self.op_shift(.as, true, .w, op),
                .asl_l => self.op_shift(.as, true, .l, op),
                .asr_b => self.op_shift(.as, false, .b, op),
                .asr_w => self.op_shift(.as, false, .w, op),
                .asr_l => self.op_shift(.as, false, .l, op),
                .lsl_b => self.op_shift(.ls, true, .b, op),
                .lsl_w => self.op_shift(.ls, true, .w, op),
                .lsl_l => self.op_shift(.ls, true, .l, op),
                .lsr_b => self.op_shift(.ls, false, .b, op),
                .lsr_w => self.op_shift(.ls, false, .w, op),
                .lsr_l => self.op_shift(.ls, false, .l, op),
                .roxl_b => self.op_shift(.rox, true, .b, op),
                .roxl_w => self.op_shift(.rox, true, .w, op),
                .roxl_l => self.op_shift(.rox, true, .l, op),
                .roxr_b => self.op_shift(.rox, false, .b, op),
                .roxr_w => self.op_shift(.rox, false, .w, op),
                .roxr_l => self.op_shift(.rox, false, .l, op),
                .rol_b => self.op_shift(.ro, true, .b, op),
                .rol_w => self.op_shift(.ro, true, .w, op),
                .rol_l => self.op_shift(.ro, true, .l, op),
                .ror_b => self.op_shift(.ro, false, .b, op),
                .ror_w => self.op_shift(.ro, false, .w, op),
                .ror_l => self.op_shift(.ro, false, .l, op),
                .asl_mem => self.op_shift_mem(bus, .as, true, op),
                .asr_mem => self.op_shift_mem(bus, .as, false, op),
                .lsl_mem => self.op_shift_mem(bus, .ls, true, op),
                .lsr_mem => self.op_shift_mem(bus, .ls, false, op),
                .roxl_mem => self.op_shift_mem(bus, .rox, true, op),
                .roxr_mem => self.op_shift_mem(bus, .rox, false, op),
                .rol_mem => self.op_shift_mem(bus, .ro, true, op),
                .ror_mem => self.op_shift_mem(bus, .ro, false, op),
            }
        }

        // ---- Handlers ----

        /// <ea>,Dn: ADD, SUB, AND, OR, CMP.
        fn op_ea_dn(self: *Self, bus: *BusT, comptime k: Alu, comptime sz: Sz, op: u16) void {
            const mode: u3 = @truncate(op >> 3);
            const reg: u3 = @truncate(op);
            const rx: u3 = @truncate(op >> 9);
            const src = self.read_ea(bus, sz, mode, reg);
            const r = self.alu(k, sz, src, self.d[rx]);
            if (k != .cmp) self.set_d(sz, rx, r);
            if (sz == .l) {
                // 6 + ea; 8 + ea from a register or an immediate (not CMP).
                self.cyc += if (k != .cmp and (mode < 2 or (mode == 7 and reg == 4))) 4 else 2;
            }
        }

        /// Dn,<ea> to memory: ADD, SUB, AND, OR.
        fn op_dn_ea(self: *Self, bus: *BusT, comptime k: Alu, comptime sz: Sz, op: u16) void {
            const addr = self.ea_addr(bus, sz, @truncate(op >> 3), @truncate(op), true);
            const dst = self.rd(bus, sz, addr);
            const r = self.alu(k, sz, self.d[@as(u3, @truncate(op >> 9))], dst);
            self.wr(bus, sz, addr, r);
        }

        /// EOR Dn,<ea> (Dn or memory).
        fn op_eor(self: *Self, bus: *BusT, comptime sz: Sz, op: u16) void {
            const mode: u3 = @truncate(op >> 3);
            const reg: u3 = @truncate(op);
            const src = self.d[@as(u3, @truncate(op >> 9))];
            if (mode == 0) {
                self.set_d(sz, reg, self.alu(.eor, sz, src, self.d[reg]));
                if (sz == .l) self.cyc += 4;
                return;
            }
            const addr = self.ea_addr(bus, sz, mode, reg, true);
            const dst = self.rd(bus, sz, addr);
            self.wr(bus, sz, addr, self.alu(.eor, sz, src, dst));
        }

        /// Read-modify-write of a data-alterable operand with `src`.
        inline fn rmw_alu(self: *Self, bus: *BusT, comptime k: Alu, comptime sz: Sz, mode: u3, reg: u3, src: u32, reg_extra: u32) void {
            if (mode == 0) {
                const r = self.alu(k, sz, src, self.d[reg]);
                if (k != .cmp) self.set_d(sz, reg, r);
                self.cyc += reg_extra;
                return;
            }
            const addr = self.ea_addr(bus, sz, mode, reg, true);
            const dst = self.rd(bus, sz, addr);
            const r = self.alu(k, sz, src, dst);
            if (k != .cmp) self.wr(bus, sz, addr, r);
        }

        /// ORI/ANDI/SUBI/ADDI/EORI/CMPI #imm,<ea>.
        fn op_imm(self: *Self, bus: *BusT, comptime k: Alu, comptime sz: Sz, op: u16) void {
            const src = self.imm(bus, sz);
            const extra: u32 = if (sz == .l) (if (k == .cmp) 2 else 4) else 0;
            self.rmw_alu(bus, k, sz, @truncate(op >> 3), @truncate(op), src, extra);
        }

        /// ADDQ/SUBQ #1-8,<ea> (not An).
        fn op_quick(self: *Self, bus: *BusT, comptime k: Alu, comptime sz: Sz, op: u16) void {
            const q: u32 = ((op >> 9) -% 1 & 7) + 1;
            self.rmw_alu(bus, k, sz, @truncate(op >> 3), @truncate(op), q, if (sz == .l) 4 else 0);
        }

        /// ADDQ/SUBQ to An: the whole register, no flags; 8 cycles for
        /// .w, 6 for .l (SingleStepTests; the manual says 8 for both).
        fn op_quick_a(self: *Self, comptime sub: bool, op: u16) void {
            const q: u32 = ((op >> 9) -% 1 & 7) + 1;
            const r: u3 = @truncate(op);
            self.a[r] = if (sub) self.a[r] -% q else self.a[r] +% q;
            self.cyc += if (op & 0x80 != 0) 2 else 4;
        }

        const Unary = enum { negx, clr, neg, not_ };

        fn op_unary(self: *Self, bus: *BusT, comptime k: Unary, comptime sz: Sz, op: u16) void {
            const mode: u3 = @truncate(op >> 3);
            const reg: u3 = @truncate(op);
            var addr: u32 = 0;
            var v: u32 = undefined;
            if (mode == 0) {
                v = self.d[reg];
                if (sz == .l) self.cyc += 2;
            } else {
                addr = self.ea_addr(bus, sz, mode, reg, true);
                if (k == .clr) {
                    // The 68000 reads before it clears; the cycles only.
                    self.cyc += if (sz == .l) 8 else 4;
                } else v = self.rd(bus, sz, addr);
            }
            const r: u32 = switch (k) {
                .neg => self.alu(.sub, sz, v, 0),
                .negx => self.alu(.subx, sz, v, 0),
                .not_ => blk: {
                    const n = ~v & mask_of(sz);
                    self.logic_flags(n << comptime shift_of(sz));
                    break :blk n;
                },
                .clr => blk: {
                    self.logic_flags(0);
                    break :blk 0;
                },
            };
            if (mode == 0) self.set_d(sz, reg, r) else self.wr(bus, sz, addr, r);
        }

        fn op_tst(self: *Self, bus: *BusT, comptime sz: Sz, op: u16) void {
            const v = self.read_ea(bus, sz, @truncate(op >> 3), @truncate(op));
            self.logic_flags(v << comptime shift_of(sz));
        }

        fn op_move(self: *Self, bus: *BusT, comptime sz: Sz, op: u16) void {
            const v = self.read_ea(bus, sz, @truncate(op >> 3), @truncate(op));
            self.logic_flags(v << comptime shift_of(sz));
            self.wr(bus, sz, self.ea_addr(bus, sz, @truncate(op >> 6), @truncate(op >> 9), false), v);
        }

        fn op_move_dn(self: *Self, bus: *BusT, comptime sz: Sz, op: u16) void {
            const v = self.read_ea(bus, sz, @truncate(op >> 3), @truncate(op));
            self.logic_flags(v << comptime shift_of(sz));
            self.set_d(sz, @truncate(op >> 9), v);
        }

        fn op_movea(self: *Self, bus: *BusT, comptime sz: Sz, op: u16) void {
            const v = self.read_ea(bus, sz, @truncate(op >> 3), @truncate(op));
            self.a[@as(u3, @truncate(op >> 9))] = sext(sz, v);
        }

        fn op_adda(self: *Self, bus: *BusT, comptime sub: bool, comptime sz: Sz, op: u16) void {
            const mode: u3 = @truncate(op >> 3);
            const reg: u3 = @truncate(op);
            const src = sext(sz, self.read_ea(bus, sz, mode, reg));
            const rx: u3 = @truncate(op >> 9);
            self.a[rx] = if (sub) self.a[rx] -% src else self.a[rx] +% src;
            if (sz == .w) {
                self.cyc += 4;
            } else {
                self.cyc += if (mode < 2 or (mode == 7 and reg == 4)) 4 else 2;
            }
        }

        fn op_cmpa(self: *Self, bus: *BusT, comptime sz: Sz, op: u16) void {
            const src = sext(sz, self.read_ea(bus, sz, @truncate(op >> 3), @truncate(op)));
            _ = self.alu(.cmp, .l, src, self.a[@as(u3, @truncate(op >> 9))]);
            self.cyc += 2;
        }

        fn op_x_r(self: *Self, comptime k: Alu, comptime sz: Sz, op: u16) void {
            const rx: u3 = @truncate(op >> 9);
            const r = self.alu(k, sz, self.d[@as(u3, @truncate(op))], self.d[rx]);
            self.set_d(sz, rx, r);
            if (sz == .l) self.cyc += 4;
        }

        fn op_x_m(self: *Self, bus: *BusT, comptime k: Alu, comptime sz: Sz, op: u16) void {
            const src = self.rd(bus, sz, self.ea_addr(bus, sz, 4, @truncate(op), false));
            const addr = self.ea_addr(bus, sz, 4, @truncate(op >> 9), false);
            const dst = self.rd(bus, sz, addr);
            self.wr(bus, sz, addr, self.alu(k, sz, src, dst));
            self.cyc += 2;
        }

        fn op_cmpm(self: *Self, bus: *BusT, comptime sz: Sz, op: u16) void {
            const src = self.rd(bus, sz, self.ea_addr(bus, sz, 3, @truncate(op), false));
            const dst = self.rd(bus, sz, self.ea_addr(bus, sz, 3, @truncate(op >> 9), false));
            _ = self.alu(.cmp, sz, src, dst);
        }

        fn op_ccr(self: *Self, bus: *BusT, comptime k: Alu) void {
            const v = self.ext16(bus) & 0x1F;
            const c = self.get_ccr();
            self.set_ccr(switch (k) {
                .or_ => c | v,
                .and_ => c & v,
                else => c ^ v,
            });
            self.cyc += 12;
        }

        fn op_sr(self: *Self, bus: *BusT, comptime k: Alu) void {
            if (!self.supervisor()) return self.trap_here(bus, Vector.privilege);
            const v = self.ext16(bus);
            const s = self.get_sr();
            self.set_sr(switch (k) {
                .or_ => s | v,
                .and_ => s & v,
                else => s ^ v,
            });
            self.cyc += 12;
        }

        fn op_move_from_sr(self: *Self, bus: *BusT, op: u16) void {
            const mode: u3 = @truncate(op >> 3);
            const reg: u3 = @truncate(op);
            if (mode == 0) {
                self.set_d(.w, reg, self.get_sr());
                self.cyc += 2;
                return;
            }
            const addr = self.ea_addr(bus, .w, mode, reg, true);
            self.cyc += 4; // the 68000 reads the operand first
            self.wr(bus, .w, addr, self.get_sr());
        }

        fn op_move_to_ccr(self: *Self, bus: *BusT, op: u16) void {
            const v = self.read_ea(bus, .w, @truncate(op >> 3), @truncate(op));
            self.set_ccr(@truncate(v));
            self.cyc += 8;
        }

        fn op_move_to_sr(self: *Self, bus: *BusT, op: u16) void {
            if (!self.supervisor()) return self.trap_here(bus, Vector.privilege);
            const v = self.read_ea(bus, .w, @truncate(op >> 3), @truncate(op));
            self.set_sr(@truncate(v));
            self.cyc += 8;
        }

        const BitOp = enum { tst, chg, clr, set };

        fn op_bit(self: *Self, bus: *BusT, comptime k: BitOp, comptime static: bool, op: u16) void {
            const mode: u3 = @truncate(op >> 3);
            const reg: u3 = @truncate(op);
            const n: u32 = if (static) self.ext16(bus) else self.d[@as(u3, @truncate(op >> 9))];
            if (mode == 0) {
                const b: u5 = @truncate(n);
                const m = @as(u32, 1) << b;
                const v = self.d[reg];
                self.f_z = v & m;
                switch (k) {
                    .tst => {},
                    .chg => self.d[reg] = v ^ m,
                    .clr => self.d[reg] = v & ~m,
                    .set => self.d[reg] = v | m,
                }
                self.cyc += switch (k) {
                    .tst => 2,
                    .chg, .set => if (b < 16) 2 else 4,
                    .clr => if (b < 16) 4 else 6,
                };
                return;
            }
            const m = @as(u32, 1) << @as(u3, @truncate(n));
            if (k == .tst) {
                self.f_z = self.read_ea(bus, .b, mode, reg) & m;
                // BTST Dn,#imm: 10 cycles, not 8.
                if (!static and mode == 7 and reg == 4) self.cyc += 2;
                return;
            }
            const addr = self.ea_addr(bus, .b, mode, reg, true);
            const v = self.rd(bus, .b, addr);
            self.f_z = v & m;
            self.wr(bus, .b, addr, switch (k) {
                .chg => v ^ m,
                .clr => v & ~m,
                else => v | m,
            });
        }

        fn op_movep(self: *Self, bus: *BusT, comptime sz: Sz, comptime to_mem: bool, op: u16) void {
            const rx: u3 = @truncate(op >> 9);
            const base = self.a[@as(u3, @truncate(op))];
            var addr = base +% sext16(self.ext16(bus));
            const n = if (sz == .l) 4 else 2;
            if (to_mem) {
                const v = self.d[rx];
                var i: u5 = n;
                while (i > 0) {
                    i -= 1;
                    self.wr(bus, .b, addr, v >> (i * 8));
                    addr +%= 2;
                }
            } else {
                var v: u32 = 0;
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    v = v << 8 | self.rd(bus, .b, addr);
                    addr +%= 2;
                }
                self.set_d(sz, rx, v);
            }
        }

        fn op_swap(self: *Self, op: u16) void {
            const r: u3 = @truncate(op);
            const v = self.d[r] << 16 | self.d[r] >> 16;
            self.d[r] = v;
            self.logic_flags(v);
        }

        fn op_ext(self: *Self, comptime sz: Sz, op: u16) void {
            const r: u3 = @truncate(op);
            if (sz == .w) {
                const v = sext8(@truncate(self.d[r])) & 0xFFFF;
                self.set_d(.w, r, v);
                self.logic_flags(v << 16);
            } else {
                const v = sext16(@truncate(self.d[r]));
                self.d[r] = v;
                self.logic_flags(v);
            }
        }

        fn op_lea(self: *Self, bus: *BusT, op: u16) void {
            const mode: u3 = @truncate(op >> 3);
            const reg: u3 = @truncate(op);
            self.a[@as(u3, @truncate(op >> 9))] = self.ctrl_addr(bus, mode, reg);
            if (is_indexed(mode, reg)) self.cyc += 2;
        }

        fn op_pea(self: *Self, bus: *BusT, op: u16) void {
            const mode: u3 = @truncate(op >> 3);
            const reg: u3 = @truncate(op);
            const addr = self.ctrl_addr(bus, mode, reg);
            if (is_indexed(mode, reg)) self.cyc += 2;
            self.push32(bus, addr);
        }

        fn op_jump(self: *Self, bus: *BusT, comptime sub: bool, op: u16) void {
            const mode: u3 = @truncate(op >> 3);
            const reg: u3 = @truncate(op);
            const addr = self.ctrl_addr(bus, mode, reg);
            self.cyc += switch (mode) {
                2 => 4,
                5 => 2,
                6 => 4,
                else => switch (reg) {
                    0, 2 => 2,
                    1 => 0,
                    else => 4,
                },
            };
            if (sub) self.push32(bus, self.pc);
            self.pc = addr;
        }

        fn op_movem_rm(self: *Self, bus: *BusT, comptime sz: Sz, op: u16) void {
            const list = self.ext16(bus);
            const mode: u3 = @truncate(op >> 3);
            const reg: u3 = @truncate(op);
            const n: u32 = if (sz == .l) 4 else 2;
            if (mode == 4) {
                // Bit 0 = A7 ... bit 15 = D0, stored downwards; An itself is
                // stored with its value before the instruction.
                var addr = self.a[reg];
                var m = list;
                var i: u5 = 0;
                while (m != 0) : (i += 1) {
                    if (m & 1 != 0) {
                        addr -%= n;
                        self.wr(bus, sz, addr, self.reg_ptr(@truncate(15 - i)).*);
                    }
                    m >>= 1;
                }
                self.a[reg] = addr;
                return;
            }
            var addr = self.ctrl_addr(bus, mode, reg);
            var m = list;
            var i: u5 = 0;
            while (m != 0) : (i += 1) {
                if (m & 1 != 0) {
                    self.wr(bus, sz, addr, self.reg_ptr(@truncate(i)).*);
                    addr +%= n;
                }
                m >>= 1;
            }
        }

        fn op_movem_mr(self: *Self, bus: *BusT, comptime sz: Sz, op: u16) void {
            const list = self.ext16(bus);
            const mode: u3 = @truncate(op >> 3);
            const reg: u3 = @truncate(op);
            const n: u32 = if (sz == .l) 4 else 2;
            var addr = if (mode == 3) self.a[reg] else self.ctrl_addr(bus, mode, reg);
            var m = list;
            var i: u5 = 0;
            while (m != 0) : (i += 1) {
                if (m & 1 != 0) {
                    self.reg_ptr(@truncate(i)).* = sext(sz, self.rd(bus, sz, addr));
                    addr +%= n;
                }
                m >>= 1;
            }
            if (mode == 3) self.a[reg] = addr;
            // The 68000 reads one more word than the list needs.
            self.cyc += 4;
        }

        fn op_tas(self: *Self, bus: *BusT, op: u16) void {
            const mode: u3 = @truncate(op >> 3);
            const reg: u3 = @truncate(op);
            if (mode == 0) {
                const v = self.d[reg];
                self.logic_flags(v << 24);
                self.d[reg] = v | 0x80;
                return;
            }
            const addr = self.ea_addr(bus, .b, mode, reg, true);
            const v = self.rd(bus, .b, addr);
            self.logic_flags(v << 24);
            self.wr(bus, .b, addr, v | 0x80);
            self.cyc += 2;
        }

        fn op_link(self: *Self, bus: *BusT, op: u16) void {
            const r: u3 = @truncate(op);
            const disp = sext16(self.ext16(bus));
            self.a[7] -%= 4;
            const sp = self.a[7];
            self.wr(bus, .l, sp, self.a[r]);
            self.a[r] = sp;
            self.a[7] +%= disp;
        }

        fn op_unlk(self: *Self, bus: *BusT, op: u16) void {
            const r: u3 = @truncate(op);
            const sp = self.a[r];
            const v = self.rd(bus, .l, sp);
            self.a[7] = sp +% 4;
            self.a[r] = v;
        }

        fn op_stop(self: *Self, bus: *BusT) void {
            if (!self.supervisor()) return self.trap_here(bus, Vector.privilege);
            const v = self.ext16(bus);
            self.set_sr(v);
            self.stopped = true;
        }

        fn op_rte(self: *Self, bus: *BusT) void {
            if (!self.supervisor()) return self.trap_here(bus, Vector.privilege);
            const s = self.pop16(bus);
            self.pc = self.pop32(bus);
            self.set_sr(s);
            self.cyc += 4;
        }

        fn op_chk(self: *Self, bus: *BusT, op: u16) void {
            const bound: i16 = @bitCast(@as(u16, @truncate(self.read_ea(bus, .w, @truncate(op >> 3), @truncate(op)))));
            const v: i16 = @bitCast(@as(u16, @truncate(self.d[@as(u3, @truncate(op >> 9))])));
            self.cyc += 6;
            // Z = Dn == 0, V and C clear; N unchanged without a trap, else
            // N = Dn < 0 (SingleStepTests).
            self.f_z = @as(u16, @bitCast(v));
            self.f_v = 0;
            self.f_c = false;
            if (v > bound or v < 0) self.f_n = if (v < 0) top else 0;
            if (v > bound) {
                self.exception(bus, Vector.chk, self.pc);
                self.cyc += 8;
            } else if (v < 0) {
                self.exception(bus, Vector.chk, self.pc);
                self.cyc += 10;
            }
        }

        fn op_scc(self: *Self, bus: *BusT, op: u16) void {
            const mode: u3 = @truncate(op >> 3);
            const reg: u3 = @truncate(op);
            const t = self.cond(@truncate(op >> 8));
            const v: u32 = if (t) 0xFF else 0;
            if (mode == 0) {
                self.set_d(.b, reg, v);
                if (t) self.cyc += 2;
                return;
            }
            const addr = self.ea_addr(bus, .b, mode, reg, true);
            self.cyc += 4; // read before write
            self.wr(bus, .b, addr, v);
        }

        fn op_dbcc(self: *Self, bus: *BusT, op: u16) void {
            const base = self.pc;
            const disp = sext16(self.ext16(bus));
            if (self.cond(@truncate(op >> 8))) {
                self.cyc += 4;
                return;
            }
            const r: u3 = @truncate(op);
            const cnt: u16 = @as(u16, @truncate(self.d[r])) -% 1;
            self.set_d(.w, r, cnt);
            if (cnt != 0xFFFF) {
                self.pc = base +% disp;
                self.cyc += 2;
            } else self.cyc += 6;
        }

        /// Branch target: 8-bit displacement, or 0 and a 16-bit word.
        inline fn branch_target(self: *Self, bus: *BusT, op: u16) u32 {
            const base = self.pc;
            const d8: u8 = @truncate(op);
            if (d8 != 0) return base +% sext8(d8);
            return base +% sext16(self.ext16(bus));
        }

        inline fn op_bra(self: *Self, bus: *BusT, op: u16) void {
            self.pc = self.branch_target(bus, op);
            self.cyc += if (op & 0xFF != 0) 6 else 2;
            if (has_wait_hook and op & 0xFF >= 0xF6) self.note_loop(bus, op & 0xFF);
        }

        /// A short branch back by `0x100 - d8` bytes was just taken. If the
        /// PC is now at what may be the head of a wait loop, one of the
        /// shapes the bus's `wait_loop` hook recognises (a branch to
        /// itself, or with -10, -8, -6: one TST, BTST #n or MOVE to Dn with
        /// an absolute source, then this branch), hand it the CPU: it may
        /// skip whole iterations by adding their cycles to `cyc`. Only the
        /// opcode is looked at here, through the fetch window; the hook
        /// checks everything else.
        inline fn note_loop(self: *Self, bus: *BusT, d8: u16) void {
            if (d8 != 0xFE) {
                if (d8 & 1 != 0 or d8 == 0xFC or !has_window) return;
                const off = (self.pc & 0xFF_FFFF) -% self.win_base;
                if (off >= self.win_len) return;
                const w = @as(u16, self.win_ptr[off]) << 8 | self.win_ptr[off + 1];
                if (w & 0xFF3E != 0x4A38 and w & 0xC1FE != 0x0038 and w & 0xFFFE != 0x0838) return;
            }
            bus.wait_loop(self);
        }

        fn op_bsr(self: *Self, bus: *BusT, op: u16) void {
            const t = self.branch_target(bus, op);
            self.push32(bus, self.pc);
            self.pc = t;
            self.cyc += if (op & 0xFF != 0) 6 else 2;
        }

        fn op_bcc(self: *Self, bus: *BusT, op: u16) void {
            if (self.cond(@truncate(op >> 8))) return self.op_bra(bus, op);
            if (op & 0xFF == 0) {
                self.pc +%= 2;
                self.cyc += 8;
            } else self.cyc += 4;
        }

        fn op_mul(self: *Self, bus: *BusT, comptime signed: bool, op: u16) void {
            const src: u16 = @truncate(self.read_ea(bus, .w, @truncate(op >> 3), @truncate(op)));
            const rx: u3 = @truncate(op >> 9);
            const dst: u16 = @truncate(self.d[rx]);
            var r: u32 = undefined;
            var ones: u32 = undefined;
            if (signed) {
                const p = @as(i32, @as(i16, @bitCast(src))) * @as(i32, @as(i16, @bitCast(dst)));
                r = @bitCast(p);
                ones = @popCount((src << 1 ^ src) & 0xFFFF);
            } else {
                r = @as(u32, src) * dst;
                ones = @popCount(src);
            }
            self.d[rx] = r;
            self.logic_flags(r);
            self.cyc += 34 + 2 * ones;
        }

        /// Division by zero: N, Z, V, C cleared, then the trap (38 + ea).
        fn div_zero(self: *Self, bus: *BusT) void {
            self.f_n = 0;
            self.f_z = 1;
            self.f_v = 0;
            self.f_c = false;
            self.exception(bus, Vector.div_zero, self.pc);
            self.cyc += 14;
        }

        fn op_divu(self: *Self, bus: *BusT, op: u16) void {
            const src: u16 = @truncate(self.read_ea(bus, .w, @truncate(op >> 3), @truncate(op)));
            const rx: u3 = @truncate(op >> 9);
            const dividend = self.d[rx];
            if (src == 0) {
                self.div_zero(bus);
                return;
            }
            self.cyc += divu_cycles(dividend, src) - 4;
            const q = dividend / src;
            if (q > 0xFFFF) {
                // Overflow: V set, C clear, N and Z unchanged, Dn kept.
                self.f_v = top;
                self.f_c = false;
                return;
            }
            const rem = dividend % src;
            self.d[rx] = rem << 16 | q;
            self.logic_flags(q << 16);
        }

        fn op_divs(self: *Self, bus: *BusT, op: u16) void {
            const src: i16 = @bitCast(@as(u16, @truncate(self.read_ea(bus, .w, @truncate(op >> 3), @truncate(op)))));
            const rx: u3 = @truncate(op >> 9);
            const dividend: i32 = @bitCast(self.d[rx]);
            if (src == 0) {
                self.div_zero(bus);
                return;
            }
            self.cyc += divs_cycles(dividend, src) - 4;
            // i64 so -2^31 / -1 cannot trap.
            const q: i64 = @divTrunc(@as(i64, dividend), src);
            if (q > 32767 or q < -32768) {
                self.f_v = top;
                self.f_c = false;
                return;
            }
            const rem: i64 = @rem(@as(i64, dividend), src);
            const qu: u32 = @as(u16, @bitCast(@as(i16, @intCast(q))));
            const ru: u32 = @as(u16, @bitCast(@as(i16, @intCast(rem))));
            self.d[rx] = ru << 16 | qu;
            self.logic_flags(qu << 16);
        }

        /// ABCD (sub = false) / SBCD (sub = true) of `src` and `dst`, with
        /// the 68000's undocumented N and V.
        fn bcd(self: *Self, comptime sub: bool, src: u32, dst: u32) u32 {
            const x: u32 = @intFromBool(self.f_x);
            var res: u32 = undefined;
            var tmp: u32 = undefined;
            if (!sub) {
                const lo = (src & 0xF) + (dst & 0xF) + x;
                tmp = (src & 0xF0) + (dst & 0xF0) + lo;
                res = tmp;
                if (lo > 9) res += 6;
                self.f_c = (res & 0x3F0) > 0x90;
                if (self.f_c) res += 0x60;
                self.f_v = if (tmp & 0x80 == 0 and res & 0x80 != 0) top else 0;
            } else {
                const lo = (dst & 0xF) -% (src & 0xF) -% x;
                tmp = (dst & 0xF0) -% (src & 0xF0) +% lo;
                res = tmp;
                var adj: u32 = 0;
                if (lo & 0xF0 != 0) {
                    adj = 6;
                    res -%= 6;
                }
                if ((dst -% src -% x) & 0x100 != 0) res -%= 0x60;
                self.f_c = (dst -% src -% adj -% x) & 0x300 != 0;
                self.f_v = if (tmp & 0x80 != 0 and res & 0x80 == 0) top else 0;
            }
            self.f_x = self.f_c;
            res &= 0xFF;
            self.f_z |= res;
            self.f_n = res << 24;
            return res;
        }

        fn op_bcd_r(self: *Self, comptime sub: bool, op: u16) void {
            const rx: u3 = @truncate(op >> 9);
            const r = self.bcd(sub, self.d[@as(u3, @truncate(op))] & 0xFF, self.d[rx] & 0xFF);
            self.set_d(.b, rx, r);
            self.cyc += 2;
        }

        fn op_bcd_m(self: *Self, bus: *BusT, comptime sub: bool, op: u16) void {
            const src = self.rd(bus, .b, self.ea_addr(bus, .b, 4, @truncate(op), false));
            const addr = self.ea_addr(bus, .b, 4, @truncate(op >> 9), false);
            const dst = self.rd(bus, .b, addr);
            self.wr(bus, .b, addr, self.bcd(sub, src, dst));
            self.cyc += 2;
        }

        fn op_nbcd(self: *Self, bus: *BusT, op: u16) void {
            const mode: u3 = @truncate(op >> 3);
            const reg: u3 = @truncate(op);
            if (mode == 0) {
                self.set_d(.b, reg, self.bcd(true, self.d[reg] & 0xFF, 0));
                self.cyc += 2;
                return;
            }
            const addr = self.ea_addr(bus, .b, mode, reg, true);
            const v = self.rd(bus, .b, addr);
            self.wr(bus, .b, addr, self.bcd(true, v, 0));
        }

        /// Shift or rotate `v` (the low `sz` bits) by `cnt` (0-63); sets
        /// every flag; returns the result.
        fn shift(self: *Self, comptime k: Shift, comptime left: bool, comptime sz: Sz, v: u32, cnt: u32) u32 {
            const n: u32 = comptime @as(u32, 32) - shift_of(sz);
            const m = comptime mask_of(sz);
            const sh = comptime shift_of(sz);
            var r: u32 = v;
            var c: bool = false;
            self.f_v = 0;
            switch (k) {
                .ls, .as => if (cnt != 0) {
                    if (left) {
                        if (cnt <= n) {
                            c = (v >> @as(u5, @truncate(n - cnt))) & 1 != 0;
                            r = if (cnt == 32) 0 else (v << @as(u5, @truncate(cnt))) & m;
                        } else r = 0;
                        if (k == .as) {
                            // V: the sign changed at any point, i.e. the top
                            // cnt+1 bits (all of them past the width) differ.
                            if (cnt >= n) {
                                self.f_v = if (v != 0) top else 0;
                            } else {
                                const topmask = (m >> @as(u5, @truncate(n - cnt - 1))) << @as(u5, @truncate(n - cnt - 1));
                                const t = v & topmask & m;
                                self.f_v = if (t != 0 and t != (topmask & m)) top else 0;
                            }
                        }
                    } else {
                        const neg = k == .as and (v >> @as(u5, @truncate(n - 1))) & 1 != 0;
                        if (cnt < n) {
                            c = (v >> @as(u5, @truncate(cnt - 1))) & 1 != 0;
                            r = v >> @as(u5, @truncate(cnt));
                            if (neg) r |= (m << @as(u5, @truncate(n - cnt))) & m;
                        } else {
                            // C is the sign only at exactly the width; past
                            // it SingleStepTests clears C and X for ASR too
                            // (Musashi keeps the sign there).
                            c = cnt == n and (v >> @as(u5, @truncate(n - 1))) & 1 != 0;
                            r = if (neg) m else 0;
                        }
                    }
                    self.f_x = c;
                },
                .ro => if (cnt != 0) {
                    const kk: u32 = cnt & (n - 1);
                    if (kk != 0) {
                        if (left) {
                            r = ((v << @as(u5, @truncate(kk))) | (v >> @as(u5, @truncate(n - kk)))) & m;
                        } else {
                            r = ((v >> @as(u5, @truncate(kk))) | (v << @as(u5, @truncate(n - kk)))) & m;
                        }
                    }
                    c = if (left) r & 1 != 0 else (r >> @as(u5, @truncate(n - 1))) & 1 != 0;
                },
                .rox => {
                    const kk: u32 = cnt % (n + 1);
                    if (kk == 0) {
                        c = self.f_x;
                    } else {
                        const w: u64 = @as(u64, @intFromBool(self.f_x)) << @as(u6, @truncate(n)) | v;
                        const wm: u64 = (@as(u64, 1) << @as(u6, @truncate(n + 1))) - 1;
                        const k6: u6 = @truncate(kk);
                        const rk: u6 = @truncate(n + 1 - kk);
                        const rw = if (left) ((w << k6) | (w >> rk)) & wm else ((w >> k6) | (w << rk)) & wm;
                        r = @truncate(rw & m);
                        c = (rw >> @as(u6, @truncate(n))) & 1 != 0;
                        self.f_x = c;
                    }
                },
            }
            self.f_c = c;
            self.f_n = r << sh;
            self.f_z = r << sh;
            return r;
        }

        fn op_shift(self: *Self, comptime k: Shift, comptime left: bool, comptime sz: Sz, op: u16) void {
            const r: u3 = @truncate(op);
            const c: u3 = @truncate(op >> 9);
            const cnt: u32 = if (op & 0x20 != 0) self.d[c] & 63 else (@as(u32, c) -% 1 & 7) + 1;
            const v = self.shift(k, left, sz, self.d[r] & mask_of(sz), cnt);
            self.set_d(sz, r, v);
            self.cyc += (if (sz == .l) 4 else 2) + 2 * cnt;
        }

        fn op_shift_mem(self: *Self, bus: *BusT, comptime k: Shift, comptime left: bool, op: u16) void {
            const addr = self.ea_addr(bus, .w, @truncate(op >> 3), @truncate(op), true);
            const v = self.rd(bus, .w, addr);
            self.wr(bus, .w, addr, self.shift(k, left, .w, v, 1));
        }
    };
}
