//! Who plays which Genesis pad (docs/MULTIPLAYER.md): the input-source
//! seam between the badge's controls and `Md.step_frame_pads`, and the
//! party source on top of it, `Session`: lib/lockstep_n.zig's `LockstepN`
//! with `Game` (the Genesis console as the lockstep World) over a cart
//! serial port. A module of its own (`players`, cart-api-free) so the host
//! tests run four `Session`s over lib/party_virtual.zig.
//!
//! Local source: the badge's pad (input.zig's mapped word) is player
//! `local_player` (player 1), every other pad is released.
//!
//! Party source: one tick = one Genesis frame; every badge submits one
//! byte per tick (`wire_byte`: the Genesis 3-button pad as the sender
//! mapped it, bits U D L R A B C Start = `core.Pad` bits 0-7, so a receiver
//! needs nobody's button layout). The participants of a race are pads 1-n
//! in slot order (`Game.World.pad_of`), so a room whose ids are 0, 2 and
//! 5 still plays pads 1-3. A slot that is not present (left, dropped) reads
//! as a released pad from the hand-over tick on every badge.
const std = @import("std");
const core = @import("core");
const party_lib = @import("party_lib");
const lockstep_n = party_lib.lockstep_n;
const party = lockstep_n.party;

/// Player slots a session may have (`LockstepN`'s 16); the console reads
/// the first `core.max_pads` pads.
pub const max_slots = lockstep_n.max_slots;

/// The byte a badge sends for its pad: the mapped 3-button pad.
pub inline fn wire_byte(pad: u16) u8 {
    return @truncate(pad);
}

/// The console's pads from a tick's slot bytes, slot s on pad `pad_of[s]`
/// (0xFF: no pad); a slot not in `present` is a released pad, not an
/// unplugged one, so a game sees its player stand still rather than vanish.
pub fn pads_from_slots(in: *const [max_slots]u8, present: u16, pad_of: *const [max_slots]u8, out: *core.Pads) void {
    out.* = @splat(0);
    for (0..max_slots) |s| {
        const p = pad_of[s];
        if (p < core.max_pads and present >> @intCast(s) & 1 != 0) out[p] = in[s];
    }
}

// ---- The local source ----

/// The pad the badge drives alone (0 = player 1).
pub var local_player: u3 = 0;

/// The local source's pads for a frame: the badge's mapped pad on
/// `local_player`, the rest released.
pub fn local_pads(local_pad: u16, out: *core.Pads) void {
    out.* = @splat(0);
    out[local_player] = wire_byte(local_pad);
}

// ---- The party source ----

/// HELLO game ids (docs/LOCKSTEP_N.md section 8): one per build variant,
/// because the RAM cart (Z80 stub) and the XIP cart / simulator (Z80) are
/// different machines and must never share a room. Bump the last
/// character when the wire or the World changes.
pub const game_ram = party.pad(party.game_len, "SNGENRM1");
pub const game_full = party.pad(party.game_len, "SNGENFL1");

/// The host's rules: the ROM's CRC32 (little-endian) and the peripheral
/// (`ports.Kind`); a guest whose CRC differs never readies.
pub const rules_len = 5;
pub const Rules = [rules_len]u8;

pub fn make_rules(crc: u32, kind: core.ports.Kind) Rules {
    var r: Rules = undefined;
    std.mem.writeInt(u32, r[0..4], crc, .little);
    r[4] = @backingInt(kind);
    return r;
}

pub fn rules_crc(r: *const Rules) u32 {
    return std.mem.readInt(u32, r[0..4], .little);
}

pub fn rules_kind(r: *const Rules) ?core.ports.Kind {
    if (r[4] >= core.ports.Kind.count) return null;
    return @fromBackingInt(r[4]);
}

/// The `G` of `LockstepN`: the World is the console.
pub const Game = struct {
    pub const rules_len = 5;
    /// The default input delay (ticks; the host may pick 1-30, GO carries it).
    pub const input_delay: u32 = 3;
    /// Silence counts from a slot's last frame, so a 29 ms tick never
    /// trips it; 3 s of nothing does.
    pub const stall_drop_ms: u32 = 3000;
    pub const min_players: u8 = 2;
    /// One INPUT frame per tick (the default); 2 would send one per badge
    /// update.
    pub const send_every: u32 = 1;
    /// The pick is unused (bit 0 set: ready to race with a matching ROM).
    pub const pick_bits: u8 = 1;

    pub const World = struct {
        md: *core.Md,
        /// Render the next simulated tick (the frontend sets it for the
        /// last tick of an update).
        render: bool = false,
        /// Slot -> pad (0xFF: none), from the race's participants.
        pad_of: [max_slots]u8 = @splat(0xFF),
        /// Slots handed over (left or dropped) in this race.
        gone: u16 = 0,
        /// Ticks simulated in this race.
        ticks: u32 = 0,
    };

    pub fn simulate(w: *World, in: *const [16]u8, present: u16) void {
        var pads: core.Pads = undefined;
        pads_from_slots(in, present, &w.pad_of, &pads);
        w.md.step_frame_pads(&pads, w.render);
        w.render = false;
        w.ticks += 1;
    }

    pub fn hash(w: *const World) u32 {
        return w.md.state_hash();
    }

    /// The slot's pad is released from this tick (it is no longer in
    /// `present`); nothing in the console changes.
    pub fn hand_over(w: *World, slot: u4) void {
        w.gone |= @as(u16, 1) << slot;
    }

    /// Power-on for a race: the agreed peripheral, lockstep on, pads in
    /// slot order.
    pub fn start(w: *World, rules: *const Rules, participants: u16) void {
        const md = w.md;
        md.setup.cfg = .{ .kind = rules_kind(rules) orelse .pad1 };
        md.setup.lockstep = true;
        md.reset();
        w.pad_of = @splat(0xFF);
        var n: u8 = 0;
        for (0..max_slots) |s| {
            if (participants >> @intCast(s) & 1 == 0) continue;
            w.pad_of[s] = n;
            n += 1;
        }
        w.gone = 0;
        w.ticks = 0;
        w.render = false;
    }
};

/// A party session over the cart serial port `Port` (`cart_serial.Badge`
/// on the badge, `cart_serial.Virtual` in the tests). The frontend calls
/// `pump` at the top of every update and from the console's poll hook,
/// `lobby` while the lobby screen shows, and `ticks` instead of
/// `step_frame` while a race runs.
pub fn Session(comptime Port: type) type {
    return struct {
        const Self = @This();
        pub const Ls = lockstep_n.LockstepN(Port, Game);

        ls: Ls,
        world: Game.World,
        /// This badge's ROM (the host offers it; a guest compares).
        crc: u32 = 0,
        crc_known: bool = false,
        kind: core.ports.Kind = .pad1,
        /// The player wants to race (A in the lobby).
        want_ready: bool = false,
        /// A race is running on this badge's console.
        racing: bool = false,

        pub fn init(s: *Self, port: Port, game: [party.game_len]u8, name: [party.name_len]u8, md: *core.Md, entropy: u32) void {
            s.* = .{
                .ls = Ls.init(port, .{ .game = game, .name = name, .max_players = core.max_pads }, entropy),
                .world = .{ .md = md },
            };
        }

        pub fn pump(s: *Self, now: u64) void {
            s.ls.pump(now);
        }

        /// The rules on offer match this badge's ROM.
        pub fn rom_matches(s: *const Self) bool {
            const r = s.ls.rules() orelse return false;
            return s.crc_known and rules_crc(&r) == s.crc and rules_kind(&r) != null;
        }

        /// One lobby frame: the host offers this badge's ROM and peripheral,
        /// everyone readies only with a matching ROM; `start` (the host's
        /// Start) sends GO when it may. Returns true once a race started
        /// (the console has been reset for it).
        pub fn lobby(s: *Self, now: u64, start: bool) bool {
            const l = &s.ls;
            l.pump(now);
            if (l.state() == .lobby) {
                if (l.is_host() and s.crc_known) l.set_rules(make_rules(s.crc, s.kind));
                l.set_pick(1, s.want_ready and s.rom_matches());
                if (start and l.is_host() and l.can_go()) _ = l.go(now);
            }
            return s.take_start();
        }

        /// A race started (GO seen): reset the console for it.
        fn take_start(s: *Self) bool {
            if (!s.ls.take_started()) return false;
            const r = s.ls.rules() orelse return false;
            Game.start(&s.world, &r, s.ls.participants());
            s.racing = true;
            return true;
        }

        /// This badge's byte for the next tick it has not sent yet
        /// (`ls.local_hi`); at most `delay + 1` ahead of the ticks run.
        pub fn submit(s: *Self, now: u64, byte: u8) void {
            s.ls.submit(now, byte);
        }

        /// Run the next tick if every player's byte for it is in;
        /// `render`: draw it through the console's line sink.
        pub fn step(s: *Self, render: bool) bool {
            s.world.render = render;
            const ok = s.ls.step(&s.world);
            s.world.render = false;
            return ok;
        }

        /// Back to the lobby (after a desync, a drop, or the player's own
        /// leave); the console keeps its state but is no longer driven.
        pub fn leave(s: *Self, now: u64) void {
            s.ls.leave(now);
            s.racing = false;
            s.world.md.setup.lockstep = false;
        }

        pub fn networked(s: *const Self) bool {
            return s.racing;
        }
    };
}
