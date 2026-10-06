//! Select's two meanings (SPEC.md section 3, docs/TOF.md M5): a press
//! toggles the sound at once, as it always has; holding it for
//! `hold_ticks` (1 s) undoes that toggle and flips ZONES (GRID / STRIPES)
//! instead. Every other button is bound, and Select acted on its press
//! with nothing for a long hold, so the hold displaces nothing. While
//! Start and Select are both held (the OS's chord) nothing reacts, and a
//! hold the chord touched never turns into ZONES. Pure: main.zig hands it
//! the buttons each tick, the host tests drive it directly.

/// Ticks (60 Hz) Select must stay down for ZONES.
pub const hold_ticks: u32 = 60;

pub const Event = struct {
    /// Toggle the sound (the press; again at the hold, which undoes it).
    sound: bool = false,
    /// Flip ZONES.
    zones: bool = false,
};

pub const SelectHold = struct {
    ticks: u32 = 0,
    /// A press outside the chord started this hold.
    armed: bool = false,
    prev_select: bool = false,

    /// One tick with Select and Start as held now.
    pub fn step(s: *SelectHold, select: bool, start: bool) Event {
        var ev: Event = .{};
        const pressed = select and !s.prev_select;
        s.prev_select = select;
        if (select and start) {
            // The OS's chord: react to neither button.
            s.armed = false;
            return ev;
        }
        if (!select) {
            s.armed = false;
            return ev;
        }
        if (pressed) {
            ev.sound = true;
            s.armed = true;
            s.ticks = 0;
            return ev;
        }
        if (s.armed) {
            s.ticks += 1;
            if (s.ticks >= hold_ticks) {
                s.armed = false;
                ev.sound = true;
                ev.zones = true;
            }
        }
        return ev;
    }
};

// ---- Host tests ----

const std = @import("std");
const testing = std.testing;

/// Runs `ticks` ticks of the given buttons; counts the sound toggles and ZONES flips.
fn hold(s: *SelectHold, ticks: u32, select: bool, start: bool, sound: *u32, zones: *u32) void {
    for (0..ticks) |_| {
        const e = s.step(select, start);
        sound.* += @intFromBool(e.sound);
        zones.* += @intFromBool(e.zones);
    }
}

test "select hold: a tap toggles the sound only, on the press" {
    var s: SelectHold = .{};
    try testing.expect(s.step(true, false).sound);
    var sound: u32 = 0;
    var zones: u32 = 0;
    hold(&s, 20, true, false, &sound, &zones);
    hold(&s, 5, false, false, &sound, &zones);
    try testing.expectEqual(@as(u32, 0), sound);
    try testing.expectEqual(@as(u32, 0), zones);
}

test "select hold: one second flips ZONES and undoes the sound toggle, once" {
    var s: SelectHold = .{};
    var sound: u32 = 0;
    var zones: u32 = 0;
    hold(&s, hold_ticks, true, false, &sound, &zones);
    // The press toggled the sound; the hold is not there yet.
    try testing.expectEqual(@as(u32, 1), sound);
    try testing.expectEqual(@as(u32, 0), zones);
    hold(&s, 1, true, false, &sound, &zones);
    try testing.expectEqual(@as(u32, 2), sound); // back as it was
    try testing.expectEqual(@as(u32, 1), zones);
    // Holding on does nothing more; letting go neither.
    hold(&s, 300, true, false, &sound, &zones);
    hold(&s, 3, false, false, &sound, &zones);
    try testing.expectEqual(@as(u32, 2), sound);
    try testing.expectEqual(@as(u32, 1), zones);
}

test "select hold: the Start+Select chord never toggles anything" {
    var s: SelectHold = .{};
    var sound: u32 = 0;
    var zones: u32 = 0;
    // Both pressed together and held.
    hold(&s, 200, true, true, &sound, &zones);
    try testing.expectEqual(@as(u32, 0), sound);
    try testing.expectEqual(@as(u32, 0), zones);
    // Start let go first, Select still held: no press, no hold.
    hold(&s, 200, true, false, &sound, &zones);
    try testing.expectEqual(@as(u32, 0), zones);
    try testing.expectEqual(@as(u32, 0), sound);
    // Select alone, then Start joins mid-hold: the press toggled (as
    // before M5), the hold is spoiled.
    hold(&s, 3, false, false, &sound, &zones);
    hold(&s, 10, true, false, &sound, &zones);
    hold(&s, 100, true, true, &sound, &zones);
    hold(&s, 100, true, false, &sound, &zones);
    try testing.expectEqual(@as(u32, 1), sound);
    try testing.expectEqual(@as(u32, 0), zones);
}
