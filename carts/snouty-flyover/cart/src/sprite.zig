//! Placeholder Snouty (SPEC.md 4, 12): 24x16, three banking frames, drawn at
//! bottom-centre after the terrain. Scaffold stub: nothing drawn yet.
const cart = @import("cart-api");

/// The one constant that removes the avatar.
pub const show_avatar = true;
/// Sprite box: x 68..91, rows 100..115.
pub const x0 = 68;
pub const y0 = 100;

/// Draw the frame for the camera roll (Q16 rows of shear; |roll| > 6 rows banks).
pub fn draw(roll: i32) void {
    if (!show_avatar) return;
    _ = roll;
}
