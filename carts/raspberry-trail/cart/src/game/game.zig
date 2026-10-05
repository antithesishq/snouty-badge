//! The Raspberry Trail game engine: a port of reference/oregon.bas (MECC,
//! 1978) as a resumable state machine. No cart API; host testable.
//!
//! The BASIC program runs straight through, printing lines and stopping
//! at each INPUT. Here `start` and `answer` run it from one INPUT to the
//! next: they append the printed lines to `lines` and leave the INPUT it
//! stopped at in `prompt`. SPEC.md section 3 is the contract.
//!
//! THIS FILE IS THE INTERFACE (written by the lead in the plan commit).
//! The types and the pub functions below are fixed; track L replaces the
//! stub engine underneath (everything marked STUB) with the real port and
//! may add fields and helpers. Renaming or removing anything public needs
//! the lead.
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
    /// Where `answer` resumes (track L's state machine).
    pc: u16 = 0,

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
    stub_step(g, null); // STUB
}

/// Answers the current prompt and runs to the next INPUT (or STOP).
/// The answer must match `g.prompt.kind`; .number is not range checked
/// here (the original's own checks run).
pub fn answer(g: *Game, a: Answer) void {
    std.debug.assert(std.meta.activeTag(a) == g.prompt.kind);
    g.n_lines = 0;
    g.text_len = 0;
    stub_step(g, a); // STUB
}

/// Appends a printed line (helper for the engine).
pub fn print(g: *Game, tag: Tag, comptime fmt: []const u8, args: anytype) void {
    if (g.n_lines == max_lines) return;
    const out = std.fmt.bufPrint(g.text[g.text_len..], fmt, args) catch return;
    g.lines[g.n_lines] = .{ .tag = tag, .text = out };
    g.n_lines += 1;
    g.text_len += out.len;
}

// ---------------------------------------------------------------- STUB
// A tiny fake game that walks through every prompt kind so the UI can be
// built before the port lands. Track L deletes all of this.

fn stub_step(g: *Game, a: ?Answer) void {
    switch (g.pc) {
        0 => {
            print(g, .question, "DO YOU NEED INSTRUCTIONS  (YES/NO)", .{});
            g.prompt = .{ .kind = .yes_no, .line = 190, .question = "NEED INSTRUCTIONS?" };
            g.pc = 1;
        },
        1 => {
            if (a.?.yes_no) {
                print(g, .instructions, "THIS PROGRAM SIMULATES A TRIP OVER THE OREGON TRAIL FROM", .{});
                print(g, .instructions, "INDEPENDENCE, MISSOURI TO OREGON CITY, OREGON IN 1847.", .{});
                print(g, .instructions, "GOOD LUCK!!!", .{});
            }
            print(g, .question, "HOW GOOD A SHOT ARE YOU WITH YOUR RIFLE?", .{});
            g.prompt = .{ .kind = .choice, .line = 760, .question = "HOW GOOD A SHOT ARE YOU?", .n_options = 5, .default_choice = 3 };
            g.prompt.options[0] = "ACE MARKSMAN";
            g.prompt.options[1] = "GOOD SHOT";
            g.prompt.options[2] = "FAIR TO MIDDLIN'";
            g.prompt.options[3] = "NEED MORE PRACTICE";
            g.prompt.options[4] = "SHAKY KNEES";
            g.pc = 2;
        },
        2 => {
            g.v.D9 = @floatFromInt(a.?.choice);
            print(g, .question, "HOW MUCH DO YOU WANT TO SPEND ON YOUR OXEN TEAM", .{});
            g.prompt = .{ .kind = .number, .line = 860, .question = "SPEND ON OXEN?", .min = 200, .max = 300, .default = 200 };
            g.pc = 3;
        },
        3 => {
            g.v.A = @floatFromInt(a.?.number);
            g.v.T = 700 - g.v.A;
            g.hud = .{ .valid = true, .cash = @intFromFloat(g.v.T), .food = 100, .bullets = 1000, .clothing = 50, .misc = 20 };
            print(g, .date, "MONDAY MARCH 29 1847", .{});
            print(g, .status_header, "FOOD      BULLETS   CLOTHING  MISC. SUPP.  CASH", .{});
            print(g, .status_values, " 100       1000      50        20          {d}", .{g.hud.cash});
            print(g, .bandits, "BANDITS ATTACK", .{});
            print(g, .plain, "TYPE BLAM", .{});
            g.prompt = .{ .kind = .shoot, .line = 6220, .question = "SHOOT!", .word = .blam, .shot = .bandits };
            g.pc = 4;
        },
        4 => {
            const s = a.?.shoot;
            const b1 = if (s.correct) s.seconds - (g.v.D9 - 1) else 9;
            if (b1 <= 1)
                print(g, .plain, "QUICKEST DRAW OUTSIDE OF DODGE CITY!!!", .{})
            else
                print(g, .plain, "YOU GOT SHOT IN THE LEG AND THEY TOOK ONE OF YOUR OXEN", .{});
            print(g, .death, "YOU DIED OF INJURIES", .{});
            print(g, .question, "WOULD YOU LIKE A MINISTER?", .{});
            g.prompt = .{ .kind = .yes_no, .line = 5220, .question = "A MINISTER?" };
            g.pc = 5;
        },
        else => {
            print(g, .letter, "BETTER LUCK NEXT TIME", .{});
            g.prompt = .{ .kind = .game_over, .outcome = .injuries };
            g.pc = 6;
        },
    }
}
