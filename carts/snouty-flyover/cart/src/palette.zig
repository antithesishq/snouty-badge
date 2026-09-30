//! The 256-entry palette (layout SPEC.md 5.3), the per-frame fog table and the
//! water table.
//!
//! Every u16 here uses the cart API's `DisplayColor` bit layout (r in bits
//! 0-4, g in 5-10, b in 11-15), so `@bitCast(rgb565[i])` is a DisplayColor.
//! `fog` is different: its entries are ready-to-store `Pixel` bits (already
//! byte-swapped on wasm), so the renderer writes them without conversion.
//!
//! The two literal tables were generated once from `tools/concept.py`
//! (`Palette` plus the district `pair()` calls in the order `World` makes
//! them), rounded to 5/6/5 bits; each line's comment gives the 0xRRGGBB
//! source values. No comptime work: `fog` is built by runtime loops.
//!
//! Layout:
//!   0-15    noise floor, 0x141833 -> 0x1E2450
//!   16-19   grid lines, 0x283060 -> 0x34407A
//!   20-23   GC rubble
//!   24-27   water (24 is the one written to the map)
//!   28-30   spare, 31 white (GC wall)
//!   32-47   pulse A comet (cyan, head at 32), 48-63 pulse A dash
//!   64-79   pulse B comet (amber, head at 64), 80-95 pulse B dash
//!   96-255  district (top, side) pairs, top at the even index:
//!           96 bus road, 98 bus rim, 100-146 sort hues, 148 sort pivot,
//!           150-160 tree levels, 162 hash bucket, 164-168 hash chain,
//!           170 small bucket, 172 stack top, 174-192 stack bands, 194 lip,
//!           196-200 heap allocated, 202 heap freed, 204 pipeline dam,
//!           206 spring, 208-254 unassigned (grey)
const cart = @import("cart-api");

/// Fog colour (concept FOG_HEX), 0xRRGGBB.
pub const fog_rgb: u32 = 0x3A2258;
/// Number of fog levels; level 0 is unfogged, level fog_levels-1 is the fog colour.
pub const fog_levels = 8;
/// Indices [emissive_lo, emissive_hi) get half-strength fog (white + pulses).
pub const emissive_lo = 31;
pub const emissive_hi = 96;

/// The base palette, DisplayColor bits.
pub const rgb565 = [256]u16{
    0x30C2, 0x30C3, 0x38C3, 0x38E3, 0x38E3, 0x38E3, 0x40E3, 0x40E3, //   0: 141833 151935 151A37 161A39 171B3B 171C3D 181D3F 191E41
    0x4103, 0x4103, 0x4903, 0x4903, 0x4903, 0x4903, 0x4924, 0x5124, //   8: 191E42 1A1F44 1B2046 1B2148 1C224A 1D224C 1D234E 1E2450
    0x6185, 0x69A5, 0x71C6, 0x7A06, 0x3925, 0x3946, 0x4187, 0x49A8, //  16: 283060 2C3569 303B71 34407A 2A2436 312A3D 393043 40364A
    0x9A82, 0x9222, 0x81C1, 0x7181, 0x834C, 0x834C, 0x834C, 0xFFBD, //  24: 1050A0 0E4590 0C3B80 0A3070 606880 606880 606880 F0F8FF
    0xFFFC, 0x3921, 0x3921, 0x3921, 0x3921, 0x3921, 0x3921, 0x3921, //  32: E8FFFF 0A2436 0A2436 0A2436 0A2436 0A2436 0A2436 0A2436
    0x3921, 0x49A2, 0x6283, 0x8BA4, 0xB4C5, 0xE627, 0xFF2B, 0xFF93, //  40: 0A2436 0F3548 175166 21738B 2C9BB5 39C6E3 5DE5FF A0F2FF
    0xFFFC, 0x3921, 0x3921, 0x3921, 0x3921, 0x3921, 0x3921, 0x3921, //  48: E8FFFF 0A2436 0A2436 0A2436 0A2436 0A2436 0A2436 0A2436
    0x3921, 0x3921, 0x3921, 0x3921, 0x3921, 0xFEE8, 0xFF95, 0xFFFC, //  56: 0A2436 0A2436 0A2436 0A2436 0A2436 40E0FF A9F3FF E8FFFF
    0xCF9F, 0x00C6, 0x00C6, 0x00C6, 0x00C6, 0x00C6, 0x00C6, 0x00C6, //  64: FFF4D0 301804 301804 301804 301804 301804 301804 301804
    0x00C6, 0x0928, 0x11EC, 0x22D0, 0x2BD6, 0x3CDC, 0x5DDF, 0x96BF, //  72: 301804 432609 623C12 87581D B3782A E39B38 FFBC59 FFD793
    0xCF9F, 0x00C6, 0x00C6, 0x00C6, 0x00C6, 0x00C6, 0x00C6, 0x00C6, //  80: FFF4D0 301804 301804 301804 301804 301804 301804 301804
    0x00C6, 0x00C6, 0x00C6, 0x00C6, 0x00C6, 0x457F, 0x9EDF, 0xCF9F, //  88: 301804 301804 301804 301804 301804 FFB040 FFDA9A FFF4D0
    0x4944, 0x30C2, 0x8247, 0x4923, 0xFFE5, 0x7BE2, 0xFE85, 0x7B42, //  96: 202848 121830 3A4A86 1C2448 26FFFF 137F7F 26D3FF 13697F
    0xFD45, 0x7AA2, 0xFBE5, 0x79E2, 0xFA85, 0x7942, 0xF925, 0x78A2, // 104: 26A8FF 13547F 267CFF 133E7F 2651FF 13287F 2626FF 13137F
    0xF92A, 0x78A5, 0xF92F, 0x78A8, 0xF934, 0x78AA, 0xF93A, 0x78AD, // 112: 5126FF 28137F 7C26FF 3E137F A826FF 54137F D326FF 69137F
    0xF93F, 0x78AF, 0xD13F, 0x68AF, 0xA13F, 0x50AF, 0x793F, 0x40AF, // 120: FF26FF 7F137F FF26D3 7F1369 FF26A8 7F1354 FF267C 7F133E
    0x513F, 0x28AF, 0x293F, 0x10AF, 0x2A9F, 0x114F, 0x2BFF, 0x11EF, // 128: FF2651 7F1328 FF2626 7F1313 FF5126 7F2813 FF7C26 7F3E13
    0x2D5F, 0x12AF, 0x2E9F, 0x134F, 0x2FFF, 0x13EF, 0x2FFA, 0x13ED, // 136: FFA826 7F5413 FFD326 7F6913 FFFF26 7F7F13 D3FF26 697F13
    0x2FF4, 0x13EA, 0x2FEF, 0x13E8, 0xFF9E, 0xAC92, 0xBFF2, 0x5C65, // 144: A8FF26 547F13 7CFF26 3E7F13 F4F4FF 9090B0 90FFC0 2C8C58
    0x86E8, 0x4383, 0x6504, 0x2A82, 0x86E8, 0x4383, 0x6504, 0x2A82, // 152: 40E080 1C7040 20A060 10502C 40E080 1C7040 20A060 10502C
    0x86E8, 0x4383, 0xBA1B, 0x6910, 0x9993, 0x58CB, 0x812F, 0x48A8, // 160: 40E080 1C7040 E040C0 80206C A030A0 5C1A5C 7C2480 441446
    0x60CB, 0x3066, 0xDB5F, 0x8172, 0x28A5, 0x1843, 0x208A, 0x1046, // 168: 5A1A60 300E34 FF6AE0 902C80 2A1428 180A16 501020 300812
    0x20AC, 0x1047, 0x28CE, 0x1868, 0x2911, 0x188A, 0x3133, 0x188B, // 176: 631523 3A0A14 761A27 450D16 8A202A 501018 9D252E 5A121A
    0x3156, 0x18AC, 0x3198, 0x20CE, 0x39BA, 0x20CF, 0x39DD, 0x20F0, // 184: B12A31 65151C C43035 70181E D83538 7A1A20 EB3A3C 851D22
    0x421F, 0x2112, 0x84DF, 0x4213, 0x351F, 0x231B, 0x2C7D, 0x1AB8, // 192: FF4040 902024 FF9A80 A04040 FFA030 E06020 F08C28 C85418
    0x5DFF, 0x2B9C, 0xADE4, 0x6342, 0xEE35, 0x7AC9, 0xCD66, 0x7B03, // 200: FFBE58 E87028 20C0B0 0E6A64 B0C8F0 485878 30B0D0 186078
    0x9C50, 0x5A49, 0x9C50, 0x5A49, 0x9C50, 0x5A49, 0x9C50, 0x5A49, // 208: 8088A0 464B58 8088A0 464B58 8088A0 464B58 8088A0 464B58
    0x9C50, 0x5A49, 0x9C50, 0x5A49, 0x9C50, 0x5A49, 0x9C50, 0x5A49, // 216: 8088A0 464B58 8088A0 464B58 8088A0 464B58 8088A0 464B58
    0x9C50, 0x5A49, 0x9C50, 0x5A49, 0x9C50, 0x5A49, 0x9C50, 0x5A49, // 224: 8088A0 464B58 8088A0 464B58 8088A0 464B58 8088A0 464B58
    0x9C50, 0x5A49, 0x9C50, 0x5A49, 0x9C50, 0x5A49, 0x9C50, 0x5A49, // 232: 8088A0 464B58 8088A0 464B58 8088A0 464B58 8088A0 464B58
    0x9C50, 0x5A49, 0x9C50, 0x5A49, 0x9C50, 0x5A49, 0x9C50, 0x5A49, // 240: 8088A0 464B58 8088A0 464B58 8088A0 464B58 8088A0 464B58
    0x9C50, 0x5A49, 0x9C50, 0x5A49, 0x9C50, 0x5A49, 0x9C50, 0x5A49, // 248: 8088A0 464B58 8088A0 464B58 8088A0 464B58 8088A0 464B58
};

/// Fog-blended palette for this frame, `fog[level][index]`, as Pixel bits.
pub var fog: [fog_levels][256]u16 = undefined;

/// This frame's palette: rgb565 with the pulse ranges rotated (SPEC 5.3),
/// DisplayColor bits. Rebuilt by begin_frame; the fog table is built from it.
pub var cur: [256]u16 = undefined;

// Index names the generators use (layout above).
pub const grid = 16;
pub const rubble = 20;
pub const white = 31;
pub const pulse_a = 32;
pub const pulse_a_dash = 48;
pub const pulse_b = 64;
pub const pulse_b_dash = 80;
pub const bus_road = 96;
pub const bus_rim = 98;
pub const sort_hue0 = 100;
pub const sort_pivot = 148;
pub const heap_alloc = [3]u8{ 196, 198, 200 };
pub const heap_free = 202;

/// Darker blue-tinted version of each entry for the lake reflection (M2);
/// present but unused in M0. Concept: lerp(0.85 * c, 0x0C2C66, 0.55) * 0.92.
pub const water = [256]u16{
    0x4102, 0x4902, 0x4902, 0x4902, 0x4902, 0x4902, 0x4902, 0x4902, //   0: 0D1F46 0D1F46 0E1F47 0E2048 0E2048 0E2049 0F204A 0F214A
    0x4902, 0x4902, 0x4902, 0x4902, 0x4902, 0x5102, 0x5122, 0x5122, //   8: 0F214B 0F214C 0F224C 10224D 10224E 10224E 10234F 112350
    0x5142, 0x5943, 0x5963, 0x5963, 0x4923, 0x4923, 0x4943, 0x4943, //  16: 142755 162958 172B5B 182D5F 152347 172549 1A274B 1D294E
    0x6981, 0x6181, 0x6161, 0x5941, 0x61E5, 0x61E5, 0x61E5, 0x8B6B, //  24: 0C326C 0B2F66 0A2B61 0A275B 283B61 283B61 283B61 5B6E8D
    0x8B8B, 0x4921, 0x4921, 0x4921, 0x4921, 0x4921, 0x4921, 0x4921, //  32: 58708D 0A2347 0A2347 0A2347 0A2347 0A2347 0A2347 0A2347
    0x4921, 0x4941, 0x59A2, 0x6202, 0x7263, 0x82E3, 0x8B25, 0x8B68, //  40: 0A2347 0B294D 0E3358 123F64 164D73 1A5C84 27678D 3F6B8D
    0x8B8B, 0x4921, 0x4921, 0x4921, 0x4921, 0x4921, 0x4921, 0x4921, //  48: 58708D 0A2347 0A2347 0A2347 0A2347 0A2347 0A2347 0A2347
    0x4921, 0x4921, 0x4921, 0x4921, 0x4921, 0x8B23, 0x8B68, 0x8B8B, //  56: 0A2347 0A2347 0A2347 0A2347 0A2347 1D658D 426C8D 58708D
    0x7B6C, 0x3103, 0x3103, 0x3103, 0x3103, 0x3103, 0x3103, 0x3103, //  64: 606C7D 171F35 171F35 171F35 171F35 171F35 171F35 171F35
    0x3103, 0x3924, 0x3965, 0x41A7, 0x4208, 0x4A6A, 0x52CC, 0x6B0C, //  72: 171F35 1E2437 282C3A 36353E 454042 564D47 605853 606267
    0x7B6C, 0x3103, 0x3103, 0x3103, 0x3103, 0x3103, 0x3103, 0x3103, //  80: 606C7D 171F35 171F35 171F35 171F35 171F35 171F35 171F35
    0x3103, 0x3103, 0x3103, 0x3103, 0x3103, 0x4AAC, 0x6B0C, 0x7B6C, //  88: 171F35 171F35 171F35 171F35 171F35 60544A 60636A 606C7D
    0x4922, 0x4102, 0x6183, 0x4922, 0x8B82, 0x6222, 0x8B02, 0x61E2, //  96: 11244D 0C1F45 1A3063 10234D 13708D 0D4360 13618D 0D3B60
    0x8A82, 0x61A2, 0x8A02, 0x6162, 0x89A2, 0x6122, 0x8922, 0x60E2, // 104: 13518D 0D3460 13428D 0D2C60 13338D 0D2460 13248D 0D1D60
    0x8924, 0x60E2, 0x8926, 0x60E3, 0x8928, 0x60E4, 0x892A, 0x60E5, // 112: 23248D 141D60 32248D 1C1D60 41248D 241D60 50248D 2B1D60
    0x892C, 0x60E6, 0x792C, 0x58E6, 0x692C, 0x50E6, 0x612C, 0x48E6, // 120: 60248D 331D60 60247E 331D59 60246F 331D51 60245F 331D49
    0x512C, 0x40E6, 0x412C, 0x38E6, 0x41AC, 0x3926, 0x420C, 0x3966, // 128: 602450 331D42 602441 331D3A 603341 33243A 604241 332C3A
    0x428C, 0x39A6, 0x430C, 0x39E6, 0x438C, 0x3A26, 0x438A, 0x3A25, // 136: 605141 33343A 606141 333B3A 607041 33433A 507041 2B433A
    0x4388, 0x3A24, 0x4386, 0x3A23, 0x8B6B, 0x7247, 0x7387, 0x5243, // 144: 417041 24433A 327041 1C433A 5C6C8D 394972 397077 164853
    0x6323, 0x49E2, 0x5262, 0x4181, 0x6323, 0x49E2, 0x5262, 0x4181, // 152: 1D6561 103E4A 114F55 0C3243 1D6561 103E4A 114F55 0C3243
    0x6323, 0x49E2, 0x716A, 0x5906, 0x6948, 0x5105, 0x6126, 0x48E4, // 160: 1D6561 103E4A 552D77 33225A 3E276C 261F54 322361 1E1D4C
    0x5105, 0x40E3, 0x81EC, 0x6127, 0x40E3, 0x38C2, 0x40E4, 0x38C3, // 168: 261F55 171B46 603C82 392661 151D42 0F1A3B 221C3F 17193A
    0x40E5, 0x38C3, 0x4106, 0x38E4, 0x4107, 0x38E4, 0x4127, 0x38E5, // 176: 291E40 1A1A3B 301F41 1E1B3B 372242 221C3C 3D2344 261D3D
    0x4128, 0x38E5, 0x4949, 0x4106, 0x494A, 0x4106, 0x496B, 0x4106, // 184: 442545 2A1E3D 4B2746 2D1F3E 522947 311F3F 592B49 352040
    0x496C, 0x4107, 0x626C, 0x4968, 0x426C, 0x41CA, 0x424B, 0x39A9, // 192: 602D4A 392240 604C61 3E2D4A 604F45 55383F 5B4842 4C343C
    0x52CC, 0x41EB, 0x72C2, 0x59E1, 0x8AE8, 0x59A4, 0x7AA3, 0x59C2, // 200: 605953 583E42 115A72 0B3C57 445D88 1F355E 17547D 0F385E
    0x6A26, 0x5184, 0x6A26, 0x5184, 0x6A26, 0x5184, 0x6A26, 0x5184, // 208: 33466C 1F3153 33466C 1F3153 33466C 1F3153 33466C 1F3153
    0x6A26, 0x5184, 0x6A26, 0x5184, 0x6A26, 0x5184, 0x6A26, 0x5184, // 216: 33466C 1F3153 33466C 1F3153 33466C 1F3153 33466C 1F3153
    0x6A26, 0x5184, 0x6A26, 0x5184, 0x6A26, 0x5184, 0x6A26, 0x5184, // 224: 33466C 1F3153 33466C 1F3153 33466C 1F3153 33466C 1F3153
    0x6A26, 0x5184, 0x6A26, 0x5184, 0x6A26, 0x5184, 0x6A26, 0x5184, // 232: 33466C 1F3153 33466C 1F3153 33466C 1F3153 33466C 1F3153
    0x6A26, 0x5184, 0x6A26, 0x5184, 0x6A26, 0x5184, 0x6A26, 0x5184, // 240: 33466C 1F3153 33466C 1F3153 33466C 1F3153 33466C 1F3153
    0x6A26, 0x5184, 0x6A26, 0x5184, 0x6A26, 0x5184, 0x6A26, 0x5184, // 248: 33466C 1F3153 33466C 1F3153 33466C 1F3153 33466C 1F3153
};

/// Blend weight of each fog level in 1/256: round(level * 256 / 7).
const fog_weight = [fog_levels]i32{ 0, 37, 73, 110, 146, 183, 219, 256 };

/// Rotate the pulse ranges into `cur` and rebuild `fog` for this frame.
/// Scaffold: TODO(Track A) rotate 32-47 by frame (A forwards), 48-63 by
/// 2 frame, 64-79 by -frame (B backwards), 80-95 by -2 frame.
pub fn begin_frame(frame: u32) void {
    _ = frame;
    cur = rgb565;
    const fr: i32 = @intCast(((fog_rgb >> 16) * 31 + 127) / 255);
    const fg: i32 = @intCast((((fog_rgb >> 8) & 0xFF) * 63 + 127) / 255);
    const fb: i32 = @intCast(((fog_rgb & 0xFF) * 31 + 127) / 255);
    for (&fog, 0..) |*level_table, level| {
        for (level_table, 0..) |*out, i| {
            const w = if (i >= emissive_lo and i < emissive_hi) fog_weight[level >> 1] else fog_weight[level];
            const c: i32 = cur[i];
            const r = blend(c & 31, fr, w);
            const g = blend((c >> 5) & 63, fg, w);
            const b = blend(c >> 11, fb, w);
            const bits: u16 = @intCast(r | (g << 5) | (b << 11));
            out.* = if (cart.is_wasm) @byteSwap(bits) else bits;
        }
    }
}

/// a + (b - a) * w / 256, rounded.
inline fn blend(a: i32, b: i32, w: i32) i32 {
    return a + (((b - a) * w + 128) >> 8);
}
