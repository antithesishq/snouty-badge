//! Suzy (SPEC.md sections 3, 4 and 7): the sprite engine (SCB walker,
//! literal and packed line decoder at 1-4 bpp, 8.8 scaling, stretch, tilt,
//! the four quadrants, H/V flip, the eight sprite types, collision buffer
//! and depository), the math unit (16x16 multiply with sign and
//! accumulate, 32/16 divide) and the hardware registers at $FC00-$FCFF.
//! PLAN.md "Frozen for M1: core/suzy.zig" is the contract; M1 Track B fills
//! this file. M0 stub: the frozen shape only.
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
//!   estimate). Everything Suzy touches is in the 64 KB `ram`; it never
//!   sees the overlays.
//! - `pixels_drawn` counts pixels written since reset (the overlay's
//!   "Suzy pixels per frame"; the frontend differences it).
//!
//! Register map ($FC00 + addr; Epyx hardware appendix, SPEC.md section 20):
//! $00-$4F sprite engine registers (TMPADR, TILTACUM, HOFF, VOFF, VIDBAS,
//! COLLBAS, VIDADR, COLLADR, SCBNEXT $10, SPRDLINE, HPOSSTRT, VPOSSTRT,
//! SPRHSIZ, SPRVSIZ, STRETCH, TILT, SPRDOFF, SPRVPOS, COLLOFF, VSIZACUM,
//! HSIZOFF $28, VSIZOFF, SCBADR, PROCADR), $52-$6F math (MATHD..MATHA $52-
//! $55, MATHP/N $56-$57, MATHH..MATHE $60-$63, MATHM..MATHJ $6C-$6F),
//! $80 SPRCTL0, $81 SPRCTL1, $82 SPRCOLL, $83 SPRINIT, $88 SUZYHREV, $89
//! SUZYSREV, $90 SUZYBUSEN, $91 SPRGO, $92 SPRSYS, $B0 JOYSTICK, $B1
//! SWITCHES, $B2 RCART0, $B3 RCART1, $C0-$C3 LEDs/parallel (ignored).

pub const Suzy = struct {
    /// SPRSYS ($FC92) as last written (bit 7 signed math, 6 accumulate, 5
    /// no collide, 4 vstretch, 3 lefthand, 2 clear unsafe, 1 sprite to stop).
    sprsys: u8 = 0,
    /// SPRGO ($FC91) as last written: bit 0 sprite go (the pending
    /// request), bit 2 everon.
    sprgo: u8 = 0,
    /// Pixels written by the sprite engine since reset (wraps).
    pixels_drawn: u32 = 0,

    pub fn reset(s: *Suzy) void {
        s.* = .{};
    }

    /// A register read at $FC00 + addr (never $B0-$B3). Stub: 0.
    pub fn read(s: *const Suzy, addr: u8) u8 {
        _ = s;
        _ = addr;
        return 0;
    }

    /// A register write at $FC00 + addr (never $B0-$B3). Stub: SPRGO and
    /// SPRSYS are stored.
    pub fn write(s: *Suzy, addr: u8, v: u8) void {
        switch (addr) {
            0x91 => s.sprgo = v,
            0x92 => s.sprsys = v,
            else => {},
        }
    }

    /// A sprite list is waiting for the bus (SPRGO bit 0 and SUZYBUSEN).
    pub fn sprites_pending(s: *const Suzy) bool {
        return s.sprgo & 1 != 0;
    }

    /// Draw the whole list now; returns the ticks to charge the CPU. Stub:
    /// clears the request, draws nothing.
    pub fn run_sprites(s: *Suzy, ram: *[0x10000]u8) u32 {
        _ = ram;
        s.sprgo &= ~@as(u8, 1);
        return 0;
    }

    /// SPRSYS bit 3: the joystick direction bits are swapped.
    pub fn lefthand(s: *const Suzy) bool {
        return s.sprsys & 0x08 != 0;
    }
};
