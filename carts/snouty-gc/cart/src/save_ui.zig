//! New for Snouty GCP (cart saves, branch `saves/gcp`): the cart side of
//! career_save.zig. The one `Saver` and `Chooser`, the SAVING mark, the
//! error line and the CIRCUIT chooser (CONTINUE CAREER / NEW CAREER and
//! its confirm), drawn in the main menu's style (menu_text.layout: the
//! lockup, a 2-row panel, the hint bar with the 18-character hint over
//! `A SELECT  B BACK`). Nothing here draws or runs unless
//! `saver.on` (the patched OS answered the probe).
const cart = @import("cart-api");
const hud = @import("hud.zig");
const menu = @import("menu.zig");
const menu_text = @import("menu_text.zig");
const career = @import("career.zig");
const csave = @import("career_save.zig");

pub var saver: csave.Saver = .{};
pub var chooser: csave.Chooser = .{};

const panel = cart.DisplayColor.rgb(0x2A1E34);
const panel_hi = cart.DisplayColor.rgb(0x4A2440);
const lay = menu_text.layout;

/// The end of update(): the SAVING mark when a write follows next update
/// (the screen holds this frame while the cart is parked), else an error
/// line while one is up. `menus`: not a race or its pause (an error line
/// never covers the race).
pub fn draw(menus: bool) void {
    if (!saver.on) return;
    if (saver.marking()) {
        hud.fill_rect(104, 0, 56, 12, hud.anti_black);
        hud.text("SAVING", 108, 2, hud.coral);
        return;
    }
    if (!menus) return;
    if (saver.error_text()) |t| {
        hud.fill_rect(0, 0, 160, 12, hud.anti_black);
        hud.centered(t, 2, hud.red);
    }
}

/// The chooser over the menu's live floor (the caller draws the floor):
/// the lockup, the rows in a panel, the row's hint and the footer.
/// `cont`: the career CONTINUE CAREER loads (the hint names its league
/// and race).
pub fn draw_chooser(can_continue: bool, cont: *const career.Career) void {
    menu.lockup(lay.title_y, 2, true);
    const labels = chooser.rows(can_continue);
    const rows: i32 = @intCast(labels.len);
    const py = lay.panel_y(rows);
    cart.rect(.{ .x = 4, .y = py, .width = 152, .height = @intCast(lay.panel_h(rows)), .fill_color = panel, .stroke_color = hud.dim });
    for (labels, 0..) |item, i| {
        const y = lay.row_y(rows, @intCast(i));
        const sel = i == chooser.cursor;
        if (sel) hud.fill_rect(6, y - lay.bar_above, 148, lay.highlight_h, panel_hi);
        hud.centered(item, y, if (sel) hud.coral else hud.white);
    }
    var buf: [18]u8 = undefined;
    const about = chooser.hint(can_continue, saver.found, cont, &buf);
    hud.fill_rect(4, lay.bar_y, 152, 128 - lay.bar_y, hud.anti_black);
    hud.centered(about, lay.hint_y, if (chooser.confirm) hud.coral else hud.grey);
    hud.centered(menu_text.footer, lay.footer_y, hud.dim);
}
