//! badge-calibrate: times micro-kernels with the core cycle counter so
//! badge-bench's cycle model can be fitted to hardware. SPEC.md for the
//! design, PLAN.md for the contract (schedule corrections, trace format).
//!
//! Frame f of a pass runs kernel f (0..19):
//!   spin to 15 k cycles after update() began   (the LCD DMA of the last
//!   busy run                                    frame is now streaming)
//!   spin to 1.2 M cycles (8 ms)                 (DMA done; skipped when
//!   idle run, idle run                           badge-bench pokes skip_wait)
//! After kernel 19 the pass's statistics are snapshotted and its 21 `CAL`
//! trace lines go out one per frame over the next 20 frames (row 19 and the
//! done line share a frame; harness.zig explains why). Five passes, then
//! the cart only draws (and drains the last pass's lines). A = next page,
//! B = restart.
const std = @import("std");
const cart = @import("cart-api");
const kernels = @import("kernels.zig");
const harness = @import("harness.zig");

comptime {
    cart.export_start_code();
}

const passes_max = 5;
/// Busy run starts this many cycles after update() begins (100 us).
const busy_start_cycles = 15_000;
/// Busy run must end by here (4.5 ms) to stay inside the ~5.2 ms DMA.
const busy_deadline_cycles = 675_000;
/// Idle runs start after this (8 ms): the DMA has finished.
const idle_start_cycles = 1_200_000;

var page: u8 = 0;
const page_count = 3;
var pass: u32 = 0;
var kernel_id: u32 = 0;
var prev_controls: cart.Controls = @bitCast(@as(u16, 0));

pub fn start() void {
    cart.set_vsync_disabled();
    cart.set_double_buffer_mode(.no_copy_full_frame);
    if (!cart.is_wasm) kernels.init();
}

pub fn update() void {
    const c = read_controls();
    const a_pressed = c.a and !prev_controls.a;
    const b_pressed = c.b and !prev_controls.b;
    prev_controls = c;

    if (cart.is_wasm) {
        draw_hardware_only();
        present_wasm();
    } else {
        update_hardware(a_pressed, b_pressed);
    }
}

fn update_hardware(a_pressed: bool, b_pressed: bool) void {
    if (a_pressed) page = (page + 1) % page_count;
    if (b_pressed) {
        harness.reset();
        harness.clear_pending();
        pass = 0;
        kernel_id = 0;
    }

    // At most one pending trace line per frame, before the kernel runs (see
    // harness.zig "Pending trace lines"). Row 19's frame also carries the
    // done line, sent after the kernel runs; it is formatted first because
    // run_frame may complete the next pass and replace the snapshot.
    var done_buf: [120]u8 = undefined;
    var done_line: ?[]const u8 = null;
    const will_run = pass < passes_max;
    const e = harness.emit_next;
    if (e < kernels.count) {
        var buf: [120]u8 = undefined;
        cart.trace(harness.format_row(&buf, harness.pending_rows[e]));
        harness.emit_next = e + 1;
        if (e == kernels.count - 1 and will_run) {
            done_line = harness.format_done(&done_buf, harness.pending_pass, harness.pending_sum);
            harness.emit_next = harness.lines_per_pass;
        }
    } else if (e == kernels.count) {
        // No kernel ran in row 19's frame (after the last pass): done line now.
        var buf: [120]u8 = undefined;
        cart.trace(harness.format_done(&buf, harness.pending_pass, harness.pending_sum));
        harness.emit_next = harness.lines_per_pass;
    }

    if (will_run) run_frame();
    if (done_line) |l| cart.trace(l);
    draw_page();
}

fn run_frame() void {
    const id = kernel_id;
    const k = &kernels.list[id];
    const t0 = harness.now();

    while (harness.now() - t0 < busy_start_cycles) {}
    const busy = harness.time(k);
    if (harness.now() - t0 > busy_deadline_cycles) harness.stats[id].late += 1;

    if (!harness.skip_wait_set()) {
        while (harness.now() - t0 < idle_start_cycles) {}
    }
    const idle0 = harness.time(k);
    const idle1 = harness.time(k);

    const s = &harness.stats[id];
    s.busy.add(busy);
    s.idle.add(idle0);
    s.idle.add(idle1);

    kernel_id += 1;
    if (kernel_id == kernels.count) {
        kernel_id = 0;
        pass += 1;
        harness.snapshot(pass);
    }
}

// ---------------------------------------------------------------------------
// Pages (8x8 font: 20 columns x 16 rows).

const bg = cart.DisplayColor.rgb(0x000010);
const fg = cart.DisplayColor.rgb(0xe0e0e0);
const hi = cart.DisplayColor.rgb(0xffd040);
const dim = cart.DisplayColor.rgb(0x80a0c0);

fn clear() void {
    const px = cart.Pixel.from_color(bg);
    for (cart.framebuffer) |*column| @memset(column, px);
}

fn line(row: i32, color: cart.DisplayColor, str: []const u8) void {
    cart.text(.{ .str = str, .x = 0, .y = row * 8, .text_color = color });
}

/// "12.34" (cycles per op, 2 decimals, clamped to 99.99) or "-".
fn per_op(buf: []u8, cycles: u32, ops: u32) []const u8 {
    if (cycles == 0) return std.fmt.bufPrint(buf, "-", .{}) catch "";
    const centi: u64 = @min(@as(u64, cycles) * 100 / ops, 9999);
    return std.fmt.bufPrint(buf, "{d}.{d:0>2}", .{ centi / 100, centi % 100 }) catch "";
}

fn draw_page() void {
    clear();
    var buf: [40]u8 = undefined;
    const title = std.fmt.bufPrint(&buf, "CAL {d}/3 pass {d}/{d}", .{ page + 1, pass, passes_max }) catch "";
    line(0, hi, title);
    switch (page) {
        0, 1 => {
            line(1, dim, "id name   idle  busy");
            const first: usize = if (page == 0) 0 else 10;
            for (first..first + 10) |id| {
                const k = &kernels.list[id];
                const s = &harness.stats[id];
                const ops = k.n * k.ops_per_iter;
                var ib: [8]u8 = undefined;
                var bb: [8]u8 = undefined;
                const row = std.fmt.bufPrint(&buf, "{d:>2} {s:<5}{s:>6}{s:>6}", .{
                    id, k.short, per_op(&ib, s.idle.min(), ops), per_op(&bb, s.busy.min(), ops),
                }) catch "";
                line(@intCast(2 + id - first), fg, row);
            }
            line(13, dim, "cycles/op, min");
            line(15, dim, "A page  B restart");
        },
        else => {
            const sum = std.fmt.bufPrint(&buf, "sum {x:0>8}", .{harness.checksum()}) catch "";
            line(1, fg, sum);
            var late: u32 = 0;
            for (harness.stats) |s| late += s.late;
            const late_s = std.fmt.bufPrint(&buf, "late busy runs {d}", .{late}) catch "";
            line(2, if (late == 0) fg else hi, late_s);
            for (0..10) |r| {
                const a = kernels.list[2 * r];
                const b = kernels.list[2 * r + 1];
                const row = std.fmt.bufPrint(&buf, "{d:>2}:{d:<7}{d:>2}:{d}", .{ 2 * r, a.n, 2 * r + 1, b.n }) catch "";
                line(@intCast(3 + r), dim, row);
            }
            line(13, dim, "idle=cycles/op after");
            line(14, dim, "8ms, busy=during");
            line(15, dim, "LCD DMA");
        },
    }
}

fn draw_hardware_only() void {
    clear();
    line(0, hi, "badge-calibrate");
    line(2, fg, "hardware only:");
    line(3, fg, "needs the core cycle");
    line(4, fg, "counter (DWT). Flash");
    line(5, fg, "the uf2 to a badge.");
}

// ---------------------------------------------------------------------------
// Simulator shims, copied from snouty-reflections (see its main.zig).

/// Button state. Upstream's platform_wasm.zig exposes `controls` but never
/// fills it from the simulator, which writes its button word (same bit
/// layout as cart.Controls) to linear address 0x04; read that directly on
/// wasm. Hardware gets the OS-maintained cart.controls.
pub fn read_controls() cart.Controls {
    if (cart.is_wasm) return @bitCast(@as(*const volatile u16, @ptrFromInt(0x04)).*);
    return cart.controls.*;
}

/// Upstream's wasm platform never presents, and the web simulator reads a
/// legacy framebuffer at 0x20 with red and blue swapped relative to
/// DisplayColor. Hardware builds compile none of this.
const sim_swap_rb = true;

fn present_wasm() void {
    const sim_framebuffer: *cart.Framebuffer = @ptrFromInt(0x20);
    if (sim_swap_rb) {
        for (cart.framebuffer, sim_framebuffer) |*src_column, *dst_column| {
            for (src_column, dst_column) |src, *dst| {
                const col = src.to_color();
                dst.* = .from_color(.{ .r = col.b, .g = col.g, .b = col.r });
            }
        }
    } else {
        sim_framebuffer.* = cart.framebuffer.*;
    }
}
