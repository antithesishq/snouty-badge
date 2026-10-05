//! The party libs as one module, for a cart's host tests that drive a
//! lobby client (lib/party.zig) through the relay model
//! (lib/party_virtual.zig): a file belongs to one module only, and
//! party_virtual.zig imports party.zig itself, so a test cannot have them
//! as two modules. Carts on the badge import lib/party.zig and
//! lib/cart_serial.zig directly. (Added for snouty-lynx's ComLynx tests,
//! carts/snouty-lynx/docs/COMLYNX.md section 10.)
pub const party = @import("party.zig");
pub const party_virtual = @import("party_virtual.zig");
pub const cart_serial = @import("cart_serial.zig");
