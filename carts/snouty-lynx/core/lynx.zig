//! The whole Atari Lynx: `Lynx`, `init_in_place`, `reset`, `step_frame(pad)`
//! and the frame view the frontend converts (SPEC.md sections 6 and 7).
//! Badge-agnostic: no cart-api, no floats, no allocator, no clock, no
//! randomness; the pad word per frame is the only input.
//!
//! PLAN.md "Frozen for M1": `Lynx` is also the CPU's bus (`fetch`, `read`,
//! `write`, `irq_line` from core/bus.zig, bound here), so `Cpu =
//! cpu65.Cpu(Lynx)`. `step_frame` runs 1/60 s of Lynx time (266,667 ticks
//! of 16 MHz, the fraction carried) one instruction at a time; the bus
//! charges the ticks and Mikey's timers are advanced by them after each
//! instruction (and before any Mikey register access).
//!
//! Boot without the boot ROM (docs/BOOT.md): `reset` runs `boot.post_boot`
//! over the cart port and applies its Mikey writes. While MAPCTL bit 2 is
//! clear, PC == $FE00 (block select) and PC == $FE4A (decrypt the next
//! frame) are trapped before they execute; any other PC in $FE00-$FFF7 (an
//! IRQ through the ROM vectors, a crash into the ROM) re-runs the boot, as
//! the ROM's reset code would. A cart that fails to boot halts the CPU
//! (`boot_error` says why) and the frame stays black.
//!
//! CPUSLEEP ($FD91 write), Epyx CPU chapter and Felix: a pending interrupt
//! (masked or not) or an unacknowledged Suzy-done (SDONEACK) keeps the CPU
//! awake. Otherwise, with a sprite list pending (`suzy.sprites_pending()`)
//! the whole list is drawn at once and its bus time charged
//! (`suzy.run_sprites`); the CPU continues when Suzy is done (those ticks
//! count as `sleep_ticks`). With nothing pending the CPU does not sleep:
//! "Sleep is broken in Mikey. The CPU will NOT remain asleep unless Suzy is
//! using the bus" (Epyx lynx4.html), and Felix agrees. `idle_sleep = true`
//! switches to the M1 contract's model instead: sleep until Mikey's next
//! interrupt (time jumps to the next timer event, capped at the frame end,
//! the sleep persists across `step_frame` calls).
//!
//! Display: DISPADR is latched when timer 2 counts down to line 101 (the
//! frame after vertical blank's three lines; Felix) or by an MTEST2 bit 0
//! write; at the next timer 2 underflow (vertical blank) the 8,160 bytes at
//! the latched address and the palette are copied into `display`, which
//! `frame()` returns: the frontend always shows the last completed Lynx
//! frame, whatever refresh rate the game runs. With DISPCTL bit 0 (video
//! DMA) clear the previous frame is kept. DISPCTL flip is ignored (M1).
const std = @import("std");

pub const cart = @import("cart.zig");
pub const cpu65 = @import("cpu65.zig");
pub const bus = @import("bus.zig");
pub const mikey = @import("mikey.zig");
pub const suzy = @import("suzy.zig");
pub const boot = @import("boot.zig");

pub const Cart = cart.Cart;

/// Picture size (SPEC.md section 6): 160x102, 4 bits per pixel.
pub const screen_w = 160;
pub const screen_h = 102;
/// Bytes of one displayed frame in Lynx RAM (two pixels per byte, the left
/// one in the high nibble).
pub const frame_bytes = screen_w * screen_h / 2;

/// 16 MHz ticks per badge frame: 16,000,000 / 60 = 266,666 + 40/60.
pub const ticks_per_frame: u64 = 266_666;
pub const frame_frac_num: u32 = 40;
pub const frame_frac_den: u32 = 60;

/// Ticks charged for the $FE00 trap (the ROM shifts eight bits out) and,
/// per 51-byte block, for the $FE4A trap (two 408-bit modular multiplies in
/// 6502 code: an estimate, nothing depends on it).
pub const set_block_ticks: u64 = 300;
pub const decrypt_block_ticks: u64 = 100_000;

/// The pad word `step_frame` takes. The low byte is the JOYSTICK register
/// ($FCB0) layout as a game reads it with SPRSYS LEFTHAND clear (cc65
/// _suzy.h); bit 8 is Pause (SWITCHES $FCB1 bit 0). SPEC.md section 5.
pub const Pad = struct {
    pub const a: u16 = 1 << 0; // outer button
    pub const b: u16 = 1 << 1; // inner button
    pub const opt2: u16 = 1 << 2;
    pub const opt1: u16 = 1 << 3;
    pub const right: u16 = 1 << 4;
    pub const left: u16 = 1 << 5;
    pub const down: u16 = 1 << 6;
    pub const up: u16 = 1 << 7;
    pub const pause: u16 = 1 << 8;
};

/// What the frontend shows: `frame_bytes` bytes of 4-bit pixels, row after
/// row, and the palette registers (GREEN $FDA0-$FDAF low nibble, BLUERED
/// $FDB0-$FDBF blue high nibble, red low nibble).
pub const Frame = struct {
    pixels: *const [frame_bytes]u8,
    green: *const [16]u8,
    bluered: *const [16]u8,
};

/// The copy of the last displayed frame (made at vertical blank).
pub const Display = struct {
    pixels: [frame_bytes]u8 = @splat(0),
    green: [16]u8 = @splat(0),
    bluered: [16]u8 = @splat(0),
};

pub const Lynx = struct {
    pub const Cpu = cpu65.Cpu(Lynx);

    // The CPU's bus (core/bus.zig).
    pub const fetch = bus.fetch;
    pub const read = bus.read;
    pub const write = bus.write;
    pub const irq_line = bus.irq_line;

    /// The 64 KB of RAM (display and collision buffers live in it).
    ram: [0x10000]u8,
    cpu: Cpu,
    mikey: mikey.Mikey,
    suzy: suzy.Suzy,
    cart: Cart,
    port: bus.CartPort,
    /// MAPCTL ($FFF9).
    mapctl: u8,
    /// Ticks of a page-mode fetch (4, or 5 with MAPCTL bit 7).
    fetch_ticks: u8,
    /// The CPU's sequential instruction stream is open (core/bus.zig).
    stream_open: bool,
    /// 16 MHz ticks since reset (the bus adds to it).
    ticks: u64,
    /// `ticks` at which the current `step_frame` ends, and the carried
    /// fraction of a tick (in 1/60).
    frame_end: u64,
    frame_frac: u32,
    /// The pad word of the last `step_frame`.
    pad: u16,
    /// Frames stepped since reset.
    frame_count: u32,

    /// Asleep until an interrupt (only with `idle_sleep`).
    sleeping: bool,
    /// The contract's sleep model for CPUSLEEP with no sprites (see the
    /// file comment). Default false: the documented hardware.
    idle_sleep: bool,
    /// The CPU stopped: the cart did not boot.
    halted: bool,
    boot_error: ?boot.BootError,

    display: Display,
    /// Mikey's `vblank_count` at the last display copy.
    vblank_seen: u32,

    // Diagnostics (SPEC.md 14).
    /// Ticks the CPU spent asleep (Suzy drawing, or `idle_sleep`).
    sleep_ticks: u64,
    /// Interrupt sequences the CPU took.
    irq_count: u32,
    /// Ticks the bus spent on video DMA and refresh.
    dma_ticks: u64,
    /// Display copies made (Lynx frames shown).
    display_frames: u32,
    /// Sprite list runs (CPUSLEEP with sprites pending).
    sprite_runs: u32,
    /// Boots re-run because PC entered ROM space elsewhere than a trap.
    rom_resets: u32,

    /// Set up in place (the console is ~75 KB: never build one on the
    /// stack, 32 KB on the badge).
    pub fn init_in_place(l: *Lynx, c: Cart) void {
        l.cart = c;
        l.idle_sleep = false;
        l.reset();
    }

    /// Power on: clocks and diagnostics to zero, then the boot.
    pub fn reset(l: *Lynx) void {
        l.ticks = 0;
        l.frame_end = 0;
        l.frame_frac = 0;
        l.pad = 0;
        l.frame_count = 0;
        l.sleep_ticks = 0;
        l.irq_count = 0;
        l.dma_ticks = 0;
        l.display_frames = 0;
        l.sprite_runs = 0;
        l.rom_resets = 0;
        l.display = .{};
        l.cpu = .{};
        l.reboot();
    }

    /// The boot without touching the clock (reset, or a jump into ROM).
    fn reboot(l: *Lynx) void {
        const instr = l.cpu.instr_count;
        l.cpu = .{};
        l.cpu.instr_count = instr;
        l.mikey.reset(l.ticks);
        l.suzy.reset();
        l.port = .{};
        l.stream_open = false;
        bus.set_mapctl(l, 0);
        l.sleeping = false;
        l.halted = false;
        l.boot_error = null;
        l.vblank_seen = 0;

        var r: bus.PortReader = .{ .port = &l.port, .cart = &l.cart };
        const st = boot.post_boot(&r, &l.ram) catch |e| return l.fail(e);
        for (st.mikey_writes) |w| l.mikey.write(@truncate(w.addr), w.value);
        l.mikey.iodir = st.iodir;
        l.mikey.iodat = st.iodat;
        l.mikey.sysctl1 = st.sysctl1;
        l.mikey.dispadr_latched = l.mikey.dispadr;
        bus.set_mapctl(l, st.mapctl);
        l.port.block = st.cart_block;
        l.port.counter = st.cart_counter;
        l.port.strobe = st.sysctl1 & 1 != 0;
        l.cpu.regs = .{ .a = st.regs.a, .x = st.regs.x, .y = st.regs.y, .s = st.regs.sp, .p = st.regs.p, .pc = st.regs.pc };
    }

    fn fail(l: *Lynx, e: boot.BootError) void {
        l.boot_error = e;
        l.halted = true;
    }

    /// One badge frame of Lynx time.
    pub fn step_frame(l: *Lynx, pad: u16) void {
        l.pad = pad;
        l.frame_frac += frame_frac_num;
        var n = ticks_per_frame;
        if (l.frame_frac >= frame_frac_den) {
            l.frame_frac -= frame_frac_den;
            n += 1;
        }
        l.frame_end += n;
        while (l.ticks < l.frame_end) l.step_one();
        l.frame_count +%= 1;
    }

    /// One instruction, interrupt sequence, trap, or stretch of sleep.
    pub fn step_one(l: *Lynx) void {
        if (l.halted) {
            l.ticks = @max(l.ticks, l.frame_end);
        } else if (l.sleeping) {
            if (l.mikey.irq_line()) {
                l.sleeping = false;
                return;
            }
            const target = @max(l.ticks, @min(l.mikey.next_event, l.frame_end));
            l.sleep_ticks += target - l.ticks;
            l.ticks = target;
        } else {
            const pc = l.cpu.regs.pc;
            const irq = l.mikey.irq_line() and l.cpu.regs.p & cpu65.Flag.i == 0;
            if (!irq and pc >= bus.rom_base and pc < 0xFFF8 and l.mapctl & bus.Mapctl.rom_off == 0) {
                l.rom_entry(pc);
            } else {
                if (irq) l.irq_count +%= 1;
                const before = l.ticks;
                l.cpu.step(l);
                // A step always charges bus cycles; this keeps a CPU that
                // charged none (the M1 stub) from hanging the frame loop.
                if (l.ticks == before) l.ticks += bus.Ticks.fetch;
            }
        }
        bus.sync_mikey(l);
        if (l.mikey.steal != 0) {
            // Video DMA and refresh held the bus (core/mikey.zig).
            l.ticks += l.mikey.steal;
            l.dma_ticks += l.mikey.steal;
            l.mikey.steal = 0;
            l.stream_open = false;
            bus.sync_mikey(l);
        }
        if (l.mikey.vblank_count != l.vblank_seen) l.on_vblank();
    }

    /// PC reached ROM space with the ROM mapped.
    fn rom_entry(l: *Lynx, pc: u16) void {
        switch (pc) {
            boot.entry_set_cart_block => l.trap_set_cart_block(),
            boot.entry_decrypt_frame => l.trap_decrypt_frame(),
            else => {
                l.rom_resets +%= 1;
                l.reboot();
            },
        }
    }

    /// $FE00: select block A on the cart port (eight strobes, counter
    /// cleared), leave the registers as the routine does, then its RTS.
    fn trap_set_cart_block(l: *Lynx) void {
        const X = boot.SetCartBlockExit;
        const r = &l.cpu.regs;
        l.port.block = r.a;
        l.port.counter = 0;
        l.port.strobe = X.sysctl1 & 1 != 0;
        l.mikey.write(mikey.Reg.sysctl1, X.sysctl1);
        l.mikey.write(mikey.Reg.iodat, X.iodat);
        r.a = X.a;
        r.x = X.x;
        r.p = (r.p | X.set_flags) & ~X.clear_flags;
        r.s +%= 1;
        const lo: u16 = l.ram[0x100 | @as(u16, r.s)];
        r.s +%= 1;
        const hi: u16 = l.ram[0x100 | @as(u16, r.s)];
        r.pc = (hi << 8 | lo) +% 1;
        l.ticks += set_block_ticks;
        l.stream_open = false;
    }

    /// $FE4A: decrypt the next frame from the cart port to ($05/$06), then
    /// continue at $0200.
    fn trap_decrypt_frame(l: *Lynx) void {
        var rd: bus.PortReader = .{ .port = &l.port, .cart = &l.cart };
        const res = boot.decrypt_frame(&rd, &l.ram) catch |e| return l.fail(e);
        for (boot.frame_mikey_writes) |w| l.mikey.write(@truncate(w.addr), w.value);
        const r = &l.cpu.regs;
        const F = cpu65.Flag;
        r.a = res.a;
        r.x = res.x;
        r.y = res.y;
        r.p = (r.p & ~(F.n | F.v | F.z | F.c)) | res.nvzc;
        r.pc = boot.loader_entry;
        l.ticks += set_block_ticks + decrypt_block_ticks * res.blocks;
        l.stream_open = false;
    }

    /// CPUSLEEP written (core/bus.zig): see the file comment.
    pub fn cpu_sleep(l: *Lynx) void {
        if (l.mikey.pending() != 0 or l.mikey.suzy_done) return;
        if (l.suzy.sprites_pending()) {
            const t = l.suzy.run_sprites(&l.ram);
            l.ticks += t;
            l.sleep_ticks += t;
            l.sprite_runs +%= 1;
            l.mikey.suzy_done = true;
            return;
        }
        if (l.idle_sleep) l.sleeping = true;
    }

    /// Vertical blank: copy the displayed frame and the palette.
    fn on_vblank(l: *Lynx) void {
        l.vblank_seen = l.mikey.vblank_count;
        if (l.mikey.dispctl & 1 == 0) return;
        const a: u16 = l.mikey.dispadr_latched & 0xFFFC;
        const first = @min(frame_bytes, 0x10000 - @as(usize, a));
        @memcpy(l.display.pixels[0..first], l.ram[a..][0..first]);
        if (first < frame_bytes) @memcpy(l.display.pixels[first..], l.ram[0 .. frame_bytes - first]);
        l.display.green = l.mikey.green;
        l.display.bluered = l.mikey.bluered;
        l.display_frames +%= 1;
    }

    /// The frame to show (the copy made at the last vertical blank).
    pub fn frame(l: *const Lynx) Frame {
        return .{
            .pixels = &l.display.pixels,
            .green = &l.display.green,
            .bluered = &l.display.bluered,
        };
    }

    /// Instructions executed since reset (wraps).
    pub fn instr_count(l: *const Lynx) u32 {
        return l.cpu.instr_count;
    }

    /// Pixels the sprite engine wrote since the last boot (wraps).
    pub fn pixels_drawn(l: *const Lynx) u32 {
        return l.suzy.pixels_drawn;
    }
};

test "lynx: a cart that does not boot halts with a black frame" {
    const S = struct {
        var l: Lynx = undefined;
    };
    const data: [600]u8 = @splat(0x12);
    const lay = cart.parse(&data, data.len);
    S.l.init_in_place(Cart.from_slice(&lay, &data));
    try std.testing.expect(S.l.halted);
    try std.testing.expectEqual(@as(?boot.BootError, error.BadCount), S.l.boot_error);
    S.l.step_frame(0);
    S.l.step_frame(0);
    S.l.step_frame(0);
    try std.testing.expectEqual(@as(u64, 800_000), S.l.ticks);
    try std.testing.expectEqual(@as(u32, 3), S.l.frame_count);
    for (S.l.frame().pixels) |p| try std.testing.expectEqual(@as(u8, 0), p);
}
