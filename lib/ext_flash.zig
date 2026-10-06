//! The fork firmware's external flash, spoken directly (our carts build
//! against the pinned SDK, which predates it): the badge's second 2 MB
//! chip mapped read-only at 0x11000000, and erase/program of its last
//! 256 KB (the cart-writable area) through mailbox 0x2B. The spec is the
//! fork's fork/EXT_FLASH.md and fork/ABI.md (adrian-computering/sycl-badge,
//! `feature/ext-flash`); the handshake below matches its
//! `platform_badge.ext_flash_request`.
//!
//! - Detection: `os_flags` (u16 at 0x200350EA) bit 2 = the chip is mapped,
//!   bit 5 = the firmware lists and launches a received cart
//!   (`feature/cart-transfer`, fork/CART_TRANSFER.md). The u32 at
//!   0x200350F8 holds the chip size in KB (low half) and the start of the
//!   cart area in KB (high half). Stock firmware leaves all of it 0.
//! - A request: an `ExtFlashRequest {op, offset, src, len}` (offset from the
//!   start of the chip, inside the cart area; `src` in cart RAM) in cart
//!   RAM, 4-aligned; the FIFO word `0x2B << 24 | (addr - 0x20000000) / 4`;
//!   the OS answers `0x2B << 24 | status` on the FIFO once it has erased one
//!   4 KB sector or programmed up to 4 KB (256-byte pages). Meanwhile
//!   core 0 has XIP off for both chips, so this core must not touch flash:
//!   a RAM cart, interrupts masked (PRIMASK), spinning on SIO and TIMER0
//!   registers only. The OS parks us ~45 ms per erase, ~10 ms per 4 KB
//!   program, up to ~300 ms at worst.
//! - The pinned runtime's `present` waits for FRAMEBUFFER_DONE
//!   (0x25000002) on the same FIFO. If that word arrives while we wait for
//!   our answer we consume it, and the runtime would then wait for a DONE
//!   that never comes (its 0.5 s timeout leaves it waiting forever). So
//!   when we swallow one we send an empty frame (FRAMEBUFFER_READY_V2 with
//!   no dirty rect) for the front buffer, which the OS answers with a fresh
//!   FRAMEBUFFER_DONE for `present` to find. The caller passes the front
//!   buffer index (`1 - cart.framebufferIndex()`). The FIFO handling lives
//!   in lib/os_mailbox.zig, shared with lib/cart_files.zig.
//!
//! Backends: `badge` on the cart core; `fake` on hosts (tests): an
//! in-memory chip that starts absent (`fake.present`); none in the wasm
//! simulator (no chip, so no 2 MB array in its memory).
const std = @import("std");
const builtin = @import("builtin");
const os_mailbox = @import("os_mailbox.zig");

/// The Cortex-M33 cart core; false for wasm and hosts.
pub const is_badge = builtin.os.tag == .freestanding and (builtin.cpu.arch.isThumb() or builtin.cpu.arch.isArm());
const is_wasm = builtin.cpu.arch.isWasm();

pub const os_flags_address: usize = 0x200350EA;
pub const flag_ext_flash: u16 = 1 << 2;
pub const flag_cart_transfer: u16 = 1 << 5;
/// Low u16: chip size in KB; high u16: start of the cart area in KB.
pub const geometry_address: usize = 0x200350F8;
/// The chip as memory (QMI window 1, cached).
pub const map_base: usize = 0x11000000;
/// Erase unit and the most one request may program.
pub const sector_size: u32 = 4096;
pub const page_size: u32 = 256;

pub const msg_type: u32 = 0x2B;
pub const Op = enum(u32) { erase = 1, program = 2 };
pub const Status = enum(u24) { ok = 0, unsupported = 1, out_of_range = 2, misaligned = 3, bad_buffer = 4, _ };
pub const Request = extern struct {
    op: Op,
    /// Byte offset from the start of the chip.
    offset: u32,
    /// Source address in cart RAM (program only).
    src: u32,
    len: u32,
};

pub const Error = error{ Unsupported, OutOfRange, Misaligned, BadBuffer, Timeout };

/// What the firmware reports.
pub const Info = struct {
    /// os_flags bit 2: the chip is mapped at `map_base`.
    mapped: bool = false,
    /// os_flags bit 5: the firmware lists and launches a received cart.
    cart_transfer: bool = false,
    chip_size: u32 = 0,
    /// Start of the cart area from the start of the chip, and its size.
    area_offset: u32 = 0,
    area_size: u32 = 0,

    /// A cart can be received: both flags, and an area of at least two
    /// sectors.
    pub fn can_receive(i: Info) bool {
        return i.mapped and i.cart_transfer and i.area_size >= 2 * sector_size;
    }
};

fn info_from(flags: u16, geometry: u32) Info {
    const size = (geometry & 0xFFFF) * 1024;
    const off = (geometry >> 16) * 1024;
    var i: Info = .{
        .mapped = flags & flag_ext_flash != 0,
        .cart_transfer = flags & flag_cart_transfer != 0,
        .chip_size = size,
    };
    if (i.mapped and off < size and off % sector_size == 0) {
        i.area_offset = off;
        i.area_size = size - off;
    }
    return i;
}

pub fn info() Info {
    if (comptime is_badge) {
        const flags: *const volatile u16 = @ptrFromInt(os_flags_address);
        const geometry: *const volatile u32 = @ptrFromInt(geometry_address);
        return info_from(flags.*, geometry.*);
    }
    if (comptime is_wasm) return .{};
    return fake.info();
}

/// The cart area as read-only memory, or null when the chip isn't mapped.
pub fn area() ?[]const u8 {
    const i = info();
    if (!i.mapped or i.area_size == 0) return null;
    if (comptime is_badge) {
        const p: [*]const u8 = @ptrFromInt(map_base + i.area_offset);
        return p[0..i.area_size];
    }
    if (comptime is_wasm) return null;
    return fake.chip[i.area_offset..][0..i.area_size];
}

/// Erase the 4 KB sector at `offset` in the cart area. Blocks ~45 ms.
pub fn erase(offset: u32, front: u1) Error!void {
    const i = info();
    if (!i.mapped) return error.Unsupported;
    if (offset % sector_size != 0) return error.Misaligned;
    if (offset >= i.area_size) return error.OutOfRange;
    if (comptime is_badge) return badge.request(.erase, i.area_offset + offset, 0, sector_size, front);
    if (comptime is_wasm) return error.Unsupported;
    return fake.erase(i.area_offset + offset);
}

/// Program `data` (at most 4 KB, a multiple of 256 bytes, in cart RAM)
/// at `offset` in the cart area, which must be erased. Blocks ~10 ms.
pub fn program(offset: u32, data: []const u8, front: u1) Error!void {
    const i = info();
    if (!i.mapped) return error.Unsupported;
    if (offset % page_size != 0 or data.len % page_size != 0) return error.Misaligned;
    if (data.len > sector_size) return error.OutOfRange;
    if (offset >= i.area_size or data.len > i.area_size - offset) return error.OutOfRange;
    if (comptime is_badge) return badge.request(.program, i.area_offset + offset, @intFromPtr(data.ptr), @intCast(data.len), front);
    if (comptime is_wasm) return error.Unsupported;
    return fake.program(i.area_offset + offset, data);
}

fn status_error(s: Status) Error!void {
    return switch (s) {
        .ok => {},
        .out_of_range => error.OutOfRange,
        .misaligned => error.Misaligned,
        .bad_buffer => error.BadBuffer,
        else => error.Unsupported,
    };
}

const badge = struct {
    const mailbox = os_mailbox.badge;
    /// Longest we wait for an answer (the OS's worst case is ~0.3 s).
    const timeout_us: u32 = 2_000_000;

    var req: Request align(4) = undefined;

    /// FIFO-answered: lib/os_mailbox.zig `wait_fifo` re-arms `present`
    /// when it swallows a FRAMEBUFFER_DONE (the top of this file).
    noinline fn request(op: Op, offset: u32, src: u32, len: u32, front: u1) Error!void {
        @as(*volatile Request, &req).* = .{ .op = op, .offset = offset, .src = src, .len = len };
        mailbox.dmb();
        const primask = mailbox.irq_disable();
        defer mailbox.irq_restore(primask);
        if (!mailbox.put(os_mailbox.word(msg_type, @intFromPtr(&req)), timeout_us)) return error.Timeout;
        const msg = mailbox.wait_fifo(msg_type, timeout_us, front) orelse return error.Timeout;
        return status_error(@fromBackingInt(@intCast(@as(u24, @truncate(msg)))));
    }
};

/// The host and simulator chip: absent until a test sets `present`.
pub const fake = struct {
    pub var present: bool = false;
    pub var cart_transfer: bool = true;
    pub const chip_kb: u32 = 2048;
    pub const area_kb: u32 = 256;
    pub var chip: [chip_kb * 1024]u8 = @splat(0xFF);
    pub var erases: u32 = 0;
    pub var programs: u32 = 0;

    fn info() Info {
        if (!present) return .{};
        const flags: u16 = flag_ext_flash | if (cart_transfer) flag_cart_transfer else 0;
        return info_from(flags, chip_kb | ((chip_kb - area_kb) << 16));
    }

    fn erase(at: u32) Error!void {
        @memset(chip[at..][0..sector_size], 0xFF);
        erases += 1;
    }

    fn program(at: u32, data: []const u8) Error!void {
        for (chip[at..][0..data.len], data) |*c, d| c.* &= d;
        programs += 1;
    }
};

test "ext_flash: geometry and flags" {
    try std.testing.expect(!info_from(0, 0).can_receive());
    // Fork e2.3 without cart transfer: mapped, no bit 5.
    const e23 = info_from(flag_ext_flash, 2048 | (1792 << 16));
    try std.testing.expect(e23.mapped and !e23.can_receive());
    try std.testing.expectEqual(@as(u32, 256 * 1024), e23.area_size);
    try std.testing.expectEqual(@as(u32, 1792 * 1024), e23.area_offset);
    const ok = info_from(flag_ext_flash | flag_cart_transfer, 2048 | (1792 << 16));
    try std.testing.expect(ok.can_receive());
    // Nonsense geometry: no area.
    try std.testing.expect(!info_from(flag_ext_flash | flag_cart_transfer, 2048 | (2048 << 16)).can_receive());
    // Bit 5 alone (no chip) is not enough.
    try std.testing.expect(!info_from(flag_cart_transfer, 2048 | (1792 << 16)).can_receive());
}

test "ext_flash: the fake erases and programs like NOR" {
    fake.present = true;
    defer fake.present = false;
    try std.testing.expect(info().can_receive());
    try erase(4096, 0);
    var page: [256]u8 = @splat(0x5A);
    try program(4096, &page, 0);
    try std.testing.expectEqual(@as(u8, 0x5A), area().?[4096 + 7]);
    page = @splat(0xF0);
    try program(4096, &page, 0);
    try std.testing.expectEqual(@as(u8, 0x50), area().?[4096 + 7]);
    try std.testing.expectError(error.Misaligned, erase(100, 0));
    try std.testing.expectError(error.Misaligned, program(4096, page[0..100], 0));
    try std.testing.expectError(error.OutOfRange, erase(256 * 1024, 0));
}
