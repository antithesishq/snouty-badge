//! Draws the App (app.zig) every frame (SPEC 4.1): the title, the game
//! screen (HUD, trail strip, log, the prompt box or the "A: MORE" bar) and
//! the log history. "Trail paper": cream paper, near-black ink, raspberry
//! accents, leaf-green highlights.
const std = @import("std");
const G = @import("game");
const app_mod = @import("app.zig");
const draw = @import("draw.zig");
const font = @import("font.zig");
const L = @import("layout.zig");
const log_mod = @import("log.zig");
const text = @import("text.zig");
const art = @import("art");

const App = app_mod.App;

pub fn frame(app: *const App) void {
    switch (app.screen) {
        .title => title(app),
        .game => game_screen(app),
        .history => history(app),
        .credits => credits(),
    }
    if (app.help) help(app);
}

// -- title -------------------------------------------------------------

fn title(app: *const App) void {
    const lay = art.layout;
    art.draw(.title_bg, 0, 0, 0, draw.sink);
    art.draw(.title_wagon, lay.title_wagon.x, lay.title_wagon.y, app.frame / 15, draw.sink);
    art.draw(.title_logo, lay.title_logo.x, lay.title_logo.y, 0, draw.sink);
    const m = lay.title_menu;
    const labels = [_][]const u8{ "NEW GAME", if (app.sound) "SOUND: ON" else "SOUND: OFF", "CREDITS" };
    for (labels, 0..) |lab, i| {
        const y = m.y + 1 + @as(i32, @intCast(i)) * 9;
        const w = font.width(lab.len);
        const x = m.x + @divTrunc(m.w - w, 2);
        if (i == @backingInt(app.title_cursor)) {
            draw.fill_rect(m.x + 4, y - 1, m.w - 8, 9, .rasp);
            var g: [1]u8 = .{font.tri_right};
            _ = draw.text(&g, m.x + 7, y, .paper);
        }
        _ = draw.text(lab, x, y, .paper);
    }
}

fn text2_center(s: []const u8, y: i32, c: draw.Color) void {
    const w = @as(i32, @intCast(s.len)) * 12 - 2;
    _ = draw.text2(s, @divTrunc(L.width - w, 2), y, c);
}

/// Word-wrapped paragraph at 26 columns; returns the y below it.
fn paragraph(s: []const u8, y0: i32, pitch: i32, c: draw.Color) i32 {
    var spans: [12]text.Span = undefined;
    const n = @min(text.wrap(s, font.cols, &spans), spans.len);
    var y = y0;
    for (spans[0..n]) |sp| {
        _ = draw.text(s[sp.start..sp.end], L.text_x, y, c);
        y += pitch;
    }
    return y;
}

fn credits() void {
    draw.clear(.paper);
    draw.fill_rect(0, 0, L.width, 2, .rasp);
    draw.text_center("THE RASPBERRY TRAIL", 5, .rasp_ink);
    var y: i32 = 17;
    y = paragraph("AFTER THE OREGON TRAIL (1971) BY DON RAWITSCH, BILL HEINEMANN AND PAUL DILLENBERGER.", y, 8, .ink) + 3;
    y = paragraph("BASIC LISTING: MECC, 1978, CREATIVE COMPUTING MAY-JUNE 1978.", y, 8, .ink) + 3;
    y = paragraph("TRANSCRIPTION: GITHUB.COM/ CLINTMOYER/OREGON-TRAIL (PUBLIC DOMAIN).", y, 8, .ink) + 3;
    _ = paragraph("PORTED TO THE SYCL BADGE'S RP2350 IN 2026.", y, 8, .faded);
    draw.fill_rect(0, L.height - 11, L.width, 11, .shade);
    draw.hline(0, L.height - 11, L.width, .rasp);
    _ = draw.text_right("A: BACK", L.width - 2, L.height - 8, .rasp_ink);
}

/// The button legend over the current screen (Start; SPEC 5).
fn help(app: *const App) void {
    const x0: i32 = 6;
    const y0: i32 = 10;
    const w: i32 = L.width - 12;
    const h: i32 = 108;
    draw.fill_rect(x0, y0, w, h, .paper);
    draw.frame(x0, y0, w, h, .rasp);
    draw.frame(x0 + 1, y0 + 1, w - 2, h - 2, .shade);
    draw.text_center("HELP", y0 + 4, .rasp_ink);
    const rows = [_][2][]const u8{
        .{ "A", "PICK, NEXT PAGE" },
        .{ "\x83\x84", "MOVE, CHANGE" },
        .{ "\x85\x86", "AMOUNT DIGIT" },
        .{ "B", "RESET THE AMOUNT" },
        .{ "SELECT", "THE LOG" },
        .{ "SHOOT", "THE CUED BUTTONS" },
        .{ "", "IN ORDER, FAST!" },
    };
    var y = y0 + 16;
    for (rows) |r| {
        _ = draw.text(r[0], x0 + 5, y, .rasp_ink);
        _ = draw.text(r[1], x0 + 5 + 7 * font.cell_w, y, .ink);
        y += 10;
    }
    const by = y0 + h - 13;
    draw.hline(x0 + 4, by - 3, w - 8, .tan);
    _ = draw.text(if (app.sound) "A: SOUND ON" else "A: SOUND OFF", x0 + 5, by, if (app.sound) .leaf else .faded);
    _ = draw.text_right("B: BACK", x0 + w - 5, by, .faded);
}

// -- game screen ---------------------------------------------------------

fn game_screen(app: *const App) void {
    draw.clear(.paper);
    hud(app);
    strip(app);
    draw.hline(0, L.rule_y, L.width, .tan);
    const bottom = app.log_bottom();
    log_view(app, L.log_top, bottom, app.view_end);
    switch (app.phase) {
        .more => footer("A: MORE", true),
        .prompt => if (app.prompt().kind == .game_over) end_scene(app) else prompt_box(app, bottom),
        .shot_ready, .shot_cue, .shot_done => shot_scene(app),
        .scene => {
            scene_picture(app);
            footer("A: CONTINUE", false);
        },
    }
}

fn hud(app: *const App) void {
    const h = &app.hud;
    _ = draw.text(app.date_text(), L.text_x, L.hud_row1_y, .ink);
    var buf: [12]u8 = undefined;
    const mi = std.fmt.bufPrint(&buf, "{d}", .{if (h.valid) h.mileage_shown else 0}) catch "";
    const x = draw.text_right(mi, L.width - 2, L.hud_row1_y, .ink);
    _ = draw.text("MI", x - 3 * font.cell_w + 1, L.hud_row1_y, .rasp);
    if (!h.valid) {
        draw.text_center("OUTFITTING AT INDEPENDENCE", L.hud_row2_y, .faded);
        return;
    }
    // F 123  B 1450  C 60  M 18  $ 52, spread over the width.
    const labels = [_][]const u8{ "F", "B", "C", "M", "$" };
    const values = [_]i32{ h.food, h.bullets, h.clothing, h.misc, h.cash };
    var bufs: [5][12]u8 = undefined;
    var strs: [5][]const u8 = undefined;
    var chars: i32 = 0;
    for (values, 0..) |v, i| {
        strs[i] = std.fmt.bufPrint(&bufs[i], "{d}", .{v}) catch "";
        chars += @as(i32, @intCast(strs[i].len)) + 1;
    }
    const used = chars * font.cell_w;
    const gap = @max(2, @divTrunc(L.width - 4 - used, 4));
    var cx: i32 = L.text_x;
    for (labels, 0..) |lab, i| {
        cx = draw.text(lab, cx, L.hud_row2_y, .rasp);
        cx = draw.text(strs[i], cx, L.hud_row2_y, .ink);
        cx += gap;
    }
}

/// The trail strip: the markers at their mileage (Independence, South
/// Pass, the Blue Mountains, Oregon City) and the wagon sliding to the
/// true mileage, wheels turning while it moves.
fn strip(app: *const App) void {
    const x0: i32 = 6;
    const x1: i32 = L.width - 7;
    const y = L.strip_y;
    var x = x0;
    while (x < x1) : (x += 3) draw.fill_rect(x, y + 8, 2, 1, .tan);
    for (art.markers) |mk| {
        const sz = art.size(mk.pic);
        const mx = x0 + @divTrunc(@as(i32, mk.mile) * (x1 - x0), 2040) - @divTrunc(@as(i32, sz.w), 2);
        art.draw(mk.pic, std.math.clamp(mx, 0, L.width - @as(i32, sz.w)), y, 0, draw.sink);
    }
    const target = if (app.hud.valid) app.hud.mileage_true else 0;
    const moving = app.wagon_miles != target;
    const wx = x0 + @divTrunc(std.math.clamp(app.wagon_miles, 0, 2040) * (x1 - x0), 2040) - 6;
    art.draw(.strip_wagon, std.math.clamp(wx, 0, L.width - 12), y, if (moving) app.frame / 6 else 0, draw.sink);
}

/// Log rows ending at `end`, bottom-aligned in [top, bottom).
fn log_view(app: *const App, top: i32, bottom: i32, end: u32) void {
    const lg = app.log;
    var i = end;
    var y = bottom - 1;
    const oldest = lg.oldest();
    while (i > oldest) {
        const r = lg.get(i - 1);
        const h = r.height();
        if (y - h < top) break;
        y -= h;
        i -= 1;
        draw_row(r, y, app.frame);
    }
}

fn draw_row(r: *const log_mod.Row, y: i32, tick: u32) void {
    switch (r.kind) {
        .picture => {
            const pic: art.Pic = @fromBackingInt(@intCast(r.buf[0]));
            const sz = art.size(pic);
            art.draw(pic, @divTrunc(L.width - @as(i32, sz.w), 2), y + 2, tick / 30, draw.sink);
        },
        .gap => {},
        .rule => {
            // -- APRIL 12 1847 --
            const w = font.width(r.len);
            const lx = @divTrunc(L.width - w, 2);
            _ = draw.text(r.str(), lx, y + 2, .faded);
            var x: i32 = 6;
            while (x < lx - 6) : (x += 4) draw.fill_rect(x, y + 5, 2, 1, .tan);
            x = lx + w + 6;
            while (x < L.width - 6) : (x += 4) draw.fill_rect(x, y + 5, 2, 1, .tan);
        },
        .text => {
            const c: draw.Color = switch (r.style) {
                .ink => .ink,
                .warn => .rasp_ink,
                .answer => .rasp,
                .good => .leaf,
            };
            _ = draw.text(r.str(), L.text_x + r.x, y + 1, c);
        },
    }
}

fn footer(label: []const u8, arrow: bool) void {
    const y = L.height - L.footer_h;
    draw.fill_rect(0, y, L.width, L.footer_h, .shade);
    draw.hline(0, y, L.width, .rasp);
    _ = draw.text("SELECT: LOG", L.text_x, y + 3, .faded);
    var x: i32 = L.width - 2;
    if (arrow) {
        var buf: [1]u8 = .{font.tri_down};
        x = draw.text_right(&buf, x, y + 3, .rasp_ink) - 3;
    }
    _ = draw.text_right(label, x, y + 3, .rasp_ink);
}

/// The tombstone (with the cause on the stone) or the arrival, over the log
/// area.
fn scene_picture(app: *const App) void {
    switch (app.scene) {
        .none => {},
        .arrival => art.draw(.arrival, 0, L.end_y, 0, draw.sink),
        .tomb => {
            art.draw(.tombstone, 0, L.end_y, 0, draw.sink);
            const r = art.layout.tomb_text;
            var lines: [5][]const u8 = @splat("");
            var n: usize = 0;
            lines[n] = app.tomb_cause;
            n += 1;
            if (app.tomb_cause2.len > 0) {
                lines[n] = app.tomb_cause2;
                n += 1;
            }
            n += 1; // a blank row
            const d = app.tomb_date_text();
            if (std.mem.lastIndexOfScalar(u8, d, ' ')) |sp| {
                lines[n] = d[0..sp];
                lines[n + 1] = d[sp + 1 ..];
                n += 2;
            }
            for (lines[0..n], 0..) |ln, i| {
                const w = font.width(ln.len);
                const tx = r.x + @divTrunc(r.w - w, 2);
                _ = draw.text(ln, tx, L.end_y + r.y + @as(i32, @intCast(i)) * 8, .ink);
            }
        },
    }
}

/// The end of a game: the scene, the ending and "A: NEW GAME".
fn end_scene(app: *const App) void {
    scene_picture(app);
    const p = app.prompt();
    const y = L.height - 20;
    draw.fill_rect(0, y, L.width, 20, .shade);
    draw.hline(0, y, L.width, .rasp);
    draw.text_center(app_mod.outcome_text(p.outcome), y + 3, if (p.outcome == .arrived) .leaf else .rasp_ink);
    if ((app.phase_frames / 30) % 2 == 0) draw.text_center("A: NEW GAME", y + 11, .ink);
}

fn prompt_box(app: *const App, y0: i32) void {
    const p = app.prompt();
    draw.fill_rect(0, y0, L.width, L.height - y0, .shade);
    draw.hline(0, y0, L.width, .rasp);
    var y = y0 + 1 + L.box_pad_top;
    if (p.kind != .game_over and p.question.len > 0) {
        var spans: [2]text.Span = undefined;
        const n = @min(2, text.wrap(p.question, font.cols, &spans));
        for (spans[0..n]) |sp| {
            _ = draw.text(p.question[sp.start..sp.end], L.text_x, y + 1, .rasp_ink);
            y += L.question_h;
        }
    }
    switch (p.kind) {
        .yes_no => {
            options(app, &.{ "YES", "NO" }, y);
        },
        .choice => {
            const n = @max(p.n_options, 1);
            options(app, p.options[0..n], y);
        },
        .number => spinner(app, y),
        // The shooting scene and the end scene replace the box.
        .shoot, .game_over => {},
    }
}

fn options(app: *const App, labels: []const []const u8, y0: i32) void {
    var y = y0;
    for (labels, 0..) |lab, i| {
        if (i == app.cursor) {
            draw.fill_rect(0, y, L.width, L.option_h, .leaf);
            var g: [1]u8 = .{font.tri_right};
            _ = draw.text(&g, L.text_x + 1, y + 2, .paper);
            _ = draw.text(lab, L.text_x + 2 * font.cell_w, y + 2, .paper);
        } else {
            _ = draw.text(lab, L.text_x + 2 * font.cell_w, y + 2, .ink);
        }
        y += L.option_h;
    }
}

fn spinner(app: *const App, y: i32) void {
    const s = &app.spin;
    const p = app.prompt();
    const n: i32 = s.digits;
    const w = (n + 1) * 12;
    var x = @divTrunc(L.width - w, 2);
    _ = draw.text2("$", x, y + 1, .ink);
    x += 12;
    var k: i32 = n - 1;
    var v: i32 = s.value;
    var digs: [12]u8 = undefined;
    var j: usize = 0;
    while (j < @as(usize, @intCast(n))) : (j += 1) {
        digs[@as(usize, @intCast(n)) - 1 - j] = '0' + @as(u8, @intCast(@mod(v, 10)));
        v = @divTrunc(v, 10);
    }
    j = 0;
    while (k >= 0) : (k -= 1) {
        const ch = digs[j .. j + 1];
        if (k == s.caret) {
            draw.fill_rect(x - 1, y, 12, 17, .leaf);
            _ = draw.text2(ch, x, y + 1, .paper);
            draw.fill_rect(x - 1, y + 18, 12, 2, .leaf);
        } else {
            _ = draw.text2(ch, x, y + 1, .ink);
        }
        x += 12;
        j += 1;
    }
    var buf: [32]u8 = undefined;
    const iy = y + L.spinner_h + 1;
    const purchase = (p.line >= 860 and p.line <= 1090) or p.line == 2330;
    if (purchase) {
        const pool = if (p.line == 860) 700 else s.max;
        const left = std.fmt.bufPrint(&buf, "LEFT ${d}", .{pool - s.value}) catch "";
        _ = draw.text(left, L.text_x, iy, .ink);
    } else {
        const range = std.fmt.bufPrint(&buf, "{d}-{d}", .{ s.min, s.max }) catch "";
        _ = draw.text(range, L.text_x, iy, .faded);
    }
    _ = draw.text_right("B: RESET", L.width - 2, iy, .faded);
}

/// Where the shot lands in each scene (picture coordinates).
fn target_of(reason: G.ShotReason) [2]i32 {
    return switch (reason) {
        .hunt => .{ 104, 40 },
        .riders => .{ 84, 40 },
        .bandits => .{ 128, 34 },
        .animals => .{ 92, 52 },
    };
}

/// The shooting scene with the cue in its sky band (SPEC 4.4, 5): GET
/// READY, then the word and one button per letter, the next one lit;
/// then the muzzle flash, a hit or a miss, and the time.
fn shot_scene(app: *const App) void {
    const s = &app.shot;
    const p = app.prompt();
    const sy = L.scene_y;
    art.draw(art.shootScene(p.shot), 0, sy, 0, draw.sink);
    const band = art.layout.shoot_cue;
    const bx = band.x;
    const by = sy + band.y;
    const ink: draw.Color = if (p.shot == .hunt) .ink else .paper;
    var buf: [24]u8 = undefined;
    switch (app.phase) {
        .shot_ready => text2_center("GET READY", by + 2, ink),
        .shot_cue => {
            _ = draw.text2(p.word.text(), bx + 4, by + 2, ink);
            const n: i32 = s.n;
            var x = bx + band.w - n * 14 - (n - 1) * 3 - 2;
            var k: u8 = 0;
            while (k < s.n) : (k += 1) {
                const st: art.ButtonState = if (k < s.idx) .done else if (k == s.idx) .highlighted else .normal;
                art.draw(art.button(s.seq[k]), x, by + 3, @backingInt(st), draw.sink);
                x += 17;
            }
        },
        .shot_done => {
            const t: []const u8 = if (s.misfire) "MISFIRE!" else if (!s.correct) "WRONG!" else blk: {
                const h = s.hundredths();
                break :blk std.fmt.bufPrint(&buf, "{d}.{d:0>2} SEC", .{ h / 100, h % 100 }) catch "";
            };
            text2_center(t, by + 2, if (s.correct) ink else .rasp);
            const age = app.phase_frames;
            if (age < 12) art.draw(.muzzle_flash, 4, sy + 58, age / 4, draw.sink);
            if (age >= 6) {
                const tg = target_of(p.shot);
                const mark: art.Pic = if (s.correct) .mark_hit else .mark_miss;
                const sz = art.size(mark);
                art.draw(mark, tg[0] - @divTrunc(@as(i32, sz.w), 2), sy + tg[1] - @divTrunc(@as(i32, sz.h), 2), 0, draw.sink);
            }
        },
        else => {},
    }
}

// -- log history -----------------------------------------------------------

fn history(app: *const App) void {
    draw.clear(.paper);
    draw.fill_rect(0, 0, L.width, 11, .shade);
    draw.hline(0, 11, L.width, .rasp);
    _ = draw.text("LOG", L.text_x, 2, .rasp_ink);
    var buf: [3]u8 = .{ font.arrow_up, font.arrow_down, ' ' };
    const x = draw.text_right("B: BACK", L.width - 2, 2, .faded);
    _ = draw.text_right(buf[0..2], x - 6, 2, .faded);
    const end = app.view_end - @min(app.hist_scroll, app.view_end);
    log_view(app, 13, L.height, end);
    // Scroll bar: where the view sits in the history.
    const span = app.view_end - app.log.oldest();
    if (span > 0 and app.hist_scroll > 0) {
        const track_h: i32 = L.height - 14;
        const pos = track_h - @as(i32, @intCast(@divTrunc(@as(u64, app.hist_scroll) * @as(u64, @intCast(track_h - 6)), span))) - 6;
        draw.fill_rect(L.width - 2, 13 + pos, 2, 6, .tan);
    }
}
