//! Formations (PLAN.md M7 "Formations and drops", 1942's POW rule): shoot
//! down every member of a formation and it drops a crate. Eight slots in
//! `world.w.formations`; an enemy names its formation by id
//! (`Enemy.formation`, 0 = none). A member that leaves the field or rams
//! the ship is `lost`: the formation can no longer be completed, and its
//! slot is freed once every member is accounted for.
const world = @import("world.zig");
const pickups = @import("pickups.zig");
const player = @import("player.zig");

pub const Formation = struct {
    /// 0 = free slot.
    id: u8 = 0,
    size: u8 = 0,
    killed: u8 = 0,
    gone: u8 = 0,
    /// Completing it drops a crate (and 200 points).
    drop: bool = false,
};

pub const slots = 8;
/// Bonus for shooting down a whole dropping formation.
const complete_points: u32 = 200;

fn in_use(id: u8) bool {
    for (world.w.formations) |f| {
        if (f.id == id) return true;
    }
    return false;
}

/// Claims a free slot for a formation of `size` members and returns its id
/// (1..255, wrapping and skipping 0 and ids still in use), or 0 when no
/// slot is free (the enemies then have no formation).
pub fn open(size: u8, drop: bool) u8 {
    if (size == 0) return 0;
    for (&world.w.formations) |*f| {
        if (f.id != 0) continue;
        var id = world.w.next_formation_id;
        while (id == 0 or in_use(id)) id +%= 1;
        world.w.next_formation_id = id +% 1;
        f.* = .{ .id = id, .size = size, .drop = drop };
        return id;
    }
    return 0;
}

fn find(id: u8) ?*Formation {
    if (id == 0) return null;
    for (&world.w.formations) |*f| {
        if (f.id == id) return f;
    }
    return null;
}

fn free_if_done(f: *Formation) void {
    if (@as(u32, f.killed) + f.gone >= f.size) f.* = .{};
}

/// A member was killed by a bolt at (cx, cy). The last kill of a complete
/// dropping formation drops a crate there and scores 200.
pub fn killed(id: u8, cx: f32, cy: f32) void {
    const f = find(id) orelse return;
    f.killed +|= 1;
    if (f.killed == f.size and f.drop) {
        pickups.spawn_drop(cx, cy);
        player.add_score(complete_points);
    }
    free_if_done(f);
}

/// A member left the field, rammed the ship or was never spawned: no drop.
pub fn lost(id: u8) void {
    const f = find(id) orelse return;
    f.gone +|= 1;
    free_if_done(f);
}

/// Every slot freed (a stage skip clears the field).
pub fn clear() void {
    world.w.formations = @splat(.{});
}
