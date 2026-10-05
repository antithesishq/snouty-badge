//! New for Snouty GC (M5): the CIRCUIT career (SPEC 8.2, 9). A league's
//! three tracks in order, points 9/6/4/3/2/1, CYCLES from the place, the
//! last-hit wrecks and the cycle chips, a league win worth 1500, the
//! garage between races (SPEC 9.2) and the AI racers' upgrade plans (SPEC
//! 4.3). The top 3 of a league open the next one; otherwise the league is
//! replayed with the CYCLES kept. The last league cleared ends the circuit.
//!
//! The accounting reads a finished World (each car's `rank`, `kills`,
//! `chips`) outside `sim.simulate`; the World only ever sees the
//! `world.Setup` this builds (the loadouts, chips on). Pure data, no cart
//! API, no globals: the host tests drive a whole circuit. State lives in
//! RAM for the session (SPEC 17.6: no saves).
const std = @import("std");
const tuning = @import("tuning.zig");
const world = @import("world.zig");
const racers = @import("racers.zig");
const track = @import("track.zig");

/// The garage's slots in its row order (SPEC 9.2).
pub const Slot = enum(u8) { front, rear, plating, clock, traction, burst, watchdog };
pub const slot_count = 7;

/// How a league ended for the player: 1st (`won`), in the top 3
/// (`cleared`: the next league opens), or out of it (`failed`: replay).
pub const Outcome = enum(u8) { won, cleared, failed };

/// What the last race paid the player (the standings show it).
pub const Award = struct {
    place: u8 = 0,
    place_cycles: u16 = 0,
    kills: u8 = 0,
    kill_cycles: u16 = 0,
    chips: u8 = 0,
    chip_cycles: u16 = 0,
    total: u32 = 0,
    /// Every racer's place and league points from this race.
    places: [racers.count]u8 = @splat(0),
    points: [racers.count]u8 = @splat(0),
};

/// What A would buy on a garage row: a gun swap, the next level, or
/// nothing (`maxed`).
pub const Offer = struct {
    kind: enum(u8) { swap, level, maxed },
    /// The price in CYCLES (0 when maxed).
    price: u16 = 0,
    /// The level the slot reaches (a swap: 1).
    level: u8 = 0,
};

pub const Buy = enum(u8) { ok, poor, maxed };

/// The AIs' upgrade plans (SPEC 4.3, 9.2): the slots each buys the next
/// level of, in order, as its budget allows; front and rear level the
/// racer's own guns (AIs never swap). LEGACY never buys CLOCK, KIDDIE
/// never buys PLATING.
pub const plans = [racers.count][]const Slot{
    // SNOUTY: the hunter; a sharper gun first, then hide and reboots.
    &.{ .front, .plating, .watchdog, .clock, .front, .traction, .rear, .plating, .burst, .clock, .watchdog, .rear, .traction, .plating, .clock, .burst, .watchdog, .traction, .burst },
    // LEGACY: PLATING, then front L2, steel; never the engine.
    &.{ .plating, .front, .plating, .rear, .plating, .watchdog, .front, .traction, .rear, .burst, .watchdog, .traction, .burst, .watchdog, .traction, .burst },
    // KIDDIE: CLOCK first, boost, more clock; armor is for noobs.
    &.{ .clock, .burst, .clock, .front, .traction, .clock, .burst, .front, .rear, .traction, .watchdog, .burst, .rear, .traction, .watchdog, .watchdog },
    // SYSADMIN: clean lines (grip), the lance, uptime.
    &.{ .traction, .front, .watchdog, .clock, .front, .plating, .traction, .rear, .clock, .watchdog, .plating, .burst, .rear, .traction, .clock, .burst, .watchdog, .plating, .burst },
    // ROOTKIT: the leak behind, speed, persistence.
    &.{ .rear, .clock, .rear, .watchdog, .front, .clock, .traction, .burst, .front, .watchdog, .clock, .traction, .plating, .burst, .watchdog, .traction, .plating, .burst, .plating },
    // BOTNET: a bus wants armor and a vote on boost.
    &.{ .plating, .burst, .front, .watchdog, .plating, .rear, .burst, .front, .traction, .plating, .rear, .watchdog, .burst, .traction, .clock, .watchdog, .traction, .clock, .clock },
};

pub const Career = struct {
    /// The player's racer (kept for the whole circuit, SPEC 8.1).
    racer: u8,
    /// The league being raced (index into `track.leagues`) and the next
    /// race in it (0..2; 3 = the league is over).
    league: u8 = 0,
    race: u8 = 0,
    /// Leagues open so far (the Dumps from the start).
    open: u8 = 1,
    /// Tries at the current league (a failed league is replayed).
    tries: u8 = 1,
    /// The player's wallet.
    cycles: u32 = 0,
    /// League points this league, per racer.
    points: [racers.count]u16 = @splat(0),
    /// Per racer: the car's upgrades, CYCLES earned in the circuit and
    /// spent in the garage (the player's included), and (AI) the next step
    /// of its plan.
    loadouts: [racers.count]world.Loadout = @splat(.{}),
    earned: [racers.count]u32 = @splat(0),
    spent: [racers.count]u32 = @splat(0),
    plan: [racers.count]u8 = @splat(0),
    /// The player's circuit totals (the end card).
    races: u16 = 0,
    kills: u16 = 0,
    wins: u16 = 0,
    /// The last race's award; the last league's outcome, its champion and
    /// the player's place in it.
    last: Award = .{},
    outcome: Outcome = .failed,
    champion: u8 = 0,
    league_place: u8 = 0,
    /// The last league closed was cleared and opened a new one.
    unlocked: bool = false,
    /// The circuit is over (the end card).
    done: bool = false,

    pub fn init(racer: u8) Career {
        return .{ .racer = racer % racers.count };
    }

    /// The track of the next race (`track.tracks` index).
    pub fn track_index(self: *const Career) u8 {
        return self.league * track.tracks_per_league + @min(self.race, track.tracks_per_league - 1);
    }

    /// The next race's setup: the player in slot 0, every car's
    /// loadout, the cycle chips on.
    pub fn setup(self: *const Career, seed: u32) world.Setup {
        return .{
            .track = self.track_index(),
            .seed = seed,
            .humans = .{ self.racer, world.no_human },
            .loadouts = self.loadouts,
            .chips = true,
        };
    }

    /// Book a finished race (SPEC 9.1): CYCLES for every racer (the
    /// player's into the wallet, the AIs' into their budgets) from its
    /// place, its credited wrecks and its chips; league points.
    pub fn finish_race(self: *Career, w: *const world.World) Award {
        var a = Award{};
        for (&w.cars, 0..) |*c, i| {
            const place: u8 = if (c.rank >= 1 and c.rank <= racers.count) c.rank else racers.count;
            const pay: u32 = @as(u32, tuning.cycles_place[place - 1]) + @as(u32, c.kills) * tuning.cycles_kill +
                @as(u32, c.chips) * tuning.cycles_chip;
            self.earned[i] += pay;
            a.places[i] = place;
            a.points[i] = tuning.points_place[place - 1];
            self.points[i] += a.points[i];
            if (i == self.racer) {
                a.place = place;
                a.place_cycles = tuning.cycles_place[place - 1];
                a.kills = c.kills;
                a.kill_cycles = @as(u16, c.kills) * tuning.cycles_kill;
                a.chips = c.chips;
                a.chip_cycles = @as(u16, c.chips) * tuning.cycles_chip;
                a.total = pay;
                self.cycles += pay;
                self.kills += c.kills;
                self.wins += @intFromBool(place == 1);
            }
        }
        self.races += 1;
        self.race += 1;
        self.last = a;
        return a;
    }

    pub fn league_over(self: *const Career) bool {
        return self.race >= track.tracks_per_league;
    }

    /// The racers by league points, best first; ties go to the better
    /// place in the last race.
    pub fn standings(self: *const Career) [racers.count]u8 {
        var order: [racers.count]u8 = .{ 0, 1, 2, 3, 4, 5 };
        var i: usize = 1;
        while (i < order.len) : (i += 1) {
            var j = i;
            while (j > 0 and self.ahead(order[j], order[j - 1])) : (j -= 1) std.mem.swap(u8, &order[j], &order[j - 1]);
        }
        return order;
    }

    fn ahead(self: *const Career, a: u8, b: u8) bool {
        if (self.points[a] != self.points[b]) return self.points[a] > self.points[b];
        return self.last.places[a] < self.last.places[b];
    }

    /// The player's place in the league standings, 1..6.
    pub fn place_of(self: *const Career, racer: u8) u8 {
        for (self.standings(), 0..) |r, k| {
            if (r == racer) return @intCast(k + 1);
        }
        return racers.count;
    }

    /// Close the league (after its third race): the champion's 1500
    /// CYCLES, and the top 3 open the next league (or end the circuit
    /// after the last); otherwise the league is replayed. Points reset.
    pub fn close_league(self: *Career) Outcome {
        const order = self.standings();
        self.champion = order[0];
        self.league_place = self.place_of(self.racer);
        self.earned[order[0]] += tuning.cycles_league;
        if (order[0] == self.racer) self.cycles += tuning.cycles_league;
        self.outcome = if (self.league_place == 1) .won else if (self.league_place <= tuning.league_clear) .cleared else .failed;
        self.unlocked = false;
        if (self.outcome == .failed) {
            self.tries += 1;
        } else if (self.league + 1 < track.leagues.len) {
            self.league += 1;
            self.open = @max(self.open, self.league + 1);
            self.unlocked = true;
            self.tries = 1;
        } else {
            self.done = true;
        }
        self.race = 0;
        self.points = @splat(0);
        return self.outcome;
    }

    /// The gun the racer's car carries (its own unless swapped).
    pub fn front_of(self: *const Career, r: u8) world.Front {
        return self.loadouts[r].front orelse racers.roster[r].front;
    }
    pub fn rear_of(self: *const Career, r: u8) world.Rear {
        return self.loadouts[r].rear orelse racers.roster[r].rear;
    }

    /// A slot's level on racer `r`'s car (front and rear: 1..3, the rest
    /// 0..3).
    pub fn level(self: *const Career, r: u8, slot: Slot) u8 {
        const lo = &self.loadouts[r];
        return switch (slot) {
            .front => lo.front_level,
            .rear => lo.rear_level,
            .plating => lo.plating,
            .clock => lo.clock,
            .traction => lo.traction,
            .burst => lo.burst,
            .watchdog => lo.watchdog,
        };
    }

    /// What A buys on `slot` for racer `r`. `pick` is the gun shown on the
    /// FRONT / REAR rows (`Front` / `Rear` as a number): another gun than
    /// the car's is a swap (at L1), the car's own is its next level; the
    /// other rows ignore it.
    pub fn offer(self: *const Career, r: u8, slot: Slot, pick: u8) Offer {
        const lv = self.level(r, slot);
        switch (slot) {
            .front, .rear => {
                const own: u8 = if (slot == .front) @backingInt(self.front_of(r)) else @backingInt(self.rear_of(r));
                if (pick % 4 != own) return .{ .kind = .swap, .price = if (slot == .front) tuning.price_front_swap else tuning.price_rear_swap, .level = 1 };
                if (lv >= tuning.level_max) return .{ .kind = .maxed };
                const table = if (slot == .front) tuning.price_front_level else tuning.price_rear_level;
                return .{ .kind = .level, .price = table[lv - 1], .level = lv + 1 };
            },
            else => {
                if (lv >= tuning.level_max) return .{ .kind = .maxed };
                const table = switch (slot) {
                    .plating => tuning.price_plating,
                    .clock => tuning.price_clock,
                    .traction => tuning.price_traction,
                    .burst => tuning.price_burst,
                    else => tuning.price_watchdog,
                };
                return .{ .kind = .level, .price = table[lv], .level = lv + 1 };
            },
        }
    }

    /// The player buys `offer(racer, slot, pick)` from the wallet.
    pub fn buy(self: *Career, slot: Slot, pick: u8) Buy {
        const o = self.offer(self.racer, slot, pick);
        if (o.kind == .maxed) return .maxed;
        if (o.price > self.cycles) return .poor;
        self.cycles -= o.price;
        self.apply(self.racer, slot, pick, o);
        return .ok;
    }

    fn apply(self: *Career, r: u8, slot: Slot, pick: u8, o: Offer) void {
        self.spent[r] += o.price;
        const lo = &self.loadouts[r];
        switch (slot) {
            .front => if (o.kind == .swap) {
                lo.front = @fromBackingInt(pick % 4);
                lo.front_level = 1;
            } else {
                lo.front_level = o.level;
            },
            .rear => if (o.kind == .swap) {
                lo.rear = @fromBackingInt(pick % 4);
                lo.rear_level = 1;
            } else {
                lo.rear_level = o.level;
            },
            .plating => lo.plating = o.level,
            .clock => lo.clock = o.level,
            .traction => lo.traction = o.level,
            .burst => lo.burst = o.level,
            .watchdog => lo.watchdog = o.level,
        }
    }

    /// An AI's garage budget left: `tuning.ai_follow_pct` of the player's
    /// spending plus `ai_own_pct` of its own CYCLES, less what it spent.
    pub fn ai_budget(self: *const Career, r: u8) u32 {
        return self.ai_allowance(r) -| self.spent[r];
    }

    pub fn ai_allowance(self: *const Career, r: u8) u32 {
        return self.spent[self.racer] * tuning.ai_follow_pct / 100 + self.earned[r] * tuning.ai_own_pct / 100;
    }

    /// Before each race: every AI buys down its plan while it can afford
    /// the next step (a maxed step is skipped). Deterministic.
    pub fn ai_shop(self: *Career) void {
        for (0..racers.count) |i| {
            const r: u8 = @intCast(i);
            if (r == self.racer) continue;
            var budget = self.ai_budget(r);
            const plan = plans[r];
            while (self.plan[r] < plan.len) {
                const slot = plan[self.plan[r]];
                const own: u8 = switch (slot) {
                    .front => @backingInt(self.front_of(r)),
                    .rear => @backingInt(self.rear_of(r)),
                    else => 0,
                };
                const o = self.offer(r, slot, own);
                if (o.kind == .maxed) {
                    self.plan[r] += 1;
                    continue;
                }
                if (o.price > budget) break;
                budget -= o.price;
                self.apply(r, slot, own, o);
                self.plan[r] += 1;
            }
        }
    }

    /// Garage levels bought on racer `r`'s car (the standings' and the
    /// tests' measure of how far a car has come).
    pub fn upgrades(self: *const Career, r: u8) u8 {
        var n: u8 = 0;
        for (0..slot_count) |k| {
            const s: Slot = @fromBackingInt(@intCast(k));
            const lv = self.level(r, s);
            n += if (s == .front or s == .rear) lv - 1 else lv;
        }
        return n;
    }
};
