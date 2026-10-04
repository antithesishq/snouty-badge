//! The rewind's visuals (SPEC.md 5.1, 5.2, 5.3, 10): the frozen bug
//! report, the reverse playback overlay, the hold-B (manual) rewind
//! overlay, the dying bar (with hardcore's `UNRECOVERABLE`), the `GO!`
//! pop and the retry shield's `FLAKY, RETRYING` (M6). Draw only: main.zig
//! runs the state machine and history.zig
//! restores the world; this module only reads `world.w`.
const cart = @import("cart-api");
const draw = @import("draw.zig");
const world = @import("world.zig");
const bullets = @import("bullets.zig");
const enemies = @import("enemies.zig");
const collide = @import("collide.zig");
const player = @import("player.zig");
const hud = @import("hud.zig");
const boss_hp = @import("boss_hp.zig");

/// Hit-stop with the bug report.
pub const report_ticks: u32 = 20;
/// The MAXIMUM frames of an auto rewind's reverse playback (120 ticks);
/// main.zig passes the actual count, `(depth + 1) / 2`.
pub const playback_frames: u32 = 60;
/// Game ticks stepped back per frame, by the auto playback and by the
/// hold-B rewind alike.
pub const ticks_per_frame: u32 = 2;
pub const resume_invuln: u32 = 60;
pub const go_ticks: u32 = 30;

/// The bug message bar: Anti-Black, full width, 16 rows, the text 4 rows
/// down. Normally y 52..67 (text at 56, the stage text line, SPEC.md 10);
/// when the ship sprite overlaps that band (it spawns at y 52), the bar
/// moves below the ship (y 88..103) or, for a ship low in the band, above
/// it (y 20..35), so the ship and its red hitbox stay visible.
const bar_h: u32 = 16;
const text_dy: i32 = 4;
const bar_mid: i32 = 52;
const bar_low: i32 = 88;
const bar_high: i32 = 20;
/// `<<` is on 8 of every 16 rewind frames, in the HUD status slot.
const blink_frames: u32 = 8;
/// Hardcore's dying bar names the bug for this many ticks, then reads
/// `UNRECOVERABLE`.
const fatal_message_ticks: u32 = 30;
/// The offender blinks 2 ticks on, 2 off during the report.
const offender_blink: u32 = 2;
/// `GO!` gets its Coral shadow for its first ticks.
const go_pop_ticks: u32 = 6;

// Draw-only state (not in the World, never rewound): the bar row chosen
// by the report is kept through the playback, and `GO!` keeps the row
// chosen on its first frame, so neither jumps as the ship moves.
var report_bar_y: i32 = bar_mid;
var go_y: i32 = bar_mid + text_dy;
var go_last: u32 = 0;
var retry_y: i32 = bar_mid + text_dy;
var retry_last: u32 = 0;

/// Top row of the bar for the ship's current position.
fn bar_top() i32 {
    const py: i32 = @intFromFloat(@floor(world.w.player.y));
    const ph: i32 = player.cell_h;
    if (py >= bar_mid + @as(i32, bar_h) or py + ph <= bar_mid) return bar_mid;
    return if (py + ph <= bar_low) bar_low else bar_high;
}

fn draw_bar_at(y: i32, kind: enemies.Kind) void {
    draw_bar_text_at(y, message(kind));
}

fn draw_bar_text_at(y: i32, str: []const u8) void {
    cart.rect(.{ .x = 0, .y = y, .width = cart.screen_width, .height = bar_h, .fill_color = draw.anti_black });
    draw.centered_text(str, y + text_dy, draw.coral);
}

/// `<<` in the HUD status slot (x 48..63), blinking on 8 of every 16
/// frames. The slot is patched Anti-Black first so the scanline dim does
/// not stripe it; the fuel bar next to it is left alone.
fn draw_rewind_mark(frame: u32) void {
    cart.rect(.{ .x = hud.status_x, .y = 0, .width = hud.status_w, .height = @intCast(draw.hud_height), .fill_color = draw.anti_black });
    if ((frame / blink_frames) % 2 == 0) draw.text("<<", hud.status_x, 0, draw.coral);
}

/// The bug message (SPEC.md 5.1, PLAN.md M7 "Kinds, bosses, messages");
/// `.boss` names the current stage's boss.
pub fn message(kind: enemies.Kind) []const u8 {
    return switch (kind) {
        .gnat => "OFF BY ONE",
        .wasp => "RACE CONDITION",
        .beetle => "OUT OF MEMORY",
        .spider => "DEADLOCK",
        .moth => "ACCESS VIOLATION",
        .centipede => "STACK OVERFLOW",
        .flea => "NULL POINTER DEREF",
        .ladybug => "INFINITE LOOP",
        .mite => "BUFFER OVERFLOW",
        .zombie => "USE AFTER FREE",
        .herd => "THUNDERING HERD",
        .boss => boss_message(boss_hp.for_stage(world.w.waves.stage)),
    };
}

pub fn boss_message(id: enemies.BossId) []const u8 {
    return switch (id) {
        .heisenbug => "UNDEFINED BEHAVIOR",
        .mandelbug => "EMERGENT BEHAVIOR",
        .schrodinbug => "IT NEVER WORKED",
        .bohrbug => "REPRODUCIBLE CRASH",
    };
}

/// The bar and message only (DYING in normal mode, later GAME OVER).
/// Placed clear of the ship (see `bar_mid`).
pub fn draw_bar(kind: enemies.Kind) void {
    draw_bar_at(bar_top(), kind);
}

/// Hardcore's DYING bar, `age` 0..59 since the fatal hit: the bug message
/// while age < 30, then `UNRECOVERABLE`, same placement and colour.
pub fn draw_fatal_bar(kind: enemies.Kind, age: u32) void {
    if (age < fatal_message_ticks) {
        draw_bar_at(bar_top(), kind);
    } else {
        draw_bar_text_at(bar_top(), "UNRECOVERABLE");
    }
}

/// Over the frozen, fully drawn scene + HUD: the bar, then over it the
/// offender blinking in flash-white and a red outline and center dot on
/// the ship hitbox. `age` is 0..report_ticks-1.
pub fn draw_report(hit: collide.Hit, age: u32) void {
    report_bar_y = bar_top();
    draw_bar_at(report_bar_y, hit.kind);
    if ((age / offender_blink) % 2 == 0) {
        const flash: draw.SpriteOpts = .{ .flash_white = true };
        switch (hit.by) {
            .bullet => bullets.draw_enemy_bullet(world.w.enemy_bullets[hit.index], flash),
            .enemy => enemies.draw_enemy(world.w.enemies[hit.index], flash),
            .none => {},
        }
    }
    const hb = player.hitbox();
    const x: i32 = @intFromFloat(@floor(hb[0]));
    const y: i32 = @intFromFloat(@floor(hb[1]));
    const s: u32 = @intFromFloat(hb[2]);
    cart.rect(.{ .x = x - 1, .y = y - 1, .width = s + 2, .height = s + 2, .stroke_color = draw.red });
    const c = player.hitbox_center();
    cart.hline(.{ .x = c[0], .y = c[1], .len = 1, .color = draw.red });
}

/// Over the restored, fully drawn scene + HUD, `frame` 1..the playback
/// length (at most playback_frames): scanlines, the bar (where the report
/// put it), and `<<` blinking in the HUD status slot. The fuel bar stays
/// visible.
pub fn draw_playback(hit: collide.Hit, frame: u32) void {
    draw.darken_scanlines();
    draw_bar_at(report_bar_y, hit.kind);
    draw_rewind_mark(frame);
}

/// Over the restored, fully drawn scene + HUD during a hold-B rewind,
/// `frame` 1.. since the hold began: scanlines and the same `<<` blink.
/// No message bar; the fuel bar stays visible as it drains.
pub fn draw_manual(frame: u32) void {
    draw.darken_scanlines();
    draw_rewind_mark(frame);
}

/// `GO!` centered on the bar's text line (y 56 unless the ship is there)
/// in Anti-White, with a Coral shadow offset by 1 px for the first ticks;
/// `ticks_left` counts go_ticks down to 0.
pub fn draw_go(ticks_left: u32) void {
    if (ticks_left == 0) return;
    // A new pop (the countdown went up): pick its row once.
    if (ticks_left >= go_last) go_y = bar_top() + text_dy;
    go_last = ticks_left;
    const str = "GO!";
    if (ticks_left + go_pop_ticks > go_ticks) {
        const w: i32 = @intCast(str.len * cart.font_width);
        const x = @divTrunc(@as(i32, cart.screen_width) - w, 2);
        draw.text(str, x - 1, go_y - 1, draw.coral);
        draw.text(str, x + 1, go_y + 1, draw.coral);
    }
    draw.centered_text(str, go_y, draw.anti_white);
}

/// `FLAKY, RETRYING` in Coral on the bar's text line, the row picked once
/// per pop as `draw_go` does; `ticks_left` counts player.retry_ticks down.
pub fn draw_retry(ticks_left: u32) void {
    if (ticks_left == 0) return;
    if (ticks_left >= retry_last) retry_y = bar_top() + text_dy;
    retry_last = ticks_left;
    draw.centered_text("FLAKY, RETRYING", retry_y, draw.coral);
}
