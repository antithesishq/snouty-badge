//! TEMPORARY stand-in for lib/lockstep.zig (being extracted from Snouty
//! GC's net.zig by another track): the same API shape, never connected
//! (`state()` is `.offline` without link hardware, `.searching` with it).
//! Lets deathmatch.zig build and preview before the real one lands; the
//! import in deathmatch.zig switches to the real module then.
const std = @import("std");

pub const State = enum(u8) { offline, searching, wrong_cart, lobby, racing, waiting, peer_left, desync };
pub const Left = enum(u8) { none, unplugged, restarted, quit };
pub const Role = enum(u8) { none, host, guest };

pub fn app_name(id: u8) []const u8 {
    return switch (id) {
        'G' => "SNOUTY GC",
        'B' => "SNOUTY BOY",
        'Z' => "SNOUTY ZERO",
        'C' => "SNOUTY CYCLES",
        'S' => "SNOUTENSTEIN",
        else => "?",
    };
}

pub fn Lockstep(comptime L: type, comptime G: type) type {
    return struct {
        const Self = @This();
        link: L,
        role: Role = .none,
        left: Left = .none,
        paused: bool = false,
        offline: bool,
        rules_v: [G.rules_len]u8 = @splat(0),
        ready: bool = false,

        pub fn init(l: L) Self {
            return .{ .link = l, .offline = l.state == .unavailable };
        }
        pub fn pump(self: *Self, now: u64) void {
            if (self.offline) return;
            self.link.poll(now);
        }
        pub fn state(self: *const Self) State {
            return if (self.offline) .offline else .searching;
        }
        pub fn local_slot(self: *const Self) u1 {
            return if (self.role == .guest) 1 else 0;
        }
        pub fn set_rules(self: *Self, r: [G.rules_len]u8) void {
            self.rules_v = r;
        }
        pub fn rules(self: *const Self) ?[G.rules_len]u8 {
            return self.rules_v;
        }
        pub fn set_pick(self: *Self, pick: u8, ready: bool) void {
            _ = pick;
            self.ready = ready;
        }
        pub fn peer_pick(_: *const Self) ?u8 {
            return null;
        }
        pub fn peer_ready(_: *const Self) bool {
            return false;
        }
        pub fn can_go(_: *const Self) bool {
            return false;
        }
        pub fn go(_: *Self, _: u64) bool {
            return false;
        }
        pub fn take_started(_: *Self) bool {
            return false;
        }
        pub fn leave(_: *Self, _: u64) void {}
        pub fn submit(_: *Self, _: u64, _: u8) void {}
        pub fn step(_: *Self, _: *G.World) bool {
            return false;
        }
        pub fn seed(_: *const Self) u32 {
            return 1;
        }
        pub fn busy(_: *const Self) bool {
            return false;
        }
    };
}
