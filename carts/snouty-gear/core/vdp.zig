//! Game Gear VDP (315-5378): mode 4 only. M0 stub holding the full state
//! with the public shape of PLAN.md's M1 contract (Track B): `tick`,
//! `render_line`, `irq_line`, plus the port accessors the bus will call.
//! SPEC.md sections 3, 4 and 6.

/// Visible Game Gear screen: VDP columns 48..207, lines 24..167.
pub const screen_w = 160;
pub const screen_h = 144;
/// NTSC: 262 lines of 228 T-states.
pub const lines_per_frame = 262;
pub const tstates_per_line = 228;

/// One visible line as CRAM indices 0..31 (16..31 are the sprite palette,
/// so the element is a u5, not a u4) plus the CRAM as it is when the line
/// is rendered, so the frontend owns the 12-bit -> RGB565 conversion.
/// Called once per visible line, y = 0..143 in Game Gear coordinates, in
/// order, including the lines the frontend's squeeze skips.
pub const LineSink = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, y: u8, pixels: *const [screen_w]u5, cram: *const [32]u16) void,

    pub fn emit(self: LineSink, y: u8, pixels: *const [screen_w]u5, cram: *const [32]u16) void {
        self.func(self.ctx, y, pixels, cram);
    }
};

/// Register values the BIOS leaves (the usual BIOS-less start).
pub const post_bios_regs = [11]u8{ 0x36, 0x80, 0xFF, 0xFF, 0xFF, 0xFF, 0xFB, 0x00, 0x00, 0x00, 0xFF };

pub const Vdp = struct {
    vram: [0x4000]u8 = @splat(0),
    /// 32 colors, 12 bits each: ----BBBBGGGGRRRR.
    cram: [32]u16 = @splat(0),
    /// Registers 0..10 (writes to 11..15 are ignored).
    regs: [11]u8 = post_bios_regs,

    // ---- Control port ----
    /// A first control byte is waiting for its second.
    latch_pending: bool = false,
    latch_low: u8 = 0,
    /// 14-bit VRAM/CRAM address and 2-bit access code (0 VRAM read, 1 VRAM
    /// write, 2 register write, 3 CRAM write).
    addr: u16 = 0,
    code: u2 = 0,
    /// VRAM read-ahead buffer.
    read_buffer: u8 = 0,
    /// CRAM writes come as byte pairs on the Game Gear: even byte latched.
    cram_latch: u8 = 0,

    // ---- Status and counters ----
    /// Bit 7 frame interrupt, bit 6 sprite overflow, bit 5 collision.
    status: u8 = 0,
    line_irq_pending: bool = false,
    /// Current line 0..261 and T-states into it.
    line: u16 = 0,
    line_tstates: u16 = 0,
    /// Register 10 down-counter.
    line_counter: u8 = 0xFF,
    /// Register 9 latched at the start of the frame.
    vscroll: u8 = 0,

    pub fn reset(v: *Vdp) void {
        v.* = .{};
    }

    /// Advance by `t` T-states, rendering each visible line at its start
    /// through `sink`. Returns true once the end of line 261 is reached
    /// (the frame is done). M0 stub: counts lines only, renders nothing.
    pub fn tick(v: *Vdp, t: u32, sink: ?LineSink) bool {
        _ = sink;
        var left = t + v.line_tstates;
        var done = false;
        while (left >= tstates_per_line) {
            left -= tstates_per_line;
            v.line += 1;
            if (v.line == lines_per_frame) {
                v.line = 0;
                done = true;
            }
        }
        v.line_tstates = @intCast(left);
        return done;
    }

    /// Render Game Gear line `y` (0..143) into `out`. M0 stub: backdrop.
    pub fn render_line(v: *const Vdp, y: u8, out: *[screen_w]u5) void {
        _ = y;
        @memset(out, @intCast(16 | (v.regs[7] & 0x0F)));
    }

    /// Interrupt output: frame IRQ (status bit 7 with register 1 bit 5) or
    /// line IRQ (pending with register 0 bit 4).
    pub fn irq_line(v: *const Vdp) bool {
        return (v.status & 0x80 != 0 and v.regs[1] & 0x20 != 0) or
            (v.line_irq_pending and v.regs[0] & 0x10 != 0);
    }

    /// Port BE read. M0 stub: the read-ahead buffer.
    pub fn read_data(v: *Vdp) u8 {
        v.latch_pending = false;
        return v.read_buffer;
    }

    /// Port BF read: status, clearing the flags, the IRQ and the latch.
    pub fn read_status(v: *Vdp) u8 {
        const s = v.status | 0x1F;
        v.status = 0;
        v.line_irq_pending = false;
        v.latch_pending = false;
        return s;
    }

    /// Port BE write. M0 stub: dropped.
    pub fn write_data(v: *Vdp, b: u8) void {
        _ = b;
        v.latch_pending = false;
    }

    /// Port BF write. M0 stub: dropped.
    pub fn write_control(v: *Vdp, b: u8) void {
        _ = v;
        _ = b;
    }
};
