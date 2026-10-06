//! The marquee's art without the badge (PLAN.md "M8 Marquee: contract"):
//! the title cleaned up for lettering, laid out as one bit mask per column,
//! and the colour scheme picked from it. No cart-api, so the host tests run it (tests/marquee_unit.zig);
//! frontend/marquee.zig turns the result into pixels every frame.
//!
//! Lettering: the 8x8 OS font (frontend/text.zig captures it), made
//! proportional (each glyph cut to its inked columns, one blank column
//! between glyphs, three for a space), then scaled: one line at twice the
//! height and as wide as fits up to twice the width, or two lines at the
//! font's height when the title is too long for one. Strokes that the
//! horizontal scale leaves one pixel wide are thickened.

/// Marquee size: the full screen width, badge rows 0..25.
pub const w = 160;
pub const h = 26;
/// Rows 0 and h - 1 are the black trim, 1 and h - 2 its highlight; the
/// lettering stays inside `inner_y0..inner_y1` (outline and shadow too).
pub const inner_y0 = 2;
pub const inner_y1 = h - 2;
/// Columns the lettering may use (its outline included), centred.
pub const max_text_w = w - 8;

/// Printable ASCII, the glyphs `text.zig` captures: `glyphs[ch - 32][c]`
/// bit r = row r of column c is ink.
pub const first_glyph: u8 = 32;
pub const glyph_count = 95;
pub const Glyphs = [glyph_count][8]u8;

/// `Glyphs` from the OS font's source (sycl-badge/src/font.zig: rows top
/// first, the left column in the top bit, 0 = ink), for the host tools and
/// tests; the cart captures the same glyphs from the screen (text.zig).
pub fn glyphs_from_rows(rows: *const [glyph_count][8]u8) Glyphs {
    var g: Glyphs = undefined;
    for (&g, rows) |*cols, r| {
        for (cols, 0..) |*m, c| {
            m.* = 0;
            for (r, 0..) |bits, y| {
                if (bits & (@as(u8, 0x80) >> @intCast(c)) == 0) m.* |= @as(u8, 1) << @intCast(y);
            }
        }
    }
    return g;
}

/// Longest cleaned title kept (two lines of `max_line` characters).
pub const max_title = 40;
const max_line = 20;

/// The title as lettering: no extension, no `(USA, Europe)` / `[!]` tags,
/// `_` as spaces (and `-` too in a file name), runs of spaces as one,
/// upper case, printable ASCII only. `src` is the header's cart name, or
/// the file name (`from_file`).
pub noinline fn clean_title(src: []const u8, from_file: bool, buf: *[max_title]u8) []const u8 {
    var s = src;
    // ".lnx" / ".lyx" (any case), also "name.lnx.lyx"-style leftovers.
    while (s.len > 4 and s[s.len - 4] == '.') {
        const e0 = lower(s[s.len - 3]);
        const e1 = lower(s[s.len - 2]);
        const e2 = lower(s[s.len - 1]);
        if (e0 == 'l' and ((e1 == 'n' and e2 == 'x') or (e1 == 'y' and e2 == 'x'))) s = s[0 .. s.len - 4] else break;
    }
    var n: usize = 0;
    var depth: u8 = 0;
    var space = true; // drops leading spaces
    for (s) |ch0| {
        var ch = ch0;
        if (ch == '(' or ch == '[') {
            depth +|= 1;
            continue;
        }
        if (ch == ')' or ch == ']') {
            depth -|= 1;
            continue;
        }
        if (depth > 0) continue;
        if (ch == '_' or ch == '\t' or (from_file and ch == '-')) ch = ' ';
        if (ch < 32 or ch > 126) continue;
        if (ch == ' ') {
            if (space) continue;
            space = true;
        } else space = false;
        if (n == buf.len) break;
        buf[n] = upper(ch);
        n += 1;
    }
    while (n > 0 and buf[n - 1] == ' ') n -= 1;
    return buf[0..n];
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn upper(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

/// The lettering: `mask[x]` bit y = ink at column x, row y. `lines` line
/// boxes (rows `y0..y0+rows`), for the fill's gradient.
pub const Layout = struct {
    mask: [w]u32 = @splat(0),
    lines: u8 = 0,
    y0: [2]u8 = .{ 0, 0 },
    rows: [2]u8 = .{ 0, 0 },
};

/// Source columns of one line in the proportional font (at most 9 per
/// glyph plus a gap): 20 glyphs.
const max_src_cols = max_line * 10;

/// One line of `text` in source columns: the glyphs cut to their inked
/// columns, one blank between glyphs, four for a space. `bold` widens every
/// glyph by a column, each column inked where it or the one to its left is
/// (so letters thicken without closing the gaps between them). Returns the
/// count.
noinline fn source_columns(text: []const u8, glyphs: *const Glyphs, bold: bool, out: *[max_src_cols]u8) usize {
    var n: usize = 0;
    for (text, 0..) |ch, i| {
        if (n + 10 > out.len) break;
        if (ch == ' ') {
            // The gap before it is already there: three more.
            @memset(out[n..][0..3], 0);
            n += 3;
            continue;
        }
        const g = &glyphs[if (ch >= first_glyph and ch - first_glyph < glyph_count) ch - first_glyph else '?' - first_glyph];
        var c0: usize = 0;
        var c1: usize = 8;
        while (c0 < 8 and g[c0] == 0) c0 += 1;
        while (c1 > c0 and g[c1 - 1] == 0) c1 -= 1;
        if (c0 == c1) continue;
        var prev: u8 = 0;
        for (g[c0..c1]) |m| {
            out[n] = if (bold) m | prev else m;
            prev = m;
            n += 1;
        }
        if (bold) {
            out[n] = prev;
            n += 1;
        }
        if (i + 1 < text.len) {
            out[n] = 0;
            n += 1;
        }
    }
    while (n > 0 and out[n - 1] == 0) n -= 1;
    return n;
}

/// Inked rows of `cols` as (first, count); (0, 0) for none.
fn ink_rows(cols: []const u8) struct { u8, u8 } {
    var any: u8 = 0;
    for (cols) |m| any |= m;
    if (any == 0) return .{ 0, 0 };
    const r0: u8 = @ctz(any);
    const r1: u8 = 8 - @clz(any);
    return .{ r0, r1 - r0 };
}

/// Draw source columns `cols` (source rows `r0..r0+rows`) into `mask` as
/// `out_rows` rows from row `y0` and `sx256 / 256` columns per source
/// column (both nearest neighbour), centred horizontally.
noinline fn place(mask: *[w]u32, cols: []const u8, r0: u8, rows: u8, y0: u8, out_rows: u8, sx256: u32) void {
    // Output row -> source row, once for the line.
    var bit_for: [h]u8 = undefined;
    for (bit_for[0..out_rows], 0..) |*b, j| b.* = @intCast(r0 + j * rows / out_rows);
    const out_w: u32 = @intCast((cols.len * sx256 + 255) / 256);
    const x0: u32 = (w - out_w) / 2;
    var ox: u32 = 0;
    while (ox < out_w) : (ox += 1) {
        const m = cols[@min(ox * 256 / sx256, cols.len - 1)];
        var bits: u32 = 0;
        for (bit_for[0..out_rows], 0..) |r, j| {
            if (m >> @intCast(r) & 1 != 0) bits |= @as(u32, 1) << @intCast(y0 + j);
        }
        mask[x0 + ox] |= bits;
    }
}

/// Columns the lettering's fill may take: the outline needs one each side
/// and the shadow one more.
const room: u32 = max_text_w - 3;

/// One line of `text` at the widest fitting scale up to 2x: the plain
/// font while it scales by 1.5 or more (strokes at least a pixel and a
/// half), else the bold one, else the plain one (squeezed below 1x, losing
/// columns, when even that is too wide). Returns the column count and
/// scale (x256), or null for no ink.
noinline fn fit_line(text: []const u8, glyphs: *const Glyphs, cols: *[max_src_cols]u8) ?struct { usize, u32 } {
    const plain = source_columns(text, glyphs, false, cols);
    if (plain == 0) return null;
    if (plain * 3 / 2 <= room) return .{ plain, @min(512, room * 256 / @as(u32, @intCast(plain))) };
    const bold = source_columns(text, glyphs, true, cols);
    if (bold <= room) return .{ bold, room * 256 / @as(u32, @intCast(bold)) };
    return .{ source_columns(text, glyphs, false, cols), room * 256 / @as(u32, @intCast(plain)) };
}

/// Lay out `title` (from `clean_title`): one line at twice the font's
/// height when it fits at full width or more, else two lines (split at the
/// space nearest the middle) as tall as the band allows.
pub noinline fn layout(title: []const u8, glyphs: *const Glyphs) Layout {
    var l: Layout = .{};
    if (title.len == 0) return l;
    // Rows the lettering's fill may take: one above for the outline, one
    // below for the outline and one for the shadow.
    const avail: u8 = inner_y1 - inner_y0 - 3;
    var cols: [max_src_cols]u8 = undefined;

    if (title.len <= max_line) {
        if (fit_line(title, glyphs, &cols)) |f| if (f[1] >= 256) {
            const n, const sx256 = f;
            const r0, const rows = ink_rows(cols[0..n]);
            const out_rows = rows * 2;
            const y0: u8 = inner_y0 + 1 + (avail - out_rows) / 2;
            place(&l.mask, cols[0..n], r0, rows, y0, out_rows, sx256);
            l.lines = 1;
            l.y0[0] = y0;
            l.rows[0] = out_rows;
            return l;
        };
    }

    var split: usize = title.len / 2;
    var best: ?usize = null;
    for (title, 0..) |ch, i| {
        if (ch != ' ') continue;
        if (best == null or absdiff(i, title.len / 2) < absdiff(best.?, title.len / 2)) best = i;
    }
    if (best) |b| split = b;
    const parts = [2][]const u8{ trim(title[0..split]), trim(title[split..]) };
    // Both lines from the same source rows, one blank row between them
    // (their outlines share it).
    var src: [2][max_src_cols]u8 = undefined;
    var fits: [2]?struct { usize, u32 } = undefined;
    var any: u8 = 0;
    for (parts, 0..) |p, k| {
        fits[k] = fit_line(p[0..@min(p.len, max_line)], glyphs, &src[k]);
        if (fits[k]) |f| for (src[k][0..f[0]]) |m| {
            any |= m;
        };
    }
    if (any == 0) return l;
    const r0: u8 = @ctz(any);
    const rows: u8 = 8 - @clz(any) - r0;
    const out_rows: u8 = @min(2 * rows, (avail - 1) / 2);
    const top: u8 = inner_y0 + 1 + (avail - (2 * out_rows + 1)) / 2;
    for (0..2) |k| {
        const n, const sx256 = fits[k] orelse continue;
        const y0: u8 = top + @as(u8, @intCast(k)) * (out_rows + 1);
        // No wider than 1.5x: the lines stay a pair.
        place(&l.mask, src[k][0..n], r0, rows, y0, out_rows, @min(384, sx256));
        l.y0[l.lines] = y0;
        l.rows[l.lines] = out_rows;
        l.lines += 1;
    }
    return l;
}

fn absdiff(a: usize, b: usize) usize {
    return if (a > b) a - b else b - a;
}

fn trim(s: []const u8) []const u8 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and s[a] == ' ') a += 1;
    while (b > a and s[b - 1] == ' ') b -= 1;
    return s[a..b];
}

// ---- Colours ----

/// One look: 0xRRGGBB colours. The background is lit from behind (brightest
/// at `bg_glow`, mid-height at the centre column, falling to `bg_edge` at
/// the trim and the ends); the letters are two-tone chrome (`hi_top` to
/// `hi_bot` above the horizon line, `lo_top` to `lo_bot` below it) with an
/// `outline` and a shadow.
pub const Scheme = struct {
    bg_edge: u32,
    bg_glow: u32,
    hi_top: u32,
    hi_bot: u32,
    lo_top: u32,
    lo_bot: u32,
    outline: u32,
    /// Bands across the lower background (the sunset stripes), 0 for none.
    band: u32,
};

pub const schemes = [_]Scheme{
    // Sunset: purple to magenta, chrome yellow over orange.
    .{ .bg_edge = 0x1A0630, .bg_glow = 0xC8287C, .hi_top = 0xFFFFE0, .hi_bot = 0xFFD840, .lo_top = 0xFF8C10, .lo_bot = 0xFFE070, .outline = 0x200018, .band = 0x5A0C58 },
    // Neon: navy to electric blue, white over cyan.
    .{ .bg_edge = 0x020A28, .bg_glow = 0x1C64D8, .hi_top = 0xFFFFFF, .hi_bot = 0xB0F0FF, .lo_top = 0x10B8E8, .lo_bot = 0x90F0FF, .outline = 0x000818, .band = 0x0C2C78 },
    // Fire: black-red to orange, white-yellow over red.
    .{ .bg_edge = 0x200400, .bg_glow = 0xE04008, .hi_top = 0xFFFFFF, .hi_bot = 0xFFF070, .lo_top = 0xFFB000, .lo_bot = 0xFFF0A0, .outline = 0x280000, .band = 0x701000 },
    // Jungle: deep green, lime over gold.
    .{ .bg_edge = 0x021404, .bg_glow = 0x1C9C30, .hi_top = 0xFFFFE8, .hi_bot = 0xE0FF60, .lo_top = 0xFFC000, .lo_bot = 0xFFF088, .outline = 0x001000, .band = 0x0C4C14 },
    // Atari: charcoal, red chrome.
    .{ .bg_edge = 0x0C0C10, .bg_glow = 0x6C7484, .hi_top = 0xFFFFFF, .hi_bot = 0xFFB0A0, .lo_top = 0xE01818, .lo_bot = 0xFF8070, .outline = 0x100000, .band = 0x30343C },
    // Candy: pink to violet, cyan over blue.
    .{ .bg_edge = 0x28042C, .bg_glow = 0xF060B0, .hi_top = 0xFFFFFF, .hi_bot = 0xA8FFFF, .lo_top = 0x2080FF, .lo_bot = 0xA0E0FF, .outline = 0x10002C, .band = 0x80207C },
};

/// FNV-1a of the title: the scheme every boot of this game gets.
pub fn scheme_index(title: []const u8) usize {
    var x: u32 = 0x811C9DC5;
    for (title) |c| x = (x ^ c) *% 0x01000193;
    return x % schemes.len;
}

/// `a` to `b` by `t / n` per channel.
pub noinline fn mix(a: u32, b: u32, t: u32, n: u32) u32 {
    var out: u32 = 0;
    var s: u5 = 0;
    while (s <= 16) : (s += 8) {
        const ca = (a >> s) & 0xFF;
        const cb = (b >> s) & 0xFF;
        const c = (ca * (n - t) + cb * t) / n;
        out |= c << s;
    }
    return out;
}

/// Horizontal glow levels: the background row tables for columns near the
/// centre (0) out to the ends (`glow_levels - 1`).
pub const glow_levels = 4;

/// Glow level of column `x`.
pub fn glow_level(x: u32) u32 {
    const d = if (x < w / 2) w / 2 - 1 - x else x - w / 2;
    return @min(glow_levels - 1, d / 22);
}

/// The colour tables `marquee.zig` converts to pixels once per boot.
pub const Colors = struct {
    /// Background per glow level and row (trim rows included).
    bg: [glow_levels][h]u32,
    /// Shadow per row (the background darkened).
    shadow: [h]u32,
    /// Letter fill per row.
    fill: [h]u32,
    outline: u32,
};

/// One background column at glow colour `glow`: black trim, its highlight,
/// brightest at mid-height, the sunset bands below. Out of line over a
/// slice, as `darken` and the cart's conversions: one-off set-up stays a
/// loop rather than 26 unrolled copies in a RAM cart.
noinline fn bg_column(s: *const Scheme, glow: u32, out: []u32) void {
    const mid: u32 = (inner_y0 + inner_y1) / 2;
    for (out, 0..) |*v, y| {
        const yy: u32 = @intCast(y);
        if (y == 0 or y == out.len - 1) {
            v.* = 0x000000;
        } else if (y == 1 or y == out.len - 2) {
            v.* = mix(0xFFFFFF, glow, 3, 5);
        } else {
            const d = if (yy < mid) mid - yy else yy - mid;
            v.* = mix(glow, s.bg_edge, d, mid - inner_y0 + 2);
            if (s.band != 0 and yy > mid + 1) {
                const k = yy - mid - 2;
                if (k == 1 or k == 4 or k == 5 or k == 8 or k == 9) v.* = mix(v.*, s.band, 2, 3);
            }
        }
    }
}

/// `dst` = `src` at a third of its brightness (the shadow).
noinline fn darken(dst: []u32, src: []const u32) void {
    for (dst, src) |*d, v| d.* = mix(v, 0x000000, 2, 3);
}

/// The tables for scheme `s` and the lettering `l`.
pub noinline fn colors(s: Scheme, l: *const Layout) Colors {
    var c: Colors = undefined;
    // The glow fades towards the ends.
    for (&c.bg, 0..) |*col, g| bg_column(&s, mix(s.bg_glow, s.bg_edge, @intCast(g), glow_levels + 1), col);
    darken(&c.shadow, &c.bg[glow_levels - 1]);
    @memset(&c.fill, s.hi_top);
    for (0..l.lines) |k| {
        const y0: u32 = l.y0[k];
        const rows: u32 = l.rows[k];
        if (rows == 0) continue;
        // The horizon a little below the middle, as on chrome lettering.
        const hz = (rows * 5 + 5) / 10;
        for (0..rows) |i| {
            const ii: u32 = @intCast(i);
            const y = y0 + ii;
            if (y >= h) break;
            c.fill[y] = if (ii < hz)
                mix(s.hi_top, s.hi_bot, ii, @max(1, hz - 1))
            else
                mix(s.lo_top, s.lo_bot, ii - hz, @max(1, rows - hz));
        }
    }
    c.outline = s.outline;
    return c;
}

// ---- Drawing ----

/// The lettering's colour tables in the display's pixel type `P` (`u32`
/// 0xRRGGBB for the host preview, tools/marquee_preview.zig); the
/// background is the caller's (`Colors.bg`).
pub fn Palette(comptime P: type) type {
    return struct {
        shadow: [h]P,
        fill: [h]P,
        /// The fill half way to white: the glint's edges.
        shine: [h]P,
        outline: P,
        glint: P,
    };
}

/// Frames from one glint to the next, and how many it takes to cross.
pub const glint_period = 360;
pub const glint_frames = 48;
/// Diagonal width of the glint in `2x + y` units: its white core is the
/// middle `glint_core` of them, the edges are `shine`.
pub const glint_width = 12;
const glint_core = 5;

/// The glint's position along the diagonal (`2x + y`) at `frame`, far off
/// the marquee between sweeps.
pub fn glint_at(frame: u32) i32 {
    const t = frame % glint_period;
    if (t >= glint_frames) return -1000;
    return @as(i32, @intCast(t * (2 * w + h + 2 * glint_width) / glint_frames)) - glint_width;
}

/// Column `x` of the lettering over a column that already holds its
/// background (`pal.bg[glow_level(x)]`): the fill (or the glint), the
/// outline around it and the shadow down and right of that. Only those
/// pixels are stored, one per set mask bit. `left_d` carries the column
/// to the left's dilated mask (0 before column 0).
pub inline fn letter_column(comptime P: type, pal: *const Palette(P), mask: *const [w]u32, x: usize, left_d: *u32, glint: i32, out: *[h]P) void {
    const f = mask[x];
    const fl = if (x > 0) mask[x - 1] else 0;
    const fr = if (x + 1 < w) mask[x + 1] else 0;
    const n3 = f | fl | fr;
    const d = n3 | n3 << 1 | n3 >> 1;
    var shadow = (left_d.* << 1) & ~d;
    left_d.* = d;
    var outline = d & ~f;
    while (outline != 0) : (outline &= outline - 1) out[@ctz(outline)] = pal.outline;
    while (shadow != 0) : (shadow &= shadow - 1) {
        const y = @ctz(shadow);
        out[y] = pal.shadow[y];
    }
    // The glint crosses the column at rows `gx..gx + glint_width` (as
    // `2x + y` runs along it), so `t = y - gx` places a fill pixel in it.
    const gx: i32 = glint - 2 * @as(i32, @intCast(x));
    var fill = f;
    // Most columns, most of the time: no glint in this column.
    if (gx >= h or gx + glint_width <= 0) {
        while (fill != 0) : (fill &= fill - 1) {
            const y = @ctz(fill);
            out[y] = pal.fill[y];
        }
        return;
    }
    while (fill != 0) : (fill &= fill - 1) {
        const y = @ctz(fill);
        const t: u32 = @bitCast(@as(i32, y) - gx);
        out[y] = if (t >= glint_width)
            pal.fill[y]
        else if (t -% (glint_width - glint_core) / 2 < glint_core)
            pal.glint
        else
            pal.shine[y];
    }
}

/// A fill colour half way to white (`Palette.shine`).
pub fn shine(fill: u32) u32 {
    return mix(fill, 0xFFFFFF, 1, 2);
}

/// The whole drawn marquee as 0xRRGGBB rows (host preview and tests).
pub fn render_rgb(l: *const Layout, c: *const Colors, frame: u32, out: *[h][w]u32) void {
    var pal: Palette(u32) = .{ .shadow = c.shadow, .fill = c.fill, .shine = undefined, .outline = c.outline, .glint = 0xFFFFFF };
    for (&pal.shine, c.fill) |*v, f| v.* = shine(f);
    const glint = glint_at(frame);
    var left_d: u32 = 0;
    for (0..w) |x| {
        var col: [h]u32 = c.bg[glow_level(@intCast(x))];
        letter_column(u32, &pal, &l.mask, x, &left_d, glint, &col);
        for (0..h) |y| out[y][x] = col[y];
    }
}
