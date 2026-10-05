//! LINK DUEL over the link cable (SPEC 10, PLAN M3 Track L): the thin
//! adapter between the shared lockstep and the game.
//!
//! The lockstep (`Lockstep(L, Glue)`, lib/lockstep.zig's API; see
//! `lockstep` below) owns the link, finds host and guest from the HELLO
//! nonces (host = slot 0 = the sim's cycle 0, so both Worlds are byte
//! equal), runs the lobby (the host's 4 rule bytes, a ready flag from each
//! badge, GO with a digest of the rules), then exchanges one input byte
//! per tick with an input delay of 3 and calls `Glue.simulate` once per
//! agreed tick on both badges. Its packets are 5 bytes, 8 on the wire,
//! always (inside the 8-byte receive FIFO). It hashes the Game every
//! `check_every` ticks (`Glue.hash`), and a differing hash piece stops it
//! (`desync`): the game shows NO CONTEST, both badges leave the race, and
//! the host starts a new one (a new race id, so a fresh seed) carrying the
//! match's wins in the rules. A partner gone (cable out, its cart
//! restarted, QUIT) makes it step on alone after `Glue.hand_over`: a T2
//! program rides the partner's cycle to the round's end, then the menu.
//!
//! The whole match is one race: the countdown, the rounds, the cards
//! between them and the rematch are all lockstep ticks (`game.duel_tick`),
//! so both badges change rounds on the same tick without a word. Pause is
//! the lockstep's pause bit (Start, `game.link_pause_bit`): both badges
//! pause and resume on the same tick.
//!
//! Per frame (main.zig, and the host tests): `begin` (pump, the lockstep's
//! state into `g.lk`, a started race into `g.duel_begin`), `g.update`,
//! `end` (the game's requests, the frame's byte, one `step`), a pump
//! between the sim and the render, and after the render `late` (pump and
//! retry the step until 14 ms into the frame, only while racing).
const std = @import("std");
const game = @import("game.zig");
/// The lockstep. STAND-IN: `lib/lockstep.zig` had not landed when Track L
/// was built; `lockstep_standin.zig` is Snouty GC's lockstep made generic
/// with the agreed API. Swap this import (and the build's module) for the
/// shared one.
pub const lockstep = @import("lockstep_standin.zig");

/// The HELLO app id: only another Snouty Cycles is a partner.
pub const app_id: u8 = 'C';

/// The game side of the lockstep.
pub const Glue = struct {
    pub const World = game.Game;
    pub const rules_len = game.link_rules_len;
    pub const app_id: u8 = 'C';
    /// The byte sampled on frame f drives tick f + 3 (SPEC 10).
    pub const input_delay: u32 = 3;
    pub const pause_bit: ?u8 = game.link_pause_bit;

    pub fn simulate(g: *game.Game, in: [2]u8) void {
        g.duel_tick(in);
    }
    /// The World's own FNV hash (sim.World.hash) plus the duel's state.
    pub fn hash(g: *const game.Game) u32 {
        return g.duel_hash();
    }
    pub fn hand_over(g: *game.Game, slot: u1) void {
        g.duel_hand_over(slot);
    }
};

/// Pump and retry until this far into the frame while racing (the vsync
/// wait is the one stretch where nothing empties the 8-byte FIFO).
pub const pump_until_us: u64 = 14_000;
/// Between two late pumps (the loop also retries the step).
pub const late_gap_us: u64 = 250;

pub fn Net(comptime L: type) type {
    return struct {
        const Self = @This();
        pub const LS = lockstep.Lockstep(L, Glue);

        ls: LS,
        /// This frame's step ran (the late loop retries it until it does).
        ticked: bool = false,

        pub fn init(l: L) Self {
            return .{ .ls = LS.init(l) };
        }

        pub fn pump(self: *Self, now: u64) void {
            self.ls.pump(now);
        }

        /// Top of the frame: pump, then the lockstep's state for the game.
        pub fn begin(self: *Self, g: *game.Game, now: u64) void {
            self.ls.pump(now);
            self.ticked = false;
            const lk = &g.lk;
            lk.status = switch (self.ls.state()) {
                inline else => |s| @field(game.LinkStatus, @tagName(s)),
            };
            lk.host = self.ls.role == .host;
            lk.partner_app = self.ls.partner_app();
            lk.paused = self.ls.paused;
            lk.can_go = self.ls.can_go();
            lk.heard = if (lk.host) null else self.ls.rules();
            self.take_started(g);
        }

        fn take_started(self: *Self, g: *game.Game) void {
            if (self.ls.take_started()) g.duel_begin(self.ls.seed, self.ls.race_rules, self.ls.local_slot());
        }

        /// After `g.update`: the game's requests (leave, rules, ready, go),
        /// then the frame's byte and one step.
        pub fn end(self: *Self, g: *game.Game, now: u64) void {
            const lk = &g.lk;
            const duel = g.duel_running() and !lk.demo;
            if (lk.want_leave or (!duel and self.ls.busy())) {
                lk.want_leave = false;
                self.ls.leave(now);
            }
            const in_lobby = g.mode == .link and g.state == .link_lobby;
            self.ls.set_pick(0, in_lobby and lk.ready);
            if (lk.host and in_lobby and !lk.resync) self.ls.set_rules(lk.rules());
            if (lk.want_go) {
                lk.want_go = false;
                if (lk.host) self.ls.set_rules(lk.rules());
                if (self.ls.go(now)) self.take_started(g);
            }
            if (g.duel_running() and !lk.demo) {
                self.ls.submit(now, lk.byte);
                // A frame the lockstep sat out (time sync) is not retried.
                self.ticked = self.ls.step(g) or self.ls.skipped;
            }
        }

        /// After the render, while `busy()`: pump and retry a step this
        /// frame has not had. main.zig loops it until `pump_until_us` into
        /// the frame (every `late_gap_us` in the host tests).
        pub fn retry(self: *Self, g: *game.Game, now: u64) void {
            self.ls.pump(now);
            if (!self.ticked and g.duel_running() and !g.lk.demo) self.ticked = self.ls.step(g) or self.ls.skipped;
        }

        /// Worth pumping in a loop until late in the frame: racing, or in
        /// LINK DUEL's screens with a partner on the wire (a HELLO is 10
        /// wire bytes, more than the 8-byte FIFO holds, so the handshake
        /// needs the receiver draining it as it arrives; docs/LINK.md:
        /// "poll in a loop while waiting for the partner"). False with no
        /// cable (the bench), so the loop never runs there.
        pub fn busy(self: *const Self, g: *const game.Game) bool {
            if (self.ls.busy()) return true;
            if (g.mode != .link) return false;
            return switch (self.ls.link.state) {
                .handshake, .connected => true,
                else => false,
            };
        }
    };
}
