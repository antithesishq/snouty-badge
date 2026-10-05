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

/// 0-3 are the campaign's; 4-7 are deathmatch only (M9 arsenal, `arsenal.zig`;
/// their ammo lives in `Match`, never in Player).
pub const Weapon = enum(u8) { swatter = 0, zapper = 1, spray = 2, debugger = 3, fuzzer = 4, fork_bomb = 5, ship_it = 6, gc = 7 };

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

/// One entry of `Match.dm_shots` (M9). `kind` 0 = free; see `arsenal.zig`.
pub const DmShot = struct {
    x: Fixed = 0,
    y: Fixed = 0,
    vx: Fixed = 0,
    vy: Fixed = 0,
    kind: u8 = 0,
    /// Fork bomb: fuse ticks left; explosion: display ticks left.
    ttl: u8 = 0,
    /// Shooter slot (frag credit).
    owner: u8 = 0,
    aux: u8 = 0,
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

/// Players a match holds (M8: the party transport's 16 slots; the M7 cable
/// match uses slots 0 and 1).
pub const max_players = 16;
/// Team modes: FFA (`Match.teams` 0), 2 or 4 teams.
pub const max_teams = 4;
/// Pickups an arena may hold (each has its own respawn timer).
pub const max_match_pickups = 32;
/// The deathmatch projectile pool (M9: fork bombs, rockets, explosions),
/// kept in Match so GameState.projectiles (the campaign pool) never grows.
pub const max_dm_shots = 32;
/// Weapons dropped by dying players lying on the floor at once (the
/// oldest goes first when a seventeenth falls).
pub const max_drops = 16;
/// `Match.last_hit` / `killer`: who did it. 0..15 are the player slots.
pub const by_bug: u8 = 0xFE;
pub const no_one: u8 = 0xFF;
/// `Match.winner` of a team mode: `team_win | team`.
pub const team_win: u8 = 0x80;

/// Deathmatch (M7 two badges, M8 up to 16; `match.zig`): everything the
/// players need beyond the campaign's GameState, kept beside it
/// (`match.World`) so the campaign state, its hash and the rewind pools
/// (51 GameState copies) do not grow. In a match `GameState.player` is a
/// scratch slot: `match.step` swaps each player into it in turn so sim.zig,
/// ai.zig and projectiles.zig work on it unchanged. Plain data,
/// padding-free (it is hashed raw). Per-player arrays are indexed by slot;
/// only the slots in `present` take part (the others are zero HP, never
/// targets, never drawn).
pub const Match = struct {
    /// The M7 cable: slot 0 is the host's human, 1 the guest's. A party:
    /// the lobby's player ids.
    players: [max_players]Player,
    frags: [max_players]i16 = @splat(0),
    deaths: [max_players]u16 = @splat(0),
    /// Shots fired (swatter swings included) and shots that hit another
    /// player (at most one per shot), for the results' accuracy.
    shots: [max_players]u16 = @splat(0),
    hits: [max_players]u16 = @splat(0),
    /// Ticks of the death view left; 0 = alive.
    dead: [max_players]u8 = @splat(0),
    /// Red hurt flash per player (`GameState.hurt` is the scratch copy).
    hurt: [max_players]u8 = @splat(0),
    /// Who damaged each player last: a slot, `by_bug` or `no_one`.
    last_hit: [max_players]u8 = @splat(no_one),
    /// Team of each slot (0..teams-1); all 0 in FFA.
    team: [max_players]u8 = @splat(0),
    /// Bit per slot in the match (fixed at the start; a leaver stays, as a bot).
    present: u16 = 0b11,
    /// Bit per present slot driven by bot.zig (`match.hand_over`, or a
    /// local match's stand-ins). Humans = `present & ~bots`.
    bots: u16 = 0,
    /// 0 = FFA, else 2 or 4 teams.
    teams: u8 = 0,
    /// The latest death: who died and who gets the credit (`last_hit`).
    victim: u8 = no_one,
    killer: u8 = no_one,
    /// Rules, fixed for the match (the host's lobby choice).
    arena: u8 = 0,
    /// Frags per team (sum of its members'), team modes only.
    team_frags: [max_teams]i16 = @splat(0),
    /// Tick of the latest death (`no_shot` if none yet).
    kill_tick: u32 = no_shot,
    /// Per player in FFA, per team in team modes.
    frag_limit: u8 = 10,
    bugs: bool = false,
    /// Set at the frag limit, or when one human (or one team's humans) is left.
    over: bool = false,
    /// Once over: a slot, `team_win | team`, or `no_one` for a draw
    /// (the top score shared at the limit).
    winner: u8 = no_one,
    /// The match ended because the others left (`match.hand_over`).
    forfeit: bool = false,
    _pad: [3]u8 = @splat(0),
    /// Ticks until each arena pickup comes back (0 = present or waiting
    /// to be taken).
    pickup_timer: [max_match_pickups]u16 = @splat(0),
    /// Ticks until each dead bug respawns (BUGS ON); 0 = alive.
    bug_timer: [max_enemies]u16 = @splat(0),
    // ---- M9 arsenal (`arsenal.zig`): per-slot state of the deathmatch-only
    // weapons (Player stays the campaign's struct).
    ammo_fuzzer: [max_players]u8 = @splat(0),
    ammo_bomb: [max_players]u8 = @splat(0),
    ammo_rocket: [max_players]u8 = @splat(0),
    /// Bit per arsenal weapon owned: 1 << (weapon - 4).
    owned: [max_players]u8 = @splat(0),
    /// Garbage Collector spin-up while A is held: 0 idle .. `arsenal.gc_spinup`.
    gc_spin: [max_players]u8 = @splat(0),
    /// Each pickup slot that is a weapon pad (`PickupKind.pad`): the
    /// `state.Weapon` it shows (or shows next, while its timer runs).
    pad_item: [max_match_pickups]u8 = @splat(0),
    /// Flying fork bombs and rockets, and explosions (display only).
    dm_shots: [max_dm_shots]DmShot = @splat(.{}),
    /// Dropped weapons (`arsenal.drop_weapon`): a dead player's weapon
    /// with its ammo, there for anyone to take.
    drops: [max_drops]Drop = @splat(.{}),

    pub fn is_present(m: *const Match, slot: usize) bool {
        return (m.present >> @intCast(slot)) & 1 == 1;
    }
    pub fn is_bot(m: *const Match, slot: usize) bool {
        return (m.bots >> @intCast(slot)) & 1 == 1;
    }
    /// Present, out of the death view and above 0 HP.
    pub fn alive(m: *const Match, slot: usize) bool {
        return m.is_present(slot) and m.dead[slot] == 0 and m.players[slot].hp > 0;
    }
    /// Can `a` hurt `b`? Different slots, and in a team mode different
    /// teams (no friendly fire; a self-hit is the caller's business).
    pub fn foes(m: *const Match, a: usize, b: usize) bool {
        return a != b and (m.teams == 0 or m.team[a] != m.team[b]);
    }
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
    assert_no_padding(DmShot);
    assert_no_padding(Drop);
}

/// One entry of `Match.drops`: `timer` 0 = free, else the ticks until it
/// vanishes; `weapon` a `Weapon`, `ammo` what the dead player had left,
/// `owner` that player's slot (the one who cannot take it back).
pub const Drop = struct {
    x: Fixed = 0,
    y: Fixed = 0,
    timer: u16 = 0,
    weapon: u8 = 0,
    ammo: u8 = 0,
    owner: u8 = 0,
    _pad: [3]u8 = @splat(0),
};

pub fn pickup_present(s: *const GameState, i: usize) bool {
    return (s.pickups[i / 32] >> @intCast(i % 32)) & 1 == 1;
}
pub fn take_pickup(s: *GameState, i: usize) void {
    s.pickups[i / 32] &= ~(@as(u32, 1) << @intCast(i % 32));
}
