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
//! - `write_at(addr, v, now)` / `read_at(addr, now)` (or the untimed
//!   `write` / `read`) for every Suzy address except $B0-$B3 (JOYSTICK,
//!   SWITCHES, RCART0, RCART1), which the bus serves itself from the pad
//!   word and the cart port; the bus calls `lefthand()` to swap the
//!   joystick direction bits (SPRSYS bit 3). Math results are written
//!   inside the write that starts them (MATHA a multiply, MATHE a divide);
//!   with the bus tick `now`, SPRSYS bit 7 reads busy for the documented
//!   duration, without it never.
//! - Sprites draw when the CPU sleeps: SPRGO ($91) bit 0 only latches the
//!   request; the bus calls `run_sprites(ram)` on the CPUSLEEP write
//!   (Mikey $FD91) while `sprites_pending()`, which walks the whole list at
//!   once, writes the video and collision buffers and the depository bytes
//!   into `ram`, clears the request and returns the 16 MHz ticks the CPU is
//!   charged (SPEC.md section 4: a per-row model fitted to lynx-tests
//!   hardware timings; docs/SUZY.md "Tick model"). Everything Suzy touches is in
//!   the 64 KB `ram`; it never sees the overlays.
//! - `pixels_drawn` counts pixels written since reset (the overlay's
//!   "Suzy pixels per frame"; the frontend differences it).
//! - `run_sprites` writes RAM directly: before each video span, each
//!   collision span and the depository byte it tells the scrubber
//!   (`undo.touch_short` / `undo.touch`, core/undo.zig), never per pixel.
//!
//! Register map ($FC00 + addr; Epyx hardware appendix, SPEC.md section 20):
//! $00-$2F the sprite engine's 16-bit registers, even address = low byte,
//! a CPU write to a low byte zeroes the high byte (TMPADR, TILTACUM, HOFF,
//! VOFF, VIDBAS, COLLBAS, VIDADR, COLLADR, SCBNEXT $10, SPRDLINE, HPOSSTRT,
//! VPOSSTRT, SPRHSIZ, SPRVSIZ, STRETCH, TILT, SPRDOFF, SPRVPOS, COLLOFF,
//! VSIZACUM, HSIZOFF $28, VSIZOFF, SCBADR, PROCADR), $40-$6F the same 48
//! bytes again, where the math unit's ports are (MATHD..MATHA $52-$55,
//! MATHP/N $56-$57, MATHH..MATHE $60-$63, MATHM..MATHJ $6C-$6F), $80 SPRCTL0, $81 SPRCTL1, $82 SPRCOLL, $83 SPRINIT, $88
//! SUZYHREV, $89 SUZYSREV, $90 SUZYBUSEN, $91 SPRGO, $92 SPRSYS, $B0
//! JOYSTICK, $B1 SWITCHES, $B2 RCART0, $B3 RCART1, $C0-$C3 LEDs/parallel
//! (ignored).

const std = @import("std");
const undo = @import("undo.zig");

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

/// The engine's time model (docs/SUZY.md "Tick model"), fitted to the
/// drhelius lynx-tests sprites1-5 timings measured on a Lynx I (each
/// within its 16 us window). Per-sprite costs are in ticks; per-row and
/// per-line costs are in 1/64 tick (`unit`), summed per sprite and
/// rounded once.
pub const tick_cost = struct {
    /// SCB fetch: the five-byte header and the source pointer/position.
    pub const sprite_header: u32 = 64;
    /// The H/V size reload block (reload depth >= 1).
    pub const reload_sizes: u32 = 8;
    /// The eight palette bytes (SPRCTL1 bit 3 clear).
    pub const reload_palette: u32 = 8;
    /// The first sprite of a run, or the first after a skipped one.
    pub const cold_start: u32 = 27;
    /// A skipped sprite (SPRCTL1 bit 2): five SCB bytes.
    pub const skipped_sprite: u32 = 25;

    pub const unit: u32 = 64;
    /// A drawn row that stopped at the screen edge (the base all rows pay).
    pub const row_base: u32 = 4198; // 65.6
    /// A row that ran out of source data instead: the row tail.
    pub const row_tail_1bpp: u32 = 237; // 3.7
    pub const row_tail: u32 = 442; // 6.9
    /// A 1 bpp row that ran out of data in a half-written byte.
    pub const row_tail_partial_1bpp: u32 = 384; // 6
    /// Each pixel position generated, or source pen decoded, whichever
    /// is more (one pipeline does both).
    pub const per_output: u32 = 125; // 1.953
    /// Totally literal rows are also bus bound: outputs x this cost (in
    /// 1/1024 tick) by source bits per output, 0..4, interpolated.
    pub const literal_bus = [5]u32{ 2462, 2462, 2518, 2692, 3012 }; // 2.40 .. 2.94
    /// Packed rows: each packet header (the end-of-line one too), less a
    /// constant, and each pen of a literal packet.
    pub const packet: u32 = 275; // 4.3
    pub const packed_row_credit: u32 = 506; // 7.9
    pub const packed_literal_pen: u32 = 16; // 0.25
    /// Collision: any collision access in the row, each 8-pixel screen
    /// group only written or only read (pen E of the shadow types), each
    /// group read, compared and written (the depository types).
    pub const coll_row: u32 = 1248; // 19.5
    pub const coll_group_light: u32 = 106; // 1.65
    pub const coll_group_detect: u32 = 640; // 10
    /// Each video byte XORed (after the rest of the row).
    pub const xor_byte: u32 = 128; // 2
    /// Each drawn row of a sprite with stretch (reload depth >= 2) and
    /// with tilt (depth 3).
    pub const row_stretch: u32 = 512; // 8
    pub const row_tilt: u32 = 1152; // 18
    /// A source line that generates no rows (downscaled away).
    pub const line_no_rows: u32 = 1280; // 20
    /// The rows of a line rejected past the screen edge (once per line).
    pub const row_reject: u32 = 1280; // 20
    /// A row that cannot reach the screen (super clipping: it starts off
    /// screen drawing away from it), or one off screen moving towards it.
    pub const row_clipped: u32 = 2925; // 45.7

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
/// Pen E of the shadow types: collision read but kept (timing only).
const flag_preserve: u8 = 4;

/// Test knob: false decodes every row (no replay of the previous row's
/// spans, `Draw.row`); the result must be the same either way.
pub var replay_rows: bool = true;

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
    math_done: u32 = 0,
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
        return s.read_at(a, std.math.maxInt(u32));
    }

    /// A register read at bus tick `now` (SPRSYS bit 7 shows a math
    /// operation still running).
    pub fn read_at(s: *const Suzy, a: u8, now: u32) u8 {
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

    fn sprsys_read(s: *const Suzy, now: u32) u8 {
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
    pub fn write_at(s: *Suzy, a: u8, v: u8, now: u32) void {
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

    /// The bus clock moved back by `d` (core/lynx.zig `rebase`).
    pub fn rebase(s: *Suzy, d: u32) void {
        s.math_done -|= d;
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
    fn math_command(s: *Suzy, a: u8, now: u32) void {
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

    fn math_started(s: *Suzy, now: u32, ticks: u32) void {
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
        // The first sprite of a run (and the first after a skipped SCB)
        // starts with an empty pipeline.
        var warm = false;
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
                warm = false;
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
            if (depth >= 1) ticks += tick_cost.reload_sizes;
            if (s.sprctl1 & 0x08 == 0) ticks += tick_cost.reload_palette;
            if (!warm) ticks += tick_cost.cold_start;
            warm = true;
            ticks += s.draw_sprite(ram, tick_cost.run_cap -| ticks);
        }
        s.sprgo &= ~@as(u8, 1);
        return ticks;
    }

    /// Paint the sprite whose SCB is loaded; returns its data/pixel ticks.
    noinline fn draw_sprite(s: *Suzy, ram: *[0x10000]u8, budget: u32) u32 {
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
            .track_vid = kind == 6,
        };
        var any: u8 = 0;
        for (0..16) |k| {
            const pen = s.pen_map[k];
            const f = pen_flags(kind, pen, no_collide);
            d.pen_flags[k] = f | (pen << 4);
            any |= f;
        }
        d.writes_vid = any & flag_opaque != 0;
        d.writes_col = any & flag_collide != 0;
        d.track_col = any & (flag_collide | flag_preserve) != 0;
        d.simple = !d.xor and !d.track_vid and !d.track_col;

        const hflip = s.sprctl0 & 0x20 != 0;
        const vflip = s.sprctl0 & 0x10 != 0;
        const depth = (s.sprctl1 >> 4) & 3;
        const stretch: u16 = if (depth >= 2) s.regs[reg.stretch] else 0;
        const tilt: u16 = if (depth >= 3) s.regs[reg.tilt] else 0;
        const vstretch = s.sprsys & 0x10 != 0 and depth >= 2;
        const transform: u32 = (if (depth >= 2) tick_cost.row_stretch else 0) +
            (if (depth >= 3) tick_cost.row_tilt else 0);
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
                if (d.ticks >= budget * tick_cost.unit) {
                    off = 0;
                    break :quads;
                }
                vsizacum +%= vsiz;
                const height = vsizacum >> 8;
                vsizacum &= 0xFF;
                off = ram[sprdline];
                if (off == 0) break :quads;
                if (height == 0 and off > 1) d.ticks += tick_cost.line_no_rows;
                sprdline +%= 1;
                var r: u16 = 0;
                while (r < height) : (r += 1) {
                    const y: i32 = @as(i16, @bitCast(vpos));
                    if (if (up) y < 0 else y >= screen_height) {
                        // Off the screen edge in the drawing direction:
                        // the rest of this line's rows are rejected.
                        d.ticks += tick_cost.row_reject;
                        break;
                    }
                    hposstrt +%= @as(u16, @bitCast(@as(i16, @as(i8, @bitCast(@as(u8, @truncate(tiltacum >> 8)))))));
                    tiltacum &= 0xFF;
                    if (y >= 0 and y < screen_height) {
                        const yo: u16 = @intCast(y);
                        const x: i32 = @as(i32, @as(i16, @bitCast(hposstrt -% hoff))) + hadj;
                        d.ticks += d.row(sprdline, off - 1, yo, x, dx, acc0, hsiz) + transform;
                    } else {
                        // A row before the screen, moving towards it.
                        d.ticks += tick_cost.row_clipped;
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
            const dep = s.regs[reg.scbadr] +% s.regs[reg.colloff];
            undo.touch(dep);
            ram[dep] = v;
        }
        s.pixels_drawn +%= d.pixels;
        return (d.ticks + tick_cost.unit / 2) / tick_cost.unit;
    }
};

/// The cost of one drawn destination row in `tick_cost.unit`s: the
/// slowest of the output pipeline and (totally literal rows) the bus,
/// then collision, XOR and the row tail on top. `d`'s unit counts must be
/// flushed.
inline fn row_ticks(d: *const Draw, rs: RowStats) u32 {
    const c = tick_cost;
    const bpp = d.bpp;
    var t: u32 = c.row_base + c.per_output * @max(rs.pens, rs.outs);
    if (!rs.edge_stop) {
        t += if (bpp == 1) c.row_tail_1bpp else c.row_tail;
        if (bpp == 1 and rs.last_part) t += c.row_tail_partial_1bpp;
    }
    if (d.literal) {
        if (rs.outs > 0) {
            // Source bits per output in 1/64: the bus cost per output.
            const bpo = @min((rs.bits * 64) / rs.outs, 4 * 64);
            const i = bpo >> 6;
            const f = bpo & 63;
            const g = if (i >= 4) c.literal_bus[4] * 64 else c.literal_bus[i] * (64 - f) + c.literal_bus[i + 1] * f;
            t = @max(t, (rs.outs * g) >> 10);
        }
    } else {
        t = (t + c.packet * rs.packets + c.packed_literal_pen * rs.lit_pens) -| c.packed_row_credit;
    }
    const light: u32 = d.col.other;
    const detect: u32 = d.col.hit;
    if (light + detect != 0) t += c.coll_row + c.coll_group_light * light + c.coll_group_detect * detect;
    const xor: u32 = d.vid.hit;
    return t + c.xor_byte * xor;
}

/// Sprite types that read the collision buffer and write the depository:
/// 2 boundary-shadow, 3 boundary, 4 normal, 6 xor-shadow, 7 shadow.
const deposit_types: u8 = 0b1101_1100;
/// Types whose pen E keeps the collision buffer: 0, 2, 6, 7.
const shadow_types: u8 = 0b1100_0101;

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
    const preserve = !no_collide and pen == 0xE and shadow_types & (@as(u8, 1) << kind) != 0;
    return (if (is_opaque) flag_opaque else 0) | (if (collide) flag_collide else 0) |
        (if (preserve) flag_preserve else 0);
}

fn rd16(ram: *const [0x10000]u8, a: u16) u16 {
    return @as(u16, ram[a]) | (@as(u16, ram[a +% 1]) << 8);
}

/// Units of the row a span touches, classified by what touched them: video
/// bytes (two pixels) or collision groups (eight pixels, screen aligned).
/// Spans arrive in drawing order and abut, so only the unit shared with
/// the previous span is pending; the others are counted at once. The tick
/// model only needs two counts per row: the units whose class mask has
/// bit `key` (`hit`) and the others (`other`); and for video bytes whether
/// the last one was partly covered.
fn Units(comptime shift: u5, comptime key: u8) type {
    return struct {
        const Self = @This();
        cur: i32 = no_unit,
        mask: u8 = 0,
        cov: u8 = 0,
        hit: u16 = 0,
        other: u16 = 0,
        /// The last unit flushed was partly covered.
        last_part: bool = false,

        const no_unit: i32 = std.math.minInt(i32);

        inline fn clear(u: *Self) void {
            u.cur = no_unit;
            u.hit = 0;
            u.other = 0;
            u.last_part = false;
        }

        inline fn count(u: *Self, m: u8, n: u16) void {
            if (m & key != 0) u.hit += n else u.other += n;
        }

        inline fn merge(u: *Self, unit: i32, m: u8, n: i32) void {
            if (unit != u.cur) {
                u.flush();
                u.cur = unit;
                u.mask = m;
                u.cov = @intCast(n);
            } else {
                u.mask |= m;
                u.cov += @intCast(n);
            }
        }

        fn flush(u: *Self) void {
            if (u.cur == no_unit) return;
            u.last_part = u.cov < (@as(u8, 1) << shift);
            u.count(u.mask, 1);
            u.cur = no_unit;
        }

        /// Pixels a..b-1 (a < b) with class bit(s) `m`, drawn rightwards or not.
        fn add(u: *Self, a: i32, b: i32, m: u8, right: bool) void {
            const lo = a >> shift;
            const hi = (b - 1) >> shift;
            if (lo == hi) return u.merge(lo, m, b - a);
            const n_lo = ((lo + 1) << shift) - a;
            const n_hi = b - (hi << shift);
            if (right) {
                u.merge(lo, m, n_lo);
                u.merge(hi, m, n_hi);
            } else {
                u.merge(hi, m, n_hi);
                u.merge(lo, m, n_lo);
            }
            u.count(m, @intCast(hi - lo - 1));
        }
    };
}

/// What one destination row asked of the engine (the tick model's input):
/// `draw_row`'s locals. The video and collision unit counts are `Draw`'s
/// (`vid`, `col`), tracked only for sprites whose cost reads them.
const RowStats = struct {
    /// Source pens decoded, output positions generated (including the one
    /// past the screen edge that stops the row) and packet headers read.
    pens: u32 = 0,
    outs: u32 = 0,
    packets: u32 = 0,
    /// Source bits consumed.
    bits: u32 = 0,
    /// Pens read in literal packets (packed rows).
    lit_pens: u32 = 0,
    /// The row stopped at the screen edge (else it ran out of data).
    edge_stop: bool = false,
    /// The last video byte the row reached is only partly covered (the
    /// 1 bpp row tail).
    last_part: bool = false,
};

const vid_write: u8 = 1;
const vid_read: u8 = 2;
const vid_xor: u8 = 4;
const col_write: u8 = 1;
const col_detect: u8 = 2;
const col_preserve: u8 = 4;

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
    /// The tick model counts the row's XORed video bytes (XOR sprites):
    /// track video bytes per span. (The 1 bpp partial-byte tail only
    /// needs the row's covered extent, `draw_row`.)
    track_vid: bool,
    /// Some pen index writes or reads the collision buffer (collide or
    /// preserve): the tick model counts collision groups per span.
    track_col: bool = false,
    /// Neither XOR nor `track_vid` nor `track_col`: spans only write
    /// video (`draw_row`'s simple copy).
    simple: bool = false,
    /// Some pen index writes the video buffer / the collision buffer: a
    /// row whose line of that buffer holds the source bytes is decoded,
    /// not replayed (`row`).
    writes_vid: bool = false,
    writes_col: bool = false,
    /// Pen index -> pen number << 4 | flags (the palette folded in).
    pen_flags: [16]u8 = @splat(0),
    fred: u8 = 0,
    on_screen: bool = false,
    last_vline: u16 = 0,
    last_cline: u16 = 0,
    pixels: u32 = 0,
    /// Ticks charged so far for this sprite.
    ticks: u32 = 0,
    /// Video bytes: bit 0 written, bit 1 read (transparent), bit 2 XOR;
    /// `hit` counts the XORed ones. Only tracked when the tick model needs
    /// it (`track_vid`).
    vid: Units(1, vid_xor) = .{},
    /// Collision groups: bit 0 written, bit 1 read and written (the
    /// depository types), bit 2 read only (pen E of the shadow types);
    /// `hit` counts the detecting ones, `other` the light ones (only with
    /// `track_col`; otherwise both stay 0, as nothing would be counted).
    col: Units(3, col_detect) = .{},

    /// The last decoded row, for the next row of the same source line
    /// (`row`): its inputs, its spans and its cost. `cache_ok` is cleared
    /// when a row's writes may have changed the source bytes.
    cache_ok: bool = false,
    c_data: u16 = 0,
    c_nbytes: u8 = 0,
    c_hsiz: u16 = 0,
    c_x: i32 = 0,
    c_dx: i32 = 0,
    c_acc: u32 = 0,
    c_cost: u32 = 0,
    n_spans: u32 = 0,
    spans: [screen_width]Span = undefined,

    const Span = struct { a: u8, b: u8, pen_index: u8 };

    /// One destination row from a source line (`draw_row`), returning its
    /// cost in `tick_cost.unit`s. A row with the same inputs as the last
    /// decoded one (the next row of a source line drawn taller than one
    /// row, unless stretch or tilt change it) decodes to the same spans
    /// and the same statistics, so those are replayed onto the new line
    /// instead: the result in RAM and the ticks are the same as decoding
    /// it again, as long as the source bytes are unchanged. A row is not
    /// replayed when a line it writes (video or collision) holds source
    /// bytes (the decode would read what it has just written), and the
    /// cache is dropped after a row that wrote over them. (A sprite that
    /// never writes a buffer cannot change the source through it, so only
    /// the buffers it writes are tested.)
    inline fn row(d: *Draw, data: u16, nbytes: u8, y: u16, x_start: i32, dx: i32, acc0: u32, hsiz: u16) u32 {
        const vline = d.vidbas +% y *% line_bytes;
        const cline = d.collbas +% y *% line_bytes;
        d.last_vline = vline;
        d.last_cline = cline;
        const hits_source = (d.writes_vid and overlaps(data, nbytes, vline, line_bytes)) or
            (d.writes_col and overlaps(data, nbytes, cline, line_bytes));
        if (replay_rows and d.cache_ok and !hits_source and data == d.c_data and nbytes == d.c_nbytes and
            x_start == d.c_x and dx == d.c_dx and acc0 == d.c_acc and hsiz == d.c_hsiz)
        {
            for (d.spans[0..d.n_spans]) |sp| _ = d.fill_pixels(vline, cline, sp.a, sp.b, sp.pen_index);
            return d.c_cost;
        }
        // A copy of the decoder for sprites that write video only (no XOR,
        // nothing for the unit counters): raycast's and Hard Drivin's.
        const cost = if (d.simple)
            d.draw_row(true, data, nbytes, vline, cline, x_start, dx, acc0, hsiz)
        else
            d.draw_row(false, data, nbytes, vline, cline, x_start, dx, acc0, hsiz);
        d.c_data = data;
        d.c_nbytes = nbytes;
        d.c_x = x_start;
        d.c_dx = dx;
        d.c_acc = acc0;
        d.c_hsiz = hsiz;
        d.c_cost = cost;
        d.cache_ok = !(hits_source and d.n_spans != 0);
        return cost;
    }

    /// Decode one source line (`nbytes` data bytes at `data`) into the
    /// destination row whose lines start at `vline`/`cline`, starting at
    /// screen column `x_start` and stepping `dx`; the spans go to `spans`
    /// and the cost (`row_ticks`) is returned. Out of line: the sprite
    /// loop stays small and this keeps its state in registers.
    inline fn draw_row(d: *Draw, comptime simple: bool, data: u16, nbytes: u8, vline: u16, cline: u16, x_start: i32, dx: i32, acc0: u32, hsiz: u16) u32 {
        d.n_spans = 0;
        const right = dx > 0;
        // Super clipping: a row starting off screen and drawing away from
        // it is rejected without decoding.
        if (if (right) x_start >= screen_width else x_start < 0) return tick_cost.row_clipped;
        if (d.track_vid) d.vid.clear();
        if (d.track_col) d.col.clear();

        var rs: RowStats = .{};
        const ram = d.ram;
        const bpp = d.bpp;
        const literal = d.literal;
        const pen_mask: u32 = (@as(u32, 1) << bpp) - 1;
        // Bit reader, MSB first. `left` is the bits still in the line; a
        // field is only taken while strictly more bits than its width
        // remain (the hardware cannot use bit 0 of the line's last byte:
        // the Epyx pad-byte bug, as Felix models it).
        const total: u32 = @as(u32, nbytes) * 8;
        var left: u32 = total;
        var src: u16 = data;
        var buf: u32 = 0;
        var have: u5 = 0;
        var x = x_start;
        var acc = acc0;
        const h: u32 = hsiz;

        // The row's covered pixels are contiguous: from the first span's
        // start edge to the last span's far edge (`first`, `last`: a for
        // rightward rows, b for leftward ones the other way round).
        var first: i32 = -1;
        var last: i32 = -1;
        var lit_left: u32 = 0; // pens still to read in a literal packet
        decode: while (true) {
            var n: u32 = 1;
            if (!literal and lit_left == 0) {
                if (left <= 5) break :decode;
                while (have < 5) : (have += 8) {
                    buf = (buf << 8) | ram[src];
                    src +%= 1;
                }
                have -= 5;
                left -= 5;
                rs.packets += 1;
                const hdr = (buf >> have) & 0x1F;
                const count = hdr & 0x0F;
                if (hdr & 0x10 != 0) {
                    lit_left = count + 1;
                    continue;
                }
                if (count == 0) break :decode; // header 00000: end of line
                n = count + 1;
            }
            if (left <= bpp) break :decode;
            while (have < bpp) : (have += 8) {
                buf = (buf << 8) | ram[src];
                src +%= 1;
            }
            have -= bpp;
            left -= bpp;
            const pen_index = (buf >> have) & pen_mask;
            if (!literal and n == 1) {
                lit_left -= 1;
                rs.lit_pens += 1;
            }
            rs.pens += n;

            // n source pixels of one pen: their total width telescopes.
            const sum = acc + n * h;
            const w: i32 = @intCast(sum >> 8);
            acc = sum & 0xFF;
            if (w == 0) continue;
            var a: i32 = undefined;
            var b: i32 = undefined;
            if (right) {
                a = x;
                b = x + w;
                x = b;
            } else {
                b = x + 1;
                a = b - w;
                x = a - 1;
            }
            const out_a = a;
            const out_b = b;
            if (a < 0) a = 0;
            if (b > screen_width) b = screen_width;
            if (a < b) {
                d.on_screen = true;
                d.fill(simple, vline, cline, @intCast(a), @intCast(b), @intCast(pen_index), right);
                if (first < 0) first = if (right) a else b;
                last = if (right) b else a;
            }
            if (if (right) x >= screen_width else x < 0) {
                // Generation stops at the first output past the edge.
                rs.outs += @intCast(@max(1, if (right) screen_width + 1 - @max(out_a, 0) else @min(out_b, screen_width) + 1));
                rs.edge_stop = true;
                break :decode;
            }
            rs.outs += @intCast(w);
        }
        rs.bits = total - left;
        if (d.track_vid) d.vid.flush();
        if (d.track_col) d.col.flush();
        if (bpp == 1 and !rs.edge_stop and last >= 0) {
            if (d.track_vid) {
                rs.last_part = d.vid.last_part;
            } else if (right) {
                // The byte of pixel last - 1, covered from first at most.
                rs.last_part = last - @max(first, (last - 1) & ~@as(i32, 1)) < 2;
            } else {
                // The byte of pixel last, covered up to first at most.
                rs.last_part = @min(first, (last & ~@as(i32, 1)) + 2) - last < 2;
            }
        }
        return row_ticks(d, rs);
    }

    /// Pixels a..b-1 of the row with one pen index: video then collision,
    /// recorded for `row`'s replay, and counted for the tick model.
    inline fn fill(d: *Draw, comptime simple: bool, vline: u16, cline: u16, a: u16, b: u16, pen_index: u8, right: bool) void {
        d.spans[d.n_spans] = .{ .a = @intCast(a), .b = @intCast(b), .pen_index = pen_index };
        d.n_spans += 1;
        if (simple) {
            // No pen collides, XORs or is tracked (`simple`).
            const f = d.pen_flags[pen_index];
            if (f & flag_opaque != 0) {
                const first = a >> 1;
                undo.touch_short(vline +% first, ((b - 1) >> 1) - first + 1);
                set_nibbles(d.ram, vline, a, b, f >> 4);
                d.pixels += b - a;
            }
            return;
        }
        const f = d.fill_pixels(vline, cline, a, b, pen_index);
        if (d.track_vid) d.vid.add(a, b, if (f & flag_opaque == 0) vid_read else if (d.xor) vid_xor else vid_write, right);
        if (f & flag_collide != 0) {
            d.col.add(a, b, if (d.deposit) col_detect else col_write, right);
        } else if (f & flag_preserve != 0) {
            d.col.add(a, b, col_preserve, right);
        }
    }

    /// The RAM side of `fill`; returns the pen's flags.
    inline fn fill_pixels(d: *Draw, vline: u16, cline: u16, a: u16, b: u16, pen_index: u8) u8 {
        const f = d.pen_flags[pen_index];
        // The bytes of pixels a..b-1 (two per byte): one scrubber touch per
        // span and buffer (core/undo.zig), never per pixel.
        const first = a >> 1;
        const n = ((b - 1) >> 1) - first + 1;
        if (f & flag_opaque != 0) {
            undo.touch_short(vline +% first, n);
            const pen = f >> 4;
            if (d.xor) xor_nibbles(d.ram, vline, a, b, pen) else set_nibbles(d.ram, vline, a, b, pen);
            d.pixels += b - a;
        }
        if (f & flag_collide != 0) {
            undo.touch_short(cline +% first, n);
            const old = max_set_nibbles(d.ram, cline, a, b, d.coll_num);
            if (d.deposit and old > d.fred) d.fred = old;
        }
        return f;
    }
};

/// Do the circular (mod 64 KB) byte ranges [a, a + la) and [b, b + lb)
/// share a byte? (la, lb >= 1.)
fn overlaps(a: u16, la: u16, b: u16, lb: u16) bool {
    return a -% b < lb or b -% a < la;
}

/// Pixels a..b-1 (a < b) of the line at `base` set to `v` (0..15).
inline fn set_nibbles(ram: *[0x10000]u8, base: u16, a: u16, b: u16, v: u8) void {
    var x = a;
    if (x & 1 != 0) {
        const p = base +% (x >> 1);
        ram[p] = (ram[p] & 0xF0) | v;
        x += 1;
    }
    const full = (b - x) >> 1;
    if (full != 0) {
        fill_bytes(ram, base +% (x >> 1), full, v * 0x11, false);
        x += 2 * full;
    }
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
    const full = (b - x) >> 1;
    if (full != 0) {
        fill_bytes(ram, base +% (x >> 1), full, v * 0x11, true);
        x += 2 * full;
    }
    if (x < b) ram[base +% (x >> 1)] ^= v << 4;
}

/// `n` (1..80) RAM bytes from `p` (wrapping at 64 KB) set to `v`, or
/// XORed with it: word stores where the run is long enough (a background
/// or polygon row is up to 80 bytes; raycast's are one or two).
inline fn fill_bytes(ram: *[0x10000]u8, p: u16, n: u16, v: u8, comptime xor: bool) void {
    var i: usize = p;
    const end = i + n;
    if (n >= 8 and end <= 0x10000) {
        const addr0 = @intFromPtr(ram);
        while ((addr0 + i) & 3 != 0) : (i += 1) {
            if (xor) ram[i] ^= v else ram[i] = v;
        }
        const w = @as(u32, v) * 0x0101_0101;
        while (i + 4 <= end) : (i += 4) {
            const q: *u32 = @ptrCast(@alignCast(&ram[i]));
            if (xor) q.* ^= w else q.* = w;
        }
    }
    while (i < end) : (i += 1) {
        const k: u16 = @truncate(i);
        if (xor) ram[k] ^= v else ram[k] = v;
    }
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
