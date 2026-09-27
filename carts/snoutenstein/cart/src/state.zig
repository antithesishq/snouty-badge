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

pub const Weapon = enum(u8) { swatter = 0, zapper = 1, spray = 2 };

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
    kind: u8 = 0, // 0 none, 1 spit, 2 web
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
}

pub fn pickup_present(s: *const GameState, i: usize) bool {
    return (s.pickups[i / 32] >> @intCast(i % 32)) & 1 == 1;
}
pub fn take_pickup(s: *GameState, i: usize) void {
    s.pickups[i / 32] &= ~(@as(u32, 1) << @intCast(i % 32));
}
