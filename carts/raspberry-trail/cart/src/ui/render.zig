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

const App = app_mod.App;

pub fn frame(app: *const App) void {
    switch (app.screen) {
        .title => title(app),
        .game => game_screen(app),
        .history => history(app),
    }
}

// -- title -------------------------------------------------------------

fn title(app: *const App) void {
    draw.clear(.paper);
    draw.fill_rect(0, 0, L.width, 4, .rasp);
    draw.text_center("THE", 16, .ink);
    text2_center("RASPBERRY", 28, .rasp);
    text2_center("TRAIL", 48, .rasp);
    // The trail, with the wagon creeping along it.
    const miles: i32 = @intCast((app.frame / 2) % 2200);
    strip(70, @min(miles, 2040));
    if ((app.phase_frames / 30) % 2 == 0 or app.phase_frames < 30) draw.text_center("A: START", 88, .ink);
    draw.text_center("A PORT OF THE 1978 MECC", 106, .faded);
    draw.text_center("BASIC LISTING", 115, .faded);
    draw.fill_rect(0, L.height - 2, L.width, 2, .rasp);
}

fn text2_center(s: []const u8, y: i32, c: draw.Color) void {
    const w = @as(i32, @intCast(s.len)) * 12 - 2;
    _ = draw.text2(s, @divTrunc(L.width - w, 2), y, c);
}

// -- game screen ---------------------------------------------------------

fn game_screen(app: *const App) void {
    draw.clear(.paper);
    hud(app);
    strip(L.strip_y, if (app.hud.valid) app.hud.mileage_true else 0);
    draw.hline(0, L.rule_y, L.width, .tan);
    const bottom = app.log_bottom();
    log_view(app, L.log_top, bottom, app.view_end);
    switch (app.phase) {
        .more => footer(),
        else => prompt_box(app, bottom),
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

/// The trail strip (M1: a track with the passes marked and a small
/// wagon at `miles`; M2 paints it).
fn strip(y: i32, miles: i32) void {
    const x0: i32 = 6;
    const x1: i32 = L.width - 7;
    const ty = y + 6;
    draw.fill_rect(x0, ty, x1 - x0, 2, .tan);
    // South Pass (950) and the Blue Mountains (1700).
    for ([_]i32{ 950, 1700 }) |m| {
        const mx = x0 + @divTrunc(m * (x1 - x0), 2040);
        draw.fill_rect(mx - 1, ty - 2, 3, 2, .faded);
        draw.plot(mx, ty - 3, draw.px(.faded));
    }
    draw.fill_rect(x0 - 2, ty - 1, 2, 4, .faded);
    // Oregon City: a raspberry flag.
    draw.vline(x1 + 1, ty - 6, 8, .ink);
    draw.fill_rect(x1 + 2, ty - 6, 4, 3, .rasp);
    // The wagon: a raspberry canopy over a brown box on two wheels.
    const wx = x0 + @divTrunc(std.math.clamp(miles, 0, 2040) * (x1 - x0), 2040) - 4;
    draw.fill_rect(wx + 1, ty - 6, 6, 3, .rasp);
    draw.fill_rect(wx, ty - 3, 8, 2, .faded);
    draw.fill_rect(wx + 1, ty - 1, 2, 2, .ink);
    draw.fill_rect(wx + 5, ty - 1, 2, 2, .ink);
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
        draw_row(r, y);
    }
}

fn draw_row(r: *const log_mod.Row, y: i32) void {
    switch (r.kind) {
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

fn footer() void {
    const y = L.height - L.footer_h;
    draw.fill_rect(0, y, L.width, L.footer_h, .shade);
    draw.hline(0, y, L.width, .rasp);
    _ = draw.text("SELECT: LOG", L.text_x, y + 3, .faded);
    var buf: [8]u8 = undefined;
    buf[0] = font.tri_down;
    const x = draw.text_right(buf[0..1], L.width - 2, y + 3, .rasp_ink);
    _ = draw.text_right("A: MORE", x - 3, y + 3, .rasp_ink);
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
        .shoot => shot(app, y),
        .game_over => {
            const o = app_mod.outcome_text(p.outcome);
            draw.text_center(o, y + 1, if (p.outcome == .arrived) .leaf else .rasp_ink);
            if ((app.phase_frames / 30) % 2 == 0) draw.text_center("A: NEW GAME", y + 1 + L.question_h, .ink);
        },
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

fn shot(app: *const App, y: i32) void {
    const s = &app.shot;
    const p = app.prompt();
    var buf: [24]u8 = undefined;
    const word_y = y + 1;
    switch (app.phase) {
        .shot_ready => text2_center("GET READY", word_y, .ink),
        .shot_cue => text2_center(p.word.text(), word_y, .rasp),
        .shot_done => {
            if (s.misfire) {
                text2_center("MISFIRE!", word_y, .rasp);
            } else if (!s.correct) {
                text2_center("WRONG!", word_y, .rasp);
            } else {
                const h = s.hundredths();
                const t = std.fmt.bufPrint(&buf, "{d}.{d:0>2} SEC", .{ h / 100, h % 100 }) catch "";
                text2_center(t, word_y, .leaf);
            }
        },
        else => text2_center(p.word.text(), word_y, .rasp),
    }
    const n: i32 = s.n;
    const box = L.shot_box;
    const gap: i32 = 6;
    const total = n * box + (n - 1) * gap;
    var bx = @divTrunc(L.width - total, 2);
    const by = y + L.shot_word_h + 2;
    var k: u8 = 0;
    while (k < s.n) : (k += 1) {
        const state: enum { hidden, pending, next, done, wrong } = blk: {
            if (app.phase == .shot_ready) break :blk .hidden;
            if (app.phase == .shot_done and !s.correct and !s.misfire and k == s.wrong_at) break :blk .wrong;
            if (k < s.idx) break :blk .done;
            if (k == s.idx and app.phase == .shot_cue) break :blk .next;
            if (app.phase == .shot_done and s.misfire) break :blk .hidden;
            break :blk .pending;
        };
        const fill: draw.Color, const ink: draw.Color = switch (state) {
            .hidden => .{ .paper, .tan },
            .pending => .{ .paper, .ink },
            .next => .{ .leaf, .paper },
            .done => .{ .tan, .faded },
            .wrong => .{ .rasp, .paper },
        };
        draw.fill_rect(bx, by, box, box, fill);
        draw.frame(bx, by, box, box, if (state == .next) .leaf else .faded);
        if (state != .hidden) {
            var g: [1]u8 = .{switch (s.seq[k]) {
                .up => font.arrow_up,
                .down => font.arrow_down,
                .left => font.arrow_left,
                .right => font.arrow_right,
                .a => 'A',
                .b => 'B',
            }};
            _ = draw.text_px(&g, bx + 4, by + 2, L.width, draw.px(ink), 2);
        } else {
            _ = draw.text("?", bx + 6, by + 5, .tan);
        }
        bx += box + gap;
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
