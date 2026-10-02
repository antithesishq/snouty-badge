//! The Lynx cartridge as the core sees it: a table of 256 block pointers.
//! SPEC.md sections 7 and 11. A Lynx cart is read through a block select
//! (the high address bits, latched by the game) plus a ripple counter that
//! walks the bytes of that block; the port logic itself belongs to
//! core/bus.zig and core/mikey.zig (M1). This file only knows where each
//! block's bytes are, and how a `.lnx`/`.lyx` file maps onto blocks.
//!
//! Bank 0 is 256 blocks of `block_size` bytes: 256 B (64 KB), 512 B
//! (128 KB), 1 KB (256 KB) or 2 KB (512 KB). Two file forms:
//!
//! - Headered (`.lnx`): 64 bytes starting "LYNX": bank 0 page size at 4
//!   (u16 LE; the block size in bytes, that is the bank size in 256-byte
//!   units), bank 1 at 6, version at 8, cart name 10..41, manufacturer
//!   42..57, rotation 58, AUDIN use 59, EEPROM type 60. The header is
//!   trusted; data follows at offset 64. Files may be shorter than the bank
//!   (homebrew often is): the missing bytes read 0xFF. Data past the
//!   declared bank (trailing padding) is ignored, up to the same 512 KB of
//!   data a headerless file may have: a headered file over 512 KB + 64
//!   bytes is refused like a headerless one over 512 KB, never clipped.
//! - Headerless (`.lyx`, or a raw dump named `.lnx`, SPEC.md 18.3): the
//!   block size is inferred from the file size, rounded up to the next
//!   supported bank (128 KB -> 512 B blocks, 256 KB -> 1 KB, 512 KB -> 2 KB).
//!
//! Refused (SPEC.md section 11, the same rules as tools/romcheck.py): a
//! bank 1, a rotated screen, an unknown bank 0 size, over 512 KB of data
//! (a headerless file over 512 KB, a headered one over 512 KB + the 64-byte
//! header), an empty file. An EEPROM is a warning, not a refusal (not emulated).
//!
//! Where the bytes live (embedded slice, the badge drive by pointer, the
//! 13.1 packed cache) is the frontend's business: no romfs, cart-api or
//! allocator import here. A block with a null pointer is served byte by
//! byte through `read_fallback` (a fragmented drive file) or from `slice`.
const std = @import("std");

pub const header_size = 64;
pub const block_count = 256;
/// Largest bank 0 (2 KB blocks).
pub const max_size: u32 = 512 * 1024;

pub const Refusal = enum {
    ok,
    empty,
    too_big,
    bad_bank0,
    bank1,
    rotation,

    pub fn text(r: Refusal) []const u8 {
        return switch (r) {
            .ok => "ok",
            .empty => "empty file",
            .too_big => "over 512 KB",
            .bad_bank0 => "bad bank 0 size",
            .bank1 => "has bank 1",
            .rotation => "rotated",
        };
    }
};

/// What a file's first bytes and its size say about it.
pub const Layout = struct {
    verdict: Refusal = .ok,
    /// True when the file starts with the 64-byte "LYNX" header.
    headered: bool = false,
    /// Where block 0 starts in the file (64 or 0).
    data_offset: u32 = 0,
    /// Bytes of cart data in the file (file size minus the header, capped
    /// at the bank size).
    data_size: u32 = 0,
    /// 256, 512, 1024 or 2048.
    block_size: u32 = 512,
    /// log2(block_size).
    block_shift: u5 = 9,
    version: u16 = 0,
    rotation: u8 = 0,
    audin: u8 = 0,
    eeprom: u8 = 0,
    /// Header name fields, NUL/space padded (zeros when headerless).
    name: [32]u8 = @splat(0),
    manufacturer: [16]u8 = @splat(0),

    /// Bank 0 size in bytes.
    pub fn bank_size(l: *const Layout) u32 {
        return l.block_size * block_count;
    }

    /// An EEPROM is declared: the cart runs without it (saves are lost).
    pub fn warn_eeprom(l: *const Layout) bool {
        return l.eeprom != 0;
    }

    /// The header's cart name, trimmed of NULs and spaces (empty if none).
    pub fn title(l: *const Layout) []const u8 {
        return trim(&l.name);
    }
};

/// Parse a file from its first bytes (`head`, at least 64 when the file is
/// that long; fewer only for a shorter file) and its full `file_size`.
pub fn parse(head: []const u8, file_size: u32) Layout {
    var l: Layout = .{};
    if (file_size == 0) return refuse(l, .empty);
    if (head.len >= header_size and std.mem.eql(u8, head[0..4], "LYNX")) {
        l.headered = true;
        l.data_offset = header_size;
        const bank0 = le16(head[4..6]);
        const bank1 = le16(head[6..8]);
        l.version = le16(head[8..10]);
        @memcpy(&l.name, head[10..42]);
        @memcpy(&l.manufacturer, head[42..58]);
        l.rotation = head[58];
        l.audin = head[59];
        l.eeprom = head[60];
        const shift = shift_for(bank0) orelse return refuse(l, .bad_bank0);
        l.block_size = bank0;
        l.block_shift = shift;
        if (bank1 != 0) return refuse(l, .bank1);
        if (l.rotation != 0) return refuse(l, .rotation);
        if (file_size <= header_size) return refuse(l, .empty);
        if (file_size - header_size > max_size) return refuse(l, .too_big);
        l.data_size = @min(file_size - header_size, l.bank_size());
        return l;
    }
    if (file_size > max_size) return refuse(l, .too_big);
    l.block_size = if (file_size <= 128 * 1024) 512 else if (file_size <= 256 * 1024) 1024 else 2048;
    l.block_shift = shift_for(@intCast(l.block_size)).?;
    l.data_size = file_size;
    return l;
}

fn refuse(l: Layout, r: Refusal) Layout {
    var out = l;
    out.verdict = r;
    return out;
}

fn shift_for(block_size: u16) ?u5 {
    return switch (block_size) {
        256 => 8,
        512 => 9,
        1024 => 10,
        2048 => 11,
        else => null,
    };
}

fn le16(b: *const [2]u8) u16 {
    return @as(u16, b[0]) | @as(u16, b[1]) << 8;
}

/// `s` without trailing NULs/spaces and leading spaces.
pub fn trim(s: []const u8) []const u8 {
    var end = s.len;
    for (s, 0..) |ch, i| {
        if (ch == 0) {
            end = i;
            break;
        }
    }
    var a: usize = 0;
    while (a < end and s[a] == ' ') a += 1;
    while (end > a and s[end - 1] == ' ') end -= 1;
    return s[a..end];
}

/// Per-byte reader for blocks without a direct pointer. `ctx` belongs to
/// the frontend and must outlive the Cart; `offset` is a byte offset into
/// the cart data (block 0 byte 0 = 0, the header not counted).
pub const ReadFallback = struct {
    ctx: *const anyopaque,
    func: *const fn (ctx: *const anyopaque, offset: u32) u8,
};

pub const Cart = struct {
    /// Block i covers data bytes [i * block_size, (i + 1) * block_size).
    /// Null: read through `read_fallback` or `slice`, never by pointer.
    blocks: [block_count]?[*]const u8 = @splat(null),
    block_size: u32 = 512,
    block_shift: u5 = 9,
    /// Cart data bytes present (reads at or past this return 0xFF).
    size: u32 = 0,
    read_fallback: ?ReadFallback = null,
    /// Cart data of a `from_slice` cart (empty otherwise).
    slice: []const u8 = &.{},

    /// An empty cart shaped by `l` (the frontend fills `blocks` and sets
    /// `read_fallback` for a drive file).
    pub fn empty(l: *const Layout) Cart {
        return .{ .block_size = l.block_size, .block_shift = l.block_shift, .size = l.data_size };
    }

    /// A cart from a whole file in memory (the embedded ROM, host tests).
    /// Every whole block gets a pointer; a partial last block reads through
    /// the slice. The caller checks `l.verdict` first.
    pub fn from_slice(l: *const Layout, file: []const u8) Cart {
        var c = empty(l);
        c.slice = file[l.data_offset..][0..l.data_size];
        var i: u32 = 0;
        while (i < block_count and (i + 1) * c.block_size <= c.size) : (i += 1) {
            c.blocks[i] = c.slice.ptr + i * c.block_size;
        }
        return c;
    }

    /// One byte: block `block`, byte `offset` within it (masked to the
    /// block size, as the ripple counter wraps). The slow, general path.
    pub fn read(c: *const Cart, block: u8, offset: u32) u8 {
        const off = offset & (c.block_size - 1);
        if (c.blocks[block]) |p| return p[off];
        return c.read_abs((@as(u32, block) << c.block_shift) | off);
    }

    /// One byte by offset into the cart data.
    pub fn read_abs(c: *const Cart, offset: u32) u8 {
        if (offset >= c.size) return 0xFF;
        if (offset < c.slice.len) return c.slice[offset];
        if (c.read_fallback) |f| return f.func(f.ctx, offset);
        return 0xFF;
    }

    /// Blocks that have a direct pointer.
    pub fn direct_blocks(c: *const Cart) u32 {
        var n: u32 = 0;
        for (c.blocks) |b| n += @intFromBool(b != null);
        return n;
    }
};
