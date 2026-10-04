//! The frontend's screen flow (SPEC.md 5, 11.1): splash -> [pick] -> running
//! <-> menu, or halted. main.zig owns the console and the drawing and hands
//! them in as `Ctx`; this file owns which screen is up and which buttons it
//! may see. No cart-api import, so tests/flow_unit.zig drives it on the host
//! (drive picking is compiled out of the wasm build, so no preview script can
//! reach the picker).
//!
//! The rule (review EM-01): every transition calls `suppress_held`, and
//! every screen but the game reads `input.State.live_edge()`, so the button
//! that leaves one screen never acts on the next one in the same or a later
//! update. The A that skips the splash does not also pick the first ROM, a
//! Down does not move the cursor, and an A or B pressed together with the Select hold does not close the menu it
//! opens. Released and pressed again, the button acts as usual.
pub const input = @import("input.zig");

pub const State = enum(u32) { splash = 0, running = 1, menu = 2, pick = 3, halted = 4, rewind = 5 };

/// What a menu update asks for (frontend/menu.zig `Result`).
pub const MenuResult = enum { stay, resume_game };

/// `Ctx` provides, all called from `update`:
///
/// - `splash_frame(ctx, skip: bool) bool`: one splash frame; true when it is over.
/// - `pick_frame(ctx, e: input.Edge) ?usize`: one picker frame; a choice (a
///   candidate index) ends it.
/// - `begin_choice(ctx, choice: usize) bool`: create the console for that choice;
///   false when it cannot run (the halted screen follows).
/// - `play_begin(ctx)`: the game starts, after the splash or the picker (not
///   after the menu closes).
/// - `step(ctx, pad: u8, fresh: bool, fast: bool)`: one game update with that
///   pad byte; `fresh` is a press this frame that is not held over from the
///   last screen; `fast` is the fast-forward gesture (Select tapped, then
///   pressed and held, frontend/input.zig): several frames, only the last
///   one drawn.
/// - `menu_open(ctx)`, `menu_frame(ctx, e: input.Edge) MenuResult`,
///   `menu_close(ctx)`: the emulator menu over the frozen game.
/// - `rewind_open(ctx)`, `rewind_frame(ctx, dir: i2)`, `rewind_close(ctx)`:
///   the chorded rewind (Left during a fast-forward hold, frontend/input.zig):
///   the game frozen as for the menu, `dir` a time step this frame (-1 back
///   0.5 s, 1 forward, 0 none; Left/Right with the menu's auto-repeat,
///   `input.ScrubRepeat`), only the scrub bar on screen. Letting go of
///   Select closes it and the game resumes from there in the same update,
///   as after the menu (`suppress_held`, so a held Left or Right does not
///   reach the game). No button reaches the game meanwhile; Start (the OS
///   chord with the held Select) does nothing.
/// - `halted_frame(ctx)`: draw the halted screen.
pub fn Flow(comptime Ctx: type) type {
    return struct {
        const Self = @This();

        state: State = .splash,
        controls: input.State = .{},
        /// Leave the splash for the picker instead of the game.
        pick_after_splash: bool = false,
        /// Left/Right auto-repeat in the chorded rewind.
        scrub: input.ScrubRepeat = .{},

        /// One badge frame with that frame's controls.
        pub fn update(f: *Self, ctx: *Ctx, c: input.Controls) void {
            f.controls.poll(c);
            switch (f.state) {
                .splash => if (ctx.splash_frame(f.controls.edge.any_pressed())) {
                    f.controls.suppress_held();
                    if (f.pick_after_splash) {
                        f.state = .pick;
                        f.pick(ctx);
                    } else {
                        f.state = .running;
                        ctx.play_begin();
                        f.run(ctx);
                    }
                },
                .pick => f.pick(ctx),
                .halted => ctx.halted_frame(),
                .running => f.run(ctx),
                .menu => if (ctx.menu_frame(f.controls.live_edge()) == .resume_game) {
                    ctx.menu_close();
                    f.controls.suppress_held();
                    f.state = .running;
                    f.run(ctx);
                },
                .rewind => {
                    const e = f.controls.live_edge();
                    if (e.held(.select)) return ctx.rewind_frame(f.scrub.update(e));
                    ctx.rewind_close();
                    f.controls.suppress_held();
                    f.state = .running;
                    f.run(ctx);
                },
            }
        }

        /// One picker frame; on a choice create the console and start the
        /// game in the same frame.
        fn pick(f: *Self, ctx: *Ctx) void {
            const choice = ctx.pick_frame(f.controls.live_edge()) orelse return;
            f.controls.suppress_held();
            if (!ctx.begin_choice(choice)) {
                f.state = .halted;
                return;
            }
            f.state = .running;
            ctx.play_begin();
            f.run(ctx);
        }

        /// One game update (one frame, several when fast forwarding), or
        /// opening the menu or the chorded rewind instead of stepping.
        fn run(f: *Self, ctx: *Ctx) void {
            const in = f.controls.game_frame();
            if (in.open_menu) {
                f.state = .menu;
                // The held Select, and anything held with it (an A, a
                // Left that would scrub), waits for a release.
                f.controls.suppress_held();
                ctx.menu_open();
                _ = ctx.menu_frame(f.controls.live_edge());
                return;
            }
            if (in.rewind) {
                f.state = .rewind;
                f.scrub = .{};
                ctx.rewind_open();
                // The Left press that started it is the first step back.
                ctx.rewind_frame(f.scrub.update(f.controls.live_edge()));
                return;
            }
            ctx.step(in.pad, f.controls.live_edge().any_pressed(), in.fast);
        }
    };
}

/// The picker's cursor and choice over `playable` (one flag per listed
/// file); frontend/picker.zig draws it. The cursor starts on the first
/// playable file; Up/Down move (wrapping), A plays the file under the cursor
/// when it is playable. There is no way out but a file: the badge build
/// embeds no ROM.
pub const Picker = struct {
    cursor: usize = 0,
    placed: bool = false,

    /// Returns null to stay, or the chosen candidate index.
    pub fn update(p: *Picker, e: input.Edge, playable: []const bool) ?usize {
        const n = playable.len;
        if (!p.placed) {
            p.placed = true;
            for (playable, 0..) |ok, i| {
                if (ok) {
                    p.cursor = i;
                    break;
                }
            }
        }
        if (n == 0) return null;
        if (e.pressed(.up)) p.cursor = (p.cursor + n - 1) % n;
        if (e.pressed(.down)) p.cursor = (p.cursor + 1) % n;
        if (e.pressed(.a) and playable[p.cursor]) return p.cursor;
        return null;
    }
};
