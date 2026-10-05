//! ComLynx on the badge (docs/COMLYNX.md section 6), as Snouty Boy's
//! frontend/linkport.zig is its link cable. While `linked` the core has a
//! ComLynx port (`Lynx.attach_link`: the real UART instead of the stub)
//! and the scrubber, the chorded rewind and fast forward are off (a
//! rewound or sped-up console would leave the others behind): main.zig and
//! the menu read `linked`. The port lives in the scrubber's arena, lent
//! while linked (frontend/rewind.zig `lend`), so being able to link costs
//! the scrub history nothing; the history restarts when the link ends.
//!
//! There is no transport yet: the badge-to-badge path (the fork firmware's
//! cart serial ring and the lobby protocol's relay) plugs into the two
//! pump points below, `before_frame` (deliver what arrived: drain the
//! serial ring every frame, `Lynx.link_deliver` each frame) and
//! `after_frame` (`Lynx.link_sync`, then send what the UART sent this
//! frame as one message). Unlinked, both return at once.
const core = @import("core");
const rewind = @import("rewind.zig");

const Port = core.comlynx.Port;

/// The core has a ComLynx port.
pub var linked = false;
var port: ?*Port = null;

/// Frames the UART sent while linked (the transport would carry them).
pub var frames_out: u32 = 0;

/// Link the console: the port in the lent arena. False when the arena is
/// too small (then nothing changes).
pub fn link(l: *core.Lynx) bool {
    if (linked) return true;
    const mem = rewind.lend(@sizeOf(Port)) orelse return false;
    const p: *Port = @ptrCast(mem.ptr);
    p.* = .{};
    port = p;
    linked = true;
    l.attach_link(p);
    return true;
}

/// Unlink: the stub again, the scrubber back (empty).
pub fn unlink(l: *core.Lynx) void {
    if (!linked) return;
    l.attach_link(null);
    port = null;
    linked = false;
    rewind.take_back(l);
}

/// After a boot (`init_in_place` detaches the port): attach it again.
pub fn after_boot(l: *core.Lynx) void {
    if (port) |p| l.attach_link(p);
}

/// Before the frame's `step_frame`: the transport's receive point.
pub fn before_frame(l: *core.Lynx) void {
    if (!linked) return;
    _ = l;
}

/// After the frame's `step_frame`: the transport's send point.
pub fn after_frame(l: *core.Lynx) void {
    if (!linked) return;
    l.link_sync();
    const p = port.?;
    while (p.take()) |_| frames_out +%= 1;
}
