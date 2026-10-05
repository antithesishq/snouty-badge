//! TEMPORARY stand-in for lib/lockstep.zig (being written in parallel):
//! the announced API with no protocol behind it (never leaves
//! `searching`), so the cart builds and the simulator previews run until
//! the shared module lands. build.zig maps the `lockstep` import here.
const std = @import("std");

pub const State = enum(u8) { offline, searching, wrong_cart, lobby, racing, waiting, peer_left, desync };
pub const Left = enum(u8) { none, unplugged, restarted, quit };
pub const Role = enum(u8) { none, host, guest };

pub fn app_name(id: u8) []const u8 {
    return switch (id) {
        'Z' => "SNOUTY ZERO",
        'G' => "SNOUTY GC",
        'C' => "SNOUTY CYCLES",
        'B' => "SNOUTY BOY",
        'L' => "SNOUTY LINK",
        else => "ANOTHER CART",
    };
}

pub fn hash_fields(comptime T: type, v: *const T) u32 {
    var h: u32 = 0x811C_9DC5;
    mix(T, v, &h);
    h ^= h >> 16;
    h *%= 0x85EB_CA6B;
    h ^= h >> 13;
    return h;
}

fn feed(h: *u32, x: u32) void {
    h.* = std.math.rotl(u32, h.* ^ x, 5) *% 0x9E37_79B1;
}

fn mix(comptime T: type, v: *const T, h: *u32) void {
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            if (s.layout == .@"packed") {
                const I = @Int(.unsigned, @bitSizeOf(T));
                return feed(h, @as(I, @bitCast(v.*)));
            }
            inline for (s.field_names, s.field_types) |name, F| mix(F, &@field(v.*, name), h);
        },
        .array => |a| for (v) |*x| mix(a.child, x, h),
        .@"enum" => feed(h, @backingInt(v.*)),
        .bool => feed(h, @intFromBool(v.*)),
        .int => feed(h, @as(@Int(.unsigned, @bitSizeOf(T)), @bitCast(v.*))),
        else => @compileError("hash_fields: unsupported field type " ++ @typeName(T)),
    }
}

pub fn Lockstep(comptime L: type, comptime G: type) type {
    return struct {
        const Self = @This();
        link: L,
        role: Role = .none,
        left: Left = .none,
        paused: bool = false,
        offline: bool,

        pub fn init(l: L) Self {
            return .{ .link = l, .offline = l.state == .unavailable };
        }
        pub fn pump(self: *Self, now: u64) void {
            if (!self.offline) self.link.poll(now);
        }
        pub fn state(self: *const Self) State {
            return if (self.offline) .offline else .searching;
        }
        pub fn busy(_: *const Self) bool {
            return false;
        }
        pub fn local_slot(self: *const Self) u1 {
            return if (self.role == .guest) 1 else 0;
        }
        pub fn set_rules(_: *Self, _: [G.rules_len]u8) void {}
        pub fn rules(_: *const Self) ?[G.rules_len]u8 {
            return null;
        }
        pub fn set_pick(_: *Self, _: u8, _: bool) void {}
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
        pub fn picks(_: *const Self) [2]u8 {
            return .{ 0, 0 };
        }
    };
}
