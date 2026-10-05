//! Save and continue (docs/SAVES.md at the repository root; the cart's
//! docs/RUNNING.md "Saves"): one key, `paperclips/game`, holding the
//! whole game (game/snapshot.zig). Free of the cart API like app.zig, so
//! the host tests drive it against lib/save.zig's fake.
//!
//! - The probe: `save.supported()` once, on the title's second frame (the
//!   title is already on screen, so the 250 ms stock-firmware timeout is
//!   invisible). On stock firmware, in the simulator and in wasm builds it
//!   is false and nothing here shows or runs: the cart is exactly the one
//!   without saves.
//! - With saves: `watchExit()`, then the saved game is read and decoded
//!   into the App's Game. The title offers CONTINUE / NEW GAME (NEW GAME
//!   asks first); a save from another build of the port says "SAVE FROM
//!   OLDER VERSION" and starts a new game.
//! - Autosave every `knobs.autosave_ms` of play (game time), every
//!   `knobs.idle_autosave_ms` once nobody has pressed a button for
//!   `knobs.idle_after_ms`; on opening the message log (Start, the cart's
//!   menu); on the OS's "Exit cart" (`exitRequested()`, then
//!   `exitReady()`). The original autosaves every 25 s to localStorage,
//!   which is free; here every save freezes the cart ~110 ms and erases a
//!   directory block shared by every cart, so the idle game left running
//!   on a desk saves at most every 5 minutes.
//! - A timer or menu save waits for a calm frame: none while a battle is
//!   live (both sides have ships: the combat steps that make the slow
//!   frames), for at most `knobs.calm_wait_max_ms`.
//! - The write happens at the start of the frame after the one that shows
//!   the SAVING mark, so the mark is what the screen holds while the cart
//!   is parked. `wrote` tells main.zig to drop the stalled time from its
//!   real-time game clock (no catch-up burst after a save).
//! - Errors: RateLimited is retried at the next trigger; any other is
//!   shown once (`err_frames`), and later triggers keep trying quietly.
const std = @import("std");
const G = @import("game");
const save = @import("save");

const snap = G.snapshot;

pub const key = "paperclips/game";

pub const knobs = struct {
    /// Game time between autosaves while someone plays.
    pub const autosave_ms: u64 = 60_000;
    /// Without a button press for this long the game counts as idle...
    pub const idle_after_ms: u64 = 300_000;
    /// ...and autosaves this often.
    pub const idle_autosave_ms: u64 = 300_000;
    /// A timer or menu save waits at most this long for a calm frame.
    pub const calm_wait_max_ms: u64 = 30_000;
    /// The update that probes (the title has been on screen one frame).
    pub const probe_frame: u32 = 2;
    /// How long an error shows (frames).
    pub const error_frames: u32 = 180;
};

/// What the title found in the store.
pub const Found = enum { none, game, old_version, damaged };

pub const Trigger = enum { timer, menu, exit };

/// The blob for reads and writes (must be in cart RAM). Smaller than
/// `snap.max_blob` (the whole image incompressible, 25.3 KB) to keep the
/// cart in its 200 KB: the largest real save, a 200 vs 200 battle at its
/// first frame with a full log, is 17.6 KB (snapshot_tests.zig). A bigger
/// one would fail with SAVE FAILED: TOO BIG and leave the last save.
pub const blob_cap = 22 * 1024;
var blob: [blob_cap]u8 align(4) = undefined;

pub const Saver = struct {
    probed: bool = false,
    /// `save.supported()`: the OS stores saves.
    on: bool = false,
    found: Found = .none,
    /// Game time (`now_ms`) of the last save attempt and of the last press.
    last_save_ms: u64 = 0,
    last_input_ms: u64 = 0,
    pending: ?Trigger = null,
    pending_since_ms: u64 = 0,
    /// The SAVING mark is in this frame; the write comes next update.
    armed: bool = false,
    /// A write (a blocking call) ran during this update.
    wrote: bool = false,
    exit_done: bool = false,
    /// The error on screen (`err_frames` left) and whether one was shown.
    err: ?save.Error = null,
    err_frames: u32 = 0,
    err_shown: bool = false,
    /// Counters (tests, debug): commits asked for, the last blob's size,
    /// rate-limited attempts.
    saves: u32 = 0,
    last_size: usize = 0,
    rate_limited: u32 = 0,

    /// The probe and, when the cart is still on the title, the read.
    /// Loads a found game into `g` (the caller does not play it yet).
    pub fn probe(s: *Saver, g: *G.Game, playing: bool) void {
        s.probed = true;
        s.on = save.supported();
        if (!s.on) return;
        save.watchExit() catch {};
        if (playing) return; // bench runs start in a game
        const n = save.read(key, &blob) catch |e| {
            s.found = if (e == error.NotFound) .none else .damaged;
            return;
        };
        if (n > blob.len) {
            s.found = .damaged;
            return;
        }
        s.found = if (snap.decode(blob[0..n], g)) .game else |e| switch (e) {
            error.OldVersion => .old_version,
            else => .damaged,
        };
    }

    /// A game starts or continues: the timers count from now.
    pub fn start_game(s: *Saver, g: *const G.Game) void {
        s.found = .none;
        s.last_save_ms = g.now_ms;
        s.last_input_ms = g.now_ms;
        s.pending = null;
        s.armed = false;
    }

    pub fn input(s: *Saver, g: *const G.Game) void {
        s.last_input_ms = g.now_ms;
    }

    /// Ask for a save at the next calm frame.
    pub fn request(s: *Saver, g: *const G.Game, t: Trigger) void {
        if (!s.on or s.pending != null) return;
        s.pending = t;
        s.pending_since_ms = g.now_ms;
    }

    /// The start of an update: the OS's exit request, then a save whose
    /// mark the last frame showed. True when the cart is exiting (the
    /// update should do nothing else).
    pub fn frame_start(s: *Saver, g: *G.Game, playing: bool) bool {
        s.wrote = false;
        if (s.err_frames > 0) s.err_frames -= 1;
        if (!s.on) return false;
        if (save.exitRequested()) {
            if (!s.exit_done) {
                if (playing) s.write(g);
                s.exit_done = true;
                save.exitReady();
            }
            return true;
        }
        if (s.armed) {
            s.armed = false;
            if (playing) s.write(g);
        }
        return false;
    }

    /// The end of an update (after the game's tick): the autosave timer,
    /// and a pending save arms on a calm frame.
    pub fn frame_end(s: *Saver, g: *const G.Game, playing: bool) void {
        if (!s.on or !playing) return;
        const now = g.now_ms;
        const idle = now -| s.last_input_ms >= knobs.idle_after_ms;
        const every = if (idle) knobs.idle_autosave_ms else knobs.autosave_ms;
        if (now -| s.last_save_ms >= every) s.request(g, .timer);
        if (s.pending != null and !s.armed) {
            if (calm(g) or now -| s.pending_since_ms >= knobs.calm_wait_max_ms) s.armed = true;
        }
    }

    fn write(s: *Saver, g: *G.Game) void {
        s.pending = null;
        s.last_save_ms = g.now_ms;
        const b = snap.encode(g, &blob) catch {
            s.fail(error.TooBig);
            return;
        };
        s.last_size = b.len;
        s.wrote = true;
        save.write(key, b) catch |e| {
            if (e == error.RateLimited) s.rate_limited += 1 else s.fail(e);
            return;
        };
        s.saves += 1;
    }

    fn fail(s: *Saver, e: save.Error) void {
        if (s.err_shown) return;
        s.err_shown = true;
        s.err = e;
        s.err_frames = knobs.error_frames;
    }

    /// The line to show while an error is up, else null.
    pub fn error_text(s: *const Saver) ?[]const u8 {
        if (s.err_frames == 0) return null;
        const e = s.err orelse return null;
        return switch (e) {
            error.NoSpace => "SAVE FAILED: NO SPACE",
            error.IoError => "SAVE FAILED: FLASH ERROR",
            error.Busy => "SAVE FAILED: OS BUSY",
            error.TooBig => "SAVE FAILED: TOO BIG",
            else => "SAVE FAILED",
        };
    }
};

/// No live battle: both sides with ships means combat steps (the heavy
/// frames) and a ship section in the save.
pub fn calm(g: *const G.Game) bool {
    return !(g.num_left_ships > 0 and g.num_right_ships > 0);
}
