//! Post-boot state without the boot ROM (SPEC.md sections 7, 11, 18.2;
//! docs/BOOT.md).
//!
//! The Lynx boot ROM clears RAM, programs a few Mikey registers, selects
//! cart block 0 and reads one "frame" of RSA-encrypted blocks from RCART0,
//! decrypts it into RAM at $0200 and jumps there. Loaders then call two ROM
//! routines themselves: $FE00 (select a cart block) and $FE4A (decrypt the
//! next frame into the page the loader chose). This file does the same work
//! natively, from public documents only:
//!
//! - [A] Alexander Thissen's annotated boot ROM disassembly, AtariAge
//!   "Annotated Lynx boot rom", 2012:
//!   https://forums.atariage.com/topic/191953-annotated-lynx-boot-rom/
//!   (archived copy: https://web.archive.org/web/2020/https://atariage.com/forums/topic/191953-annotated-lynx-boot-rom/)
//! - [H] David Huseby's lynx-encryption-tools (zlib licence), keys.h and
//!   lynxdec.c: the public modulus, exponent 3, the reversed byte order,
//!   the 51/50-byte framing and the running-sum obfuscation:
//!   https://github.com/dhuseby/lynx-encryption-tools
//!
//! Nothing here is derived from a boot ROM image. `tools/bootrom_crosscheck.py`
//! runs Adrian's local copy on a host 6502 and `tests/boot_crosscheck.zig`
//! compares its results with these functions (docs/BOOT.md).
//!
//! Badge-safe: no allocator, no floats, fixed arrays, integer math only.
const std = @import("std");

// ---------------------------------------------------------------------------
// The cart image

/// `.lnx` header size. [H] sizes.h and the cc65 `lynx` target's
/// libsrc/lynx/exehdr.s ("LYNX", bank sizes, version, name, maker, rotation).
pub const header_len = 64;

pub const Rotation = enum(u8) { none = 0, left = 1, right = 2, _ };

pub const Header = struct {
    /// Bank 0 page (block) size in bytes, from header bytes 4-5.
    bank0_page: u16,
    /// Bank 1 page size, bytes 6-7 (0 = no bank 1).
    bank1_page: u16,
    version: u16,
    /// NUL-padded, header bytes 10..41.
    name: [32]u8,
    /// NUL-padded, header bytes 42..57.
    manufacturer: [16]u8,
    /// Byte 58.
    rotation: Rotation,
    /// Byte 59 (version 1 headers from newer tools: AUDIN used as a bank
    /// switch bit), 0 when unused.
    audin: u8,
    /// Byte 60 (EEPROM type and flags), 0 when there is none.
    eeprom: u8,

    pub fn name_slice(h: *const Header) []const u8 {
        return std.mem.sliceTo(&h.name, 0);
    }
};

pub const CartError = error{
    /// Headerless file whose size is not 128, 256 or 512 KB.
    UnknownSize,
    /// "LYNX" header with a bank 0 page size that is not 256..2048 and a
    /// power of two.
    BadHeader,
};

/// The cart as the boot code sees it: the payload (header stripped) and its
/// block size. The cart port's full model lives in core/cart.zig (M1); this
/// is only what the boot path needs.
pub const Cart = struct {
    data: []const u8,
    block_size: u32,
    header: ?Header,

    /// Accepts a headered `.lnx` (trust the header) or a headerless dump
    /// (SPEC 18.3: 128 KB = 256 blocks of 512 B, 256 KB = 1 KB blocks,
    /// 512 KB = 2 KB blocks).
    pub fn from_file(file: []const u8) CartError!Cart {
        if (file.len >= header_len and std.mem.eql(u8, file[0..4], "LYNX")) {
            const page = std.mem.readInt(u16, file[4..6], .little);
            if (page < 256 or page > 2048 or !std.math.isPowerOfTwo(page)) return error.BadHeader;
            var h: Header = .{
                .bank0_page = page,
                .bank1_page = std.mem.readInt(u16, file[6..8], .little),
                .version = std.mem.readInt(u16, file[8..10], .little),
                .name = undefined,
                .manufacturer = undefined,
                .rotation = @fromBackingInt(@intCast(file[58])),
                .audin = file[59],
                .eeprom = file[60],
            };
            @memcpy(&h.name, file[10..42]);
            @memcpy(&h.manufacturer, file[42..58]);
            return .{ .data = file[header_len..], .block_size = page, .header = h };
        }
        const bs: u32 = switch (file.len) {
            128 * 1024 => 512,
            256 * 1024 => 1024,
            512 * 1024 => 2048,
            else => return error.UnknownSize,
        };
        return .{ .data = file, .block_size = bs, .header = null };
    }

    /// Byte `counter` of block `block`. Past the end of a short image (a
    /// homebrew file smaller than its header's bank) reads 0xFF.
    pub fn byte_at(c: *const Cart, block: u8, counter: u32) u8 {
        const off = @as(usize, block) * c.block_size + (counter % c.block_size);
        return if (off < c.data.len) c.data[off] else 0xFF;
    }
};

/// Sequential reader over RCART0: the block selected by $FE00 and a counter
/// that advances on every read (the cart's ripple counter). `decrypt_frame`
/// takes any value with this shape (`read_byte`), so M1's cart port can be
/// passed directly.
pub const CartReader = struct {
    cart: *const Cart,
    block: u8 = 0,
    counter: u32 = 0,

    pub fn read_byte(r: *CartReader) u8 {
        const b = r.cart.byte_at(r.block, r.counter);
        r.counter += 1;
        return b;
    }
};

// ---------------------------------------------------------------------------
// RSA: plaintext = encrypted^3 mod N, over 51-byte numbers

/// Bytes per encrypted block (408-bit numbers). [A] "LDX #$32 ... Each block
/// in a frame is 50 + 1 byte long"; [H] sizes.h ENCRYPTED_BLOCK_SIZE.
pub const block_len = 51;
/// Plaintext bytes kept per block (the most significant byte is the $15
/// check byte). [H] lynxdec.c "we only take 50 bytes of output".
pub const plain_len = 50;
/// Most significant byte of every decrypted block. [A] FE78-FE7C:
/// "LDA ($0B) ... CMP #$15 ... Must always be $15".
pub const check_byte = 0x15;
/// Frame block-count bytes the ROM accepts: $FB..$FF = 5..1 blocks.
/// [A] FE4D "CMP #$FB ... BCC error"; [H] lynxdec.c "256 - block count".
pub const min_count_byte = 0xFB;

/// The public modulus, most significant byte first. [A] "FF9A Public key
/// for decryption 35 B5 A3 ... AC 7E 79"; identical to [H] keys.h
/// `lynx_public_mod`.
pub const modulus_be = [block_len]u8{
    0x35, 0xB5, 0xA3, 0x94, 0x28, 0x06, 0xD8, 0xA2,
    0x26, 0x95, 0xD7, 0x71, 0xB2, 0x3C, 0xFD, 0x56,
    0x1C, 0x4A, 0x19, 0xB6, 0xA3, 0xB0, 0x26, 0x00,
    0x36, 0x5A, 0x30, 0x6E, 0x3C, 0x4D, 0x63, 0x38,
    0x1B, 0xD4, 0x1C, 0x13, 0x64, 0x89, 0x36, 0x4C,
    0xF2, 0xBA, 0x2A, 0x58, 0xF4, 0xFE, 0xE1, 0xFD,
    0xAC, 0x7E, 0x79,
};

/// 13 x 32 bits = 416 bits holds 2N (N < 2^406), little-endian limbs.
const limbs = 13;
const Big = [limbs]u32;

fn from_be(be: *const [block_len]u8) Big {
    var r: Big = @splat(0);
    for (0..block_len) |i| {
        const byte_index = block_len - 1 - i; // i = significance in bytes
        r[i / 4] |= @as(u32, be[byte_index]) << @intCast(8 * (i % 4));
    }
    return r;
}

fn to_be(x: *const Big) [block_len]u8 {
    var out: [block_len]u8 = undefined;
    for (0..block_len) |i| out[block_len - 1 - i] = @truncate(x[i / 4] >> @intCast(8 * (i % 4)));
    return out;
}

fn geq(a: *const Big, b: *const Big) bool {
    var i: usize = limbs;
    while (i > 0) {
        i -= 1;
        if (a[i] != b[i]) return a[i] > b[i];
    }
    return true;
}

fn sub_in_place(a: *Big, b: *const Big) void {
    var borrow: u64 = 0;
    for (0..limbs) |i| {
        const d = @as(u64, a[i]) -% @as(u64, b[i]) -% borrow;
        a[i] = @truncate(d);
        borrow = (d >> 63) & 1;
    }
}

fn add_in_place(a: *Big, b: *const Big) void {
    var carry: u64 = 0;
    for (0..limbs) |i| {
        const s = @as(u64, a[i]) + @as(u64, b[i]) + carry;
        a[i] = @truncate(s);
        carry = s >> 32;
    }
}

fn shl1_in_place(a: *Big) void {
    var carry: u32 = 0;
    for (0..limbs) |i| {
        const next = a[i] >> 31;
        a[i] = (a[i] << 1) | carry;
        carry = next;
    }
}

/// a * b mod n for a, b < n, by the shift-and-add loop the ROM uses (MSB
/// first; [A] FEE2-FF1D and "routine X" FF1E, the conditional subtract).
fn mul_mod(a: *const Big, b: *const Big, n: *const Big) Big {
    var r: Big = @splat(0);
    var bit: usize = limbs * 32;
    while (bit > 0) {
        bit -= 1;
        shl1_in_place(&r);
        if (geq(&r, n)) sub_in_place(&r, n);
        if ((a[bit / 32] >> @intCast(bit % 32)) & 1 != 0) {
            add_in_place(&r, b);
            if (geq(&r, n)) sub_in_place(&r, n);
        }
    }
    return r;
}

/// c^3 mod N of one block as the cart stores it (least significant byte
/// first: the ROM stores cart bytes at $DC down to $AA, [A] FE59-FE61; [H]
/// `load_reverse`). Returns the result most significant byte first, as the
/// ROM's ($0B) buffer holds it. `c` must be below N (the caller checks).
pub fn cube(block_le: *const [block_len]u8) [block_len]u8 {
    var be: [block_len]u8 = undefined;
    for (0..block_len) |i| be[i] = block_le[block_len - 1 - i];
    const n = from_be(&modulus_be);
    const c = from_be(&be);
    const c2 = mul_mod(&c, &c, &n);
    const c3 = mul_mod(&c2, &c, &n);
    return to_be(&c3);
}

// ---------------------------------------------------------------------------
// The frame decryptor ($FE4A) and the first boot pass

pub const BootError = error{
    /// Block-count byte below $FB (more than five blocks, or no loader).
    BadCount,
    /// An encrypted block failed the ROM's range check (top three bytes all
    /// zero, or not below the modulus's top three bytes).
    BadBlock,
    /// A decrypted block's most significant byte was not $15.
    BadCheckByte,
    /// The last plaintext byte of the frame was not zero (the ROM's TAX /
    /// BNE before JMP $0200).
    BadLastByte,
};

/// 65SC02 status bits.
pub const flag_c: u8 = 0x01;
pub const flag_z: u8 = 0x02;
pub const flag_i: u8 = 0x04;
pub const flag_d: u8 = 0x08;
pub const flag_b: u8 = 0x10;
pub const flag_u: u8 = 0x20;
pub const flag_v: u8 = 0x40;
pub const flag_n: u8 = 0x80;

pub const Regs = struct {
    a: u8,
    x: u8,
    y: u8,
    /// Status as PHP would push it (bits 4 and 5 set).
    p: u8,
    sp: u8,
    pc: u16,
};

/// What `decrypt_frame` leaves at its JMP $0200.
pub const FrameResult = struct {
    /// Blocks in the frame (1..5) and plaintext bytes written (50 each).
    blocks: u8,
    len: u16,
    /// Where the plaintext went: the page from $06, the offset from $05
    /// (the ROM increments $05 only, so a frame wraps within its page).
    dest: u16,
    /// A = 0, X = 0, Y = 2; N/V/Z/C from the last ADC and the TAX; SP is
    /// the caller's (the routine is entered by JMP and leaves by JMP).
    a: u8,
    x: u8,
    y: u8,
    /// Only the N, V, Z and C bits are meaningful; D and I are untouched
    /// by the routine and must be merged from the CPU.
    nvzc: u8,
};

/// Zero-page bytes the ROM routine uses and leaves meaningful. [A] FE3D-FE8E.
pub const zp_transition = 0x02; // running sum carried across blocks
pub const zp_dest_lo = 0x05;
pub const zp_dest_hi = 0x06;
pub const zp_count = 0x07; // block count byte, counts up to 0

/// One pass of the ROM's frame loop, [A] FE4A-FE9A: read the count byte and
/// the blocks from `reader`, decrypt, un-obfuscate (running sum, [A] FE7E-
/// FE8C, [H] `decrypt_block`) and store at ($05) onwards. Updates $02, $05,
/// $07 like the ROM. Mikey side effects the caller applies: GREENF ($FDAF)
/// and BLUEREDF ($FDBF) are written 0 after the count byte is accepted and
/// IODAT ($FD8B) is written 2 at the end (`frame_mikey_writes`).
///
/// The ROM's work buffers in zero page ($08-$0B, $0F, $11-$DC) and the
/// copy of its multiply routine at $5000-$50FF are not reproduced
/// (docs/BOOT.md).
pub fn decrypt_frame(reader: anytype, ram: *[65536]u8) BootError!FrameResult {
    const count = reader.read_byte();
    if (count < min_count_byte) return error.BadCount;
    ram[zp_count] = count;
    const n_top = @as(u32, modulus_be[0]) << 16 | @as(u32, modulus_be[1]) << 8 | modulus_be[2];
    const page: u16 = @as(u16, ram[zp_dest_hi]) << 8;
    const start_lo = ram[zp_dest_lo];
    // Carry going into each block's range check: set by the CMP #$FB for the
    // first block, then whatever the previous block's last ADC left.
    var carry: u1 = 1;
    var acc: u8 = ram[zp_transition];
    var v: bool = false;
    var blocks: u8 = 0;
    while (true) {
        var enc: [block_len]u8 = undefined;
        for (&enc) |*b| b.* = reader.read_byte();
        // [A] FE63-FE73: the top three bytes (the last three read) must not
        // all be zero and must be below the modulus's top three bytes (an
        // SBC chain entered with the carry above: borrow required).
        const top = @as(u32, enc[50]) << 16 | @as(u32, enc[49]) << 8 | enc[48];
        if (top == 0) return error.BadBlock;
        if (top >= n_top + @as(u32, 1 - carry)) return error.BadBlock;
        const plain = cube(&enc);
        if (plain[0] != check_byte) return error.BadCheckByte;
        // [A] FE80-FE8A: from the least significant byte (offset 50) up to
        // offset 1, A += byte (CLC each time), stored at ($05), INC $05.
        var i: usize = plain_len;
        while (i > 0) : (i -= 1) {
            const s = @as(u16, acc) + plain[i];
            const r: u8 = @truncate(s);
            v = ((acc ^ r) & (plain[i] ^ r) & 0x80) != 0;
            carry = @intCast(s >> 8);
            acc = r;
            ram[page | ram[zp_dest_lo]] = acc;
            ram[zp_dest_lo] +%= 1;
        }
        ram[zp_transition] = acc;
        blocks += 1;
        ram[zp_count] +%= 1;
        if (ram[zp_count] == 0) break;
    }
    if (acc != 0) return error.BadLastByte;
    var nvzc: u8 = flag_z; // TAX of A = 0
    if (carry == 1) nvzc |= flag_c;
    if (v) nvzc |= flag_v;
    return .{
        .blocks = blocks,
        .len = @as(u16, blocks) * plain_len,
        .dest = page | start_lo,
        .a = 0,
        .x = 0,
        .y = 2,
        .nvzc = nvzc,
    };
}

pub const RegWrite = struct { addr: u16, value: u8 };

/// Mikey writes of one `decrypt_frame` pass, in order. [A] FE53, FE56, FE94.
pub const frame_mikey_writes = [_]RegWrite{
    .{ .addr = 0xFDAF, .value = 0x00 }, // GREENF
    .{ .addr = 0xFDBF, .value = 0x00 }, // BLUEREDF
    .{ .addr = 0xFD8B, .value = 0x02 }, // IODAT
};

/// Mikey registers the ROM programs before the first frame, in the order it
/// writes them. [A] FE26-FE32 walks X = 13..1 over the address table at
/// FFCD (offsets from $FD00) and the value table at FFD9: FD00 TIM0BKUP
/// = $9E (158), FD01 TIM0CTLA = $18, FD08 TIM2BKUP = $68 (104), FD09
/// TIM2CTLA = $1F, FDA0 GREEN0 = 0, FDB0 BLUERED0 = 0, FDAF GREENF = $0E,
/// FDBF BLUEREDF = $3E, FD93 PBKUP = $29, FD94/FD95 DISPADR = $2000, FD92
/// DISPCTL = $0D, FD90 SDONEACK = 0. Before that, [A] FF89-FF8F: IODAT =
/// 2, IODIR = 3; the $FE00 call leaves SYSCTL1 = 2 and IODAT = 0.
pub const boot_mikey_writes = [_]RegWrite{
    .{ .addr = 0xFD8B, .value = 0x02 }, // IODAT (FF8B)
    .{ .addr = 0xFD8A, .value = 0x03 }, // IODIR (FF8F)
    .{ .addr = 0xFD00, .value = 0x9E },
    .{ .addr = 0xFD01, .value = 0x18 },
    .{ .addr = 0xFDA0, .value = 0x00 },
    .{ .addr = 0xFDB0, .value = 0x00 },
    .{ .addr = 0xFDAF, .value = 0x0E },
    .{ .addr = 0xFDBF, .value = 0x3E },
    .{ .addr = 0xFD08, .value = 0x68 },
    .{ .addr = 0xFD09, .value = 0x1F },
    .{ .addr = 0xFD93, .value = 0x29 },
    .{ .addr = 0xFD94, .value = 0x00 },
    .{ .addr = 0xFD95, .value = 0x20 },
    .{ .addr = 0xFD92, .value = 0x0D },
    .{ .addr = 0xFD90, .value = 0x00 },
    // $FE00 with A = 0: eight strobes of SYSCTL1 bit 0 with IODAT bit 1 = 0.
    .{ .addr = 0xFD87, .value = 0x02 },
    .{ .addr = 0xFD8B, .value = 0x00 },
};

/// ROM entry points loaders call (tools/bootrom_crosscheck.py records them:
/// Hard Drivin' and Blue Lightning use exactly these two). Without a boot
/// ROM the emulator traps PC == these while the ROM is mapped (MAPCTL bit 2
/// clear) and runs `SetCartBlockExit` / `decrypt_frame` instead, then does
/// the routine's RTS (for $FE00) or continues at $0200 (for $FE4A).
pub const entry_set_cart_block: u16 = 0xFE00;
pub const entry_decrypt_frame: u16 = 0xFE4A;

/// Where `decrypt_frame` jumps on success. [A] FE9A.
pub const loader_entry: u16 = 0x0200;

/// ROM vectors, as the bytes at FFFA-FFFF read when MAPCTL bit 3 is clear.
/// [A] "FFFA 00 30 NMI vector, FFFC 80 FF boot vector, FFFE 80 FF IRQ".
pub const vector_nmi: u16 = 0x3000;
pub const vector_reset: u16 = 0xFF80;
pub const vector_irq: u16 = 0xFF80;

/// CPU registers after `JSR $FE00` returns (the RTS itself is the caller's):
/// the block number is shifted out MSB first with a sentinel carry, so the
/// routine leaves A = 0, X = 2, C = 1 (the sentinel), Z = 1, N = 0, and
/// SYSCTL1 = 2 (strobe low, power on), IODAT = 0. [A] FE00-FE18. The block
/// register and the counter reset are the cart port's (core/cart.zig).
pub const SetCartBlockExit = struct {
    pub const a: u8 = 0;
    pub const x: u8 = 2;
    pub const set_flags: u8 = flag_c | flag_z;
    pub const clear_flags: u8 = flag_n;
    pub const sysctl1: u8 = 0x02;
    pub const iodat: u8 = 0x00;
};

/// The state the ROM leaves at its first JMP $0200.
pub const BootState = struct {
    /// PC = $0200, A = 0, X = 0, Y = 2, P = I, Z, C/V from the last ADC,
    /// SP = $01 (see `sp_at_entry`).
    regs: Regs,
    /// 0: the RAM clear loop writes 0 to $FFF9 on its way through page $FF
    /// ([A] FE19-FE24 after FF92 set MAPCTL = 3), so Suzy, Mikey, the ROM
    /// and the vectors are all mapped in.
    mapctl: u8,
    iodir: u8,
    iodat: u8,
    sysctl1: u8,
    /// Cart block selected (0) and bytes read from it (count byte + 51 per
    /// block): the ripple counter's value.
    cart_block: u8,
    cart_counter: u32,
    /// The first frame.
    frame: FrameResult,
    /// Every Mikey write of the boot, in order (the last value per address
    /// is the register state).
    mikey_writes: [boot_mikey_writes.len + frame_mikey_writes.len]RegWrite,
};

/// SP when the ROM jumps to $0200. The ROM does four PLAs at FF85-FF88 and
/// otherwise balances its stack; a 65C02 leaves SP = $FD after reset from
/// SP = 0 (three dummy pushes), giving $01. The real value depends on SP
/// before reset, so loaders set their own (Blue Lightning does; Hard
/// Drivin' runs its loader with SP = $01). This is an assumption, not a
/// documented fact (docs/BOOT.md).
pub const sp_at_entry: u8 = 0x01;

/// The first boot pass: RAM cleared, Mikey programmed, block 0 selected,
/// the first frame decrypted to $0200 ([A] FF80-FE9A). `ram` is fully
/// overwritten. The returned reader position (`cart_block`,
/// `cart_counter`) is where the loader's own RCART0 reads continue.
pub fn post_boot(cart: *const Cart, ram: *[65536]u8) BootError!BootState {
    // [A] FF95 STZ $00, FE19-FE24 clears $0003-$FFFF (RAM under every
    // overlay), FE43 STZ $02; $01 wraps to 0. All RAM is zero.
    @memset(ram, 0);
    // [A] FE3D-FE41: destination $0200.
    ram[zp_dest_lo] = 0x00;
    ram[zp_dest_hi] = 0x02;
    var reader: CartReader = .{ .cart = cart, .block = 0, .counter = 0 };
    const f = try decrypt_frame(&reader, ram);
    var writes: [boot_mikey_writes.len + frame_mikey_writes.len]RegWrite = undefined;
    @memcpy(writes[0..boot_mikey_writes.len], &boot_mikey_writes);
    @memcpy(writes[boot_mikey_writes.len..], &frame_mikey_writes);
    return .{
        .regs = .{
            .a = f.a,
            .x = f.x,
            .y = f.y,
            .p = f.nvzc | flag_i | flag_b | flag_u,
            .sp = sp_at_entry,
            .pc = loader_entry,
        },
        .mapctl = 0,
        .iodir = 0x03,
        .iodat = 0x02,
        .sysctl1 = 0x02,
        .cart_block = reader.block,
        .cart_counter = reader.counter,
        .frame = f,
        .mikey_writes = writes,
    };
}
