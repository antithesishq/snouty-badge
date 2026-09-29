//! Game Gear VDP (315-5378, the SMS2 VDP with a 12-bit palette): mode 4
//! only. Control/data ports, counters and interrupts, and a scanline
//! renderer. SPEC.md sections 3, 4 and 6; PLAN.md "M1 Core: contract".
//! Reference: Charles MacDonald's msvdp.txt (SMS Power).
//!
//! Scanline accuracy: each line's events happen when `tick` crosses the
//! start of the line, in this order: vertical scroll latch (line 0), sprite
//! evaluation and rendering with the registers as they are then (active
//! lines), line counter, frame interrupt flag (line 193). An interrupt
//! raised at the start of line N lets its handler change registers before
//! line N + 1 is rendered.
const tables = @import("vdp_tables.zig");

/// Visible Game Gear screen: VDP columns 48..207, lines 24..167.
pub const screen_w = 160;
pub const screen_h = 144;
/// First VDP column and line of the Game Gear window.
pub const window_x0 = 48;
pub const window_y0 = 24;
/// NTSC: 262 lines of 228 T-states, 192 of them active.
pub const lines_per_frame = 262;
pub const tstates_per_line = 228;
pub const active_lines = 192;
/// The frame interrupt flag sets at the start of this line (V counter C1).
pub const frame_irq_line = 193;

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

/// Status register bits.
pub const status_frame: u8 = 0x80;
pub const status_overflow: u8 = 0x40;
pub const status_collision: u8 = 0x20;
/// Low five status bits: unused on the SMS2 (open bus); read as set.
const status_unused: u8 = 0x1F;

/// Up to eight sprites found on one line, in SAT order (entry 0 wins).
const LineSprites = struct {
    n: u8 = 0,
    /// Left column (shift-left-8 applied, so -8..255).
    x: [8]i16 = undefined,
    /// The sprite's pattern row, packed: pixel i's colour in nibble i.
    row: [8]u32 = undefined,
};

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
    /// Current line 0..261 and T-states into it. Line 0's start events are
    /// taken as done at reset (nothing visible happens on line 0).
    line: u16 = 0,
    line_tstates: u16 = 0,
    /// Register 10 down-counter.
    line_counter: u8 = 0xFF,
    /// Register 9 latched at the start of the frame.
    vscroll: u8 = 0,

    pub fn reset(v: *Vdp) void {
        v.* = .{};
    }

    // ---- Timing ----

    /// Advance by `t` T-states. Each line start crossed runs that line's
    /// events (`start_line`): visible lines are rendered and sent to
    /// `sink`, active lines evaluate sprites even without a sink. Returns
    /// true when the end of line 261 is crossed; the T-states beyond it
    /// count towards the next frame.
    pub inline fn tick(v: *Vdp, t: u32, sink: ?LineSink) bool {
        const lt = v.line_tstates + t;
        if (lt < tstates_per_line) {
            v.line_tstates = @intCast(lt);
            return false;
        }
        return v.cross_lines(lt, sink);
    }

    fn cross_lines(v: *Vdp, t_in_line: u32, sink: ?LineSink) bool {
        var lt = t_in_line;
        var done = false;
        while (lt >= tstates_per_line) {
            lt -= tstates_per_line;
            v.line += 1;
            if (v.line == lines_per_frame) {
                v.line = 0;
                done = true;
            }
            v.start_line(sink);
        }
        v.line_tstates = @intCast(lt);
        return done;
    }

    /// The events at the start of `v.line`.
    fn start_line(v: *Vdp, sink: ?LineSink) void {
        const line = v.line;
        if (line == 0) v.vscroll = v.regs[9];

        if (line < active_lines) {
            const l: u8 = @intCast(line);
            if (line >= window_y0 and line < window_y0 + screen_h) {
                if (sink) |s| {
                    var out: [screen_w]u5 = undefined;
                    v.render_line(l, window_x0, &out);
                    s.emit(@intCast(line - window_y0), &out, &v.cram);
                } else v.sprite_flags(l);
            } else v.sprite_flags(l);
        }

        // Line counter: decremented on lines 0..192, reloaded on 193..261
        // and on underflow (which raises the line interrupt).
        if (line <= active_lines) {
            if (v.line_counter == 0) {
                v.line_counter = v.regs[10];
                v.line_irq_pending = true;
            } else v.line_counter -= 1;
        } else v.line_counter = v.regs[10];

        if (line == frame_irq_line) v.status |= status_frame;
    }

    /// Interrupt output: frame IRQ (status bit 7 with register 1 bit 5) or
    /// line IRQ (pending with register 0 bit 4).
    pub fn irq_line(v: *const Vdp) bool {
        return (v.status & status_frame != 0 and v.regs[1] & 0x20 != 0) or
            (v.line_irq_pending and v.regs[0] & 0x10 != 0);
    }

    /// Port 7E read: V counter, 192-line NTSC (00-DA, then D5-FF).
    pub fn v_counter(v: *const Vdp) u8 {
        const l = v.line;
        return @truncate(if (l <= 0xDA) l else l - 6);
    }

    /// Port 7F read: H counter approximated from the T-state offset. 171
    /// counts per line (342 dots / 2, 3/4 of a count per T-state) over the
    /// documented sequence 00-93, E9-FF.
    pub fn h_counter(v: *const Vdp) u8 {
        const i: u16 = v.line_tstates * 3 / 4;
        return @truncate(if (i <= 0x93) i else i + (0xE9 - 0x94));
    }

    // ---- Ports ----

    /// Port BE read: the read-ahead buffer, refilled from VRAM.
    pub fn read_data(v: *Vdp) u8 {
        v.latch_pending = false;
        const b = v.read_buffer;
        v.read_buffer = v.vram[v.addr];
        v.addr = (v.addr + 1) & 0x3FFF;
        return b;
    }

    /// Port BF read: status, clearing the flags, the line IRQ and the latch.
    pub fn read_status(v: *Vdp) u8 {
        const s = v.status | status_unused;
        v.status = 0;
        v.line_irq_pending = false;
        v.latch_pending = false;
        return s;
    }

    /// Port BE write: VRAM for codes 0-2 (also loads the read buffer), CRAM
    /// for code 3 as Game Gear byte pairs.
    pub fn write_data(v: *Vdp, b: u8) void {
        v.latch_pending = false;
        if (v.code == 3) {
            if (v.addr & 1 == 0) {
                v.cram_latch = b;
            } else {
                v.cram[(v.addr & 0x3F) >> 1] = (@as(u16, b & 0x0F) << 8) | v.cram_latch;
            }
        } else {
            v.vram[v.addr] = b;
            v.read_buffer = b;
        }
        v.addr = (v.addr + 1) & 0x3FFF;
    }

    /// Port BF write: two-byte command word (low address, then code and
    /// high address bits).
    pub fn write_control(v: *Vdp, b: u8) void {
        if (!v.latch_pending) {
            v.latch_low = b;
            v.addr = (v.addr & 0x3F00) | b;
            v.latch_pending = true;
            return;
        }
        v.latch_pending = false;
        v.addr = (@as(u16, b & 0x3F) << 8) | v.latch_low;
        v.code = @intCast(b >> 6);
        switch (v.code) {
            0 => {
                v.read_buffer = v.vram[v.addr];
                v.addr = (v.addr + 1) & 0x3FFF;
            },
            2 => {
                const r = b & 0x0F;
                if (r < v.regs.len) v.regs[r] = v.latch_low;
            },
            else => {},
        }
    }

    // ---- Rendering ----

    inline fn backdrop(v: *const Vdp) u5 {
        return @intCast(16 | (v.regs[7] & 0x0F));
    }

    inline fn display_on(v: *const Vdp) bool {
        return v.regs[1] & 0x40 != 0;
    }

    /// Render active line `line` (0..191), VDP columns `x0 .. x0 + 159`
    /// (`x0` <= 96; the Game Gear window is `window_x0`), into `out`.
    /// Evaluates the line's sprites, so the overflow and collision flags
    /// update as a side effect. Uses the latched vertical scroll.
    pub fn render_line(v: *Vdp, line: u8, x0: u8, out: *[screen_w]u5) void {
        const bd = v.backdrop();
        if (!v.display_on()) {
            @memset(out, bd);
            return;
        }
        // Indexed by VDP column; room for column counter 31 at fine 7.
        var buf: [256 + 8]u5 = undefined;
        // Per column counter: opaque pixels of priority tiles (bit 7 = left).
        var prio: [32]u8 = @splat(0);

        const r0 = v.regs[0];
        const hs: u8 = if (r0 & 0x40 != 0 and line < 16) 0 else v.regs[8];
        const fine: u16 = hs & 7;
        const coarse: u8 = hs >> 3;
        const x_end: u16 = @as(u16, x0) + screen_w;

        // Pixels left of the first column counter show the backdrop.
        var n_lo: u16 = 0;
        if (x0 < fine) {
            for (x0..fine) |x| buf[x] = bd;
        } else n_lo = (x0 - fine) >> 3;
        const n_hi: u16 = (x_end - 1 - fine) >> 3;

        const nt: u16 = @as(u16, v.regs[2] & 0x0E) << 10;
        var ys: u16 = @as(u16, line) + v.vscroll;
        if (ys >= 224) ys -= 224;
        if (ys >= 224) ys -= 224;
        const row_scrolled: u16 = nt + (ys >> 3) * 64;
        const row_locked: u16 = nt + @as(u16, line >> 3) * 64;
        const lock_col: u16 = if (r0 & 0x80 != 0) 24 else 32;

        var n = n_lo;
        while (n <= n_hi) : (n += 1) {
            const locked = n >= lock_col;
            const rbase = if (locked) row_locked else row_scrolled;
            const fy: u16 = if (locked) line & 7 else ys & 7;
            const col: u16 = (n -% coarse) & 31;
            const ea = rbase + col * 2;
            const entry: u16 = @as(u16, v.vram[ea]) | (@as(u16, v.vram[ea + 1]) << 8);
            const r: u16 = if (entry & 0x400 != 0) 7 - fy else fy;
            const pa = (entry & 0x1FF) * 32 + r * 4;
            const p0 = v.vram[pa];
            const p1 = v.vram[pa + 1];
            const p2 = v.vram[pa + 2];
            const p3 = v.vram[pa + 3];
            const hflip = entry & 0x200 != 0;
            const row = decode(p0, p1, p2, p3, hflip);
            if (entry & 0x1000 != 0) {
                const m = p0 | p1 | p2 | p3;
                prio[n] = if (hflip) @bitReverse(m) else m;
            }
            const pal: u32 = if (entry & 0x800 != 0) 16 else 0;
            const px = n * 8 + fine;
            inline for (0..8) |i| buf[px + i] = @intCast(pal | ((row >> (4 * i)) & 0xF));
        }

        var list: LineSprites = .{};
        v.find_sprites(line, &list);
        if (list.n != 0) v.sprites(&list, &buf, &prio, @intCast(fine), x0, true);

        if (r0 & 0x20 != 0 and x0 < 8) {
            for (x0..8) |x| buf[x] = bd;
        }
        @memcpy(out, buf[x0..x_end]);
    }

    /// Sprite evaluation for an active line that is not rendered: sets the
    /// overflow and collision flags only.
    pub fn sprite_flags(v: *Vdp, line: u8) void {
        if (!v.display_on()) return;
        var list: LineSprites = .{};
        v.find_sprites(line, &list);
        if (list.n >= 2 and v.status & status_collision == 0) {
            v.sprites(&list, undefined, undefined, 0, 0, false);
        }
    }

    /// Scan the SAT for the sprites on `line`: the first eight go into
    /// `list` with their pattern row, a ninth sets the overflow flag. Y =
    /// 0xD0 ends the list (192-line mode).
    fn find_sprites(v: *Vdp, line: u8, list: *LineSprites) void {
        const sat: u16 = @as(u16, v.regs[5] & 0x7E) << 7;
        const r1 = v.regs[1];
        const zoom: u3 = @intCast(r1 & 1);
        const tall = r1 & 0x02 != 0;
        const h: u8 = @as(u8, if (tall) 16 else 8) << zoom;
        const pat_base: u16 = @as(u16, v.regs[6] & 0x04) << 11;
        const shift: i16 = if (v.regs[0] & 0x08 != 0) 8 else 0;
        var i: u16 = 0;
        while (i < 64) : (i += 1) {
            const y = v.vram[sat + i];
            if (y == 0xD0) break;
            const d = line -% y -% 1;
            if (d >= h) continue;
            if (list.n == 8) {
                v.status |= status_overflow;
                break;
            }
            const xa = sat + 128 + i * 2;
            var pat: u16 = v.vram[xa + 1];
            if (tall) pat &= 0xFE;
            var r: u16 = d >> zoom;
            if (r >= 8) {
                pat += 1;
                r -= 8;
            }
            const pa = pat_base + pat * 32 + r * 4;
            list.x[list.n] = @as(i16, v.vram[xa]) - shift;
            list.row[list.n] = decode(v.vram[pa], v.vram[pa + 1], v.vram[pa + 2], v.vram[pa + 3], false);
            list.n += 1;
        }
    }

    /// Composite `list` (entry 0 on top) over the background in `buf`
    /// (when `draw`), and set the collision flag when two opaque sprite
    /// pixels meet anywhere in columns 0..255. `prio` and `fine` locate the
    /// background's priority pixels; only columns `x0 .. x0 + 159` are drawn.
    fn sprites(v: *Vdp, list: *const LineSprites, buf: *[256 + 8]u5, prio: *const [32]u8, fine: u8, x0: u8, comptime draw: bool) void {
        const zoom: u4 = @intCast(v.regs[1] & 1);
        var occ: [8]u32 = @splat(0);
        var hit = false;
        const lo: i16 = x0;
        const hi: i16 = @as(i16, x0) + screen_w;
        for (0..list.n) |s| {
            var row = list.row[s];
            const sx = list.x[s];
            var i: i16 = 0;
            while (row != 0) : ({
                row >>= 4;
                i += 1;
            }) {
                const c: u5 = @intCast(row & 0xF);
                if (c == 0) continue;
                var k: i16 = 0;
                while (k < (@as(i16, 1) << zoom)) : (k += 1) {
                    const colx = sx + (i << zoom) + k;
                    if (colx < 0 or colx > 255) continue;
                    const col: u16 = @intCast(colx);
                    const w = col >> 5;
                    const bit = @as(u32, 1) << @intCast(col & 31);
                    if (occ[w] & bit != 0) {
                        hit = true;
                        continue;
                    }
                    occ[w] |= bit;
                    if (draw and colx >= lo and colx < hi) {
                        if (col >= fine) {
                            const off = col - fine;
                            if (prio[off >> 3] & (@as(u8, 0x80) >> @intCast(off & 7)) != 0) continue;
                        }
                        buf[col] = 16 | c;
                    }
                }
            }
        }
        if (hit) v.status |= status_collision;
    }
};

/// Four plane bytes of a tile row to eight packed pixels, nibble i =
/// pixel i from the left (mirrored when `hflip`).
inline fn decode(p0: u8, p1: u8, p2: u8, p3: u8, hflip: bool) u32 {
    const t = if (hflip) &tables.spread_rev else &tables.spread;
    return t[p0] | (t[p1] << 1) | (t[p2] << 2) | (t[p3] << 3);
}
