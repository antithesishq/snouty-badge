//! GameState: everything the simulation touches, as plain data. It is
//! copied wholesale into rewind keyframes, so: no pointers, no slices, and
//! render-only state (bob, flashes) lives elsewhere (SPEC.md 9.2, 9.3).
const fixed = @import("fixed.zig");
const Fixed = fixed.Fixed;

/// Same bit layout as cart.Controls; kept separate so sim.zig has no
/// cart-api dependency and `zig test` runs on the host.
pub const Buttons = packed struct(u16) {
    start: bool = false,
    select: bool = false,
    a: bool = false,
    b: bool = false,
    click: bool = false,
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    _pad: u7 = 0,
};

pub const max_enemies = 40;
pub const max_projectiles = 12;
pub const max_doors = 64;
pub const max_pickups = 256;

pub const Weapon = enum(u8) { swatter = 0, zapper = 1, spray = 2, debugger = 3 };

pub const Player = struct {
    x: Fixed,
    y: Fixed,
    angle: fixed.Angle,
    hp: i16 = 100,
    weapon: Weapon = .zapper,
    ammo_zapper: u8 = 40,
    ammo_spray: u8 = 0,
    keys: u8 = 0, // bit 0 Coral, 1 Iris, 2 Gold
    fire_cooldown: u8 = 0,
    frozen: u8 = 0, // ticks of web freeze left
    rewind_meter: u16 = 600, // ticks, max 600
    rewind_regen: u8 = 0,
    prev: Buttons = .{},
    /// Set by the first spray-can pickup (which also selects the spray).
    has_spray: bool = false,
    /// The Debugger (M6): charges 0..max_debugger, and whether the first
    /// cartridge has been picked up (which also selects the weapon).
    ammo_debugger: u8 = 0,
    has_debugger: bool = false,
    /// Ticks of invulnerability left after rewinding out of death
    /// (`sim.death_grace`); set only by a rewind patch.
    grace: u8 = 0,
    /// Explicit padding to a 4-byte multiple (assert_no_padding).
    _pad: [1]u8 = @splat(0),
};

pub const EnemyKind = enum(u8) { gnat = 0, wasp = 1, beetle = 2, spider = 3, boss = 4 };
pub const EnemyState = enum(u8) { dormant = 0, idle, alert, chase, attack, pain, dying, dead };

pub const Enemy = struct {
    x: Fixed = 0,
    y: Fixed = 0,
    kind: EnemyKind = .gnat,
    state: EnemyState = .dead,
    hp: i16 = 0,
    timer: u8 = 0,
    frame: u8 = 0,
    dir: fixed.Angle = 0,
    flash: u8 = 0,
    /// AI scratch bytes (ai.zig documents their meaning per kind); they
    /// double as explicit padding so `sim.hash` sees no undefined bytes.
    aux: [3]u8 = @splat(0),
};

pub const Projectile = struct {
    x: Fixed = 0,
    y: Fixed = 0,
    vx: Fixed = 0,
    vy: Fixed = 0,
    kind: u8 = 0, // 0 none, 1 spit, 2 web, 3 debug bolt (player), 4 debug burst (display only)
    ttl: u8 = 0,
    /// projectiles.zig scratch; doubles as explicit padding.
    aux: [2]u8 = @splat(0),
};

pub const Door = struct {
    /// 0 closed .. 255 fully open (16.16 would be overkill; 8 bits of open fraction).
    open: u8 = 0,
    /// Ticks the door stays open once fully open, counts down.
    timer: u8 = 0,
    /// 0 idle/closed, 1 opening, 2 open, 3 closing
    phase: u8 = 0,
    _pad: u8 = 0,
};

pub const GameState = struct {
    tick: u32 = 0,
    rng: u32 = 0x2545F491,
    level: u8 = 0,
    player: Player,
    enemies: [max_enemies]Enemy = @splat(.{}),
    projectiles: [max_projectiles]Projectile = @splat(.{}),
    doors: [max_doors]Door = @splat(.{}),
    /// Bit set = pickup still present.
    pickups: [max_pickups / 32]u32 = @splat(0xFFFFFFFF),
    kills: u16 = 0,
    rewinds: u16 = 0,
    /// Set by `step` when the player walks into the exit door.
    finished: bool = false,
    /// Door kind (1 coral, 2 iris, 3 gold) the player bumped this tick
    /// without the key, 0 = none. Cleared at the start of every `step`.
    last_locked: u8 = 0,
    /// Ticks of red "hurt" flash left (set by `sim.damage_player`).
    hurt: u8 = 0,
    /// Tick of the player's last zapper/spray shot (enemies wake on
    /// gunfire within 8 cells), `no_shot` if none yet.
    last_shot: u32 = no_shot,
};

pub const no_shot: u32 = 0xFFFF_FFFF;

// ---------------------------------------------------------------- deathmatch

/// Pickups an arena may hold (each has its own respawn timer).
pub const max_match_pickups = 32;
/// `Match.last_hit` / `killer`: who did it. 0 and 1 are the players.
pub const by_bug: u8 = 2;
pub const no_one: u8 = 0xFF;

/// Deathmatch (M7, `match.zig`): everything two players need beyond the
/// campaign's GameState, kept beside it (`match.World`) so the campaign
/// state, its hash and the rewind pools (51 GameState copies) do not grow.
/// In a match `GameState.player` is a scratch slot: `match.step` swaps
/// each player into it in turn so sim.zig, ai.zig and projectiles.zig
/// work on it unchanged. Plain data, padding-free (it is hashed raw).
pub const Match = struct {
    /// Player 0 is the host's human, 1 the guest's.
    players: [2]Player,
    frags: [2]i16 = .{ 0, 0 },
    deaths: [2]u16 = .{ 0, 0 },
    /// Shots fired (swatter swings included) and shots that hit the
    /// other player, for the results' accuracy.
    shots: [2]u16 = .{ 0, 0 },
    hits: [2]u16 = .{ 0, 0 },
    /// Ticks of the death view left; 0 = alive.
    dead: [2]u8 = .{ 0, 0 },
    /// Red hurt flash per player (`GameState.hurt` is the scratch copy).
    hurt: [2]u8 = .{ 0, 0 },
    /// Who damaged each player last: 0, 1, `by_bug` or `no_one`.
    last_hit: [2]u8 = .{ no_one, no_one },
    /// The latest death: who died and who gets the credit (`last_hit`).
    victim: u8 = no_one,
    killer: u8 = no_one,
    /// Tick of that death (`no_shot` if none yet).
    kill_tick: u32 = no_shot,
    /// Rules, fixed for the match (the host's lobby choice).
    arena: u8 = 0,
    frag_limit: u8 = 10,
    bugs: bool = false,
    /// Set when someone reaches the frag limit or the partner left.
    over: bool = false,
    /// 0 or 1 once over; `no_one` for a draw (both at the limit at once).
    winner: u8 = no_one,
    /// The match ended because the other badge left (`match.forfeit`).
    forfeit: bool = false,
    _pad: [2]u8 = @splat(0),
    /// Ticks until each arena pickup comes back (0 = present or waiting
    /// to be taken).
    pickup_timer: [max_match_pickups]u16 = @splat(0),
    /// Ticks until each dead bug respawns (BUGS ON); 0 = alive.
    bug_timer: [max_enemies]u16 = @splat(0),
};

/// `sim.hash` runs FNV-1a over the raw bytes of GameState, so no struct
/// in it may contain compiler padding (its bytes would be undefined).
fn assert_no_padding(comptime T: type) void {
    var n: usize = 0;
    for (@typeInfo(T).@"struct".field_types) |ft| n += @sizeOf(ft);
    if (n != @sizeOf(T)) @compileError(@typeName(T) ++ " has padding; add an explicit _pad field");
}
comptime {
    assert_no_padding(Player);
    assert_no_padding(Enemy);
    assert_no_padding(Projectile);
    assert_no_padding(Door);
    assert_no_padding(GameState);
    assert_no_padding(Match);
}

pub fn pickup_present(s: *const GameState, i: usize) bool {
    return (s.pickups[i / 32] >> @intCast(i % 32)) & 1 == 1;
}
pub fn take_pickup(s: *GameState, i: usize) void {
    s.pickups[i / 32] &= ~(@as(u32, 1) << @intCast(i % 32));
}
