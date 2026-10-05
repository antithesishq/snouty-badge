//! The Raspberry Trail game engine: a port of reference/oregon.bas (MECC,
//! 1978) as a resumable state machine. No cart API; host testable.
//!
//! The BASIC program runs straight through, printing lines and stopping
//! at each INPUT. Here `start` and `answer` run it from one INPUT to the
//! next: they append the printed lines to `lines` and leave the INPUT it
//! stopped at in `prompt`. SPEC.md section 3 is the contract.
//!
//! THIS FILE IS THE INTERFACE (written by the lead in the plan commit).
//! The types and the pub functions below are fixed; fields and helpers
//! may be added. Renaming or removing anything public needs the lead.
//!
//! The port (`run`) is a labeled switch over the listing's line numbers:
//! each prong is a jump target and runs straight-line BASIC until a GOTO
//! (`continue :sw`), an INPUT (`ask`, which records the line in `pc`) or
//! the STOP. Every expression keeps the listing's operator order, so the
//! f64 values are bit-identical to an interpreter running the listing.
const std = @import("std");
pub const rng = @import("rng.zig");

/// One of the four shooting words (BASIC S$(1..4)).
pub const Word = enum(u8) {
    bang = 1,
    blam = 2,
    pow = 3,
    wham = 4,

    pub fn text(w: Word) []const u8 {
        return switch (w) {
            .bang => "BANG",
            .blam => "BLAM",
            .pow => "POW",
            .wham => "WHAM",
        };
    }
};

pub const PromptKind = enum(u8) {
    /// INPUT C$ answered YES or NO (lines 190, 5220, 5240, 5260).
    yes_no,
    /// INPUT of a dollar amount (lines 860..1090, 2330). The badge UI
    /// offers `min..max` with `default` preselected (SPEC 4.3).
    number,
    /// INPUT of a menu number (lines 760, 2100, 2180, 2770, 3000).
    /// `options[0..n_options]` are short labels; answer 1-based.
    choice,
    /// The shooting subroutine's INPUT (line 6220): show `word`.
    shoot,
    /// STOP or END was reached: dead (`outcome`) or arrived.
    game_over,
};

pub const Prompt = struct {
    kind: PromptKind = .game_over,
    /// The BASIC line number of the INPUT (6220 for every shot, 0 for
    /// game_over). The oracle transcript keys on it.
    line: u16 = 0,
    /// A short question for the UI's prompt box (at most 2 x 26 chars),
    /// e.g. "SPEND ON OXEN?", "WHAT NEXT?". The original's own question
    /// text is in `lines` (tagged .question).
    question: []const u8 = "",
    /// .choice: labels, at most 5, each at most 22 chars ("HUNT").
    options: [5][]const u8 = @splat(""),
    n_options: u8 = 0,
    /// .choice: the option the cursor starts on (1-based).
    default_choice: u8 = 1,
    /// .number: spinner bounds and start value (the UI clamps to these,
    /// so the original's re-ask messages are unreachable from the badge
    /// but stay in the engine for the oracle).
    min: i32 = 0,
    max: i32 = 0,
    default: i32 = 0,
    /// .shoot: the word, and why we are shooting (for the scene art).
    word: Word = .bang,
    shot: ShotReason = .hunt,
    /// .game_over
    outcome: Outcome = .none,
};

pub const ShotReason = enum(u8) { hunt, riders, bandits, animals };

pub const Outcome = enum(u8) {
    none,
    arrived,
    starved, // 5060
    no_doctor_money, // 5080 -> "YOU CAN'T AFFORD A DOCTOR" + died of ...
    no_medicine, // 5110 -> died of ...
    pneumonia, // 5120 with K8=0 (wolves path sets K8=1 -> injuries)
    injuries, // 5120 with K8=1
    winter, // 1690 blizzard of winter
    massacred, // 3520 out of bullets vs riders
    snakebite, // 4260
};

/// What a printed line is, for the UI's routing and the M2 pictures.
/// The oracle transcript ignores tags (it prints every line's text).
pub const Tag = enum(u8) {
    plain,
    /// An instructions page line (lines 240-680).
    instructions,
    /// The question an INPUT asks; the UI shows `Prompt.question` in
    /// the prompt box instead and may leave this out of the log.
    question,
    /// "MONDAY APRIL 12 1847" (and the arrival date).
    date,
    /// "TOTAL MILEAGE IS 950"
    mileage,
    /// The two status-table lines (header, values); the HUD shows them.
    status_header,
    status_values,
    warning, // low food, doctor's bill, not enough bullets
    // Events (the M2 vignette for the line that starts the event):
    wagon_breaks,
    ox_injured,
    daughter_arm,
    ox_wanders,
    son_lost,
    bad_water,
    heavy_rain,
    bandits,
    fire,
    fog,
    snake,
    river,
    wild_animals,
    cold,
    hail,
    illness,
    helpful_food, // 4670
    riders,
    hunt_result,
    fort,
    mountains,
    blizzard,
    south_pass,
    death,
    funeral,
    arrival,
    letter, // the closing letters (Chamber of Commerce, President Polk)
    bell, // a line the listing marks with bells (2660, 5470, 5480)
};

pub const Line = struct {
    tag: Tag = .plain,
    /// Upper case, as the original prints it, whitespace as printed
    /// (TAB() and print zones expanded to spaces). Owned by `Game.text`.
    text: []const u8,
};

pub const Answer = union(PromptKind) {
    yes_no: bool,
    number: i32,
    choice: u8,
    /// `correct`: every button of the sequence pressed right (else the
    /// original's wrong word: B1=9). `seconds`: time from the cue to the
    /// last press, already scaled (SPEC 4.4); the engine feeds it to line
    /// 6240 as CLK(0) differences: B1 = ((secs/3600 - 0) * 3600) - (D9-1).
    shoot: struct { correct: bool, seconds: f64 },
    game_over: void,
};

/// The values the HUD shows, as the original last printed them (so the
/// "TOTAL MILEAGE IS 950" quirk after South Pass shows too).
pub const Hud = struct {
    /// Turn number D3 (0 = the start, MARCH 29). date_text is the printed date
    /// ("MARCH 29 1847", "APRIL 12 1847").
    turn: u8 = 0,
    date_text: []const u8 = "MARCH 29 1847",
    mileage_shown: i32 = 0,
    /// The true mileage M (for the M2 trail strip; INT(M), >= 0).
    mileage_true: i32 = 0,
    food: i32 = 0,
    bullets: i32 = 0,
    clothing: i32 = 0,
    misc: i32 = 0,
    cash: i32 = 0,
    /// The status table has been printed at least once.
    valid: bool = false,
};

/// Every BASIC numeric variable the program uses, same names, f64 like
/// the original's floats. The oracle snapshots these at each INPUT.
pub const Vars = struct {
    A: f64 = 0,
    B: f64 = 0,
    B1: f64 = 0,
    B3: f64 = 0,
    C: f64 = 0,
    C1: f64 = 0,
    D: f64 = 0,
    D1: f64 = 0,
    D3: f64 = 0,
    D9: f64 = 0,
    E: f64 = 0,
    F: f64 = 0,
    F1: f64 = 0,
    F2: f64 = 0,
    F9: f64 = 0,
    K8: f64 = 0,
    L1: f64 = 0,
    M: f64 = 0,
    M1: f64 = 0,
    M2: f64 = 0,
    M9: f64 = 0,
    P: f64 = 0,
    R1: f64 = 0,
    S4: f64 = 0,
    S5: f64 = 0,
    S6: f64 = 0,
    T: f64 = 0,
    T1: f64 = 0,
    X: f64 = 0,
    X1: f64 = 0,
};

/// The longest stretch between two INPUTs is the instructions page (190 ->
/// 760: 56 lines, about 2.4 KB); a turn prints far less.
pub const max_lines = 96;
pub const text_bytes = 6144;

pub const Game = struct {
    v: Vars = .{},
    rng: rng.Rng = .{},
    /// Lines printed since the last `start`/`answer` (oldest first).
    lines: [max_lines]Line = undefined,
    n_lines: usize = 0,
    text: [text_bytes]u8 = undefined,
    text_len: usize = 0,
    prompt: Prompt = .{},
    hud: Hud = .{},
    /// Where `answer` resumes: the BASIC line number of the pending INPUT
    /// (0 before `start` and after the STOP).
    pc: u16 = 0,

    // ---- engine state (track L additions) ----
    /// RND(-1) draws so far (tests count them per turn).
    draws: u32 = 0,
    /// Set if a line or its text did not fit in `lines`/`text` (never in
    /// practice; the tests assert it stays false).
    overflow: bool = false,
    /// The GOSUB return lines (the two subroutines never nest).
    ret_fort: u16 = 0, // GOSUB 2330
    ret_shoot: u16 = 0, // GOSUB 6140
    /// C$ was "YES" (yes_no prompts; the shot word check uses `shot_ok`).
    cs_yes: bool = false,
    /// The death or arrival cause, by the first cause line executed.
    outcome: Outcome = .none,
    /// The open (partial) output line: a PRINT that ended with `;`.
    line_open: bool = false,
    line_start: usize = 0,
    line_tag: Tag = .plain,
    /// `hud.date_text` storage for the arrival date ("AUGUST 3 1847").
    hud_date: [24]u8 = undefined,
    /// Tests: RND(-1) values to return before the generator's (consumed
    /// one per draw). Empty in play.
    rnd_script: []const f64 = &.{},

    pub fn printed(g: *const Game) []const Line {
        return g.lines[0..g.n_lines];
    }
};

/// A new game with this seed (RND draws come from rng.Rng.init(seed)).
pub fn init(g: *Game, seed: u64) void {
    g.* = .{};
    g.rng = rng.Rng.init(seed);
}

/// Runs from the first line to the first INPUT (line 190).
pub fn start(g: *Game) void {
    g.n_lines = 0;
    g.text_len = 0;
    g.line_open = false;
    run(g, 160, null);
}

/// Answers the current prompt and runs to the next INPUT (or STOP).
/// The answer must match `g.prompt.kind`; .number is not range checked
/// here (the original's own checks run).
pub fn answer(g: *Game, a: Answer) void {
    std.debug.assert(std.meta.activeTag(a) == g.prompt.kind);
    const in: In = switch (a) {
        .yes_no => |y| .{ .yes = y },
        .number => |n| .{ .num = @floatFromInt(n) },
        .choice => |c| .{ .num = @floatFromInt(c) },
        .shoot => |s| .{ .shot = .{ .correct = s.correct, .seconds = s.seconds } },
        .game_over => return,
    };
    resume_with(g, in);
}

/// Answers a .number or .choice prompt with any value the BASIC INPUT
/// could get (negative or out of range choices, numbers beyond i32). The
/// oracle runner uses it for the answers `Answer` cannot carry.
pub fn answer_value(g: *Game, x: f64) void {
    std.debug.assert(g.prompt.kind == .number or g.prompt.kind == .choice);
    resume_with(g, .{ .num = x });
}

/// Tests and bench setups: clears the output and runs the listing from
/// `line`, which must be one of the port's jump targets (a prong of `run`,
/// e.g. 1230 a new turn, 1750 the turn's status, 2720 the eating check,
/// 3550 the events, 4710 the mountains, 6300 an illness), with `g.v` as
/// the caller left it, to the next INPUT or STOP.
pub fn run_at(g: *Game, line: u16) void {
    g.n_lines = 0;
    g.text_len = 0;
    g.line_open = false;
    run(g, line, null);
}

/// Appends a printed line (helper for the engine).
pub fn print(g: *Game, tag: Tag, comptime fmt: []const u8, args: anytype) void {
    if (g.n_lines == max_lines) {
        g.overflow = true;
        return;
    }
    const s = std.fmt.bufPrint(g.text[g.text_len..], fmt, args) catch {
        g.overflow = true;
        return;
    };
    g.lines[g.n_lines] = .{ .tag = tag, .text = s };
    g.n_lines += 1;
    g.text_len += s.len;
}

// ------------------------------------------------------------- output ----

/// PRINT "s"; (no newline): appends to the open line, or opens one. A
/// segment with a tag other than .plain retags the line (1690's death
/// message lands on the "MONDAY " line).
fn out(g: *Game, tag: Tag, s: []const u8) void {
    if (!g.line_open) {
        g.line_open = true;
        g.line_start = g.text_len;
        g.line_tag = tag;
    } else if (tag != .plain) g.line_tag = tag;
    const room = text_bytes - g.text_len;
    if (s.len > room) {
        g.overflow = true;
        return;
    }
    @memcpy(g.text[g.text_len..][0..s.len], s);
    g.text_len += s.len;
}

/// Ends the current output line (a PRINT without a trailing `;`). With no
/// open line it emits an empty one.
fn endl(g: *Game) void {
    if (!g.line_open) {
        g.line_start = g.text_len;
        g.line_tag = .plain;
    }
    g.line_open = false;
    if (g.n_lines == max_lines) {
        g.overflow = true;
        return;
    }
    g.lines[g.n_lines] = .{ .tag = g.line_tag, .text = g.text[g.line_start..g.text_len] };
    g.n_lines += 1;
}

/// PRINT "s"
fn say(g: *Game, tag: Tag, s: []const u8) void {
    out(g, tag, s);
    endl(g);
}

/// An empty PRINT, tagged.
fn blank(g: *Game, tag: Tag) void {
    if (!g.line_open) {
        g.line_open = true;
        g.line_start = g.text_len;
        g.line_tag = tag;
    }
    endl(g);
}

/// A number as PRINT shows it. The listing only prints integral values
/// (with integral answers); the leading sign space and trailing space of
/// BASIC's number format are left out (the transcript collapses them).
fn num(g: *Game, x: f64) void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{sat_i64(x)}) catch unreachable;
    out(g, .plain, s);
}

/// Pads the open line with spaces to `col` (TAB(col), print zones).
fn pad_to(g: *Game, col: usize) void {
    while (g.text_len - g.line_start < col) out(g, .plain, " ");
}

/// PRINT a,b,c,d,e in 15-column zones.
fn zone(g: *Game, tag: Tag, k: usize) void {
    if (!g.line_open) out(g, tag, "");
    pad_to(g, k * 15);
}

fn sat_i64(x: f64) i64 {
    if (!(x == x)) return 0;
    if (x >= 9.2e18) return std.math.maxInt(i64);
    if (x <= -9.2e18) return std.math.minInt(i64);
    return @intFromFloat(@trunc(x));
}

fn sat_i32(x: f64) i32 {
    if (!(x == x)) return 0;
    if (x >= 2147483647.0) return std.math.maxInt(i32);
    if (x <= -2147483648.0) return std.math.minInt(i32);
    return @intFromFloat(@trunc(x));
}

// ---------------------------------------------------------------- port ----

/// A pending INPUT's value.
const In = union(enum) {
    yes: bool,
    num: f64,
    shot: struct { correct: bool, seconds: f64 },
};

fn resume_with(g: *Game, in: In) void {
    g.n_lines = 0;
    g.text_len = 0;
    g.line_open = false;
    if (g.pc == 0) return; // game over
    run(g, g.pc, in);
}

fn rnd(g: *Game) f64 {
    g.draws += 1;
    if (g.rnd_script.len > 0) {
        const x = g.rnd_script[0];
        g.rnd_script = g.rnd_script[1..];
        return x;
    }
    return g.rng.rnd();
}

/// INT
fn int(x: f64) f64 {
    return @floor(x);
}

/// X**2 as the listing uses it (lines 2890, 4720).
fn sq(x: f64) f64 {
    return x * x;
}

/// ON X GOTO with n targets: the 1-based target, or null (falls through).
fn on(x: f64, n: usize) ?usize {
    const i = @floor(x);
    if (!(i >= 1) or i > @as(f64, @floatFromInt(n))) return null;
    return @intFromFloat(i);
}

/// Stops at an INPUT: closes the open line (the user's RETURN ends it),
/// sets the prompt and the resume line.
fn ask(g: *Game, p: Prompt) void {
    if (g.line_open) endl(g);
    g.prompt = p;
    g.pc = p.line;
}

fn ask_number(g: *Game, line: u16, q: []const u8, min: i32, max_: f64, def: i32) void {
    const max = @max(min, sat_i32(@floor(max_)));
    ask(g, .{ .kind = .number, .line = line, .question = q, .min = min, .max = max, .default = std.math.clamp(def, min, max) });
}

fn ask_choice(g: *Game, line: u16, q: []const u8, labels: []const []const u8, def: u8) void {
    var p: Prompt = .{ .kind = .choice, .line = line, .question = q, .n_options = @intCast(labels.len), .default_choice = def };
    for (labels, 0..) |l, i| p.options[i] = l;
    ask(g, p);
}

fn ask_yes(g: *Game, line: u16, q: []const u8) void {
    ask(g, .{ .kind = .yes_no, .line = line, .question = q });
}

fn stop(g: *Game) void {
    if (g.line_open) endl(g);
    g.prompt = .{ .kind = .game_over, .line = 0, .question = "", .outcome = g.outcome };
    g.pc = 0;
}

fn set_outcome(g: *Game, o: Outcome) void {
    if (g.outcome == .none) g.outcome = o;
}

const instructions = [_][]const u8{
    "THIS PROGRAM SIMULATES A TRIP OVER THE OREGON TRAIL FROM",
    "INDEPENDENCE, MISSOURI TO OREGON CITY, OREGON IN 1847.",
    "YOUR FAMILY OF FIVE WILL COVER THE 2040 MILE OREGON TRAIL",
    "IN 5-6 MONTHS --- IF YOU MAKE IT ALIVE.",
    "",
    "YOU HAD SAVED $900 TO SPEND FOR THE TRIP, AND YOU'VE JUST",
    "   PAID $200 FOR A WAGON.",
    "YOU WILL NEED TO SPEND THE REST OF YOUR MONEY ON THE",
    "   FOLLOWING ITEMS:",
    "",
    "     OXEN - YOU CAN SPEND $200-$300 ON YOUR TEAM",
    "            THE MORE YOU SPEND, THE FASTER YOU'LL GO",
    "            BECAUSE YOU'LL HAVE BETTER ANIMALS",
    "",
    "     FOOD - THE MORE YOU HAVE, THE LESS CHANCE THERE",
    "            IS OF GETTING SICK",
    "",
    "AMMUNITION - $1 BUYS A BELT OF 50 BULLETS",
    "            YOU WILL NEED BULLETS FOR ATTACKS BY ANIMALS",
    "            AND BANDITS, AND FOR HUNTING FOOD",
    "",
    "CLOTHING - THIS IS ESPECIALLY IMPORTANT FOR THE COLD",
    "            WEATHER YOU WILL ENCOUNTER WHEN CROSSING",
    "            THE MOUNTAINS",
    "",
    "MISCELLANEOUS SUPPLIES - THIS INCLUDES MEDICINE AND",
    "            OTHER THINGS YOU WILL NEED FOR SICKNESS",
    "            AND EMERGENCY REPAIRS",
    "",
    "",
    "YOU CAN SPEND ALL YOUR MONEY BEFORE YOU START YOUR TRIP -",
    "OR YOU CAN SAVE SOME OF YOUR CASH TO SPEND AT FORTS ALONG",
    "THE WAY WHEN YOU RUN LOW. HOWEVER, ITEMS COST MORE AT",
    "THE FORTS. YOU CAN ALSO GO HUNTING ALONG THE WAY TO GET",
    "MORE FOOD.",
    "WHENEVER YOU HAVE TO USE YOUR TRUSTY RIFLE ALONG THE WAY,",
    "YOU WILL BE TOLD TO TYPE IN A WORD (ONE THAT SOUNDS LIKE A",
    "GUN SHOT). THE FASTER YOU TYPE IN THAT WORD AND HIT THE",
    // Line 620 as intended (SPEC 1: the transcription's one defect).
    "\"RETURN\" KEY, THE BETTER LUCK YOU'LL HAVE WITH YOUR GUN.",
    "",
    "AT EACH TURN, ALL ITEMS ARE SHOWN IN DOLLAR AMOUNTS",
    "EXCEPT BULLETS",
    "WHEN ASKED TO ENTER MONEY AMOUNTS, DON'T USE A \"$\".",
    "",
    "GOOD LUCK!!!",
};

/// Lines 1310-1670: the date of turn D3 = 1..19 (printed "MONDAY " ++
/// month ++ " " ++ day ++ " " ++ "1847"; HUD form below).
const turn_dates = [_][]const u8{
    "APRIL 12",   "APRIL 26",     "MAY 10",       "MAY 24",      "JUNE 7",
    "JUNE 21",    "JULY 5",       "JULY 19",      "AUGUST 2",    "AUGUST 16",
    "AUGUST 31",  "SEPTEMBER 13", "SEPTEMBER 27", "OCTOBER 11",  "OCTOBER 25",
    "NOVEMBER 8", "NOVEMBER 22",  "DECEMBER 6",   "DECEMBER 20",
};
const turn_dates_hud = [_][]const u8{
    "APRIL 12 1847",   "APRIL 26 1847",     "MAY 10 1847",       "MAY 24 1847",      "JUNE 7 1847",
    "JUNE 21 1847",    "JULY 5 1847",       "JULY 19 1847",      "AUGUST 2 1847",    "AUGUST 16 1847",
    "AUGUST 31 1847",  "SEPTEMBER 13 1847", "SEPTEMBER 27 1847", "OCTOBER 11 1847",  "OCTOBER 25 1847",
    "NOVEMBER 8 1847", "NOVEMBER 22 1847",  "DECEMBER 6 1847",   "DECEMBER 20 1847",
};

const weekdays = [_][]const u8{ "MONDAY ", "TUESDAY ", "WEDNESDAY ", "THURSDAY ", "FRIDAY ", "SATURDAY ", "SUNDAY " };

/// Line 3620.
const event_data = [_]f64{ 6, 11, 13, 15, 17, 22, 32, 35, 37, 42, 44, 54, 64, 69, 95 };

const marksman_labels = [_][]const u8{ "ACE MARKSMAN", "GOOD SHOT", "FAIR TO MIDDLIN'", "NEED MORE PRACTICE", "SHAKY KNEES" };
const fort_labels = [_][]const u8{ "STOP AT THE NEXT FORT", "HUNT", "CONTINUE" };
const hunt_labels = [_][]const u8{ "HUNT", "CONTINUE" };
const eat_labels = [_][]const u8{ "POORLY", "MODERATELY", "WELL" };
const tactics_labels = [_][]const u8{ "RUN", "ATTACK", "CONTINUE", "CIRCLE WAGONS" };

fn status_header(g: *Game, tag: Tag) void {
    const items = [_][]const u8{ "FOOD", "BULLETS", "CLOTHING", "MISC. SUPP.", "CASH" };
    for (items, 0..) |s, k| {
        zone(g, tag, k);
        out(g, tag, s);
    }
    endl(g);
}

fn status_values(g: *Game, tag: Tag, vals: [5]f64) void {
    for (vals, 0..) |x, k| {
        zone(g, tag, k);
        num(g, x);
    }
    endl(g);
    g.hud.food = sat_i32(vals[0]);
    g.hud.bullets = sat_i32(vals[1]);
    g.hud.clothing = sat_i32(vals[2]);
    g.hud.misc = sat_i32(vals[3]);
    g.hud.cash = sat_i32(vals[4]);
    g.hud.valid = true;
    g.hud.mileage_true = @max(0, sat_i32(int(g.v.M)));
}

/// GOSUB 6140 (the shot) returning to `ret`.
fn shot_reason(ret: u16) ShotReason {
    return switch (ret) {
        2590 => .hunt,
        3130, 3300 => .riders,
        3980 => .bandits,
        else => .animals, // 4360
    };
}

/// Runs the listing from `line` until the next INPUT or STOP. `in_arg` is
/// the value for the INPUT at `line` when resuming there.
fn run(g: *Game, line: u16, in_arg: ?In) void {
    var in = in_arg;
    const v = &g.v;
    sw: switch (line) {
        160 => {
            say(g, .question, "DO YOU NEED INSTRUCTIONS  (YES/NO)");
            continue :sw 190;
        },
        190 => {
            const x = in orelse return ask_yes(g, 190, "NEED INSTRUCTIONS?");
            in = null;
            g.cs_yes = x.yes;
            if (!g.cs_yes) continue :sw 690; // 200 IF C$="NO"
            blank(g, .plain);
            blank(g, .plain);
            for (instructions) |s| say(g, .instructions, s);
            continue :sw 690;
        },
        690 => {
            blank(g, .plain);
            blank(g, .plain);
            say(g, .question, "HOW GOOD A SHOT ARE YOU WITH YOUR RIFLE?");
            say(g, .question, "  (1) ACE MARKSMAN,  (2) GOOD SHOT,  (3) FAIR TO MIDDLIN'");
            say(g, .question, "         (4) NEED MORE PRACTICE,  (5) SHAKY KNEES");
            say(g, .plain, "ENTER ONE OF THE ABOVE -- THE BETTER YOU CLAIM YOU ARE, THE");
            say(g, .plain, "FASTER YOU'LL HAVE TO BE WITH YOUR GUN TO BE SUCCESSFUL.");
            continue :sw 760;
        },
        760 => {
            const x = in orelse return ask_choice(g, 760, "HOW GOOD A SHOT ARE YOU?", &marksman_labels, 3);
            in = null;
            v.D9 = x.num;
            if (v.D9 > 5) v.D9 = 0; // 770-790
            v.X1 = -1; // 810
            // 820 K8=S4=F1=F2=M=M9=D3=0
            v.K8 = 0;
            v.S4 = 0;
            v.F1 = 0;
            v.F2 = 0;
            v.M = 0;
            v.M9 = 0;
            v.D3 = 0;
            continue :sw 830;
        },
        830 => {
            blank(g, .plain);
            blank(g, .plain);
            continue :sw 850;
        },
        850 => {
            out(g, .question, "HOW MUCH DO YOU WANT TO SPEND ON YOUR OXEN TEAM");
            continue :sw 860;
        },
        860 => {
            const x = in orelse return ask_number(g, 860, "SPEND ON OXEN?", 200, 300, 200);
            in = null;
            v.A = x.num;
            if (!(v.A >= 200)) {
                say(g, .plain, "NOT ENOUGH");
                continue :sw 850;
            }
            if (!(v.A <= 300)) {
                say(g, .plain, "TOO MUCH");
                continue :sw 850;
            }
            continue :sw 930;
        },
        930 => {
            out(g, .question, "HOW MUCH DO YOU WANT TO SPEND ON FOOD");
            continue :sw 940;
        },
        940 => {
            const x = in orelse return ask_number(g, 940, "SPEND ON FOOD?", 0, 700 - v.A, 0);
            in = null;
            v.F = x.num;
            if (v.F >= 0) continue :sw 980;
            say(g, .plain, "IMPOSSIBLE");
            continue :sw 930;
        },
        980 => {
            out(g, .question, "HOW MUCH DO YOU WANT TO SPEND ON AMMUNITION");
            continue :sw 990;
        },
        990 => {
            const x = in orelse return ask_number(g, 990, "SPEND ON AMMUNITION?", 0, 700 - v.A - v.F, 0);
            in = null;
            v.B = x.num;
            if (v.B >= 0) continue :sw 1030;
            say(g, .plain, "IMPOSSIBLE");
            continue :sw 980;
        },
        1030 => {
            out(g, .question, "HOW MUCH DO YOU WANT TO SPEND ON CLOTHING");
            continue :sw 1040;
        },
        1040 => {
            const x = in orelse return ask_number(g, 1040, "SPEND ON CLOTHING?", 0, 700 - v.A - v.F - v.B, 0);
            in = null;
            v.C = x.num;
            if (v.C >= 0) continue :sw 1080;
            say(g, .plain, "IMPOSSIBLE");
            continue :sw 1030;
        },
        1080 => {
            out(g, .question, "HOW MUCH DO YOU WANT TO SPEND ON MISCELLANEOUS SUPPLIES");
            continue :sw 1090;
        },
        1090 => {
            const x = in orelse return ask_number(g, 1090, "SPEND ON MISC. SUPPLIES?", 0, 700 - v.A - v.F - v.B - v.C, 0);
            in = null;
            v.M1 = x.num;
            if (v.M1 >= 0) continue :sw 1130;
            say(g, .plain, "IMPOSSIBLE");
            continue :sw 1080;
        },
        1130 => {
            v.T = 700 - v.A - v.F - v.B - v.C - v.M1;
            if (!(v.T >= 0)) {
                say(g, .plain, "YOU OVERSPENT--YOU ONLY HAD $700 TO SPEND.  BUY AGAIN");
                continue :sw 830;
            }
            v.B = 50 * v.B; // 1170
            out(g, .plain, "AFTER ALL YOUR PURCHASES, YOU NOW HAVE ");
            num(g, v.T);
            out(g, .plain, " DOLLARS LEFT");
            endl(g);
            blank(g, .plain);
            say(g, .date, "MONDAY MARCH 29 1847");
            g.hud.turn = 0;
            g.hud.date_text = "MARCH 29 1847";
            blank(g, .plain);
            continue :sw 1750;
        },
        1230 => {
            if (v.M >= 2040) continue :sw 5430;
            v.D3 = v.D3 + 1; // 1250
            blank(g, .plain);
            out(g, .date, "MONDAY ");
            // 1280-1300: ON D3 / ON D3-10; out of range falls through to 1310.
            var k: ?usize = null;
            if (!(v.D3 > 10)) k = on(v.D3, 10);
            if (k == null) if (on(v.D3 - 10, 10)) |i| {
                k = 10 + i;
            };
            const t = k orelse 1;
            if (t == 20) continue :sw 1690;
            out(g, .date, turn_dates[t - 1]);
            out(g, .date, " ");
            say(g, .date, "1847"); // 1720
            g.hud.turn = @intCast(t);
            g.hud.date_text = turn_dates_hud[t - 1];
            blank(g, .plain); // 1730
            continue :sw 1750;
        },
        1690 => {
            set_outcome(g, .winter);
            say(g, .death, "YOU HAVE BEEN ON THE TRAIL TOO LONG  ------");
            say(g, .death, "YOUR FAMILY DIES IN THE FIRST BLIZZARD OF WINTER");
            continue :sw 5170;
        },
        1750 => {
            if (!(v.F >= 0)) v.F = 0;
            if (!(v.B >= 0)) v.B = 0;
            if (!(v.C >= 0)) v.C = 0;
            if (!(v.M1 >= 0)) v.M1 = 0;
            if (!(v.F >= 13)) say(g, .warning, "YOU'D BETTER DO SOME HUNTING OR BUY FOOD AND SOON!!!!");
            v.F = int(v.F);
            v.B = int(v.B);
            v.C = int(v.C);
            v.M1 = int(v.M1);
            v.T = int(v.T);
            v.M = int(v.M);
            v.M2 = v.M; // 1910
            if (v.S4 == 1 or v.K8 == 1) {
                v.T = v.T - 20; // 1950
                if (v.T < 0) continue :sw 5080;
                say(g, .warning, "DOCTOR'S BILL IS $20");
                v.K8 = 0; // 1980 LET K8=S4=0
                v.S4 = 0;
            }
            if (v.M9 == 1) {
                say(g, .mileage, "TOTAL MILEAGE IS 950"); // 2020
                v.M9 = 0;
                g.hud.mileage_shown = 950;
            } else {
                out(g, .mileage, "TOTAL MILEAGE IS ");
                num(g, v.M);
                endl(g);
                g.hud.mileage_shown = sat_i32(v.M);
            }
            status_header(g, .status_header);
            status_values(g, .status_values, .{ v.F, v.B, v.C, v.M1, v.T });
            if (v.X1 == -1) continue :sw 2170;
            v.X1 = v.X1 * (-1); // 2070
            continue :sw 2080;
        },
        2080 => {
            out(g, .question, "DO YOU WANT TO (1) STOP AT THE NEXT FORT, (2) HUNT, ");
            say(g, .question, "OR (3) CONTINUE");
            continue :sw 2100;
        },
        2100 => {
            const x = in orelse return ask_choice(g, 2100, "WHAT NEXT?", &fort_labels, 3);
            in = null;
            v.X = x.num;
            if (v.X > 2 or v.X < 1) {
                v.X = 3; // 2150
            } else {
                v.X = int(v.X); // 2130
            }
            continue :sw 2270;
        },
        2170 => {
            say(g, .question, "DO YOU WANT TO (1) HUNT, OR (2) CONTINUE");
            continue :sw 2180;
        },
        2180 => {
            const x = in orelse return ask_choice(g, 2180, "WHAT NEXT?", &hunt_labels, 2);
            in = null;
            v.X = x.num;
            if (v.X != 1) v.X = 2; // 2190-2200
            v.X = v.X + 1; // 2210
            if (v.X != 3 and !(v.B > 39)) {
                say(g, .warning, "TOUGH---YOU NEED MORE BULLETS TO GO HUNTING");
                continue :sw 2170;
            }
            v.X1 = v.X1 * (-1); // 2260
            continue :sw 2270;
        },
        2270 => {
            const k = on(v.X, 3) orelse 1; // out of range falls into 2290
            continue :sw switch (k) {
                1 => 2290,
                2 => 2540,
                else => 2720,
            };
        },
        2290 => {
            say(g, .fort, "ENTER WHAT YOU WISH TO SPEND ON THE FOLLOWING");
            out(g, .question, "FOOD");
            g.ret_fort = 2410; // 2310 GOSUB 2330, 2320 GOTO 2410
            continue :sw 2330;
        },
        2330 => {
            const q: []const u8 = switch (g.ret_fort) {
                2410 => "FORT: SPEND ON FOOD?",
                2440 => "FORT: SPEND ON AMMUNITION?",
                2470 => "FORT: SPEND ON CLOTHING?",
                else => "FORT: SPEND ON SUPPLIES?",
            };
            const x = in orelse return ask_number(g, 2330, q, 0, v.T, 0);
            in = null;
            v.P = x.num;
            if (!(v.P < 0)) {
                v.T = v.T - v.P;
                if (!(v.T >= 0)) {
                    say(g, .plain, "YOU DON'T HAVE THAT MUCH--KEEP YOUR SPENDING DOWN");
                    say(g, .plain, "YOU MISS YOUR CHANCE TO SPEND ON THAT ITEM");
                    v.T = v.T + v.P;
                    v.P = 0;
                }
            }
            continue :sw g.ret_fort; // 2400 RETURN
        },
        2410 => {
            v.F = v.F + 2.0 / 3.0 * v.P;
            out(g, .question, "AMMUNITION");
            g.ret_fort = 2440;
            continue :sw 2330;
        },
        2440 => {
            v.B = int(v.B + 2.0 / 3.0 * v.P * 50);
            out(g, .question, "CLOTHING");
            g.ret_fort = 2470;
            continue :sw 2330;
        },
        2470 => {
            v.C = v.C + 2.0 / 3.0 * v.P;
            out(g, .question, "MISCELLANEOUS SUPPLIES");
            g.ret_fort = 2500;
            continue :sw 2330;
        },
        2500 => {
            v.M1 = v.M1 + 2.0 / 3.0 * v.P;
            v.M = v.M - 45;
            continue :sw 2720;
        },
        2540 => {
            if (!(v.B > 39)) {
                say(g, .warning, "TOUGH---YOU NEED MORE BULLETS TO GO HUNTING");
                continue :sw 2080; // 2560
            }
            v.M = v.M - 45; // 2570
            g.ret_shoot = 2590;
            continue :sw 6140;
        },
        2590 => {
            if (v.B1 <= 1) {
                // 2660 (BELLS)
                say(g, .bell, "RIGHT BETWEEN THE EYES---YOU GOT A BIG ONE!!!!");
                say(g, .plain, "FULL BELLIES TONIGHT!");
                v.F = v.F + 52 + rnd(g) * 6;
                v.B = v.B - 10 - rnd(g) * 4;
                continue :sw 2720;
            }
            if (100 * rnd(g) < 13 * v.B1) {
                say(g, .hunt_result, "YOU MISSED---AND YOUR DINNER GOT AWAY.....");
                continue :sw 2720;
            }
            v.F = v.F + 48 - 2 * v.B1;
            say(g, .hunt_result, "NICE SHOT--RIGHT ON TARGET--GOOD EATIN' TONIGHT!!");
            v.B = v.B - 10 - 3 * v.B1;
            continue :sw 2720;
        },
        2720 => {
            if (v.F >= 13) continue :sw 2750;
            continue :sw 5060;
        },
        2750 => {
            say(g, .question, "DO YOU WANT TO EAT (1) POORLY  (2) MODERATELY");
            out(g, .question, "OR (3) WELL");
            continue :sw 2770;
        },
        2770 => {
            const x = in orelse return ask_choice(g, 2770, "HOW WELL DO YOU EAT?", &eat_labels, 2);
            in = null;
            v.E = x.num;
            if (v.E > 3 or v.E < 1) continue :sw 2750;
            v.E = int(v.E);
            v.F = v.F - 8 - 5 * v.E;
            if (v.F >= 0) continue :sw 2860;
            v.F = v.F + 8 + 5 * v.E;
            say(g, .plain, "YOU CAN'T EAT THAT WELL");
            continue :sw 2750;
        },
        2860 => {
            v.M = v.M + 200 + (v.A - 220) / 5 + 10 * rnd(g);
            v.L1 = 0; // 2870 L1=C1=0
            v.C1 = 0;
            // 2890
            const r = rnd(g);
            const q = v.M / 100 - 4;
            if (r * 10 * (sq(q) + 72) / (sq(q) + 12) > 1) continue :sw 3550;
            out(g, .riders, "RIDERS AHEAD.  THEY ");
            v.S5 = 0;
            if (!(rnd(g) < 0.8)) {
                out(g, .plain, "DON'T ");
                v.S5 = 1;
            }
            say(g, .plain, "LOOK HOSTILE");
            say(g, .question, "TACTICS");
            continue :sw 2970;
        },
        2970 => {
            say(g, .question, "(1) RUN  (2) ATTACK  (3) CONTINUE  (4) CIRCLE WAGONS");
            if (!(rnd(g) > 0.2)) v.S5 = 1 - v.S5;
            continue :sw 3000;
        },
        3000 => {
            const x = in orelse return ask_choice(g, 3000, "RIDERS! TACTICS?", &tactics_labels, 1);
            in = null;
            v.T1 = x.num;
            if (v.T1 < 1 or v.T1 > 4) continue :sw 2970;
            v.T1 = int(v.T1);
            if (v.S5 == 1) continue :sw 3330;
            if (v.T1 > 1) continue :sw 3110;
            v.M = v.M + 20;
            v.M1 = v.M1 - 15;
            v.B = v.B - 150;
            v.A = v.A - 40;
            continue :sw 3470;
        },
        3110 => {
            if (v.T1 > 2) continue :sw 3240;
            g.ret_shoot = 3130;
            continue :sw 6140;
        },
        3130 => {
            v.B = v.B - v.B1 * 40 - 80;
            continue :sw 3140;
        },
        3140 => {
            if (v.B1 > 1) {
                if (v.B1 <= 4) {
                    say(g, .plain, "KINDA SLOW WITH YOUR COLT .45"); // 3220
                    continue :sw 3470;
                }
                say(g, .plain, "LOUSY SHOT---YOU GOT KNIFED");
                v.K8 = 1;
                say(g, .plain, "YOU HAVE TO SEE OL' DOC BLANCHARD");
                continue :sw 3470;
            }
            say(g, .plain, "NICE SHOOTING---YOU DROVE THEM OFF");
            continue :sw 3470;
        },
        3240 => {
            if (v.T1 > 3) {
                g.ret_shoot = 3300; // 3290 GOSUB 6140
                continue :sw 6140;
            }
            if (rnd(g) > 0.8) {
                say(g, .plain, "THEY DID NOT ATTACK"); // 3450
                continue :sw 3550;
            }
            v.B = v.B - 150;
            v.M1 = v.M1 - 15;
            continue :sw 3470;
        },
        3300 => {
            v.B = v.B - v.B1 * 30 - 80;
            v.M = v.M - 25;
            continue :sw 3140;
        },
        3330 => {
            if (v.T1 > 1) {
                if (v.T1 > 2) {
                    if (v.T1 > 3) v.M = v.M - 20; // 3430
                    continue :sw 3470;
                }
                v.M = v.M - 5; // 3380
                v.B = v.B - 100;
                continue :sw 3470;
            }
            v.M = v.M + 15;
            v.A = v.A - 10;
            continue :sw 3470;
        },
        3470 => {
            if (v.S5 != 0) {
                say(g, .plain, "RIDERS WERE FRIENDLY, BUT CHECK FOR POSSIBLE LOSSES");
                continue :sw 3550;
            }
            say(g, .plain, "RIDERS WERE HOSTILE--CHECK FOR LOSSES");
            if (v.B >= 0) continue :sw 3550;
            set_outcome(g, .massacred);
            say(g, .death, "YOU RAN OUT OF BULLETS AND GOT MASSACRED BY THE RIDERS");
            continue :sw 5170;
        },
        3550 => {
            v.D1 = 0;
            // 3560 RESTORE
            v.R1 = 100 * rnd(g);
            while (true) {
                v.D1 = v.D1 + 1; // 3580
                if (v.D1 == 16) continue :sw 4670;
                v.D = event_data[@intFromFloat(v.D1 - 1)]; // 3600 READ D
                if (!(v.R1 > v.D)) break;
            }
            const k: usize = @intFromFloat(v.D1);
            continue :sw switch (k) {
                1 => 3660,
                2 => 3700,
                3 => 3740,
                4 => 3790,
                5 => 3820,
                6 => 3850,
                7 => 3880,
                8 => 3960,
                9 => 4130,
                10 => 4190,
                11 => 4220,
                12 => 4290,
                13 => 4340,
                14 => 4560,
                else => 4610,
            };
        },
        3660 => {
            say(g, .wagon_breaks, "WAGON BREAKS DOWN--LOSE TIME AND SUPPLIES FIXING IT");
            v.M = v.M - 15 - 5 * rnd(g);
            v.M1 = v.M1 - 8;
            continue :sw 4710;
        },
        3700 => {
            say(g, .ox_injured, "OX INJURES LEG---SLOWS YOU DOWN REST OF TRIP");
            v.M = v.M - 25;
            v.A = v.A - 20;
            continue :sw 4710;
        },
        3740 => {
            say(g, .daughter_arm, "BAD LUCK---YOUR DAUGHTER BROKE HER ARM");
            say(g, .plain, "YOU HAD TO STOP AND USE SUPPLIES TO MAKE A SLING");
            v.M = v.M - 5 - 4 * rnd(g);
            v.M1 = v.M1 - 2 - 3 * rnd(g);
            continue :sw 4710;
        },
        3790 => {
            say(g, .ox_wanders, "OX WANDERS OFF---SPEND TIME LOOKING FOR IT");
            v.M = v.M - 17;
            continue :sw 4710;
        },
        3820 => {
            say(g, .son_lost, "YOUR SON GETS LOST---SPEND HALF THE DAY LOOKING FOR HIM");
            v.M = v.M - 10;
            continue :sw 4710;
        },
        3850 => {
            say(g, .bad_water, "UNSAFE WATER--LOSE TIME LOOKING FOR CLEAN SPRING");
            v.M = v.M - 10 * rnd(g) - 2;
            continue :sw 4710;
        },
        3880 => {
            if (v.M > 950) continue :sw 4490;
            say(g, .heavy_rain, "HEAVY RAINS---TIME AND SUPPLIES LOST");
            v.F = v.F - 10;
            v.B = v.B - 500;
            v.M1 = v.M1 - 15;
            v.M = v.M - 10 * rnd(g) - 5;
            continue :sw 4710;
        },
        3960 => {
            say(g, .bandits, "BANDITS ATTACK");
            g.ret_shoot = 3980;
            continue :sw 6140;
        },
        3980 => {
            v.B = v.B - 20 * v.B1;
            if (!(v.B >= 0)) {
                say(g, .plain, "YOU RAN OUT OF BULLETS---THEY GET LOTS OF CASH");
                v.T = v.T / 3;
            } else if (v.B1 <= 1) {
                say(g, .plain, "QUICKEST DRAW OUTSIDE OF DODGE CITY!!!"); // 4100
                say(g, .plain, "YOU GOT 'EM!");
                continue :sw 4710;
            }
            say(g, .plain, "YOU GOT SHOT IN THE LEG AND THEY TOOK ONE OF YOUR OXEN"); // 4040
            v.K8 = 1;
            say(g, .plain, "BETTER HAVE A DOC LOOK AT YOUR WOUND");
            v.M1 = v.M1 - 5;
            v.A = v.A - 20;
            continue :sw 4710;
        },
        4130 => {
            say(g, .fire, "THERE WAS A FIRE IN YOUR WAGON--FOOD AND SUPPLIES DAMAGE");
            v.F = v.F - 40;
            v.B = v.B - 400;
            v.M1 = v.M1 - rnd(g) * 8 - 3;
            v.M = v.M - 15;
            continue :sw 4710;
        },
        4190 => {
            say(g, .fog, "LOSE YOUR WAY IN HEAVY FOG---TIME IS LOST");
            v.M = v.M - 10 - 5 * rnd(g);
            continue :sw 4710;
        },
        4220 => {
            say(g, .snake, "YOU KILLED A POISONOUS SNAKE AFTER IT BIT YOU");
            v.B = v.B - 10;
            v.M1 = v.M1 - 5;
            if (v.M1 >= 0) continue :sw 4710;
            set_outcome(g, .snakebite);
            say(g, .death, "YOU DIE OF SNAKEBITE SINCE YOU HAVE NO MEDICINE");
            continue :sw 5170;
        },
        4290 => {
            say(g, .river, "WAGON GETS SWAMPED FORDING RIVER--LOSE FOOD AND CLOTHES");
            v.F = v.F - 30;
            v.C = v.C - 20;
            v.M = v.M - 20 - 20 * rnd(g);
            continue :sw 4710;
        },
        4340 => {
            say(g, .wild_animals, "WILD ANIMALS ATTACK!");
            g.ret_shoot = 4360;
            continue :sw 6140;
        },
        4360 => {
            if (!(v.B > 39)) {
                say(g, .plain, "YOU WERE TOO LOW ON BULLETS--");
                say(g, .plain, "THE WOLVES OVERPOWERED YOU");
                v.K8 = 1;
                continue :sw 5120;
            }
            if (v.B1 > 2) {
                say(g, .plain, "SLOW ON THE DRAW---THEY GOT AT YOUR FOOD AND CLOTHES");
            } else {
                say(g, .plain, "NICE SHOOTIN' PARTNER---THEY DIDN'T GET MUCH");
            }
            v.B = v.B - 20 * v.B1; // 4450
            v.C = v.C - v.B1 * 4;
            v.F = v.F - v.B1 * 8;
            continue :sw 4710;
        },
        4490 => {
            out(g, .cold, "COLD WEATHER---BRRRRRRR!---YOU ");
            if (!(v.C > 22 + 4 * rnd(g))) {
                out(g, .plain, "DON'T ");
                v.C1 = 1;
            }
            say(g, .plain, "HAVE ENOUGH CLOTHING TO KEEP YOU WARM");
            if (v.C1 == 0) continue :sw 4710;
            continue :sw 6300;
        },
        4560 => {
            say(g, .hail, "HAIL STORM---SUPPLIES DAMAGED");
            v.M = v.M - 5 - rnd(g) * 10;
            v.B = v.B - 200;
            v.M1 = v.M1 - 4 - rnd(g) * 3;
            continue :sw 4710;
        },
        4610 => {
            if (v.E == 1) continue :sw 6300;
            if (v.E == 3) {
                if (rnd(g) < 0.5) continue :sw 6300; // 4650
                continue :sw 4710;
            }
            if (rnd(g) > 0.25) continue :sw 6300; // 4630
            continue :sw 4710;
        },
        4670 => {
            say(g, .helpful_food, "HELPFUL INDIANS SHOW YOU WHERE TO FIND MORE FOOD");
            v.F = v.F + 14;
            continue :sw 4710;
        },
        4710 => {
            if (v.M <= 950) continue :sw 1230;
            const r = rnd(g);
            const q = v.M / 100 - 15;
            if (r * 10 > 9 - (sq(q) + 72) / (sq(q) + 12)) continue :sw 4860;
            say(g, .mountains, "RUGGED MOUNTAINS");
            if (!(rnd(g) > 0.1)) {
                say(g, .plain, "YOU GOT LOST---LOSE VALUABLE TIME TRYING TO FIND TRAIL!");
                v.M = v.M - 60;
                continue :sw 4860;
            }
            if (!(rnd(g) > 0.11)) {
                say(g, .plain, "WAGON DAMAGED!---LOSE TIME AND SUPPLIES");
                v.M1 = v.M1 - 5;
                v.B = v.B - 200;
                v.M = v.M - 20 - 30 * rnd(g);
                continue :sw 4860;
            }
            say(g, .plain, "THE GOING GETS SLOW");
            v.M = v.M - 45 - rnd(g) / 0.02;
            continue :sw 4860;
        },
        4860 => {
            if (v.F1 != 1) {
                v.F1 = 1;
                if (rnd(g) < 0.8) continue :sw 4970;
                say(g, .south_pass, "YOU MADE IT SAFELY THROUGH SOUTH PASS--NO SNOW");
            }
            // 4900
            if (v.M < 1700) continue :sw 4940;
            if (v.F2 == 1) continue :sw 4940;
            v.F2 = 1;
            if (rnd(g) < 0.7) continue :sw 4970;
            continue :sw 4940;
        },
        4940 => {
            if (v.M > 950) continue :sw 1230;
            v.M9 = 1;
            continue :sw 1230;
        },
        4970 => {
            say(g, .blizzard, "BLIZZARD IN MOUNTAIN PASS--TIME AND SUPPLIES LOST");
            v.L1 = 1;
            v.F = v.F - 25;
            v.M1 = v.M1 - 10;
            v.B = v.B - 300;
            v.M = v.M - 30 - 40 * rnd(g);
            if (v.C < 18 + 2 * rnd(g)) continue :sw 6300;
            continue :sw 4940;
        },
        5060 => {
            set_outcome(g, .starved);
            say(g, .death, "YOU RAN OUT OF FOOD AND STARVED TO DEATH");
            continue :sw 5170;
        },
        5080 => {
            v.T = 0;
            set_outcome(g, .no_doctor_money);
            say(g, .death, "YOU CAN'T AFFORD A DOCTOR");
            continue :sw 5120;
        },
        5110 => {
            set_outcome(g, .no_medicine);
            say(g, .death, "YOU RAN OUT OF MEDICAL SUPPLIES");
            continue :sw 5120;
        },
        5120 => {
            out(g, .death, "YOU DIED OF ");
            if (v.K8 == 1) {
                set_outcome(g, .injuries);
                say(g, .plain, "INJURIES");
            } else {
                set_outcome(g, .pneumonia);
                say(g, .plain, "PNEUMONIA");
            }
            continue :sw 5170;
        },
        5170 => {
            blank(g, .plain);
            say(g, .funeral, "DUE TO YOUR UNFORTUNATE SITUATION, THERE ARE A FEW");
            say(g, .funeral, "FORMALITIES WE MUST GO THROUGH");
            blank(g, .plain);
            say(g, .question, "WOULD YOU LIKE A MINISTER?");
            continue :sw 5220;
        },
        5220 => {
            const x = in orelse return ask_yes(g, 5220, "WOULD YOU LIKE A MINISTER?");
            in = null;
            g.cs_yes = x.yes;
            say(g, .question, "WOULD YOU LIKE A FANCY FUNERAL?");
            continue :sw 5240;
        },
        5240 => {
            const x = in orelse return ask_yes(g, 5240, "A FANCY FUNERAL?");
            in = null;
            g.cs_yes = x.yes;
            say(g, .question, "WOULD YOU LIKE US TO INFORM YOUR NEXT OF KIN?");
            continue :sw 5260;
        },
        5260 => {
            const x = in orelse return ask_yes(g, 5260, "INFORM YOUR NEXT OF KIN?");
            in = null;
            g.cs_yes = x.yes;
            if (g.cs_yes) {
                say(g, .plain, "THAT WILL BE $4.50 FOR THE TELEGRAPH CHARGE.");
            } else {
                say(g, .plain, "BUT YOUR AUNT SADIE IN ST. LOUIS IS REALLY WORRIED ABOUT YOU");
            }
            blank(g, .plain);
            say(g, .letter, "WE THANK YOU FOR THIS INFORMATION AND WE ARE SORRY YOU");
            say(g, .letter, "DIDN'T MAKE IT TO THE GREAT TERRITORY OF OREGON");
            say(g, .letter, "BETTER LUCK NEXT TIME");
            blank(g, .letter);
            blank(g, .letter);
            out(g, .letter, "");
            pad_to(g, 30);
            say(g, .letter, "SINCERELY");
            blank(g, .letter);
            out(g, .letter, "");
            pad_to(g, 17);
            say(g, .letter, "THE OREGON CITY CHAMBER OF COMMERCE");
            return stop(g); // 5410
        },
        5430 => {
            v.F9 = (2040 - v.M2) / (v.M - v.M2);
            v.F = v.F + (1 - v.F9) * (8 + 5 * v.E);
            blank(g, .plain);
            set_outcome(g, .arrived);
            say(g, .bell, "YOU FINALLY ARRIVED AT OREGON CITY");
            say(g, .bell, "AFTER 2040 LONG MILES---HOORAY!!!!!");
            say(g, .arrival, "A REAL PIONEER!");
            blank(g, .plain);
            const turns = v.D3;
            v.F9 = int(v.F9 * 14); // 5510
            v.D3 = v.D3 * 14 + v.F9;
            v.F9 = v.F9 + 1;
            if (!(v.F9 < 8)) v.F9 = v.F9 - 7;
            const wd = on(v.F9, 7) orelse 1; // out of range falls into 5570
            out(g, .date, weekdays[wd - 1]);
            var month: []const u8 = undefined;
            if (!(v.D3 > 124)) {
                v.D3 = v.D3 - 93;
                month = "JULY ";
            } else if (!(v.D3 > 155)) {
                v.D3 = v.D3 - 124;
                month = "AUGUST ";
            } else if (!(v.D3 > 185)) {
                v.D3 = v.D3 - 155;
                month = "SEPTEMBER ";
            } else if (!(v.D3 > 216)) {
                v.D3 = v.D3 - 185;
                month = "OCTOBER ";
            } else if (!(v.D3 > 246)) {
                v.D3 = v.D3 - 216;
                month = "NOVEMBER ";
            } else {
                v.D3 = v.D3 - 246;
                month = "DECEMBER ";
            }
            out(g, .date, month);
            num(g, v.D3);
            out(g, .date, " 1847");
            endl(g);
            g.hud.date_text = std.fmt.bufPrint(&g.hud_date, "{s}{d} 1847", .{ month, sat_i64(v.D3) }) catch "1847";
            g.hud.turn = @intFromFloat(@max(0, @min(255, turns)));
            g.hud.mileage_shown = 2040;
            blank(g, .plain); // 5920
            status_header(g, .status_header);
            if (!(v.B > 0)) v.B = 0;
            if (!(v.C > 0)) v.C = 0;
            if (!(v.M1 > 0)) v.M1 = 0;
            if (!(v.T > 0)) v.T = 0;
            if (!(v.F > 0)) v.F = 0;
            status_values(g, .status_values, .{ int(v.F), int(v.B), int(v.C), int(v.M1), int(v.T) });
            blank(g, .plain);
            const letter = [_]struct { u8, []const u8 }{
                .{ 11, "PRESIDENT JAMES K. POLK SENDS YOU HIS" },
                .{ 17, "HEARTIEST CONGRATULATIONS" },
                .{ 0, "" },
                .{ 11, "AND WISHES YOU A PROSPEROUS LIFE AHEAD" },
                .{ 0, "" },
                .{ 22, "AT YOUR NEW HOME" },
            };
            for (letter) |l| {
                if (l[0] == 0) {
                    blank(g, .letter);
                } else {
                    out(g, .letter, "");
                    pad_to(g, l[0]);
                    say(g, .letter, l[1]);
                }
            }
            return stop(g); // 6120
        },
        6140 => {
            // 6140-6180: DIM S$(5), the four words.
            v.S6 = int(rnd(g) * 4 + 1); // 6190
            const w: Word = @fromBackingInt(@intCast(@as(u8, @intFromFloat(std.math.clamp(v.S6, 1, 4)))));
            out(g, .question, "TYPE ");
            say(g, .question, w.text());
            v.B3 = 0; // 6210 B3 = CLK(0): the clock starts at 0
            continue :sw 6220;
        },
        6220 => {
            const w: Word = @fromBackingInt(@intCast(@as(u8, @intFromFloat(std.math.clamp(v.S6, 1, 4)))));
            const x = in orelse return ask(g, .{
                .kind = .shoot,
                .line = 6220,
                .question = "QUICK, SHOOT!",
                .word = w,
                .shot = shot_reason(g.ret_shoot),
            });
            in = null;
            const s = x.shot;
            v.B1 = s.seconds / 3600; // 6230 B1 = CLK(0), in hours
            v.B1 = ((v.B1 - v.B3) * 3600) - (v.D9 - 1); // 6240
            blank(g, .plain); // 6250
            if (!(v.B1 > 0)) v.B1 = 0; // 6255-6257
            if (!s.correct) v.B1 = 9; // 6260-6270
            continue :sw g.ret_shoot; // 6280 RETURN
        },
        6300 => {
            if (100 * rnd(g) < 10 + 35 * (v.E - 1)) {
                say(g, .illness, "MILD ILLNESS---MEDICINE USED"); // 6370
                v.M = v.M - 5;
                v.M1 = v.M1 - 2;
            } else if (100 * rnd(g) < 100 - (40 / std.math.pow(f64, 4, v.E - 1))) {
                say(g, .illness, "BAD ILLNESS---MEDICINE USED"); // 6410
                v.M = v.M - 5;
                v.M1 = v.M1 - 5;
            } else {
                say(g, .illness, "SERIOUS ILLNESS---");
                say(g, .plain, "YOU MUST STOP FOR MEDICAL ATTENTION");
                v.M1 = v.M1 - 10;
                v.S4 = 1;
            }
            // 6440
            if (v.M1 < 0) continue :sw 5110;
            if (v.L1 == 1) continue :sw 4940;
            continue :sw 4710;
        },
        else => unreachable,
    }
}
