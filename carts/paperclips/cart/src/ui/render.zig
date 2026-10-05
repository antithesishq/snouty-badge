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
        // The overlay blinks: every other 32 ms the page shows through.
        .game => if (app.hypno_on and app.game.panels.hypno_drone_event_div) hypno(app) else game_screen(app),
        .log => log_screen(app),
        .wall => wall(app),
    }
}

/// Pixels the tab bar and rows move down when the clip count needs four
/// lines (the ending's 74-character count).
var shift: i32 = 0;

fn game_screen(app: *App) void {
    draw.clear(.white);
    const lines = header(app.game);
    if (lines < 3) status_line(app);
    shift = if (lines > 3) 8 else 0;
    tab_bar(app);
    rows(app);
    ticker(app);
}

// -- header: "Paperclips: n", big while it fits --------------------------

fn header(g: *const G.Game) usize {
    var buf: [96]u8 = undefined;
    const n = G.clips_text(g, &buf);
    const label = "Paperclips:";
    const label_w = font.width(label.len);
    const big_w = @as(i32, @intCast(n.len)) * 12 - 2;
    if (label_w + 6 + big_w <= draw.width - 2) {
        _ = draw.text(label, 2, 5, .black);
        _ = draw.text_px(n, draw.width - 1 - big_w, 0, draw.width, draw.px(.black), 2);
        return 2;
    }
    if (big_w <= draw.width - 2) {
        _ = draw.text_px(n, @divTrunc(draw.width - big_w, 2), 0, draw.width, draw.px(.black), 2);
        return 2;
    }
    // Three lines of digits would push out the status line: the
    // original's crunched form instead ("75.8 duodecillion", its tooltip),
    // except in the ending, where the long count is the point.
    if (n.len > L.cols + (L.cols - 12) and g.milestone_flag < 15) {
        _ = draw.text(label, 2, 0, .black);
        var cb: [64]u8 = undefined;
        const c = std.mem.trimEnd(u8, G.fmt.number_cruncher(&cb, g.clips, 1), " ");
        _ = draw.text_right(c, L.right_x, 8, .black);
        return 2;
    }
    // Small type: the label, then the digits right-aligned, broken after
    // commas into lines of at most 26 characters (the first beside the
    // label), up to three lines.
    // Past 66 characters the label gives way; the ending's 74-character
    // count takes four lines (the rows move down, see `shift`).
    const labelled = n.len <= 2 * L.cols + (L.cols - 12);
    if (labelled) _ = draw.text(label, 2, 0, .black);
    if (!labelled) {
        // The ending: the count as a paragraph, lines broken after commas.
        var start: usize = 0;
        var k: i32 = 0;
        while (start < n.len and k < 4) : (k += 1) {
            var end = @min(n.len, start + L.cols);
            if (end < n.len) {
                while (end > start + 1 and n[end - 1] != ',') end -= 1;
            }
            _ = draw.text(n[start..end], L.text_x, k * 8, .black);
            start = end;
        }
        return @intCast(@max(2, k));
    }
    const first_room: usize = L.cols - 12;
    var lines: [4][]const u8 = undefined;
    var count: usize = 0;
    var end = n.len;
    // Fill lines from the end so the last lines are full, each starting
    // just after a comma.
    while (end > 0 and count < 4) {
        const room: usize = if (end <= first_room) first_room else L.cols;
        var start = end - @min(end, room);
        if (start > 0) {
            while (start < end and n[start - 1] != ',') start += 1;
        }
        if (start == end) start = end - @min(end, room);
        lines[count] = n[start..end];
        count += 1;
        end = start;
    }
    if (count < 2) {
        _ = draw.text_right(lines[0], L.right_x, 0, .black);
        return 2;
    }
    // lines[] is last-first: the first drawn line shares the label's row.
    var k: usize = 0;
    while (k < count) : (k += 1) {
        const line = lines[count - 1 - k];
        _ = draw.text_right(line, L.right_x, @as(i32, @intCast(k)) * 8, .black);
    }
    return @max(2, count);
}

fn status_line(app: *App) void {
    const s = pages.status(app.game, app.arena, L.cols);
    _ = draw.text(s, 2, L.status_y, .black);
}

// -- page tab: "< BUSINESS >   2/6 !" ------------------------------------

fn tab_bar(app: *App) void {
    draw.fill_rect(0, L.tab_y + shift, draw.width, L.tab_h, .black);
    const y = L.tab_y + 1 + shift;
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
        draw.fill_rect(L.right_x - 7, L.tab_y + 1 + shift, 8, L.tab_h - 2, .white);
        _ = draw.text("!", L.right_x - 5, y, .black);
    }
}

// -- rows ----------------------------------------------------------------

fn rows(app: *App) void {
    const list = app.rows.slice();
    const pi = @intFromEnum(app.page);
    const cursor = app.cursor_ix[pi];
    const area = app.list_lines() - @as(usize, if (shift > 0) 1 else 0);
    const scroll = app.scroll[pi];

    var line: usize = 0;
    for (list, 0..) |*r, i| {
        defer line += r.lines;
        if (line + r.lines <= scroll) continue;
        if (line >= scroll + area) break;
        // A tall row that does not fit waits for the scroll (unless it is
        // the first one shown).
        if (line + r.lines > scroll + area and line > scroll) break;
        const y = L.rows_y + shift + @as(i32, @intCast(line - scroll)) * L.row_h;
        row(app, r, y, i == cursor and list.len > 0);
    }

    // Scroll marks: a small triangle on the right when rows are hidden.
    var total: usize = 0;
    for (list) |*r| total += r.lines;
    if (scroll > 0) mark_up(L.rows_y);
    if (scroll + area < total) mark_down(L.rows_y + @as(i32, @intCast(area)) * L.row_h - 3);

    if (area < L.rows_visible and list.len > 0) footer(app, &list[cursor]);
}

fn mark_up(y: i32) void {
    draw.hline(155, y, 1, .grey);
    draw.hline(154, y + 1, 3, .grey);
}

fn mark_down(y: i32) void {
    draw.hline(154, y + 1, 3, .grey);
    draw.hline(155, y + 2, 1, .grey);
}

fn row(app: *App, r: *const pages.Row, y: i32, selected: bool) void {
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
        .text => if (r.lines == 2) {
            // Label and value do not fit side by side: the value goes on
            // a second line, right-aligned.
            _ = draw.text_clip(r.left, L.text_x, y, L.right_x, fg);
            _ = draw.text_right(r.right, L.right_x, y + L.row_h, fg);
        } else {
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
        .button, .project => if (!r.blank) {
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
fn slider(r: *const pages.Row, y: i32, selected: bool) void {
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

fn footer(app: *App, r: *const pages.Row) void {
    const top = L.rows_y + @as(i32, @intCast(app.list_lines())) * L.row_h;
    draw.hline(0, top + 1, draw.width, .grey);
    if (r.detail.len == 0) return;
    const lines = app.footer_text_lines();
    var spans: [12]text.Span = undefined;
    const n = text.wrap(r.detail, L.cols, &spans);
    const shown = @min(n, spans.len);
    var first: usize = 0;
    if (shown > lines) {
        // Step down a line at a time, pause at the end, start over.
        const steps = shown - lines + 2;
        const st = (app.footer_frames / app_mod.knobs.footer_step_frames) % steps;
        first = @min(st, shown - lines);
    }
    for (0..lines) |k| {
        const li = first + k;
        if (li >= shown) break;
        const sp = spans[li];
        _ = draw.text(r.detail[sp.start..sp.end], L.text_x, top + 4 + @as(i32, @intCast(k)) * L.row_h, .black);
    }
}

// -- ticker: the newest message, two lines -------------------------------

/// The one HTML entity the original's messages use (the closing credit's
/// "&#169;") as the font's copyright glyph.
fn plain(msg: []const u8, buf: []u8) []const u8 {
    const ent = "&#169;";
    const i = std.mem.indexOf(u8, msg, ent) orelse return msg;
    if (msg.len > buf.len) return msg;
    @memcpy(buf[0..i], msg[0..i]);
    buf[i] = font.copyright;
    const rest = msg[i + ent.len ..];
    @memcpy(buf[i + 1 .. i + 1 + rest.len], rest);
    return buf[0 .. i + 1 + rest.len];
}

fn ticker(app: *App) void {
    draw.hline(0, L.rule_y, draw.width, .grey);
    var pb: [160]u8 = undefined;
    const msg = plain(app_mod.message(app.game, 0) orelse return, &pb);
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
    var pb: [160]u8 = undefined;
    outer: while (app_mod.message(app.game, k)) |raw| : (k += 1) {
        const msg = plain(raw, &pb);
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
        line_y -= 2; // a little air between messages
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
    const step = app.game.long_blink_counter;
    draw.clear(.black);
    const words: []const []const u8 = if (step > 55)
        &.{ "Release", "the", "Hypno", "Drones" }
    else
        &.{"Release"};
    // The original's <br /> line breaks in front of "Release", its huge
    // white type at the top of a black band.
    const offset: i32 = if (step > 30 and step < 46) 3 else if (step > 45 and step <= 55) 1 else 0;
    const lh: i32 = 26;
    var y: i32 = 4 + offset * lh;
    for (words) |w| {
        _ = draw.text_px(w, 4, y, draw.width, draw.px(.white), 3);
        y += lh;
    }
}

fn wall(app: *App) void {
    draw.clear(.white);
    _ = header(app.game);
    draw.hline(0, 20, draw.width, .grey);
    draw.text_center("Release the HypnoDrones:", 34, .black);
    draw.text_center("stage 1 complete.", 44, .black);
    draw.text_center("Stage 2 arrives in M2.", 62, .black);
    draw.text_center("Start: message log", 90, .grey);
    ticker(app);
}
