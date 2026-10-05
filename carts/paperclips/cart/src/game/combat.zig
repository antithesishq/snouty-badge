//! combat.js: the canvas battle (ships on a 310 x 150 field, a 31 x 15
//! grid, dice rolls per contested cell) and the battle bookkeeping that
//! `war()` drives. The 16 ms `Update` interval runs from page load to the
//! end, even with the canvas hidden: at load two `battleRestart()` calls
//! make 400 ships each (4 draws per ship) and the opening skirmish rolls
//! dice until one side is gone, so the port runs it too to keep the RNG
//! stream identical. Ship positions are plain state for the UI to draw.

const std = @import("std");
const game = @import("game.zig");
const Game = game.Game;
const fmt = @import("fmt.zig");

pub const width: f64 = 310;
pub const height: f64 = 150;
pub const grid_w = 31;
pub const grid_h = 15;
const inv_grid_w: f64 = 1.0 / (width / @as(f64, grid_w));
const inv_grid_h: f64 = 1.0 / (height / @as(f64, grid_h));
pub const max_speed: f64 = 2;
pub const max_ships = 400;
const probe_combat_base_rate: f64 = 0.15;

pub const Ship = struct {
    x: f64 = 0,
    y: f64 = 0,
    vx: f64 = 0,
    vy: f64 = 0,
    gx: i16 = 0,
    gy: i16 = 0,
    team: u8 = 0, // 0 = left (probes, white), 1 = right (drifters, black)
    alive: bool = true,
    frames_dead: u8 = 0, // explosion frames drawn, 0..10
};

pub const BattleNameKind = enum(u8) { foo, drifter_attack, named };

/// `battleName` / `threnodyTitle`: "Drifter Attack <id>" or
/// "<battleNames[idx]> <num>".
pub const BattleName = struct {
    kind: BattleNameKind = .foo,
    idx: u8 = 0,
    num: f64 = 0,

    pub fn write(n: BattleName, o: *fmt.Out) void {
        switch (n.kind) {
            .foo => o.str("foo"),
            .drifter_attack => {
                o.str("Drifter Attack ");
                fmt.write_num(o, n.num);
            },
            .named => {
                o.str(battle_names[n.idx]);
                o.byte(' ');
                fmt.write_num(o, n.num);
            },
        }
    }
};

pub const BattleResult = enum(u8) { victory, defeat };

pub const Battle = struct {
    id: f64 = 0,
    clip_probes: f64 = 0,
    drifter_probes: f64 = 0,
    territory: f64 = 0,
};

pub const battle_names = [_][]const u8{ "Aboukir", "Abensberg", "Acre", "Alba de Tormes", "la Albuera", "Algeciras Bay", "Amstetten", "Arcis-sur-Aube", "Aspern-Essling", "Jena-Auerstedt", "Arcole", "Austerlitz", "Badajoz", "Bailen", "la Barrosa", "Bassano", "Bautzen", "Berezina", "Bergisel", "Borodino", "Burgos", "Bucaco", "Cadiz", "Caldiero", "Castiglione", "Castlebar", "Champaubert", "Chateau-Thierry", "Copenhagen", "Corunna", "Craonne", "Dego", "Dennewitz", "Dresden", "Durenstein", "Eckmuhl", "Elchingen", "Espinosa de los Monteros", "Eylau", "Cape Finisterre", "Friedland", "Fuentes de Onoro", "Gevora River", "Gerona", "Hamburg", "Haslach-Jungingen", "Heilsberg", "Hohenlinden", "Jena-Auerstedt", "Kaihona", "Kolberg", "Landshut", "Leipzig", "Ligny", "Lodi", "Lubeck", "Lutzen", "Marengo", "Maria", "Medellin", "Medina de Rioseco", "Millesimo", "Mincio River", "Mondovi", "Montebello", "Montenotte", "Montmirail", "Mount Tabor", "The Nile", "Novi", "Ocana", "Cape Ortegal", "Orthez", "Pancorbo", "Piave River", "The Pyramids", "Quatre Bras", "Raab", "Raszyn", "Rivoli", "Rolica", "La Rothiere", "Rovereto", "Saalfeld", "Schongrabern", "Salamanca", "Smolensk", "Somosierra", "Talavera", "Tamames", "Trafalgar", "Trebbia", "Tudela", "Ulm", "Valls", "Valmaseda", "Valutino", "Vauchamps", "Vimeiro", "Vitoria", "Wagram", "Waterloo", "Wavre", "Wertingen", "Zaragoza" };

fn new_ship(g: *Game, team: u8) Ship {
    var s = Ship{ .team = team };
    if (team == 0) {
        s.x = (g.rand() * 0.2) * width;
        s.y = g.rand() * height;
        s.vx = g.rand() * max_speed;
        s.vy = g.rand() - 0.5;
    } else {
        s.x = (g.rand() * 0.2 + 0.8) * width;
        s.y = g.rand() * height;
        s.vx = -1 * g.rand() * max_speed;
        s.vy = g.rand() - 0.5;
    }
    return s;
}

/// `battleRestart()`: new ships, alternating teams, right team first.
pub fn battle_restart(g: *Game) void {
    g.num_left_ships = 0;
    g.num_right_ships = 0;
    g.num_ships = 0;
    var left_turn = false;
    var i: usize = 0;
    while (g.num_left_ships < g.battle_left_ships or g.num_right_ships < g.battle_right_ships) {
        if (left_turn) {
            g.ships[i] = new_ship(g, 0);
            g.num_left_ships += 1;
            g.num_ships += 1;
            if (g.num_right_ships < g.battle_right_ships) left_turn = false;
        } else {
            g.ships[i] = new_ship(g, 1);
            g.num_right_ships += 1;
            g.num_ships += 1;
            if (g.num_left_ships < g.battle_left_ships) left_turn = true;
        }
        i += 1;
    }
}

/// Grid cells: ship indices of each cell, in ship order (the JS `Cell`
/// arrays), rebuilt every update.
const Grid = struct {
    start: [grid_w * grid_h + 1]u16,
    list: [max_ships]u16,

    fn cell(gr: *const Grid, row: usize, col: usize) []const u16 {
        const c = row * grid_w + col;
        return gr.list[gr.start[c]..gr.start[c + 1]];
    }
};

fn update_grid(g: *Game, gr: *Grid) void {
    var count: [grid_w * grid_h]u16 = @splat(0);
    const n: usize = g.num_ships;
    for (g.ships[0..n]) |*p| {
        if (!p.alive) continue;
        // Ships stay in [0, 310] x [0, 150] (the walls clamp them), so
        // truncation is the JS Math.floor; clamped as integers.
        var gx: i32 = @intFromFloat(p.x * inv_grid_w);
        var gy: i32 = @intFromFloat(p.y * inv_grid_h);
        if (gx < 0) gx = 0;
        if (gy < 0) gy = 0;
        if (gx > grid_w - 1) gx = grid_w - 1;
        if (gy > grid_h - 1) gy = grid_h - 1;
        p.gx = @intCast(gx);
        p.gy = @intCast(gy);
        count[@as(usize, @intCast(p.gy)) * grid_w + @as(usize, @intCast(p.gx))] += 1;
    }
    var acc: u16 = 0;
    for (0..grid_w * grid_h) |c| {
        gr.start[c] = acc;
        acc += count[c];
    }
    gr.start[grid_w * grid_h] = acc;
    var fill: [grid_w * grid_h]u16 = undefined;
    @memcpy(&fill, gr.start[0 .. grid_w * grid_h]);
    for (g.ships[0..n], 0..) |*p, i| {
        if (!p.alive) continue;
        const c = @as(usize, @intCast(p.gy)) * grid_w + @as(usize, @intCast(p.gx));
        gr.list[fill[c]] = @intCast(i);
        fill[c] += 1;
    }
}

fn move_single_ship(g: *Game, gr: *const Grid, i: usize, cx: f64, cy: f64) void {
    const p = &g.ships[i];
    p.vx += (cx - p.x) * 0.001;
    p.vy += (cy - p.y) * 0.001;
    // With no enemy alive, nothing past the fourth teammate can change p.
    const lone = g.num_left_ships == 0 or g.num_right_ships == 0;
    var mates: u32 = 0;
    const r0: usize = @intCast(@max(p.gy - 1, 0));
    const r1: usize = @intCast(@min(p.gy + 2, grid_h));
    const c0: usize = @intCast(@max(p.gx - 1, 0));
    const c1: usize = @intCast(@min(p.gx + 2, grid_w));
    outer: for (r0..r1) |row| {
        for (c0..c1) |col| {
            const cell = gr.cell(row, col);
            if (cell.len < 2) continue;
            for (cell) |oi| {
                const o = &g.ships[oi];
                if (!o.alive) continue;
                if (o.team == p.team) {
                    mates += 1;
                    if (mates > 3) {
                        if (lone) break :outer;
                        continue;
                    }
                    p.vx += o.vx * 0.01;
                    p.vy += o.vy * 0.01;
                    // Itself: v - (x - x) * 0.1 is v - +0, exactly v.
                    if (oi == i) continue;
                    p.vx -= (o.x - p.x) * 0.1;
                    p.vy -= (o.y - p.y) * 0.1;
                } else {
                    p.vx += o.vx * 0.2;
                    p.vy += o.vy * 0.2;
                    p.vx += (o.x - p.x) * 0.2;
                    p.vy += (o.y - p.y) * 0.2;
                }
            }
        }
    }
    // The compares below are on the bit patterns (exact for these finite
    // values; a soft-float compare costs ~35 cycles on the badge).
    if (abs_gt(p.vx, max_speed)) p.vx = if (neg(p.vx)) -max_speed else max_speed;
    if (abs_gt(p.vy, max_speed)) p.vy = if (neg(p.vy)) -max_speed else max_speed;
    p.x += p.vx;
    p.y += p.vy;
    if (abs_gt(p.x, width) and !neg(p.x)) {
        p.x = width;
        p.vx = -max_speed;
    } else if (neg(p.x)) {
        p.x = 0;
        p.vx = max_speed;
    }
    if (abs_gt(p.y, height) and !neg(p.y)) {
        p.y = height;
        p.vy = -max_speed;
    } else if (neg(p.y)) {
        p.y = 0;
        p.vy = max_speed;
    }
}

const sign_bit: u64 = 1 << 63;
const inf_bits: u64 = 0x7ff0000000000000;

/// |x| > c for a positive constant c (false for NaN, like the compare).
inline fn abs_gt(x: f64, c: f64) bool {
    const m = @as(u64, @bitCast(x)) & ~sign_bit;
    return m > @as(u64, @bitCast(c)) and m <= inf_bits;
}

/// x < 0 (false for -0 and NaN, like the compare).
inline fn neg(x: f64) bool {
    const b: u64 = @bitCast(x);
    const m = b & ~sign_bit;
    return (b & sign_bit) != 0 and m != 0 and m <= inf_bits;
}

fn move_ships(g: *Game, gr: *const Grid) void {
    const n: usize = g.num_ships;
    // FindCentroid
    var cx: f64 = 0;
    var cy: f64 = 0;
    var alive: f64 = 0;
    for (g.ships[0..n]) |*p| {
        if (!p.alive) continue;
        cx += p.x;
        cy += p.y;
        alive += 1;
    }
    cx /= alive;
    cy /= alive;
    cx = (cx * 0.8) + (width / 2 * 0.2);
    cy = (cy * 0.8) + (height / 2 * 0.2);
    for (0..n) |i| {
        const p = &g.ships[i];
        if (!p.alive) {
            if (p.frames_dead < 10) p.frames_dead += 1;
        } else {
            move_single_ship(g, gr, i, cx, cy);
        }
    }
}

fn do_combat(g: *Game, gr: *const Grid) void {
    const px = g.probe_combat * probe_combat_base_rate;
    const dx = g.drifter_combat;
    var ooda: f64 = 0;
    if (g.attack_speed_flag == 1) ooda = g.probe_speed * 0.2;
    // Cells only hold both teams while both have ships alive.
    if (g.num_left_ships > 0 and g.num_right_ships > 0) {
        for (0..grid_h) |row| {
            for (0..grid_w) |col| {
                const cell = gr.cell(row, col);
                if (cell.len < 2) continue;
                var nl: f64 = 0;
                var nr: f64 = 0;
                for (cell) |si| {
                    const p = &g.ships[si];
                    if (!p.alive) continue;
                    if (p.team == 0) nl += 1 else nr += 1;
                }
                if (nl == 0 or nr == 0) continue;
                // The JS works these out per ship; same values per cell.
                const left_odds = (nr / nl) * 0.5;
                const right_odds = (nl / nr) * 0.5;
                const right_base = g.probe_combat * 0.1;
                for (cell) |si| {
                    const p = &g.ships[si];
                    var roll: f64 = undefined;
                    if (p.team == 0) {
                        roll = g.rand() * dx * left_odds;
                        g.battle_death_threshold = g.battle_death_threshold + ooda;
                    } else {
                        roll = ((g.rand() * px) + right_base) * right_odds;
                    }
                    if (roll > g.battle_death_threshold) {
                        p.alive = false;
                        if (p.team == 0) {
                            g.num_left_ships -= 1;
                            if (g.unit_size > g.probe_count) g.unit_size = g.probe_count;
                            g.probe_count = g.probe_count - g.unit_size;
                            g.probes_lost_combat = g.probes_lost_combat + g.unit_size;
                        } else {
                            g.num_right_ships -= 1;
                            if (g.unit_size > g.drifter_count) g.unit_size = g.drifter_count;
                            g.drifter_count = g.drifter_count - g.unit_size;
                            g.drifters_killed = g.drifters_killed + g.unit_size;
                        }
                    }
                    g.battle_death_threshold = 0.5;
                }
            }
        }
    }
    check_for_battle_end(g);
}

fn check_for_battle_end(g: *Game) void {
    if (g.battles_len == 0) return;
    if (g.num_left_ships == 0 or g.num_right_ships == 0) {
        if (g.project_flag(.p121) == 1) {
            g.panels.victory_div = true;
            if (g.num_left_ships == 0) {
                if (g.honor_count == 0) {
                    g.bonus_honor = 0;
                    g.honor = g.honor - g.battle_left_ships_f();
                    g.honor_count = 1;
                }
                g.battle_result = .defeat;
                g.honor_amount = g.battle_left_ships_f();
                g.threnody_title = g.battle_name;
            }
            if (g.num_right_ships == 0) {
                if (g.honor_count == 0) {
                    g.honor_reward = g.battle_right_ships_f() + g.bonus_honor;
                    g.honor_amount = g.honor_reward;
                    g.honor = g.honor + g.honor_reward;
                    if (g.project_flag(.p134) == 1) g.bonus_honor = g.bonus_honor + 10;
                    g.honor_count = 1;
                }
                g.battle_result = .victory;
            }
        }
        g.battle_end_delay += 1;
    } else if (g.num_left_ships <= 4 or g.num_right_ships <= 4) {
        g.battle_clock += 1;
        if (g.battle_clock > 2000) end_battle(g);
    }
    if (g.battle_end_delay >= g.battle_end_timer) end_battle(g);
    g.master_battle_clock += 1;
    if (g.master_battle_clock >= 8000) end_battle(g);
}

fn end_battle(g: *Game) void {
    g.panels.victory_div = false;
    g.honor_count = 0;
    g.battle_clock = 0;
    g.master_battle_clock = 0;
    g.battle_end_delay = 0;
    if (g.battles_len > 0) g.battles_len -= 1;
}

/// The 16 ms `Update` interval: ClearFrame, UpdateGrid, MoveShips, DoCombat.
///
/// With one side gone no cell holds both teams: no dice, so the ships'
/// movement changes nothing but their drawing, and the next battle starts
/// from fresh ships (`battle_restart`). Then they only move while someone
/// can see them: the canvas shows (`panels.battle_canvas_div`) and the UI
/// says it draws them (`ships_observed`). Without that the opening
/// skirmish's 200 survivors would cost ~12 ms of soft-float a frame on
/// the badge for the whole game.
pub fn update(g: *Game) void {
    const lone = g.num_left_ships == 0 or g.num_right_ships == 0;
    if (lone and !(g.panels.battle_canvas_div and g.ships_observed)) {
        check_for_battle_end(g); // all DoCombat does without a contested cell
        return;
    }
    var gr: Grid = undefined;
    update_grid(g, &gr);
    move_ships(g, &gr);
    do_combat(g, &gr);
}

/// `checkForBattles()` (via `war()`), each main-loop tick in space.
pub fn check_for_battles(g: *Game) void {
    if (g.drifter_count > g.war_trigger and g.probe_count > 0 and @as(f64, @floatFromInt(g.battles_len)) < g.max_battles) {
        const r = g.rand() * 100;
        if (r >= 50) {
            if (g.battle_flag == 0) g.battle_flag = 1;
            create_battle(g);
        }
    }
}

fn generate_battle_name(g: *Game) BattleName {
    const x: usize = @intFromFloat(@floor(g.rand() * @as(f64, battle_names.len)));
    const n = BattleName{ .kind = .named, .idx = @intCast(x), .num = g.battle_numbers[x] };
    g.battle_numbers[x] = g.battle_numbers[x] + 1;
    return n;
}

pub fn create_battle(g: *Game) void {
    g.unit_size = 0;
    if (g.drifter_count >= g.probe_count) {
        g.unit_size = g.probe_count / 100;
    } else {
        g.unit_size = g.drifter_count / 100;
    }
    if (g.unit_size < 1) g.unit_size = 1;
    var rr = g.rand() * g.drifter_count;
    if (rr < 1) rr = 1;
    var ss = g.rand() * g.probe_count;
    if (ss < 1) ss = 1;
    const tt = g.rand() * g.available_matter;
    g.battle_id += 1;
    const nb = Battle{ .id = g.battle_id, .clip_probes = ss, .drifter_probes = rr, .territory = tt };

    var left = @ceil(ss / 1000000);
    if (left > 200) left = 200;
    if (left == 200) {
        const hinder = g.rand();
        if (hinder < 0.50) left = @ceil(g.rand() * 175);
    }
    var right = @ceil(rr / 1000000);
    if (right > 200) right = 200;
    g.battle_left_ships = @intFromFloat(left);
    g.battle_right_ships = @intFromFloat(right);

    battle_restart(g);

    g.battle_name = .{ .kind = .drifter_attack, .num = nb.id };
    if (g.battle_name_flag == 1) g.battle_name = generate_battle_name(g);
    g.battle = nb;
    g.battles_len += 1;
}
