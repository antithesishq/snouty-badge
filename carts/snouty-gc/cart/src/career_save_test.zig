//! Host tests for the CIRCUIT's save (career_save.zig, branch `saves/gcp`)
//! against lib/save.zig's fake store: the format's round trip mid-career
//! (after booked races, a league closed, garage purchases and the AIs'
//! shopping), refusals (version, guard, length, sum, ranges), the probe on
//! stock firmware (no UI at all), the save points and the SAVING mark's
//! one-frame lead, the exit hook, never a write during a link session,
//! the rate limiter's retry and an error shown once, the end-of-circuit
//! delete, the chooser and its hints.
const std = @import("std");
const save = @import("save");
const career = @import("career.zig");
const csave = @import("career_save.zig");
const racers = @import("racers.zig");
const track = @import("track.zig");
const world = @import("world.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

/// A finished race: the player `place`, the others in racer order, with
/// `kills` and `chips` for the player (like main.zig's debug_prix_skip).
fn finished(c: *const career.Career, place: u8, kills: u8, chips: u8) world.World {
    var w: world.World = .{};
    var next: u8 = 1;
    for (&w.cars, 0..) |*car, i| {
        car.racer = @intCast(i);
        if (i == c.racer) {
            car.rank = place;
            car.kills = kills;
            car.chips = chips;
            continue;
        }
        if (next == place) next += 1;
        car.rank = next;
        next += 1;
        car.chips = @intCast(i);
    }
    return w;
}

/// A career well into the circuit: the Dumps raced and closed (cleared,
/// the Runoff open), purchases and the AIs' shopping, one Runoff race
/// booked.
fn mid_career() career.Career {
    var c = career.Career.init(racers.kiddie);
    c.cycles = 2500;
    _ = c.buy(.front, @backingInt(world.Front.phish)); // a swap
    _ = c.buy(.plating, 0);
    c.ai_shop();
    for ([_]u8{ 2, 1, 3 }) |p| {
        const w = finished(&c, p, 2, 7);
        _ = c.finish_race(&w);
        _ = c.buy(.clock, 0);
        c.ai_shop();
    }
    _ = c.close_league();
    const w = finished(&c, 4, 1, 3);
    _ = c.finish_race(&w);
    return c;
}

fn same(a: *const career.Career, b: *const career.Career) !void {
    var x: [csave.blob_len]u8 = undefined;
    var y: [csave.blob_len]u8 = undefined;
    csave.encode(a, &x);
    csave.encode(b, &y);
    try expectEqualSlices(u8, &x, &y);
    // And field by field where the bytes could hide a mix-up.
    try expectEqual(a.racer, b.racer);
    try expectEqual(a.league, b.league);
    try expectEqual(a.race, b.race);
    try expectEqual(a.cycles, b.cycles);
    try expectEqual(a.points, b.points);
    try expectEqual(a.earned, b.earned);
    try expectEqual(a.spent, b.spent);
    try expectEqual(a.plan, b.plan);
    for (a.loadouts, b.loadouts) |la, lb| try expect(std.meta.eql(la, lb));
    try expect(std.meta.eql(a.last, b.last));
    try expectEqual(a.outcome, b.outcome);
    try expectEqual(a.done, b.done);
    try expectEqual(a.unlocked, b.unlocked);
}

const no_link = false;

fn ctx(c: *const career.Career, on: bool, link: bool) csave.Ctx {
    return .{ .career = c, .on = on, .link = link };
}

/// One update's worth of the saver: the top of the update.
fn top(s: *csave.Saver, c: *const career.Career, on: bool, link: bool) void {
    s.frame_start(ctx(c, on, link));
}

test "the blob: 181 bytes, the fields of a career in a fixed order" {
    try expectEqual(@as(usize, 181), csave.blob_len);
    var c = mid_career();
    var b: [csave.blob_len]u8 = undefined;
    csave.encode(&c, &b);
    try expectEqualSlices(u8, "GCPC", b[0..4]);
    try expectEqual(csave.version, b[4]);
    try expectEqualSlices(u8, &csave.guard, b[5..10]);
    try expectEqual(@as(u8, csave.payload_len), b[10]);
    const back = try csave.decode(&b);
    try same(&c, &back);
    // A fresh career and a finished one survive too.
    var fresh = career.Career.init(racers.botnet);
    csave.encode(&fresh, &b);
    try same(&fresh, &(try csave.decode(&b)));
    c.done = true;
    c.unlocked = true;
    csave.encode(&c, &b);
    try same(&c, &(try csave.decode(&b)));
}

test "round trip through the store mid-career: booked races, a league closed, purchases" {
    save.fake.reset();
    var s = csave.Saver{};
    s.boot(0, true);
    try expect(!s.probed); // update 0: not yet
    s.boot(1, false);
    try expect(!s.probed); // not on the splash or title
    s.boot(1, true);
    try expect(s.on and s.found == .none);
    try expect(save.fake.exitWatched());
    try expect(!s.offers(false));

    // A session: a career booked race by race, each result a save point.
    var c = career.Career.init(racers.sysadmin);
    c.cycles = 1800;
    _ = c.buy(.traction, 0);
    var writes: u32 = 0;
    for (0..3) |k| {
        c.ai_shop();
        const w = finished(&c, @intCast(k + 1), @intCast(k), 5);
        _ = c.finish_race(&w);
        s.request(&c, .race);
        try expect(s.marking()); // the mark is in this frame...
        try expectEqual(writes, save.fake.commits());
        top(&s, &c, true, no_link); // ...the write at the next update's top
        writes += 1;
        try expectEqual(writes, save.fake.commits());
        try expect(!s.marking());
        save.fake.advanceMs(60_000);
    }
    try expect(c.league_over());
    // The league closes on the standings (no save point of its own), the
    // garage is left for the menu: that saves the closed league.
    try expectEqual(career.Outcome.cleared, c.close_league());
    try expect(c.unlocked and c.league == 1);
    _ = c.buy(.burst, 0);
    s.request(&c, .menu);
    top(&s, &c, true, no_link);
    try expectEqual(writes + 1, save.fake.commits());
    // B again with nothing bought: no mark, no write.
    s.request(&c, .menu);
    try expect(!s.marking());
    top(&s, &c, true, no_link);
    try expectEqual(writes + 1, save.fake.commits());
    // One Runoff race booked.
    c.ai_shop();
    const w = finished(&c, 5, 0, 2);
    _ = c.finish_race(&w);
    s.request(&c, .race);
    top(&s, &c, true, no_link);
    try expectEqual(writes + 2, save.fake.commits());
    try expectEqual(@as(u64, (writes + 2) * 2 * 55), save.fake.flashMs()); // one data block + the directory each

    // Power off, power on: the probe reads it back.
    save.fake.reboot();
    var t = csave.Saver{};
    t.boot(1, true);
    try expectEqual(csave.Found.career, t.found);
    try expect(t.offers(false) and t.can_continue(false));
    const back = t.take_staged();
    try same(&c, &back);
    try expectEqual(csave.Resume.garage, csave.resume_at(&back));
    // Nothing changed since: B out of the garage writes nothing.
    t.request(&back, .menu);
    try expect(!t.marking());
}

test "a career saved after its league's third race resumes on the standings, and closes the same" {
    save.fake.reset();
    var s = csave.Saver{};
    s.probe();
    var c = career.Career.init(racers.snouty);
    for ([_]u8{ 1, 1, 2 }) |p| {
        const w = finished(&c, p, 3, 4);
        _ = c.finish_race(&w);
    }
    s.request(&c, .race);
    top(&s, &c, true, no_link);
    save.fake.reboot();
    var t = csave.Saver{};
    t.probe();
    var back = t.take_staged();
    try expectEqual(csave.Resume.standings, csave.resume_at(&back));
    // The league closed after the reload is the league closed before it.
    var before = c;
    try expectEqual(before.close_league(), back.close_league());
    try same(&before, &back);
    back.done = true;
    try expectEqual(csave.Resume.end, csave.resume_at(&back));
}

test "an incompatible save is refused: another version, guard or length is old; a bad sum or range is damaged" {
    const c = mid_career();
    var good: [csave.blob_len]u8 = undefined;
    csave.encode(&c, &good);

    var b = good;
    b[4] +%= 1; // version
    try std.testing.expectError(error.Old, csave.decode(&b));
    b = good;
    b[5] +%= 1; // racers in the guard
    try std.testing.expectError(error.Old, csave.decode(&b));
    b = good;
    b[0] = 'X'; // magic
    try std.testing.expectError(error.Old, csave.decode(&b));
    try std.testing.expectError(error.Old, csave.decode(good[0 .. good.len - 1]));
    try std.testing.expectError(error.Old, csave.decode(good[0..4]));
    b = good;
    b[csave.header_len + 9] ^= 0x40; // a payload byte: the sum fails
    try std.testing.expectError(error.Damaged, csave.decode(&b));

    // A field out of range with a correct sum (a build that misread it).
    var bad = c;
    bad.racer = 9;
    csave.encode(&bad, &b);
    try std.testing.expectError(error.Damaged, csave.decode(&b));
    bad = c;
    bad.loadouts[2].clock = 4;
    csave.encode(&bad, &b);
    try std.testing.expectError(error.Damaged, csave.decode(&b));

    // Through the store: the probe says old, the chooser offers NEW CAREER
    // alone with the reason, and the first save replaces it.
    save.fake.reset();
    b = good;
    b[4] = csave.version + 1;
    try save.write(csave.key, &b);
    var s = csave.Saver{};
    s.probe();
    try expectEqual(csave.Found.old, s.found);
    try expect(s.offers(false) and !s.can_continue(false));
    var ch = csave.Chooser{};
    ch.enter();
    var buf: [18]u8 = undefined;
    try expectEqual(@as(usize, 1), ch.rows(false).len);
    try std.testing.expectEqualStrings("OLD SAVE: UNUSABLE", ch.hint(false, s.found, &s.staged, &buf));
    try expectEqual(csave.Pick.new_career, ch.update(false, .{ .a = true }));
    var fresh = career.Career.init(racers.rootkit);
    s.request(&fresh, .menu);
    top(&s, &fresh, true, no_link);
    var t = csave.Saver{};
    save.fake.reboot();
    t.probe();
    try expectEqual(csave.Found.career, t.found);
    try same(&fresh, &t.staged);

    // A blob the store's CRC rejects reads as damaged.
    save.fake.reset();
    try save.write(csave.key, &good);
    save.fake.failNext(error.IoError);
    var u = csave.Saver{};
    u.probe();
    try expectEqual(csave.Found.damaged, u.found);
    try std.testing.expectEqualStrings("SAVE IS DAMAGED", ch.hint(false, u.found, &u.staged, &buf));
}

test "stock firmware: no probe answer, no UI, no request, no exit hook" {
    save.fake.reset();
    save.fake.setSupported(false);
    var s = csave.Saver{};
    s.boot(1, true);
    try expect(s.probed and !s.on);
    try expect(!save.fake.exitWatched());
    var c = mid_career();
    try expect(!s.offers(true) and !s.offers(false));
    s.request(&c, .race);
    s.request(&c, .menu);
    s.request(&c, .finished);
    try expect(!s.marking());
    top(&s, &c, true, no_link);
    try expectEqual(@as(u32, 0), save.fake.commits());
    try expect(s.error_text() == null);
    // The probe ran once: later updates never probe again.
    s.boot(500, true);
    try expect(!s.on);
}

test "the exit hook: saves a changed career, then exitReady; nothing to save still answers" {
    save.fake.reset();
    var s = csave.Saver{};
    s.probe();
    var c = career.Career.init(racers.legacy);
    c.cycles = 900;
    _ = c.buy(.watchdog, 0); // bought, not yet saved
    save.fake.setExitRequested();
    top(&s, &c, true, no_link);
    try expectEqual(@as(u32, 2), save.fake.exitWord());
    try expectEqual(@as(u32, 1), save.fake.commits());
    // The OS stops the cart soon; until then nothing runs twice.
    top(&s, &c, true, no_link);
    try expectEqual(@as(u32, 1), save.fake.commits());
    save.fake.reboot();
    var t = csave.Saver{};
    t.probe();
    try same(&c, &t.staged);

    // Unchanged career: no write, still ready.
    save.fake.setExitRequested();
    top(&t, &t.staged, true, no_link);
    try expectEqual(@as(u32, 2), save.fake.exitWord());
    try expectEqual(@as(u32, 1), save.fake.commits());

    // No career in the session (menus, a quick race): ready, no write.
    save.fake.reboot();
    var u = csave.Saver{};
    u.probe();
    save.fake.setExitRequested();
    top(&u, &c, false, no_link);
    try expectEqual(@as(u32, 2), save.fake.exitWord());
    try expectEqual(@as(u32, 1), save.fake.commits());
}

test "never during a link session: a pending save waits, the exit hook only answers" {
    save.fake.reset();
    var s = csave.Saver{};
    s.probe();
    var c = career.Career.init(racers.snouty);
    const w = finished(&c, 1, 0, 0);
    _ = c.finish_race(&w);
    s.request(&c, .race);
    // The next update is a link session (cannot happen from the standings
    // in one frame, but the guard holds anyway): nothing is written.
    for (0..10) |_| top(&s, &c, true, true);
    try expectEqual(@as(u32, 0), save.fake.commits());
    try expectEqual(@as(u32, 1), s.link_held);
    // The exit hook in a link session: exitReady, no write.
    save.fake.setExitRequested();
    top(&s, &c, true, true);
    try expectEqual(@as(u32, 2), save.fake.exitWord());
    try expectEqual(@as(u32, 0), save.fake.commits());
    // Back in single player the next save point writes it.
    save.fake.reboot();
    var t = csave.Saver{};
    t.probe();
    t.request(&c, .menu);
    top(&t, &c, true, true); // still linked: held
    try expectEqual(@as(u32, 0), save.fake.commits());
    t.request(&c, .menu);
    top(&t, &c, true, false);
    try expectEqual(@as(u32, 1), save.fake.commits());
}

test "RateLimited retries at the next save point quietly; NoSpace shows once" {
    save.fake.reset();
    var s = csave.Saver{};
    s.probe();
    var c = career.Career.init(racers.botnet);
    var w = finished(&c, 2, 1, 1);
    _ = c.finish_race(&w);
    save.fake.failNext(error.RateLimited);
    s.request(&c, .race);
    top(&s, &c, true, no_link);
    try expectEqual(@as(u32, 0), save.fake.commits());
    try expectEqual(@as(u32, 1), s.rate_limited);
    try expect(s.error_text() == null);
    // The garage's B is the next save point: it writes.
    s.request(&c, .menu);
    try expect(s.marking());
    top(&s, &c, true, no_link);
    try expectEqual(@as(u32, 1), save.fake.commits());

    w = finished(&c, 3, 0, 0);
    _ = c.finish_race(&w);
    save.fake.failNext(error.NoSpace);
    s.request(&c, .race);
    top(&s, &c, true, no_link);
    try std.testing.expectEqualStrings("SAVE: NO SPACE", s.error_text().?);
    for (0..csave.knobs.error_frames) |_| top(&s, &c, true, no_link);
    try expect(s.error_text() == null);
    // A second failure is not shown again; a later point still writes.
    save.fake.failNext(error.IoError);
    s.request(&c, .menu);
    top(&s, &c, true, no_link);
    try expect(s.error_text() == null);
    s.request(&c, .menu);
    top(&s, &c, true, no_link);
    try expectEqual(@as(u32, 2), save.fake.commits());
    for ([_]save.Error{ error.NoSpace, error.IoError, error.Busy, error.TooBig, error.BadBuffer }) |e| {
        const t = csave.Saver{ .on = true, .err = e, .err_frames = 1 };
        try expect(t.error_text().?.len <= 18);
    }
}

test "the end card deletes the save; the rate limiter's retry reaches it" {
    save.fake.reset();
    var s = csave.Saver{};
    s.probe();
    var c = career.Career.init(racers.kiddie);
    const w = finished(&c, 1, 0, 0);
    _ = c.finish_race(&w);
    s.request(&c, .race);
    top(&s, &c, true, no_link);
    var buf: [csave.blob_len]u8 = undefined;
    try expect(save.fake.peek(csave.key, &buf) != null);
    c.done = true;
    save.fake.failNext(error.RateLimited);
    s.request(&c, .finished);
    try expect(s.marking());
    top(&s, &c, false, no_link);
    try expect(save.fake.peek(csave.key, &buf) != null);
    // The exit hook finishes the delete.
    save.fake.setExitRequested();
    top(&s, &c, false, no_link);
    try expect(save.fake.peek(csave.key, &buf) == null);
    try expectEqual(@as(u32, 1), s.deletes);
    // Nothing stored: a finished circuit asks nothing.
    save.fake.reboot();
    var t = csave.Saver{};
    t.probe();
    try expectEqual(csave.Found.none, t.found);
    t.request(&c, .finished);
    try expect(!t.marking());
}

test "the chooser: CONTINUE first, NEW CAREER asks (NO first), B backs out a step" {
    var ch = csave.Chooser{};
    ch.enter();
    try expectEqual(@as(usize, 2), ch.rows(true).len);
    try expectEqual(csave.Pick.resume_career, ch.update(true, .{ .a = true }));
    try expect(!ch.open);

    ch.enter();
    try expectEqual(csave.Pick.none, ch.update(true, .{ .down = true }));
    try expectEqual(@as(u8, 1), ch.cursor);
    try expectEqual(csave.Pick.none, ch.update(true, .{ .a = true }));
    try expect(ch.confirm and ch.cursor == 0); // NO, KEEP IT under the cursor
    try std.testing.expectEqualStrings("NO, KEEP IT", ch.rows(true)[0]);
    // A on NO: back to the rows, on NEW CAREER.
    try expectEqual(csave.Pick.none, ch.update(true, .{ .a = true }));
    try expect(!ch.confirm and ch.cursor == 1 and ch.open);
    // A, Down, A: YES.
    _ = ch.update(true, .{ .a = true });
    _ = ch.update(true, .{ .down = true });
    try expectEqual(csave.Pick.new_career, ch.update(true, .{ .a = true }));
    try expect(!ch.open);
    // B from the confirm goes back to the rows, B there to the menu.
    ch.enter();
    _ = ch.update(true, .{ .up = true }); // wraps to NEW CAREER
    try expectEqual(@as(u8, 1), ch.cursor);
    _ = ch.update(true, .{ .a = true });
    try expectEqual(csave.Pick.none, ch.update(true, .{ .b = true }));
    try expect(ch.open and !ch.confirm);
    try expectEqual(csave.Pick.back, ch.update(true, .{ .b = true }));
    try expect(!ch.open);
}

test "every chooser line and the SAVING mark fit the 18-character hint width" {
    var buf: [18]u8 = undefined;
    var c = career.Career.init(racers.snouty);
    for (0..track.leagues.len) |l| {
        for (0..track.tracks_per_league + 1) |r| {
            c.league = @intCast(l);
            c.race = @intCast(r);
            const h = csave.continue_hint(&c, &buf);
            try expect(h.len <= 18);
            if (r < track.tracks_per_league) try expect(h[h.len - 1] == '1' + @as(u8, @intCast(r)));
        }
    }
    c.league = 0;
    c.race = 1;
    try std.testing.expectEqualStrings("THE DUMPS, RACE 2", csave.continue_hint(&c, &buf));
    c.league = 1;
    c.race = 3;
    try std.testing.expectEqualStrings("THE RUNOFF RESULTS", csave.continue_hint(&c, &buf));
    var ch = csave.Chooser{};
    for ([_]bool{ false, true }) |cf| {
        ch.confirm = cf;
        for ([_]bool{ false, true }) |can| {
            for (ch.rows(can)) |row| try expect(row.len <= 18);
            for (0..2) |cur| {
                ch.cursor = @intCast(cur);
                for ([_]csave.Found{ .none, .career, .old, .damaged }) |f| try expect(ch.hint(can, f, &c, &buf).len <= 18);
            }
        }
    }
    try expect("SAVING".len <= 18);
}
