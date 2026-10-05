//! The fork firmware's cart serial port (the "SYCL Badge Cart Serial" USB
//! port, `/home/exedev/sycl-badge-fork` branch `feature/cart-serial`,
//! `fork/CART_SERIAL.md` section "Cart ABI (for other SDKs)"), spoken
//! directly: our carts build against the pinned SDK, which has no
//! `cart.serial`. docs/LOCKSTEP_N.md; the lobby protocol on top is
//! lib/party.zig.
//!
//! The ABI (frozen by the OS session, 2026-10-05):
//! - `ipc_data.os_flags` (u16 at 0x200350EA) bit 1 = cart serial supported.
//!   Stock firmware leaves it 0.
//! - `ipc_data.cart_serial` (u32 at 0x200350F4) = the address of a
//!   `CartSerialRings` in cart RAM, 0 while closed. The OS zeroes it at
//!   cart start and detaches at cart stop.
//! - Two single-producer single-consumer byte rings with free-running u32
//!   indices: `write - read` is the number of queued bytes, byte i lives at
//!   `buf[i & (cap - 1)]`. Writers store the data, `dmb`, then the index;
//!   readers load the index, `dmb`, then the data.
//! - rx (host -> cart) is lossless: when it is full the OS stops taking USB
//!   data and the host blocks. tx bytes are discarded while no host program
//!   has the port open (status bit 0 clear).
//!
//! `Badge(.{})` is the port carts use (static rings, 4 KiB in and 1 KiB
//! out by default; on a host build every call is a no-op and `supported`
//! is false). `Virtual(.{})` has the same interface with the rings inside
//! the value and the OS side exposed, for host tests (lib/party_virtual.zig
//! plays the OS and `badge lobby` with it).
const std = @import("std");
const builtin = @import("builtin");

/// The Cortex-M33 cart core; false for wasm and hosts.
pub const is_badge = builtin.os.tag == .freestanding and (builtin.cpu.arch.isThumb() or builtin.cpu.arch.isArm());

/// "SER1".
pub const magic: u32 = 0x53455231;
/// `ipc_data.os_flags` (u16); bit 1 = cart serial supported.
pub const os_flags_address: usize = 0x200350EA;
pub const os_flag_supported: u16 = 1 << 1;
/// `ipc_data.cart_serial` (u32): the address of the rings, 0 = closed.
pub const cart_serial_address: usize = 0x200350F4;

/// `status` bits, written by the OS only.
pub const status_host_open: u32 = 1 << 0;
pub const status_attached: u32 = 1 << 1;

/// The OS's `CartSerialRings` (os_abi.zig), 40 bytes, little-endian. The
/// buffer addresses are u32 here (the badge's pointers), so the host tests
/// can hold the same struct; off the badge they are never dereferenced.
pub const CartSerialRings = extern struct {
    magic: u32 = magic,
    rx_buf: u32,
    rx_cap: u32,
    /// Written by the OS.
    rx_write: u32 = 0,
    /// Written by the cart.
    rx_read: u32 = 0,
    tx_buf: u32,
    tx_cap: u32,
    /// Written by the cart.
    tx_write: u32 = 0,
    /// Written by the OS.
    tx_read: u32 = 0,
    /// Written by the OS: bit 0 host open (DTR), bit 1 attached.
    status: u32 = 0,

    comptime {
        std.debug.assert(@sizeOf(CartSerialRings) == 40);
        std.debug.assert(@offsetOf(CartSerialRings, "rx_write") == 12);
        std.debug.assert(@offsetOf(CartSerialRings, "tx_read") == 32);
        std.debug.assert(@offsetOf(CartSerialRings, "status") == 36);
    }
};

/// Ring sizes: powers of two, at least 64 (the OS checks). The receive
/// ring is the one that matters: the relay never drops a frame for a
/// connected player, and removes a player whose cart stopped reading
/// (more than 64 KiB waiting for 1 s, or 1 MiB), so drain it every frame
/// (docs/LOCKSTEP_N.md, "Transport requirements"). 4 KiB holds about 45
/// ticks of a 16-badge race (15 x 6 bytes a tick).
pub const Options = struct {
    rx_size: u32 = 4096,
    tx_size: u32 = 1024,
};

fn valid_size(n: u32) bool {
    return n >= 64 and n & (n - 1) == 0;
}

inline fn dmb() void {
    if (comptime is_badge) asm volatile ("dmb" ::: .{ .memory = true });
}

/// The header and both rings in one block of cart RAM.
pub fn Storage(comptime rx_size: u32, comptime tx_size: u32) type {
    comptime {
        if (!valid_size(rx_size)) @compileError("cart_serial: rx_size must be a power of two >= 64");
        if (!valid_size(tx_size)) @compileError("cart_serial: tx_size must be a power of two >= 64");
    }
    return extern struct {
        const Self = @This();
        hdr: CartSerialRings align(4),
        rx: [rx_size]u8,
        tx: [tx_size]u8,

        fn h(s: *Self) *volatile CartSerialRings {
            return &s.hdr;
        }

        /// Fill the header with zeroed indices (before publishing it).
        pub fn reset(s: *Self) void {
            s.h().* = .{
                .rx_buf = @truncate(@intFromPtr(&s.rx)),
                .rx_cap = rx_size,
                .tx_buf = @truncate(@intFromPtr(&s.tx)),
                .tx_cap = tx_size,
            };
        }

        // ---- the cart side ----

        /// Bytes waiting to be read.
        pub fn available(s: *Self) u32 {
            const r = s.h();
            return r.rx_write -% r.rx_read;
        }

        /// Copy received bytes into `buf`; the count.
        pub fn read(s: *Self, buf: []u8) usize {
            const r = s.h();
            const w = r.rx_write;
            const rd = r.rx_read;
            const n: u32 = @min(w -% rd, @as(u32, @intCast(@min(buf.len, rx_size))));
            if (n == 0) return 0;
            // The index before the data it covers.
            dmb();
            for (buf[0..n], 0..) |*b, i| b.* = s.rx[(rd +% @as(u32, @intCast(i))) & (rx_size - 1)];
            // The data read before the space is handed back.
            dmb();
            r.rx_read = rd +% n;
            return n;
        }

        /// Bytes `write` takes now.
        pub fn space(s: *Self) u32 {
            const r = s.h();
            return tx_size - (r.tx_write -% r.tx_read);
        }

        /// Queue bytes for the host; the count (less than `bytes.len` when
        /// the ring is full).
        pub fn write(s: *Self, bytes: []const u8) usize {
            const r = s.h();
            const rd = r.tx_read;
            const w = r.tx_write;
            const n: u32 = @min(tx_size - (w -% rd), @as(u32, @intCast(@min(bytes.len, tx_size))));
            if (n == 0) return 0;
            dmb();
            for (bytes[0..n], 0..) |b, i| s.tx[(w +% @as(u32, @intCast(i))) & (tx_size - 1)] = b;
            // The data before the index that covers it.
            dmb();
            r.tx_write = w +% n;
            return n;
        }

        // ---- the OS side (host tests) ----

        /// Put bytes into the receive ring as far as they fit; the count
        /// (the rest waits: USB back-pressure).
        pub fn os_put(s: *Self, bytes: []const u8) usize {
            const r = s.h();
            const w = r.rx_write;
            const n: u32 = @min(rx_size - (w -% r.rx_read), @as(u32, @intCast(@min(bytes.len, rx_size))));
            for (bytes[0..n], 0..) |b, i| s.rx[(w +% @as(u32, @intCast(i))) & (rx_size - 1)] = b;
            r.rx_write = w +% n;
            return n;
        }

        /// Room in the receive ring.
        pub fn os_room(s: *Self) u32 {
            const r = s.h();
            return rx_size - (r.rx_write -% r.rx_read);
        }

        /// Take what the cart wrote (up to `buf.len`); the count.
        pub fn os_take(s: *Self, buf: []u8) usize {
            const r = s.h();
            const rd = r.tx_read;
            const n: u32 = @min(r.tx_write -% rd, @as(u32, @intCast(@min(buf.len, tx_size))));
            for (buf[0..n], 0..) |*b, i| b.* = s.tx[(rd +% @as(u32, @intCast(i))) & (tx_size - 1)];
            r.tx_read = rd +% n;
            return n;
        }
    };
}

/// The port on the badge: static rings (`opts` sizes; each distinct
/// `opts` is its own RAM), published at `ipc_data.cart_serial`. A value of
/// this type holds nothing; every instance is the one port. Off the badge
/// `supported` is false and nothing touches memory-mapped addresses.
pub fn Badge(comptime opts: Options) type {
    return struct {
        const Self = @This();
        const S = Storage(opts.rx_size, opts.tx_size);
        var store: S = undefined;

        fn os_flags() *volatile u16 {
            return @ptrFromInt(os_flags_address);
        }
        fn slot() *volatile u32 {
            return @ptrFromInt(cart_serial_address);
        }
        fn mine() u32 {
            return @truncate(@intFromPtr(&store.hdr));
        }

        /// The firmware serves the port (`os_flags` bit 1).
        pub fn supported(_: *Self) bool {
            if (comptime !is_badge) return false;
            return os_flags().* & os_flag_supported != 0;
        }

        /// Publish the rings (zeroed indices). False without firmware
        /// support. Opening an open port does nothing.
        pub fn open(self: *Self) bool {
            if (!self.supported()) return false;
            if (slot().* == mine()) return true;
            store.reset();
            dmb();
            slot().* = mine();
            return true;
        }

        /// Unpublish (queued bytes both ways are dropped). The OS also
        /// detaches at cart exit.
        pub fn close(_: *Self) void {
            if (comptime !is_badge) return;
            slot().* = 0;
        }

        /// The rings are published (the OS zeroes the slot at cart start).
        pub fn is_open(_: *Self) bool {
            if (comptime !is_badge) return false;
            return slot().* == mine();
        }

        /// A host program has the port open (status bit 0).
        pub fn connected(self: *Self) bool {
            if (!self.is_open()) return false;
            const st: *volatile u32 = &store.hdr.status;
            return st.* & status_host_open != 0;
        }

        pub fn available(self: *Self) u32 {
            if (!self.is_open()) return 0;
            return store.available();
        }
        pub fn read(self: *Self, buf: []u8) usize {
            if (!self.is_open()) return 0;
            return store.read(buf);
        }
        pub fn space(self: *Self) u32 {
            if (!self.is_open()) return 0;
            return store.space();
        }
        pub fn write(self: *Self, bytes: []const u8) usize {
            if (!self.is_open()) return 0;
            return store.write(bytes);
        }
    };
}

/// A port for host tests: the same interface, the rings in the value, and
/// the OS side (`os_*`, `host_open`, `os_supported`) for the test to drive.
pub fn Virtual(comptime opts: Options) type {
    return struct {
        const Self = @This();
        pub const S = Storage(opts.rx_size, opts.tx_size);
        store: S = undefined,
        /// `os_flags` bit 1 (false: stock firmware).
        os_supported: bool = true,
        opened: bool = false,
        /// Status bit 0: a host program has the port open.
        host_open: bool = false,
        /// The cart stopped reading long ago (a stuck cart): `read` sees
        /// nothing and the OS finds the receive ring full.
        deaf: bool = false,

        pub fn supported(self: *Self) bool {
            return self.os_supported;
        }
        pub fn open(self: *Self) bool {
            if (!self.os_supported) return false;
            if (self.opened) return true;
            self.store.reset();
            self.opened = true;
            return true;
        }
        pub fn close(self: *Self) void {
            self.opened = false;
        }
        pub fn is_open(self: *Self) bool {
            return self.opened;
        }
        pub fn connected(self: *Self) bool {
            return self.opened and self.host_open;
        }
        pub fn available(self: *Self) u32 {
            if (!self.opened or self.deaf) return 0;
            return self.store.available();
        }
        pub fn read(self: *Self, buf: []u8) usize {
            if (!self.opened or self.deaf) return 0;
            return self.store.read(buf);
        }
        pub fn space(self: *Self) u32 {
            if (!self.opened) return 0;
            return self.store.space();
        }
        pub fn write(self: *Self, bytes: []const u8) usize {
            if (!self.opened) return 0;
            return self.store.write(bytes);
        }

        // ---- the OS side ----
        pub fn os_put(self: *Self, bytes: []const u8) usize {
            if (!self.opened) return bytes.len; // nobody has the port: discarded
            if (self.deaf) return 0; // its ring filled long ago
            return self.store.os_put(bytes);
        }
        pub fn os_room(self: *Self) u32 {
            if (!self.opened) return std.math.maxInt(u32);
            return self.store.os_room();
        }
        /// What the cart wrote; discarded (counted, not returned) while no
        /// host program has the port open, as the OS does.
        pub fn os_take(self: *Self, buf: []u8) usize {
            if (!self.opened) return 0;
            if (!self.host_open) {
                var sink: [256]u8 = undefined;
                while (self.store.os_take(&sink) > 0) {}
                return 0;
            }
            return self.store.os_take(buf);
        }
    };
}

test "CartSerialRings layout" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(CartSerialRings));
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(Badge(.{})));
}

test "free-running indices wrap at 2^32, not at the capacity" {
    var v: Virtual(.{ .rx_size = 64, .tx_size = 64 }) = .{};
    try std.testing.expect(v.open());
    v.host_open = true;
    // Both rings start just below the u32 wrap.
    const start: u32 = 0xFFFF_FFF0;
    v.store.hdr.rx_write = start;
    v.store.hdr.rx_read = start;
    v.store.hdr.tx_write = start;
    v.store.hdr.tx_read = start;
    var buf: [100]u8 = undefined;
    var src: [100]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i);
    try std.testing.expectEqual(@as(usize, 64), v.os_put(&src));
    try std.testing.expectEqual(@as(usize, 0), v.os_put(&src)); // full
    try std.testing.expectEqual(@as(u32, 64), v.available());
    try std.testing.expectEqual(@as(usize, 40), v.read(buf[0..40]));
    try std.testing.expectEqualSlices(u8, src[0..40], buf[0..40]);
    try std.testing.expectEqual(@as(usize, 24), v.read(&buf));
    try std.testing.expectEqualSlices(u8, src[40..64], buf[0..24]);
    try std.testing.expectEqual(@as(u32, 0x30), v.store.hdr.rx_read);
    try std.testing.expectEqual(@as(u32, 64), v.space());
    try std.testing.expectEqual(@as(usize, 64), v.write(&src));
    try std.testing.expectEqual(@as(usize, 0), v.write(&src));
    try std.testing.expectEqual(@as(usize, 64), v.os_take(&buf));
    try std.testing.expectEqualSlices(u8, src[0..64], buf[0..64]);
    // Host closed: tx is discarded.
    v.host_open = false;
    _ = v.write(src[0..10]);
    try std.testing.expectEqual(@as(usize, 0), v.os_take(&buf));
    try std.testing.expectEqual(@as(u32, 64), v.space());
}

test "badge port off the badge is unsupported and inert" {
    var p: Badge(.{}) = .{};
    try std.testing.expect(!p.supported());
    try std.testing.expect(!p.open());
    try std.testing.expect(!p.connected());
    try std.testing.expectEqual(@as(usize, 0), p.write("x"));
}
