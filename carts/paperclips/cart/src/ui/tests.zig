//! Host tests of the UI that need no cart API: number formats, wrapping,
//! the font table, the pages and the App's input handling against the
//! game module.
const std = @import("std");
const G = @import("game");
const app_mod = @import("app.zig");
const pages = @import("pages.zig");
const text = @import("text.zig");
const save = @import("save");
const saves = app_mod.saves;
const snap = G.snapshot;

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
    save.fake.reset(); // an empty store on the patched OS
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
        pages.build(app.game, p, &list, &arena);
        try std.testing.expect(list.n < pages.max_rows);
        try std.testing.expect(arena.n < arena.buf.len);
    }
}

test "held A repeats on buy rows: 0.4 s, then 8 per second" {
    const app = fresh();
    press(app, .{ .a = true });
    for (0..3) |_| G.act(app.game, .cheat_money);
    app.update(.{});
    // Down to Marketing (Make Paperclip -> price -> Marketing).
    press(app, .{ .down = true });
    press(app, .{ .down = true });
    const row = app.rows.slice()[app.cursor_ix[0]];
    try std.testing.expectEqualStrings("Marketing", row.left);
    const lvl0 = app.game.marketing_lvl;
    // One second held: the press, then repeats from frame 25 on.
    for (0..60) |_| app.update(.{ .a = true });
    app.update(.{});
    const bought = app.game.marketing_lvl - lvl0;
    try std.testing.expect(bought >= 5 and bought <= 7);
}

test "a page that appears gets a news mark; Select goes there" {
    const app = fresh();
    press(app, .{ .a = true });
    try std.testing.expect(!app.any_news());
    // Enough money shows the AutoClippers row (manufacturing news).
    G.act(app.game, .cheat_money);
    for (0..20) |_| app.update(.{});
    try std.testing.expect(app.news[@intFromEnum(pages.Page.manufacturing)]);
    press(app, .{ .select = true });
    try std.testing.expectEqual(pages.Page.manufacturing, app.page);
    try std.testing.expect(!app.news[@intFromEnum(pages.Page.manufacturing)]);
}

// ---- saves (saves.zig against lib/save.zig's fake) ----

fn frames(app: *app_mod.App, n: usize) void {
    for (0..n) |_| app.update(.{});
}

/// Play time without frames: the game clock, then one frame for the saver.
fn play_ms(app: *app_mod.App, ms: u32) void {
    G.advance_ms(app.game, ms);
    app.update(.{});
}

var peek_buf: [snap.max_blob]u8 = undefined;
var check_game: G.Game = undefined;

/// The stored game, decoded.
fn stored() !*G.Game {
    const b = save.fake.peek(saves.key, &peek_buf) orelse return error.NoSave;
    try snap.decode(b, &check_game);
    return &check_game;
}

/// A boot of the cart with whatever the store holds: the title and its
/// probe (frame 2).
fn boot() *app_mod.App {
    save.fake.reboot();
    const app = &app_storage;
    app.init(777);
    frames(app, 2);
    return app;
}

test "saves: stock firmware shows and does nothing" {
    const app = fresh();
    save.fake.setSupported(false);
    frames(app, 3);
    try std.testing.expect(app.saver.probed and !app.saver.on);
    try std.testing.expect(!app.title_menu());
    press(app, .{ .a = true });
    try std.testing.expectEqual(app_mod.Screen.game, app.screen);
    play_ms(app, 400_000);
    press(app, .{ .start = true });
    for (0..10) |_| {
        app.update(.{});
        try std.testing.expect(!app.saver.armed);
    }
    try std.testing.expectEqual(@as(u32, 0), save.fake.commits());
    try std.testing.expect(!save.fake.exitWatched());
    try std.testing.expect(app.saver.error_text() == null);
}

test "saves: autosave after a minute of play, the SAVING mark first" {
    const app = fresh();
    frames(app, 2);
    try std.testing.expect(app.saver.on and save.fake.exitWatched());
    try std.testing.expect(!app.title_menu()); // no save yet: "Press A"
    press(app, .{ .a = true });
    // Past the opening battle, then just short of a minute: nothing yet.
    play_ms(app, 59_000);
    try std.testing.expect(saves.calm(app.game));
    try std.testing.expect(!app.saver.armed);
    try std.testing.expectEqual(@as(u32, 0), save.fake.commits());
    play_ms(app, 2_000);
    // The frame that shows the mark has not written yet...
    try std.testing.expect(app.saver.armed);
    try std.testing.expectEqual(@as(u32, 0), save.fake.commits());
    const at = app.game.now_ms;
    // ...the next update writes first, then plays on.
    app.update(.{});
    try std.testing.expect(!app.saver.armed and app.saver.wrote);
    try std.testing.expectEqual(@as(u32, 1), save.fake.commits());
    const g = try stored();
    try std.testing.expectEqual(at, g.now_ms);
    // Two blocks: one 4 KB data block plus the directory.
    try std.testing.expect(app.saver.last_size <= 4096);
    try std.testing.expectEqual(@as(u64, 110), save.fake.flashMs());
    // And not again for another minute.
    play_ms(app, 30_000);
    try std.testing.expect(!app.saver.armed);
}

test "saves: the log (Start) saves, a battle waits for a calm frame" {
    const app = fresh();
    frames(app, 2);
    press(app, .{ .a = true });
    // The opening skirmish is on for the first seconds.
    try std.testing.expect(!saves.calm(app.game));
    press(app, .{ .start = true });
    try std.testing.expectEqual(app_mod.Screen.log, app.screen);
    try std.testing.expect(app.saver.pending != null);
    try std.testing.expect(!app.saver.armed);
    var n: usize = 0;
    while (!saves.calm(app.game) and n < 3000) : (n += 1) {
        app.update(.{});
        if (!saves.calm(app.game)) try std.testing.expect(!app.saver.armed);
    }
    try std.testing.expect(saves.calm(app.game));
    frames(app, 2);
    try std.testing.expectEqual(@as(u32, 1), save.fake.commits());
    // Once calm, the log saves on the spot (mark, then write).
    play_ms(app, 20_000);
    press(app, .{ .start = true }); // back to the game
    press(app, .{ .start = true }); // the log again
    try std.testing.expect(app.saver.armed);
    app.update(.{});
    try std.testing.expectEqual(@as(u32, 2), save.fake.commits());
}

test "saves: a battle that will not end is saved after 30 s anyway" {
    const app = fresh();
    frames(app, 2);
    press(app, .{ .a = true });
    press(app, .{ .start = true });
    // Hold the battle open by hand (both sides keep ships).
    const g = app.game;
    g.num_left_ships = 5;
    g.num_right_ships = 5;
    app.saver.pending_since_ms = g.now_ms;
    G.advance_ms(g, 1);
    g.num_left_ships = 5;
    g.num_right_ships = 5;
    app.saver.frame_end(g, true);
    try std.testing.expect(!app.saver.armed);
    g.now_ms += saves.knobs.calm_wait_max_ms;
    app.saver.frame_end(g, true);
    try std.testing.expect(app.saver.armed);
}

test "saves: idle play saves every five minutes" {
    const app = fresh();
    frames(app, 2);
    press(app, .{ .a = true });
    // Eight minutes in 5 s steps, nobody pressing: a save each minute up
    // to 4 min, then idle (from 5 min on) and every 5 minutes.
    var k: usize = 0;
    while (k < 96) : (k += 1) play_ms(app, 5_000);
    try std.testing.expectEqual(@as(u32, 4), save.fake.commits());
    while (k < 114) : (k += 1) play_ms(app, 5_000); // 9.5 min: the 9 min save
    try std.testing.expectEqual(@as(u32, 5), save.fake.commits());
    // A press: back to every minute.
    press(app, .{ .down = true });
    play_ms(app, 61_000);
    frames(app, 2);
    try std.testing.expectEqual(@as(u32, 6), save.fake.commits());
}

test "saves: CONTINUE picks up the saved game, NEW GAME asks first" {
    var app = fresh();
    frames(app, 2);
    press(app, .{ .a = true });
    for (0..30) |_| press(app, .{ .a = true }); // 30 clips
    play_ms(app, 70_000);
    frames(app, 2);
    try std.testing.expectEqual(@as(u32, 1), save.fake.commits());
    const saved = try stored();
    const clips = saved.clips;
    const now = saved.now_ms;
    try std.testing.expect(clips >= 30);

    // Power off and on: the title offers the save.
    app = boot();
    try std.testing.expect(app.title_menu());
    try std.testing.expectEqual(saves.Found.game, app.saver.found);
    press(app, .{ .a = true }); // CONTINUE
    try std.testing.expectEqual(app_mod.Screen.game, app.screen);
    try std.testing.expect(app.playing);
    try std.testing.expectEqual(clips, app.game.clips);
    try std.testing.expect(app.game.now_ms >= now and app.game.now_ms < now + 100);

    // Again, NEW GAME this time: Down, A asks, B backs out, A A starts.
    app = boot();
    press(app, .{ .down = true });
    try std.testing.expectEqual(@as(u8, 1), app.title_sel);
    press(app, .{ .a = true });
    try std.testing.expect(app.confirm_new and !app.playing);
    press(app, .{ .b = true });
    try std.testing.expect(!app.confirm_new and app.title_menu());
    press(app, .{ .a = true });
    press(app, .{ .a = true });
    try std.testing.expect(app.playing);
    try std.testing.expectEqual(@as(f64, 0), app.game.clips);
    // The old save stays until the new game's first save.
    try std.testing.expectEqual(clips, (try stored()).clips);
}

test "saves: NEW GAME keeps a finished game's prestige" {
    var app = fresh();
    frames(app, 2);
    press(app, .{ .a = true });
    app.game.prestige_u = 1;
    app.game.prestige_s = 2;
    app.game.has_save_prestige = true;
    press(app, .{ .start = true });
    frames(app, 300); // past the opening battle
    try std.testing.expect(save.fake.commits() >= 1);
    app = boot();
    press(app, .{ .down = true });
    press(app, .{ .a = true });
    press(app, .{ .a = true });
    try std.testing.expect(app.playing);
    try std.testing.expectEqual(@as(f64, 1), app.game.prestige_u);
    try std.testing.expectEqual(@as(f64, 2), app.game.prestige_s);
}

test "saves: a save from another build is refused, a new game starts" {
    var app = fresh();
    frames(app, 2);
    press(app, .{ .a = true });
    play_ms(app, 70_000);
    frames(app, 2);
    var b = save.fake.peek(saves.key, &peek_buf).?;
    std.mem.writeInt(u32, b[8..12], snap.layout +% 1, .little); // another layout
    try save.write(saves.key, b);
    app = boot();
    try std.testing.expectEqual(saves.Found.old_version, app.saver.found);
    try std.testing.expect(!app.title_menu());
    press(app, .{ .a = true });
    try std.testing.expect(app.playing);
    try std.testing.expectEqual(@as(f64, 0), app.game.clips);
    try std.testing.expectEqual(@as(u64, 17 + 17), app.game.now_ms);
    // Damaged data says so too.
    b = save.fake.peek(saves.key, &peek_buf).?;
    b[30] ^= 0xFF;
    b[31] ^= 0xFF;
    b[32] ^= 0xFF;
    std.mem.writeInt(u32, b[8..12], snap.layout, .little);
    try save.write(saves.key, b);
    app = boot();
    try std.testing.expectEqual(saves.Found.damaged, app.saver.found);
}

test "saves: the OS's Exit cart saves, then says ready" {
    const app = fresh();
    frames(app, 2);
    press(app, .{ .a = true });
    play_ms(app, 20_000);
    save.fake.setExitRequested();
    const before = app.game.now_ms;
    app.update(.{});
    try std.testing.expectEqual(@as(u32, 1), save.fake.commits());
    try std.testing.expectEqual(save.abi.exit_ready, save.fake.exitWord());
    // The cart does nothing more until the OS stops it.
    frames(app, 5);
    press(app, .{ .a = true });
    try std.testing.expectEqual(before, app.game.now_ms);
    try std.testing.expectEqual(@as(u32, 1), save.fake.commits());
    try std.testing.expectEqual(before, (try stored()).now_ms);
}

test "saves: exit on the title with an unplayed save writes nothing" {
    var app = fresh();
    frames(app, 2);
    press(app, .{ .a = true });
    save.fake.setExitRequested();
    app.update(.{});
    try std.testing.expectEqual(@as(u32, 1), save.fake.commits());
    app = boot();
    try std.testing.expect(app.title_menu());
    save.fake.setExitRequested();
    app.update(.{});
    try std.testing.expectEqual(save.abi.exit_ready, save.fake.exitWord());
    try std.testing.expectEqual(@as(u32, 1), save.fake.commits());
}

test "saves: rate limited retries at the next trigger, other errors show once" {
    const app = fresh();
    frames(app, 2);
    press(app, .{ .a = true });
    play_ms(app, 61_000);
    save.fake.failNext(error.RateLimited);
    frames(app, 2);
    try std.testing.expectEqual(@as(u32, 1), app.saver.rate_limited);
    try std.testing.expectEqual(@as(u32, 0), save.fake.commits());
    try std.testing.expect(app.saver.error_text() == null);
    // The next trigger (the log) goes through.
    press(app, .{ .start = true });
    frames(app, 2);
    try std.testing.expectEqual(@as(u32, 1), save.fake.commits());
    // A real failure shows once...
    press(app, .{ .start = true });
    play_ms(app, 61_000);
    save.fake.failNext(error.NoSpace);
    frames(app, 2);
    try std.testing.expectEqualStrings("SAVE FAILED: NO SPACE", app.saver.error_text().?);
    frames(app, saves.knobs.error_frames);
    try std.testing.expect(app.saver.error_text() == null);
    // ...the next failure stays quiet, and later saves still work.
    play_ms(app, 61_000);
    save.fake.failNext(error.IoError);
    frames(app, 2);
    try std.testing.expect(app.saver.error_text() == null);
    play_ms(app, 61_000);
    frames(app, 2);
    try std.testing.expectEqual(@as(u32, 2), save.fake.commits());
}
