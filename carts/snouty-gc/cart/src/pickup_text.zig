//! New for Snouty GC: the words of the main menu's PICKUPS page
//! (pickup_page.zig draws it): what each of the 15 non-league pickups does
//! (SPEC 6.3, checked against pickups.zig and tuning.zig, not just the
//! SPEC) and who tends to roll it (SPEC 6.4, `tuning.roll_odds`), plus the
//! page's grid (a row per roll tier) and its cursor moves. PROMPT INJECTION
//! is Perimeter-only and not built, so it is left out. No cart API, so the
//! host tests hold every line to the 152 px panel (content_test.zig).
const world = @import("world.zig");

const Pickup = world.Pickup;

/// What a pickup does: three lines of at most 18 characters (the 8x8 font
/// across 144 px of the 152 px panel) and the roll odds in a line.
pub const Entry = struct {
    lines: [3][]const u8,
    who: []const u8,
};

const tier_a = "MOSTLY 1ST AND 2ND";
const tier_b = "MOSTLY 3RD TO 5TH";
const tier_c = "MOSTLY 5TH AND 6TH";

/// Indexed by `world.Pickup` (SPEC 6.3 order), PREFETCH .. ZERO-DAY.
pub const entries = [count]Entry{
    .{ .lines = .{ "A KICK, THEN +40%", "TOP SPEED FOR 1.5S", "WALLS HURT HALF" }, .who = tier_a }, // PREFETCH
    .{ .lines = .{ "A CRATE THAT ISN'T", "30 DMG AND A SPIN", "DOWN+B: BEHIND YOU" }, .who = tier_a }, // HONEYPOT
    .{ .lines = .{ "EATS ONE PHISH,", "DDOS, BIT FLIP OR", "SHOT FROM BEHIND" }, .who = tier_a }, // RUBBER DUCK
    .{ .lines = .{ "+40 ARMOR IN 1 S.", "NO REBOOT. CLEARS", "BIT FLIP, DEADLOCK" }, .who = tier_a }, // HOT PATCH
    .{ .lines = .{ "A TANGLE: 40% FOR", "1 S, THEN -10% FOR", "3 S. DOWN+B DROPS" }, .who = tier_a }, // SPAGHETTI CODE
    .{ .lines = .{ "DROPS AN & THAT", "FORKS EVERY 1 S", "TO 8. 15 DMG EACH" }, .who = tier_b }, // FORK BOMB
    .{ .lines = .{ "A COSMIC RAY SWAPS", "LEFT AND RIGHT FOR", "THE CAR AHEAD, 3 S" }, .who = tier_b }, // BIT FLIP
    .{ .lines = .{ "CHAINS THE 2 CARS", "AHEAD AT 30% SPEED", "TILL TOUCH OR 2.5S" }, .who = tier_b }, // DEADLOCK
    .{ .lines = .{ "8 DRONES SWARM THE", "CAR AHEAD FOR 3 S:", "-20%, UP TO 96 DMG" }, .who = tier_b }, // DDOS
    .{ .lines = .{ "UNOBSERVABLE 4 S:", "NO LOCKS, YOU PASS", "THROUGH CARS/DROPS" }, .who = tier_b }, // HEISENBUG
    .{ .lines = .{ "PURE RANK THEFT:", "SWAP PLACES WITH", "THE CAR JUST AHEAD" }, .who = tier_b }, // RACE CONDITION
    .{ .lines = .{ "A PACKET HUNTS 1ST", "(2ND IF YOU LEAD):", "40 DMG, 1.5 S HANG" }, .who = tier_c }, // KERNEL PANIC
    .{ .lines = .{ "PROVE YOU'RE HUMAN", "ALL OTHERS AT 10%", "UNTIL SOLVED (2 S)" }, .who = tier_c }, // CAPTCHA
    .{ .lines = .{ "ROOT FOR 5 S: NO", "DAMAGE, +20% SPEED", "RAMS HIT FOR 40" }, .who = tier_c }, // SUDO
    .{ .lines = .{ "WRECKS THE NEAREST", "CAR AHEAD OUTRIGHT", "NO PATCH EXISTS." }, .who = "5TH/6TH ONLY, ONCE" }, // ZERO-DAY
};

// --- The grid --------------------------------------------------------------------------

/// The pickups on the page: PREFETCH .. ZERO-DAY.
pub const count = @backingInt(Pickup.zero_day) + 1;
/// A row per roll tier (pickups.tier_of): A from PREFETCH, B from FORK
/// BOMB, C from KERNEL PANIC; the cursor is the pickup's index.
pub const row_start = [3]u8{ 0, 5, 11 };
pub const row_len = [3]u8{ 5, 6, 4 };
pub const cols = 6;

pub fn row_of(i: u8) u8 {
    return if (i >= row_start[2]) 2 else if (i >= row_start[1]) 1 else 0;
}

/// The cursor after a press: Left/Right (`dx`) wrap within the row,
/// Up/Down (`dy`) wrap over the rows and keep the column where the row is
/// long enough, else land on its last cell.
pub fn move(i: u8, dx: i8, dy: i8) u8 {
    var r = row_of(i);
    var c = i - row_start[r];
    if (dx != 0) {
        const n: i8 = @intCast(row_len[r]);
        c = @intCast(@mod(@as(i8, @intCast(c)) + dx, n));
    }
    if (dy != 0) {
        r = @intCast(@mod(@as(i8, @intCast(r)) + dy, 3));
        c = @min(c, row_len[r] - 1);
    }
    return row_start[r] + c;
}
