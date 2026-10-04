//! Screen layout, in pixels (SPEC section 3). Top to bottom: the header
//! (clip count), the status line, the page tab bar, the page rows, a rule,
//! the two-line message ticker.
pub const header_y: i32 = 0;
pub const header_h: i32 = 16;
pub const status_y: i32 = 16;
pub const tab_y: i32 = 24;
pub const tab_h: i32 = 9;
pub const rows_y: i32 = 34;
pub const row_h: i32 = 8;
pub const rows_visible: usize = 9;
pub const rows_bottom: i32 = rows_y + @as(i32, rows_visible) * row_h; // 106
pub const rule_y: i32 = 107;
pub const ticker_y: i32 = 110;
pub const ticker_line_h: i32 = 9;
pub const ticker_lines: usize = 2;

/// Text columns: 26 cells of 6 px (the 160th pixel column stays blank).
pub const cols: usize = 26;
/// Row text starts one cell in (the cursor bar runs the full width).
pub const text_x: i32 = 2;
pub const right_x: i32 = 158;

/// Footer panel (a selected row's detail, e.g. a project's description):
/// lines of text below the list, inside the rows area.
pub const footer_lines: usize = 4;
