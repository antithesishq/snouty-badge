//! Host tests of the UI that need no cart API: number formats, wrapping,
//! the font table, the pages and the App's input handling against the
//! game module.
const std = @import("std");
const G = @import("game");
const app_mod = @import("app.zig");
const pages = @import("pages.zig");
const text = @import("text.zig");

comptime {
    _ = @import("numfmt.zig");
    _ = text;
    _ = @import("font.zig");
}

const B = app_mod.Buttons;

fn press(app: *app_mod.App, b: B) void {
    app.update(b);
    app.update(.{});
}

var app_storage: app_mod.App = .{};

fn fresh() *app_mod.App {
    const app = &app_storage;
    app.init(12345);
    return app;
}

test "title: A starts the game, the code unlocks cheats" {
    const app = fresh();
    try std.testing.expectEqual(app_mod.Screen.title, app.screen);
    for ([_]B{ .{ .up = true }, .{ .up = true }, .{ .down = true }, .{ .down = true }, .{ .left = true }, .{ .right = true }, .{ .left = true }, .{ .right = true }, .{ .b = true }, .{ .a = true } }) |b| press(app, b);
    try std.testing.expect(app.cheats);
    try std.testing.expectEqual(app_mod.Screen.title, app.screen);
    press(app, .{ .a = true });
    try std.testing.expectEqual(app_mod.Screen.game, app.screen);
    try std.testing.expect(app.playing);
}

test "make paperclip: one clip per press, never repeats" {
    const app = fresh();
    press(app, .{ .a = true });
    try std.testing.expectEqual(app_mod.Page.business, app.page);
    // The cursor starts on Make Paperclip.
    try std.testing.expectEqual(@as(u16, 0), app.cursor_ix[0]);
    press(app, .{ .a = true });
    press(app, .{ .a = true });
    try std.testing.expectEqual(@as(f64, 2), app.game.clips);
    // Held for two seconds: still one clip.
    for (0..120) |_| app.update(.{ .a = true });
    app.update(.{});
    try std.testing.expectEqual(@as(f64, 3), app.game.clips);
}

test "virtual clock: 50 ms per three frames" {
    try std.testing.expectEqual(@as(u32, 50), app_mod.frame_ms(0) + app_mod.frame_ms(1) + app_mod.frame_ms(2));
}

test "start and select are ignored while both are held" {
    const app = fresh();
    press(app, .{ .a = true });
    app.update(.{ .start = true });
    app.update(.{ .start = true, .select = true });
    app.update(.{ .select = true });
    app.update(.{});
    try std.testing.expectEqual(app_mod.Screen.game, app.screen);
    // Start alone opens the log on release, and closes it again.
    press(app, .{ .start = true });
    try std.testing.expectEqual(app_mod.Screen.log, app.screen);
    press(app, .{ .start = true });
    try std.testing.expectEqual(app_mod.Screen.game, app.screen);
}

test "price row: A raises, B lowers" {
    const app = fresh();
    press(app, .{ .a = true });
    const m0 = app.game.margin;
    // Down from Make Paperclip lands on the price (the first selectable row below).
    press(app, .{ .down = true });
    const row = app.rows.slice()[app.cursor_ix[0]];
    try std.testing.expectEqual(pages.Kind.value, row.kind);
    press(app, .{ .a = true });
    try std.testing.expect(app.game.margin > m0);
    press(app, .{ .b = true });
    press(app, .{ .b = true });
    try std.testing.expect(app.game.margin < m0);
}

test "every visible page builds within the row and text limits" {
    const app = fresh();
    press(app, .{ .a = true });
    var list: pages.RowList = .{};
    var arena: text.Arena = .{};
    for (0..pages.page_count) |i| {
        const p: pages.Page = @enumFromInt(i);
        pages.build(&app.game, p, &list, &arena);
        try std.testing.expect(list.n < pages.max_rows);
        try std.testing.expect(arena.n < arena.buf.len);
    }
}
