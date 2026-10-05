//! New for Snouty GCP (cart saves, branch `saves/gcp`): the CIRCUIT's
//! save. One key, `gcp/career`, holds the whole `career.Career` (the SNOUTY
//! GCP: league, race, points, wallet, every car's loadout, the AIs' plans,
//! the last award); root docs/SAVES.md is the store, the cart's
//! docs/RUNNING.md "Saves" the player's side. Pure like career.zig (no cart
//! API): the host tests drive it against lib/save.zig's fake, save_ui.zig
//! draws it and main.zig calls it from a few hooks.
//!
//! - The probe: `save.supported()` once, on update 1 while the splash (or
//!   the title, if Start skipped it) is up, so the 250 ms a stock OS takes
//!   to time out is a splash frame held a little longer. On stock firmware,
//!   in the simulator and in wasm builds it is false and nothing here shows
//!   or runs: the cart is the one without saves, byte for byte in its
//!   screens. With saves: `watchExit()`, then the stored career is read and
//!   checked (`decode`) and kept in `blob`.
//! - Save points (`request`): the race booked (`finish_race`, results to
//!   standings), the garage left for the menu (B), the end card dismissed
//!   (the circuit is over: the key is deleted), and the OS's "Exit cart"
//!   (`exitRequested()`, then `exitReady()`). Each request arms only when
//!   the career's bytes differ from what the store holds (`last`), so B in
//!   and out of the garage costs nothing. Never mid-race: no request comes
//!   from a race frame, and the write happens at the start of the update
//!   after the one that drew the SAVING mark (`armed`), so the mark is what
//!   the screen holds while the cart is parked.
//! - Link play: `Ctx.link` (main.zig's lobby, link select and link race)
//!   blocks every write and delete, the exit hook's too: a parked cart would
//!   stall the lockstep partner. A CIRCUIT never runs over the link, so a
//!   request is never made during one; an exit request then answers
//!   `exitReady()` without writing (nothing of the career changes in link
//!   play, so only a save that had already failed could be lost).
//! - Errors: RateLimited keeps the want and retries at the next save point
//!   (or the exit hook); any other is shown once (`err_frames`), later save
//!   points keep trying quietly.
//!
//! The blob (`header_len` + `payload_len` = 181 B, one 4 KB store block):
//! magic `GCPC`, `version`, the five-byte layout guard (`guard`: racers,
//! leagues, tracks a league, garage slots, top level), the payload length
//! (u16 LE) and an FNV-1a 32 of the payload (u32 LE; the store has its own
//! CRC, this one catches a payload this build misreads), then the fields
//! of `Career` in a fixed order, little-endian (`encode`). A save with
//! another magic, version, guard or length is `old` (the title says so and
//! starts a fresh career); one whose sum or field ranges fail is `damaged`.
//! Bump `version` whenever the payload's fields change.
const std = @import("std");
const save = @import("save");
const career = @import("career.zig");
const racers = @import("racers.zig");
const track = @import("track.zig");
const tuning = @import("tuning.zig");
const world = @import("world.zig");

pub const key = "gcp/career";
pub const magic = "GCPC";
pub const version: u8 = 1;
/// What the payload's layout depends on; a save made with other counts is
/// refused (`old`) rather than misread.
pub const guard = [5]u8{ racers.count, track.leagues.len, track.tracks_per_league, career.slot_count, tuning.level_max };
pub const header_len = 16;
/// The fields `encode` writes (the test checks the count).
pub const payload_len = 165;
pub const blob_len = header_len + payload_len;

/// No gun swapped in (`Loadout.front` / `rear` null).
const own_gun: u8 = 0xFF;

/// What the probe found in the store.
pub const Found = enum(u8) { none, career, old, damaged };
pub const Trigger = enum(u8) { race, menu, finished };
const Want = enum(u8) { none, write, delete };

pub const knobs = struct {
    /// How long an error line shows (frames).
    pub const error_frames: u32 = 180;
    /// The update that probes (the splash has been on screen one frame).
    pub const probe_frame: u32 = 1;
};

// --- The format ----------------------------------------------------------------

fn fnv1a(bytes: []const u8) u32 {
    var h: u32 = 0x811C9DC5;
    for (bytes) |b| h = (h ^ b) *% 0x01000193;
    return h;
}

const Writer = struct {
    buf: []u8,
    n: usize = 0,
    fn u8_(w: *Writer, v: u8) void {
        w.buf[w.n] = v;
        w.n += 1;
    }
    fn u16_(w: *Writer, v: u16) void {
        w.u8_(@truncate(v));
        w.u8_(@truncate(v >> 8));
    }
    fn u32_(w: *Writer, v: u32) void {
        w.u16_(@truncate(v));
        w.u16_(@truncate(v >> 16));
    }
};

const Reader = struct {
    buf: []const u8,
    n: usize = 0,
    fn u8_(r: *Reader) u8 {
        const v = r.buf[r.n];
        r.n += 1;
        return v;
    }
    fn u16_(r: *Reader) u16 {
        const lo = r.u8_();
        return lo | @as(u16, r.u8_()) << 8;
    }
    fn u32_(r: *Reader) u32 {
        const lo = r.u16_();
        return lo | @as(u32, r.u16_()) << 16;
    }
};

/// The blob for `c` in `out` (`blob_len` bytes).
pub fn encode(c: *const career.Career, out: *[blob_len]u8) void {
    var w = Writer{ .buf = out[header_len..] };
    w.u8_(c.racer);
    w.u8_(c.league);
    w.u8_(c.race);
    w.u8_(c.open);
    w.u8_(c.tries);
    w.u32_(c.cycles);
    for (c.points) |p| w.u16_(p);
    for (&c.loadouts) |*lo| {
        w.u8_(if (lo.front) |f| @backingInt(f) else own_gun);
        w.u8_(if (lo.rear) |r| @backingInt(r) else own_gun);
        w.u8_(lo.front_level);
        w.u8_(lo.rear_level);
        w.u8_(lo.plating);
        w.u8_(lo.clock);
        w.u8_(lo.traction);
        w.u8_(lo.burst);
        w.u8_(lo.watchdog);
    }
    for (c.earned) |v| w.u32_(v);
    for (c.spent) |v| w.u32_(v);
    for (c.plan) |v| w.u8_(v);
    w.u16_(c.races);
    w.u16_(c.kills);
    w.u16_(c.wins);
    const a = &c.last;
    w.u8_(a.place);
    w.u16_(a.place_cycles);
    w.u8_(a.kills);
    w.u16_(a.kill_cycles);
    w.u8_(a.chips);
    w.u16_(a.chip_cycles);
    w.u32_(a.total);
    for (a.places) |v| w.u8_(v);
    for (a.points) |v| w.u8_(v);
    w.u8_(@backingInt(c.outcome));
    w.u8_(c.champion);
    w.u8_(c.league_place);
    w.u8_(@intFromBool(c.unlocked));
    w.u8_(@intFromBool(c.done));
    std.debug.assert(w.n == payload_len);

    var h = Writer{ .buf = out[0..header_len] };
    for (magic) |b| h.u8_(b);
    h.u8_(version);
    for (guard) |b| h.u8_(b);
    h.u16_(payload_len);
    h.u32_(fnv1a(out[header_len..]));
}

pub const DecodeError = error{ Old, Damaged };

/// Read a stored blob back into a Career: `error.Old` for another format
/// (magic, version, guard, length), `error.Damaged` for a bad sum or a
/// field out of range.
pub fn decode(blob: []const u8) DecodeError!career.Career {
    if (blob.len < header_len) return error.Old;
    var h = Reader{ .buf = blob[0..header_len] };
    for (magic) |b| if (h.u8_() != b) return error.Old;
    if (h.u8_() != version) return error.Old;
    for (guard) |b| if (h.u8_() != b) return error.Old;
    if (h.u16_() != payload_len or blob.len != blob_len) return error.Old;
    if (h.u32_() != fnv1a(blob[header_len..])) return error.Damaged;

    var r = Reader{ .buf = blob[header_len..] };
    var c = career.Career.init(0);
    c.racer = r.u8_();
    c.league = r.u8_();
    c.race = r.u8_();
    c.open = r.u8_();
    c.tries = r.u8_();
    c.cycles = r.u32_();
    for (&c.points) |*p| p.* = r.u16_();
    for (&c.loadouts) |*lo| {
        const f = r.u8_();
        const rr = r.u8_();
        if (f != own_gun and f >= 4) return error.Damaged;
        if (rr != own_gun and rr >= 4) return error.Damaged;
        lo.front = if (f == own_gun) null else @as(world.Front, @fromBackingInt(f));
        lo.rear = if (rr == own_gun) null else @as(world.Rear, @fromBackingInt(rr));
        lo.front_level = r.u8_();
        lo.rear_level = r.u8_();
        lo.plating = r.u8_();
        lo.clock = r.u8_();
        lo.traction = r.u8_();
        lo.burst = r.u8_();
        lo.watchdog = r.u8_();
        if (lo.front_level < 1 or lo.front_level > tuning.level_max) return error.Damaged;
        if (lo.rear_level < 1 or lo.rear_level > tuning.level_max) return error.Damaged;
        for ([_]u8{ lo.plating, lo.clock, lo.traction, lo.burst, lo.watchdog }) |v| {
            if (v > tuning.level_max) return error.Damaged;
        }
    }
    for (&c.earned) |*v| v.* = r.u32_();
    for (&c.spent) |*v| v.* = r.u32_();
    for (&c.plan, 0..) |*v, i| {
        // A later build may shorten a plan: the AI then has bought it all.
        v.* = @min(r.u8_(), @as(u8, @intCast(career.plans[i].len)));
    }
    c.races = r.u16_();
    c.kills = r.u16_();
    c.wins = r.u16_();
    const a = &c.last;
    a.place = r.u8_();
    a.place_cycles = r.u16_();
    a.kills = r.u8_();
    a.kill_cycles = r.u16_();
    a.chips = r.u8_();
    a.chip_cycles = r.u16_();
    a.total = r.u32_();
    for (&a.places) |*v| v.* = r.u8_();
    for (&a.points) |*v| v.* = r.u8_();
    const outcome = r.u8_();
    c.champion = r.u8_();
    c.league_place = r.u8_();
    const unlocked = r.u8_();
    const done = r.u8_();
    std.debug.assert(r.n == payload_len);

    if (c.racer >= racers.count or c.league >= track.leagues.len) return error.Damaged;
    if (c.race > track.tracks_per_league or c.open < c.league + 1 or c.open > track.leagues.len) return error.Damaged;
    if (c.tries == 0 or outcome > 2 or unlocked > 1 or done > 1) return error.Damaged;
    if (c.champion >= racers.count or c.league_place > racers.count or a.place > racers.count) return error.Damaged;
    for (a.places) |p| if (p > racers.count) return error.Damaged;
    c.outcome = @fromBackingInt(outcome);
    c.unlocked = unlocked == 1;
    c.done = done == 1;
    return c;
}

// --- Where a continued career picks up ------------------------------------------

pub const Resume = enum(u8) { garage, standings, end };

/// A career saved after its league's third race (the league not closed
/// yet) resumes on the standings, whose A closes it as before; one saved
/// on the end card resumes there; everything else in the garage.
/// `close_league` is a pure function of the career, so a league closed
/// again from the saved standings gives the same cards and CYCLES.
pub fn resume_at(c: *const career.Career) Resume {
    if (c.done) return .end;
    if (c.league_over()) return .standings;
    return .garage;
}

/// The CONTINUE CAREER row's hint (at most 18 characters): the league and
/// the next race, e.g. `THE DUMPS, RACE 2`.
pub fn continue_hint(c: *const career.Career, buf: *[18]u8) []const u8 {
    if (c.done) return "CIRCUIT FINISHED";
    const name = track.leagues[c.league % track.leagues.len].name;
    var n: usize = 0;
    const tail_race = ", RACE 1";
    const tail_over = " RESULTS";
    const tail = if (c.league_over()) tail_over else tail_race;
    const keep = @min(name.len, buf.len - tail.len);
    @memcpy(buf[0..keep], name[0..keep]);
    n = keep;
    @memcpy(buf[n..][0..tail.len], tail);
    n += tail.len;
    if (!c.league_over()) buf[n - 1] = @as(u8, '1') + @min(c.race, 8);
    return buf[0..n];
}

// --- The saver -------------------------------------------------------------------

/// What main.zig passes each update.
pub const Ctx = struct {
    /// The CIRCUIT in this session (`prix`) and whether one is on
    /// (`prix_on`).
    career: *const career.Career,
    on: bool,
    /// A link session is up (the LINK lobby, the link select, a link race,
    /// its pause or results): no write or delete may run.
    link: bool,
};

pub const Saver = struct {
    probed: bool = false,
    /// `save.supported()`: the OS stores saves. False: no save UI at all.
    on: bool = false,
    /// `.career`: `blob` holds the stored career (CONTINUE CAREER decodes
    /// it; no second copy of a Career is kept).
    found: Found = .none,
    /// The store holds our key (read at the probe or written since).
    stored: bool = false,
    /// FNV-1a of the blob the store holds (`last_ok`: a career of this
    /// build), for "changed since the last save" without a copy.
    last_sum: u32 = 0,
    last_ok: bool = false,
    want: Want = .none,
    /// The SAVING mark is in this frame; the write comes next update.
    armed: bool = false,
    exit_done: bool = false,
    err: ?save.Error = null,
    err_frames: u32 = 0,
    err_shown: bool = false,
    /// Counters (tests, the bench note): writes and deletes that reached
    /// the store, rate-limited attempts, save points a link session held.
    writes: u32 = 0,
    deletes: u32 = 0,
    rate_limited: u32 = 0,
    link_held: u32 = 0,
    /// The blob being written (cart RAM, as `save.write` needs).
    blob: [blob_len]u8 align(4) = @splat(0),

    /// The probe and the read. Once per boot: main.zig calls `boot` on
    /// every update and it probes on `knobs.probe_frame` of the splash or
    /// title (nothing else on screen moves then).
    pub fn boot(s: *Saver, frame: u32, quiet_screen: bool) void {
        if (s.probed or frame < knobs.probe_frame or !quiet_screen) return;
        s.probe();
    }

    pub fn probe(s: *Saver) void {
        s.probed = true;
        s.on = save.supported();
        if (!s.on) return;
        save.watchExit() catch {};
        const n = save.read(key, &s.blob) catch |e| {
            s.found = if (e == error.NotFound) .none else .damaged;
            s.stored = e != error.NotFound;
            return;
        };
        s.stored = true;
        if (n > s.blob.len) {
            s.found = .old;
            return;
        }
        _ = decode(s.blob[0..n]) catch |e| {
            s.found = if (e == error.Old) .old else .damaged;
            return;
        };
        s.found = .career;
        s.last_sum = fnv1a(&s.blob);
        s.last_ok = true;
    }

    /// CIRCUIT in the main menu opens the CONTINUE / NEW chooser (instead
    /// of today's straight resume or racer select): only with saves, and
    /// only when there is something to continue or to warn about.
    pub fn offers(s: *const Saver, session: bool) bool {
        return s.on and (session or s.found != .none);
    }

    /// The chooser has a CONTINUE CAREER row: a career in this session or
    /// a readable one in the store.
    pub fn can_continue(s: *const Saver, session: bool) bool {
        return session or s.found == .career;
    }

    /// The stored career the probe found (`found == .career`), decoded
    /// from `blob`; a fresh one otherwise. CONTINUE CAREER loads it (a
    /// career in the session is newer and main.zig keeps that).
    pub fn stored_career(s: *const Saver) career.Career {
        if (s.found != .career) return career.Career.init(0);
        return decode(&s.blob) catch career.Career.init(0);
    }

    /// The career differs from what the store holds. Encodes it into
    /// `blob`: from here on the session's career is the one that counts
    /// (the chooser has continued or replaced the stored one).
    pub fn dirty(s: *Saver, c: *const career.Career) bool {
        s.found = .none;
        encode(c, &s.blob);
        return !(s.last_ok and s.last_sum == fnv1a(&s.blob));
    }

    /// A save point: the SAVING mark goes into this frame and the write
    /// (or, `.finished`, the delete) runs at the start of the next update.
    /// Nothing when the career is what the store holds.
    pub fn request(s: *Saver, c: *const career.Career, t: Trigger) void {
        if (!s.on) return;
        switch (t) {
            .finished => {
                s.found = .none;
                if (!s.stored) {
                    s.want = .none;
                    return;
                }
                s.want = .delete;
            },
            .race, .menu => {
                if (!s.dirty(c)) return;
                s.want = .write;
            },
        }
        s.armed = true;
    }

    /// The SAVING mark belongs in this frame.
    pub fn marking(s: *const Saver) bool {
        return s.on and s.armed;
    }

    /// The top of every update: the OS's exit request (save if anything
    /// changed, then `exitReady`), then a save whose mark the last frame
    /// showed. Never inside a link session.
    pub fn frame_start(s: *Saver, ctx: Ctx) void {
        if (s.err_frames > 0) s.err_frames -= 1;
        if (!s.on) return;
        if (!s.exit_done and save.exitRequested()) {
            s.exit_done = true;
            s.armed = false;
            if (ctx.link) s.link_held += 1 else s.flush(ctx, true);
            save.exitReady();
            return;
        }
        if (!s.armed) return;
        s.armed = false;
        if (ctx.link) {
            s.link_held += 1;
            return;
        }
        s.flush(ctx, false);
    }

    fn flush(s: *Saver, ctx: Ctx, exiting: bool) void {
        if (s.want == .delete) {
            save.delete(key) catch |e| switch (e) {
                error.NotFound => {},
                error.RateLimited => {
                    s.rate_limited += 1;
                    return;
                },
                else => return s.fail(e),
            };
            s.deletes += 1;
            s.want = .none;
            s.stored = false;
            s.last_ok = false;
            return;
        }
        if (!ctx.on) return;
        if (!exiting and s.want != .write) return;
        if (!s.dirty(ctx.career)) {
            s.want = .none;
            return;
        }
        save.write(key, &s.blob) catch |e| {
            if (e == error.RateLimited) s.rate_limited += 1 else s.fail(e);
            return;
        };
        s.writes += 1;
        s.want = .none;
        s.stored = true;
        s.last_sum = fnv1a(&s.blob);
        s.last_ok = true;
    }

    fn fail(s: *Saver, e: save.Error) void {
        if (s.err_shown) return;
        s.err_shown = true;
        s.err = e;
        s.err_frames = knobs.error_frames;
    }

    /// The line to show while an error is up (at most 18 characters).
    pub fn error_text(s: *const Saver) ?[]const u8 {
        if (s.err_frames == 0) return null;
        const e = s.err orelse return null;
        return switch (e) {
            error.NoSpace => "SAVE: NO SPACE",
            error.IoError => "SAVE: FLASH ERROR",
            error.Busy => "SAVE: OS BUSY",
            error.TooBig => "SAVE: TOO BIG",
            else => "SAVE FAILED",
        };
    }
};

// --- The chooser (CIRCUIT in the main menu, saves only) ---------------------------

pub const Keys = struct { up: bool = false, down: bool = false, a: bool = false, b: bool = false };

pub const Pick = enum(u8) { none, resume_career, new_career, back };

/// CONTINUE CAREER / NEW CAREER, and NEW CAREER's confirm (NO first). An
/// unreadable save leaves NEW CAREER alone, with the reason as its hint.
pub const Chooser = struct {
    open: bool = false,
    confirm: bool = false,
    cursor: u8 = 0,

    pub fn enter(ch: *Chooser) void {
        ch.* = .{ .open = true };
    }

    pub fn rows(ch: *const Chooser, can_continue: bool) []const []const u8 {
        if (ch.confirm) return &.{ "NO, KEEP IT", "YES, START OVER" };
        if (can_continue) return &.{ "CONTINUE CAREER", "NEW CAREER" };
        return &.{"NEW CAREER"};
    }

    /// Up/Down move, A (or Start) picks, B backs out (from the confirm to
    /// the rows, from the rows to the menu).
    pub fn update(ch: *Chooser, can_continue: bool, k: Keys) Pick {
        const n: u8 = @intCast(ch.rows(can_continue).len);
        if (ch.cursor >= n) ch.cursor = 0;
        if (k.b) {
            if (ch.confirm) {
                ch.confirm = false;
                ch.cursor = 1;
                return .none;
            }
            ch.open = false;
            return .back;
        }
        if (k.up) ch.cursor = if (ch.cursor == 0) n - 1 else ch.cursor - 1;
        if (k.down) ch.cursor = if (ch.cursor + 1 >= n) 0 else ch.cursor + 1;
        if (!k.a) return .none;
        if (ch.confirm) {
            if (ch.cursor == 0) {
                ch.confirm = false;
                ch.cursor = 1;
                return .none;
            }
            ch.open = false;
            return .new_career;
        }
        if (can_continue and ch.cursor == 0) {
            ch.open = false;
            return .resume_career;
        }
        if (can_continue) {
            ch.confirm = true;
            ch.cursor = 0;
            return .none;
        }
        ch.open = false;
        return .new_career;
    }

    /// The hint under the rows (at most 18 characters); `cont` is the
    /// career CONTINUE CAREER would load.
    pub fn hint(ch: *const Chooser, can_continue: bool, found: Found, cont: *const career.Career, buf: *[18]u8) []const u8 {
        if (ch.confirm) return "LOSE THAT CAREER?";
        if (can_continue and ch.cursor == 0) return continue_hint(cont, buf);
        if (can_continue) return "PICK A NEW RACER";
        return switch (found) {
            .damaged => "SAVE IS DAMAGED",
            .old => "OLD SAVE: UNUSABLE",
            else => "PICK A NEW RACER",
        };
    }
};
