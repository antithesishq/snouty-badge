//! The game's state machine (SPEC.md section 6, PLAN.md M1 Track P and
//! M2 Track R): the title over an attract round, the menu, HOW TO PLAY,
//! OPTIONS, and two modes.
//!
//! GRID LADDER: level intro, countdown 3-2-1-RUN, play, then LEVEL CLEAR
//! and the next level. Your derez with a snapshot left freezes time,
//! then the round runs backwards 2 s (`history.zig`: the trails retract
//! newest first at 3x under a scanline tint), the exact state 2 s before
//! the crash comes back, and a short 2-1-RUN resumes it. With none left
//! it is CORE DUMPED. A level clear gives a snapshot back (up to 3).
//!
//! SKIRMISH: you against 1-3 programs of one tier in an arena you pick,
//! first to 3 round wins, with Achtung's points (+1 for each cycle you
//! outlive). No snapshots.
//!
//! Start pauses (RESUME / RESTART / QUIT). Pure: no cart API, so host
//! tests run it; main.zig feeds it buttons and hands `view()` and `world`
//! to the renderer.
const std = @import("std");
const sim = @import("sim.zig");
const ai = @import("ai.zig");
const rng = @import("rng.zig");
const render = @import("render.zig");
const levels = @import("levels.zig");
const layouts = @import("layouts.zig");
const history = @import("history.zig");

/// `debug_state` reports these numbers (docs/RUNNING.md section 6).
/// M1's 0..9 keep their numbers.
pub const State = enum(u8) {
    /// The logo over the attract round.
    title,
    menu,
    howto,
    /// Level (or SKIRMISH round) intro banner over the arena.
    intro,
    /// 3-2-1, or 2-1 after a rewind (`resume`).
    countdown,
    play,
    /// Your derez with no snapshot left (or the clock ran out; the World
    /// runs on); in SKIRMISH you watch the programs finish the round.
    derez,
    /// LEVEL CLEAR and the score tally.
    clear,
    /// CORE DUMPED (or EXIT 0 after QUIT): score, level reached, session high.
    game_over,
    paused,
    /// Your derez with a snapshot left: time stops on the crash.
    frozen,
    /// The round runs backwards, then the exact restore and replay.
    rewind,
    options,
    /// SKIRMISH's setup menu.
    skirmish_setup,
    /// SKIRMISH: the round's winner and the standings.
    round_over,
    /// SKIRMISH: the match card.
    match_over,
    /// LINK DUEL: the cable screen and the lobby (the host's setup, the
    /// guest's view of it). The duel itself runs in countdown, play,
    /// round_over and match_over with `mode` link.
    link_lobby,
    /// LINK DUEL: PEER LEFT or NO CONTEST, then the menu or the next round.
    link_notice,
};

pub const Mode = enum(u8) { ladder, skirmish, link };

/// Buttons, held or newly pressed this tick.
pub const Buttons = packed struct(u8) {
    up: bool = false,
    right: bool = false,
    down: bool = false,
    left: bool = false,
    a: bool = false,
    b: bool = false,
    start: bool = false,
    select: bool = false,

    fn any(b: Buttons) bool {
        return @as(u8, @bitCast(b)) != 0;
    }
};

pub const tuning = struct {
    /// Snapshots per game (SPEC 6), and the most a level clear tops up to.
    pub const max_snapshots: u8 = 3;
    /// Level intro banner; A skips it after `skip_ticks`.
    pub const intro_ticks: u32 = 110;
    pub const skip_ticks: u32 = 20;
    /// 3, 2, 1: this long each (a booth wants quick restarts).
    pub const count_step_ticks: u32 = 45;
    pub const countdown_ticks: u32 = 3 * count_step_ticks;
    /// After a rewind: 2, 1 only.
    pub const resume_ticks: u32 = 2 * count_step_ticks;
    /// RUN stays up this long into play.
    pub const run_banner_ticks: u32 = 40;
    /// SUDDEN DEATH stays up this long once the first ring closes.
    pub const sudden_death_banner_ticks: u32 = 100;
    /// Your derez: the crash banner while the World runs on.
    pub const derez_ticks: u32 = 120;
    /// Your derez with a snapshot: time stands still this long (SPEC 6).
    pub const freeze_ticks: u32 = 20;
    /// The replay after a restore: AI work units per frame (about 0.55 us
    /// each, ai.zig) and ticks per frame. A tick can take a whole
    /// `ai.tuning.tick_pool`, so a frame goes on only while that much is
    /// left: no replay frame passes ~8 ms.
    pub const replay_units: u64 = 14_000;
    pub const replay_max_ticks: u32 = 40;
    /// The tint wipes down the arena this many pixel rows a frame as a
    /// rewind starts (a full tinted repaint at once costs ~10 ms).
    pub const wipe_rows: u8 = 20;
    /// A longer rewind retracts faster: about this many frames at most.
    pub const retract_frames: u32 = 40;
    /// A crash within `escalate_window` ticks of resuming means that
    /// landing was already lost (a Tron endgame is decided seconds before
    /// the crash): this rewind lands `escalate_ticks` before it, which is
    /// usually past the kept keyframes, so the round starts over (the
    /// same round: same seed, same programs). The window must pass a 2 s
    /// rewind plus a keyframe gap: a replay then never crosses the last
    /// landing, where the autopilot changed (`finish_rewind`).
    pub const escalate_window: u32 = 180;
    pub const escalate_ticks: u32 = 120;
    comptime {
        std.debug.assert(escalate_window > history.tuning.rewind_ticks + history.tuning.keyframe_every);
    }
    /// After a rewind the autopilot (the ladder bot, the bench) rides as
    /// `alt_tier` this long with random moves `alt_slip_permille` of its
    /// decisions (a new stream per rewind), or it would make the same
    /// moves into the same crash, retry after retry.
    pub const autopilot_alt_ticks: u32 = 300;
    pub const alt_tier: ai.Tier = .avoid;
    pub const alt_slip_permille: u16 = 80;
    /// LEVEL CLEAR: the tally; A moves on after `clear_min_ticks`.
    pub const clear_ticks: u32 = 210;
    pub const clear_min_ticks: u32 = 60;
    /// The tally: the bonus line at this tick, the score counts up over
    /// `tally_count_ticks`, then "+1 SNAPSHOT".
    pub const tally_bonus_tick: u32 = 30;
    pub const tally_count_ticks: u32 = 36;
    pub const tally_life_tick: u32 = 90;
    /// CORE DUMPED: input waits this long, the title comes back after
    /// `game_over_idle_ticks` (a booth badge left alone goes back to attract).
    pub const game_over_min_ticks: u32 = 60;
    pub const game_over_idle_ticks: u32 = 20 * 60;
    /// Menu and HOW TO PLAY go back to the title after this long idle.
    pub const menu_idle_ticks: u32 = 30 * 60;
    /// Title: the attract round restarts this long after it ends.
    pub const attract_rest_ticks: u32 = 120;
    pub const blink_ticks: u32 = 32;
    /// Score (SPEC 6): a kill credited to you, a program crashing on its
    /// own, a level clear (times the ladder position), each snapshot left
    /// at the end.
    pub const kill_points: u32 = 500;
    pub const self_crash_points: u32 = 250;
    pub const clear_points: u32 = 1000;
    pub const snapshot_points: u32 = 2000;
    /// Autopilot 2's chance of a random move per decision (per mille).
    pub const sloppy_permille: u16 = 80;
    /// The `ai.preset` level the autopilot's brain uses (the strongest).
    pub const autopilot_preset: u8 = 3;
    /// SKIRMISH: round wins for the match; the round result card (A moves
    /// on after the minimum); holding A while you watch runs this many
    /// World ticks a frame (within `replay_units`).
    pub const match_wins: u8 = 3;
    pub const round_over_ticks: u32 = 200;
    pub const round_over_min_ticks: u32 = 40;
    pub const watch_fast_ticks: u32 = 4;
};

pub const colors = struct {
    pub const title_a = render.rgb(0x18E0FF);
    pub const title_b = render.rgb(0xFF7A10);
    pub const text = render.rgb(0xE0ECFF);
    pub const dim = render.rgb(0x5A6E90);
    pub const grey = render.rgb(0x3A4660);
    pub const win = render.rgb(0x60FFB0);
    pub const lose = render.rgb(0xFF4040);
    pub const warn = render.rgb(0xFFD040);
    pub const select = render.rgb(0xFFE870);
    pub const rewind = render.rgb(0x9CF0FF);
    /// Per cycle, for SKIRMISH's standings.
    pub const cycle = render.colors.trail;
};

/// A banner's default vertical centre.
const default_cy: u8 = (render.Banner{}).cy;

/// Cycle names on SKIRMISH's cards (by trail colour).
const cycle_names = [sim.max_cycles][]const u8{ "YOU", "ORANGE", "MAGENTA", "LIME" };

/// A program's Brain: `ai.preset` knobs (tier, level 0..3) and its own
/// rng stream.
fn brain(tier: ai.Tier, level: u8, seed: u32) ai.Brain {
    return .from(ai.preset(tier, level), seed);
}

pub const MenuItem = enum(u8) { ladder, skirmish, link, options, howto };
const menu_text = [5][]const u8{ "GRID LADDER", "SKIRMISH   ", "LINK DUEL  ", "OPTIONS    ", "HOW TO PLAY" };
const menu_items: u8 = menu_text.len;

pub const PauseItem = enum(u8) { resume_play, restart, quit };

/// OPTIONS rows (SPEC 6).
pub const OptionRow = enum(u8) { speed, trails, gaps, wrap, hardcore, back };
/// SKIRMISH setup rows.
pub const SetupRow = enum(u8) { programs, tier, arena, speed, start };

/// SKIRMISH: the setup and the match in progress.
pub const Skirmish = struct {
    programs: u8 = 1,
    /// 0..3: T0..T3, shown as BASIC / PASCAL / C / ASM.
    tier: u8 = 1,
    /// `layouts.zig` index (0 OPEN).
    layout: u8 = 0,
    row: SetupRow = .start,
    round: u32 = 0,
    wins: [sim.max_cycles]u8 = @splat(0),
    /// Achtung: +1 for each cycle a cycle outlives.
    points: [sim.max_cycles]u16 = @splat(0),
    /// The last round's winner (no_cycle: a draw).
    winner: u8 = sim.no_cycle,

    /// `debug_skirmish` and the `snouty_cycles_skirmish` poke: bits 0-1
    /// programs - 1, 2-3 tier, 4-7 layout.
    pub fn from_bits(b: u32) Skirmish {
        return .{
            .programs = @intCast(@min(b & 3, 2) + 1),
            .tier = @intCast((b >> 2) & 3),
            .layout = @intCast(((b >> 4) & 15) % layouts.count),
        };
    }

    fn n_cycles(s: *const Skirmish) u8 {
        return 1 + s.programs;
    }
    fn match_winner(s: *const Skirmish) ?u8 {
        for (s.wins, 0..) |w, i| {
            if (w >= tuning.match_wins) return @intCast(i);
        }
        return null;
    }
};

// ------------------------------------------------------------ LINK DUEL

/// LINK DUEL's input byte (one per lockstep tick, net.zig): `sim.Input`'s
/// low 5 bits (the press, A = boost, B = brake) and Start as the
/// lockstep's pause bit. Never 0xC0 or 0xDB (at most 0x3F).
pub const link_pause_bit: u8 = 0x20;
const link_input_mask: u8 = 0x1F;
/// The host's rules (the lobby's SETUP, GO's digest): arena, speed, the
/// modifier bits, and the match byte (first-to-N in bits 0-1, the host's
/// and the guest's round wins in bits 2-3 and 4-5: a NO CONTEST's new race
/// carries on from them).
pub const link_rules_len = 4;
pub const LinkRules = [link_rules_len]u8;

/// What net.zig reports of the lockstep (its `state()`).
pub const LinkStatus = enum(u8) { offline, searching, wrong_cart, lobby, racing, waiting, peer_left, desync };

/// The host's setup rows.
pub const LinkRow = enum(u8) { arena, speed, trails, gaps, wrap, hardcore, first_to, start };

pub const LinkNotice = enum(u8) { none, peer_left, no_contest };

/// LINK DUEL: what net.zig tells the game each frame, what the game asks of
/// it, the host's setup, and the match. The match fields change only in
/// `duel_tick` (agreed on both badges); `duel_hash` covers them.
pub const Link = struct {
    // From the lockstep (net.zig `begin`), every frame.
    status: LinkStatus = .offline,
    host: bool = false,
    partner_app: u8 = 0,
    /// This badge's input slot (0 host, 1 guest; the sim's cycle index).
    slot: u1 = 0,
    /// The lockstep's pause (a Start edge of either player, agreed).
    paused: bool = false,
    can_go: bool = false,
    /// Guest: the host's rules, once heard.
    heard: ?LinkRules = null,
    // To the lockstep (net.zig `end`).
    byte: u8 = 0,
    /// In the lobby screen, ready to start (the lobby's PICK).
    ready: bool = false,
    want_go: bool = false,
    want_leave: bool = false,
    // The host's setup.
    row: LinkRow = .start,
    layout: u8 = 0,
    opts: levels.Options = .{},
    first_to: u8 = 3,
    // The match (agreed).
    seed: u32 = 0,
    /// Rounds started in this race (round seeds), rounds of this match.
    serial: u32 = 0,
    round: u32 = 0,
    wins: [2]u8 = .{ 0, 0 },
    winner: u8 = sim.no_cycle,
    rematch: [2]bool = .{ false, false },
    prev_in: [2]u8 = .{ 0, 0 },
    /// The slot the T2 program rides since the partner left.
    ai_slot: ?u1 = null,
    brain: ai.Brain = undefined,
    // Local.
    /// A NO CONTEST happened: the next race carries the match on.
    resync: bool = false,
    notice: LinkNotice = .none,
    /// Pause menu: 0 RESUME, 1 LEAVE DUEL.
    pause_sel: u1 = 0,
    /// The last d-pad press, sent until a tick carries it back (a press
    /// on a stalled frame is not lost; pressing the planned heading again
    /// does nothing).
    press: sim.Press = .none,
    press_frames: u8 = 0,
    /// Simulator and badge-bench: a duel against the T2 program with no
    /// partner (the duel screens without a cable).
    demo: bool = false,
    /// Counters for tests and the hand-back: rounds decided, NO CONTESTs.
    rounds_done: u32 = 0,
    no_contests: u32 = 0,

    pub fn rules(lk: *const Link) LinkRules {
        const o = lk.opts;
        const mods: u8 = @as(u8, @intFromBool(o.snake)) | @as(u8, @intFromBool(o.gaps)) << 1 |
            @as(u8, @intFromBool(o.wrap)) << 2 | @as(u8, @intFromBool(o.hardcore)) << 3;
        const match: u8 = (lk.first_to & 3) | (lk.wins[0] & 3) << 2 | (lk.wins[1] & 3) << 4;
        return .{ lk.layout, @backingInt(o.speed), mods, match };
    }

    /// Takes the host's rules (both badges at the race start; the guest's
    /// lobby view).
    pub fn set_rules(lk: *Link, r: LinkRules) void {
        lk.layout = @min(r[0], layouts.count - 1);
        lk.opts = .{
            .speed = @fromBackingInt(@min(r[1], 2)),
            .snake = r[2] & 1 != 0,
            .gaps = r[2] & 2 != 0,
            .wrap = r[2] & 4 != 0,
            .hardcore = r[2] & 8 != 0,
        };
        lk.first_to = std.math.clamp(r[3] & 3, 1, 3);
        lk.wins = .{ (r[3] >> 2) & 3, (r[3] >> 4) & 3 };
    }

    fn match_winner(lk: *const Link) ?u1 {
        if (lk.wins[0] >= lk.first_to) return 0;
        if (lk.wins[1] >= lk.first_to) return 1;
        return null;
    }

    fn in_race(lk: *const Link) bool {
        return switch (lk.status) {
            .racing, .waiting, .peer_left => true,
            else => false,
        };
    }
};

/// LINK DUEL timing (frames for the local screens, ticks for the duel's).
pub const link_tuning = struct {
    /// PEER LEFT / NO CONTEST stay up this long (A goes on sooner).
    pub const notice_frames: u32 = 150;
    pub const notice_min_frames: u32 = 40;
    /// A press is re-sent this many frames at most.
    pub const press_frames: u8 = 8;
    /// The partner's program after it left: tier and preset.
    pub const ai_tier: ai.Tier = .territory;
    pub const ai_preset: u8 = 2;
};

/// The partner's cart by its link app id (WRONG CART).
fn cart_name(app: u8) []const u8 {
    return switch (app) {
        'B' => "SNOUTY BOY",
        'G' => "SNOUTY GC",
        'L' => "SNOUTY LINK",
        'Z' => "SNOUTY ZERO",
        'S' => "SNOUTENSTEIN",
        else => "ANOTHER CART",
    };
}

pub const Game = struct {
    state: State,
    mode: Mode,
    /// Ticks in the current state.
    timer: u32,
    /// Ticks since init.
    ticks: u32,
    /// Ladder position (1-based; 13 is BASIC on the second loop), 0 off
    /// the ladder.
    level: u32,
    /// Snapshots left (the HUD's pips); 0 in HARDCORE.
    snapshots: u8,
    score: u32,
    /// The score when this attempt at the level began (RESTART LEVEL).
    score_level_start: u32,
    /// Session high score (RAM only, SPEC 6) and whether this game set it.
    high: u32,
    new_high: bool,
    /// Worlds started this game (attempts), levels cleared, your derezzes,
    /// rewinds.
    rounds: u32,
    clears: u32,
    deaths: u32,
    rewinds: u32,
    menu_sel: MenuItem,
    pause_sel: PauseItem,
    option_row: OptionRow,
    /// The session's OPTIONS (RAM only).
    opts: levels.Options,
    sk: Skirmish,
    /// Your crash (the derez banner); .none with `timed_out`.
    crash: sim.Crash,
    timed_out: bool,
    /// The level clear: score before the bonus, and a snapshot won back.
    tally_from: u32,
    life_back: bool,
    /// The game ended by QUIT (EXIT 0), and the snapshot bonus it got.
    quit: bool,
    bonus: u32,
    /// World tick when the first sudden-death ring closed (0: not yet).
    sudden_death_tick: u32,
    /// Attract rounds played (picks the attract arena), and the World tick
    /// the current one ended on.
    attract_rounds: u32,
    attract_end: u32,
    /// 0: the player drives. 1: T1 drives the player (debug_autopilot,
    /// badge-bench). 2: T1 with `tuning.sloppy_permille` random moves.
    /// 3: T3 SEARCH (the ladder bot).
    autopilot: u8,
    /// Until this World tick the autopilot rides as T2 (after a rewind).
    autopilot_alt_until: u32,
    /// The countdown resumes a rewound round (2-1, no intro).
    resuming: bool,
    /// A heading pressed during that countdown, pressed on its first tick.
    resume_press: ?sim.Dir,
    /// Rewind: the World is being restored and replayed (else retracted),
    /// and the keyframe is back in.
    replaying: bool,
    restored: bool,
    /// The RUN banner's vertical centre (away from you after a rewind).
    run_cy: u8,
    /// Rewind: the banner's vertical centre (away from your crash).
    rewind_cy: u8,
    /// The World tick the last rewind of this round resumed on (0: none).
    last_resume: u32,
    /// Ticks undone per frame while retracting (3x; faster for a long
    /// way back, so the picture takes about the same time).
    retract_step: u32,
    /// Main skips drawing this frame (the replay runs on a World the
    /// screen must not follow).
    hold_frame: bool,
    /// The scanline tint over the arena: this many pixel rows from its top
    /// (main's pixel sink applies it; it wipes down as a rewind starts).
    tint_rows: u8,
    /// badge-bench and tools: derez the player when the World reaches
    /// this tick in play (once; 0 off).
    crash_at: u32,
    seeds: rng.Xorshift,
    brains: [sim.max_cycles]ai.Brain,
    /// Set when the screen must be repainted whole (new World, new scene);
    /// main.zig clears it after telling the renderer.
    repaint: bool,
    /// LINK DUEL (net.zig drives it).
    lk: Link,
    world: sim.World,
    history: history.History,

    /// In place: the Game holds a 38 KB World and the 46 KB History.
    pub fn init(g: *Game, seed: u32) void {
        g.seeds = .init(seed);
        g.autopilot = 0;
        g.high = 0;
        g.score = 0;
        g.attract_rounds = 0;
        g.opts = .{};
        g.sk = .{};
        g.option_row = .speed;
        g.crash_at = 0;
        g.lk = .{};
        g.to_title();
    }

    noinline fn to_title(g: *Game) void {
        g.state = .title;
        g.mode = .ladder;
        g.timer = 0;
        g.ticks = 0;
        g.level = 0;
        g.snapshots = 0;
        g.rounds = 0;
        g.clears = 0;
        g.deaths = 0;
        g.rewinds = 0;
        g.menu_sel = .ladder;
        g.crash = .none;
        g.timed_out = false;
        g.clear_round_flags();
        g.start_attract();
    }

    fn clear_round_flags(g: *Game) void {
        g.resuming = false;
        g.resume_press = null;
        g.replaying = false;
        g.restored = false;
        g.run_cy = default_cy;
        g.hold_frame = false;
        g.tint_rows = 0;
        g.last_resume = 0;
        g.autopilot_alt_until = 0;
        g.sudden_death_tick = 0;
    }

    noinline fn start_attract(g: *Game) void {
        const s = g.seeds.next();
        init_world(&g.world, .{
            .n_cycles = 4,
            .grinding = true,
            .energy = true,
            .rubber = sim.tuning.rubber_max,
            .sudden_death = true,
            .layout = @intCast(g.attract_rounds % (levels.layouts_used + 1)),
        }, s);
        g.attract_rounds += 1;
        // Four T2 programs at their strongest preset.
        for (&g.brains, 0..) |*b, i| b.* = brain(.territory, 3, rng.mix(s, @intCast(i)));
        g.sudden_death_tick = 0;
        g.repaint = true;
    }

    /// A new ladder game from position n (debug_set_level jumps here).
    pub noinline fn new_game(g: *Game, n: u32) void {
        g.mode = .ladder;
        g.level = @max(n, 1);
        g.snapshots = if (g.opts.hardcore) 0 else tuning.max_snapshots;
        g.score = 0;
        g.new_high = false;
        g.quit = false;
        g.bonus = 0;
        g.rounds = 0;
        g.clears = 0;
        g.deaths = 0;
        g.rewinds = 0;
        g.start_level(true);
    }

    fn autopilot_tier(g: *const Game) ai.Tier {
        if (g.world.tick < g.autopilot_alt_until) return tuning.alt_tier;
        return if (g.autopilot == 3) .search else .avoid;
    }

    /// A fresh World for the current level: the intro first, or straight
    /// to the countdown (a retry).
    noinline fn start_level(g: *Game, intro: bool) void {
        const r = levels.get(g.level);
        const s = g.seeds.next();
        g.clear_round_flags();
        init_world(&g.world, g.opts.apply(r.config()), s);
        g.level_brains(s);
        g.state = if (intro) .intro else .countdown;
        g.timer = 0;
        g.crash = .none;
        g.timed_out = false;
        g.score_level_start = g.score;
        g.rounds += 1;
        g.repaint = true;
        g.history.start(&g.world, &g.brains, g.aux());
    }

    /// What a keyframe keeps of the game: the score and the autopilot's
    /// tier deadline (its decisions spend the AI pool: a replay must make
    /// them again exactly).
    fn aux(g: *const Game) history.Aux {
        return .{ .score = g.score, .alt_until = g.autopilot_alt_until };
    }

    /// The level's Brains for a round seeded `s` (start_level, and the
    /// exact restart of the round on a rewind to its start).
    fn level_brains(g: *Game, s: u32) void {
        g.brains[0] = brain(g.autopilot_tier(), tuning.autopilot_preset, rng.mix(s, 0));
        for (g.round().programs(), 1..) |p, i| g.brains[i] = brain(p.tier, p.preset, rng.mix(s, @intCast(i)));
    }

    /// The round exactly as it started: same seed, same Brains, the
    /// level's starting score (a rewind to tick 0 once its keyframe is gone).
    fn restart_round(g: *Game) void {
        const cfg = g.world.cfg;
        const s = g.world.seed;
        init_world(&g.world, cfg, s);
        g.level_brains(s);
        g.score = g.score_level_start;
        g.sudden_death_tick = 0;
        g.history.start(&g.world, &g.brains, g.aux());
        ai.reset_pool();
    }

    pub fn round(g: *const Game) levels.Round {
        return levels.get(g.level);
    }

    /// A new SKIRMISH match with the setup in `g.sk`.
    pub noinline fn new_match(g: *Game) void {
        g.mode = .skirmish;
        g.level = 0;
        g.snapshots = 0;
        g.score = 0;
        g.rounds = 0;
        g.clears = 0;
        g.deaths = 0;
        g.rewinds = 0;
        g.sk.round = 0;
        g.sk.wins = @splat(0);
        g.sk.points = @splat(0);
        g.sk.winner = sim.no_cycle;
        g.start_skirmish_round();
    }

    noinline fn start_skirmish_round(g: *Game) void {
        const s = g.seeds.next();
        g.clear_round_flags();
        init_world(&g.world, levels.skirmish_config(g.sk.programs, g.sk.layout, g.opts), s);
        g.brains[0] = brain(g.autopilot_tier(), tuning.autopilot_preset, rng.mix(s, 0));
        const tier = levels.skirmish_tiers[g.sk.tier];
        for (1..g.sk.n_cycles()) |i| g.brains[i] = brain(tier, levels.skirmish_preset, rng.mix(s, @intCast(i)));
        g.sk.round += 1;
        g.rounds += 1;
        g.state = .intro;
        g.timer = 0;
        g.crash = .none;
        g.timed_out = false;
        g.repaint = true;
    }

    pub fn update(g: *Game, held: Buttons, pressed_raw: Buttons) void {
        // Newer firmware opens its settings box on Start+Select over the
        // running cart: react to neither while both are held.
        var pressed = pressed_raw;
        if (held.start and held.select) {
            pressed.start = false;
            pressed.select = false;
        }
        g.hold_frame = false;
        if (g.mode == .link) return g.update_link(held, pressed);
        g.ticks +%= 1;
        g.timer += 1;
        switch (g.state) {
            .title => {
                if (pressed.any()) return g.goto(.menu);
                g.run_attract();
            },
            .menu => {
                g.run_attract();
                g.update_menu(pressed);
            },
            .howto => {
                g.run_attract();
                if (pressed.any()) return g.goto(.menu);
                if (g.timer >= tuning.menu_idle_ticks) g.to_title();
            },
            .options => {
                g.run_attract();
                g.update_options(pressed);
            },
            .skirmish_setup => {
                g.run_attract();
                g.update_setup(pressed);
            },
            .intro => {
                if (dpad(pressed)) |d| g.world.set_heading(0, d);
                if (g.timer >= tuning.intro_ticks or (pressed.a and g.timer >= tuning.skip_ticks)) g.goto(.countdown);
            },
            .countdown => {
                if (dpad(pressed)) |d| {
                    // At the round's start the press sets the heading; on
                    // a rewound round it is pressed on the first tick.
                    if (g.world.tick == 0) g.world.set_heading(0, d) else g.resume_press = d;
                }
                const len = if (g.resuming) tuning.resume_ticks else tuning.countdown_ticks;
                if (g.timer >= len) {
                    g.run_cy = if (g.resuming) g.away_from_player() else default_cy;
                    g.resuming = false;
                    g.goto(.play);
                }
            },
            .play => {
                if (pressed.start) {
                    g.pause_sel = .resume_play;
                    return g.goto(.paused);
                }
                g.play_tick(held, pressed);
            },
            .derez => g.update_derez(held),
            .frozen => {
                if (g.timer >= tuning.freeze_ticks) g.begin_rewind();
            },
            .rewind => g.update_rewind(),
            .clear => {
                g.world.step(@splat(.idle));
                if (g.timer >= tuning.clear_ticks or (pressed.a and g.timer >= tuning.clear_min_ticks)) {
                    g.level += 1;
                    g.start_level(true);
                }
            },
            .round_over => {
                g.world.step(@splat(.idle));
                if (g.timer >= tuning.round_over_ticks or (pressed.a and g.timer >= tuning.round_over_min_ticks)) {
                    if (g.sk.match_winner() != null) return g.goto(.match_over);
                    g.start_skirmish_round();
                }
            },
            .match_over => {
                g.world.step(@splat(.idle));
                if (g.timer >= tuning.game_over_min_ticks) {
                    if (pressed.a) return g.new_match();
                    if (pressed.b or pressed.start or pressed.select) return g.to_menu(.skirmish);
                }
                if (g.timer >= tuning.game_over_idle_ticks) g.to_title();
            },
            .game_over => {
                g.world.step(@splat(.idle));
                if (g.timer >= tuning.game_over_min_ticks) {
                    if (pressed.a) return g.new_game(1);
                    if (pressed.b or pressed.start or pressed.select) return g.to_title();
                }
                if (g.timer >= tuning.game_over_idle_ticks) g.to_title();
            },
            .paused => g.update_pause(pressed),
            // Only in LINK DUEL (update_link).
            .link_lobby, .link_notice => {},
        }
    }

    fn goto(g: *Game, s: State) void {
        g.state = s;
        g.timer = 0;
    }

    /// Back to the menu over a fresh attract round, on item `sel`.
    noinline fn to_menu(g: *Game, sel: MenuItem) void {
        g.to_title();
        g.menu_sel = sel;
        g.goto(.menu);
    }

    noinline fn update_menu(g: *Game, p: Buttons) void {
        if (p.up or p.down) {
            const i: u8 = @backingInt(g.menu_sel);
            g.menu_sel = @fromBackingInt(if (p.down) (i + 1) % menu_items else (i + menu_items - 1) % menu_items);
            g.timer = 0;
        }
        if (p.a or p.start) {
            switch (g.menu_sel) {
                .ladder => g.new_game(1),
                .skirmish => {
                    g.sk.row = .start;
                    g.goto(.skirmish_setup);
                },
                .link => g.enter_link(),
                .options => {
                    g.option_row = .speed;
                    g.goto(.options);
                },
                .howto => g.goto(.howto),
            }
            return;
        }
        if (p.b or p.select) return g.goto(.title);
        if (g.timer >= tuning.menu_idle_ticks) g.to_title();
    }

    /// OPTIONS: Up/Down pick a row, Left/Right or A change it; BACK, B or
    /// Select return to the menu.
    noinline fn update_options(g: *Game, p: Buttons) void {
        const n: u8 = @typeInfo(OptionRow).@"enum".field_names.len;
        if (p.up or p.down) {
            const i: u8 = @backingInt(g.option_row);
            g.option_row = @fromBackingInt(if (p.down) (i + 1) % n else (i + n - 1) % n);
            g.timer = 0;
        }
        const change = p.left or p.right or p.a;
        if (change) {
            g.timer = 0;
            const o = &g.opts;
            switch (g.option_row) {
                .speed => o.speed = cycle_speed(o.speed, p.left),
                .trails => o.snake = !o.snake,
                .gaps => o.gaps = !o.gaps,
                .wrap => o.wrap = !o.wrap,
                .hardcore => o.hardcore = !o.hardcore,
                .back => if (p.a) return g.goto(.menu),
            }
        }
        if (p.b or p.select or p.start) return g.goto(.menu);
        if (g.timer >= tuning.menu_idle_ticks) g.to_title();
    }

    /// SKIRMISH setup: Up/Down pick a row, Left/Right (or A) change it, A
    /// on START (or Start anywhere) begins; B or Select go back.
    noinline fn update_setup(g: *Game, p: Buttons) void {
        const n: u8 = @typeInfo(SetupRow).@"enum".field_names.len;
        const s = &g.sk;
        if (p.up or p.down) {
            const i: u8 = @backingInt(s.row);
            s.row = @fromBackingInt(if (p.down) (i + 1) % n else (i + n - 1) % n);
            g.timer = 0;
        }
        if (p.start or (p.a and s.row == .start)) return g.new_match();
        if (p.left or p.right or p.a) {
            g.timer = 0;
            const back = p.left;
            switch (s.row) {
                .programs => s.programs = step_in(s.programs, 1, 3, back),
                .tier => s.tier = step_in(s.tier, 0, 3, back),
                .arena => s.layout = step_in(s.layout, 0, layouts.count - 1, back),
                .speed => g.opts.speed = cycle_speed(g.opts.speed, back),
                .start => {},
            }
        }
        if (p.b or p.select) return g.goto(.menu);
        if (g.timer >= tuning.menu_idle_ticks) g.to_title();
    }

    noinline fn update_pause(g: *Game, p: Buttons) void {
        if (p.up or p.down) {
            const i: u8 = @backingInt(g.pause_sel);
            g.pause_sel = @fromBackingInt(if (p.down) (i + 1) % 3 else (i + 2) % 3);
        }
        if (p.start or p.b) return g.resume_play();
        if (p.a) switch (g.pause_sel) {
            .resume_play => g.resume_play(),
            .restart => switch (g.mode) {
                .ladder => {
                    g.score = g.score_level_start;
                    g.start_level(false);
                },
                .skirmish, .link => g.new_match(),
            },
            .quit => switch (g.mode) {
                .ladder => g.end_game(true),
                .skirmish, .link => g.to_menu(.skirmish),
            },
        };
    }

    fn resume_play(g: *Game) void {
        g.state = .play;
        // No RUN banner again.
        g.timer = tuning.run_banner_ticks;
    }

    /// The attract round: four programs, restarted after each ends.
    fn run_attract(g: *Game) void {
        const w = &g.world;
        if (w.result == .running) {
            var in: [sim.max_cycles]sim.Input = @splat(.idle);
            for (0..w.cfg.n_cycles) |i| in[i] = ai.decide(&g.brains[i], w, i);
            w.step(in);
            if (w.result != .running) g.attract_end = w.tick;
        } else {
            w.step(@splat(.idle));
            if (w.tick - g.attract_end >= tuning.attract_rest_ticks) g.start_attract();
        }
    }

    /// One World tick with the player (you, the autopilot, or the input a
    /// replay logged; `player` false once you have derezzed) and the
    /// programs. Returns the player's input (the history logs it).
    ///
    /// The autopilot decides first and spends the AI's shared per-tick
    /// pool before the programs (M1's order, which the ladder bot was
    /// tuned with), so on a replay it decides again, from its keyframed
    /// Brain and `autopilot_alt_until`, to leave the programs the same
    /// pool; its answer equals the logged input. A human player never
    /// touches the pool, so a replay of yours runs the programs alone.
    fn step_world(g: *Game, held: Buttons, pressed: Buttons, player: bool, logged: ?sim.Input) sim.Input {
        const w = &g.world;
        var in: [sim.max_cycles]sim.Input = @splat(.idle);
        if (player and w.cycles[0].state == .alive) {
            if (g.autopilot != 0) {
                const b = &g.brains[0];
                const tier = g.autopilot_tier();
                if (b.tier != tier) b.* = brain(tier, tuning.autopilot_preset, b.rng.state);
                if (g.autopilot == 2) b.mistake_permille = tuning.sloppy_permille;
                if (w.tick < g.autopilot_alt_until) b.mistake_permille = tuning.alt_slip_permille;
                in[0] = ai.decide(b, w, 0);
            } else if (logged == null) {
                if (dpad(pressed)) |d| {
                    in[0].press = .of(d);
                } else if (g.resume_press) |d| {
                    in[0].press = .of(d);
                }
                g.resume_press = null;
                in[0].boost = held.a;
                in[0].brake = held.b;
            }
            if (logged) |l| in[0] = l;
        }
        for (1..w.cfg.n_cycles) |i| in[i] = ai.decide(&g.brains[i], w, i);
        w.step(in);
        if (g.sudden_death_tick == 0 and w.sudden_death_ring != 0) g.sudden_death_tick = w.tick;
        return in[0];
    }

    /// A play tick: the step, its points, the history, then the end of
    /// the round either way.
    fn play_tick(g: *Game, held: Buttons, pressed: Buttons) void {
        const in0 = g.step_world(held, pressed, true, null);
        g.score_step();
        if (g.mode == .ladder) g.history.record(&g.world, in0, &g.brains, g.aux());
        const w = &g.world;
        if (g.crash_at != 0 and w.tick >= g.crash_at and g.mode == .ladder and w.cycles[0].state == .alive) {
            g.crash_at = 0;
            return g.player_crashed(.segfault);
        }
        if (w.cycles[0].state != .alive) return g.player_crashed(w.cycles[0].crash);
        switch (g.mode) {
            .ladder => {
                if (w.result == .won and w.winner == 0) return g.level_clear();
                if (w.result == .draw) {
                    // The clock ran out with you riding (no sudden death):
                    // the level again, nothing lost.
                    g.crash = .none;
                    g.timed_out = true;
                    return g.goto(.derez);
                }
            },
            .skirmish, .link => if (w.result != .running) g.round_end(),
        }
    }

    /// Derezzes the player now (debug_force_crash, the bench's crash_at):
    /// as a crash in play, though the World's cycle rides on.
    pub fn force_crash(g: *Game) void {
        if (g.state != .play or g.mode != .ladder) return;
        g.player_crashed(.segfault);
    }

    fn player_crashed(g: *Game, kind: sim.Crash) void {
        g.crash = kind;
        g.timed_out = false;
        g.deaths += 1;
        if (g.mode == .ladder and g.snapshots > 0) return g.goto(.frozen);
        g.goto(.derez);
    }

    /// Your derez with no snapshot (ladder: the banner, then CORE
    /// DUMPED or, after a time-out, the level again) or SKIRMISH's
    /// watching (the programs finish the round; hold A to speed it up).
    noinline fn update_derez(g: *Game, held: Buttons) void {
        switch (g.mode) {
            .ladder => {
                g.world.step(@splat(.idle));
                if (g.timer < tuning.derez_ticks) return;
                if (g.timed_out) return g.start_level(false);
                g.end_game(false);
            },
            .skirmish, .link => {
                const w = &g.world;
                if (w.result != .running) {
                    // Decided: the fades go on under the banner a moment.
                    w.step(@splat(.idle));
                    if (g.timer >= tuning.derez_ticks) g.round_end();
                    return;
                }
                const fast = held.a and g.timer >= tuning.derez_ticks;
                const units0 = ai_units();
                var n: u32 = 0;
                while (w.result == .running) {
                    _ = g.step_world(.{}, .{}, false, null);
                    g.score_step();
                    n += 1;
                    if (!fast or n >= tuning.watch_fast_ticks or ai_units() - units0 + pool_units > tuning.replay_units) break;
                }
            },
        }
    }

    /// Where this rewind lands (sets `history.target`): 2 s back (SPEC 6;
    /// the oldest kept keyframe if a recent rewind dropped the ones
    /// before). A crash soon after the last resume (`escalate_window`)
    /// means that landing was a lost cause: this one lands
    /// `escalate_ticks` before it, or, once the keyframes do not reach
    /// that far, at the round's start.
    fn plan_rewind(g: *Game) void {
        const h = &g.history;
        const now = g.world.tick;
        if (g.last_resume != 0 and now < g.last_resume + tuning.escalate_window) {
            if (h.plan_exact(g.last_resume -| tuning.escalate_ticks) == null) h.plan_start();
            return;
        }
        if (h.plan(now, history.tuning.rewind_ticks) == null) h.plan_start();
    }

    /// Time stood still long enough: start running backwards.
    noinline fn begin_rewind(g: *Game) void {
        g.plan_rewind();
        // The retraction shows at most the ticks the history kept.
        const span = @min(g.world.tick - g.history.target, history.tuning.ticks - 1);
        g.retract_step = @max(history.tuning.retract_per_frame, (span + tuning.retract_frames - 1) / tuning.retract_frames);
        g.snapshots -= 1;
        g.rewinds += 1;
        g.replaying = false;
        g.tint_rows = 0;
        const me = &g.world.cycles[0];
        g.rewind_cy = if (me.y < sim.grid_h / 2) 100 else 30;
        g.goto(.rewind);
        // The first ticks go back on this frame (you ride again at once).
        g.update_rewind();
    }

    noinline fn update_rewind(g: *Game) void {
        const w = &g.world;
        if (!g.replaying) {
            g.tint_rows = @min(render.screen_h - render.arena_y, g.tint_rows + tuning.wipe_rows);
            const r = g.history.retract(w, g.retract_step);
            if (r.done) {
                g.replaying = true;
                g.restored = false;
            }
            return;
        }
        // The exact part, off screen: the keyframe, then the logged inputs
        // to the target, as many ticks a frame as the AI budget allows.
        g.hold_frame = true;
        if (!g.restored) {
            var kept: history.Aux = undefined;
            if (g.history.restore(w, &g.brains, &kept)) |_| {
                g.score = kept.score;
                g.autopilot_alt_until = kept.alt_until;
            } else {
                g.restart_round();
            }
            g.restored = true;
            if (g.sudden_death_tick > w.tick) g.sudden_death_tick = 0;
        }
        const units0 = ai_units();
        var n: u32 = 0;
        while (w.tick < g.history.target and n < tuning.replay_max_ticks) : (n += 1) {
            const in0 = g.step_world(.{}, .{}, true, g.history.input_at(w.tick + 1));
            g.score_step();
            g.history.record(w, in0, &g.brains, g.aux());
            if (ai_units() - units0 + pool_units > tuning.replay_units) break;
        }
        if (w.tick < g.history.target) return;
        g.finish_rewind();
    }

    noinline fn finish_rewind(g: *Game) void {
        g.replaying = false;
        g.restored = false;
        g.tint_rows = 0;
        g.repaint = true;
        g.resuming = true;
        // Tick 0 is a landing too (0 means none).
        g.last_resume = @max(g.world.tick, 1);
        g.resume_press = null;
        if (g.autopilot != 0) {
            // The autopilot would ride into the same crash: another tier
            // for a while and a new stream for its slips (and the landing's
            // keyframe must know, for a replay from it).
            g.autopilot_alt_until = g.world.tick + tuning.autopilot_alt_ticks;
            g.brains[0] = brain(g.autopilot_tier(), tuning.autopilot_preset, rng.mix(g.brains[0].rng.state, g.rewinds));
            g.history.resave(&g.world, &g.brains, g.aux());
        }
        g.goto(.countdown);
    }

    /// The game ends: CORE DUMPED, or EXIT 0 after QUIT. Each snapshot
    /// left is worth `tuning.snapshot_points` (SPEC 6).
    noinline fn end_game(g: *Game, quit: bool) void {
        g.quit = quit;
        g.bonus = @as(u32, g.snapshots) * tuning.snapshot_points;
        g.score += g.bonus;
        g.new_high = g.score > g.high;
        g.high = @max(g.high, g.score);
        g.clear_round_flags();
        g.goto(.game_over);
    }

    noinline fn level_clear(g: *Game) void {
        g.tally_from = g.score;
        g.score += tuning.clear_points * g.level;
        g.clears += 1;
        g.life_back = !g.opts.hardcore and g.snapshots < tuning.max_snapshots;
        if (g.life_back) g.snapshots += 1;
        g.goto(.clear);
    }

    /// SKIRMISH: the round is decided.
    noinline fn round_end(g: *Game) void {
        const w = &g.world;
        g.sk.winner = if (w.result == .won) w.winner else sim.no_cycle;
        if (g.sk.winner != sim.no_cycle) g.sk.wins[g.sk.winner] += 1;
        if (g.sk.winner == 0) g.clears += 1;
        g.goto(.round_over);
    }

    /// Points for this step's crashes as they happen. Ladder (SPEC 6):
    /// your kills and programs crashing on their own. SKIRMISH (Achtung):
    /// every cycle still riding gets +1 per cycle that crashed.
    fn score_step(g: *Game) void {
        const w = &g.world;
        for (w.events[0..w.n_events]) |e| {
            if (e.kind != .crash) continue;
            switch (g.mode) {
                .ladder => {
                    if (e.cycle == 0) continue;
                    const kind: sim.Crash = @fromBackingInt(@intCast(e.a));
                    if (e.b == 0) {
                        g.score += tuning.kill_points;
                    } else if (kind != .race_condition and kind != .deadlock) {
                        g.score += tuning.self_crash_points;
                    }
                },
                .skirmish, .link => {
                    for (w.cycles, 0..) |c, i| {
                        if (c.state == .alive) g.sk.points[i] += 1;
                    }
                },
            }
        }
        if (g.mode == .skirmish) g.score = g.sk.points[0];
    }

    // ------------------------------------------------------------ LINK DUEL

    /// LINK DUEL from the menu: the cable screen, then the lobby (net.zig
    /// reports the link in `lk.status` every frame).
    pub noinline fn enter_link(g: *Game) void {
        g.mode = .link;
        g.lk.resync = false;
        g.lk.notice = .none;
        g.lk.demo = false;
        g.lk.ai_slot = null;
        g.lk.row = .start;
        g.goto(.link_lobby);
    }

    /// The duel is on: the lockstep steps it (`duel_tick`) and gets this
    /// badge's byte every frame.
    pub fn duel_running(g: *const Game) bool {
        if (g.mode != .link) return false;
        return switch (g.state) {
            .countdown, .play, .round_over, .match_over => true,
            else => false,
        };
    }

    /// A frame in LINK DUEL. Nothing here changes the duel's agreed state:
    /// only `duel_tick` does (the lockstep calls it with both bytes).
    noinline fn update_link(g: *Game, held: Buttons, p: Buttons) void {
        const lk = &g.lk;
        g.ticks +%= 1;
        lk.byte = 0;
        switch (g.state) {
            .link_lobby => {
                g.timer += 1;
                g.run_attract();
                g.update_lobby(p);
            },
            .link_notice => {
                g.timer += 1;
                if (lk.notice == .no_contest) g.world.step(@splat(.idle));
                if (g.timer >= link_tuning.notice_frames or (p.a and g.timer >= link_tuning.notice_min_frames)) {
                    // Out of the race now (after a desync the lockstep
                    // kept telling the partner while the notice was up).
                    lk.want_leave = true;
                    // NO CONTEST: the next race carries the match on, if
                    // the partner is still there.
                    const there = switch (lk.status) {
                        .lobby, .desync, .racing, .waiting => true,
                        else => false,
                    };
                    if (lk.notice == .no_contest and there) {
                        lk.resync = true;
                        lk.notice = .none;
                        g.start_attract();
                        return g.goto(.link_lobby);
                    }
                    return g.to_menu(.link);
                }
            },
            else => g.update_duel_frame(held, p),
        }
    }

    /// The lobby: the host's rows (Up/Down, Left/Right or A; START or the
    /// Start button begins), the guest's view; B or Select back to the menu.
    noinline fn update_lobby(g: *Game, p: Buttons) void {
        const lk = &g.lk;
        lk.ready = lk.status == .lobby;
        // A new partner (or none) starts a new match.
        if (lk.status == .searching or lk.status == .wrong_cart) lk.resync = false;
        if (p.b or p.select) return g.to_menu(.link);
        if (lk.status != .lobby or !lk.host) return;
        if (lk.resync) {
            // A NO CONTEST: the next round as soon as the guest is back.
            if (lk.can_go) lk.want_go = true;
            return;
        }
        const n: u8 = @typeInfo(LinkRow).@"enum".field_names.len;
        if (p.up or p.down) {
            const i: u8 = @backingInt(lk.row);
            lk.row = @fromBackingInt(if (p.down) (i + 1) % n else (i + n - 1) % n);
        }
        if (p.start or (p.a and lk.row == .start)) {
            if (lk.can_go) {
                lk.wins = .{ 0, 0 };
                lk.want_go = true;
            }
            return;
        }
        if (p.left or p.right or p.a) {
            const back = p.left;
            const o = &lk.opts;
            switch (lk.row) {
                .arena => lk.layout = step_in(lk.layout, 0, layouts.count - 1, back),
                .speed => o.speed = cycle_speed(o.speed, back),
                .trails => o.snake = !o.snake,
                .gaps => o.gaps = !o.gaps,
                .wrap => o.wrap = !o.wrap,
                .hardcore => o.hardcore = !o.hardcore,
                .first_to => lk.first_to = step_in(lk.first_to, 1, 3, back),
                .start => {},
            }
        }
    }

    /// A duel frame: leave on a desync or a gone partner, the pause menu,
    /// the match card's B, else this frame's byte.
    noinline fn update_duel_frame(g: *Game, held: Buttons, p: Buttons) void {
        const lk = &g.lk;
        if (!lk.demo) {
            switch (lk.status) {
                .desync => return g.link_notice(.no_contest),
                // Gone in mid-round: the program rides its cycle to the
                // round's end (duel_tick ends it there); else at once.
                .peer_left => if (g.state == .match_over) return g.link_notice(.peer_left),
                .racing, .waiting => {},
                // The race is gone without a word (it should not be).
                else => return g.link_notice(.peer_left),
            }
        }
        if (lk.paused) {
            if (p.up or p.down) lk.pause_sel ^= 1;
            if (p.a and lk.pause_sel == 1) {
                lk.want_leave = true;
                return g.to_menu(.link);
            }
            // RESUME: a Start edge of ours (agreed when its tick runs).
            if (p.start or p.b or p.a) lk.byte = link_pause_bit;
            return;
        }
        if (g.state == .match_over and g.timer >= tuning.game_over_min_ticks and (p.b or p.select)) {
            lk.want_leave = true;
            return g.to_menu(.link);
        }
        if (dpad(p)) |d| {
            lk.press = .of(d);
            lk.press_frames = link_tuning.press_frames;
        }
        var in: sim.Input = .{ .boost = held.a, .brake = held.b };
        if (lk.press_frames > 0) {
            lk.press_frames -= 1;
            in.press = lk.press;
        }
        if (g.autopilot != 0 and g.state == .play and g.world.cycles[lk.slot].state == .alive) {
            in = ai.decide(&g.brains[0], &g.world, lk.slot);
        }
        lk.byte = @as(u8, @bitCast(in)) & link_input_mask;
        if (p.start) {
            lk.pause_sel = 0;
            lk.byte |= link_pause_bit;
        }
        if (lk.demo) g.duel_tick(if (lk.slot == 0) .{ lk.byte, 0 } else .{ 0, lk.byte });
    }

    noinline fn link_notice(g: *Game, kind: LinkNotice) void {
        const lk = &g.lk;
        lk.notice = kind;
        // A desync stays in the lockstep while the notice is up, so the
        // partner hears DESYNC (not a QUIT that would read as PEER LEFT).
        lk.want_leave = kind == .peer_left;
        lk.ai_slot = null;
        lk.press_frames = 0;
        if (kind == .no_contest) lk.no_contests += 1;
        g.goto(.link_notice);
    }

    /// The race starts (both badges, net.zig on `take_started`): the
    /// agreed seed and rules, this badge's slot.
    pub noinline fn duel_begin(g: *Game, seed: u32, r: LinkRules, slot: u1) void {
        const lk = &g.lk;
        lk.seed = seed;
        lk.slot = slot;
        lk.set_rules(r);
        lk.serial = 0;
        if (!lk.resync) lk.round = 0;
        lk.resync = false;
        lk.ai_slot = null;
        lk.prev_in = .{ 0, 0 };
        lk.rematch = .{ false, false };
        lk.notice = .none;
        lk.press_frames = 0;
        g.mode = .link;
        g.brains[0] = brain(.search, tuning.autopilot_preset, rng.mix(seed, 0xB07));
        g.duel_next_round();
    }

    /// A demo duel with no partner (simulator previews, badge-bench): you
    /// against the T2 program in slot 1, from the setup in `lk`.
    pub noinline fn duel_demo(g: *Game, seed: u32) void {
        g.enter_link();
        g.lk.status = .racing;
        g.duel_begin(seed, g.lk.rules(), 0);
        g.lk.demo = true;
        g.duel_hand_over(1);
    }

    fn duel_next_round(g: *Game) void {
        const lk = &g.lk;
        lk.serial += 1;
        lk.round += 1;
        lk.winner = sim.no_cycle;
        g.clear_round_flags();
        init_world(&g.world, levels.skirmish_config(1, lk.layout, lk.opts), rng.mix(lk.seed, lk.serial));
        g.state = .countdown;
        g.timer = 0;
        g.repaint = true;
    }

    /// One agreed tick of the duel (lockstep `simulate`): `in[s]` is slot
    /// s's byte. The only place the duel's state changes, so both badges'
    /// Games stay equal (`duel_hash`).
    pub fn duel_tick(g: *Game, in: [2]u8) void {
        const lk = &g.lk;
        var ins: [sim.max_cycles]sim.Input = @splat(.idle);
        ins[0] = @bitCast(in[0] & link_input_mask);
        ins[1] = @bitCast(in[1] & link_input_mask);
        const a_bit: u8 = 0x08;
        const a_edge = [2]bool{ in[0] & ~lk.prev_in[0] & a_bit != 0, in[1] & ~lk.prev_in[1] & a_bit != 0 };
        lk.prev_in = in;
        // Our press is in: stop re-sending it.
        if (ins[lk.slot].press == lk.press) lk.press_frames = 0;
        const w = &g.world;
        switch (g.state) {
            .countdown => {
                for (0..2) |s| {
                    if (ins[s].press.dir()) |d| w.set_heading(s, d);
                }
                g.timer += 1;
                if (g.timer >= tuning.countdown_ticks) g.goto(.play);
            },
            .play => {
                if (lk.ai_slot) |s| ins[s] = ai.decide(&lk.brain, w, s);
                w.step(ins);
                g.timer += 1;
                if (g.sudden_death_tick == 0 and w.sudden_death_ring != 0) g.sudden_death_tick = w.tick;
                if (w.result != .running) {
                    lk.winner = if (w.result == .won) w.winner else sim.no_cycle;
                    if (lk.winner < 2) lk.wins[lk.winner] += 1;
                    lk.rounds_done += 1;
                    g.goto(.round_over);
                }
            },
            .round_over => {
                w.step(@splat(.idle));
                g.timer += 1;
                if (g.timer >= tuning.round_over_ticks) {
                    if (lk.ai_slot != null and !lk.demo) return g.link_notice(.peer_left);
                    if (lk.match_winner() != null) {
                        lk.rematch = .{ false, false };
                        return g.goto(.match_over);
                    }
                    g.duel_next_round();
                }
            },
            .match_over => {
                w.step(@splat(.idle));
                g.timer += 1;
                if (g.timer >= tuning.game_over_min_ticks) {
                    for (0..2) |s| {
                        if (a_edge[s]) lk.rematch[s] = true;
                    }
                    // The demo's program always wants another (and the
                    // demo rides on by itself after a while).
                    if (lk.demo) {
                        lk.rematch[lk.slot ^ 1] = true;
                        if (g.timer >= 2 * tuning.game_over_min_ticks) lk.rematch[lk.slot] = true;
                    }
                }
                if (lk.rematch[0] and lk.rematch[1]) {
                    lk.wins = .{ 0, 0 };
                    lk.round = 0;
                    g.duel_next_round();
                }
            },
            else => {},
        }
    }

    /// The lockstep's desync check: the World and the duel's agreed state.
    pub fn duel_hash(g: *const Game) u32 {
        const lk = &g.lk;
        var h = g.world.hash();
        h = rng.mix(h, @as(u32, @backingInt(g.state)) << 24 | g.timer);
        h = rng.mix(h, lk.serial << 16 | @as(u32, lk.wins[0]) << 8 | lk.wins[1]);
        return rng.mix(h, @as(u32, @intFromBool(lk.rematch[0])) | @as(u32, @intFromBool(lk.rematch[1])) << 1);
    }

    /// The partner left (lockstep `hand_over`): a T2 program rides its
    /// cycle to the round's end.
    pub fn duel_hand_over(g: *Game, slot: u1) void {
        const lk = &g.lk;
        lk.ai_slot = slot;
        lk.brain = brain(link_tuning.ai_tier, link_tuning.ai_preset, rng.mix(lk.seed, 0x7E2));
    }

    // ------------------------------------------------------------ LINK DUEL view

    /// LINK DUEL's screens. Your cycle (the sim's slot `lk.slot`) is drawn
    /// in the player's colour and the partner's in orange on both badges
    /// (`View.swap` on the guest).
    noinline fn link_view(g: *const Game) render.View {
        const lk = &g.lk;
        var v: render.View = .{};
        const blink_on = (g.ticks / tuning.blink_ticks) % 2 == 0;
        switch (g.state) {
            .link_lobby => {
                v.hud.left = .of("LINK DUEL", 1, colors.dim);
                if (lk.status == .lobby) v.hud.right = .of(if (lk.host) "HOST" else "GUEST", 1, colors.dim);
                v.banner = g.lobby_banner(blink_on);
                return v;
            },
            .link_notice => {
                v.swap = lk.slot == 1;
                g.link_hud(&v);
                var b: render.Banner = .{};
                if (lk.notice == .no_contest) {
                    add_line(&b, "NO", 2, colors.warn);
                    add_line(&b, "CONTEST", 2, colors.warn);
                    add_line(&b, "BADGES DISAGREE", 1, colors.text);
                    add_line(&b, "NEXT ROUND", 1, colors.dim);
                    add_line(&b, "WITH A NEW SEED", 1, colors.dim);
                } else {
                    add_line(&b, "PEER LEFT", 2, colors.lose);
                    add_line(&b, "BACK TO THE MENU", 1, colors.text);
                }
                v.banner = b;
                return v;
            },
            else => {},
        }
        v.swap = lk.slot == 1;
        g.link_hud(&v);
        switch (g.state) {
            .countdown => {
                var b: render.Banner = .{};
                const n = 3 - @min(2, g.timer / tuning.count_step_ticks);
                const digit = [1]u8{'0' + @as(u8, @intCast(n))};
                add_line(&b, &digit, 3, colors.warn);
                var buf: [20]u8 = undefined;
                var k = copy(&buf, "ROUND ");
                k += decimal(buf[k..], lk.round, 1);
                add_line(&b, buf[0..k], 1, colors.text);
                v.banner = b;
            },
            .play => {
                if (g.timer < tuning.run_banner_ticks) {
                    var b: render.Banner = .{};
                    add_line(&b, "RUN", 2, colors.win);
                    v.banner = b;
                } else if (g.sudden_death_tick != 0 and g.world.tick - g.sudden_death_tick < tuning.sudden_death_banner_ticks) {
                    var b: render.Banner = .{ .cy = 40 };
                    const on = (g.world.tick / 8) % 2 == 0;
                    add_line(&b, "SUDDEN", 2, if (on) colors.lose else colors.warn);
                    add_line(&b, "DEATH", 2, if (on) colors.lose else colors.warn);
                    v.banner = b;
                } else if (lk.ai_slot != null and !lk.demo) {
                    var b: render.Banner = .{ .cy = 18 };
                    add_line(&b, "PEER LEFT AI RIDES", 1, colors.warn);
                    v.banner = b;
                }
            },
            .round_over, .match_over => v.banner = g.duel_card(g.state == .match_over, blink_on),
            else => {},
        }
        if (lk.paused) {
            var b: render.Banner = .{};
            add_line(&b, "PAUSED", 2, colors.text);
            add_line(&b, "", 1, colors.text);
            const items = [2][]const u8{ "RESUME    ", "LEAVE DUEL" };
            for (items, 0..) |t, i| {
                const sel = i == lk.pause_sel;
                var buf: [20]u8 = undefined;
                add_line(&b, cursor_line(&buf, sel, t), 1, if (sel) colors.select else colors.text);
            }
            v.banner = b;
        } else if (lk.status == .waiting) {
            var b: render.Banner = .{ .cy = 18 };
            add_line(&b, "WAITING FOR PEER", 1, if (blink_on) colors.warn else colors.text);
            v.banner = b;
        }
        return v;
    }

    /// Round, your wins as pips, your energy, the partner's wins.
    noinline fn link_hud(g: *const Game, v: *render.View) void {
        const lk = &g.lk;
        var buf: [20]u8 = undefined;
        var n = copy(&buf, "ROUND ");
        n += decimal(buf[n..], lk.round, 1);
        v.hud.left = .of(buf[0..n], 1, colors.text);
        var rb: [20]u8 = undefined;
        n = copy(&rb, "PEER ");
        n += decimal(rb[n..], lk.wins[lk.slot ^ 1], 1);
        v.hud.right = .of(rb[0..n], 1, colors.cycle[1]);
        v.hud.lives = lk.wins[lk.slot];
        v.hud.max_lives = lk.first_to;
        const me = &g.world.cycles[lk.slot];
        v.hud.energy = if (me.state == .alive) me.energy else 0;
        v.hud.bar_mode = if (me.state != .alive) 0 else if (me.boost) 1 else if (me.brake) 2 else 0;
    }

    /// "YOU 2  PEER 1" in the two colours' place: one line.
    fn add_duel_score(g: *const Game, b: *render.Banner) void {
        const lk = &g.lk;
        var buf: [20]u8 = undefined;
        var n = copy(&buf, "YOU ");
        n += decimal(buf[n..], lk.wins[lk.slot], 1);
        n += copy(buf[n..], "  PEER ");
        n += decimal(buf[n..], lk.wins[lk.slot ^ 1], 1);
        add_line(b, buf[0..n], 1, colors.text);
    }

    /// The round's result, or the match card.
    noinline fn duel_card(g: *const Game, match: bool, blink_on: bool) render.Banner {
        const lk = &g.lk;
        var b: render.Banner = .{};
        const w: u8 = if (match) (if (lk.match_winner()) |m| m else sim.no_cycle) else lk.winner;
        if (w == sim.no_cycle) {
            add_line(&b, "DRAW", 2, colors.warn);
            add_line(&b, "NOBODY RIDES ON", 1, colors.dim);
        } else if (w == lk.slot) {
            add_line(&b, "YOU WIN", 2, colors.cycle[0]);
            add_line(&b, if (match) "THE MATCH" else "THE ROUND", 1, colors.text);
        } else {
            add_line(&b, "PEER WINS", 2, colors.cycle[1]);
            add_line(&b, if (match) "THE MATCH" else "THE ROUND", 1, colors.text);
        }
        g.add_duel_score(&b);
        if (!match) {
            var buf: [20]u8 = undefined;
            var n = copy(&buf, "FIRST TO ");
            n += decimal(buf[n..], lk.first_to, 1);
            add_line(&b, buf[0..n], 1, colors.dim);
        } else if (g.timer >= tuning.game_over_min_ticks) {
            if (lk.rematch[lk.slot]) {
                add_line(&b, "WAITING FOR PEER", 1, colors.dim);
            } else {
                add_line(&b, "A REMATCH  B MENU", 1, if (blink_on) colors.title_a else colors.text);
            }
            if (lk.rematch[lk.slot ^ 1]) add_line(&b, "PEER WANTS MORE", 1, colors.cycle[1]);
        }
        return b;
    }

    /// The cable screen, the host's setup, the guest's view of it.
    noinline fn lobby_banner(g: *const Game, blink_on: bool) render.Banner {
        const lk = &g.lk;
        var b: render.Banner = .{};
        switch (lk.status) {
            .offline => {
                add_line(&b, "LINK DUEL", 2, colors.title_a);
                add_line(&b, "NO LINK IN", 1, colors.warn);
                add_line(&b, "SIMULATOR", 1, colors.warn);
                add_line(&b, "", 1, colors.text);
                add_line(&b, "B BACK", 1, colors.dim);
            },
            .wrong_cart => {
                add_line(&b, "WRONG", 2, colors.lose);
                add_line(&b, "CART", 2, colors.lose);
                add_line(&b, cart_name(lk.partner_app), 1, colors.text);
                add_line(&b, "", 1, colors.text);
                add_line(&b, "START SNOUTY", 1, colors.dim);
                add_line(&b, "CYCLES ON BOTH", 1, colors.dim);
                add_line(&b, "B BACK", 1, colors.dim);
            },
            .lobby => {
                if (lk.resync) {
                    add_line(&b, "NO", 2, colors.warn);
                    add_line(&b, "CONTEST", 2, colors.warn);
                    add_line(&b, "NEXT ROUND", 1, colors.text);
                    add_line(&b, "WITH A NEW SEED", 1, colors.dim);
                    add_line(&b, "B LEAVE", 1, colors.dim);
                } else if (lk.host) {
                    g.setup_rows(&b, true, lk.rules());
                    const can = lk.can_go;
                    var buf: [20]u8 = undefined;
                    const sel = lk.row == .start;
                    const t = if (can) "START" else "WAITING FOR PEER";
                    add_line(&b, cursor_line(&buf, sel, t), 1, if (!can) colors.dim else if (sel) colors.select else colors.win);
                } else if (lk.heard) |r| {
                    g.setup_rows(&b, false, r);
                    add_line(&b, "HOST PICKS", 1, if (blink_on) colors.title_b else colors.text);
                } else {
                    add_line(&b, "LINK DUEL", 2, colors.title_a);
                    add_line(&b, "CONNECTED", 1, colors.win);
                    add_line(&b, "HOST PICKS", 1, colors.text);
                }
            },
            // searching, or a race on the way in or out
            else => {
                add_line(&b, "LINK DUEL", 2, colors.title_a);
                add_line(&b, "PLUG IN THE CABLE", 1, colors.text);
                add_line(&b, "UART TO UART", 1, colors.dim);
                add_line(&b, "SEARCHING", 1, if (blink_on) colors.warn else colors.grey);
                add_line(&b, "", 1, colors.text);
                add_line(&b, "B BACK", 1, colors.dim);
            },
        }
        return b;
    }

    /// The setup's seven rows from rules `r`: the host's with its cursor,
    /// the guest's without.
    noinline fn setup_rows(g: *const Game, b: *render.Banner, cursor: bool, r: LinkRules) void {
        var shown: Link = .{};
        shown.set_rules(r);
        const o = shown.opts;
        var nb: [2]u8 = undefined;
        const rows = [_]struct { k: []const u8, v: []const u8 }{
            .{ .k = "ARENA", .v = layouts.get(shown.layout).name },
            .{ .k = "SPEED", .v = o.speed.name() },
            .{ .k = "TRAILS", .v = if (o.snake) "SNAKE" else "FULL" },
            .{ .k = "GAPS", .v = on_off(o.gaps) },
            .{ .k = "WRAP", .v = on_off(o.wrap) },
            .{ .k = "HARDCORE", .v = on_off(o.hardcore) },
            .{ .k = "FIRST TO", .v = nb[0..decimal(&nb, shown.first_to, 1)] },
        };
        for (rows, 0..) |row, i| {
            const sel = cursor and i == @backingInt(g.lk.row);
            var buf: [20]u8 = undefined;
            add_line(b, row_line(&buf, sel, row.k, row.v), 1, if (sel) colors.select else colors.text);
        }
    }

    // ------------------------------------------------------------ view

    /// What to draw besides the World.
    pub noinline fn view(g: *const Game) render.View {
        if (g.mode == .link) return g.link_view();
        var v: render.View = .{};
        const blink_on = (g.ticks / tuning.blink_ticks) % 2 == 0;
        switch (g.state) {
            .title => {
                g.title_hud(&v);
                var b: render.Banner = .{ .iris = true, .cy = 67 };
                add_line(&b, "SNOUTY", 2, colors.title_a);
                add_line(&b, "CYCLES", 2, colors.title_b);
                add_line(&b, "LIGHT CYCLES", 1, colors.text);
                add_line(&b, "CPU CYCLES", 1, colors.dim);
                add_line(&b, "PRESS A", 1, if (blink_on) colors.select else colors.grey);
                v.banner = b;
            },
            .menu => {
                g.title_hud(&v);
                var b: render.Banner = .{};
                add_line(&b, "SNOUTY CYCLES", 1, colors.title_a);
                add_line(&b, "", 1, colors.text);
                for (menu_text, 0..) |t, i| {
                    const sel = i == @backingInt(g.menu_sel);
                    var buf: [20]u8 = undefined;
                    // OPTIONS gets a star while any is on.
                    const item = if (i == @backingInt(MenuItem.options) and !g.opts.is_default()) "OPTIONS *  " else t;
                    add_line(&b, cursor_line(&buf, sel, item), 1, if (sel) colors.select else colors.text);
                }
                v.banner = b;
            },
            .howto => {
                g.title_hud(&v);
                var b: render.Banner = .{};
                add_line(&b, "HOW TO PLAY", 1, colors.title_a);
                add_line(&b, "D-PAD   STEER", 1, colors.text);
                add_line(&b, "A HOLD  BOOST", 1, colors.text);
                add_line(&b, "B HOLD  BRAKE", 1, colors.text);
                add_line(&b, "NEAR A WALL: GRIND", 1, colors.dim);
                add_line(&b, "CRASH: REWIND 2 S", 1, colors.rewind);
                add_line(&b, "BE THE LAST RIDING", 1, colors.win);
                add_line(&b, "START   PAUSE", 1, colors.text);
                v.banner = b;
            },
            .options => {
                g.title_hud(&v);
                v.banner = g.options_banner();
            },
            .skirmish_setup => {
                g.title_hud(&v);
                v.banner = g.setup_banner();
            },
            .intro => {
                g.hud(&v);
                v.banner = if (g.mode == .skirmish) g.skirmish_intro_banner() else g.intro_banner();
            },
            .countdown => {
                g.hud(&v);
                v.banner = g.countdown_banner();
            },
            .play => {
                g.hud(&v);
                v.tags = 0b1110;
                if (g.timer < tuning.run_banner_ticks) {
                    var b: render.Banner = .{ .cy = g.run_cy };
                    add_line(&b, "RUN", 2, colors.win);
                    v.banner = b;
                } else if (g.sudden_death_tick != 0 and g.world.tick - g.sudden_death_tick < tuning.sudden_death_banner_ticks) {
                    var b: render.Banner = .{ .cy = 40 };
                    const on = (g.world.tick / 8) % 2 == 0;
                    add_line(&b, "SUDDEN", 2, if (on) colors.lose else colors.warn);
                    add_line(&b, "DEATH", 2, if (on) colors.lose else colors.warn);
                    v.banner = b;
                }
            },
            .derez => {
                g.hud(&v);
                v.tags = 0b1110;
                v.banner = g.derez_banner();
            },
            .frozen => {
                g.hud(&v);
                v.tags = 0b1110;
                v.banner = g.frozen_banner();
            },
            .rewind => {
                g.hud(&v);
                // The World clock running backwards, in the score's place.
                var buf: [20]u8 = undefined;
                v.hud.right = .of(clock(&buf, g.world.tick), 1, colors.rewind);
                var b: render.Banner = .{ .cy = g.rewind_cy };
                const on = (g.timer / 6) % 2 == 0;
                add_line(&b, "<< REWIND", 2, if (on) colors.rewind else colors.text);
                v.banner = b;
            },
            .clear => {
                g.hud(&v);
                v.tags = 0b1110;
                v.banner = g.clear_banner();
                // The HUD score counts up with the tally.
                var buf: [20]u8 = undefined;
                const n = decimal(&buf, g.tally_score(), 6);
                v.hud.right = .of(buf[0..n], 1, colors.text);
            },
            .game_over => {
                g.hud(&v);
                v.banner = g.game_over_banner(blink_on);
            },
            .round_over => {
                g.hud(&v);
                v.tags = 0b1110;
                v.banner = g.standings_banner(false, blink_on);
            },
            .match_over => {
                g.hud(&v);
                v.banner = g.standings_banner(true, blink_on);
            },
            .link_lobby, .link_notice => {},
            .paused => {
                g.hud(&v);
                var b: render.Banner = .{};
                add_line(&b, "PAUSED", 2, colors.text);
                add_line(&b, "", 1, colors.text);
                const items = [3][]const u8{ "RESUME       ", if (g.mode == .ladder) "RESTART LEVEL" else "RESTART MATCH", "QUIT         " };
                for (items, 0..) |t, i| {
                    const sel = i == @backingInt(g.pause_sel);
                    var buf: [20]u8 = undefined;
                    add_line(&b, cursor_line(&buf, sel, t), 1, if (sel) colors.select else colors.text);
                }
                v.banner = b;
            },
        }
        return v;
    }

    /// Arena pixel rows under the scanline tint, from the top (main's
    /// pixel sink applies it).
    pub fn tinted(g: *const Game) u8 {
        return g.tint_rows;
    }

    /// A banner centre away from your head (rows 34 or 98).
    fn away_from_player(g: *const Game) u8 {
        return if (g.world.cycles[0].y < sim.grid_h / 2) 98 else 34;
    }

    noinline fn title_hud(g: *const Game, v: *render.View) void {
        v.hud.left = .of("SNOUTY CYCLES", 1, colors.dim);
        var buf: [20]u8 = undefined;
        var n = copy(&buf, "HI ");
        n += decimal(buf[n..], g.high, 6);
        v.hud.right = .of(buf[0..n], 1, colors.dim);
    }

    /// The HUD: level (or SKIRMISH round), pips (snapshots, or your round
    /// wins), energy bar, score (or your points).
    noinline fn hud(g: *const Game, v: *render.View) void {
        var buf: [20]u8 = undefined;
        var n: usize = 0;
        switch (g.mode) {
            .ladder => {
                const r = g.round();
                n = decimal(&buf, r.number(), 2);
                n += copy(buf[n..], " ");
                n += copy(buf[n..], r.name());
                v.hud.left = .of(buf[0..n], 1, colors.text);
                n = decimal(&buf, g.score, 6);
                v.hud.right = .of(buf[0..n], 1, colors.text);
                v.hud.lives = g.snapshots;
                v.hud.max_lives = if (g.opts.hardcore) 0 else tuning.max_snapshots;
            },
            .skirmish, .link => {
                n = copy(&buf, "ROUND ");
                n += decimal(buf[n..], g.sk.round, 1);
                v.hud.left = .of(buf[0..n], 1, colors.text);
                n = copy(&buf, "PTS ");
                n += decimal(buf[n..], g.sk.points[0], 1);
                v.hud.right = .of(buf[0..n], 1, colors.text);
                v.hud.lives = g.sk.wins[0];
                v.hud.max_lives = tuning.match_wins;
            },
        }
        const me = &g.world.cycles[0];
        v.hud.energy = if (me.state == .alive) me.energy else 0;
        v.hud.bar_mode = if (me.state != .alive) 0 else if (me.boost) 1 else if (me.brake) 2 else 0;
    }

    /// The modifiers that are on ("SNAKE GAPS WRAP HARDCORE"), and the
    /// speed with `speed`, packed into banner lines of up to 18 characters.
    noinline fn add_modifiers(g: *const Game, b: *render.Banner, speed: bool) void {
        const o = g.opts;
        const parts = [_]struct { on: bool, s: []const u8 }{
            .{ .on = speed and o.speed == .slow, .s = "SLOW" },
            .{ .on = speed and o.speed == .fast, .s = "FAST" },
            .{ .on = o.snake, .s = "SNAKE" },
            .{ .on = o.gaps, .s = "GAPS" },
            .{ .on = o.wrap, .s = "WRAP" },
            .{ .on = o.hardcore, .s = "HARDCORE" },
        };
        var buf: [20]u8 = undefined;
        var n: usize = 0;
        for (parts) |p| {
            if (!p.on) continue;
            if (n != 0 and n + 1 + p.s.len > 18) {
                add_line(b, buf[0..n], 1, colors.warn);
                n = 0;
            }
            if (n != 0) n += copy(buf[n..], " ");
            n += copy(buf[n..], p.s);
        }
        if (n != 0) add_line(b, buf[0..n], 1, colors.warn);
    }

    noinline fn options_banner(g: *const Game) render.Banner {
        var b: render.Banner = .{};
        add_line(&b, "OPTIONS", 1, colors.title_a);
        add_line(&b, "", 1, colors.text);
        const o = g.opts;
        const rows = [_]struct { k: []const u8, v: []const u8 }{
            .{ .k = "SPEED", .v = o.speed.name() },
            .{ .k = "TRAILS", .v = if (o.snake) "SNAKE" else "FULL" },
            .{ .k = "GAPS", .v = on_off(o.gaps) },
            .{ .k = "WRAP", .v = on_off(o.wrap) },
            .{ .k = "HARDCORE", .v = on_off(o.hardcore) },
            .{ .k = "BACK", .v = "" },
        };
        for (rows, 0..) |r, i| {
            const sel = i == @backingInt(g.option_row);
            var buf: [20]u8 = undefined;
            add_line(&b, row_line(&buf, sel, r.k, r.v), 1, if (sel) colors.select else colors.text);
        }
        return b;
    }

    noinline fn setup_banner(g: *const Game) render.Banner {
        var b: render.Banner = .{};
        add_line(&b, "SKIRMISH", 1, colors.title_a);
        const s = &g.sk;
        var nb: [2]u8 = undefined;
        const rows = [_]struct { k: []const u8, v: []const u8 }{
            .{ .k = "PROGRAMS", .v = nb[0..decimal(&nb, s.programs, 1)] },
            .{ .k = "TIER", .v = levels.tier_names[s.tier] },
            .{ .k = "ARENA", .v = layouts.get(s.layout).name },
            .{ .k = "SPEED", .v = g.opts.speed.name() },
            .{ .k = "START", .v = "" },
        };
        for (rows, 0..) |r, i| {
            const sel = i == @backingInt(s.row);
            var buf: [20]u8 = undefined;
            add_line(&b, row_line(&buf, sel, r.k, r.v), 1, if (sel) colors.select else if (i == rows.len - 1) colors.win else colors.text);
        }
        g.add_modifiers(&b, false);
        return b;
    }

    noinline fn intro_banner(g: *const Game) render.Banner {
        const r = g.round();
        var b: render.Banner = .{};
        var buf: [20]u8 = undefined;
        var n: usize = 0;
        if (r.loop != 0) {
            n += copy(buf[n..], "LOOP ");
            n += decimal(buf[n..], r.loop + 1, 1);
            n += copy(buf[n..], " ");
        }
        n += copy(buf[n..], "LEVEL ");
        n += decimal(buf[n..], r.number(), 1);
        add_line(&b, buf[0..n], 1, colors.dim);
        const name = r.name();
        add_line(&b, name, if (name.len <= 6) 3 else 2, colors.title_a);
        const progs = r.programs().len;
        n = decimal(&buf, @intCast(progs), 1);
        n += copy(buf[n..], if (progs == 1) " PROGRAM" else " PROGRAMS");
        add_line(&b, buf[0..n], 1, colors.title_b);
        const speed = g.world.cfg.speed_pct;
        if (speed != 100) {
            n = copy(&buf, "SPEED ");
            n += decimal(buf[n..], speed, 1);
            n += copy(buf[n..], "%");
            add_line(&b, buf[0..n], 1, colors.warn);
        }
        g.add_modifiers(&b, false);
        return b;
    }

    noinline fn skirmish_intro_banner(g: *const Game) render.Banner {
        var b: render.Banner = .{};
        var buf: [20]u8 = undefined;
        add_line(&b, "FIRST TO 3 WINS", 1, colors.dim);
        var n = copy(&buf, "ROUND ");
        n += decimal(buf[n..], g.sk.round, 1);
        add_line(&b, buf[0..n], 2, colors.title_a);
        n = decimal(&buf, g.sk.programs, 1);
        n += copy(buf[n..], " ");
        n += copy(buf[n..], levels.tier_names[g.sk.tier]);
        n += copy(buf[n..], "  ");
        n += copy(buf[n..], layouts.get(g.sk.layout).name);
        add_line(&b, buf[0..n], 1, colors.title_b);
        if (g.sk.round > 1) {
            g.add_standings(&b);
        } else {
            g.add_modifiers(&b, true);
        }
        return b;
    }

    noinline fn countdown_banner(g: *const Game) render.Banner {
        var b: render.Banner = .{};
        const steps: u32 = if (g.resuming) 2 else 3;
        const n = steps - @min(steps - 1, g.timer / tuning.count_step_ticks);
        const digit = [1]u8{'0' + @as(u8, @intCast(n))};
        // Narrow, so the start cells beside it stay in view.
        add_line(&b, &digit, 3, colors.warn);
        if (g.resuming) {
            // Away from where you ride on.
            b.cy = g.away_from_player();
            var buf: [20]u8 = undefined;
            if (g.world.tick == 0) add_line(&b, "FROM THE TOP", 1, colors.text);
            add_line(&b, snapshots_line(&buf, g.snapshots), 1, colors.rewind);
        } else if (g.mode == .skirmish) {
            var buf: [20]u8 = undefined;
            var k = copy(&buf, "ROUND ");
            k += decimal(buf[k..], g.sk.round, 1);
            add_line(&b, buf[0..k], 1, colors.text);
        } else {
            add_line(&b, g.round().name(), 1, colors.text);
        }
        return b;
    }

    fn crash_lines(g: *const Game, b: *render.Banner) void {
        const name = g.crash.name();
        if (name.len <= 9) {
            add_line(b, name, 2, colors.lose);
        } else {
            // Two big lines: "ACCESS" / "VIOLATION".
            const sp = std.mem.indexOfScalar(u8, name, ' ') orelse name.len;
            add_line(b, name[0..sp], 2, colors.lose);
            if (sp < name.len) add_line(b, name[sp + 1 ..], 2, colors.lose);
        }
    }

    noinline fn derez_banner(g: *const Game) render.Banner {
        // Away from the crash, so the burst stays in view.
        var b: render.Banner = .{ .cy = g.away_from_player() };
        if (g.timed_out) {
            add_line(&b, "TIME UP", 2, colors.warn);
            add_line(&b, "AGAIN", 1, colors.text);
            return b;
        }
        if (g.mode == .skirmish and g.timer >= tuning.derez_ticks) {
            // Watching the programs finish the round.
            b.cy = 18;
            add_line(&b, "WATCHING  A FAST", 1, colors.dim);
            return b;
        }
        g.crash_lines(&b);
        switch (g.mode) {
            .ladder => add_line(&b, if (g.opts.hardcore) "HARDCORE NO REWIND" else "NO SNAPSHOTS LEFT", 1, colors.warn),
            .skirmish, .link => add_line(&b, "PROGRAMS RIDE ON", 1, colors.dim),
        }
        return b;
    }

    noinline fn frozen_banner(g: *const Game) render.Banner {
        var b: render.Banner = .{ .cy = g.away_from_player() };
        g.crash_lines(&b);
        add_line(&b, "RESTORING SNAPSHOT", 1, colors.rewind);
        return b;
    }

    /// The score shown during the tally: counting up after the bonus line.
    fn tally_score(g: *const Game) u32 {
        if (g.state != .clear) return g.score;
        if (g.timer < tuning.tally_bonus_tick) return g.tally_from;
        const t = g.timer - tuning.tally_bonus_tick;
        if (t >= tuning.tally_count_ticks) return g.score;
        return g.tally_from + (g.score - g.tally_from) * t / tuning.tally_count_ticks;
    }

    noinline fn clear_banner(g: *const Game) render.Banner {
        const r = g.round();
        var b: render.Banner = .{};
        add_line(&b, r.name(), 1, colors.text);
        add_line(&b, "CLEAR", 3, colors.win);
        var buf: [20]u8 = undefined;
        if (g.timer >= tuning.tally_bonus_tick) {
            var n = copy(&buf, "BONUS +");
            n += decimal(buf[n..], g.score - g.tally_from, 1);
            add_line(&b, buf[0..n], 1, colors.warn);
            n = copy(&buf, "SCORE ");
            n += decimal(buf[n..], g.tally_score(), 6);
            add_line(&b, buf[0..n], 1, colors.text);
        }
        if (g.life_back and g.timer >= tuning.tally_life_tick) {
            const on = (g.timer / 8) % 2 == 0;
            add_line(&b, "+1 SNAPSHOT", 1, if (on) colors.title_a else colors.text);
        }
        return b;
    }

    noinline fn game_over_banner(g: *const Game, blink_on: bool) render.Banner {
        var b: render.Banner = .{};
        if (g.quit) {
            add_line(&b, "EXIT 0", 2, colors.win);
        } else {
            add_line(&b, "CORE", 2, colors.lose);
            add_line(&b, "DUMPED", 2, colors.lose);
        }
        var buf: [20]u8 = undefined;
        var n: usize = 0;
        if (g.bonus != 0) {
            n = copy(&buf, "SNAPSHOTS +");
            n += decimal(buf[n..], g.bonus, 1);
            add_line(&b, buf[0..n], 1, colors.rewind);
        }
        n = copy(&buf, "SCORE ");
        n += decimal(buf[n..], g.score, 6);
        add_line(&b, buf[0..n], 1, colors.text);
        const r = g.round();
        n = copy(&buf, "LEVEL ");
        n += decimal(buf[n..], r.number(), 1);
        n += copy(buf[n..], " ");
        n += copy(buf[n..], r.name());
        add_line(&b, buf[0..n], 1, colors.dim);
        if (g.new_high) {
            add_line(&b, "NEW HIGH SCORE", 1, if (blink_on) colors.warn else colors.select);
        } else {
            n = copy(&buf, "HIGH ");
            n += decimal(buf[n..], g.high, 6);
            add_line(&b, buf[0..n], 1, colors.dim);
        }
        if (g.timer >= tuning.game_over_min_ticks) add_line(&b, "A RETRY  B MENU", 1, colors.title_a);
        return b;
    }

    /// One line per cycle: name, round wins, points, in its colour.
    noinline fn add_standings(g: *const Game, b: *render.Banner) void {
        for (0..g.sk.n_cycles()) |i| {
            var buf: [20]u8 = undefined;
            var n = copy(&buf, cycle_names[i]);
            while (n < 8) : (n += 1) buf[n] = ' ';
            n += decimal(buf[n..], g.sk.wins[i], 1);
            n += copy(buf[n..], "W ");
            n += decimal(buf[n..], g.sk.points[i], 2);
            n += copy(buf[n..], "P");
            add_line(b, buf[0..n], 1, colors.cycle[i]);
        }
    }

    /// SKIRMISH: a round's result (`match` false) or the match card.
    noinline fn standings_banner(g: *const Game, match: bool, blink_on: bool) render.Banner {
        var b: render.Banner = .{};
        const w = if (match) g.sk.match_winner() orelse sim.no_cycle else g.sk.winner;
        if (w == sim.no_cycle) {
            add_line(&b, "DRAW", 2, colors.warn);
            add_line(&b, "NOBODY RIDES ON", 1, colors.dim);
        } else {
            add_line(&b, if (w == 0) "YOU WIN" else cycle_names[w], 2, colors.cycle[w]);
            if (w != 0) add_line(&b, if (match) "WINS THE MATCH" else "WINS THE ROUND", 1, colors.text) else add_line(&b, if (match) "THE MATCH" else "THE ROUND", 1, colors.text);
        }
        g.add_standings(&b);
        if (match and g.timer >= tuning.game_over_min_ticks) add_line(&b, "A REMATCH  B MENU", 1, if (blink_on) colors.title_a else colors.text);
        return b;
    }
};

/// A whole World tick's AI pool, in units.
const pool_units: u64 = @intCast(ai.tuning.tick_pool);

/// `World.init`, kept out of line (three callers; 2 KB inlined each).
noinline fn init_world(w: *sim.World, cfg: sim.Config, seed: u32) void {
    w.init(cfg, seed);
}

/// `Banner.add`, kept out of line: the banners are cold code and an
/// inlined add costs ~150 bytes of .text a line (a RAM cart).
noinline fn add_line(b: *render.Banner, s: []const u8, scale: u8, color: u16) void {
    b.add(s, scale, color);
}

/// The AI's work units so far (all tiers): the replay's frame budget.
fn ai_units() u64 {
    var n: u64 = 0;
    for (ai.stats.units) |u| n += u;
    return n;
}

fn cycle_speed(s: levels.Options.Speed, back: bool) levels.Options.Speed {
    // In the order shown: SLOW, NORMAL, FAST.
    return switch (s) {
        .slow => if (back) .fast else .normal,
        .normal => if (back) .slow else .fast,
        .fast => if (back) .normal else .slow,
    };
}

/// v stepped by one inside [lo, hi], wrapping.
fn step_in(v: u8, lo: u8, hi: u8, back: bool) u8 {
    if (back) return if (v <= lo) hi else v - 1;
    return if (v >= hi) lo else v + 1;
}

fn on_off(b: bool) []const u8 {
    return if (b) "ON" else "OFF";
}

/// "> KEY      VALUE": the cursor, the key, the value right-aligned in 16.
fn row_line(buf: *[20]u8, sel: bool, k: []const u8, v: []const u8) []const u8 {
    var n = copy(buf, if (sel) "> " else "  ");
    n += copy(buf[n..], k);
    const end: usize = 2 + 15;
    while (n + v.len < end) : (n += 1) buf[n] = ' ';
    n += copy(buf[n..], v);
    return buf[0..n];
}

fn snapshots_line(buf: *[20]u8, n: u8) []const u8 {
    return switch (n) {
        0 => "NO SNAPSHOTS LEFT",
        1 => "1 SNAPSHOT LEFT",
        else => blk: {
            var k = decimal(buf, n, 1);
            k += copy(buf[k..], " SNAPSHOTS LEFT");
            break :blk buf[0..k];
        },
    };
}

/// The World clock as seconds with a tenth ("31.4").
fn clock(buf: *[20]u8, tick: u32) []const u8 {
    var n = decimal(buf, tick / 60, 2);
    n += copy(buf[n..], ".");
    n += decimal(buf[n..], tick % 60 / 6, 1);
    return buf[0..n];
}

/// "> " before the selected item, two spaces before the others, so the
/// items line up under one centre.
fn cursor_line(buf: *[20]u8, sel: bool, t: []const u8) []const u8 {
    var n = copy(buf, if (sel) "> " else "  ");
    n += copy(buf[n..], t);
    return buf[0..n];
}

/// The heading pressed this tick, if any (one per tick; the turn queue
/// keeps a fast double tap across two ticks).
fn dpad(p: Buttons) ?sim.Dir {
    if (p.up) return .up;
    if (p.right) return .right;
    if (p.down) return .down;
    if (p.left) return .left;
    return null;
}

noinline fn copy(dst: []u8, s: []const u8) usize {
    const n = @min(dst.len, s.len);
    @memcpy(dst[0..n], s[0..n]);
    return n;
}

/// `v` in decimal, zero-padded to `width` digits, into dst.
pub noinline fn decimal(dst: []u8, v: u32, width: usize) usize {
    var tmp: [10]u8 = undefined;
    var n: usize = 0;
    var x = v;
    while (true) {
        tmp[n] = '0' + @as(u8, @intCast(x % 10));
        n += 1;
        x /= 10;
        if (x == 0) break;
    }
    while (n < width and n < tmp.len) : (n += 1) tmp[n] = '0';
    const m = @min(n, dst.len);
    for (0..m) |i| dst[i] = tmp[n - 1 - i];
    return m;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
var tg: Game = undefined;

const press_a: Buttons = .{ .a = true };

fn tap(g: *Game, b: Buttons) void {
    g.update(b, b);
}

fn idle(g: *Game, n: u32) void {
    for (0..n) |_| g.update(.{}, .{});
}

/// Runs until `state` (or the tick cap); returns whether it got there.
fn run_until(g: *Game, state: State, cap: u32) bool {
    var t: u32 = 0;
    while (g.state != state and t < cap) : (t += 1) g.update(.{}, .{});
    return g.state == state;
}

test "decimal formatting" {
    var b: [12]u8 = undefined;
    try testing.expectEqualStrings("000500", b[0..decimal(&b, 500, 6)]);
    try testing.expectEqualStrings("7", b[0..decimal(&b, 7, 1)]);
    try testing.expectEqualStrings("1234567", b[0..decimal(&b, 1234567, 6)]);
    var c: [20]u8 = undefined;
    try testing.expectEqualStrings("31.4", clock(&c, 31 * 60 + 25));
    try testing.expectEqualStrings("00.0", clock(&c, 0));
}

test "title, menu, GRID LADDER: intro, countdown, play" {
    const g = &tg;
    g.init(1);
    idle(g, 30);
    try testing.expectEqual(State.title, g.state);
    tap(g, press_a);
    try testing.expectEqual(State.menu, g.state);
    try testing.expectEqual(MenuItem.ladder, g.menu_sel);
    tap(g, press_a);
    try testing.expectEqual(State.intro, g.state);
    try testing.expectEqual(@as(u32, 1), g.level);
    try testing.expectEqual(tuning.max_snapshots, g.snapshots);
    try testing.expectEqual(@as(u8, 2), g.world.cfg.n_cycles);
    // A skips the intro once it has been up a moment.
    idle(g, tuning.skip_ticks);
    tap(g, press_a);
    try testing.expectEqual(State.countdown, g.state);
    idle(g, tuning.countdown_ticks);
    try testing.expectEqual(State.play, g.state);
}

test "the menu: five items, B goes back; HOW TO PLAY, OPTIONS, SKIRMISH, LINK DUEL and back" {
    const g = &tg;
    g.init(2);
    tap(g, press_a);
    tap(g, .{ .up = true });
    try testing.expectEqual(MenuItem.howto, g.menu_sel);
    tap(g, press_a);
    try testing.expectEqual(State.howto, g.state);
    tap(g, .{ .b = true });
    try testing.expectEqual(State.menu, g.state);
    tap(g, .{ .down = true });
    try testing.expectEqual(MenuItem.ladder, g.menu_sel);
    tap(g, .{ .down = true });
    try testing.expectEqual(MenuItem.skirmish, g.menu_sel);
    tap(g, press_a);
    try testing.expectEqual(State.skirmish_setup, g.state);
    tap(g, .{ .b = true });
    try testing.expectEqual(State.menu, g.state);
    tap(g, .{ .down = true });
    try testing.expectEqual(MenuItem.link, g.menu_sel);
    tap(g, press_a);
    try testing.expectEqual(State.link_lobby, g.state);
    try testing.expectEqual(Mode.link, g.mode);
    tap(g, .{ .b = true });
    try testing.expectEqual(State.menu, g.state);
    try testing.expectEqual(MenuItem.link, g.menu_sel);
    tap(g, .{ .down = true });
    try testing.expectEqual(MenuItem.options, g.menu_sel);
    tap(g, press_a);
    try testing.expectEqual(State.options, g.state);
    tap(g, .{ .b = true });
    tap(g, .{ .b = true });
    try testing.expectEqual(State.title, g.state);
}

test "OPTIONS: each row changes its option; the ladder's World gets them" {
    const g = &tg;
    g.init(3);
    tap(g, press_a);
    g.menu_sel = .options;
    tap(g, press_a);
    try testing.expectEqual(State.options, g.state);
    tap(g, .{ .right = true }); // SPEED: NORMAL -> FAST
    try testing.expectEqual(levels.Options.Speed.fast, g.opts.speed);
    tap(g, .{ .right = true }); // FAST -> SLOW
    try testing.expectEqual(levels.Options.Speed.slow, g.opts.speed);
    tap(g, .{ .left = true }); // back to FAST
    for ([_]OptionRow{ .trails, .gaps, .wrap, .hardcore }) |row| {
        tap(g, .{ .down = true });
        try testing.expectEqual(row, g.option_row);
        tap(g, press_a);
    }
    try testing.expect(g.opts.snake and g.opts.gaps and g.opts.wrap and g.opts.hardcore);
    tap(g, .{ .down = true });
    try testing.expectEqual(OptionRow.back, g.option_row);
    tap(g, press_a);
    try testing.expectEqual(State.menu, g.state);
    g.new_game(9);
    const c = g.world.cfg;
    // RUST is 110%: 125% of it.
    try testing.expectEqual(@as(u16, 137), c.speed_pct);
    try testing.expectEqual(levels.Options.snake_len, c.snake_len);
    try testing.expect(c.gaps and c.wrap);
    try testing.expectEqual(levels.Options.hardcore_rubber, c.rubber);
    // HARDCORE: no snapshots.
    try testing.expectEqual(@as(u8, 0), g.snapshots);
}

/// The World hash at each tick of a ladder round, for the rewind checks.
var hashes: [4096]u32 = undefined;
var scores: [4096]u32 = undefined;

/// Plays level `level` on autopilot 3 to World tick `crash` (or the
/// round's end), recording the hash and score per tick; then forces a
/// derez there and runs the freeze and the rewind. The countdown must
/// start on the World exactly as it was 2 s before (hash and score), and
/// no replay frame may run more than the frame budget's ticks.
fn check_rewind(g: *Game, seed: u32, level: u32, crash: u32, opts: levels.Options) !bool {
    g.init(seed);
    g.opts = opts;
    g.autopilot = 3;
    g.new_game(level);
    if (!run_until(g, .play, 400)) return error.NoPlay;
    while (g.state == .play and g.world.tick < crash) {
        g.update(.{}, .{});
        hashes[g.world.tick] = g.world.hash();
        scores[g.world.tick] = g.score;
    }
    // A real crash or the level's end came first: not this check's case.
    if (g.state != .play) return false;
    const snaps = g.snapshots;
    g.force_crash();
    try testing.expectEqual(State.frozen, g.state);
    idle(g, tuning.freeze_ticks);
    try testing.expectEqual(State.rewind, g.state);
    try testing.expectEqual(snaps - 1, g.snapshots);
    try testing.expect(g.tint_rows > 0);
    // Backwards at 3x: the World clock falls 3 ticks a frame.
    var frames: u32 = 0;
    var held: u32 = 0;
    var last = g.world.tick;
    while (g.state == .rewind) : (frames += 1) {
        g.update(.{}, .{});
        if (g.hold_frame) {
            held += 1;
        } else if (g.state == .rewind and !g.replaying) {
            try testing.expect(last - g.world.tick <= history.tuning.retract_per_frame);
        }
        last = g.world.tick;
        if (frames > 400) return error.RewindHangs;
    }
    try testing.expectEqual(State.countdown, g.state);
    try testing.expect(g.resuming and g.tint_rows == 0);
    const t = crash -| history.tuning.rewind_ticks;
    try testing.expectEqual(t, g.world.tick);
    if (t > 0) {
        try testing.expectEqual(hashes[t], g.world.hash());
        try testing.expectEqual(scores[t], g.score);
    }
    try testing.expect(frames <= history.tuning.rewind_ticks / history.tuning.retract_per_frame + 2 + held);
    // The replay never needs more than a handful of frames.
    try testing.expect(held <= 12);
    // 2, 1, RUN.
    idle(g, tuning.resume_ticks);
    try testing.expectEqual(State.play, g.state);
    return true;
}

test "a rewind lands on the exact World 2 s before the crash (hash and score)" {
    const g = &tg;
    var done: u32 = 0;
    const cases = [_]struct { level: u32, crash: u32, opts: levels.Options }{
        .{ .level = 1, .crash = 400, .opts = .{} },
        .{ .level = 5, .crash = 700, .opts = .{} },
        .{ .level = 8, .crash = 1000, .opts = .{ .speed = .fast } },
        .{ .level = 12, .crash = 900, .opts = .{} },
        .{ .level = 12, .crash = 1900, .opts = .{} },
        .{ .level = 11, .crash = 60, .opts = .{} },
        .{ .level = 6, .crash = 800, .opts = .{ .snake = true, .gaps = true } },
        .{ .level = 7, .crash = 800, .opts = .{ .wrap = true, .speed = .slow } },
        .{ .level = 10, .crash = 1300, .opts = .{ .snake = true, .gaps = true, .wrap = true } },
    };
    for (cases, 0..) |c, k| {
        if (try check_rewind(g, @intCast(11 + k), c.level, c.crash, c.opts)) done += 1;
    }
    try testing.expect(done >= 6);
}

test "a quick second derez lands further back, exactly; past the keyframes, the round's start" {
    const g = &tg;
    var cases: u32 = 0;
    for ([_]u32{ 5, 9, 12 }) |level| {
        g.init(level * 7);
        g.autopilot = 3;
        g.new_game(level);
        try testing.expect(run_until(g, .play, 400));
        hashes[0] = g.world.hash();
        // The straight run's hashes, to tick 1000, then a derez.
        while (g.state == .play and g.world.tick < 1000) {
            g.update(.{}, .{});
            hashes[g.world.tick] = g.world.hash();
        }
        if (g.state != .play) continue;
        g.force_crash();
        try testing.expect(run_until(g, .play, 400));
        const first = g.world.tick;
        try testing.expectEqual(@as(u32, 880), first);
        try testing.expectEqual(hashes[first], g.world.hash());
        // A second derez 1 s later: the landing was lost; 2 s before it
        // (760) is past the kept keyframes (780..990), so the round
        // starts over, exactly as it began.
        idle(g, 60);
        if (g.state != .play) continue;
        g.force_crash();
        try testing.expect(run_until(g, .countdown, 400));
        try testing.expectEqual(@as(u32, 0), g.world.tick);
        try testing.expectEqual(hashes[0], g.world.hash());
        try testing.expectEqual(@as(u8, 1), g.snapshots);
        // The countdown says so.
        var found = false;
        if (g.view().banner) |b| {
            for (b.lines[0..b.n]) |l| found = found or std.mem.eql(u8, l.str(), "FROM THE TOP");
        }
        try testing.expect(found);
        cases += 1;
    }
    try testing.expect(cases >= 2);
}

test "derezzes use the snapshots, then CORE DUMPED; a clear gives one back" {
    const g = &tg;
    g.init(3);
    g.new_game(1);
    var t: u32 = 0;
    // No input: you ride straight into something every time.
    while (g.state != .game_over and t < 60 * 60 * 5) : (t += 1) {
        const before = g.state;
        g.update(.{}, .{});
        if (before == .play and g.state == .frozen) try testing.expect(g.crash != .none);
        if (g.state == .clear) break;
    }
    if (g.state == .clear) {
        // The program crashed first: a snapshot back (if one was used).
        try testing.expect(g.snapshots <= tuning.max_snapshots);
        return;
    }
    try testing.expectEqual(State.game_over, g.state);
    try testing.expectEqual(@as(u32, tuning.max_snapshots), g.rewinds);
    try testing.expectEqual(@as(u32, tuning.max_snapshots + 1), g.deaths);
    try testing.expectEqual(@as(u8, 0), g.snapshots);
    try testing.expectEqual(g.score, g.high);
    try testing.expect(!g.quit);
    // Input waits a moment, then A retries from level 1.
    tap(g, press_a);
    try testing.expectEqual(State.game_over, g.state);
    idle(g, tuning.game_over_min_ticks);
    tap(g, press_a);
    try testing.expectEqual(State.intro, g.state);
    try testing.expectEqual(@as(u32, 1), g.level);
    try testing.expectEqual(tuning.max_snapshots, g.snapshots);
}

test "HARDCORE: no snapshots, a derez ends the game" {
    const g = &tg;
    g.init(4);
    g.opts.hardcore = true;
    g.new_game(2);
    try testing.expect(run_until(g, .play, 400));
    g.force_crash();
    try testing.expectEqual(State.derez, g.state);
    try testing.expect(run_until(g, .game_over, tuning.derez_ticks + 5));
    try testing.expectEqual(@as(u32, 0), g.rewinds);
}

test "autopilot clears BASIC: tally, a snapshot back, the next level" {
    const g = &tg;
    var cleared = false;
    var seed: u32 = 1;
    while (!cleared and seed <= 12) : (seed += 1) {
        g.init(seed);
        g.autopilot = 1;
        g.new_game(1);
        g.snapshots = 2;
        var t: u32 = 0;
        while (g.level == 1 and g.state != .game_over and t < 60 * 60 * 10) : (t += 1) {
            g.update(.{}, .{});
            if (g.state == .clear and g.timer == 1) {
                try testing.expect(g.life_back);
                try testing.expect(g.snapshots >= 1 and g.snapshots <= tuning.max_snapshots);
                try testing.expect(g.score >= g.tally_from + tuning.clear_points);
                // The tally counts up from the old score.
                try testing.expectEqual(g.tally_from, g.tally_score());
            }
        }
        if (g.level == 2) {
            cleared = true;
            try testing.expectEqual(State.intro, g.state);
            try testing.expectEqual(@as(u32, 1), g.clears);
        }
    }
    try testing.expect(cleared);
}

test "pause: RESUME, RESTART LEVEL restores the level's score, QUIT is EXIT 0 with the snapshot bonus" {
    const g = &tg;
    g.init(5);
    g.new_game(3);
    try testing.expect(run_until(g, .play, 1000));
    g.update(.{ .start = true, .select = true }, .{ .start = true });
    try testing.expectEqual(State.play, g.state);
    tap(g, .{ .start = true });
    try testing.expectEqual(State.paused, g.state);
    const tick = g.world.tick;
    idle(g, 10);
    try testing.expectEqual(tick, g.world.tick);
    tap(g, .{ .start = true });
    try testing.expectEqual(State.play, g.state);
    // RESTART LEVEL: the score goes back to the level's start.
    g.score += 777;
    tap(g, .{ .start = true });
    tap(g, .{ .down = true });
    try testing.expectEqual(PauseItem.restart, g.pause_sel);
    tap(g, press_a);
    try testing.expectEqual(State.countdown, g.state);
    try testing.expectEqual(@as(u32, 0), g.score);
    try testing.expectEqual(@as(u32, 3), g.level);
    // QUIT: the card, 2000 a snapshot.
    try testing.expect(run_until(g, .play, 1000));
    tap(g, .{ .start = true });
    tap(g, .{ .up = true });
    try testing.expectEqual(PauseItem.quit, g.pause_sel);
    tap(g, press_a);
    try testing.expectEqual(State.game_over, g.state);
    try testing.expect(g.quit);
    try testing.expectEqual(@as(u32, 3 * tuning.snapshot_points), g.bonus);
    try testing.expectEqual(g.bonus, g.score);
}

test "countdown presses set the first heading; after a rewind they press on the first tick" {
    const g = &tg;
    g.init(6);
    g.new_game(1);
    g.update(.{ .up = true }, .{ .up = true });
    try testing.expectEqual(sim.Dir.up, g.world.cycles[0].dir);
    try testing.expect(run_until(g, .play, 400));
    // The autopilot rides to tick 300, then you take over after a rewind.
    g.autopilot = 1;
    idle(g, 300);
    try testing.expectEqual(State.play, g.state);
    g.force_crash();
    try testing.expect(run_until(g, .countdown, 400));
    try testing.expect(g.resuming);
    try testing.expectEqual(@as(u32, 180), g.world.tick);
    g.autopilot = 0;
    const d = g.world.cycles[0].dir.cw();
    tap(g, .{ .down = d == .down, .up = d == .up, .left = d == .left, .right = d == .right });
    try testing.expectEqual(@as(?sim.Dir, d), g.resume_press);
    try testing.expect(run_until(g, .play, 200));
    g.update(.{}, .{});
    try testing.expectEqual(@as(?sim.Dir, null), g.resume_press);
    try testing.expectEqual(d, g.world.planned_dir(0));
}

test "SKIRMISH: setup rows, first to 3 round wins, Achtung points, rematch" {
    const g = &tg;
    g.init(8);
    g.autopilot = 3;
    tap(g, press_a);
    g.menu_sel = .skirmish;
    tap(g, press_a);
    try testing.expectEqual(State.skirmish_setup, g.state);
    tap(g, .{ .down = true }); // START -> PROGRAMS
    try testing.expectEqual(SetupRow.programs, g.sk.row);
    tap(g, .{ .right = true });
    tap(g, .{ .right = true });
    try testing.expectEqual(@as(u8, 3), g.sk.programs);
    tap(g, .{ .down = true });
    tap(g, .{ .left = true }); // PASCAL -> BASIC
    try testing.expectEqual(@as(u8, 0), g.sk.tier);
    tap(g, .{ .down = true });
    tap(g, .{ .right = true }); // OPEN -> PILLARS
    try testing.expectEqual(@as(u8, 1), g.sk.layout);
    tap(g, .{ .start = true });
    try testing.expectEqual(State.intro, g.state);
    try testing.expectEqual(Mode.skirmish, g.mode);
    try testing.expectEqual(@as(u8, 4), g.world.cfg.n_cycles);
    try testing.expectEqual(@as(u8, 1), g.world.cfg.layout);
    var t: u32 = 0;
    var rounds: u32 = 0;
    while (g.state != .match_over and t < 60 * 60 * 20) : (t += 1) {
        const before = g.state;
        g.update(.{ .a = g.state == .derez }, .{});
        if (g.state == .round_over and before != .round_over) {
            rounds += 1;
            // The winner outlived everyone: n - 1 points this round at least.
            const w = g.sk.winner;
            if (w != sim.no_cycle) try testing.expect(g.sk.points[w] >= 3);
            try testing.expect(g.snapshots == 0 and g.rewinds == 0);
        }
    }
    try testing.expectEqual(State.match_over, g.state);
    const winner = g.sk.match_winner().?;
    try testing.expectEqual(tuning.match_wins, g.sk.wins[winner]);
    var total: u32 = 0;
    for (g.sk.wins) |w| total += w;
    try testing.expect(total <= rounds);
    try testing.expect(rounds >= tuning.match_wins);
    idle(g, tuning.game_over_min_ticks);
    tap(g, press_a);
    try testing.expectEqual(State.intro, g.state);
    try testing.expectEqual(@as(u32, 1), g.sk.round);
    try testing.expectEqual(@as(u8, 0), g.sk.wins[winner]);
}

/// Every banner and HUD the game makes, for the margin test below.
fn check_view(g: *const Game) !void {
    const v = g.view();
    if (v.banner) |b| {
        if (!b.fits()) {
            for (b.lines[0..b.n]) |l| std.debug.print("banner line '{s}' x{d}\n", .{ l.str(), l.scale });
            return error.BannerTooWide;
        }
        const r = b.rect();
        try testing.expect(r.x0 >= render.margin and r.x1 <= render.screen_w - render.margin);
        try testing.expect(r.y0 >= render.arena_y and r.y1 <= render.screen_h - render.margin);
    }
    for ([_]render.Line{ v.hud.left, v.hud.right }) |l| try testing.expect(l.len * render.font5.advance <= 72);
}

test "every banner fits inside the 2 px screen margin" {
    const g = &tg;
    g.init(7);
    try check_view(g);
    tap(g, press_a);
    try check_view(g);
    g.opts = .{ .speed = .fast, .snake = true, .gaps = true, .wrap = true, .hardcore = true };
    try check_view(g);
    g.state = .options;
    try check_view(g);
    g.state = .skirmish_setup;
    for (0..layouts.count) |l| {
        g.sk.layout = @intCast(l);
        g.sk.tier = @intCast(l % 4);
        try check_view(g);
    }
    tap(g, .{ .down = true });
    tap(g, press_a);
    try check_view(g);
    // Every level's intro, countdown, play, clear, derez, game over, pause.
    var n: u32 = 1;
    while (n <= 14) : (n += 1) {
        g.opts = if (n % 2 == 0) .{} else .{ .speed = .slow, .snake = true, .gaps = true, .wrap = true, .hardcore = true };
        g.new_game(n);
        try check_view(g);
        g.state = .countdown;
        try check_view(g);
        g.resuming = true;
        g.snapshots = @intCast(n % 4);
        try check_view(g);
        g.state = .clear;
        g.tally_from = 0;
        g.score = 999_999;
        g.life_back = true;
        g.timer = tuning.tally_life_tick;
        try check_view(g);
        g.state = .game_over;
        g.new_high = n % 2 == 0;
        g.quit = n % 3 == 0;
        g.bonus = 6000;
        g.timer = tuning.game_over_min_ticks;
        try check_view(g);
        g.state = .paused;
        try check_view(g);
        g.state = .rewind;
        g.rewind_cy = if (n % 2 == 0) 30 else 100;
        g.world.tick = 3539;
        try check_view(g);
    }
    for ([_]State{ .derez, .frozen }) |st| {
        g.state = st;
        for (std.enums.values(sim.Crash)) |c| {
            g.crash = c;
            for (0..4) |s| {
                g.snapshots = @intCast(s);
                try check_view(g);
            }
        }
    }
    g.timed_out = true;
    g.state = .derez;
    try check_view(g);
    g.state = .play;
    g.timer = tuning.run_banner_ticks;
    g.sudden_death_tick = g.world.tick;
    try check_view(g);
    // SKIRMISH: intro with standings, round over, match over, watching.
    g.sk = .{ .programs = 3, .tier = 3, .layout = 6 };
    g.new_match();
    g.sk.round = 12;
    g.sk.wins = .{ 2, 3, 1, 0 };
    g.sk.points = .{ 99, 12, 7, 0 };
    try check_view(g);
    for ([_]u8{ 0, 1, 2, 3, sim.no_cycle }) |w| {
        g.sk.winner = w;
        g.state = .round_over;
        try check_view(g);
        g.state = .match_over;
        g.timer = tuning.game_over_min_ticks;
        try check_view(g);
    }
    g.state = .derez;
    g.timed_out = false;
    g.timer = 0;
    try check_view(g);
    g.timer = tuning.derez_ticks;
    try check_view(g);
}

test "LINK DUEL: every screen's banner fits; the lobby, a demo duel to the match card" {
    const g = &tg;
    g.init(31);
    g.enter_link();
    const lk = &g.lk;
    for (std.enums.values(LinkStatus)) |st| {
        lk.status = st;
        for ([_]bool{ false, true }) |host| {
            lk.host = host;
            lk.heard = null;
            try check_view(g);
            lk.heard = lk.rules();
            lk.can_go = host;
            try check_view(g);
            lk.resync = true;
            try check_view(g);
            lk.resync = false;
            for ([_]u8{ 'B', 'G', 'X' }) |app| {
                lk.partner_app = app;
                try check_view(g);
            }
        }
    }
    // The host's rows change the rules; the guest decodes them back.
    lk.status = .lobby;
    lk.host = true;
    lk.can_go = true;
    tap(g, .{ .down = true }); // START -> ARENA
    try testing.expectEqual(LinkRow.arena, lk.row);
    tap(g, .{ .right = true });
    tap(g, .{ .down = true });
    tap(g, .{ .right = true }); // FAST
    for (0..4) |_| {
        tap(g, .{ .down = true });
        tap(g, press_a);
    }
    tap(g, .{ .down = true });
    tap(g, .{ .left = true }); // FIRST TO 2
    var copy_lk: Link = .{};
    copy_lk.set_rules(lk.rules());
    try testing.expectEqual(@as(u8, 1), copy_lk.layout);
    try testing.expect(std.meta.eql(copy_lk.opts, levels.Options{ .speed = .fast, .snake = true, .gaps = true, .wrap = true, .hardcore = true }));
    try testing.expectEqual(@as(u8, 2), copy_lk.first_to);
    try check_view(g);
    // START asks the lockstep to go.
    tap(g, .{ .start = true });
    try testing.expect(lk.want_go);
    lk.want_go = false;
    // A demo duel (the partner's slot ridden by T2) to the match card.
    g.autopilot = 3;
    g.duel_demo(77);
    try testing.expectEqual(Mode.link, g.mode);
    try testing.expectEqual(@as(u8, 2), g.world.cfg.n_cycles);
    var t: u32 = 0;
    var seen_round_over = false;
    while (g.state != .match_over and t < 60 * 60 * 30) : (t += 1) {
        g.update(.{}, .{});
        if (g.state == .round_over) seen_round_over = true;
        if (t % 97 == 0) try check_view(g);
    }
    try testing.expect(seen_round_over);
    try testing.expectEqual(State.match_over, g.state);
    try testing.expect(lk.wins[0] == lk.first_to or lk.wins[1] == lk.first_to);
    g.timer = tuning.game_over_min_ticks;
    try check_view(g);
    lk.paused = true;
    try check_view(g);
    lk.paused = false;
    lk.status = .waiting;
    try check_view(g);
    // The guest's view: colours swapped.
    lk.slot = 1;
    try testing.expect(g.view().swap);
    for ([_]LinkNotice{ .peer_left, .no_contest }) |k| {
        lk.notice = k;
        g.state = .link_notice;
        try check_view(g);
    }
}
