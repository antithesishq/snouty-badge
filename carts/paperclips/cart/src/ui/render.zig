//! Draws the App (app.zig) every frame: the title, the game screen
//! (header, status line, page tab, rows, footer, ticker), the message log,
//! the HypnoDrones flash and the stage 2 wall. Black on white, like the
//! original.
const std = @import("std");
const G = @import("game");
const app_mod = @import("app.zig");
const pages = @import("pages.zig");
const draw = @import("draw.zig");
const font = @import("font.zig");
const L = @import("layout.zig");
const numfmt = @import("numfmt.zig");
const text = @import("text.zig");
const title = @import("title.zig");
const combat_view = @import("combat_view.zig");

const App = app_mod.App;

pub fn frame(app: *App) void {
    switch (app.screen) {
        .title => title.screen(app),
        .game => if (app.hypno_on) hypno(app) else game_screen(app),
        .log => log_screen(app),
        .wall => if (app.hypno_on) hypno(app) else wall(app),
    }
}

fn game_screen(app: *App) void {
    draw.clear(.white);
    header(app.game);
    status_line(app);
    tab_bar(app);
    rows(app);
    ticker(app);
}

// -- header: "Paperclips: n", big while it fits --------------------------

fn header(g: *const G.Game) void {
    var buf: [96]u8 = undefined;
    const n = G.clips_text(g, &buf);
    const label = "Paperclips:";
    const label_w = font.width(label.len);
    const big_w = @as(i32, @intCast(n.len)) * 12 - 2;
    if (label_w + 6 + big_w <= draw.width - 2) {
        _ = draw.text(label, 2, 5, .black);
        _ = draw.text_px(n, draw.width - 1 - big_w, 0, draw.width, draw.px(.black), 2);
    } else if (big_w <= draw.width - 2) {
        _ = draw.text_px(n, @divTrunc(draw.width - big_w, 2), 0, draw.width, draw.px(.black), 2);
    } else if (n.len <= L.cols - 1) {
        _ = draw.text(label, 2, 0, .black);
        _ = draw.text_right(n, L.right_x, 8, .black);
    } else {
        // Longer than a line (stage 3 and the ending): the digits in two
        // lines under no label, split at a comma.
        var cut = n.len - (L.cols - 1);
        while (cut < n.len and n[cut] != ',') cut += 1;
        cut = @min(cut + 1, n.len);
        if (cut > L.cols) cut = n.len - (L.cols - 1);
        _ = draw.text_right(n[0..cut], L.right_x, 0, .black);
        _ = draw.text_right(n[cut..], L.right_x, 8, .black);
    }
}

fn status_line(app: *App) void {
    const s = pages.status(app.game, app.arena, L.cols);
    _ = draw.text(s, 2, L.status_y, .black);
}

// -- page tab: "< BUSINESS >   2/6 !" ------------------------------------

fn tab_bar(app: *App) void {
    draw.fill_rect(0, L.tab_y, draw.width, L.tab_h, .black);
    const y = L.tab_y + 1;
    const pos = app.page_position();
    if (pos.count > 1) _ = draw.text(&.{font.tri_left}, 2, y, .white);
    const name = app.page.title();
    const x_end = draw.text(name, 10, y, .white);
    if (pos.count > 1) _ = draw.text(&.{font.tri_right}, x_end + 1, y, .white);

    var buf: [8]u8 = undefined;
    var n: usize = 0;
    n += numfmt.plain_u(buf[n..], pos.index + 1).len;
    buf[n] = '/';
    n += 1;
    n += numfmt.plain_u(buf[n..], pos.count).len;
    const news = app.any_news();
    const right = if (news) L.right_x - 12 else L.right_x;
    _ = draw.text_right(buf[0..n], right, y, .white);
    if (news and (app.frame / 20) % 3 != 0) {
        // A white box with a black "!" (blinks).
        draw.fill_rect(L.right_x - 7, L.tab_y + 1, 8, L.tab_h - 2, .white);
        _ = draw.text("!", L.right_x - 5, y, .black);
    }
}

// -- rows ----------------------------------------------------------------

fn rows(app: *App) void {
    const list = app.rows.slice();
    const pi = @intFromEnum(app.page);
    const cursor = app.cursor_ix[pi];
    const area = app.list_lines();
    const scroll = app.scroll[pi];

    var line: usize = 0;
    for (list, 0..) |r, i| {
        defer line += r.lines;
        if (line + r.lines <= scroll) continue;
        if (line >= scroll + area) break;
        const y = L.rows_y + @as(i32, @intCast(line - scroll)) * L.row_h;
        row(app, r, y, i == cursor and list.len > 0);
    }

    // Scroll marks: a small triangle on the right when rows are hidden.
    var total: usize = 0;
    for (list) |r| total += r.lines;
    if (scroll > 0) mark_up(L.rows_y);
    if (scroll + area < total) mark_down(L.rows_y + @as(i32, @intCast(area)) * L.row_h - 3);

    if (area < L.rows_visible and list.len > 0) footer(app, list[cursor]);
}

fn mark_up(y: i32) void {
    draw.hline(155, y, 1, .grey);
    draw.hline(154, y + 1, 3, .grey);
}

fn mark_down(y: i32) void {
    draw.hline(154, y + 1, 3, .grey);
    draw.hline(155, y + 2, 1, .grey);
}

fn row(app: *App, r: pages.Row, y: i32, selected: bool) void {
    const fg: draw.Color = if (selected) .white else .black;
    const off: draw.Color = if (selected) .dim else .grey;
    if (selected) draw.fill_rect(0, y - 1, draw.width, @as(i32, r.lines) * L.row_h + 1, .black);
    switch (r.kind) {
        .note => {
            if (r.strong and !selected) draw.fill_rect(0, y - 1, draw.width, @as(i32, r.lines) * L.row_h, .face);
            var spans: [4]text.Span = undefined;
            const n = @min(text.wrap(r.left, pages.note_cols, &spans), r.lines);
            for (spans[0..n], 0..) |sp, k| {
                _ = draw.text(r.left[sp.start..sp.end], L.text_x, y + @as(i32, @intCast(k)) * L.row_h, fg);
            }
        },
        .text => {
            const right_w = if (r.right.len > 0) font.width(r.right.len) + 6 else 0;
            if (r.strong and !selected) draw.fill_rect(0, y - 1, draw.width, L.row_h, .face);
            _ = draw.text_clip(r.left, L.text_x, y, L.right_x - right_w, fg);
            if (r.right.len > 0) _ = draw.text_right(r.right, L.right_x, y, fg);
        },
        .heading => {
            _ = draw.text(r.left, L.text_x, y, fg);
            const x = L.text_x + font.width(r.left.len) + 3;
            draw.hline(x, y + 3, L.right_x - x, if (selected) .white else .grey);
        },
        .button, .project => {
            const c: draw.Color = if (r.enabled) fg else off;
            const label_w = font.width(r.left.len);
            const right_w = if (r.right.len > 0) font.width(r.right.len) + 6 else 0;
            const max_label = L.right_x - right_w;
            // A button face behind the label, like the browser's buttons.
            if (!selected) {
                const face_w = @min(label_w + 4, max_label - L.text_x + 2);
                draw.fill_rect(L.text_x - 2, y - 1, face_w, L.row_h, if (r.enabled) .face else .white);
                if (!r.enabled) draw.frame(L.text_x - 2, y - 1, face_w, L.row_h, .faint);
            }
            _ = draw.text_clip(r.left, L.text_x, y, max_label, c);
            if (r.right.len > 0) {
                if (r.fade == 255) {
                    _ = draw.text_right(r.right, L.right_x, y, fg);
                } else {
                    // The quantum display fades out (its CSS opacity).
                    const f: u32 = r.fade;
                    const level: u32 = if (selected) f else 255 - f;
                    const x0 = L.right_x - font.width(r.right.len);
                    _ = draw.text_px(r.right, x0, y, draw.width, draw.pixel_of(level << 16 | level << 8 | level), 1);
                }
            }
        },
        .value => {
            // "< $0.25 >": the arrows show which way A and B move it.
            const vx = L.right_x - 7 - font.width(r.right.len);
            _ = draw.text_clip(r.left, L.text_x, y, vx - 8, fg);
            _ = draw.text_right(r.right, L.right_x - 7, y, fg);
            _ = draw.text(&.{font.tri_right}, L.right_x - 5, y, if (r.enabled) fg else off);
            _ = draw.text(&.{font.tri_left}, vx - 7, y, if (r.enabled_b) fg else off);
        },
        .chips => chips(app.game, y),
        .battle => combat_view.draw(app.game, 2, y - 1, draw.width - 4, @as(i32, r.lines) * L.row_h - 1),
        .slider => slider(r, y, selected),
        .grid => grid(app.game, y, selected),
        .stock_head => {
            stock_cols(.{ "Stk", "Amt", "Price", "Total", "P/L" }, y, if (selected) .white else .grey);
            draw.hline(L.text_x, y + 7, L.right_x - L.text_x, if (selected) .white else .faint);
        },
        .stock => {
            var parts: [5][]const u8 = .{ r.left, "", "", "", "" };
            var it = std.mem.splitScalar(u8, r.right, '|');
            var k: usize = 1;
            while (it.next()) |p| : (k += 1) if (k < 5) {
                parts[k] = p;
            };
            stock_cols(parts, y, fg);
        },
    }
}

/// The work/think range input: "Work [----o----] Think".
fn slider(r: pages.Row, y: i32, selected: bool) void {
    const fg: draw.Color = if (selected) .white else .black;
    const x0 = draw.text(r.left, L.text_x, y, fg) + 4;
    const x1 = L.right_x - font.width(r.right.len) - 4;
    _ = draw.text_right(r.right, L.right_x, y, fg);
    draw.hline(x0, y + 3, x1 - x0, if (selected) .white else .grey);
    const knob = x0 + @divTrunc((x1 - x0 - 4) * @as(i32, r.value), 200);
    draw.fill_rect(knob, y, 4, 7, fg);
}

/// Five columns: the symbol left, the numbers right-aligned.
fn stock_cols(parts: [5][]const u8, y: i32, c: draw.Color) void {
    _ = draw.text(parts[0], L.text_x, y, c);
    const rights = [_]i32{ 64, 96, 128, L.right_x };
    for (parts[1..], rights) |p, rx| _ = draw.text_right(p, rx, y, c);
}

/// Quantum chips: ten squares whose brightness is the chip's value
/// (the original sets each div's opacity to it; negative reads as clear).
fn chips(g: *const G.Game, y: i32) void {
    const size: i32 = 11;
    const gap: i32 = 4;
    const x0: i32 = L.text_x + 3;
    for (g.q_chips, 0..) |c, i| {
        if (!g.panels.q_chip[i]) continue;
        const x = x0 + @as(i32, @intCast(i)) * (size + gap);
        const v = std.math.clamp(c.value, 0, 1);
        // Opacity of a black square over white.
        const level: u32 = @intFromFloat(@round(255 - v * 255));
        const shade = level << 16 | level << 8 | level;
        draw.fill_rect_px(x, y + 1, size, size, draw.pixel_of(shade));
        draw.frame(x - 1, y, size + 2, size + 2, if (c.active != 0) .grey else .faint);
    }
}

/// The payoff grid: column and row labels and the four cells, the cell
/// being played shaded, the two strategies of the round below.
fn grid(g: *const G.Game, y: i32, selected: bool) void {
    const fg: draw.Color = if (selected) .white else .black;
    const x_lab: i32 = L.text_x;
    const x_a: i32 = 82;
    const x_b: i32 = 122;
    const cell_w: i32 = 38;
    var buf: [16]u8 = undefined;
    const la: []const u8 = if (g.grid_labels_set) G.strategy.choice_a_names[g.grid_labels] else "Move A";
    const lb: []const u8 = if (g.grid_labels_set) G.strategy.choice_b_names[g.grid_labels] else "Move B";
    // Column heads "A" and "B"; the row labels carry the move names.
    _ = draw.text("A", x_a + 9, y, fg);
    _ = draw.text("B", x_b + 9, y, fg);
    const vals = [4]f64{ g.aa, g.ab, g.ba, g.bb };
    const cross = [4]f64{ g.aa, g.ba, g.ab, g.bb };
    const lit: usize = switch (g.payoff_cell) {
        .none => 99,
        .aa => 0,
        .ab => 1,
        .ba => 2,
        .bb => 3,
    };
    for (0..2) |ry| {
        const yy = y + L.row_h * @as(i32, @intCast(ry + 1));
        _ = draw.text(if (ry == 0) "A" else "B", x_lab, yy, fg);
        _ = draw.text_clip(if (ry == 0) la else lb, x_lab + 9, yy, x_a - 4, fg);
        for (0..2) |cx| {
            const k = ry * 2 + cx;
            const x = if (cx == 0) x_a else x_b;
            if (lit == k) draw.fill_rect(x - 2, yy - 1, cell_w - 2, L.row_h, if (selected) .grey else .faint);
            var n: usize = numfmt.plain_u(&buf, @intFromFloat(@max(0, vals[k]))).len;
            buf[n] = ',';
            n += 1;
            n += numfmt.plain_u(buf[n..], @intFromFloat(@max(0, cross[k]))).len;
            _ = draw.text(buf[0..n], x, yy, fg);
        }
    }
    if (g.strat_names_shown) {
        const yy = y + L.row_h * 3;
        const hs = G.strategy.names[g.h_strat];
        const vs = G.strategy.names[g.v_strat];
        const x = draw.text(hs, x_lab, yy, fg);
        const x2 = draw.text(" vs ", x, yy, if (selected) .white else .grey);
        _ = draw.text(vs, x2, yy, fg);
    }
}

// -- footer: the selected row's detail (projects) ------------------------

fn footer(app: *App, r: pages.Row) void {
    const top = L.rows_y + @as(i32, @intCast(app.list_lines())) * L.row_h;
    draw.hline(0, top + 1, draw.width, .grey);
    if (r.detail.len == 0) return;
    var spans: [12]text.Span = undefined;
    const n = text.wrap(r.detail, L.cols, &spans);
    const shown = @min(n, spans.len);
    var first: usize = 0;
    if (shown > L.footer_lines) {
        // Step down a line at a time, pause at the end, start over.
        const steps = shown - L.footer_lines + 2;
        const s = (app.footer_frames / app_mod.knobs.footer_step_frames) % steps;
        first = @min(s, shown - L.footer_lines);
    }
    for (0..L.footer_lines) |k| {
        const li = first + k;
        if (li >= shown) break;
        const sp = spans[li];
        _ = draw.text(r.detail[sp.start..sp.end], L.text_x, top + 4 + @as(i32, @intCast(k)) * L.row_h, .black);
    }
}

// -- ticker: the newest message, two lines -------------------------------

fn ticker(app: *App) void {
    draw.hline(0, L.rule_y, draw.width, .grey);
    const msg = app_mod.message(app.game, 0) orelse return;
    var spans: [8]text.Span = undefined;
    const width = L.cols - 1;
    const n = @min(text.wrap(msg, width, &spans), spans.len);
    var first: usize = 0;
    if (n > L.ticker_lines) {
        const pairs = (n + 1) / 2;
        first = 2 * ((app.ticker_frames / app_mod.knobs.ticker_page_frames) % pairs);
    }
    // A new message flashes the prompt for half a second.
    const fresh = app.msg_age < 30 and (app.msg_age / 5) % 2 == 0;
    if (fresh) draw.fill_rect(0, L.ticker_y - 1, 7, L.ticker_line_h, .black);
    _ = draw.text(">", 1, L.ticker_y, if (fresh) .white else .black);
    for (0..L.ticker_lines) |k| {
        const li = first + k;
        if (li >= n) break;
        const sp = spans[li];
        _ = draw.text(msg[sp.start..sp.end], 8, L.ticker_y + @as(i32, @intCast(k)) * L.ticker_line_h, .black);
    }
}

// -- the message log (Start) ---------------------------------------------

fn log_screen(app: *App) void {
    draw.clear(.white);
    draw.fill_rect(0, 0, draw.width, 9, .black);
    _ = draw.text("CONSOLE", 2, 1, .white);
    _ = draw.text_right("Start: back", L.right_x, 1, .white);
    if (!app.playing) return;
    // Lay out from the newest message up, then skip `log_scroll` lines.
    const top: i32 = 11;
    const lines_on_screen: usize = 14;
    var budget_skip = app.log_scroll;
    var line_y: i32 = top + @as(i32, @intCast(lines_on_screen - 1)) * L.row_h;
    var k: u32 = 0;
    var any_hidden_above = false;
    outer: while (app_mod.message(app.game, k)) |msg| : (k += 1) {
        var spans: [8]text.Span = undefined;
        const n = @min(text.wrap(msg, L.cols - 1, &spans), spans.len);
        var li = n;
        while (li > 0) {
            li -= 1;
            if (budget_skip > 0) {
                budget_skip -= 1;
                continue;
            }
            if (line_y < top) {
                any_hidden_above = true;
                break :outer;
            }
            const sp = spans[li];
            if (li == 0) _ = draw.text(if (k == 0) ">" else ".", 1, line_y, if (k == 0) .black else .grey);
            _ = draw.text(msg[sp.start..sp.end], 8, line_y, if (k == 0) .black else .black);
            line_y -= L.row_h;
        }
    }
    if (app.log_scroll > budget_skip and app.log_scroll > 0) mark_down(draw.height - 4);
    if (any_hidden_above) mark_up(top);
    // Clamp the scroll to the oldest line.
    if (budget_skip > 0) app.log_scroll -= budget_skip;
}

// -- the HypnoDrones flash and the M1 wall -------------------------------

fn hypno(app: *App) void {
    // The original's longBlink: every 32 ms the overlay toggles; its text
    // grows from "Release" to "Release the Hypno Drones".
    const t = app.game.hypno_event_ms orelse app.game.now_ms;
    const step = (app.game.now_ms - t) / 32;
    const shown = step % 2 == 0;
    draw.clear(if (shown) .black else .white);
    if (!shown) return;
    const words: []const []const u8 = if (step > 55)
        &.{ "Release", "the", "Hypno", "Drones" }
    else
        &.{"Release"};
    const offset: i32 = if (step > 30 and step < 40) 3 else if (step > 45 and step < 55) 1 else 0;
    const lh: i32 = 22;
    const h = @as(i32, @intCast(words.len)) * lh;
    var y = @divTrunc(draw.height - h, 2) + offset * 8;
    for (words) |w| {
        const wpx = @as(i32, @intCast(w.len)) * 12 - 2;
        _ = draw.text_px(w, @divTrunc(draw.width - wpx, 2), y, draw.width, draw.px(.white), 2);
        y += lh;
    }
}

fn wall(app: *App) void {
    draw.clear(.white);
    header(app.game);
    draw.hline(0, 20, draw.width, .grey);
    draw.text_center("Release the HypnoDrones:", 34, .black);
    draw.text_center("stage 1 complete.", 44, .black);
    draw.text_center("Stage 2 arrives in M2.", 62, .black);
    draw.text_center("Start: message log", 90, .grey);
    ticker(app);
}
