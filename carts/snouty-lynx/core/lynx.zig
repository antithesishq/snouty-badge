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
//! the whole list is drawn at once and its bus time (`suzy.run_sprites`)
//! is slept through; the CPU continues when Suzy is done (those ticks count
//! as `sleep_ticks`) or, earlier, when a Mikey interrupt becomes pending:
//! then Suzy is paused with the rest of the time in `sprite_left`, SPRSYS
//! still reads "working", and the next CPUSLEEP resumes it without an
//! SDONEACK (lynx-tests sdoneack IRQ RESLEEP). The pixels are already in
//! RAM at the start of the run; only time and the wake-up are split. With nothing pending the CPU does not sleep:
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
pub const undo = @import("undo.zig");
pub const boot = @import("boot.zig");

pub const Cart = cart.Cart;

/// Picture size (SPEC.md section 6): 160x102, 4 bits per pixel.
pub const screen_w = 160;
pub const screen_h = 102;
/// Bytes of one displayed frame in Lynx RAM (two pixels per byte, the left
/// one in the high nibble).
pub const frame_bytes = screen_w * screen_h / 2;

/// 16 MHz ticks per badge frame: 16,000,000 / 60 = 266,666 + 40/60.
pub const ticks_per_frame: u32 = 266_666;
pub const frame_frac_num: u32 = 40;
pub const frame_frac_den: u32 = 60;

/// Ticks charged for the $FE00 trap (the ROM shifts eight bits out) and,
/// per 51-byte block, for the $FE4A trap (two 408-bit modular multiplies in
/// 6502 code: an estimate, nothing depends on it).
pub const set_block_ticks: u32 = 300;
pub const decrypt_block_ticks: u32 = 100_000;

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
    /// The CPU runs on a `bus.Port` (run_cpu's local view of the console).
    pub const Cpu = cpu65.Cpu(bus.Port);

    // The bus accesses on the console itself (core/bus.zig; the tests'
    // way in, the CPU's is `bus.Port`).
    pub const fetch = bus.fetch;
    pub const read = bus.read;
    pub const dummy = bus.dummy;
    pub const write = bus.write;
    pub const irq_line = bus.irq_line;
    /// $CB/$DB are 1-cycle NOPs on the Lynx (core/cpu65.zig).
    pub const cpu_lynx_nops = true;

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
    fetch_ticks: u32,
    /// Ticks of the next opcode or operand fetch at an address not on a
    /// 16-byte boundary (core/bus.zig): `fetch_ticks` while the CPU's
    /// sequential instruction stream is open, `bus.Ticks.fetch_full` while
    /// it is closed (one byte to test per fetch instead of a flag and
    /// `fetch_ticks`; with MAPCTL bit 7 both are a full cycle anyway).
    fetch_cost: u32,
    /// 16 MHz ticks since `tick_base` (the bus adds to it; `time()` is
    /// the clock since reset). 32-bit for the badge's core: `step_frame`
    /// rebases before it nears 2^31 (`rebase`).
    ticks: u32,
    /// Ticks since reset at `ticks` = 0 (a multiple of 2^20).
    tick_base: u64,
    /// `ticks` at which the current `step_frame` ends, and the carried
    /// fraction of a tick (in 1/60).
    frame_end: u32,
    frame_frac: u32,
    /// `run_cpu`'s bound: below it an instruction needs no Mikey catch-up.
    /// Any Mikey access zeroes it (bus.sync_mikey).
    fast_end: u32,
    /// The pad word of the last `step_frame`.
    pad: u16,
    /// Frames stepped since reset.
    frame_count: u32,

    /// Asleep until an interrupt (only with `idle_sleep`).
    sleeping: bool,
    /// Bus ticks of the current sprite run not yet spent: an interrupt
    /// woke the CPU mid-run (Suzy paused, SPRSYS reads it working); the
    /// next CPUSLEEP resumes it without SDONEACK.
    sprite_left: u32,
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

    /// Power on: clocks and diagnostics to zero, then the boot. RAM is
    /// rewritten past the scrubber's hooks: the frontend calls
    /// `undo.reset` after this (and after `init_in_place`).
    pub fn reset(l: *Lynx) void {
        l.ticks = 0;
        l.tick_base = 0;
        l.frame_end = 0;
        l.frame_frac = 0;
        l.fast_end = 0;
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
        l.fetch_cost = bus.Ticks.fetch_full;
        bus.set_mapctl(l, 0);
        l.sleeping = false;
        l.sprite_left = 0;
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
        if (l.ticks >= rebase_at) l.rebase();
        l.frame_end += n;
        while (l.ticks < l.frame_end) {
            if (l.halted or l.sleeping) l.step_one() else l.run_cpu(false);
        }
        l.frame_count +%= 1;
    }

    /// `ticks` past this at a frame start: `rebase`.
    const rebase_at: u32 = 1 << 30;

    /// Move the clock origin forward by a multiple of 2^20 ticks (every
    /// timer period, the refresh grid and the 16-tick round robin divide
    /// it, so no phase changes): `ticks`, `frame_end` and every clock value
    /// in Mikey and Suzy drop by the same amount, `tick_base` grows by it.
    fn rebase(l: *Lynx) void {
        bus.sync_mikey(l);
        const d = @min(l.ticks, l.frame_end) & ~@as(u32, (1 << 20) - 1);
        l.tick_base += d;
        l.ticks -= d;
        l.frame_end -= d;
        l.mikey.rebase(d);
        l.suzy.rebase(d);
    }

    /// 16 MHz ticks since reset.
    pub fn time(l: *const Lynx) u64 {
        return l.tick_base + l.ticks;
    }

    /// Instructions back to back while nothing but the CPU can happen: the
    /// same as `step_one` per instruction, with the Mikey catch-up after
    /// an instruction skipped while it would do nothing. That is while the
    /// clock stays below `fast_end` (Mikey's next event, or the frame
    /// end): Mikey's state (interrupts, `steal`, `vblank_count`,
    /// `next_event`) only changes at its events or through a register
    /// access, and every access zeroes `fast_end` (bus.sync_mikey), as do
    /// the ROM traps, so the full catch-up runs after that instruction.
    /// Mikey's `now` lags the bus clock in between; nothing reads it before
    /// the next sync. `single`: one instruction (or interrupt sequence or
    /// trap) and its `after_step`, which is `step_one` awake.
    ///
    /// Out of line on purpose, with the CPU's whole opcode switch inlined
    /// into its loop (`step_inline`): the only copy of the switch in the
    /// program (~30 KB), and no call or register save per instruction.
    /// For a build with room to spare (XIP), `noinline` -> `inline` here
    /// puts the loop into `step_frame` and `step_one` (two copies; the
    /// call it saves is once per Mikey event, not per instruction).
    noinline fn run_cpu(l: *Lynx, single: bool) void {
        // DMA that fell in the last catch-up's own steal is charged after
        // the next instruction (`after_step`), as `step_one` does.
        l.fast_end = if (single or l.mikey.steal != 0) 0 else @min(l.frame_end, l.mikey.next_event);
        // The IRQ line is constant for the whole run: only Mikey changes
        // it (its events and register writes), and both end the run after
        // that instruction (`sync_mikey`); the DMA catch-up below changes
        // no interrupt bit.
        const line = l.mikey.irq_line();
        const line_bit: u8 = @intFromBool(line);
        // PCs from here on may be in the mapped boot ROM (a MAPCTL write
        // ends the run: `bus.set_mapctl`); $FFFF only takes the precise
        // test below.
        const rom_lo: u16 = if (l.mapctl & bus.Mapctl.rom_off == 0) bus.rom_base else 0xFFFF;
        l.cpu.normalize_p();
        // Instructions of this run, added to `cpu.instr_count` at its end
        // (nothing reads the count during a run; a reboot keeps it).
        var count: u32 = 0;
        defer l.cpu.instr_count +%= count;
        // The clock and the page-mode state in registers for the run
        // (bus.Port); back in `l` before anything here reads them.
        var port = bus.Port.of(l);
        while (true) {
            step: {
                const pc = l.cpu.regs.pc;
                var irq = false;
                if (pc >= rom_lo or @intFromBool(l.cpu.irq_ok) & line_bit != 0) {
                    irq = l.cpu.takes_irq(line);
                    if (!irq and pc >= bus.rom_base and pc < 0xFFF8 and l.mapctl & bus.Mapctl.rom_off == 0) {
                        port.put();
                        l.rom_entry(pc);
                        port.get();
                        break :step;
                    }
                    if (irq) l.irq_count +%= 1;
                }
                count +%= @intFromBool(!irq);
                l.cpu.step_decided(&port, irq);
            }
            if (port.t < l.fast_end) continue;
            port.put();
            // Only a display burst or refresh due (no register access in
            // the instruction, no timer event, the frame goes on): its
            // catch-up in line.
            if (l.fast_end == 0 or l.ticks >= l.frame_end or l.mikey.timer_event <= l.ticks) break;
            if (!l.dma_catch_up()) return;
            port.get();
            l.fast_end = @min(l.frame_end, l.mikey.next_event);
        }
        l.after_step();
    }

    /// `after_step` when only video DMA or refresh events are due (no timer
    /// event, so no interrupt or vertical blank can come from them): the
    /// same steps, without the general event loop. False when the charged
    /// steal reaches another event or the frame end: then the rest of
    /// `after_step` has been done and `run_cpu` returns.
    inline fn dma_catch_up(l: *Lynx) bool {
        const m = &l.mikey;
        m.now = l.ticks;
        while (m.dma_next <= m.now) m.dma_event(m.dma_next);
        m.next_event = @min(m.timer_event, m.dma_next);
        l.ticks += m.steal;
        l.dma_ticks += m.steal;
        m.steal = 0;
        if (m.steal_burst) l.fetch_cost = bus.Ticks.fetch_full;
        m.steal_burst = false;
        if (l.ticks >= m.next_event or l.ticks >= l.frame_end) {
            bus.sync_mikey(l);
            if (m.vblank_count != l.vblank_seen) l.on_vblank();
            return false;
        }
        m.now = l.ticks;
        return true;
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
            const target = @max(l.ticks, @min(l.mikey.timer_event, l.frame_end));
            l.sleep_ticks += target - l.ticks;
            l.ticks = target;
            // Video DMA and refresh delay nothing while the CPU sleeps.
            bus.sync_mikey(l);
            l.mikey.steal = 0;
            l.mikey.steal_burst = false;
        } else {
            // One instruction, interrupt sequence or trap, then
            // `after_step` (a step always charges bus cycles: at least the
            // opcode fetch, or the interrupt sequence's).
            return l.run_cpu(true);
        }
        l.after_step();
    }

    /// After an instruction: Mikey caught up (its events up to now), the
    /// video DMA and refresh it took charged, the display copied at
    /// vertical blank.
    fn after_step(l: *Lynx) void {
        bus.sync_mikey(l);
        if (l.mikey.steal != 0) {
            // Video DMA and refresh held the bus (core/mikey.zig).
            l.ticks += l.mikey.steal;
            l.dma_ticks += l.mikey.steal;
            l.mikey.steal = 0;
            // A display burst takes the DRAM page: the next fetch is a full
            // cycle (lynx-page-mode.md). A refresh does not break the
            // stream: lynx-tests page-mode NOP PM ON measures $35 only
            // without that (fitted; the timers ONESHOT+LINK loop, in
            // visible lines, needs the burst break to reach 13 IRQs).
            if (l.mikey.steal_burst) l.fetch_cost = bus.Ticks.fetch_full;
            l.mikey.steal_burst = false;
            bus.sync_mikey(l);
        }
        if (l.mikey.vblank_count != l.vblank_seen) l.on_vblank();
    }

    /// PC reached ROM space with the ROM mapped.
    fn rom_entry(l: *Lynx, pc: u16) void {
        // The traps write Mikey's registers directly: bring its clock up
        // first (`run_cpu` lets it lag).
        bus.sync_mikey(l);
        switch (pc) {
            boot.entry_set_cart_block => l.trap_set_cart_block(),
            boot.entry_decrypt_frame => l.trap_decrypt_frame(),
            else => {
                l.rom_resets +%= 1;
                // The boot clears and rewrites all of RAM past the bus.
                undo.touch_range(0, 0x10000);
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
        l.fetch_cost = bus.Ticks.fetch_full;
    }

    /// $FE4A: decrypt the next frame from the cart port to ($05/$06), then
    /// continue at $0200.
    fn trap_decrypt_frame(l: *Lynx) void {
        var rd: bus.PortReader = .{ .port = &l.port, .cart = &l.cart };
        // decrypt_frame writes RAM past the bus: its zero-page bytes ($02,
        // $05, $07) and up to 250 bytes wrapping within the page at $06.
        undo.touch(boot.zp_count);
        undo.touch_range(@as(u16, l.ram[boot.zp_dest_hi]) << 8, 0x100);
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
        l.fetch_cost = bus.Ticks.fetch_full;
    }

    /// CPUSLEEP written (core/bus.zig): see the file comment.
    /// Out of line: Suzy's register writes share `bus.high_write` with
    /// this rare path, and should not pay its register saves.
    pub noinline fn cpu_sleep(l: *Lynx) void {
        if (l.mikey.pending() != 0 or l.mikey.suzy_done) return;
        if (l.sprite_left == 0) {
            if (!l.suzy.sprites_pending()) {
                if (l.idle_sleep) l.sleeping = true;
                return;
            }
            l.sprite_left = l.suzy.run_sprites(&l.ram);
            l.sprite_runs +%= 1;
        }
        l.sprite_sleep();
    }

    /// Asleep while Suzy spends `sprite_left` bus ticks, until she is done
    /// (SDONEACK needed before the next sleep) or a Mikey interrupt is
    /// pending (masked or not: the CPU wakes, Suzy pauses with the rest
    /// still to do). The list was already drawn into RAM by `run_sprites`;
    /// only the time and the wake-up are split. Video DMA in the run
    /// extends it (Suzy waits for the bus too).
    fn sprite_sleep(l: *Lynx) void {
        bus.sync_mikey(l);
        while (true) {
            if (l.sprite_left == 0) {
                l.mikey.suzy_done = true;
                return;
            }
            // (The catch-up on entry may already have raised an
            // interrupt: then the step below and its test come first.)
            if (l.mikey.steal == 0 and l.mikey.pending() == 0 and l.sleep_through_dma()) return;
            const step = @min(l.sprite_left, l.mikey.next_event -| l.ticks);
            l.ticks += step;
            l.sleep_ticks += step;
            l.sprite_left -= step;
            bus.sync_mikey(l);
            if (l.mikey.steal != 0) {
                l.ticks += l.mikey.steal;
                l.sleep_ticks += l.mikey.steal;
                l.dma_ticks += l.mikey.steal;
                l.mikey.steal = 0;
                bus.sync_mikey(l);
            }
            l.mikey.steal_burst = false;
            if (l.sprite_left != 0 and l.mikey.pending() != 0) return;
        }
    }

    /// `sprite_sleep`'s steps while the next event is a display burst or
    /// refresh due before the run ends and before any timer event (most
    /// of a run: one every 192 or 256 ticks), with the clock and counters
    /// in locals: sleep to the event, run it, add its steal, catch up to
    /// the new time. Mikey is caught up, nothing is stolen and no
    /// interrupt is pending on entry;
    /// on return the same holds unless the last catch-up left steal for
    /// `sprite_sleep`'s next step. True when that catch-up ran a timer
    /// event that woke the CPU (the run is not over: `sprite_sleep`
    /// returns).
    inline fn sleep_through_dma(l: *Lynx) bool {
        const m = &l.mikey;
        var t = l.ticks;
        var left = l.sprite_left;
        var sleep: u32 = 0;
        var dma: u32 = 0;
        var woke = false;
        while (m.steal == 0 and m.dma_next < m.timer_event and m.dma_next - t < left) {
            const e = m.dma_next;
            left -= e - t;
            sleep += e - t;
            m.now = e;
            m.dma_event(e);
            m.next_event = @min(m.timer_event, m.dma_next);
            const st = m.steal;
            m.steal = 0;
            t = e + st;
            sleep += st;
            dma += st;
            m.now = t;
            if (t >= m.next_event) {
                const timers = m.timer_event <= t;
                m.advance_to(t);
                if (timers and m.pending() != 0) woke = true;
            }
            m.steal_burst = false;
            if (woke) break;
        }
        l.ticks = t;
        l.sprite_left = left;
        l.sleep_ticks += sleep;
        l.dma_ticks += dma;
        return woke;
    }

    /// The sprite engine is mid-run (SPRSYS bit 0 reads set).
    pub fn sprite_paused(l: *const Lynx) bool {
        return l.sprite_left != 0;
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

    /// Copy the frame at the latched DISPADR and the palette into `display`
    /// without stepping (what `on_vblank` does): the picture of a restored
    /// state while the scrubber is parked (M3). Changes nothing but
    /// `display` (not even `display_frames`: a parked state must stay
    /// equal to the one recorded), so it may be called any number of
    /// times. A game that draws into the shown buffer after vertical blank
    /// may differ from what was shown at that moment; the next live
    /// vertical blank replaces it.
    pub fn refresh_display(l: *Lynx) void {
        const a: u16 = l.mikey.dispadr_latched & 0xFFFC;
        const first = @min(frame_bytes, 0x10000 - @as(usize, a));
        @memcpy(l.display.pixels[0..first], l.ram[a..][0..first]);
        if (first < frame_bytes) @memcpy(l.display.pixels[first..], l.ram[0 .. frame_bytes - first]);
        l.display.green = l.mikey.green;
        l.display.bluered = l.mikey.bluered;
    }

    // ---- The scrubber's small state (M3, core/undo.zig) ----

    /// Every console field outside `ram` that is console state: the head
    /// of every undo record. Excluded (`small_excluded`): `ram` (the
    /// record's blocks), `cart` (the ROM, read-only: only the port's block
    /// and counter are state, in `port`), `display` (an output copy the
    /// game never reads; `refresh_display` rebuilds it) and `idle_sleep`
    /// (a frontend setting). The diagnostics are in, so a restored state
    /// equals the saved one field for field. Compare field by field, never
    /// as bytes (padding is zeroed by `save_small` only so equal states
    /// give equal record bytes). Nothing in it holds a pointer
    /// (comptime-checked below), so a record is position-independent.
    pub const Small = struct {
        cpu: Cpu,
        mikey: mikey.Mikey,
        suzy: suzy.Suzy,
        port: bus.CartPort,
        mapctl: u8,
        fetch_ticks: u32,
        fetch_cost: u32,
        ticks: u32,
        tick_base: u64,
        frame_end: u32,
        frame_frac: u32,
        fast_end: u32,
        pad: u16,
        frame_count: u32,
        sleeping: bool,
        sprite_left: u32,
        halted: bool,
        boot_error: ?boot.BootError,
        vblank_seen: u32,
        sleep_ticks: u64,
        irq_count: u32,
        dma_ticks: u64,
        display_frames: u32,
        sprite_runs: u32,
        rom_resets: u32,
    };

    /// The `Lynx` fields `Small` leaves out on purpose (see `Small`).
    pub const small_excluded = [_][]const u8{ "ram", "cart", "display", "idle_sleep" };

    pub fn save_small(l: *const Lynx, out: *Small) void {
        @memset(std.mem.asBytes(out), 0);
        inline for (@typeInfo(Small).@"struct".field_names) |name| @field(out, name) = @field(l, name);
    }

    /// Apply a `Small`; `ram` is the caller's. Keeps `cart`, `display` and
    /// `idle_sleep`.
    pub fn load_small(l: *Lynx, k: *const Small) void {
        inline for (@typeInfo(Small).@"struct".field_names) |name| @field(l, name) = @field(k, name);
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

// `Lynx.Small` is every `Lynx` field but `Lynx.small_excluded`, with the
// same types, and holds no pointer: a field added to the console must be
// classified here (put in `Small`, or excluded on purpose), or this fails.
comptime {
    const lf = @typeInfo(Lynx).@"struct".field_names;
    const sf = @typeInfo(Lynx.Small).@"struct".field_names;
    for (lf) |name| {
        var excluded = false;
        for (Lynx.small_excluded) |x| {
            if (std.mem.eql(u8, x, name)) excluded = true;
        }
        if (excluded) {
            if (@hasField(Lynx.Small, name)) @compileError("Lynx.Small holds an excluded field: " ++ name);
        } else if (!@hasField(Lynx.Small, name)) {
            @compileError("Lynx field not classified for the scrubber (Lynx.Small or small_excluded): " ++ name);
        }
    }
    if (lf.len != sf.len + Lynx.small_excluded.len) @compileError("Lynx.small_excluded names a field Lynx lacks");
    for (sf) |name| {
        if (!@hasField(Lynx, name)) @compileError("Lynx.Small field not in Lynx: " ++ name);
        if (@FieldType(Lynx.Small, name) != @FieldType(Lynx, name)) @compileError("Lynx.Small field type differs: " ++ name);
    }
    if (has_pointer(Lynx.Small)) @compileError("Lynx.Small must hold no pointer (records are swapped as bytes)");
}

/// Does `T` contain a pointer anywhere (struct fields, arrays, optionals)?
fn has_pointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .@"struct" => blk: {
            for (@typeInfo(T).@"struct".field_names) |name| {
                if (has_pointer(@FieldType(T, name))) break :blk true;
            }
            break :blk false;
        },
        .array => |a| has_pointer(a.child),
        .optional => |o| has_pointer(o.child),
        .@"union", .@"opaque", .@"fn" => true,
        else => false,
    };
}

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
