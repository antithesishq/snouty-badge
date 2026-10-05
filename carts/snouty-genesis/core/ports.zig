//! What is plugged into the two pad ports (and the cartridge): one pad
//! (the default, port 2 empty), two pads, the Sega Team Player multitap on
//! port 1, port 2 or both, the EA 4 Way Play, or a Codemasters J-Cart.
//! docs/MULTIPLAYER.md has the protocols, their sources and the peripheral
//! table; `ports_table.zig` (generated) is the table itself.
//!
//! The console reads up to `max_pads` pad words per frame (`Md.pads`, set by
//! `Md.step_frame_pads`); which ones a game can see depends on `Config`.
//! `Config` is machine configuration, not state: it is chosen at power-on
//! (`detect`, or the menu's override) and kept by `Md.reset`; every badge
//! of a networked session must use the same one. `State` is console state
//! (keyframes, undo records, the state hash).
//!
//! Written from public documentation only (Plutiedev's "Sega multitap" and
//! "EA multitap" pages, the Team Player / 4 Way Play driver of Street
//! Racer as commented by r57shell, the J-Cart register as the emulation
//! community describes it); no emulator code was consulted.
//!
//! Pin levels: a port pin set as an output (control bit 1) is driven by the
//! data register, an input pin is pulled high, so a device sees
//! `out_level`. The device answers on the input pins (`lines`); bus.zig
//! mixes the two as the I/O chip does (`port_read`).
//!
//! Team Player (`tap*`), per tap: TH high = idle, the tap answers ID nibble
//! 3 with TL high. TH falling starts a transfer: nibble 0 is F; every TR
//! edge after that steps to the next nibble and TL follows TR (the
//! acknowledge games wait for; ours is immediate). Nibbles 1-2 are 0, 3-6
//! the device in slots A-D (0 3-button, 1 6-button, F none), then per
//! connected slot in order: R L D U, St A C B, and for a 6-button pad
//! Mode X Y Z, all active low. Past the end: F.
//!
//! 4 Way Play (`ea4way`): port 2 is all outputs and its bits 6-4 pick the
//! pad port 1 reads (0-3), 7 = the adapter's ID, which reads 0 on the
//! low data bits (bits 1-0 = 00 is how games detect it). TH comes from
//! port 1 as usual.
//!
//! J-Cart (`jcart`): pads 3 and 4 sit on the cartridge at 38FFFE: a word
//! read gives pad 4's lines in bits 13-8 and pad 3's in bits 5-0, each
//! with TH in bit 6 as a 3-button pad reads; bit 0 of a write to 38FFFE or
//! 38FFFF sets TH for both. Pads 1 and 2 are on the ports. The register
//! lives in the bus's SRAM window (`Md.sram` bytes 0-1, refreshed from
//! the pads at each frame and after a TH write), so the ROM read path
//! gets no new check.
const std = @import("std");
const md_mod = @import("md.zig");
const Md = md_mod.Md;
const Pad = md_mod.Pad;
const rom = @import("rom.zig");
const undo = @import("undo.zig");
const table = @import("ports_table.zig");

/// Pad words per frame the core takes (`Md.pads`): two Team Players.
pub const max_pads = 8;
pub const Pads = [max_pads]u16;

pub const Kind = enum(u8) {
    /// One pad on port 1, port 2 empty: the cart's behaviour before
    /// multiplayer, and every game's default.
    pad1 = 0,
    /// Pads 1 and 2 on ports 1 and 2.
    pads2 = 1,
    /// Team Player on port 1 (pads 1-4), a pad on port 2 (pad 5).
    tap1 = 2,
    /// A pad on port 1 (pad 1), Team Player on port 2 (pads 2-5).
    tap2 = 3,
    /// Team Players on both ports (pads 1-4 and 5-8).
    taps = 4,
    /// EA 4 Way Play on both ports (pads 1-4).
    ea4way = 5,
    /// Pads 1-2 on the ports, pads 3-4 on a J-Cart.
    jcart = 6,

    pub const count = 7;

    /// Pads the configuration lets a game read.
    pub fn pads(k: Kind) u8 {
        return switch (k) {
            .pad1 => 1,
            .pads2 => 2,
            .tap1, .tap2 => 5,
            .taps => 8,
            .ea4way, .jcart => 4,
        };
    }
};

pub const Config = struct {
    kind: Kind = .pad1,
    /// Pads (bit i = pad i + 1) that are 6-button pads; only a Team Player
    /// reports them as such (elsewhere every pad is a 3-button pad).
    six: u8 = 0,
    /// Pads not plugged in: a Team Player slot reports no device (ID F), a
    /// direct port or 4 Way Play pad reads as an empty port. For a
    /// session's start; a player who leaves mid-game keeps a released pad.
    absent: u8 = 0,
};

/// A poll the frontend may install (`Setup.poll_hook`): called a few times
/// inside every frame (`poll_lines`) so a network transport can drain its
/// receive ring during a long frame (docs/MULTIPLAYER.md). It must not
/// touch the console.
pub const PollHook = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque) void,
};

/// Lines between `poll_hook` calls (a call at lines 0, 64, 128 and 192).
pub const poll_lines: u32 = 64;

/// `Md.setup`: configuration, not console state; kept by `Md.reset`.
pub const Setup = struct {
    /// What is plugged in: chosen by `Md.init_in_place` (`detect`), or by
    /// the frontend before a `reset`.
    cfg: Config = .{},
    /// Lockstep mode: the console state must not depend on which frames or
    /// lines the frontend renders, so the renderer's sticky sprite
    /// overflow and collision bits are not kept (they read 0). Off: the
    /// behaviour before multiplayer.
    lockstep: bool = false,
    /// Called every `poll_lines` lines when set.
    poll_hook: ?PollHook = null,
};

/// Console state of the peripherals (`Md.ports`: keyframes, undo records,
/// the state hash).
pub const State = struct {
    /// This frame's pads (`Pad` bits), set by `Md.step_frame_pads`; pad 1
    /// first.
    pads: Pads = @splat(0),
    /// Team Player per port: nibbles stepped since TH fell.
    step: [2]u8 = @splat(0),
    /// TH (bit 6) and TR (bit 5) as each port's tap last saw them.
    seen: [2]u8 = @splat(0x60),
    /// J-Cart TH (bit 0 of the last write to 38FFFE/F).
    jcart_th: bool = true,
};

/// The J-Cart register's address (word): the two bytes the bus sees there.
pub const jcart_lo: u32 = 0x38FFFE;
pub const jcart_hi: u32 = 0x38FFFF;

/// Level of each pin as a device sees it: outputs from the data register,
/// inputs pulled high.
pub inline fn out_level(data: u8, ctrl: u8) u8 {
    return (data & ctrl & 0x7F) | (~ctrl & 0x7F);
}

/// The 3-button pad's lines, active low, with TH on bit 6 as selected:
/// TH high `1 TH C B R L D U`, TH low `1 TH St A 0 0 D U`.
pub noinline fn pad_lines(pad: u16, th: bool) u8 {
    var pressed: u8 = 0;
    if (pad & Pad.up != 0) pressed |= 0x01;
    if (pad & Pad.down != 0) pressed |= 0x02;
    if (th) {
        if (pad & Pad.left != 0) pressed |= 0x04;
        if (pad & Pad.right != 0) pressed |= 0x08;
        if (pad & Pad.b != 0) pressed |= 0x10;
        if (pad & Pad.c != 0) pressed |= 0x20;
        return 0x40 | (0x3F & ~pressed);
    }
    pressed |= 0x0C;
    if (pad & Pad.a != 0) pressed |= 0x10;
    if (pad & Pad.start != 0) pressed |= 0x20;
    return 0x3F & ~pressed;
}

/// Pad `i` on a direct port: its lines, or an empty port's.
noinline fn direct(md: *const Md, i: u3, th: bool) u8 {
    if (md.setup.cfg.absent >> i & 1 != 0) return 0x7F;
    return pad_lines(md.ports.pads[i], th);
}

/// The first pad behind the Team Player on port `p` (0 or 1), or null when
/// that port has none.
fn tap_base(k: Kind, p: u1) ?u3 {
    return switch (k) {
        .tap1 => if (p == 0) 0 else null,
        .tap2 => if (p == 1) 1 else null,
        .taps => if (p == 0) 0 else 4,
        else => null,
    };
}

/// The pad a direct port `p` holds under `k` (no tap there), or null.
fn port_pad(k: Kind, p: u1) ?u3 {
    return switch (k) {
        .pad1 => if (p == 0) 0 else null,
        .pads2, .jcart => p,
        .tap1 => if (p == 1) 4 else null,
        .tap2 => if (p == 0) 0 else null,
        .taps, .ea4way => null,
    };
}

/// The input lines of port `p` (0 = port 1, 1 = port 2) for `bus.zig`'s
/// data port read; `data`/`ctrl` are that port's registers.
pub noinline fn lines(md: *const Md, p: u1) u8 {
    @branchHint(.cold);
    const io = &md.io;
    const k = md.setup.cfg.kind;
    const th = io.ctrl[p] & 0x40 == 0 or io.data[p] & 0x40 != 0;
    if (port_pad(k, p)) |i| return direct(md, i, th);
    if (tap_base(k, p)) |base| return tap_lines(md, p, base);
    if (k == .ea4way and p == 0) {
        const sel: u3 = @truncate(out_level(io.data[1], io.ctrl[1]) >> 4);
        if (sel < 4) return direct(md, sel, th);
        return 0x70;
    }
    return 0x7F;
}

/// A port's data or control register was written: a Team Player there
/// follows TH and TR.
pub noinline fn port_written(md: *Md, p: u1) void {
    @branchHint(.cold);
    const k = md.setup.cfg.kind;
    if (tap_base(k, p) == null) return;
    const lv = out_level(md.io.data[p], md.io.ctrl[p]) & 0x60;
    const st = &md.ports;
    const was = st.seen[p];
    if (lv & 0x40 != 0 or was & 0x40 != 0) {
        // Idle, or TH just fell: the transfer starts over.
        st.step[p] = 0;
    } else if ((lv ^ was) & 0x20 != 0) {
        st.step[p] +|= 1;
    }
    st.seen[p] = lv;
}

/// The Team Player's answer: `0 1 1 TL d3 d2 d1 d0` (TH and TR are the
/// console's outputs, read back from the data register by bus.zig).
fn tap_lines(md: *const Md, p: u1, base: u3) u8 {
    const st = &md.ports;
    const lv = st.seen[p];
    if (lv & 0x40 != 0) return 0x70 | 0x03;
    const tl: u8 = if (lv & 0x20 != 0) 0x10 else 0;
    return 0x60 | tl | tap_nibble(md, base, st.step[p]);
}

/// Slot `s` (0-3) of the tap whose slot A is pad `base`: 0 3-button, 1
/// 6-button, F none.
fn slot_id(md: *const Md, base: u3, s: u2) u4 {
    const i: u3 = base +% s;
    if (md.setup.cfg.absent >> i & 1 != 0) return 0xF;
    return if (md.setup.cfg.six >> i & 1 != 0) 1 else 0;
}

noinline fn tap_nibble(md: *const Md, base: u3, step: u8) u4 {
    switch (step) {
        0 => return 0xF,
        1, 2 => return 0,
        3...6 => return slot_id(md, base, @intCast(step - 3)),
        else => {},
    }
    var k: u32 = step - 7;
    var s: u3 = 0;
    while (s < 4) : (s += 1) {
        const id = slot_id(md, base, @intCast(s));
        const n: u32 = switch (id) {
            0 => 2,
            1 => 3,
            else => 0,
        };
        if (k < n) return pad_nibble(md.ports.pads[base +% s], @intCast(k));
        k -= n;
    }
    return 0xF;
}

/// Nibble `k` of a pad behind a Team Player, active low: 0 R L D U, 1 St A
/// C B, 2 Mode X Y Z.
pub fn pad_nibble(pad: u16, k: u2) u4 {
    const v: u16 = switch (k) {
        0 => pad & 0xF,
        1 => (pad >> 4 & 1) << 2 | (pad >> 5 & 1) | (pad >> 6 & 1) << 1 | (pad >> 7 & 1) << 3,
        else => (pad >> 8 & 1) << 2 | (pad >> 9 & 1) << 1 | (pad >> 10 & 1) | (pad >> 11 & 1) << 3,
    };
    return @truncate(~v);
}

// ---- J-Cart ----

/// Power-on: map the J-Cart register into the bus's SRAM window.
pub fn jcart_map() rom.SramMap {
    return .{ .lo = jcart_lo, .hi = jcart_hi };
}

/// Recompute the register's two bytes from pads 3 and 4 and TH.
pub fn jcart_refresh(md: *Md) void {
    const th = md.ports.jcart_th;
    const hi = direct(md, 3, th);
    const lo = direct(md, 2, th);
    if (md.sram[0] == hi and md.sram[1] == lo) return;
    undo.touch_sr(0);
    md.sram[0] = hi;
    md.sram[1] = lo;
}

/// A byte write into the register: bit 0 is TH.
pub fn jcart_write(md: *Md, v: u8) void {
    md.ports.jcart_th = v & 1 != 0;
    jcart_refresh(md);
}

// ---- Choosing the peripheral at power-on ----

/// Header bytes 0x180-0x19F (serial, checksum, device field). Not unrolled:
/// this runs once per ROM and the RAM cart pays for code in RAM.
fn header_bytes(src: *const rom.RomSource) [32]u8 {
    var out: [32]u8 = undefined;
    var n: u32 = out.len;
    std.mem.doNotOptimizeAway(&n);
    var i: u32 = 0;
    while (i < n) : (i += 1) out[i] = header_byte(src, 0x180 + i);
    return out;
}

/// A call per byte keeps LLVM from unrolling the loop above.
noinline fn header_byte(src: *const rom.RomSource, a: u32) u8 {
    return rom.read8(src, a);
}

/// The peripheral for `src`: its row in the table (serial, and the header
/// checksum where the serial is a placeholder), else a Team Player on port
/// 1 when the header's device field (0x190-0x19F) declares '4' (Sega's
/// code for multitap support), else one pad.
pub noinline fn detect(src: *const rom.RomSource) Config {
    @branchHint(.cold);
    if (src.size < rom.header_end) return .{};
    const b = header_bytes(src);
    // The serial's hash, and that hash continued over the checksum's two
    // bytes (the key of a placeholder serial's row).
    var h: u32 = 0x811C9DC5;
    var n: u32 = 16;
    std.mem.doNotOptimizeAway(&n);
    var i: u32 = 0;
    var serial: u32 = 0;
    while (i < n) : (i += 1) {
        if (i == 14) serial = h;
        h = (h ^ b[i]) *% 0x01000193;
    }
    i = 0;
    while (i < table.count) : (i += 1) {
        const row = table.rows[i];
        const key = row & ~table.kind_mask;
        if (key == serial & ~table.kind_mask or key == h & ~table.kind_mask)
            return .{ .kind = @fromBackingInt(@intCast(row & table.kind_mask)) };
    }
    i = 16;
    while (i < n + 16) : (i += 1) if (b[i] == '4') return .{ .kind = .tap1 };
    return .{};
}
