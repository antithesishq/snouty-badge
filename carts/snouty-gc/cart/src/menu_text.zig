//! The main menu's hint lines and geometry (menu.zig draws them): the line
//! about the row under the cursor, the footer, the title screen's hint.
//! Kept apart from menu.zig (which needs the cart API) so the host tests
//! (panel_text_test.zig) can hold every line to the menu panel's 152 px,
//! 18 characters of the 8x8 font, and the layout to the 160x128 screen
//! for up to `layout.max_rows` rows.
pub const quick = "3 LAPS, SIX RACERS";
pub const gc = "LAST CAR LEFT WINS";
/// M6, BATTLE (`KILL -9`, SPEC 8.3).
pub const battle = "ARENA, MOST KILLS";
pub const circuit = "2 PRIX, A GARAGE";
pub const pickups = "WHAT CRATES GIVE";
pub const link = "2 BADGES, 1 CABLE";
pub const no_link = "SIMULATOR: NO LINK";
pub const sound = "A TOGGLES SOUND";
pub const footer = "A SELECT  B BACK";
/// The title screen: alternates with PRESS START (A opens the Quick Race
/// select, L40).
pub const title_a = "A  QUICK RACE";

/// Every line above (the host test walks it).
pub const all = [_][]const u8{ quick, gc, battle, circuit, pickups, link, no_link, sound, footer, title_a };

/// The main menu's geometry, top to bottom (y in px):
/// - the title lockup (SNOUTY 1x, GCP 2x) from `title_y`; its ink and drop
///   end above `title_end`;
/// - the rows' panel, `panel_h(n)` tall, centred in `title_end + 2 ..
///   bar_y - 2`: rows `pitch` apart, each with an 11 px highlight bar;
/// - the hint bar from `bar_y` to the bottom edge: the line about the row
///   (`hint_y`) and the footer (`footer_y`).
/// Built for `max_rows` = 7: M6 added BATTLE after GARBAGE COLLECTION
/// (SPEC 8.3), so the cart ships 7. The host test checks nothing overlaps.
pub const layout = struct {
    pub const max_rows = 7;
    pub const title_y: i32 = 3;
    /// GCP at 2x is 16 rows, its coral drop 2 below: the last ink row is
    /// title_y + 17.
    pub const title_end: i32 = title_y + 18;
    pub const pitch: i32 = 11;
    /// A row's highlight bar: from 2 above the text, 11 tall.
    pub const bar_above: i32 = 2;
    pub const highlight_h: i32 = 11;
    pub const bar_y: i32 = 107;
    pub const hint_y: i32 = 109;
    pub const footer_y: i32 = 119;

    /// The panel's height for `n` rows: 3 px above the first row's text,
    /// 2 below the last row's highlight.
    pub fn panel_h(n: i32) i32 {
        return n * pitch + 5;
    }
    /// The panel's top for `n` rows: centred between the title and the bar.
    pub fn panel_y(n: i32) i32 {
        const lo = title_end + 2;
        const hi = bar_y - 2;
        return lo + @divTrunc(hi - lo - panel_h(n), 2);
    }
    /// Row `i`'s text top for `n` rows.
    pub fn row_y(n: i32, i: i32) i32 {
        return panel_y(n) + 3 + i * pitch;
    }
};
