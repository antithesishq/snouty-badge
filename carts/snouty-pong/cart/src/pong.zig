//! Pong's rules: the World both badges hold and the function that moves it.
//!
//! This file is the `G` that `lockstep.Lockstep(L, G)` takes
//! (docs/LOCKSTEP.md section 1). The one rule to keep: `simulate` reads
//! only the World and the two input bytes. No clock, no `cart.rand()`, no
//! floats, no cart API at all. Then two badges that feed it the same bytes
//! hold the same World, and only input bytes ever cross the cable.
const lockstep = @import("lockstep");

// ---- what the lockstep needs ----------------------------------------------

/// Bytes of rules the host picks in the lobby: the score that wins.
pub const rules_len = 1;
/// A button press drives the tick 2 frames later on both badges, which
/// hides the cable's latency.
pub const input_delay: u32 = 2;

pub fn hash(w: *const World) u32 {
    return lockstep.hash_fields(World, w);
}

/// The partner left: the CPU takes over its paddle.
pub fn hand_over(w: *World, slot: u1) void {
    w.cpu[slot] = true;
}

// ---- the game ----------------------------------------------------------------

pub const width = 160;
pub const height = 128;
/// Positions are in 1/16 pixel, so speeds can be fractional without floats.
pub const sub = 16;

pub const paddle_w = 3;
pub const paddle_h = 20;
pub const ball_size = 3;
/// Left edge of each paddle, in pixels: slot 0 (the host) plays on the left.
pub const paddle_x = [2]i32{ 6, width - 6 - paddle_w };

const paddle_speed = 40; // 2.5 px a tick
const cpu_speed = 16; // slower, so the CPU misses
const serve_speed = 24;
const max_speed = 56;
const serve_wait = 45; // ticks

/// One input byte per player per tick. Bits 6 and 7 must never both be
/// set (docs/LOCKSTEP.md section 1); these two bits never come close.
pub const Input = packed struct(u8) {
    up: bool = false,
    down: bool = false,
    _: u6 = 0,
};

pub const World = struct {
    /// Top edge of each paddle.
    paddle_y: [2]i32 = @splat((height - paddle_h) / 2 * sub),
    ball_x: i32 = 0,
    ball_y: i32 = 0,
    ball_vx: i32 = 0,
    ball_vy: i32 = 0,
    score: [2]u8 = .{ 0, 0 },
    /// First to this many points wins.
    target: u8,
    /// Ticks until the ball leaves the middle.
    serve_in: u16 = 0,
    /// The CPU plays this paddle (practice, or after the partner left).
    cpu: [2]bool = .{ false, false },
    /// The World's own random numbers, seeded identically on both badges.
    rng: u32,

    pub fn init(seed: u32, target: u8) World {
        var w: World = .{ .target = target, .rng = seed | 1 };
        w.serve(@truncate(w.random()));
        return w;
    }

    pub fn winner(w: *const World) ?u1 {
        for (w.score, 0..) |s, i| if (s >= w.target) return @intCast(i);
        return null;
    }

    /// Put the ball in the middle, heading for `to`'s side.
    fn serve(w: *World, to: u1) void {
        w.ball_x = (width - ball_size) / 2 * sub;
        w.ball_y = (height - ball_size) / 2 * sub;
        w.ball_vx = if (to == 0) -serve_speed else serve_speed;
        w.ball_vy = @as(i32, @intCast(w.random() % 33)) - 16;
        w.serve_in = serve_wait;
    }

    /// xorshift32.
    fn random(w: *World) u32 {
        w.rng ^= w.rng << 13;
        w.rng ^= w.rng >> 17;
        w.rng ^= w.rng << 5;
        return w.rng;
    }
};

/// One tick. `in[0]` is the host's (left) byte, `in[1]` the guest's.
pub fn simulate(w: *World, in: [2]u8) void {
    if (w.winner() != null) return;
    for (in, 0..) |byte, i| {
        const slot: u1 = @intCast(i);
        move_paddle(w, slot, if (w.cpu[slot]) cpu_input(w, slot) else @bitCast(byte));
    }
    if (w.serve_in > 0) {
        w.serve_in -= 1;
        return;
    }
    move_ball(w);
}

fn move_paddle(w: *World, slot: u1, in: Input) void {
    const speed: i32 = if (w.cpu[slot]) cpu_speed else paddle_speed;
    var y = w.paddle_y[slot];
    if (in.up) y -= speed;
    if (in.down) y += speed;
    w.paddle_y[slot] = @max(0, @min(y, (height - paddle_h) * sub));
}

/// The CPU player: chase the ball once it is on our half (beatable,
/// because it waits). The host tests use it as both players.
pub fn cpu_input(w: *const World, slot: u1) Input {
    const ours = if (slot == 0) w.ball_x < width / 2 * sub else w.ball_x > width / 2 * sub;
    const target = if (ours) w.ball_y + ball_size * sub / 2 else height / 2 * sub;
    const centre = w.paddle_y[slot] + paddle_h * sub / 2;
    const dead_zone = 4 * sub;
    return .{ .up = target < centre - dead_zone, .down = target > centre + dead_zone };
}

fn move_ball(w: *World) void {
    w.ball_x += w.ball_vx;
    w.ball_y += w.ball_vy;

    // Bounce off the top and bottom walls.
    const max_y = (height - ball_size) * sub;
    if (w.ball_y < 0 or w.ball_y > max_y) {
        w.ball_y = if (w.ball_y < 0) -w.ball_y else 2 * max_y - w.ball_y;
        w.ball_vy = -w.ball_vy;
    }

    const toward: u1 = if (w.ball_vx < 0) 0 else 1;
    if (touches(w, toward)) bounce(w, toward);

    if (w.ball_x < -ball_size * sub) score(w, 1);
    if (w.ball_x > width * sub) score(w, 0);
}

fn touches(w: *const World, slot: u1) bool {
    const px = paddle_x[slot] * sub;
    const py = w.paddle_y[slot];
    return w.ball_x < px + paddle_w * sub and w.ball_x + ball_size * sub > px and
        w.ball_y < py + paddle_h * sub and w.ball_y + ball_size * sub > py;
}

/// Send the ball back a little faster, steeper the further from the
/// paddle's centre it hit.
fn bounce(w: *World, slot: u1) void {
    const speed = @min(@as(i32, @intCast(@abs(w.ball_vx))) + 1, max_speed);
    w.ball_vx = if (slot == 0) speed else -speed;
    const hit = (w.ball_y + ball_size * sub / 2) - (w.paddle_y[slot] + paddle_h * sub / 2);
    w.ball_vy = @divTrunc(hit, 5);
    // Out of the paddle, so it cannot bounce twice.
    w.ball_x = if (slot == 0) (paddle_x[0] + paddle_w) * sub else (paddle_x[1] - ball_size) * sub;
}

fn score(w: *World, slot: u1) void {
    w.score[slot] += 1;
    w.serve(~slot);
}
