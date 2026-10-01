//! Suzy (SPEC.md sections 3, 4 and 7): the sprite engine (SCB walker,
//! literal and packed line decoder at 1-4 bpp, 8.8 scaling, stretch, tilt,
//! the four quadrants, H/V flip, the eight sprite types, collision buffer
//! and depository), the math unit (16x16 multiply with sign and
//! accumulate, 32/16 divide) and the hardware registers at $FC00-$FCFF.
//! PLAN.md "Frozen for M1: core/suzy.zig" is the contract; docs/SUZY.md
//! says what is exact, what is approximate and what is still open.
//!
//! What the bus (core/lynx.zig, Track C) does with it:
//!
//! - `write(addr, v)` / `read(addr)` for every Suzy address except $B0-$B3
//!   (JOYSTICK, SWITCHES, RCART0, RCART1), which the bus serves itself from
//!   the pad word and the cart port; the bus calls `lefthand()` to swap the
//!   joystick direction bits (SPRSYS bit 3). Math unit operations complete
//!   inside `write` (MATHA starts a multiply, MATHE a divide), so a read of
//!   SPRSYS never shows a math in progress.
//! - Sprites draw when the CPU sleeps: SPRGO ($91) bit 0 only latches the
//!   request; the bus calls `run_sprites(ram)` on the CPUSLEEP write
//!   (Mikey $FD91) while `sprites_pending()`, which walks the whole list at
//!   once, writes the video and collision buffers and the depository bytes
//!   into `ram`, clears the request and returns the 16 MHz ticks the CPU is
//!   charged (SPEC.md section 4: pixels written and bytes read, an
//!   estimate; docs/SUZY.md "Tick model"). Everything Suzy touches is in
//!   the 64 KB `ram`; it never sees the overlays.
//! - `pixels_drawn` counts pixels written since reset (the overlay's
//!   "Suzy pixels per frame"; the frontend differences it).
//!
//! Register map ($FC00 + addr; Epyx hardware appendix, SPEC.md section 20):
//! $00-$2F the sprite engine's 16-bit registers, even address = low byte,
//! a CPU write to a low byte zeroes the high byte (TMPADR, TILTACUM, HOFF,
//! VOFF, VIDBAS, COLLBAS, VIDADR, COLLADR, SCBNEXT $10, SPRDLINE, HPOSSTRT,
//! VPOSSTRT, SPRHSIZ, SPRVSIZ, STRETCH, TILT, SPRDOFF, SPRVPOS, COLLOFF,
//! VSIZACUM, HSIZOFF $28, VSIZOFF, SCBADR, PROCADR), $52-$6F math (MATHD..
//! MATHA $52-$55, MATHP/N $56-$57, MATHH..MATHE $60-$63, MATHM..MATHJ
//! $6C-$6F), $80 SPRCTL0, $81 SPRCTL1, $82 SPRCOLL, $83 SPRINIT, $88
//! SUZYHREV, $89 SUZYSREV, $90 SUZYBUSEN, $91 SPRGO, $92 SPRSYS, $B0
//! JOYSTICK, $B1 SWITCHES, $B2 RCART0, $B3 RCART1, $C0-$C3 LEDs/parallel
//! (ignored).

const std = @import("std");

pub const screen_width: i32 = 160;
pub const screen_height: i32 = 102;
pub const line_bytes: u16 = 80;

/// Word index (addr >> 1) of each 16-bit engine register in `Suzy.regs`.
pub const reg = struct {
    pub const tmpadr = 0x00 >> 1;
    pub const tiltacum = 0x02 >> 1;
    pub const hoff = 0x04 >> 1;
    pub const voff = 0x06 >> 1;
    pub const vidbas = 0x08 >> 1;
    pub const collbas = 0x0A >> 1;
    pub const vidadr = 0x0C >> 1;
    pub const colladr = 0x0E >> 1;
    pub const scbnext = 0x10 >> 1;
    pub const sprdline = 0x12 >> 1;
    pub const hposstrt = 0x14 >> 1;
    pub const vposstrt = 0x16 >> 1;
    pub const sprhsiz = 0x18 >> 1;
    pub const sprvsiz = 0x1A >> 1;
    pub const stretch = 0x1C >> 1;
    pub const tilt = 0x1E >> 1;
    pub const sprdoff = 0x20 >> 1;
    pub const sprvpos = 0x22 >> 1;
    pub const colloff = 0x24 >> 1;
    pub const vsizacum = 0x26 >> 1;
    pub const hsizoff = 0x28 >> 1;
    pub const vsizoff = 0x2A >> 1;
    pub const scbadr = 0x2C >> 1;
    pub const procadr = 0x2E >> 1;
    pub const count = 24;
};

/// Byte addresses ($FC00 + addr) of the other registers.
pub const addr = struct {
    pub const mathd = 0x52;
    pub const mathc = 0x53;
    pub const mathb = 0x54;
    pub const matha = 0x55;
    pub const mathp = 0x56;
    pub const mathn = 0x57;
    pub const mathh = 0x60;
    pub const mathg = 0x61;
    pub const mathf = 0x62;
    pub const mathe = 0x63;
    pub const mathm = 0x6C;
    pub const mathl = 0x6D;
    pub const mathk = 0x6E;
    pub const mathj = 0x6F;
    pub const sprctl0 = 0x80;
    pub const sprctl1 = 0x81;
    pub const sprcoll = 0x82;
    pub const sprinit = 0x83;
    pub const suzyhrev = 0x88;
    pub const suzysrev = 0x89;
    pub const suzybusen = 0x90;
    pub const sprgo = 0x91;
    pub const sprsys = 0x92;
};

/// The bus-time estimate (docs/SUZY.md "Tick model"; tuned in M4).
pub const tick_cost = struct {
    /// A drawn sprite's SCB fetch and setup.
    pub const sprite_header: u32 = 50;
    /// A skipped sprite (SPRCTL1 bit 2): five SCB bytes.
    pub const skipped_sprite: u32 = 25;
    /// Each source data byte read (offset bytes once per source line, the
    /// line's data bytes once per destination row drawn).
    pub const byte_read: u32 = 5;
    /// Each pixel written to the video buffer.
    pub const pixel_write: u32 = 5;
    /// Each collision buffer pixel accessed.
    pub const coll_access: u32 = 5;
    /// Safety cap: a list (or a sprite whose data never ends) that would
    /// keep Suzy busy longer than this stops there; the hardware would hang.
    pub const run_cap: u32 = 4_000_000;
};

/// Math unit durations in 16 MHz ticks (Epyx "Math": 44 ticks, 54 with
/// sign or accumulate; divide 176 + 14 per leading zero bit of NP).
pub const math_ticks = struct {
    pub const multiply: u32 = 44;
    pub const multiply_signed_or_acc: u32 = 54;
    pub const divide: u32 = 176;
    pub const divide_per_zero: u32 = 14;
};

/// Draw order of the quadrants: SE, NE, NW, SW, starting from SPRCTL1
/// bits 0-1 (bit 0 left, bit 1 up: SE 0, SW 1, NE 2, NW 3).
const quad_cycle = [4]u2{ 0, 2, 3, 1 };
const quad_pos = [4]u2{ 0, 3, 1, 2 };

const flag_opaque: u8 = 1;
const flag_collide: u8 = 2;

pub const Suzy = struct {
    /// SPRSYS ($FC92) as last written (bit 7 signed math, 6 accumulate, 5
    /// no collide, 4 vstretch, 3 lefthand, 2 clear unsafe, 1 sprite to stop).
    sprsys: u8 = 0,
    /// SPRGO ($FC91) as last written: bit 0 sprite go (the pending
    /// request), bit 2 everon.
    sprgo: u8 = 0,
    /// Pixels written by the sprite engine since reset (wraps).
    pixels_drawn: u32 = 0,

    /// The 48 physical registers $00-$2F (`reg`), also seen at $40-$6F:
    /// the math unit's ABCD, NP, EFGH and JKLM are SPRDLINE..VPOSSTRT,
    /// SPRDOFF/SPRVPOS and SCBADR/PROCADR (lynx-tests memio "SUZY MIRRORS").
    regs: [reg.count]u16 = @splat(0),
    /// Signs saved by the signed-multiply conversion (on MATHA/MATHC writes).
    sign_ab_neg: bool = false,
    sign_cd_neg: bool = false,
    /// SPRSYS read bit 6: accumulator overflow / divide by zero.
    math_warning: bool = false,
    /// SPRSYS read bit 5: last carry.
    math_carry: bool = false,
    /// SPRSYS read bit 2: set when a math operation starts (and on any
    /// engine register write while one runs), cleared by writing SPRSYS
    /// with bit 2 set.
    unsafe_access: bool = false,
    /// Bus tick at which the running math operation completes (SPRSYS bit
    /// 7 reads 1 before it). Only `write_at`/`read_at` see time; plain
    /// `write`/`read` behave as if the math were instant.
    math_done: u64 = 0,
    sprctl0: u8 = 0,
    sprctl1: u8 = 0,
    sprcoll: u8 = 0,
    sprinit: u8 = 0,
    suzybusen: u8 = 0,
    /// The pen index palette: pen index -> pen number.
    pen_map: [16]u8 = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },

    pub fn reset(s: *Suzy) void {
        s.* = .{};
    }

    /// A register read at $FC00 + addr (never $B0-$B3), math instant.
    pub fn read(s: *const Suzy, a: u8) u8 {
        return s.read_at(a, std.math.maxInt(u64));
    }

    /// A register read at bus tick `now` (SPRSYS bit 7 shows a math
    /// operation still running).
    pub fn read_at(s: *const Suzy, a: u8, now: u64) u8 {
        if (a < 0x30 or (a >= 0x40 and a < 0x70)) {
            const w = s.regs[(a & 0x3F) >> 1];
            return if (a & 1 == 0) @truncate(w) else @truncate(w >> 8);
        }
        return switch (a) {
            addr.suzyhrev => 0x01,
            addr.sprsys => s.sprsys_read(now),
            // Write-only and unallocated addresses: Felix measured mostly
            // %11111100 here; any constant will do for games.
            else => if (a < 0x80) 0x00 else 0xFC,
        };
    }

    fn sprsys_read(s: *const Suzy, now: u64) u8 {
        var v: u8 = s.sprsys & 0x1A; // vstretch, lefthand, stop request
        if (now < s.math_done) v |= 0x80;
        if (s.math_warning) v |= 0x40;
        if (s.math_carry) v |= 0x20;
        if (s.unsafe_access) v |= 0x04;
        if (s.sprgo & 1 != 0) v |= 0x01;
        return v;
    }

    /// A register write at $FC00 + addr (never $B0-$B3), math instant.
    pub fn write(s: *Suzy, a: u8, v: u8) void {
        s.write_at(a, v, 0);
    }

    /// A register write at bus tick `now`: a math operation started here
    /// reads as running in SPRSYS bit 7 until its documented duration has
    /// passed (its results are visible at once).
    pub fn write_at(s: *Suzy, a: u8, v: u8, now: u64) void {
        if (a < 0x30 or (a >= 0x40 and a < 0x70)) {
            if (now < s.math_done) s.unsafe_access = true;
            const i = (a & 0x3F) >> 1;
            if (a & 1 == 0) {
                s.regs[i] = v; // a low-byte write zeroes the high byte
            } else {
                s.regs[i] = (s.regs[i] & 0x00FF) | (@as(u16, v) << 8);
            }
            if (a >= 0x40) s.math_command(a, now);
            return;
        }
        switch (a) {
            addr.sprctl0 => s.sprctl0 = v,
            addr.sprctl1 => s.sprctl1 = v,
            addr.sprcoll => s.sprcoll = v,
            addr.sprinit => s.sprinit = v,
            addr.suzybusen => s.suzybusen = v,
            addr.sprgo => {
                s.sprgo = v;
                s.sprsys &= ~@as(u8, 0x02); // either edge clears the stop request
            },
            addr.sprsys => {
                s.sprsys = v;
                if (v & 0x04 != 0) s.unsafe_access = false;
            },
            else => {},
        }
    }

    /// A sprite list is waiting for the bus (SPRGO bit 0 and SUZYBUSEN).
    pub fn sprites_pending(s: *const Suzy) bool {
        return s.sprgo & 1 != 0 and s.suzybusen & 1 != 0;
    }

    /// SPRSYS bit 3: the joystick direction bits are swapped.
    pub fn lefthand(s: *const Suzy) bool {
        return s.sprsys & 0x08 != 0;
    }

    // ---------------------------------------------------------------
    // Math unit

    /// The 16-bit value whose low byte is at math address `a` ($40-$6F).
    fn m16(s: *const Suzy, a: u8) u16 {
        return s.regs[(a & 0x3F) >> 1];
    }

    fn set_m16(s: *Suzy, a: u8, v: u16) void {
        s.regs[(a & 0x3F) >> 1] = v;
    }

    fn m32(s: *const Suzy, a: u8) u32 {
        return @as(u32, s.m16(a)) | (@as(u32, s.m16(a + 2)) << 16);
    }

    fn set_m32(s: *Suzy, a: u8, v: u32) void {
        s.set_m16(a, @truncate(v));
        s.set_m16(a + 2, @truncate(v >> 16));
    }

    /// What a write to math address `a` ($40-$6F, already stored) starts.
    fn math_command(s: *Suzy, a: u8, now: u64) void {
        switch (a) {
            addr.mathc => if (s.sprsys & 0x80 != 0) {
                s.sign_cd_neg = s.sign_convert(addr.mathd);
            },
            addr.matha => {
                if (s.sprsys & 0x80 != 0) s.sign_ab_neg = s.sign_convert(addr.mathb);
                s.multiply();
                s.math_started(now, if (s.sprsys & 0xC0 != 0) math_ticks.multiply_signed_or_acc else math_ticks.multiply);
            },
            addr.mathe => {
                const np = s.m16(addr.mathp);
                s.divide();
                s.math_started(now, math_ticks.divide + math_ticks.divide_per_zero * @as(u32, @clz(np)));
            },
            // "The write to 'M' will clear the accumulator overflow bit";
            // the last carry stays (lynx-tests math ACCUM MUL).
            addr.mathm => s.math_warning = false,
            else => {},
        }
    }

    fn math_started(s: *Suzy, now: u64, ticks: u32) void {
        s.unsafe_access = true; // lynx-tests math: set after every operation
        s.math_done = now +| ticks;
    }

    /// The signed-multiply input conversion, done when the high byte is
    /// written: the operand becomes its magnitude in place and the sign is
    /// saved. The hardware tests bit 15 of (value - 1), so $8000 counts as
    /// positive and 0 as negative (Epyx "Bugs in MathLand").
    fn sign_convert(s: *Suzy, lo: u8) bool {
        const val = s.m16(lo);
        if ((val -% 1) & 0x8000 != 0) {
            s.set_m16(lo, ~val +% 1);
            return true;
        }
        return false;
    }

    /// AB x CD -> EFGH, optionally accumulated into JKLM. Last carry: set
    /// when a signed product was negated (and is non-zero), or by the
    /// accumulator's carry out of bit 31, which is also the warning
    /// (lynx-tests math SIGNED MUL, ACCUM MUL).
    fn multiply(s: *Suzy) void {
        var prod: u32 = @as(u32, s.m16(addr.mathb)) * @as(u32, s.m16(addr.mathd));
        s.math_carry = false;
        if (s.sprsys & 0x80 != 0 and s.sign_ab_neg != s.sign_cd_neg) {
            s.math_carry = prod != 0;
            prod = ~prod +% 1;
        }
        s.set_m32(addr.mathh, prod);
        s.math_warning = false;
        if (s.sprsys & 0x40 != 0) {
            const sum = @addWithOverflow(s.m32(addr.mathm), prod);
            const carry = sum[1] != 0;
            s.math_warning = carry;
            s.math_carry = carry;
            s.set_m32(addr.mathm, sum[0]);
        }
    }

    /// EFGH / NP -> ABCD, remainder in JKLM (JK = 0). Unsigned only. Last
    /// carry: the remainder is non-zero (lynx-tests math SIMPLE DIV, NO
    /// REM DIV).
    fn divide(s: *Suzy) void {
        const np: u32 = s.m16(addr.mathp);
        const efgh = s.m32(addr.mathh);
        if (np == 0) {
            s.set_m32(addr.mathd, 0xFFFF_FFFF);
            s.set_m32(addr.mathm, 0);
            s.math_warning = true;
            s.math_carry = true;
            return;
        }
        const rem = efgh % np;
        s.set_m32(addr.mathd, efgh / np);
        s.set_m32(addr.mathm, rem);
        s.math_warning = false;
        s.math_carry = rem != 0;
    }

    // ---------------------------------------------------------------
    // Sprite engine

    /// Draw the whole list now; returns the ticks to charge the CPU.
    pub fn run_sprites(s: *Suzy, ram: *[0x10000]u8) u32 {
        var ticks: u32 = 0;
        // Only the upper byte of SCBNEXT is tested for the end of the list.
        while (s.regs[reg.scbnext] & 0xFF00 != 0) {
            if (ticks >= tick_cost.run_cap) break;
            const scb = s.regs[reg.scbnext];
            s.regs[reg.scbadr] = scb;
            s.sprctl0 = ram[scb];
            s.sprctl1 = ram[scb +% 1];
            s.sprcoll = ram[scb +% 2];
            s.regs[reg.scbnext] = rd16(ram, scb +% 3);
            var p: u16 = scb +% 5;
            if (s.sprctl1 & 0x04 != 0) {
                s.regs[reg.tmpadr] = p;
                ticks += tick_cost.skipped_sprite;
                continue;
            }
            s.regs[reg.sprdline] = rd16(ram, p);
            s.regs[reg.hposstrt] = rd16(ram, p +% 2);
            s.regs[reg.vposstrt] = rd16(ram, p +% 4);
            p +%= 6;
            const depth = (s.sprctl1 >> 4) & 3;
            if (depth >= 1) {
                s.regs[reg.sprhsiz] = rd16(ram, p);
                s.regs[reg.sprvsiz] = rd16(ram, p +% 2);
                p +%= 4;
            }
            if (depth >= 2) {
                s.regs[reg.stretch] = rd16(ram, p);
                p +%= 2;
            }
            if (depth >= 3) {
                s.regs[reg.tilt] = rd16(ram, p);
                p +%= 2;
            }
            if (s.sprctl1 & 0x08 == 0) {
                for (0..8) |k| {
                    const b = ram[p +% @as(u16, @intCast(k))];
                    s.pen_map[2 * k] = b >> 4;
                    s.pen_map[2 * k + 1] = b & 0x0F;
                }
                p +%= 8;
            }
            s.regs[reg.tmpadr] = p;
            ticks += tick_cost.sprite_header;
            ticks += s.draw_sprite(ram, tick_cost.run_cap -| ticks);
        }
        s.sprgo &= ~@as(u8, 1);
        return ticks;
    }

    /// Paint the sprite whose SCB is loaded; returns its data/pixel ticks.
    fn draw_sprite(s: *Suzy, ram: *[0x10000]u8, budget: u32) u32 {
        const kind: u3 = @truncate(s.sprctl0);
        const no_collide = s.sprsys & 0x20 != 0 or s.sprcoll & 0x20 != 0;
        var d: Draw = .{
            .ram = ram,
            .vidbas = s.regs[reg.vidbas],
            .collbas = s.regs[reg.collbas],
            .bpp = @as(u5, @intCast(s.sprctl0 >> 6)) + 1,
            .literal = s.sprctl1 & 0x80 != 0,
            .xor = kind == 6,
            .deposit = !no_collide and deposit_types & (@as(u8, 1) << kind) != 0,
            .coll_num = s.sprcoll & 0x0F,
        };
        for (0..16) |k| {
            const pen = s.pen_map[k];
            d.pen_flags[k] = pen_flags(kind, pen, no_collide) | (pen << 4);
        }

        const hflip = s.sprctl0 & 0x20 != 0;
        const vflip = s.sprctl0 & 0x10 != 0;
        const depth = (s.sprctl1 >> 4) & 3;
        const stretch: u16 = if (depth >= 2) s.regs[reg.stretch] else 0;
        const tilt: u16 = if (depth >= 3) s.regs[reg.tilt] else 0;
        const vstretch = s.sprsys & 0x10 != 0 and depth >= 2;
        const hoff = s.regs[reg.hoff];
        const voff = s.regs[reg.voff];
        const hsizoff = s.regs[reg.hsizoff];
        const vsizoff = s.regs[reg.vsizoff];

        var sprdline = s.regs[reg.sprdline];
        var hposstrt = s.regs[reg.hposstrt];
        var hsiz = s.regs[reg.sprhsiz];
        var vsiz = s.regs[reg.sprvsiz];
        var tiltacum: u16 = 0;
        var vsizacum: u16 = 0;
        var vpos: u16 = 0;
        var off: u8 = 0;

        const q_start: u2 = @truncate(s.sprctl1);
        const pos0 = quad_pos[q_start];
        var qi: u3 = 0;
        quads: while (qi < 4) : (qi += 1) {
            const q = quad_cycle[pos0 +% @as(u2, @truncate(qi))];
            const left = (q & 1 != 0) != hflip;
            const up = (q & 2 != 0) != vflip;
            const dx: i32 = if (left) -1 else 1;
            const dy: u16 = if (up) 0xFFFF else 1;
            tiltacum = 0;
            // The size offsets follow the quadrant, not the flips: an
            // H-flipped SE sprite still starts at HSIZOFF (lynx-tests
            // sprites2 ALPINE FLIP, Alpine Games' protection check).
            vsizacum = if (q & 2 != 0) 0 else vsizoff;
            vpos = s.regs[reg.vposstrt] -% voff;
            // Quadrants drawing the other way from the first start one
            // pixel further out, so the halves do not overlap.
            if ((q ^ q_start) & 2 != 0) vpos +%= dy;
            const hadj: i32 = if ((q ^ q_start) & 1 != 0) dx else 0;
            const acc0: u32 = if (q & 1 != 0) 0 else hsizoff;

            while (true) {
                if (d.ticks() >= budget) {
                    off = 0;
                    break :quads;
                }
                vsizacum +%= vsiz;
                const height = vsizacum >> 8;
                vsizacum &= 0xFF;
                off = ram[sprdline];
                d.bytes += 1;
                if (off == 0) break :quads;
                sprdline +%= 1;
                var r: u16 = 0;
                while (r < height) : (r += 1) {
                    const y: i32 = @as(i16, @bitCast(vpos));
                    if (if (up) y < 0 else y >= screen_height) break;
                    hposstrt +%= @as(u16, @bitCast(@as(i16, @as(i8, @bitCast(@as(u8, @truncate(tiltacum >> 8)))))));
                    tiltacum &= 0xFF;
                    if (y >= 0 and y < screen_height) {
                        const yo: u16 = @intCast(y);
                        const x: i32 = @as(i32, @as(i16, @bitCast(hposstrt -% hoff))) + hadj;
                        d.draw_row(sprdline, off - 1, yo, x, dx, acc0, hsiz);
                    }
                    vpos +%= dy;
                    hsiz +%= stretch;
                    tiltacum +%= tilt;
                }
                if (off == 1) break; // next quadrant
                sprdline +%= off - 1;
                if (vstretch) vsiz +%= stretch *% height;
            }
        }

        s.regs[reg.sprdline] = sprdline;
        s.regs[reg.hposstrt] = hposstrt;
        s.regs[reg.sprhsiz] = hsiz;
        s.regs[reg.sprvsiz] = vsiz;
        s.regs[reg.tiltacum] = tiltacum;
        s.regs[reg.vsizacum] = vsizacum;
        s.regs[reg.sprvpos] = vpos;
        s.regs[reg.sprdoff] = off;
        s.regs[reg.vidadr] = d.last_vline;
        s.regs[reg.colladr] = d.last_cline;
        s.regs[reg.procadr] = sprdline;

        const everon = s.sprgo & 0x04 != 0;
        if (d.deposit or everon) {
            var v: u8 = if (d.deposit) d.fred else 0;
            if (everon and !d.on_screen) v |= 0x80;
            ram[s.regs[reg.scbadr] +% s.regs[reg.colloff]] = v;
        }
        s.pixels_drawn +%= d.pixels;
        return d.ticks();
    }
};

/// Sprite types that read the collision buffer and write the depository:
/// 2 boundary-shadow, 3 boundary, 4 normal, 6 xor-shadow, 7 shadow.
const deposit_types: u8 = 0b1101_1100;

/// What pen number `pen` does in a sprite of type `kind` (Epyx sprite
/// chapter's table, with the shadow-inverter error folded in): opaque =
/// written to the video buffer, collide = its collision number written to
/// the collision buffer (and, for the depository types, the old value read).
fn pen_flags(kind: u3, pen: u8, no_collide: bool) u8 {
    const is_opaque = switch (kind) {
        0, 1 => true, // background: every pen, 0 and F included
        2, 3 => pen != 0 and pen != 0xF, // boundary: F transparent
        else => pen != 0,
    };
    const collide = !no_collide and switch (kind) {
        0 => pen != 0xE, // background-shadow: writes, E does not
        1, 5 => false,
        2, 6, 7 => pen != 0 and pen != 0xE, // shadow: E does not collide
        3, 4 => pen != 0,
    };
    return (if (is_opaque) flag_opaque else 0) | (if (collide) flag_collide else 0);
}

fn rd16(ram: *const [0x10000]u8, a: u16) u16 {
    return @as(u16, ram[a]) | (@as(u16, ram[a +% 1]) << 8);
}

/// One sprite's drawing state.
const Draw = struct {
    ram: *[0x10000]u8,
    vidbas: u16,
    collbas: u16,
    bpp: u5,
    literal: bool,
    xor: bool,
    deposit: bool,
    coll_num: u8,
    /// Pen index -> pen number << 4 | flags (the palette folded in).
    pen_flags: [16]u8 = @splat(0),
    fred: u8 = 0,
    on_screen: bool = false,
    last_vline: u16 = 0,
    last_cline: u16 = 0,
    bytes: u32 = 0,
    pixels: u32 = 0,
    coll: u32 = 0,

    fn ticks(d: *const Draw) u32 {
        return d.bytes * tick_cost.byte_read + d.pixels * tick_cost.pixel_write +
            d.coll * tick_cost.coll_access;
    }

    /// Decode one source line (`nbytes` data bytes at `data`) into one
    /// destination row `y`, starting at screen column `x` and stepping `dx`.
    fn draw_row(d: *Draw, data: u16, nbytes: u8, y: u16, x_start: i32, dx: i32, acc0: u32, hsiz: u16) void {
        const vline = d.vidbas +% y *% line_bytes;
        const cline = d.collbas +% y *% line_bytes;
        d.last_vline = vline;
        d.last_cline = cline;
        d.bytes += nbytes;

        const ram = d.ram;
        const bpp = d.bpp;
        const pen_mask: u32 = (@as(u32, 1) << bpp) - 1;
        // Bit reader, MSB first. `left` is the bits still in the line; a
        // field is only taken while strictly more bits than its width
        // remain (the hardware cannot use bit 0 of the line's last byte:
        // the Epyx pad-byte bug, as Felix models it).
        var left: u32 = @as(u32, nbytes) * 8;
        var src: u16 = data;
        var buf: u32 = 0;
        var have: u5 = 0;
        var x = x_start;
        var acc = acc0;
        const h: u32 = hsiz;

        var lit_left: u32 = 0; // pens still to read in a literal packet
        while (true) {
            var n: u32 = 1;
            var pen_index: u32 = undefined;
            if (d.literal) {
                if (left <= bpp) return;
                while (have < bpp) : (have += 8) {
                    buf = (buf << 8) | ram[src];
                    src +%= 1;
                }
                have -= bpp;
                left -= bpp;
                pen_index = (buf >> have) & pen_mask;
            } else if (lit_left > 0) {
                if (left <= bpp) return;
                while (have < bpp) : (have += 8) {
                    buf = (buf << 8) | ram[src];
                    src +%= 1;
                }
                have -= bpp;
                left -= bpp;
                pen_index = (buf >> have) & pen_mask;
                lit_left -= 1;
            } else {
                if (left <= 5) return;
                while (have < 5) : (have += 8) {
                    buf = (buf << 8) | ram[src];
                    src +%= 1;
                }
                have -= 5;
                left -= 5;
                const hdr = (buf >> have) & 0x1F;
                const count = hdr & 0x0F;
                if (hdr & 0x10 != 0) {
                    lit_left = count + 1;
                    continue;
                }
                if (count == 0) return; // header 00000: end of line
                if (left <= bpp) return;
                while (have < bpp) : (have += 8) {
                    buf = (buf << 8) | ram[src];
                    src +%= 1;
                }
                have -= bpp;
                left -= bpp;
                pen_index = (buf >> have) & pen_mask;
                n = count + 1;
            }

            // n source pixels of one pen: their total width telescopes.
            const sum = acc + n * h;
            const w: i32 = @intCast(sum >> 8);
            acc = sum & 0xFF;
            if (w == 0) continue;
            var a: i32 = undefined;
            var b: i32 = undefined;
            if (dx > 0) {
                a = x;
                b = x + w;
                x = b;
            } else {
                b = x + 1;
                a = b - w;
                x = a - 1;
            }
            if (a < 0) a = 0;
            if (b > screen_width) b = screen_width;
            if (a < b) {
                d.on_screen = true;
                d.fill(vline, cline, @intCast(a), @intCast(b), @intCast(pen_index));
            }
            if (if (dx > 0) x >= screen_width else x < 0) return;
        }
    }

    /// Pixels a..b-1 of the row with one pen index: video then collision.
    fn fill(d: *Draw, vline: u16, cline: u16, a: u16, b: u16, pen_index: u8) void {
        const f = d.pen_flags[pen_index];
        if (f & (flag_opaque | flag_collide) == 0) return;
        const n: u32 = b - a;
        if (f & flag_opaque != 0) {
            const pen = f >> 4;
            if (d.xor) xor_nibbles(d.ram, vline, a, b, pen) else set_nibbles(d.ram, vline, a, b, pen);
            d.pixels += n;
        }
        if (f & flag_collide != 0) {
            const old = max_set_nibbles(d.ram, cline, a, b, d.coll_num);
            if (d.deposit and old > d.fred) d.fred = old;
            d.coll += n;
        }
    }
};

/// Pixels a..b-1 (a < b) of the line at `base` set to `v` (0..15).
fn set_nibbles(ram: *[0x10000]u8, base: u16, a: u16, b: u16, v: u8) void {
    var x = a;
    if (x & 1 != 0) {
        const p = base +% (x >> 1);
        ram[p] = (ram[p] & 0xF0) | v;
        x += 1;
    }
    const both = v * 0x11;
    while (x + 1 < b) : (x += 2) ram[base +% (x >> 1)] = both;
    if (x < b) {
        const p = base +% (x >> 1);
        ram[p] = (ram[p] & 0x0F) | (v << 4);
    }
}

fn xor_nibbles(ram: *[0x10000]u8, base: u16, a: u16, b: u16, v: u8) void {
    var x = a;
    if (x & 1 != 0) {
        ram[base +% (x >> 1)] ^= v;
        x += 1;
    }
    const both = v * 0x11;
    while (x + 1 < b) : (x += 2) ram[base +% (x >> 1)] ^= both;
    if (x < b) ram[base +% (x >> 1)] ^= v << 4;
}

/// Like `set_nibbles`, returning the largest nibble it overwrote.
fn max_set_nibbles(ram: *[0x10000]u8, base: u16, a: u16, b: u16, v: u8) u8 {
    var m: u8 = 0;
    var x = a;
    if (x & 1 != 0) {
        const p = base +% (x >> 1);
        m = @max(m, ram[p] & 0x0F);
        ram[p] = (ram[p] & 0xF0) | v;
        x += 1;
    }
    const both = v * 0x11;
    while (x + 1 < b) : (x += 2) {
        const p = base +% (x >> 1);
        const o = ram[p];
        m = @max(m, @max(o >> 4, o & 0x0F));
        ram[p] = both;
    }
    if (x < b) {
        const p = base +% (x >> 1);
        m = @max(m, ram[p] >> 4);
        ram[p] = (ram[p] & 0x0F) | (v << 4);
    }
    return m;
}
