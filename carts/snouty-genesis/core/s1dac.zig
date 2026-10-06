//! A high-level fake of Sonic 1's Z80 sound driver for the RAM cart
//! (PLAN.md "Sonic 1 DAC fake (2026-10-05)", `-Dgenesis_s1dac=true`). The
//! RAM cart has no Z80 (core/z80bus.zig's stub), and in Sonic 1 the Z80 is
//! only a DAC sample player: the 68000's SMPS sends a sample id to Z80 RAM
//! `$1FFF` and the driver streams it into YM2612 register 2A. Without it
//! the drums, the timpani and the SEGA chant are silent. This file does
//! what that driver does, from the 68000's side and in the renderer, for
//! that one game; other ROMs never switch it on.
//!
//! The driver, as the 68000 uploads it at boot (Kosinski-compressed in the
//! ROM; tools/s1dac_trace.zig checked every fact below against the real Z80
//! running it):
//!
//! - After RESET: `$1FFD` = `$1FFF` = 0, the bank register = 68000
//!   0x78000. Then it polls `$1FFF` until bit 7 is set and stores id - $81
//!   there (bit 7 clear: taken; the 68000 never reads it back).
//! - id - $81 < 6: a 4-bit DPCM sample, entry `table` + 8 x (id - $81) in
//!   Z80 RAM: pointer, length in bytes, delay count `c` (+4). The
//!   accumulator starts at $80; each byte gives two nibbles, high first,
//!   each adds a signed delta from the 16-byte table at Z80 `deltas` and
//!   the sum goes to 2A. The driver writes 2B = $80 (DAC on) first. Write
//!   spacing (Z80 T-states, instruction to instruction): high -> low
//!   99 + 13c, low -> next high 176 + 13c. After each low nibble it checks
//!   `$1FFF` bit 7; a new id cuts the sample there.
//! - Otherwise (id $87 and up, $80): the SEGA chant, raw unsigned 8-bit
//!   PCM through the bank window (`LD DE,` / `LD HL,` operands of its code:
//!   window `$9688`, 27,000 bytes, to the window's end), 77 + 13B T-states
//!   per sample (`LD B,` operand 11: 220, 16.27 kHz). It never checks
//!   `$1FFF` and does not write 2B.
//! - `$1FFD` bit 7 is set around each two-byte YM2612 access; the 68000
//!   polls it before touching the YM2612 (it reads $1F after a sample).
//! - Music: kick $81 (c = $17), snare $82 (c = 1), timpani $83 with the
//!   68000 writing its delay count to Z80 `$00EA` first (the SMPS maps its
//!   notes $88-$8B to $83 and four counts). The title's SEGA sends $88.
//!   $84-$87 are table entries overlapping sample data; nothing sends them.
//!
//! The fake, two halves:
//!
//! - Console side: Z80 RAM is `Md.sram` (8 KB, `rom.sram_max`, unused by
//!   Sonic 1, which has no SRAM), so the 68000 reads back what it wrote (its
//!   Kosinski decompressor reads its own output). When the Z80 would be
//!   running (BUSREQ and RESET released) and `$1FFF` has bit 7, the command
//!   is taken as the driver does (`$1FFF`, `$1FFD`, 2B, the address latch)
//!   and handed to the renderer; a Z80 RESET does the driver's init. All of
//!   it writes existing console state from console events only, so it is
//!   deterministic (link play's state hash, docs/LINK_PLAY.md). It differs
//!   from the real Z80 only in when: a command is taken at once even while
//!   a sample plays (the 68000 does not read `$1FFF`), `$1FFD` never shows
//!   bit 7 (no 68000 retries), and the init runs at RESET's assertion, not
//!   after its release (Sonic writes nothing in between). `bus.zig`,
//!   `z80bus.zig` and `sound.zig` call this file in place of their own
//!   Z80-side code in every build with the fake, as whole out-of-line
//!   calls: the 68000's hot loop inlines the bus, and the fake's checks
//!   inlined there cost up to 1.2 ms per update in spilled registers
//!   (PLAN.md).
//! - Render side (`Player`, render-only state in `sound.Sound`): the sample
//!   being played and the T-states to its next DAC write, stepped per
//!   44.1 kHz output sample while the Z80 would run (while a sample plays,
//!   BUSREQ writes catch the render up first, so the DAC pauses while the
//!   68000 holds the bus, as on hardware; the real-Z80 core runs the Z80 a
//!   line at a time, so its pauses are whole lines). The DAC level is added
//!   per output sample, not through the FM's held 14.7 kHz value. Nothing
//!   renders with the Sound row off; the console side still runs.
//!
//! The constants are the driver's own (opcode timings and Z80 RAM
//! addresses of its code); sample data, tables and parameters are read
//! from Z80 RAM and the ROM at run time. Nothing from the ROM is in the
//! repository.
const std = @import("std");
const build_options = @import("build_options");
const md_mod = @import("md.zig");
const Md = md_mod.Md;
const rom = @import("rom.zig");
const sound = @import("sound.zig");
const probe = @import("probe.zig");

/// The fake is built in (`build_options.s1dac`, the RAM cart with
/// `-Dgenesis_s1dac=true`): it needs the synthesis and no Z80.
pub const enabled: bool = build_options.s1dac;

comptime {
    if (enabled and (build_options.z80 or !build_options.synth)) @compileError("s1dac: the RAM cart's variant only (no Z80, synth on)");
    if (enabled and rom.sram_max < 0x2000) @compileError("s1dac: Z80 RAM lives in Md.sram, which must hold 8 KB");
}

// ---- The driver's addresses (Z80 RAM) ----

/// The command byte the 68000 writes (68000 A01FFF).
const cmd_at: u16 = 0x1FFF;
/// The busy flag the 68000 polls (A01FFD).
const busy_at: u16 = 0x1FFD;
/// The DPCM sample table: 8-byte entries.
const table_at: u16 = 0x00D6;
/// The 16 signed nibble deltas.
const deltas_at: u16 = 0x0022;
/// Entries the driver treats as DPCM (id - $81 below this); the rest is
/// the SEGA chant.
const dpcm_ids: u8 = 6;
/// Operands of the SEGA code: `LD DE,start`, `LD HL,length`, `LD B,delay`.
const sega_de_at: u16 = 0x00BA;
const sega_hl_at: u16 = 0x00BD;
const sega_b_at: u16 = 0x00C9;
/// The bank register value the driver's init leaves (68000 0x78000 >> 15).
const driver_bank: u16 = 0x00F;
/// `$1FFD` once a DPCM sample has written its first nibble (`LD (HL),H`).
const busy_idle: u8 = 0x1F;

// ---- Its timing, Z80 T-states between instruction starts ----

/// High nibble's 2A write -> low nibble's, + 13 per delay count.
const t_hi_lo: i32 = 99;
/// Low nibble's write -> the `$1FFF` check, + 13c.
const t_lo_check: i32 = 29;
/// The check -> next byte's high nibble write (176 - 29).
const t_check_hi: i32 = 147;
/// The check with a command waiting -> the poll's read of `$1FFF`.
const t_check_poll: i32 = 41;
/// The poll's read of `$1FFF` -> a DPCM sample's first 2A write.
const t_poll_dpcm: i32 = 398;
/// The poll's read -> the SEGA's first write.
const t_poll_sega: i32 = 107;
/// SEGA: per sample 77 + 13B; the last write -> the poll's read.
const t_sega_base: i32 = 77;
const t_sega_poll: i32 = 214;
/// Average wait in the idle poll loop (21 T-states) before it reads.
const t_poll_phase: i32 = 10;
/// One DJNZ step of a delay loop.
const t_count: i32 = 13;

/// T-states per 44.1 kHz output sample, Q8: 53,693,175 / 15 / 44,100 x 256.
pub const step_q8: i32 = 20779;

// ---- Detection ----

/// The ROM the fake is for: Sonic 1 REV01 (`GM 00004049-01`, the one the
/// fake was checked against) by serial and checksum word, and the 68000
/// code that feeds the driver at the addresses the fake was written
/// against. Anything else (REV00 included) keeps the stub.
pub noinline fn detect(src: *const rom.RomSource) bool {
    if (src.size < 0x80000) return false;
    for (checks) |x| if (rom.read16(src, x.at) != x.w) return false;
    return true;
}

/// A 68000 word the ROM must hold.
const Word = struct { at: u32, w: u16 };
const checks = [_]Word{
    // The serial `GM 00004049-01` and the checksum word.
    .{ .at = 0x180, .w = 0x474D },
    .{ .at = 0x182, .w = 0x2030 },
    .{ .at = 0x184, .w = 0x3030 },
    .{ .at = 0x186, .w = 0x3034 },
    .{ .at = 0x188, .w = 0x3034 },
    .{ .at = 0x18A, .w = 0x392D },
    .{ .at = 0x18C, .w = 0x3031 },
    .{ .at = 0x18E, .w = 0xAFC7 },
    // move.b d0,$A01FFF (music DAC notes)
    .{ .at = 0x71CA4, .w = 0x13C0 },
    .{ .at = 0x71CA6, .w = 0x00A0 },
    .{ .at = 0x71CA8, .w = 0x1FFF },
    // move.b d0,$A000EA; move.b #$83,$A01FFF (timpani)
    .{ .at = 0x71CB4, .w = 0x13C0 },
    .{ .at = 0x71CB6, .w = 0x00A0 },
    .{ .at = 0x71CB8, .w = 0x00EA },
    .{ .at = 0x71CBA, .w = 0x13FC },
    .{ .at = 0x71CBC, .w = 0x0083 },
    .{ .at = 0x71CBE, .w = 0x00A0 },
    .{ .at = 0x71CC0, .w = 0x1FFF },
    // move.b #$88,$A01FFF (SEGA)
    .{ .at = 0x71FAC, .w = 0x13FC },
    .{ .at = 0x71FAE, .w = 0x0088 },
    .{ .at = 0x71FB0, .w = 0x00A0 },
    .{ .at = 0x71FB2, .w = 0x1FFF },
};

/// The fake drives this console (built in, and the ROM is Sonic 1).
pub inline fn on(md: *const Md) bool {
    if (comptime !enabled) return false;
    return md.s1dac_on;
}

// ---- Console side ----
//
// `bus.zig`, `z80bus.zig` and `sound.zig` call these in every build with
// the fake, for every ROM, in place of their own code: out of line, as the
// 68000's hot loop inlines the bus and anything more there spilled its
// registers (PLAN.md "Sonic 1 DAC fake", up to 1.2 ms per update).

/// A 68000 read of the Z80 side (`bus.zig`'s `z80_read`; the stub's 68000
/// always has the bus): Z80 RAM is what was written while the fake is on.
pub noinline fn z80_read(md: *Md, addr: u24) u8 {
    if (addr & 0x8000 != 0) return 0xFF;
    if (addr & 0x4000 == 0 and md.s1dac_on) return md.sram[addr & 0x1FFF];
    var zb = md.z80bus_for();
    return zb.read(@truncate(addr & 0x7FFF));
}

/// The same as a word (`bus.zig`'s `read16_io`: the byte in both halves).
pub noinline fn z80_read16(md: *Md, addr: u24) u16 {
    const b = z80_read(md, addr);
    return @as(u16, b) << 8 | b;
}

/// A 68000 write to Z80 0000-3FFF (`z80bus.zig`'s stub): kept while the
/// fake is on, and a command written while the Z80 runs is taken at once.
pub noinline fn ram_write(md: *Md, addr: u16, v: u8) void {
    if (!md.s1dac_on) return;
    md.sram[addr & 0x1FFF] = v;
    if (addr & 0x1FFF == cmd_at) poll(md);
}

/// A11100 written (`bus.zig`'s `set_busreq`): while a sample plays, the
/// render catches up first (its DAC runs only while the Z80 would); a Z80
/// that runs again takes a waiting command.
pub noinline fn set_busreq(md: *Md, busreq: bool) void {
    if (md.s1dac_on) sync_if_playing(md);
    md.arbiter.busreq = busreq;
    if (md.s1dac_on) poll(md);
}

/// Render up to now if the player is busy: BUSREQ is about to change.
/// (Idle, the render has nothing to step; a command catches up itself,
/// `poll`.) Every catch-up splits the render's chunks, so Sonic's dozen
/// BUSREQ writes a frame cost only while a sample plays.
fn sync_if_playing(md: *Md) void {
    const s = sound.active(md) orelse return;
    if (s.dac.state != .idle) sound.sync(md);
}

/// The 68000 asserted Z80 RESET (`z80bus.reset_line`, after the YM2612's
/// reset, every ROM): the render starts the FM over, the player stops, and
/// the driver's init is done now (on hardware it runs once RESET is
/// released; Sonic 1 writes nothing in between).
pub noinline fn z80_reset(md: *Md) void {
    if (sound.active(md)) |s| {
        s.fm_resync(md);
        if (md.s1dac_on) s.dac.stop();
    }
    if (!md.s1dac_on) return;
    md.sram[busy_at] = 0;
    md.sram[cmd_at] = 0;
    md.z80_bank = driver_bank;
}

/// The driver's poll, when the Z80 runs: take a command with bit 7 set.
fn poll(md: *Md) void {
    if (md.arbiter.busreq or md.arbiter.z80_reset) return;
    const v = md.sram[cmd_at];
    if (v & 0x80 == 0) return;
    const idx = v -% 0x81;
    md.sram[cmd_at] = idx;
    if (sound.active(md)) |s| {
        sound.sync(md);
        s.dac.command(md, v);
    }
    if (idx < dpcm_ids) {
        // DAC on (`LD (IX),2Bh; LD (IX+1),80h`), leaving the address latch
        // at 2A as the first nibble's write does, and the busy flag as the
        // first nibble leaves it. (2B has no side effect in the register
        // model or the renderer, and `sync` above rendered up to now.)
        md.sram[busy_at] = busy_idle;
        md.ym.regs[0][0x2B] = 0x80;
        md.ym.write_addr(0, 0x2A);
    }
}

// ---- Render side ----

/// What the player's next event is. `dpcm_first` is a sample's first high
/// nibble (no check comes before it); `dpcm_take` the check after a low
/// nibble with a command waiting.
const State = enum(u8) { idle, dpcm_first, dpcm_hi, dpcm_lo, dpcm_take, sega, sega_end };

/// The driver's playback as the renderer steps it (render-only; reset by
/// `stop` and by `sound.Sound.resync`).
pub const Player = struct {
    state: State = .idle,
    /// Q8 T-states to the next event (`state`).
    wait: i32 = 0,
    /// A command the driver has not taken yet (bit 7 set), or 0.
    pending: u8 = 0,
    /// The value in 2A (unsigned, $80 = centre).
    level: u8 = 0x80,
    /// DPCM: the sample byte's Z80 address, bytes left (this one included),
    /// 13c, the accumulator. SEGA: the window address (Z80) of the next
    /// sample and samples left in `src`/`left`, per-sample T-states in
    /// `t_sega`.
    src: u16 = 0,
    left: u32 = 0,
    t_delay: i32 = 0,
    acc: u8 = 0x80,
    t_sega: i32 = 0,
    /// DPCM: Q8 T-states high -> low nibble and low -> next high.
    q_hi_lo: i32 = 0,
    q_lo_hi: i32 = 0,

    pub fn stop(p: *Player) void {
        p.state = .idle;
        p.pending = 0;
        p.wait = 0;
    }

    /// A command reached the driver now (the console took it): start it
    /// from the idle poll, or keep it for the next check (a DPCM byte's,
    /// after its low nibble, or the SEGA's end).
    fn command(p: *Player, md: *const Md, v: u8) void {
        switch (p.state) {
            .idle => {
                p.wait = 0;
                p.take(md, v, t_poll_phase);
            },
            .dpcm_hi => {
                // Waiting for the next byte: if its check is still ahead,
                // that check takes the command.
                const to_check = p.wait - (t_check_hi << 8);
                if (to_check > 0) {
                    p.wait = to_check;
                    p.state = .dpcm_take;
                    p.pending = v;
                } else p.pending = v;
            },
            else => p.pending = v,
        }
    }

    /// The driver reads command `v` from `$1FFF` `t` T-states after the
    /// current event.
    noinline fn take(p: *Player, md: *const Md, v: u8, t: i32) void {
        p.pending = 0;
        if (comptime probe.enabled) probe.note(.fake_take, probe.cur_frame, 0, 0, v);
        const idx = v -% 0x81;
        if (idx < dpcm_ids) {
            const e = table_at + @as(u16, idx) * 8;
            p.src = zword(md, e);
            const n = zword(md, e + 2);
            p.left = if (n == 0) 0x10000 else n;
            p.t_delay = delay(zread(md, e + 4));
            p.q_hi_lo = (t_hi_lo + p.t_delay) << 8;
            p.q_lo_hi = (t_lo_check + p.t_delay + t_check_hi) << 8;
            p.acc = 0x80;
            p.state = .dpcm_first;
            p.wait += (t + t_poll_dpcm) << 8;
        } else {
            p.src = zword(md, sega_de_at);
            const n = zword(md, sega_hl_at);
            p.left = if (n == 0) 0x10000 else n;
            p.t_sega = t_sega_base + delay(zread(md, sega_b_at));
            p.state = .sega;
            p.wait += (t + t_poll_sega) << 8;
        }
    }

    /// The next event, due now (`wait` <= 0); schedules the one after.
    inline fn event(p: *Player, md: *const Md) void {
        switch (p.state) {
            .idle => p.wait = 0,
            .dpcm_first, .dpcm_hi, .dpcm_lo => {
                const hi = p.state != .dpcm_lo;
                const b = zread(md, p.src);
                const nib: u8 = if (hi) b >> 4 else b & 0xF;
                p.acc +%= zread(md, deltas_at + nib);
                p.level = p.acc;
                if (comptime probe.enabled) p.note();
                if (hi) {
                    p.state = .dpcm_lo;
                    p.wait += p.q_hi_lo;
                    return;
                }
                // After the low nibble the driver checks `$1FFF` (29 + 13c
                // later): a waiting command is taken there, else the next
                // byte follows (`command` turns a later arrival into a take
                // while that check is still ahead).
                if (p.pending != 0) {
                    p.state = .dpcm_take;
                    p.wait += (t_lo_check + p.t_delay) << 8;
                    return;
                }
                p.src +%= 1;
                p.left -= 1;
                if (p.left == 0) return p.stop();
                p.state = .dpcm_hi;
                p.wait += p.q_lo_hi;
            },
            .dpcm_take => p.take(md, p.pending, t_check_poll),
            .sega => {
                p.level = zread(md, p.src);
                if (comptime probe.enabled) p.note();
                p.src +%= 1;
                p.left -= 1;
                if (p.left == 0) {
                    p.state = .sega_end;
                    p.wait += t_sega_poll << 8;
                } else p.wait += p.t_sega << 8;
            },
            .sega_end => {
                if (p.pending != 0) return p.take(md, p.pending, 0);
                p.stop();
            },
        }
    }

    /// Add the DAC to `m` (one chunk of FM output, a value per 44.1 kHz
    /// sample), stepping the driver while the Z80 runs: the arbiter is
    /// constant over a render (`sync` runs before it changes). `pan` is
    /// channel 6's (0-2, `ym2612.Fm`), `dac_on` register 2B bit 7.
    pub noinline fn mix(p: *Player, md: *const Md, m: []i32, pan: i32, dac_on: bool) void {
        var d: i32 = if (dac_on) level_out(p.level, pan) else 0;
        var i: usize = 0;
        if (p.state != .idle and !md.arbiter.busreq and !md.arbiter.z80_reset) {
            // Up to the end of the chunk or of the sample; the level is
            // constant between writes.
            var wait = p.wait;
            while (i < m.len) : (i += 1) {
                wait -= step_q8;
                if (wait <= 0) {
                    if (comptime probe.enabled) probe_bin = probe_bin0 + @as(u32, @intCast(i));
                    p.wait = wait;
                    while (p.wait <= 0 and p.state != .idle) p.event(md);
                    wait = p.wait;
                    if (dac_on) d = level_out(p.level, pan);
                    if (p.state == .idle) break;
                }
                m[i] += d;
            }
            p.wait = wait;
        }
        if (d != 0) for (m[i..]) |*v| {
            v.* += d;
        };
    }

    fn note(p: *const Player) void {
        // The event's time: the end of the output sample being made plus
        // the (negative) wait left, in master clocks (15 per T-state).
        // An event in a frame's first output sample may fall in the
        // frame before (the sample straddles the boundary).
        const end = probe_t(probe_bin + 1);
        const t: i64 = @as(i64, end) + @divFloor(@as(i64, p.wait) * 15, 256);
        if (t < 0) return probe.note(.fake_dac, probe.cur_frame -% 1, @intCast(t + frame_clocks), 0x2A, p.level);
        probe.note(.fake_dac, probe.cur_frame, @intCast(t), 0x2A, p.level);
    }
};

/// Channel 6's DAC output in FM units for 2A value `v` (`ym2612.Fm`'s
/// scale: +-8192, then the pan as for every channel).
inline fn level_out(v: u8, pan: i32) i32 {
    return ((@as(i32, v) - 128) << 6) * pan >> 1;
}

/// T-states a `LD B,n; DJNZ $` loop adds over its one-count minimum (13
/// per count past the first; B = 0 counts 256).
inline fn delay(n: u8) i32 {
    const c: i32 = if (n == 0) 256 else n;
    return t_count * c;
}

/// A byte as the Z80 reads it: Z80 RAM, or the ROM through the bank
/// window (the driver's bank is ROM; anything else reads FF).
inline fn zread(md: *const Md, a: u16) u8 {
    if (a < 0x4000) return md.sram[a & 0x1FFF];
    if (a < 0x8000) return 0xFF;
    const at = @as(u32, md.z80_bank & 0x1FF) << 15 | (a & 0x7FFF);
    return if (at < 0x400000) rom.read8(&md.rom, at) else 0xFF;
}

fn zword(md: *const Md, a: u16) u16 {
    return @as(u16, zread(md, a)) | @as(u16, zread(md, a +% 1)) << 8;
}

// ---- The trace probe's clock (host trace builds only) ----

/// The output sample `mix` is at, as an index into the frame
/// (`sound.zig` sets `probe_bin0` per chunk and the frame's phase).
pub var probe_bin0: u32 = 0;
var probe_bin: u32 = 0;
pub var probe_phase: u32 = 0;

const frame_clocks: i64 = 262 * 3420;

/// Master clocks into the frame at the start of output sample `bin`.
fn probe_t(bin: u32) u32 {
    const q12 = (@as(i64, bin) << 12) - probe_phase;
    return @intCast(@max(0, @divFloor(q12 << 20, sound.q12_per_clock)));
}
