//! Two-player link cable play (docs/LINK_PLAY.md): two badges
//! joined by the link cable (root docs/LINK.md) run one Genesis in
//! deterministic lockstep over lib/lockstep.zig (root docs/LOCKSTEP.md).
//! Only the pads cross the cable: one byte per badge per tick. The host
//! (the badge whose link nonce is higher) is pad 1, the guest pad 2.
//!
//! A module of its own (`linkplay`, cart-api-free, generic over the link)
//! so the host tests run two of them over lib/link_virtual.zig with the
//! real console (tests/link_play.zig). app.zig owns the badge's session
//! (`Session(link.Badge)`), frontend/link_lobby.zig draws its screen.
//!
//! One lockstep tick is one badge update: the two Genesis frames of the
//! 30 Hz update (`core.tunables.render_every`), both with the tick's pads,
//! the second rendered. The badge samples its buttons once an update, so
//! nothing is lost, and lockstep's one step per frame is one per update.
//! Input delay 2 ticks = 4 Genesis frames (67 ms).
//!
//! The wire byte is the Genesis 3-button pad as the sender mapped it (its
//! own Buttons setting; a receiver needs nobody's layout), with Up and
//! Down on bits 6 and 7: lockstep clears bits 6 and 7 when both are set
//! (they would make the SLIP bytes 0xC0 / 0xDB), and Up with Down is the
//! one pair a d-pad never holds, so the clipped combination loses nothing.
const std = @import("std");
const core = @import("core");
const lockstep = @import("lockstep");

const Pad = core.Pad;

/// The HELLO app id (root docs/LOCKSTEP.md section 6).
pub const app_id: u8 = lockstep.apps.genesis;

/// The byte a badge sends for its pad (`core.Pad` bits 0-7): bit 0 Left,
/// 1 Right, 2 A, 3 B, 4 C, 5 Start, 6 Up, 7 Down.
pub inline fn wire_byte(pad: u16) u8 {
    const p: u8 = @truncate(pad);
    return (p >> 2) | (p << 6);
}

/// The pad word of a wire byte (`wire_byte` inverted).
pub inline fn pad_of(byte: u8) u16 {
    return @as(u16, (byte << 2) | (byte >> 6));
}

/// The build variant in the rules: the RAM cart (Z80 stub) and the full
/// core (XIP cart, simulator, host tests) are different machines, so a
/// guest on the other one never readies (OTHER BUILD).
pub const Variant = enum(u8) { ram = 0, full = 1 };
pub const this_variant: Variant = if (core.tunables.z80_enabled) .full else .ram;

/// The host's rules: the ROM's CRC32 (little-endian), the peripheral the
/// race plugs in (`ports.Kind`) and the build variant.
pub const rules_len = 6;
pub const Rules = [rules_len]u8;

pub fn make_rules(crc: u32, kind: core.ports.Kind, variant: Variant) Rules {
    var r: Rules = undefined;
    std.mem.writeInt(u32, r[0..4], crc, .little);
    r[4] = @backingInt(kind);
    r[5] = @backingInt(variant);
    return r;
}

pub fn rules_crc(r: *const Rules) u32 {
    return std.mem.readInt(u32, r[0..4], .little);
}

pub fn rules_kind(r: *const Rules) ?core.ports.Kind {
    if (r[4] >= core.ports.Kind.count) return null;
    return @fromBackingInt(r[4]);
}

/// What the race plugs in for a ROM whose own choice is `detected`
/// (core/ports.zig `detect`): a second pad where the game would have one
/// pad, else the game's multitap (pads 1 and 2 are on it, or on the ports
/// for a J-Cart or the 4 Way Play), so the host is pad 1 and the guest
/// pad 2 whatever the peripheral.
pub fn race_kind(detected: core.ports.Kind) core.ports.Kind {
    return if (detected == .pad1) .pads2 else detected;
}

/// The guest's verdict on the host's offer.
pub const Match = enum { checking, waiting_host, same, wrong_rom, other_build };

pub fn match(offer: ?Rules, crc_known: bool, crc: u32) Match {
    if (!crc_known) return .checking;
    const r = offer orelse return .waiting_host;
    if (r[5] != @backingInt(this_variant)) return .other_build;
    if (rules_crc(&r) != crc or rules_kind(&r) == null) return .wrong_rom;
    return .same;
}

/// The `G` of `Lockstep`: the World is the console (a pointer: it is the
/// frontend's static, ~140 KB).
pub const Game = struct {
    pub const rules_len = 6;
    /// Ticks (badge updates of two Genesis frames): 67 ms. The minimum
    /// lockstep allows; the cable's latency is far below a tick.
    pub const input_delay: u32 = 2;
    /// A state hash about once a second (`Md.state_hash`, ~150 KB read).
    pub const check_every: u32 = 32;
    /// The pick is unused; ready means "my ROM is the host's".
    pub const pick_bits: u8 = 1;
    /// Bump when the wire byte, the rules or what a tick does changes.
    pub const version: u4 = 1;

    pub const World = struct {
        md: *core.Md,
        /// Render the second frame of the next simulated tick.
        render: bool = false,
        /// Slots whose badge left: their pad is released from then on.
        gone: u2 = 0,
        /// Ticks simulated in this race.
        ticks: u32 = 0,
    };

    pub fn simulate(w: *World, in: [2]u8) void {
        var pads: core.Pads = @splat(0);
        pads[0] = pad_of(in[0]);
        pads[1] = pad_of(in[1]);
        var f: u32 = 1;
        while (f < frames_per_tick) : (f += 1) w.md.step_frame_pads(&pads, false);
        w.md.step_frame_pads(&pads, w.render);
        w.render = false;
        w.ticks += 1;
    }

    pub fn hash(w: *const World) u32 {
        return w.md.state_hash();
    }

    /// The partner left: lockstep feeds its slot 0 from now on (a
    /// released pad, so its player stands still); only noted here.
    pub fn hand_over(w: *World, slot: u1) void {
        w.gone |= @as(u2, 1) << slot;
    }

    /// Power-on for a race: the agreed peripheral, lockstep mode on.
    /// Cartridge SRAM is in RAM and starts zeroed, so nothing badge-local
    /// survives.
    pub fn start(w: *World, rules: *const Rules) void {
        const md = w.md;
        md.setup.cfg = .{ .kind = rules_kind(rules) orelse .pads2 };
        md.setup.lockstep = true;
        md.reset();
        w.render = false;
        w.gone = 0;
        w.ticks = 0;
    }
};

/// Genesis frames per tick: the update's (`render_every`).
pub const frames_per_tick: u32 = core.tunables.render_every;

/// A link session over the link type `L` (`link.Badge` on the badge, a
/// link over the virtual cable in the tests): the lockstep plus what the
/// frontend needs. The frontend calls `pump` at the top of every update
/// and from the console's poll hook, `lobby` while the link screen shows,
/// and `submit` + `step` instead of `step_frame` while a race runs.
pub fn Session(comptime L: type) type {
    return struct {
        const Self = @This();
        pub const Ls = lockstep.Lockstep(L, Game);

        ls: Ls,
        world: Game.World,
        /// This badge's ROM and what its race would plug in.
        crc: u32 = 0,
        crc_known: bool = false,
        kind: core.ports.Kind = .pads2,
        /// The link screen is open: this badge wants to play.
        want: bool = false,
        /// A race drives this badge's console.
        racing: bool = false,

        pub fn init(s: *Self, l: L, md: *core.Md) void {
            s.* = .{ .ls = Ls.init(l), .world = .{ .md = md } };
        }

        pub fn pump(s: *Self, now: u64) void {
            s.ls.pump(now);
        }

        /// The offer on the table against this badge's ROM (the host's
        /// own offer always matches).
        pub fn verdict(s: *const Self) Match {
            return match(s.ls.rules(), s.crc_known, s.crc);
        }

        /// One lobby frame: the host offers its ROM, peripheral and
        /// variant; each badge is ready while its link screen is open and
        /// its ROM matches; `go` (the host's A or Start) starts the race,
        /// which `take_start` (the top of every update) then picks up.
        pub fn lobby(s: *Self, now: u64, go: bool) void {
            const l = &s.ls;
            l.pump(now);
            if (l.state() != .lobby) return;
            if (l.role == .host and s.crc_known) l.set_rules(make_rules(s.crc, s.kind, this_variant));
            l.set_pick(1, s.want and s.verdict() == .same);
            if (go and l.role == .host and l.can_go()) _ = l.go(now);
        }

        /// Once per update on both badges: true when a race started (GO
        /// sent or heard), after resetting the console for it. Until then
        /// the console is this badge's own.
        pub fn take_start(s: *Self) bool {
            if (!s.ls.take_started()) return false;
            const r = s.ls.rules() orelse return false;
            Game.start(&s.world, &r);
            s.racing = true;
            return true;
        }

        /// This update's pad (`core.Pad` bits, this badge's mapping).
        pub fn submit(s: *Self, now: u64, pad: u16) void {
            s.ls.submit(now, wire_byte(pad));
        }

        /// Run the next tick if both pads for it are here; `render`: draw
        /// its second frame through the console's line sink.
        pub fn step(s: *Self, render: bool) bool {
            s.world.render = render;
            const ok = s.ls.step(&s.world);
            s.world.render = false;
            return ok;
        }

        /// Back to the lobby (after a desync, the partner leaving, or this
        /// badge's own Leave); the console keeps its state and plays on
        /// locally, lockstep mode off.
        pub fn leave(s: *Self, now: u64) void {
            s.ls.leave(now);
            s.racing = false;
            s.world.md.setup.lockstep = false;
        }
    };
}

comptime {
    // The wire byte round trips and puts Up and Down on bits 6 and 7 (a
    // few straight-line checks, no comptime loops: CLAUDE.md).
    if (wire_byte(Pad.up) != 0x40 or wire_byte(Pad.down) != 0x80) @compileError("wire: up/down");
    if (wire_byte(Pad.left) != 0x01 or wire_byte(Pad.start) != 0x20) @compileError("wire: left/start");
    if (pad_of(wire_byte(Pad.c | Pad.start | Pad.up)) != Pad.c | Pad.start | Pad.up) @compileError("wire: round trip");
    if (lockstep.sanitize(wire_byte(Pad.up | Pad.down | Pad.a)) != wire_byte(Pad.a)) @compileError("wire: up+down");
}
