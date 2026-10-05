//! The main menu's hint lines (menu.zig draws them under the rows): what
//! the row under the cursor does, and a second line in dim for some. Kept
//! apart from menu.zig (which needs the cart API) so the host tests can
//! hold every line to the menu panel's 152 px, 18 characters of the 8x8
//! font (content_test.zig, "panel text fits").
pub const quick = "3 LAPS, SIX RACERS";
pub const gc = "LAST CAR LEFT WINS";
pub const gc_2 = "MARK AND SWEEP";
pub const pickups = "WHAT CRATES GIVE";
pub const pickups_2 = "AND WHO GETS THEM";
pub const link = "2 BADGES, 1 CABLE";
pub const link_2 = "LINK RACE, LINK GC";
pub const no_link = "NO LINK IN";
pub const no_link_2 = "SIMULATOR";
pub const sound = "A TOGGLES SOUND";
pub const footer = "A SELECT  B BACK";

/// Every line above (the host test walks it).
pub const all = [_][]const u8{ quick, gc, gc_2, pickups, pickups_2, link, link_2, no_link, no_link_2, sound, footer };
