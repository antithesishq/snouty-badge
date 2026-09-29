//! Zilog Z80 interpreter, generic over the bus (PLAN.md, M1 contract,
//! Track A).
//!
//! `Z80(BusT)` is the register file plus `step`. The bus is a comptime
//! parameter (no function pointers on the hot path) and must provide
//! `read(addr: u16) u8`, `write(addr: u16, v: u8)`, `in(port: u8) u8`,
//! `out(port: u8, v: u8)` and `irq_line() bool`, all on `*BusT`; the port
//! argument is the low byte of the 16-bit port address. `irq_line` is
//! sampled between instructions. Nothing here depends on the Game Gear, so
//! the file can move to lib/ when a second Z80 machine arrives (SPEC.md
//! section 7).
//!
//! Coverage: every documented and undocumented opcode in all prefix groups
//! (none, CB, ED, DD, FD, DDCB, FDCB), X/Y flags everywhere, MEMPTR (WZ),
//! the Q latch behind SCF/CCF, R (low 7 bits per opcode fetch, twice for
//! prefixed opcodes), IFF1/IFF2, IM 0/1/2 (IM 0 acts as IM 1: the data bus
//! reads FF = RST 38h), HALT, the EI delay, the block-instruction flags of
//! an interrupted (repeating) LDxR/CPxR/INxR/OTxR, and T-states incl.
//! taken/not-taken conditionals. Checked by the SingleStepTests Z80 suite
//! and ZEXDOC/ZEXALL (tests/z80_*.zig).
//!
//! Decode is one `switch` per prefix group; the regular groups (LD r,r',
//! ALU r) use `inline` prongs so each opcode gets its own body behind the
//! compiler's jump table. DD/FD share one decoder that takes a pointer to
//! IX or IY and hands every opcode that does not touch HL back to the
//! unprefixed decoder. Flag tables come from a host generator
//! (tools/gen_tables.py -> core/tables.zig), never from comptime loops
//! (Adrian's Mac Zig OOMs).
const tables = @import("tables.zig");

const FS: u8 = 0x80;
const FZ: u8 = 0x40;
const FY: u8 = 0x20;
const FH: u8 = 0x10;
const FX: u8 = 0x08;
const FP: u8 = 0x04;
const FN: u8 = 0x02;
const FC: u8 = 0x01;
const FXY: u8 = FX | FY;

pub fn Z80(comptime BusT: type) type {
    return struct {
        const Self = @This();
        pub const Bus = BusT;

        // Main and alternate register sets. Plain bytes so a keyframe is a
        // struct copy.
        a: u8 = 0xFF,
        f: u8 = 0xFF,
        b: u8 = 0,
        c: u8 = 0,
        d: u8 = 0,
        e: u8 = 0,
        h: u8 = 0,
        l: u8 = 0,
        a_: u8 = 0,
        f_: u8 = 0,
        b_: u8 = 0,
        c_: u8 = 0,
        d_: u8 = 0,
        e_: u8 = 0,
        h_: u8 = 0,
        l_: u8 = 0,
        ix: u16 = 0,
        iy: u16 = 0,
        sp: u16 = 0xDFF0,
        pc: u16 = 0,
        /// Interrupt vector base (IM 2) and refresh register (low 7 bits count).
        i: u8 = 0,
        r: u8 = 0,
        /// MEMPTR, visible through the X/Y flags of BIT n,(HL).
        wz: u16 = 0,
        iff1: bool = false,
        iff2: bool = false,
        im: u2 = 1,
        halted: bool = false,
        /// EI was the last instruction: no interrupt before the next one.
        ei_delay: bool = false,
        /// Q: F as written by the last instruction if it wrote the flags,
        /// else 0. SCF/CCF take X/Y from `(q_prev ^ f) | a`.
        q: u8 = 0,
        /// `q` as it was before the current instruction started.
        q_prev: u8 = 0,

        /// Post-BIOS register state (SPEC.md section 3): SP DFF0, IM 1,
        /// interrupts off, PC 0, A/F FF.
        pub fn reset(self: *Self) void {
            self.* = .{};
        }

        /// Run one instruction (or accept an interrupt) and return its
        /// T-states.
        pub fn step(self: *Self, bus: *BusT) u32 {
            if (self.iff1 and !self.ei_delay and bus.irq_line()) return self.interrupt(bus);
            const ei_was_set = self.ei_delay;
            self.ei_delay = false;
            self.q_prev = self.q;
            self.q = 0;
            if (self.halted) {
                // HALT executes NOPs at the same PC until an interrupt. A
                // bus that knows when the interrupt line can next change
                // (`halt_steps`) gets all the NOPs until then in one call.
                if (@hasDecl(BusT, "halt_steps") and !ei_was_set) return self.halt_nops(bus.halt_steps());
                self.inc_r();
                return 4;
            }
            return self.exec(bus, self.fetch_op(bus));
        }

        /// `n` (1..255) steps of a halted CPU with no interrupt accepted,
        /// in one go: exactly what `n` calls of `step` would do then (R
        /// counts every NOP, Q ends clear). `step` calls it only when no
        /// interrupt can be taken in between. Returns the T-states.
        fn halt_nops(self: *Self, n: u8) u32 {
            self.q_prev = if (n == 1) self.q else 0;
            self.q = 0;
            self.r = (self.r & 0x80) | ((self.r +% n) & 0x7F);
            return @as(u32, n) * 4;
        }

        /// Non-maskable interrupt (unused on the Game Gear; untested).
        pub fn nmi(self: *Self, bus: *BusT) u32 {
            self.halted = false;
            self.ei_delay = false;
            self.iff1 = false;
            self.inc_r();
            self.push16(bus, self.pc);
            self.pc = 0x66;
            self.wz = 0x66;
            self.q = 0;
            return 11;
        }

        /// Maskable interrupt acceptance. IM 0 behaves as IM 1: nothing
        /// drives the data bus on this machine, so the CPU reads FF, which
        /// is RST 38h.
        fn interrupt(self: *Self, bus: *BusT) u32 {
            self.halted = false;
            self.iff1 = false;
            self.iff2 = false;
            self.q = 0;
            self.inc_r();
            self.push16(bus, self.pc);
            if (self.im == 2) {
                const vec = (@as(u16, self.i) << 8) | 0xFF;
                self.pc = self.read16(bus, vec);
                self.wz = self.pc;
                return 19;
            }
            self.pc = 0x38;
            self.wz = 0x38;
            return 13;
        }

        // ---- small helpers ----

        inline fn inc_r(self: *Self) void {
            self.r = (self.r & 0x80) | ((self.r +% 1) & 0x7F);
        }

        /// Opcode fetch (M1 cycle): bumps R.
        inline fn fetch_op(self: *Self, bus: *BusT) u8 {
            const v = bus.read(self.pc);
            self.pc +%= 1;
            self.inc_r();
            return v;
        }

        inline fn fetch8(self: *Self, bus: *BusT) u8 {
            const v = bus.read(self.pc);
            self.pc +%= 1;
            return v;
        }

        inline fn fetch16(self: *Self, bus: *BusT) u16 {
            const lo = self.fetch8(bus);
            const hi = self.fetch8(bus);
            return (@as(u16, hi) << 8) | lo;
        }

        /// Displacement byte as a two's-complement offset added with wrap.
        inline fn fetch_disp(self: *Self, bus: *BusT, base: u16) u16 {
            const d = self.fetch8(bus);
            return base +% @as(u16, @bitCast(@as(i16, @as(i8, @bitCast(d)))));
        }

        inline fn read16(self: *Self, bus: *BusT, addr: u16) u16 {
            _ = self;
            const lo = bus.read(addr);
            const hi = bus.read(addr +% 1);
            return (@as(u16, hi) << 8) | lo;
        }

        inline fn write16(self: *Self, bus: *BusT, addr: u16, v: u16) void {
            _ = self;
            bus.write(addr, @truncate(v));
            bus.write(addr +% 1, @truncate(v >> 8));
        }

        inline fn push16(self: *Self, bus: *BusT, v: u16) void {
            self.sp -%= 1;
            bus.write(self.sp, @truncate(v >> 8));
            self.sp -%= 1;
            bus.write(self.sp, @truncate(v));
        }

        inline fn pop16(self: *Self, bus: *BusT) u16 {
            const lo = bus.read(self.sp);
            self.sp +%= 1;
            const hi = bus.read(self.sp);
            self.sp +%= 1;
            return (@as(u16, hi) << 8) | lo;
        }

        /// Write F and latch it into Q (the instruction changed the flags).
        inline fn setf(self: *Self, v: u8) void {
            self.f = v;
            self.q = v;
        }

        pub inline fn bc(self: *const Self) u16 {
            return (@as(u16, self.b) << 8) | self.c;
        }
        pub inline fn de(self: *const Self) u16 {
            return (@as(u16, self.d) << 8) | self.e;
        }
        pub inline fn hl(self: *const Self) u16 {
            return (@as(u16, self.h) << 8) | self.l;
        }
        pub inline fn af(self: *const Self) u16 {
            return (@as(u16, self.a) << 8) | self.f;
        }
        pub inline fn set_bc(self: *Self, v: u16) void {
            self.b = @truncate(v >> 8);
            self.c = @truncate(v);
        }
        pub inline fn set_de(self: *Self, v: u16) void {
            self.d = @truncate(v >> 8);
            self.e = @truncate(v);
        }
        pub inline fn set_hl(self: *Self, v: u16) void {
            self.h = @truncate(v >> 8);
            self.l = @truncate(v);
        }
        pub inline fn set_af(self: *Self, v: u16) void {
            self.a = @truncate(v >> 8);
            self.f = @truncate(v);
        }

        /// Register pair by index for LD/INC/DEC/ADD: BC DE HL SP.
        inline fn get_rp(self: *const Self, comptime i: u2) u16 {
            return switch (i) {
                0 => self.bc(),
                1 => self.de(),
                2 => self.hl(),
                3 => self.sp,
            };
        }
        inline fn set_rp(self: *Self, comptime i: u2, v: u16) void {
            switch (i) {
                0 => self.set_bc(v),
                1 => self.set_de(v),
                2 => self.set_hl(v),
                3 => self.sp = v,
            }
        }

        /// 8-bit register by index B C D E H L - A (6, (HL), is the caller's).
        inline fn reg(self: *Self, comptime i: u3) *u8 {
            return switch (i) {
                0 => &self.b,
                1 => &self.c,
                2 => &self.d,
                3 => &self.e,
                4 => &self.h,
                5 => &self.l,
                6 => @compileError("(HL) is not a register"),
                7 => &self.a,
            };
        }

        /// Runtime-index register read/write for the CB groups (6 unused).
        fn get_r(self: *const Self, i: u3) u8 {
            return switch (i) {
                0 => self.b,
                1 => self.c,
                2 => self.d,
                3 => self.e,
                4 => self.h,
                5 => self.l,
                6 => 0,
                7 => self.a,
            };
        }
        fn set_r(self: *Self, i: u3, v: u8) void {
            switch (i) {
                0 => self.b = v,
                1 => self.c = v,
                2 => self.d = v,
                3 => self.e = v,
                4 => self.h = v,
                5 => self.l = v,
                6 => {},
                7 => self.a = v,
            }
        }

        /// Condition by index: NZ Z NC C PO PE P M.
        inline fn cond(self: *const Self, comptime i: u3) bool {
            return switch (i) {
                0 => (self.f & FZ) == 0,
                1 => (self.f & FZ) != 0,
                2 => (self.f & FC) == 0,
                3 => (self.f & FC) != 0,
                4 => (self.f & FP) == 0,
                5 => (self.f & FP) != 0,
                6 => (self.f & FS) == 0,
                7 => (self.f & FS) != 0,
            };
        }

        // ---- ALU ----

        /// ALU op by index: ADD ADC SUB SBC AND XOR OR CP.
        inline fn alu(self: *Self, comptime op: u3, v: u8) void {
            const a = self.a;
            switch (op) {
                0, 1 => {
                    const cy: u16 = if (op == 1) self.f & FC else 0;
                    const sum: u16 = @as(u16, a) + v + cy;
                    const r: u8 = @truncate(sum);
                    self.setf(tables.sz53[r] | @as(u8, @truncate(sum >> 8)) |
                        ((a ^ v ^ r) & FH) |
                        (((a ^ ~v) & (a ^ r) & 0x80) >> 5));
                    self.a = r;
                },
                2, 3, 7 => {
                    const cy: u16 = if (op == 3) self.f & FC else 0;
                    const diff: u16 = @as(u16, a) -% v -% cy;
                    const r: u8 = @truncate(diff);
                    const xy = if (op == 7) v else r;
                    self.setf((tables.sz53[r] & ~FXY) | (xy & FXY) | FN |
                        @as(u8, @truncate((diff >> 8) & 1)) |
                        ((a ^ v ^ r) & FH) |
                        (((a ^ v) & (a ^ r) & 0x80) >> 5));
                    if (op != 7) self.a = r;
                },
                4 => {
                    self.a = a & v;
                    self.setf(tables.sz53p[self.a] | FH);
                },
                5 => {
                    self.a = a ^ v;
                    self.setf(tables.sz53p[self.a]);
                },
                6 => {
                    self.a = a | v;
                    self.setf(tables.sz53p[self.a]);
                },
            }
        }

        inline fn inc8(self: *Self, v: u8) u8 {
            const r = v +% 1;
            self.setf((self.f & FC) | tables.inc[r]);
            return r;
        }

        inline fn dec8(self: *Self, v: u8) u8 {
            const r = v -% 1;
            self.setf((self.f & FC) | tables.dec[r]);
            return r;
        }

        /// ADD HL/IX/IY,rr: S Z P/V kept, H and X/Y from the high byte.
        inline fn add16(self: *Self, x: u16, y: u16) u16 {
            const sum: u32 = @as(u32, x) + y;
            const r: u16 = @truncate(sum);
            self.wz = x +% 1;
            self.setf((self.f & (FS | FZ | FP)) |
                @as(u8, @truncate(sum >> 16)) |
                (@as(u8, @truncate(r >> 8)) & FXY) |
                (@as(u8, @truncate((x ^ y ^ r) >> 8)) & FH));
            return r;
        }

        inline fn adc16(self: *Self, y: u16) void {
            const x = self.hl();
            const sum: u32 = @as(u32, x) + y + (self.f & FC);
            const r: u16 = @truncate(sum);
            self.wz = x +% 1;
            self.setf((@as(u8, @truncate(r >> 8)) & (FS | FXY)) |
                (if (r == 0) FZ else 0) |
                @as(u8, @truncate(sum >> 16)) |
                (@as(u8, @truncate((x ^ y ^ r) >> 8)) & FH) |
                @as(u8, @truncate(((x ^ ~y) & (x ^ r) & 0x8000) >> 13)));
            self.set_hl(r);
        }

        inline fn sbc16(self: *Self, y: u16) void {
            const x = self.hl();
            const diff: u32 = @as(u32, x) -% y -% (self.f & FC);
            const r: u16 = @truncate(diff);
            self.wz = x +% 1;
            self.setf((@as(u8, @truncate(r >> 8)) & (FS | FXY)) |
                (if (r == 0) FZ else 0) | FN |
                @as(u8, @truncate((diff >> 16) & 1)) |
                (@as(u8, @truncate((x ^ y ^ r) >> 8)) & FH) |
                @as(u8, @truncate(((x ^ y) & (x ^ r) & 0x8000) >> 13)));
            self.set_hl(r);
        }

        /// CB rotate/shift by index: RLC RRC RL RR SLA SRA SLL SRL.
        fn rot(self: *Self, op: u3, v: u8) u8 {
            var r: u8 = undefined;
            var cy: u8 = undefined;
            switch (op) {
                0 => {
                    cy = v >> 7;
                    r = (v << 1) | cy;
                },
                1 => {
                    cy = v & 1;
                    r = (v >> 1) | (cy << 7);
                },
                2 => {
                    cy = v >> 7;
                    r = (v << 1) | (self.f & FC);
                },
                3 => {
                    cy = v & 1;
                    r = (v >> 1) | ((self.f & FC) << 7);
                },
                4 => {
                    cy = v >> 7;
                    r = v << 1;
                },
                5 => {
                    cy = v & 1;
                    r = (v >> 1) | (v & 0x80);
                },
                6 => {
                    cy = v >> 7;
                    r = (v << 1) | 1;
                },
                7 => {
                    cy = v & 1;
                    r = v >> 1;
                },
            }
            self.setf(tables.sz53p[r] | cy);
            return r;
        }

        /// BIT n: Z and P/V from the tested bit, S only for bit 7, X/Y from
        /// `xy` (the operand for registers, WZ's high byte for memory).
        inline fn bit(self: *Self, n: u3, v: u8, xy: u8) void {
            const t = v & (@as(u8, 1) << n);
            self.setf((self.f & FC) | FH | (t & FS) | (if (t == 0) FZ | FP else 0) | (xy & FXY));
        }

        fn daa(self: *Self) void {
            const a = self.a;
            var add: u8 = 0;
            var cy: u8 = self.f & FC;
            if ((self.f & FH) != 0 or (a & 0x0F) > 9) add = 0x06;
            if (cy != 0 or a > 0x99) {
                add |= 0x60;
                cy = FC;
            }
            const r = if ((self.f & FN) != 0) a -% add else a +% add;
            self.setf(tables.sz53p[r] | cy | (self.f & FN) | ((a ^ r) & FH));
            self.a = r;
        }

        // ---- unprefixed ----

        fn exec(self: *Self, bus: *BusT, op: u8) u32 {
            // The 256-way switch inlines the bus accessors into every prong;
            // with the real Game Gear bus (itself inline) semantic analysis
            // passes Zig's default 1000-branch quota. Not a comptime loop.
            @setEvalBranchQuota(20_000);
            switch (op) {
                0x00 => return 4,
                inline 0x01, 0x11, 0x21, 0x31 => |o| {
                    self.set_rp(o >> 4, self.fetch16(bus));
                    return 10;
                },
                0x02 => {
                    const addr = self.bc();
                    bus.write(addr, self.a);
                    self.wz = (@as(u16, self.a) << 8) | ((addr +% 1) & 0xFF);
                    return 7;
                },
                0x12 => {
                    const addr = self.de();
                    bus.write(addr, self.a);
                    self.wz = (@as(u16, self.a) << 8) | ((addr +% 1) & 0xFF);
                    return 7;
                },
                0x0A => {
                    const addr = self.bc();
                    self.a = bus.read(addr);
                    self.wz = addr +% 1;
                    return 7;
                },
                0x1A => {
                    const addr = self.de();
                    self.a = bus.read(addr);
                    self.wz = addr +% 1;
                    return 7;
                },
                inline 0x03, 0x13, 0x23, 0x33 => |o| {
                    self.set_rp(o >> 4, self.get_rp(o >> 4) +% 1);
                    return 6;
                },
                inline 0x0B, 0x1B, 0x2B, 0x3B => |o| {
                    self.set_rp(o >> 4, self.get_rp(o >> 4) -% 1);
                    return 6;
                },
                inline 0x04, 0x0C, 0x14, 0x1C, 0x24, 0x2C, 0x3C => |o| {
                    const p = self.reg(o >> 3);
                    p.* = self.inc8(p.*);
                    return 4;
                },
                inline 0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x3D => |o| {
                    const p = self.reg(o >> 3);
                    p.* = self.dec8(p.*);
                    return 4;
                },
                0x34 => {
                    const addr = self.hl();
                    bus.write(addr, self.inc8(bus.read(addr)));
                    return 11;
                },
                0x35 => {
                    const addr = self.hl();
                    bus.write(addr, self.dec8(bus.read(addr)));
                    return 11;
                },
                inline 0x06, 0x0E, 0x16, 0x1E, 0x26, 0x2E, 0x3E => |o| {
                    self.reg(o >> 3).* = self.fetch8(bus);
                    return 7;
                },
                0x36 => {
                    const v = self.fetch8(bus);
                    bus.write(self.hl(), v);
                    return 10;
                },
                0x07 => {
                    const a = (self.a << 1) | (self.a >> 7);
                    self.a = a;
                    self.setf((self.f & (FS | FZ | FP)) | (a & (FXY | FC)));
                    return 4;
                },
                0x0F => {
                    const cy = self.a & 1;
                    const a = (self.a >> 1) | (cy << 7);
                    self.a = a;
                    self.setf((self.f & (FS | FZ | FP)) | (a & FXY) | cy);
                    return 4;
                },
                0x17 => {
                    const cy = self.a >> 7;
                    const a = (self.a << 1) | (self.f & FC);
                    self.a = a;
                    self.setf((self.f & (FS | FZ | FP)) | (a & FXY) | cy);
                    return 4;
                },
                0x1F => {
                    const cy = self.a & 1;
                    const a = (self.a >> 1) | ((self.f & FC) << 7);
                    self.a = a;
                    self.setf((self.f & (FS | FZ | FP)) | (a & FXY) | cy);
                    return 4;
                },
                0x08 => {
                    const a = self.a;
                    const f = self.f;
                    self.a = self.a_;
                    self.f = self.f_;
                    self.a_ = a;
                    self.f_ = f;
                    return 4;
                },
                inline 0x09, 0x19, 0x29, 0x39 => |o| {
                    self.set_hl(self.add16(self.hl(), self.get_rp(o >> 4)));
                    return 11;
                },
                0x10 => {
                    const target = self.fetch_disp(bus, self.pc +% 1);
                    self.b -%= 1;
                    if (self.b != 0) {
                        self.pc = target;
                        self.wz = target;
                        return 13;
                    }
                    return 8;
                },
                0x18 => {
                    const target = self.fetch_disp(bus, self.pc +% 1);
                    self.pc = target;
                    self.wz = target;
                    return 12;
                },
                inline 0x20, 0x28, 0x30, 0x38 => |o| {
                    const target = self.fetch_disp(bus, self.pc +% 1);
                    if (self.cond((o >> 3) & 3)) {
                        self.pc = target;
                        self.wz = target;
                        return 12;
                    }
                    return 7;
                },
                0x22 => {
                    const addr = self.fetch16(bus);
                    self.write16(bus, addr, self.hl());
                    self.wz = addr +% 1;
                    return 16;
                },
                0x2A => {
                    const addr = self.fetch16(bus);
                    self.set_hl(self.read16(bus, addr));
                    self.wz = addr +% 1;
                    return 16;
                },
                0x32 => {
                    const addr = self.fetch16(bus);
                    bus.write(addr, self.a);
                    self.wz = (@as(u16, self.a) << 8) | ((addr +% 1) & 0xFF);
                    return 13;
                },
                0x3A => {
                    const addr = self.fetch16(bus);
                    self.a = bus.read(addr);
                    self.wz = addr +% 1;
                    return 13;
                },
                0x27 => {
                    self.daa();
                    return 4;
                },
                0x2F => {
                    self.a = ~self.a;
                    self.setf((self.f & (FS | FZ | FP | FC)) | FH | FN | (self.a & FXY));
                    return 4;
                },
                0x37 => {
                    self.setf((self.f & (FS | FZ | FP)) | FC | (((self.q_prev ^ self.f) | self.a) & FXY));
                    return 4;
                },
                0x3F => {
                    const hc: u8 = if ((self.f & FC) != 0) FH else FC;
                    self.setf((self.f & (FS | FZ | FP)) | hc | (((self.q_prev ^ self.f) | self.a) & FXY));
                    return 4;
                },
                0x76 => {
                    self.halted = true;
                    return 4;
                },
                // LD r,r' / LD r,(HL) / LD (HL),r
                inline 0x40...0x75, 0x77...0x7F => |o| {
                    const dst: u3 = (o >> 3) & 7;
                    const src: u3 = o & 7;
                    if (src == 6) {
                        self.reg(dst).* = bus.read(self.hl());
                        return 7;
                    } else if (dst == 6) {
                        bus.write(self.hl(), self.reg(src).*);
                        return 7;
                    } else {
                        self.reg(dst).* = self.reg(src).*;
                        return 4;
                    }
                },
                // ALU A,r / ALU A,(HL)
                inline 0x80...0xBF => |o| {
                    const src: u3 = o & 7;
                    if (src == 6) {
                        self.alu((o >> 3) & 7, bus.read(self.hl()));
                        return 7;
                    }
                    self.alu((o >> 3) & 7, self.reg(src).*);
                    return 4;
                },
                inline 0xC6, 0xCE, 0xD6, 0xDE, 0xE6, 0xEE, 0xF6, 0xFE => |o| {
                    self.alu((o >> 3) & 7, self.fetch8(bus));
                    return 7;
                },
                inline 0xC0, 0xC8, 0xD0, 0xD8, 0xE0, 0xE8, 0xF0, 0xF8 => |o| {
                    if (self.cond((o >> 3) & 7)) {
                        self.pc = self.pop16(bus);
                        self.wz = self.pc;
                        return 11;
                    }
                    return 5;
                },
                0xC9 => {
                    self.pc = self.pop16(bus);
                    self.wz = self.pc;
                    return 10;
                },
                0xC1 => {
                    self.set_bc(self.pop16(bus));
                    return 10;
                },
                0xD1 => {
                    self.set_de(self.pop16(bus));
                    return 10;
                },
                0xE1 => {
                    self.set_hl(self.pop16(bus));
                    return 10;
                },
                0xF1 => {
                    self.set_af(self.pop16(bus));
                    return 10;
                },
                0xC5 => {
                    self.push16(bus, self.bc());
                    return 11;
                },
                0xD5 => {
                    self.push16(bus, self.de());
                    return 11;
                },
                0xE5 => {
                    self.push16(bus, self.hl());
                    return 11;
                },
                0xF5 => {
                    self.push16(bus, self.af());
                    return 11;
                },
                inline 0xC2, 0xCA, 0xD2, 0xDA, 0xE2, 0xEA, 0xF2, 0xFA => |o| {
                    const addr = self.fetch16(bus);
                    self.wz = addr;
                    if (self.cond((o >> 3) & 7)) self.pc = addr;
                    return 10;
                },
                0xC3 => {
                    const addr = self.fetch16(bus);
                    self.wz = addr;
                    self.pc = addr;
                    return 10;
                },
                inline 0xC4, 0xCC, 0xD4, 0xDC, 0xE4, 0xEC, 0xF4, 0xFC => |o| {
                    const addr = self.fetch16(bus);
                    self.wz = addr;
                    if (self.cond((o >> 3) & 7)) {
                        self.push16(bus, self.pc);
                        self.pc = addr;
                        return 17;
                    }
                    return 10;
                },
                0xCD => {
                    const addr = self.fetch16(bus);
                    self.wz = addr;
                    self.push16(bus, self.pc);
                    self.pc = addr;
                    return 17;
                },
                inline 0xC7, 0xCF, 0xD7, 0xDF, 0xE7, 0xEF, 0xF7, 0xFF => |o| {
                    self.push16(bus, self.pc);
                    self.pc = o & 0x38;
                    self.wz = self.pc;
                    return 11;
                },
                0xCB => return self.exec_cb(bus),
                0xED => return self.exec_ed(bus),
                0xDD => return self.exec_xy(bus, &self.ix),
                0xFD => return self.exec_xy(bus, &self.iy),
                0xD3 => {
                    const n = self.fetch8(bus);
                    bus.out(n, self.a);
                    self.wz = (@as(u16, self.a) << 8) | ((n +% 1) & 0xFF);
                    return 11;
                },
                0xDB => {
                    const n = self.fetch8(bus);
                    self.wz = ((@as(u16, self.a) << 8) | n) +% 1;
                    self.a = bus.in(n);
                    return 11;
                },
                0xD9 => {
                    var t = self.b;
                    self.b = self.b_;
                    self.b_ = t;
                    t = self.c;
                    self.c = self.c_;
                    self.c_ = t;
                    t = self.d;
                    self.d = self.d_;
                    self.d_ = t;
                    t = self.e;
                    self.e = self.e_;
                    self.e_ = t;
                    t = self.h;
                    self.h = self.h_;
                    self.h_ = t;
                    t = self.l;
                    self.l = self.l_;
                    self.l_ = t;
                    return 4;
                },
                0xE3 => {
                    const v = self.read16(bus, self.sp);
                    self.write16(bus, self.sp, self.hl());
                    self.set_hl(v);
                    self.wz = v;
                    return 19;
                },
                0xE9 => {
                    self.pc = self.hl();
                    return 4;
                },
                0xEB => {
                    var t = self.d;
                    self.d = self.h;
                    self.h = t;
                    t = self.e;
                    self.e = self.l;
                    self.l = t;
                    return 4;
                },
                0xF3 => {
                    self.iff1 = false;
                    self.iff2 = false;
                    return 4;
                },
                0xFB => {
                    self.iff1 = true;
                    self.iff2 = true;
                    self.ei_delay = true;
                    return 4;
                },
                0xF9 => {
                    self.sp = self.hl();
                    return 6;
                },
            }
        }

        // ---- CB prefix ----

        fn exec_cb(self: *Self, bus: *BusT) u32 {
            const op = self.fetch_op(bus);
            const z: u3 = @truncate(op);
            const y: u3 = @truncate(op >> 3);
            if (z == 6) {
                const addr = self.hl();
                const v = bus.read(addr);
                switch (op >> 6) {
                    0 => bus.write(addr, self.rot(y, v)),
                    1 => {
                        self.bit(y, v, @truncate(self.wz >> 8));
                        return 12;
                    },
                    2 => bus.write(addr, v & ~(@as(u8, 1) << y)),
                    else => bus.write(addr, v | (@as(u8, 1) << y)),
                }
                return 15;
            }
            const v = self.get_r(z);
            switch (op >> 6) {
                0 => self.set_r(z, self.rot(y, v)),
                1 => self.bit(y, v, v),
                2 => self.set_r(z, v & ~(@as(u8, 1) << y)),
                else => self.set_r(z, v | (@as(u8, 1) << y)),
            }
            return 8;
        }

        // ---- DD/FD prefix (IX or IY through `xy`) ----

        inline fn xh(xy: *const u16) u8 {
            return @truncate(xy.* >> 8);
        }
        inline fn xl(xy: *const u16) u8 {
            return @truncate(xy.*);
        }
        inline fn set_xh(xy: *u16, v: u8) void {
            xy.* = (xy.* & 0x00FF) | (@as(u16, v) << 8);
        }
        inline fn set_xl(xy: *u16, v: u8) void {
            xy.* = (xy.* & 0xFF00) | v;
        }

        /// Register operand of an indexed opcode where H/L mean IXH/IXL.
        inline fn get_rx(self: *Self, xy: *const u16, comptime i: u3) u8 {
            return switch (i) {
                4 => xh(xy),
                5 => xl(xy),
                else => self.reg(i).*,
            };
        }
        inline fn set_rx(self: *Self, xy: *u16, comptime i: u3, v: u8) void {
            switch (i) {
                4 => set_xh(xy, v),
                5 => set_xl(xy, v),
                else => self.reg(i).* = v,
            }
        }

        fn exec_xy(self: *Self, bus: *BusT, xy: *u16) u32 {
            const op = self.fetch_op(bus);
            switch (op) {
                inline 0x09, 0x19, 0x29, 0x39 => |o| {
                    const rr: u16 = switch (o >> 4) {
                        0 => self.bc(),
                        1 => self.de(),
                        2 => xy.*,
                        else => self.sp,
                    };
                    xy.* = self.add16(xy.*, rr);
                    return 15;
                },
                0x21 => {
                    xy.* = self.fetch16(bus);
                    return 14;
                },
                0x22 => {
                    const addr = self.fetch16(bus);
                    self.write16(bus, addr, xy.*);
                    self.wz = addr +% 1;
                    return 20;
                },
                0x2A => {
                    const addr = self.fetch16(bus);
                    xy.* = self.read16(bus, addr);
                    self.wz = addr +% 1;
                    return 20;
                },
                0x23 => {
                    xy.* +%= 1;
                    return 10;
                },
                0x2B => {
                    xy.* -%= 1;
                    return 10;
                },
                0x24 => {
                    set_xh(xy, self.inc8(xh(xy)));
                    return 8;
                },
                0x25 => {
                    set_xh(xy, self.dec8(xh(xy)));
                    return 8;
                },
                0x26 => {
                    set_xh(xy, self.fetch8(bus));
                    return 11;
                },
                0x2C => {
                    set_xl(xy, self.inc8(xl(xy)));
                    return 8;
                },
                0x2D => {
                    set_xl(xy, self.dec8(xl(xy)));
                    return 8;
                },
                0x2E => {
                    set_xl(xy, self.fetch8(bus));
                    return 11;
                },
                0x34 => {
                    const addr = self.fetch_disp(bus, xy.*);
                    self.wz = addr;
                    bus.write(addr, self.inc8(bus.read(addr)));
                    return 23;
                },
                0x35 => {
                    const addr = self.fetch_disp(bus, xy.*);
                    self.wz = addr;
                    bus.write(addr, self.dec8(bus.read(addr)));
                    return 23;
                },
                0x36 => {
                    const addr = self.fetch_disp(bus, xy.*);
                    self.wz = addr;
                    bus.write(addr, self.fetch8(bus));
                    return 19;
                },
                // LD with IXH/IXL or (IX+d) operands
                inline 0x44, 0x45, 0x4C, 0x4D, 0x54, 0x55, 0x5C, 0x5D, 0x60...0x65, 0x67...0x6D, 0x6F, 0x7C, 0x7D => |o| {
                    self.set_rx(xy, (o >> 3) & 7, self.get_rx(xy, o & 7));
                    return 8;
                },
                inline 0x46, 0x4E, 0x56, 0x5E, 0x66, 0x6E, 0x7E => |o| {
                    const addr = self.fetch_disp(bus, xy.*);
                    self.wz = addr;
                    self.reg((o >> 3) & 7).* = bus.read(addr);
                    return 19;
                },
                inline 0x70...0x75, 0x77 => |o| {
                    const addr = self.fetch_disp(bus, xy.*);
                    self.wz = addr;
                    bus.write(addr, self.reg(o & 7).*);
                    return 19;
                },
                inline 0x84, 0x85, 0x8C, 0x8D, 0x94, 0x95, 0x9C, 0x9D, 0xA4, 0xA5, 0xAC, 0xAD, 0xB4, 0xB5, 0xBC, 0xBD => |o| {
                    self.alu((o >> 3) & 7, self.get_rx(xy, o & 7));
                    return 8;
                },
                inline 0x86, 0x8E, 0x96, 0x9E, 0xA6, 0xAE, 0xB6, 0xBE => |o| {
                    const addr = self.fetch_disp(bus, xy.*);
                    self.wz = addr;
                    self.alu((o >> 3) & 7, bus.read(addr));
                    return 19;
                },
                0xCB => return self.exec_xycb(bus, xy),
                0xE1 => {
                    xy.* = self.pop16(bus);
                    return 14;
                },
                0xE5 => {
                    self.push16(bus, xy.*);
                    return 15;
                },
                0xE3 => {
                    const v = self.read16(bus, self.sp);
                    self.write16(bus, self.sp, xy.*);
                    xy.* = v;
                    self.wz = v;
                    return 23;
                },
                0xE9 => {
                    self.pc = xy.*;
                    return 8;
                },
                0xF9 => {
                    self.sp = xy.*;
                    return 10;
                },
                0xDD, 0xFD, 0xED => {
                    // The first prefix acts as a 4 T NOP; the next one starts
                    // a new instruction (on the next step).
                    self.pc -%= 1;
                    self.r = (self.r & 0x80) | ((self.r -% 1) & 0x7F);
                    return 4;
                },
                // Everything else ignores the prefix, which counts as an
                // instruction of its own that left the flags alone (Q = 0
                // for SCF/CCF).
                else => {
                    self.q_prev = 0;
                    return self.exec(bus, op) + 4;
                },
            }
        }

        /// DDCB/FDCB d op: the operand is always (IX+d); rotates, RES and SET
        /// also copy the result to register `op & 7` unless it is 6. The two
        /// bytes after CB are not opcode fetches, so R is not bumped.
        fn exec_xycb(self: *Self, bus: *BusT, xy: *u16) u32 {
            const addr = self.fetch_disp(bus, xy.*);
            const op = self.fetch8(bus);
            self.wz = addr;
            const v = bus.read(addr);
            const z: u3 = @truncate(op);
            const y: u3 = @truncate(op >> 3);
            const r = switch (op >> 6) {
                0 => self.rot(y, v),
                1 => {
                    self.bit(y, v, @truncate(addr >> 8));
                    return 20;
                },
                2 => v & ~(@as(u8, 1) << y),
                else => v | (@as(u8, 1) << y),
            };
            bus.write(addr, r);
            self.set_r(z, r);
            return 23;
        }

        // ---- ED prefix ----

        fn exec_ed(self: *Self, bus: *BusT) u32 {
            const op = self.fetch_op(bus);
            switch (op) {
                // IN r,(C); 0x70 is IN F,(C) (flags only)
                inline 0x40, 0x48, 0x50, 0x58, 0x60, 0x68, 0x70, 0x78 => |o| {
                    const port = self.bc();
                    self.wz = port +% 1;
                    const v = bus.in(self.c);
                    self.setf((self.f & FC) | tables.sz53p[v]);
                    if (o != 0x70) self.reg((o >> 3) & 7).* = v;
                    return 12;
                },
                // OUT (C),r; 0x71 is OUT (C),0
                inline 0x41, 0x49, 0x51, 0x59, 0x61, 0x69, 0x71, 0x79 => |o| {
                    self.wz = self.bc() +% 1;
                    bus.out(self.c, if (o == 0x71) 0 else self.reg((o >> 3) & 7).*);
                    return 12;
                },
                inline 0x42, 0x52, 0x62, 0x72 => |o| {
                    self.sbc16(self.get_rp(o >> 4 & 3));
                    return 15;
                },
                inline 0x4A, 0x5A, 0x6A, 0x7A => |o| {
                    self.adc16(self.get_rp(o >> 4 & 3));
                    return 15;
                },
                inline 0x43, 0x53, 0x63, 0x73 => |o| {
                    const addr = self.fetch16(bus);
                    self.write16(bus, addr, self.get_rp(o >> 4 & 3));
                    self.wz = addr +% 1;
                    return 20;
                },
                inline 0x4B, 0x5B, 0x6B, 0x7B => |o| {
                    const addr = self.fetch16(bus);
                    self.set_rp(o >> 4 & 3, self.read16(bus, addr));
                    self.wz = addr +% 1;
                    return 20;
                },
                0x44, 0x4C, 0x54, 0x5C, 0x64, 0x6C, 0x74, 0x7C => {
                    const v = self.a;
                    self.a = 0;
                    self.alu(2, v);
                    return 8;
                },
                // RETN / RETI (both copy IFF2 to IFF1)
                0x45, 0x4D, 0x55, 0x5D, 0x65, 0x6D, 0x75, 0x7D => {
                    self.iff1 = self.iff2;
                    self.pc = self.pop16(bus);
                    self.wz = self.pc;
                    return 14;
                },
                0x46, 0x4E, 0x66, 0x6E => {
                    self.im = 0;
                    return 8;
                },
                0x56, 0x76 => {
                    self.im = 1;
                    return 8;
                },
                0x5E, 0x7E => {
                    self.im = 2;
                    return 8;
                },
                0x47 => {
                    self.i = self.a;
                    return 9;
                },
                0x4F => {
                    self.r = self.a;
                    return 9;
                },
                0x57 => {
                    self.a = self.i;
                    self.setf((self.f & FC) | tables.sz53[self.a] | (if (self.iff2) FP else 0));
                    return 9;
                },
                0x5F => {
                    self.a = self.r;
                    self.setf((self.f & FC) | tables.sz53[self.a] | (if (self.iff2) FP else 0));
                    return 9;
                },
                0x67 => {
                    const addr = self.hl();
                    const v = bus.read(addr);
                    bus.write(addr, (self.a << 4) | (v >> 4));
                    self.a = (self.a & 0xF0) | (v & 0x0F);
                    self.setf((self.f & FC) | tables.sz53p[self.a]);
                    self.wz = addr +% 1;
                    return 18;
                },
                0x6F => {
                    const addr = self.hl();
                    const v = bus.read(addr);
                    bus.write(addr, (v << 4) | (self.a & 0x0F));
                    self.a = (self.a & 0xF0) | (v >> 4);
                    self.setf((self.f & FC) | tables.sz53p[self.a]);
                    self.wz = addr +% 1;
                    return 18;
                },
                inline 0xA0, 0xA8, 0xB0, 0xB8 => |o| return self.block_ld(bus, o & 0x08 == 0, o & 0x10 != 0),
                inline 0xA1, 0xA9, 0xB1, 0xB9 => |o| return self.block_cp(bus, o & 0x08 == 0, o & 0x10 != 0),
                inline 0xA2, 0xAA, 0xB2, 0xBA => |o| return self.block_in(bus, o & 0x08 == 0, o & 0x10 != 0),
                inline 0xA3, 0xAB, 0xB3, 0xBB => |o| return self.block_out(bus, o & 0x08 == 0, o & 0x10 != 0),
                // The rest of ED are 8 T NOPs.
                else => return 8,
            }
        }

        /// A repeating block instruction rewinds PC to itself; X/Y then come
        /// from PC's high byte (bits 13 and 11).
        inline fn block_repeat(self: *Self) void {
            self.pc -%= 2;
            self.wz = self.pc +% 1;
            self.f = (self.f & ~FXY) | (@as(u8, @truncate(self.pc >> 8)) & FXY);
            self.q = self.f;
        }

        fn block_ld(self: *Self, bus: *BusT, comptime up: bool, comptime repeat: bool) u32 {
            const v = bus.read(self.hl());
            bus.write(self.de(), v);
            if (up) {
                self.set_hl(self.hl() +% 1);
                self.set_de(self.de() +% 1);
            } else {
                self.set_hl(self.hl() -% 1);
                self.set_de(self.de() -% 1);
            }
            const count = self.bc() -% 1;
            self.set_bc(count);
            const n = v +% self.a;
            self.setf((self.f & (FS | FZ | FC)) | (if (count != 0) FP else 0) | (n & FX) | ((n << 4) & FY));
            if (repeat and count != 0) {
                self.block_repeat();
                return 21;
            }
            return 16;
        }

        fn block_cp(self: *Self, bus: *BusT, comptime up: bool, comptime repeat: bool) u32 {
            const v = bus.read(self.hl());
            const r = self.a -% v;
            if (up) {
                self.set_hl(self.hl() +% 1);
                self.wz +%= 1;
            } else {
                self.set_hl(self.hl() -% 1);
                self.wz -%= 1;
            }
            const count = self.bc() -% 1;
            self.set_bc(count);
            const hf = (self.a ^ v ^ r) & FH;
            const n = r -% (hf >> 4);
            self.setf((self.f & FC) | FN | (tables.sz53[r] & (FS | FZ)) | hf |
                (if (count != 0) FP else 0) | (n & FX) | ((n << 4) & FY));
            if (repeat and count != 0 and r != 0) {
                self.block_repeat();
                return 21;
            }
            return 16;
        }

        /// INI/IND/OUTI/OUTD flags (`k` is the 9-bit sum the hardware forms,
        /// `v` the byte moved) plus the interrupted-repeat adjustment of H and
        /// P/V found by David Banks (2022, see MAME's z80.cpp).
        inline fn block_io_flags(self: *Self, v: u8, k: u16, comptime repeating: bool) void {
            const b = self.b;
            var f = tables.sz53[b] | (if ((v & 0x80) != 0) FN else 0) |
                (if (k > 0xFF) FH | FC else 0) |
                (tables.sz53p[@as(u8, @truncate(k & 7)) ^ b] & FP);
            if (repeating) {
                self.pc -%= 2;
                self.wz = self.pc +% 1;
                f = (f & ~FXY) | (@as(u8, @truncate(self.pc >> 8)) & FXY);
                if ((f & FC) != 0) {
                    f &= ~FH;
                    if ((v & 0x80) != 0) {
                        f ^= (tables.sz53p[(b -% 1) & 7] ^ FP) & FP;
                        if ((b & 0x0F) == 0x00) f |= FH;
                    } else {
                        f ^= (tables.sz53p[(b +% 1) & 7] ^ FP) & FP;
                        if ((b & 0x0F) == 0x0F) f |= FH;
                    }
                } else {
                    f ^= (tables.sz53p[b & 7] ^ FP) & FP;
                }
            }
            self.setf(f);
        }

        fn block_in(self: *Self, bus: *BusT, comptime up: bool, comptime repeat: bool) u32 {
            const port = self.bc();
            const v = bus.in(self.c);
            bus.write(self.hl(), v);
            self.b -%= 1;
            const c2: u8 = if (up) self.c +% 1 else self.c -% 1;
            self.wz = if (up) port +% 1 else port -% 1;
            self.set_hl(if (up) self.hl() +% 1 else self.hl() -% 1);
            const k = @as(u16, v) + c2;
            if (repeat and self.b != 0) {
                self.block_io_flags(v, k, true);
                return 21;
            }
            self.block_io_flags(v, k, false);
            return 16;
        }

        fn block_out(self: *Self, bus: *BusT, comptime up: bool, comptime repeat: bool) u32 {
            const v = bus.read(self.hl());
            self.b -%= 1;
            bus.out(self.c, v);
            const port = self.bc();
            self.wz = if (up) port +% 1 else port -% 1;
            self.set_hl(if (up) self.hl() +% 1 else self.hl() -% 1);
            const k = @as(u16, v) + self.l;
            if (repeat and self.b != 0) {
                self.block_io_flags(v, k, true);
                return 21;
            }
            self.block_io_flags(v, k, false);
            return 16;
        }
    };
}
