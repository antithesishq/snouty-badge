//! Who plays which Genesis pad (docs/MULTIPLAYER.md): the input-source
//! seam between the badge's controls and `Md.step_frame_pads`.
//!
//! Today there is one source, `local`: the badge's pad (input.zig's mapped
//! word) is player `local_player` (player 1), every other pad is
//! released. A network source (lib/lockstep_n.zig's `LockstepN` over the
//! cart serial port, once the party firmware ships) plugs in here: its
//! `G.simulate(w, in, present)` hands `pads_from_slots` the 16 slot bytes
//! and the presence mask, one tick per Genesis frame, and its `G.hand_over`
//! needs nothing from the console (a slot that is not present reads as a
//! released pad).
//!
//! The wire byte is the Genesis 3-button pad as the sender mapped it
//! (`wire_byte`: bits U D L R A B C Start = `core.Pad` bits 0-7), so a
//! receiver needs nobody's button layout.
const core = @import("core");

/// Player slots a session may have (`LockstepN`'s 16); the console reads
/// the first `core.max_pads` of them.
pub const max_slots = 16;

pub const Source = enum { local };

/// Where the pads come from.
pub var source: Source = .local;

/// The pad the badge drives with the `local` source (0 = player 1).
pub var local_player: u3 = 0;

/// True while a network session drives the console. Fast forward, the
/// scrubber, the chorded rewind and the menu's Reset / Pick ROM must then
/// stay off (docs/MULTIPLAYER.md "Transport requirements"); comptime false
/// until a network source exists, so nothing here costs code yet.
pub const networked = false;

/// The byte a badge sends for its pad: the mapped 3-button pad.
pub inline fn wire_byte(pad: u16) u8 {
    return @truncate(pad);
}

/// The console's pads from a tick's slot bytes: slot s is pad s; a slot not
/// in `present` (never joined, or left mid-game) is a released pad, not an
/// unplugged one, so a game sees its player stand still rather than vanish.
pub fn pads_from_slots(in: *const [max_slots]u8, present: u16, out: *core.Pads) void {
    for (out, 0..) |*p, s| p.* = if (present >> @intCast(s) & 1 != 0) in[s] else 0;
}

/// The pads for the next Genesis frame, given the badge's own mapped pad.
/// False: not ready (a network source still waits for a peer's byte); the
/// caller then steps nothing this update. `local` is always ready.
pub fn next_frame(local_pad: u16, out: *core.Pads) bool {
    switch (source) {
        .local => {
            var in: [max_slots]u8 = @splat(0);
            in[local_player] = wire_byte(local_pad);
            pads_from_slots(&in, @as(u16, 1) << local_player, out);
            return true;
        },
    }
}

/// The transport's receive-ring drain, called at the top of every update
/// and through `Md.setup.poll_hook` inside every frame (a long frame must
/// not let the relay's queue for this badge overflow). Nothing to drain
/// without a network source; the hook is not installed then.
pub fn poll() void {}
