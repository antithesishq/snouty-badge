//! Placeholder Snouty (SPEC.md 4, 12): 24x16, three banking frames, drawn at
//! bottom-centre after the terrain. Two one-bit layers per frame (body and
//! outline), bit 23 = leftmost pixel, zero bits transparent. Seen from
//! behind and a little above: two ears, the snout poking up over the head
//! (it points forward, along the flight), trotters out to the sides. The
//! bank frames are the level frame sheared by 0.17 rows per column; the
//! literals were drawn in ASCII and packed by a throwaway script.
const cart = @import("cart-api");

// --- Knobs ------------------------------------------------------------------

/// The one constant that removes the avatar (draw compiles to nothing).
pub const show_avatar = true;
/// Sprite box: x 68..91, rows 100..115.
pub const x0 = 68;
pub const y0 = 100;
/// |roll| above this many rows (Q16) picks a bank frame.
const bank_rows: i32 = 6;
/// Body and outline colours, 0xRRGGBB.
const body_rgb: u32 = 0xE8D8C0;
const line_rgb: u32 = 0x402830;

const w = 24;
const h = 16;

const Frame = struct { body: [h]u24, line: [h]u24 };

/// level, bank left (positive roll: left side down), bank right.
const frames = [3]Frame{
    // level
    .{
        .body = .{ 0x000000, 0x000000, 0x307E0C, 0x38BD1C, 0x3CFF3C, 0x1E0078, 0x0FFFF0, 0x1FFFF8, 0x3FFFFC, 0x3FFFFC, 0x37FFEC, 0x13FFC8, 0x01FF80, 0x01C380, 0x000000, 0x000000 },
        .line = .{ 0x000000, 0x307E0C, 0x488112, 0x4542A2, 0x4300C2, 0x21FF84, 0x100008, 0x200004, 0x400002, 0x400002, 0x480012, 0x2C0034, 0x120048, 0x023C40, 0x01C380, 0x000000 },
    },
    // bank left: left side low
    .{
        .body = .{ 0x000004, 0x00000C, 0x007F1C, 0x103D38, 0x38FE78, 0x3C81F0, 0x3E7FFC, 0x0FFFFC, 0x1FFFFC, 0x1FFFE8, 0x3FFFC8, 0x37FF80, 0x33FF80, 0x01C200, 0x018000, 0x000000 },
        .line = .{ 0x00000A, 0x007F12, 0x1080A2, 0x28C2C4, 0x450184, 0x437E0C, 0x418002, 0x300002, 0x200002, 0x200014, 0x400034, 0x480048, 0x4C0040, 0x323D80, 0x024200, 0x018000 },
    },
    // bank right: right side low
    .{
        .body = .{ 0x200000, 0x300000, 0x38FE00, 0x1CBC08, 0x1E7F1C, 0x0F813C, 0x3FFE7C, 0x3FFFF0, 0x3FFFF8, 0x17FFF8, 0x13FFFC, 0x01FFEC, 0x01FFCC, 0x004380, 0x000180, 0x000000 },
        .line = .{ 0x500000, 0x48FE00, 0x450108, 0x234314, 0x2180A2, 0x307EC2, 0x400182, 0x40000C, 0x400004, 0x280004, 0x2C0002, 0x120012, 0x020032, 0x01BC4C, 0x004240, 0x000180 },
    },
};

/// Draw the frame for the camera roll (Q16 rows of shear; banking right is
/// negative roll).
pub fn draw(roll: i32) void {
    if (!show_avatar) return;
    const f: usize = if (roll > bank_rows << 16) 1 else if (roll < -(bank_rows << 16)) 2 else 0;
    const body_px: cart.Pixel = .from_color(.rgb(body_rgb));
    const line_px: cart.Pixel = .from_color(.rgb(line_rgb));
    const fr = &frames[f];
    for (0..w) |sx| {
        const col = &cart.framebuffer[x0 + sx];
        const bit: u24 = @as(u24, 1) << @intCast(w - 1 - sx);
        for (0..h) |sy| {
            if (fr.body[sy] & bit != 0) {
                col[y0 + sy] = body_px;
            } else if (fr.line[sy] & bit != 0) {
                col[y0 + sy] = line_px;
            }
        }
    }
}
