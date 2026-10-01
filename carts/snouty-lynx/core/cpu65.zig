//! 65C02 interpreter (the Lynx's Rockwell set: RMB/SMB/BBR/BBS, no WAI/STP;
//! SPEC.md sections 3, 4, 16, 20), generic over a Bus type. PLAN.md "Frozen
//! for M1: core/cpu65.zig" is the contract; docs/CPU.md the notes.
//!
//! Bus contract (`Cpu(Bus)` calls nothing else):
//!
//! - `bus.fetch(addr: u16) u8`: an opcode or operand byte read at PC (the
//!   Lynx charges these 4 ticks in page mode).
//! - `bus.read(addr: u16) u8`: a data read (operands' memory, pointers,
//!   the stack, vectors).
//! - `bus.dummy(addr: u16) void`: an internal cycle: the dummy reads the
//!   65C02 makes while it computes (implied instructions' second cycle,
//!   indexing, the RMW re-read, the decimal extra cycle, JSR/RTS/RTI/pull
//!   stack and PC dummies, the IRQ sequence's two opcode cycles). The
//!   SingleStepTests list them as reads of `addr`; the Lynx charges a full
//!   cycle but no device sees it and the page-mode instruction stream
//!   stays open (lynx-tests lynx-page-mode.md: internal cycles do not
//!   contribute to, nor break, the sequential fetch stream). A taken
//!   branch's extra cycle is a `read` when the target differs from PC (it
//!   ends the stream) and a `dummy` for a zero displacement.
//! - `bus.write(addr: u16, v: u8) void`.
//! - `bus.irq_line() bool`: sampled at the start of `step`; when set and
//!   the previous instruction's interrupt poll allowed it (`irq_ok`), the
//!   step is the 7-cycle interrupt sequence instead of an instruction
//!   (pushes PCH, PCL, P with B clear, sets I, PC from `read($FFFE/$FFFF)`).
//!   The poll is the 6502's: an instruction polls in its last cycle with
//!   the I flag it has then, so CLI, SEI and PLP act one instruction late
//!   (CLI; INC: the INC runs before the IRQ), RTI at once, and the Lynx's
//!   1-cycle NOPs ($x3, $xB) do not poll at all: an IRQ cannot be taken
//!   right after one (lynx-tests cpu "UNDC NOP IRQ", measured on hardware).
//! - Optional `Bus.cpu_lynx_nops: bool` (a decl): when true, $CB and $DB
//!   are 1-byte 1-cycle NOPs like the rest of the $xB column, as the Lynx
//!   runs them (lynx-tests cpu Test 8 executes five of each between CLI and
//!   the sentinel and the IRQ still comes after the sentinel; Felix and
//!   Gearlynx agree). Absent or false: the suite's $CB (1 byte, 2 cycles)
//!   and $DB (2 bytes, 4 cycles, zp,X).
//!
//! Timing: the CPU does exactly the bus cycles the hardware does (the
//! SingleStepTests `cycles` lists are the reference), one `fetch`/`read`/
//! `write` call each; the bus turns them into 16 MHz ticks. `step` returns
//! nothing; the bus owns the clock. No NMI (the Lynx has no NMI source).
//!
//! Cycle patterns are the suite's (docs/CPU.md lists the quirks: the
//! decimal-mode extra cycle of ADC #/SBC # reads $0059/$0000, $CB is a
//! 1-byte 2-cycle NOP, $DB a 2-byte zp,X NOP unless `cpu_lynx_nops`,
//! $5C/$DC/$FC 3-byte 4-cycle).
//!
//! Variant switch for later consoles (NES, 2600, C64 would want an NMOS
//! 6502 with its illegal opcodes): `Variant` is the hook; only `.lynx` is
//! implemented in M1.

pub const Variant = enum { lynx };

/// Processor status bits.
pub const Flag = struct {
    pub const c: u8 = 0x01;
    pub const z: u8 = 0x02;
    pub const i: u8 = 0x04;
    pub const d: u8 = 0x08;
    pub const b: u8 = 0x10;
    pub const u: u8 = 0x20;
    pub const v: u8 = 0x40;
    pub const n: u8 = 0x80;
};

pub const Regs = struct {
    a: u8 = 0,
    x: u8 = 0,
    y: u8 = 0,
    s: u8 = 0xFF,
    /// Bits 4 and 5 always read set (as PHP pushes them).
    p: u8 = Flag.u | Flag.i,
    pc: u16 = 0,
};

/// The CPU over `Bus` (see the file comment for what `Bus` provides).
pub fn Cpu(comptime Bus: type) type {
    return struct {
        const Self = @This();
        pub const variant: Variant = .lynx;

        regs: Regs = .{},
        /// The last instruction's interrupt poll: an IRQ may be taken
        /// before the next one (see the file comment).
        irq_ok: bool = false,
        /// Instructions executed (interrupt sequences not counted); wraps.
        /// Diagnostic for the frontend overlay (SPEC.md section 14).
        instr_count: u32 = 0,

        /// The reset sequence: I set, D clear, S -= 3 (the three fake
        /// pushes), PC from `bus.read($FFFC/$FFFD)`. The Lynx core never
        /// calls this at boot (core/boot.zig sets the registers directly)
        /// but tests and later consoles do.
        pub fn reset(self: *Self, bus: *Bus) void {
            self.regs.p = (self.regs.p | Flag.i | Flag.u) & ~Flag.d;
            self.regs.s -%= 3;
            const lo: u16 = bus.read(0xFFFC);
            const hi: u16 = bus.read(0xFFFD);
            self.regs.pc = hi << 8 | lo;
        }

        /// One instruction, or the interrupt sequence when `bus.irq_line()`
        /// and I is clear.
        pub fn step(self: *Self, bus: *Bus) void {
            if (self.irq_ok and bus.irq_line()) {
                self.interrupt(bus);
                self.irq_ok = false;
                return;
            }
            self.regs.p |= Flag.u | Flag.b;
            self.instr_count +%= 1;
            const p_before = self.regs.p;
            const op = self.fetch8(bus);
            self.exec(bus, op);
            self.irq_ok = poll(op, p_before, self.regs.p);
        }

        /// Will the next `step` take the interrupt when the line is `line`?
        pub inline fn takes_irq(self: *const Self, line: bool) bool {
            return self.irq_ok and line;
        }

        /// The interrupt poll of instruction `op`: I as the instruction's
        /// last cycle sees it (before CLI/SEI/PLP change it), and never
        /// after a 1-cycle NOP (every $x3/$xB opcode has low bits 011).
        inline fn poll(op: u8, p_before: u8, p_after: u8) bool {
            if (op & 0x07 == 0x03 and (lynx_nops or (op != 0xCB and op != 0xDB))) return false;
            const p = if (op == 0x58 or op == 0x78 or op == 0x28) p_before else p_after;
            return p & Flag.i == 0;
        }

        const lynx_nops = @hasDecl(Bus, "cpu_lynx_nops") and Bus.cpu_lynx_nops;

        /// The 7-cycle IRQ sequence: the discarded opcode fetch and its
        /// repeat (as BRK's first two cycles, without advancing PC; internal
        /// cycles, `dummy`), PCH, PCL, P with B clear, then the vector.
        fn interrupt(self: *Self, bus: *Bus) void {
            const r = &self.regs;
            bus.dummy(r.pc);
            bus.dummy(r.pc);
            self.push(bus, @truncate(r.pc >> 8));
            self.push(bus, @truncate(r.pc));
            self.push(bus, (r.p | Flag.u) & ~Flag.b);
            r.p = (r.p | Flag.i | Flag.u | Flag.b) & ~Flag.d;
            const lo: u16 = bus.read(0xFFFE);
            const hi: u16 = bus.read(0xFFFF);
            r.pc = hi << 8 | lo;
        }

        // ---- bus helpers ----

        inline fn fetch8(self: *Self, bus: *Bus) u8 {
            const v = bus.fetch(self.regs.pc);
            self.regs.pc +%= 1;
            return v;
        }

        inline fn fetch16(self: *Self, bus: *Bus) u16 {
            const lo: u16 = self.fetch8(bus);
            const hi: u16 = self.fetch8(bus);
            return hi << 8 | lo;
        }

        inline fn push(self: *Self, bus: *Bus, v: u8) void {
            bus.write(0x100 | @as(u16, self.regs.s), v);
            self.regs.s -%= 1;
        }

        inline fn pull(self: *Self, bus: *Bus) u8 {
            self.regs.s +%= 1;
            return bus.read(0x100 | @as(u16, self.regs.s));
        }

        /// The dummy read of the byte after the opcode (implied and
        /// accumulator instructions, pushes and pulls).
        inline fn dummy_pc(self: *Self, bus: *Bus) void {
            bus.dummy(self.regs.pc);
        }

        // ---- addressing modes (each issues its own dummy cycles) ----

        inline fn ea_zp(self: *Self, bus: *Bus) u16 {
            return self.fetch8(bus);
        }

        /// zp,X / zp,Y: a dummy read of the unindexed zero-page address.
        inline fn ea_zp_idx(self: *Self, bus: *Bus, idx: u8) u16 {
            const z = self.fetch8(bus);
            bus.dummy(z);
            return z +% idx;
        }

        inline fn ea_abs(self: *Self, bus: *Bus) u16 {
            return self.fetch16(bus);
        }

        /// abs,X / abs,Y. A page crossing (or `always`, for stores and
        /// INC/DEC) costs a dummy read of the operand's high byte address.
        inline fn ea_abs_idx(self: *Self, bus: *Bus, idx: u8, always: bool) u16 {
            const base = self.fetch16(bus);
            const ea = base +% idx;
            if (always or (base ^ ea) & 0xFF00 != 0) bus.dummy(self.regs.pc -% 1);
            return ea;
        }

        inline fn zp_ptr(bus: *Bus, z: u8) u16 {
            const lo: u16 = bus.read(z);
            const hi: u16 = bus.read(z +% 1);
            return hi << 8 | lo;
        }

        /// (zp,X): dummy read of zp, then the pointer at zp + X.
        inline fn ea_izx(self: *Self, bus: *Bus) u16 {
            const z = self.fetch8(bus);
            bus.dummy(z);
            return zp_ptr(bus, z +% self.regs.x);
        }

        /// (zp),Y: a page crossing (or `always`, for STA) costs a dummy
        /// read of the operand address.
        inline fn ea_izy(self: *Self, bus: *Bus, always: bool) u16 {
            const z = self.fetch8(bus);
            const base = zp_ptr(bus, z);
            const ea = base +% self.regs.y;
            if (always or (base ^ ea) & 0xFF00 != 0) bus.dummy(self.regs.pc -% 1);
            return ea;
        }

        inline fn ea_izp(self: *Self, bus: *Bus) u16 {
            return zp_ptr(bus, self.fetch8(bus));
        }

        // ---- flags and ALU ----

        inline fn nz(self: *Self, v: u8) void {
            self.regs.p = (self.regs.p & ~(Flag.n | Flag.z)) | (v & Flag.n) | (if (v == 0) Flag.z else 0);
        }

        inline fn set_flag(self: *Self, f: u8, on: bool) void {
            if (on) self.regs.p |= f else self.regs.p &= ~f;
        }

        inline fn carry(self: *Self) u8 {
            return self.regs.p & Flag.c;
        }

        /// ADC/SBC: `ea` is the decimal-mode extra cycle's read address
        /// (the operand's own address; the suite's $0059/$0000 for #).
        fn adc(self: *Self, bus: *Bus, m: u8, ea: u16) void {
            const r = &self.regs;
            const a = r.a;
            const c: u16 = self.carry();
            if (r.p & Flag.d == 0) {
                const sum: u16 = @as(u16, a) + m + c;
                const res: u8 = @truncate(sum);
                self.set_flag(Flag.c, sum > 0xFF);
                self.set_flag(Flag.v, (~(a ^ m) & (a ^ res) & 0x80) != 0);
                r.a = res;
                self.nz(res);
                return;
            }
            bus.dummy(ea);
            // 65C02 decimal add (Bruce Clark, "Decimal Mode", appendix A).
            var lo: u16 = @as(u16, a & 0x0F) + (m & 0x0F) + c;
            if (lo >= 0x0A) lo = ((lo + 0x06) & 0x0F) + 0x10;
            var sum: u16 = @as(u16, a & 0xF0) + (m & 0xF0) + lo;
            // V from the signed sum of the high nibbles (sequence 2).
            const sv: i16 = @as(i16, @as(i8, @bitCast(a & 0xF0))) + @as(i16, @as(i8, @bitCast(m & 0xF0))) + @as(i16, @intCast(lo));
            self.set_flag(Flag.v, sv < -128 or sv > 127);
            if (sum >= 0xA0) sum += 0x60;
            self.set_flag(Flag.c, sum >= 0x100);
            r.a = @truncate(sum);
            self.nz(r.a);
        }

        fn sbc(self: *Self, bus: *Bus, m: u8, ea: u16) void {
            const r = &self.regs;
            const a = r.a;
            const borrow: u16 = 1 - @as(u16, self.carry());
            const diff: u16 = @as(u16, a) -% m -% borrow;
            const bin: u8 = @truncate(diff);
            self.set_flag(Flag.v, ((a ^ m) & (a ^ bin) & 0x80) != 0);
            self.set_flag(Flag.c, diff < 0x100);
            if (r.p & Flag.d == 0) {
                r.a = bin;
                self.nz(bin);
                return;
            }
            bus.dummy(ea);
            // 65C02 decimal subtract (Bruce Clark, sequence 4).
            const lo: i16 = @as(i16, a & 0x0F) - @as(i16, m & 0x0F) - @as(i16, @intCast(borrow));
            var res: i16 = @as(i16, a) - @as(i16, m) - @as(i16, @intCast(borrow));
            if (res < 0) res -= 0x60;
            if (lo < 0) res -= 0x06;
            r.a = @truncate(@as(u16, @bitCast(res)));
            self.nz(r.a);
        }

        inline fn cmp(self: *Self, reg: u8, m: u8) void {
            self.set_flag(Flag.c, reg >= m);
            self.nz(reg -% m);
        }

        inline fn bit(self: *Self, m: u8, imm: bool) void {
            const r = &self.regs;
            self.set_flag(Flag.z, r.a & m == 0);
            if (!imm) r.p = (r.p & ~(Flag.n | Flag.v)) | (m & (Flag.n | Flag.v));
        }

        /// The read-group operations in the cc=01 column order.
        const Alu = enum(u3) { ora, @"and", eor, adc, sta, lda, cmp, sbc };

        fn alu(self: *Self, bus: *Bus, op: Alu, m: u8, ea: u16) void {
            const r = &self.regs;
            switch (op) {
                .ora => {
                    r.a |= m;
                    self.nz(r.a);
                },
                .@"and" => {
                    r.a &= m;
                    self.nz(r.a);
                },
                .eor => {
                    r.a ^= m;
                    self.nz(r.a);
                },
                .adc => self.adc(bus, m, ea),
                .sta => unreachable,
                .lda => {
                    r.a = m;
                    self.nz(m);
                },
                .cmp => self.cmp(r.a, m),
                .sbc => self.sbc(bus, m, ea),
            }
        }

        const Rmw = enum { asl, lsr, rol, ror, inc, dec, tsb, trb };

        fn rmw_op(self: *Self, f: Rmw, v: u8) u8 {
            const r = &self.regs;
            switch (f) {
                .asl => {
                    self.set_flag(Flag.c, v & 0x80 != 0);
                    const o = v << 1;
                    self.nz(o);
                    return o;
                },
                .lsr => {
                    self.set_flag(Flag.c, v & 1 != 0);
                    const o = v >> 1;
                    self.nz(o);
                    return o;
                },
                .rol => {
                    const o = (v << 1) | self.carry();
                    self.set_flag(Flag.c, v & 0x80 != 0);
                    self.nz(o);
                    return o;
                },
                .ror => {
                    const o = (v >> 1) | (self.carry() << 7);
                    self.set_flag(Flag.c, v & 1 != 0);
                    self.nz(o);
                    return o;
                },
                .inc => {
                    const o = v +% 1;
                    self.nz(o);
                    return o;
                },
                .dec => {
                    const o = v -% 1;
                    self.nz(o);
                    return o;
                },
                .tsb => {
                    self.set_flag(Flag.z, r.a & v == 0);
                    return v | r.a;
                },
                .trb => {
                    self.set_flag(Flag.z, r.a & v == 0);
                    return v & ~r.a;
                },
            }
        }

        /// Read, dummy re-read (the 65C02 reads twice where the NMOS part
        /// wrote twice), write.
        fn rmw(self: *Self, bus: *Bus, f: Rmw, ea: u16) void {
            const v = bus.read(ea);
            bus.dummy(ea);
            bus.write(ea, self.rmw_op(f, v));
        }

        fn rmw_a(self: *Self, bus: *Bus, f: Rmw) void {
            self.dummy_pc(bus);
            self.regs.a = self.rmw_op(f, self.regs.a);
        }

        /// Relative branch: taken costs a dummy read of PC, a page
        /// crossing another of the target's low byte in the old page.
        fn branch(self: *Self, bus: *Bus, taken: bool) void {
            const off: u8 = self.fetch8(bus);
            if (!taken) return;
            const r = &self.regs;
            const target = r.pc +% @as(u16, @bitCast(@as(i16, @as(i8, @bitCast(off)))));
            taken_cycle(bus, r.pc, target);
            if ((target ^ r.pc) & 0xFF00 != 0) bus.dummy((r.pc & 0xFF00) | (target & 0x00FF));
            r.pc = target;
        }

        /// The extra cycle of a taken branch (a read of PC). To another
        /// address it is a `read`, which ends the sequential fetch stream
        /// (the Lynx's page mode: the target's fetch is a full cycle); with
        /// a zero displacement the stream goes on, so it is a `dummy`
        /// (lynx-tests lynx-page-mode.md, measured on hardware).
        inline fn taken_cycle(bus: *Bus, pc: u16, target: u16) void {
            if (target != pc) _ = bus.read(pc) else bus.dummy(pc);
        }

        /// BBRn/BBSn zp,rel (5 cycles; taken +1, page crossing +1, both
        /// dummy reads of PC after the offset).
        fn bbx(self: *Self, bus: *Bus, mask: u8, set: bool) void {
            const z = self.fetch8(bus);
            const v = bus.read(z);
            bus.dummy(z);
            const off: u8 = self.fetch8(bus);
            if ((v & mask != 0) != set) return;
            const r = &self.regs;
            const target = r.pc +% @as(u16, @bitCast(@as(i16, @as(i8, @bitCast(off)))));
            taken_cycle(bus, r.pc, target);
            if ((target ^ r.pc) & 0xFF00 != 0) bus.dummy(r.pc);
            r.pc = target;
        }

        /// RMBn/SMBn zp (5 cycles: read, dummy re-read, write).
        fn xmb(self: *Self, bus: *Bus, mask: u8, set: bool) void {
            const z = self.fetch8(bus);
            const v = bus.read(z);
            bus.dummy(z);
            bus.write(z, if (set) v | mask else v & ~mask);
        }

        /// The cc=01 column (ORA AND EOR ADC STA LDA CMP SBC) plus (zp)
        /// in column $x2, decoded from the opcode's low five bits.
        fn group1(self: *Self, bus: *Bus, op: u8) void {
            const r = &self.regs;
            const f: Alu = @fromBackingInt(@intCast(op >> 5));
            if (f == .sta) {
                const ea: u16 = switch (op & 0x1F) {
                    0x01 => self.ea_izx(bus),
                    0x05 => self.ea_zp(bus),
                    0x0D => self.ea_abs(bus),
                    0x11 => self.ea_izy(bus, true),
                    0x12 => self.ea_izp(bus),
                    0x15 => self.ea_zp_idx(bus, r.x),
                    0x19 => self.ea_abs_idx(bus, r.y, true),
                    0x1D => self.ea_abs_idx(bus, r.x, true),
                    else => unreachable,
                };
                bus.write(ea, r.a);
                return;
            }
            if (op & 0x1F == 0x09) {
                const m = self.fetch8(bus);
                // Suite quirk: the decimal extra cycle of ADC # reads $0059,
                // of SBC # $0000 (docs/CPU.md).
                self.alu(bus, f, m, if (f == .adc) 0x0059 else 0x0000);
                return;
            }
            const ea: u16 = switch (op & 0x1F) {
                0x01 => self.ea_izx(bus),
                0x05 => self.ea_zp(bus),
                0x0D => self.ea_abs(bus),
                0x11 => self.ea_izy(bus, false),
                0x12 => self.ea_izp(bus),
                0x15 => self.ea_zp_idx(bus, r.x),
                0x19 => self.ea_abs_idx(bus, r.y, false),
                0x1D => self.ea_abs_idx(bus, r.x, false),
                else => unreachable,
            };
            self.alu(bus, f, bus.read(ea), ea);
        }

        fn load_x(self: *Self, v: u8) void {
            self.regs.x = v;
            self.nz(v);
        }

        fn load_y(self: *Self, v: u8) void {
            self.regs.y = v;
            self.nz(v);
        }

        fn exec(self: *Self, bus: *Bus, op: u8) void {
            const r = &self.regs;
            switch (op) {
                // ---- cc=01 column and (zp) ----
                0x01,
                0x05,
                0x09,
                0x0D,
                0x11,
                0x12,
                0x15,
                0x19,
                0x1D,
                0x21,
                0x25,
                0x29,
                0x2D,
                0x31,
                0x32,
                0x35,
                0x39,
                0x3D,
                0x41,
                0x45,
                0x49,
                0x4D,
                0x51,
                0x52,
                0x55,
                0x59,
                0x5D,
                0x61,
                0x65,
                0x69,
                0x6D,
                0x71,
                0x72,
                0x75,
                0x79,
                0x7D,
                0x81,
                0x85,
                0x8D,
                0x91,
                0x92,
                0x95,
                0x99,
                0x9D,
                0xA1,
                0xA5,
                0xA9,
                0xAD,
                0xB1,
                0xB2,
                0xB5,
                0xB9,
                0xBD,
                0xC1,
                0xC5,
                0xC9,
                0xCD,
                0xD1,
                0xD2,
                0xD5,
                0xD9,
                0xDD,
                0xE1,
                0xE5,
                0xE9,
                0xED,
                0xF1,
                0xF2,
                0xF5,
                0xF9,
                0xFD,
                => self.group1(bus, op),

                // ---- shifts and INC/DEC ----
                0x06 => self.rmw(bus, .asl, self.ea_zp(bus)),
                0x16 => self.rmw(bus, .asl, self.ea_zp_idx(bus, r.x)),
                0x0E => self.rmw(bus, .asl, self.ea_abs(bus)),
                0x1E => self.rmw(bus, .asl, self.ea_abs_idx(bus, r.x, false)),
                0x0A => self.rmw_a(bus, .asl),
                0x26 => self.rmw(bus, .rol, self.ea_zp(bus)),
                0x36 => self.rmw(bus, .rol, self.ea_zp_idx(bus, r.x)),
                0x2E => self.rmw(bus, .rol, self.ea_abs(bus)),
                0x3E => self.rmw(bus, .rol, self.ea_abs_idx(bus, r.x, false)),
                0x2A => self.rmw_a(bus, .rol),
                0x46 => self.rmw(bus, .lsr, self.ea_zp(bus)),
                0x56 => self.rmw(bus, .lsr, self.ea_zp_idx(bus, r.x)),
                0x4E => self.rmw(bus, .lsr, self.ea_abs(bus)),
                0x5E => self.rmw(bus, .lsr, self.ea_abs_idx(bus, r.x, false)),
                0x4A => self.rmw_a(bus, .lsr),
                0x66 => self.rmw(bus, .ror, self.ea_zp(bus)),
                0x76 => self.rmw(bus, .ror, self.ea_zp_idx(bus, r.x)),
                0x6E => self.rmw(bus, .ror, self.ea_abs(bus)),
                0x7E => self.rmw(bus, .ror, self.ea_abs_idx(bus, r.x, false)),
                0x6A => self.rmw_a(bus, .ror),
                0xC6 => self.rmw(bus, .dec, self.ea_zp(bus)),
                0xD6 => self.rmw(bus, .dec, self.ea_zp_idx(bus, r.x)),
                0xCE => self.rmw(bus, .dec, self.ea_abs(bus)),
                0xDE => self.rmw(bus, .dec, self.ea_abs_idx(bus, r.x, true)),
                0x3A => self.rmw_a(bus, .dec),
                0xE6 => self.rmw(bus, .inc, self.ea_zp(bus)),
                0xF6 => self.rmw(bus, .inc, self.ea_zp_idx(bus, r.x)),
                0xEE => self.rmw(bus, .inc, self.ea_abs(bus)),
                0xFE => self.rmw(bus, .inc, self.ea_abs_idx(bus, r.x, true)),
                0x1A => self.rmw_a(bus, .inc),
                0x04 => self.rmw(bus, .tsb, self.ea_zp(bus)),
                0x0C => self.rmw(bus, .tsb, self.ea_abs(bus)),
                0x14 => self.rmw(bus, .trb, self.ea_zp(bus)),
                0x1C => self.rmw(bus, .trb, self.ea_abs(bus)),

                // ---- X and Y loads, stores, compares ----
                0xA2 => self.load_x(self.fetch8(bus)),
                0xA6 => self.load_x(bus.read(self.ea_zp(bus))),
                0xB6 => self.load_x(bus.read(self.ea_zp_idx(bus, r.y))),
                0xAE => self.load_x(bus.read(self.ea_abs(bus))),
                0xBE => self.load_x(bus.read(self.ea_abs_idx(bus, r.y, false))),
                0xA0 => self.load_y(self.fetch8(bus)),
                0xA4 => self.load_y(bus.read(self.ea_zp(bus))),
                0xB4 => self.load_y(bus.read(self.ea_zp_idx(bus, r.x))),
                0xAC => self.load_y(bus.read(self.ea_abs(bus))),
                0xBC => self.load_y(bus.read(self.ea_abs_idx(bus, r.x, false))),
                0x86 => bus.write(self.ea_zp(bus), r.x),
                0x96 => bus.write(self.ea_zp_idx(bus, r.y), r.x),
                0x8E => bus.write(self.ea_abs(bus), r.x),
                0x84 => bus.write(self.ea_zp(bus), r.y),
                0x94 => bus.write(self.ea_zp_idx(bus, r.x), r.y),
                0x8C => bus.write(self.ea_abs(bus), r.y),
                0x64 => bus.write(self.ea_zp(bus), 0),
                0x74 => bus.write(self.ea_zp_idx(bus, r.x), 0),
                0x9C => bus.write(self.ea_abs(bus), 0),
                0x9E => bus.write(self.ea_abs_idx(bus, r.x, true), 0),
                0xE0 => self.cmp(r.x, self.fetch8(bus)),
                0xE4 => self.cmp(r.x, bus.read(self.ea_zp(bus))),
                0xEC => self.cmp(r.x, bus.read(self.ea_abs(bus))),
                0xC0 => self.cmp(r.y, self.fetch8(bus)),
                0xC4 => self.cmp(r.y, bus.read(self.ea_zp(bus))),
                0xCC => self.cmp(r.y, bus.read(self.ea_abs(bus))),

                // ---- BIT ----
                0x89 => self.bit(self.fetch8(bus), true),
                0x24 => self.bit(bus.read(self.ea_zp(bus)), false),
                0x34 => self.bit(bus.read(self.ea_zp_idx(bus, r.x)), false),
                0x2C => self.bit(bus.read(self.ea_abs(bus)), false),
                0x3C => self.bit(bus.read(self.ea_abs_idx(bus, r.x, false)), false),

                // ---- branches and jumps ----
                0x10 => self.branch(bus, r.p & Flag.n == 0),
                0x30 => self.branch(bus, r.p & Flag.n != 0),
                0x50 => self.branch(bus, r.p & Flag.v == 0),
                0x70 => self.branch(bus, r.p & Flag.v != 0),
                0x90 => self.branch(bus, r.p & Flag.c == 0),
                0xB0 => self.branch(bus, r.p & Flag.c != 0),
                0xD0 => self.branch(bus, r.p & Flag.z == 0),
                0xF0 => self.branch(bus, r.p & Flag.z != 0),
                0x80 => self.branch(bus, true),
                0x4C => r.pc = self.fetch16(bus),
                0x6C => {
                    // JMP (abs): no page-wrap bug, but the extra cycle is
                    // the NMOS (wrapped) high-byte read, before the real one.
                    const ptr = self.fetch16(bus);
                    const lo: u16 = bus.read(ptr);
                    bus.dummy((ptr & 0xFF00) | ((ptr +% 1) & 0x00FF));
                    const hi: u16 = bus.read(ptr +% 1);
                    r.pc = hi << 8 | lo;
                },
                0x7C => {
                    // JMP (abs,X): dummy read of the operand's low byte
                    // address (the suite's).
                    const base = self.fetch16(bus);
                    bus.dummy(r.pc -% 2);
                    const ptr = base +% r.x;
                    const lo: u16 = bus.read(ptr);
                    const hi: u16 = bus.read(ptr +% 1);
                    r.pc = hi << 8 | lo;
                },
                0x20 => {
                    const lo: u16 = self.fetch8(bus);
                    bus.dummy(0x100 | @as(u16, r.s));
                    self.push(bus, @truncate(r.pc >> 8));
                    self.push(bus, @truncate(r.pc));
                    const hi: u16 = bus.fetch(r.pc);
                    r.pc = hi << 8 | lo;
                },
                0x60 => {
                    self.dummy_pc(bus);
                    bus.dummy(0x100 | @as(u16, r.s));
                    const lo: u16 = self.pull(bus);
                    const hi: u16 = self.pull(bus);
                    const ret = hi << 8 | lo;
                    bus.dummy(ret);
                    r.pc = ret +% 1;
                },
                0x40 => {
                    self.dummy_pc(bus);
                    bus.dummy(0x100 | @as(u16, r.s));
                    r.p = self.pull(bus) | Flag.u | Flag.b;
                    const lo: u16 = self.pull(bus);
                    const hi: u16 = self.pull(bus);
                    r.pc = hi << 8 | lo;
                },
                0x00 => {
                    _ = self.fetch8(bus); // signature byte
                    self.push(bus, @truncate(r.pc >> 8));
                    self.push(bus, @truncate(r.pc));
                    self.push(bus, r.p | Flag.u | Flag.b);
                    r.p = (r.p | Flag.i) & ~Flag.d;
                    const lo: u16 = bus.read(0xFFFE);
                    const hi: u16 = bus.read(0xFFFF);
                    r.pc = hi << 8 | lo;
                },

                // ---- stack ----
                0x48 => {
                    self.dummy_pc(bus);
                    self.push(bus, r.a);
                },
                0xDA => {
                    self.dummy_pc(bus);
                    self.push(bus, r.x);
                },
                0x5A => {
                    self.dummy_pc(bus);
                    self.push(bus, r.y);
                },
                0x08 => {
                    self.dummy_pc(bus);
                    self.push(bus, r.p | Flag.u | Flag.b);
                },
                0x68, 0xFA, 0x7A, 0x28 => {
                    self.dummy_pc(bus);
                    bus.dummy(0x100 | @as(u16, r.s));
                    const v = self.pull(bus);
                    switch (op) {
                        0x68 => {
                            r.a = v;
                            self.nz(v);
                        },
                        0xFA => self.load_x(v),
                        0x7A => self.load_y(v),
                        else => r.p = v | Flag.u | Flag.b,
                    }
                },

                // ---- implied ----
                0x18, 0x38, 0x58, 0x78, 0xB8, 0xD8, 0xF8, 0xAA, 0xA8, 0x8A, 0x98, 0xBA, 0x9A, 0xE8, 0xC8, 0xCA, 0x88, 0xEA => {
                    self.dummy_pc(bus);
                    switch (op) {
                        0x18 => r.p &= ~Flag.c,
                        0x38 => r.p |= Flag.c,
                        0x58 => r.p &= ~Flag.i,
                        0x78 => r.p |= Flag.i,
                        0xB8 => r.p &= ~Flag.v,
                        0xD8 => r.p &= ~Flag.d,
                        0xF8 => r.p |= Flag.d,
                        0xAA => self.load_x(r.a),
                        0xA8 => self.load_y(r.a),
                        0x8A => {
                            r.a = r.x;
                            self.nz(r.a);
                        },
                        0x98 => {
                            r.a = r.y;
                            self.nz(r.a);
                        },
                        0xBA => self.load_x(r.s),
                        0x9A => r.s = r.x,
                        0xE8 => self.load_x(r.x +% 1),
                        0xC8 => self.load_y(r.y +% 1),
                        0xCA => self.load_x(r.x -% 1),
                        0x88 => self.load_y(r.y -% 1),
                        else => {}, // 0xEA NOP
                    }
                },

                // ---- Rockwell bit instructions ----
                0x07, 0x17, 0x27, 0x37, 0x47, 0x57, 0x67, 0x77 => self.xmb(bus, @as(u8, 1) << @intCast(op >> 4), false),
                0x87, 0x97, 0xA7, 0xB7, 0xC7, 0xD7, 0xE7, 0xF7 => self.xmb(bus, @as(u8, 1) << @intCast((op >> 4) & 7), true),
                0x0F, 0x1F, 0x2F, 0x3F, 0x4F, 0x5F, 0x6F, 0x7F => self.bbx(bus, @as(u8, 1) << @intCast(op >> 4), false),
                0x8F, 0x9F, 0xAF, 0xBF, 0xCF, 0xDF, 0xEF, 0xFF => self.bbx(bus, @as(u8, 1) << @intCast((op >> 4) & 7), true),

                // ---- undefined opcodes: NOPs with the suite's bytes and cycles ----
                // $x2: 2 bytes, 2 cycles.
                0x02, 0x22, 0x42, 0x62, 0x82, 0xC2, 0xE2 => _ = self.fetch8(bus),
                // $44: zp, 3 cycles.
                0x44 => _ = bus.read(self.ea_zp(bus)),
                // $54/$D4/$F4 and (suite) $DB: zp,X, 4 cycles.
                0x54, 0xD4, 0xF4 => _ = bus.read(self.ea_zp_idx(bus, r.x)),
                0xDB => if (!lynx_nops) {
                    _ = bus.read(self.ea_zp_idx(bus, r.x));
                },
                // $5C/$DC/$FC: 3 bytes, 4 cycles (the last re-reads the
                // operand's high byte address; Felix has $5C at 8).
                0x5C, 0xDC, 0xFC => {
                    _ = self.fetch16(bus);
                    bus.dummy(r.pc -% 1);
                },
                // $CB (WAI on WDC parts): 1 byte, 2 cycles in the suite; 1
                // cycle on the Lynx (`lynx_nops`).
                0xCB => if (!lynx_nops) self.dummy_pc(bus),
                // $x3/$xB: 1 byte, 1 cycle.
                0x03,
                0x13,
                0x23,
                0x33,
                0x43,
                0x53,
                0x63,
                0x73,
                0x83,
                0x93,
                0xA3,
                0xB3,
                0xC3,
                0xD3,
                0xE3,
                0xF3,
                0x0B,
                0x1B,
                0x2B,
                0x3B,
                0x4B,
                0x5B,
                0x6B,
                0x7B,
                0x8B,
                0x9B,
                0xAB,
                0xBB,
                0xEB,
                0xFB,
                => {},
            }
        }
    };
}
