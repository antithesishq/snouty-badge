//! Root for `zig build test`: the modules whose tests run on the host. The
//! test module imports the real cart API for its types only (Pixel,
//! DisplayColor, Framebuffer); nothing here calls the platform or the font,
//! so timeline.zig is tested through its plain data (`bars`, `Clock`),
//! never through `entries`, which would pull every part's render in.
const std = @import("std");
const font = @import("gen/scroller_font.zig");

test {
    _ = @import("math.zig");
    _ = @import("rng.zig");
    _ = @import("palette.zig");
    _ = @import("fx.zig");
    _ = @import("text.zig");
    _ = @import("timeline.zig");
    _ = @import("gen/scroller_font.zig");
    _ = @import("parts/copper.zig");
    _ = @import("parts/twister.zig");
    _ = @import("parts/rotozoomer.zig");
    _ = @import("parts/tunnel.zig");
}

test "scroller font: every glyph is non-empty and fits 16 rows" {
    try std.testing.expectEqual(@as(u32, 16), font.height);
    var c: u8 = font.first;
    while (true) : (c += 1) {
        const g = font.glyph(c);
        try std.testing.expect(g.width > 0);
        try std.testing.expectEqual(@as(usize, g.width), g.columns.len);
        // Columns are u16 with bit 0 the top row: 16 rows by construction;
        // the last column is the baked-in 1 px spacing, blank.
        try std.testing.expectEqual(@as(u16, 0), g.columns[g.columns.len - 1]);
        if (c == font.last) break;
    }
    // Unknown characters fall back to '?', lower case to upper case.
    try std.testing.expectEqual(font.glyph('?').columns.ptr, font.glyph(200).columns.ptr);
    try std.testing.expectEqual(font.glyph('A').columns.ptr, font.glyph('a').columns.ptr);
}
