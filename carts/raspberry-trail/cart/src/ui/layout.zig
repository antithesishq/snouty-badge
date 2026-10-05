//! Screen layout in pixels (SPEC 4.1), shared by app.zig (paging needs the
//! prompt box's height) and render.zig. Top to bottom: the HUD (two text
//! rows), the trail strip (10 px), a rule, the log, and at the bottom the
//! prompt box or the "A: MORE" footer.
const G = @import("game");
const text = @import("text.zig");
const font = @import("font.zig");

pub const width: i32 = 160;
pub const height: i32 = 128;

pub const hud_row1_y: i32 = 1;
pub const hud_row2_y: i32 = 10;
/// The trail strip (M1: a plain track with markers; M2: the art).
pub const strip_y: i32 = 19;
pub const strip_h: i32 = 10;
pub const rule_y: i32 = strip_y + strip_h;
pub const log_top: i32 = rule_y + 3;
pub const text_x: i32 = 2;

/// The shooting scenes (160x80) sit at the bottom of the screen.
pub const scene_y: i32 = height - 80;
/// The tombstone and the arrival (160x96) fill the log area.
pub const end_y: i32 = height - 96;

/// The "A: MORE" bar while paging.
pub const footer_h: i32 = 11;

/// Prompt box: a 1 px raspberry rule, padding, the question (one or two
/// rows), the body, padding.
pub const box_pad_top: i32 = 3;
pub const box_pad_bottom: i32 = 2;
pub const question_h: i32 = 9;
pub const option_h: i32 = 10;
/// The number spinner: twice-size digits (16 px) and the caret bar...
pub const spinner_h: i32 = 20;
/// ...then the "LEFT $450" row.
pub const info_h: i32 = 9;
/// The shooting cue: the word, twice size, over the button boxes.
pub const shot_word_h: i32 = 18;
pub const shot_box: i32 = 18;
pub const shot_h: i32 = shot_word_h + 2 + shot_box;

pub fn question_rows(q: []const u8) usize {
    var spans: [2]text.Span = undefined;
    return @min(2, text.wrap(q, font.cols, &spans));
}

pub fn body_height(p: *const G.Prompt) i32 {
    return switch (p.kind) {
        .yes_no => 2 * option_h,
        .choice => @as(i32, p.n_options) * option_h,
        .number => spinner_h + info_h,
        .shoot => shot_h,
        // The outcome and "A: NEW GAME".
        .game_over => 2 * question_h,
    };
}

/// The prompt box's height for this prompt, rule included.
pub fn prompt_height(p: *const G.Prompt) i32 {
    // The end screen (the tombstone or the arrival) takes the whole log
    // area: every closing line is read on its own pages first.
    if (p.kind == .game_over) return height - log_top;
    // The shooting scene fills the bottom 80 px.
    if (p.kind == .shoot) return height - scene_y;
    const q: i32 = if (p.kind == .game_over) 0 else @intCast(question_rows(p.question));
    return 1 + box_pad_top + q * question_h + body_height(p) + box_pad_bottom;
}
