//! Snouty Boy core: the whole Game Boy in one struct, badge-agnostic.
//! No cart-api, no floats, no allocator, no clock, no randomness: the only
//! input is the joypad byte given to `step_frame`. See SPEC.md sections 3,
//! 4, 7, 10.3 and 19 (Game Boy Color). PLAN.md has the M6 file ownership
//! and interface contract.
const std = @import("std");

pub const cpu = @import("cpu.zig");
pub const mmu = @import("mmu.zig");
pub const ppu = @import("ppu.zig");
pub const timer = @import("timer.zig");
pub const apu = @import("apu.zig");
pub const serial = @import("serial.zig");
pub const joypad = @import("joypad.zig");
pub const ring = @import("ring.zig");
pub const kstore = @import("kstore.zig");
pub const rom_mod = @import("rom.zig");
pub const Rom = rom_mod.Rom;

pub const screen_w = 160;
pub const screen_h = 144;
/// M-cycles in one Game Boy frame at normal speed (70,224 T-cycles / 4).
pub const frame_m_cycles: u32 = 17_556;
/// PPU dots (T-cycles at normal speed) in one frame, at either CPU speed.
pub const frame_dots: u32 = 70_224;

/// Which console the core behaves as (SPEC.md 19.1). DMG games run as a
/// DMG; CGB-flagged games run as a CGB. Tests pick either explicitly.
pub const Model = enum(u1) { dmg, cgb };

/// The model a ROM boots in on a Game Boy Color: CGB if header byte 0x143
/// has bit 7 set (0x80 CGB-enhanced, 0xC0 CGB-only).
pub fn default_model(rom: *const Rom) Model {
    if (rom.len < 0x150) return .dmg;
    return if ((rom.read(0x143) & 0x80) != 0) .cgb else .dmg;
}

/// Interrupt bits in IF (0xFF0F) and IE (0xFFFF).
pub const Irq = struct {
    pub const vblank: u8 = 1 << 0;
    pub const stat: u8 = 1 << 1;
    pub const timer: u8 = 1 << 2;
    pub const serial: u8 = 1 << 3;
    pub const joypad: u8 = 1 << 4;
};

/// I/O register offsets from 0xFF00 (index into `Gb.io`).
pub const Reg = struct {
    pub const p1: u8 = 0x00;
    pub const sb: u8 = 0x01;
    pub const sc: u8 = 0x02;
    pub const div: u8 = 0x04;
    pub const tima: u8 = 0x05;
    pub const tma: u8 = 0x06;
    pub const tac: u8 = 0x07;
    pub const if_: u8 = 0x0F;
    pub const nr10: u8 = 0x10;
    pub const nr52: u8 = 0x26;
    pub const lcdc: u8 = 0x40;
    pub const stat: u8 = 0x41;
    pub const scy: u8 = 0x42;
    pub const scx: u8 = 0x43;
    pub const ly: u8 = 0x44;
    pub const lyc: u8 = 0x45;
    pub const dma: u8 = 0x46;
    pub const bgp: u8 = 0x47;
    pub const obp0: u8 = 0x48;
    pub const obp1: u8 = 0x49;
    pub const wy: u8 = 0x4A;
    pub const wx: u8 = 0x4B;
    // CGB only (SPEC.md 19.1).
    pub const key1: u8 = 0x4D;
    pub const vbk: u8 = 0x4F;
    pub const hdma1: u8 = 0x51;
    pub const hdma2: u8 = 0x52;
    pub const hdma3: u8 = 0x53;
    pub const hdma4: u8 = 0x54;
    pub const hdma5: u8 = 0x55;
    pub const rp: u8 = 0x56;
    pub const bcps: u8 = 0x68;
    pub const bcpd: u8 = 0x69;
    pub const ocps: u8 = 0x6A;
    pub const ocpd: u8 = 0x6B;
    pub const opri: u8 = 0x6C;
    pub const svbk: u8 = 0x70;
};

/// One rendered scanline, delivered by the PPU as each visible line is
/// rendered, in order 0..143, once per frame while the LCD is on.
/// DMG mode: 160 final shades, 0 = lightest, 3 = darkest (BGP/OBP applied).
/// CGB mode: 160 colour indices, `pal * 4 + colour` for BG (0..31) and
/// `32 + pal * 4 + colour` for OBJ (32..63), looked up in `ppu.bg_pal` /
/// `ppu.obj_pal` as they are when the line is emitted (SPEC.md 19.2).
pub const LineSink = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, ly: u8, line: *const [screen_w]u8) void,

    pub fn emit(self: LineSink, ly: u8, line: *const [screen_w]u8) void {
        self.func(self.ctx, ly, line);
    }
};

/// Joypad byte fed to `step_frame`: bit set = pressed.
pub const Pad = struct {
    pub const right: u8 = 1 << 0;
    pub const left: u8 = 1 << 1;
    pub const up: u8 = 1 << 2;
    pub const down: u8 = 1 << 3;
    pub const a: u8 = 1 << 4;
    pub const b: u8 = 1 << 5;
    pub const select: u8 = 1 << 6;
    pub const start: u8 = 1 << 7;
};

pub const Gb = struct {
    /// Fixed at `init`; `reset` keeps it.
    model: Model = .dmg,

    // ---- CPU (owner: core/cpu.zig) ----
    cpu: cpu.Cpu = .{},
    /// PPU/APU dots per CPU M-cycle as a shift: 2 at normal speed, 1 in
    /// CGB double speed (KEY1 + STOP, owner core/cpu.zig).
    dot_shift: u2 = 2,
    /// CPU M-cycles the CPU is stalled for by GDMA/HDMA or the speed switch
    /// (owner core/mmu.zig and core/cpu.zig). `step_frame` ticks them away
    /// after the instruction that caused them.
    stall_m: u16 = 0,

    // ---- Memory (owner: core/mmu.zig) ----
    mbc: mmu.Mbc = .{},
    /// Cached pointers to the ROM banks mapped at 0x0000 and 0x4000, from
    /// `rom.banks` via the MBC's offsets (`mmu.remap_rom`); null sends the
    /// read through `Rom.read` (a fragmented drive file, a partial or
    /// missing bank). Derived state, not in keyframes.
    rom0: ?[*]const u8 = null,
    romn: ?[*]const u8 = null,
    /// Cached VRAM/WRAM bank offsets (VBK, SVBK). DMG mode keeps VRAM at
    /// bank 0 and D000 at WRAM bank 1.
    banks: mmu.Banks = .{},
    /// CGB general/HBlank DMA state (HDMA1..5).
    hdma: mmu.Hdma = .{},
    oam: [0xA0]u8 = @splat(0),
    hram: [0x7F]u8 = @splat(0),
    /// External cart RAM, owned by whoever calls `init`: at least
    /// `mmu.cart_ram_len(rom)` bytes (at most 32 KB is used, SPEC.md 19.1).
    cart_ram: []u8 = &.{},
    /// Raw I/O registers 0xFF00..0xFF7F. Subsystems keep their register
    /// values here so that snapshot/restore is a plain struct copy.
    io: [0x80]u8 = @splat(0),
    ie: u8 = 0,

    // ---- Subsystems ----
    ppu: ppu.Ppu = .{},
    timer: timer.Timer = .{},
    apu: apu.Apu = .{},
    serial: serial.Serial = .{},
    /// Current joypad state (Pad bits), set by `step_frame`.
    pad: u8 = 0,

    // ---- Sound samples (owner: core/apu.zig "Sample generation") ----
    /// Render the APU into `snd` (set with `apu.set_render`). Off: the
    /// register model runs as it always did and nothing is rendered. Not
    /// console state; `reset` keeps it.
    audio_render: bool = false,
    /// Samples the last `step_frame` left in `snd.out` (`apu.samples`).
    audio_len: u16 = 0,
    /// Render state and output, owned by the caller (3.7 KB, kept out of
    /// `Gb` so the hot fields keep their offsets). Not console state;
    /// `reset` keeps the pointer, `load_small` resets what it points at.
    snd: ?*apu.Snd = null,

    // ---- Frame bookkeeping (owner: core/gb.zig) ----
    /// Dots run so far in the current `step_frame` call.
    frame_dots: u32 = 0,
    /// Set by the PPU when it enters VBlank; cleared by `step_frame`.
    vblank_hit: bool = false,
    /// Total frames stepped since reset (wraps).
    frame_count: u32 = 0,
    /// PC of the opcode `cpu.step` is executing, and the M-cycles of it
    /// already ticked by `sync_for_read` (CGB LY/STAT reads). Not console
    /// state: both are rebuilt every instruction.
    op_pc: u16 = 0x0100,
    pre_m: u8 = 0,
    /// CPU M-cycles the timer, PPU and APU have not been given yet, and the
    /// M-cycles after the last flush at which one of them has an event
    /// (`tick_lazy`). Not console state: `step_frame` ends with a sync and
    /// `load_small` clears both (`ev_m` 0 forces a flush on the next tick).
    pend_m: u32 = 0,
    ev_m: u32 = 0,

    /// Where rendered lines go. Not part of the console state: excluded
    /// from keyframes by `snapshot`, set once by the frontend.
    line_sink: ?LineSink = null,
    /// Visible lines the frontend wants rendered, one bit per LY (bit
    /// `ly & 31` of word `ly >> 5`), default all. The PPU skips the pixel
    /// work of a cleared line (no `line_sink` call) but still does its
    /// window-line and timing bookkeeping, so the mask never changes
    /// console state. Not console state; `reset` keeps it.
    lines_wanted: [5]u32 = @splat(0xFFFF_FFFF),
    /// Set by the PPU whenever CGB palette RAM is written; cleared by the
    /// frontend when it has rebuilt its colour table. Not console state:
    /// excluded from keyframes (the frontend sets it itself after a restore).
    pal_dirty: bool = true,

    /// The cartridge image as 16 KB bank pointers (core/rom.zig): an
    /// embedded ROM or a file on the badge drive. Immutable, not console
    /// state. Only the header and the slow path read it; the hot path uses
    /// `rom0`/`romn`, so it sits past the hot fields.
    rom: Rom,

    // ---- Big memories last (owner: core/mmu.zig) ----
    // Declared after every other field so the small hot fields (CPU, I/O,
    // PPU, timer) sit within the 4 KB immediate-offset reach of Thumb-2
    // loads from the `Gb` base: one `ldrb r, [base, #off]` instead of
    // `movw` + `ldrb` per access (the auto layout keeps declaration order
    // among byte-aligned fields).
    /// Two 8 KB banks on CGB; DMG uses the first.
    vram: [0x4000]u8 = @splat(0),
    /// Eight 4 KB banks on CGB; DMG uses the first two.
    wram: [0x8000]u8 = @splat(0),

    /// Construct a console around a ROM image and reset it to the post-boot
    /// state of `model` (SPEC.md sections 3 and 19). The memory `rom` points
    /// into and `cart_ram` must outlive the Gb; `cart_ram` needs
    /// `mmu.cart_ram_len(&rom)` bytes.
    pub fn init(rom: Rom, model: Model, cart_ram: []u8) Gb {
        var gb: Gb = .{ .rom = rom, .model = model, .cart_ram = cart_ram };
        gb.reset();
        return gb;
    }

    /// `init` into memory the caller already has (the badge's arena): no
    /// 50 KB `Gb` temporary on the 32 KB stack.
    pub fn init_in(gb: *Gb, rom: Rom, model: Model, cart_ram: []u8) void {
        gb.rom = rom;
        gb.model = model;
        gb.cart_ram = cart_ram;
        gb.line_sink = null;
        gb.lines_wanted = @splat(0xFFFF_FFFF);
        gb.snd = null;
        gb.audio_render = false;
        gb.reset();
    }

    /// `init` around a contiguous image (host tests, an embedded ROM).
    pub fn init_slice(bytes: []const u8, model: Model, cart_ram: []u8) Gb {
        return init(Rom.from_slice(bytes), model, cart_ram);
    }

    /// Post-boot state. Memory, cart RAM included, is zeroed (SPEC.md 10.3).
    pub fn reset(gb: *Gb) void {
        const rom = gb.rom;
        const sink = gb.line_sink;
        const model = gb.model;
        const cart_ram = gb.cart_ram;
        const wanted = gb.lines_wanted;
        const snd = gb.snd;
        const render = gb.audio_render;
        gb.* = .{ .rom = rom, .line_sink = sink, .model = model, .cart_ram = cart_ram, .lines_wanted = wanted, .snd = snd, .audio_render = render };
        if (render) snd.?.reset();
        @memset(cart_ram, 0);
        gb.mbc = mmu.Mbc.from_header(&gb.rom);
        mmu.remap_rom(gb);
        cpu.reset(gb);
        mmu.reset_io(gb);
        ppu.reset(gb);
        timer.reset(gb);
        apu.reset(gb);
    }

    pub inline fn is_cgb(gb: *const Gb) bool {
        return gb.model == .cgb;
    }

    /// Run one frame: until the PPU enters VBlank, or, with the LCD off,
    /// for `frame_dots` dots. Exactly one call per badge frame.
    pub fn step_frame(gb: *Gb, pad: u8) void {
        gb.pad = pad;
        joypad.update(gb);
        gb.frame_dots = 0;
        gb.vblank_hit = false;
        while (!gb.vblank_hit and gb.frame_dots < frame_dots * 2) {
            gb.step_instruction();
            if (!ppu.lcd_on(gb) and gb.frame_dots >= frame_dots) break;
        }
        // Everything outside the core (frontend, keyframes) sees caught-up
        // subsystems.
        gb.sync();
        if (gb.audio_render) apu.end_frame(gb);
        gb.frame_count +%= 1;
    }

    /// One instruction (or interrupt dispatch) and everything it clocks:
    /// the M-cycles `sync_for_read` has not ticked yet, then any DMA or
    /// speed-switch stall it caused.
    pub inline fn step_instruction(gb: *Gb) void {
        var m = @call(.always_inline, cpu.step, .{gb});
        if (gb.pre_m != 0) {
            m -= gb.pre_m;
            gb.pre_m = 0;
        }
        gb.tick_lazy(m);
        while (gb.stall_m != 0) {
            const s: u8 = @intCast(@min(gb.stall_m, 0xFF));
            gb.stall_m -= s;
            gb.tick_lazy(s);
        }
    }

    /// M-cycles a halted CPU skips in one step (`cpu.step`). The CPU used
    /// to step 4 M-cycles at a time while halted, waking at the first
    /// 4-cycle boundary after an interrupt flag rose. This returns whole
    /// 4-cycle chunks up to and including the chunk in which the next
    /// thing that can end the halt or the frame happens: a PPU mode or line
    /// change (the VBlank/STAT sources, HBlank DMA, the frame's VBlank),
    /// the next TIMA overflow, or the frame loop's dot limit. Nothing else
    /// changes while halted, and the timer, PPU and APU tick batches
    /// exactly, so the result is identical to stepping by 4. Capped at
    /// `max_halt_m`, which also keeps each tick under one APU sequencer
    /// step (8192 dots).
    pub fn halt_m(gb: *const Gb) u8 {
        const sh: u5 = gb.dot_shift;
        const dpm: u32 = @as(u32, 1) << sh; // dots per M-cycle
        // M-cycles until the event, rounded up: the event happens during
        // that M-cycle.
        var e: u32 = max_halt_m;
        const lcd = ppu.lcd_on(gb);
        const limit: u32 = if (lcd) frame_dots * 2 else frame_dots;
        if (gb.frame_dots < limit) e = @min(e, (limit - gb.frame_dots + dpm - 1) >> sh);
        if (lcd) {
            const d: u32 = gb.ppu.next_t -| gb.ppu.line_t;
            e = @min(e, (d + dpm - 1) >> sh);
        }
        const tac = gb.io[Reg.tac];
        if (tac & 0x04 != 0) e = @min(e, timer.m_to_overflow(gb));
        // Whole chunks, at least one.
        return @intCast(@max(4, (e + 3) & ~@as(u32, 3)));
    }

    /// Upper bound of `halt_m` (a multiple of 4).
    pub const max_halt_m: u32 = 252;

    /// Bring the subsystems up to the M-cycle of a CPU read in the middle
    /// of an instruction (CGB mode, LY and STAT only). `step_frame` ticks
    /// after each whole instruction, so without this `cp [hl]` on LY sees
    /// the line before, and a VBlank interrupt raised by the same
    /// instruction is taken first: `wait LY == 144` loops with IME on (e.g.
    /// Rebound before its level loop) never exit. On hardware the read is
    /// at the operand's M-cycle, which for the reading instructions is the
    /// number of bytes fetched so far: `cp [hl]` 1, `ldh a,[n]` 2,
    /// `ld a,[nn]` 3, `bit b,[hl]` 2. Between instructions PC equals `op_pc`,
    /// so reads from the frontend or tests never tick.
    pub fn sync_for_read(gb: *Gb) void {
        const done = gb.cpu.pc -% gb.op_pc;
        if (done > 3 or done <= gb.pre_m) return;
        const n: u8 = @intCast(done - gb.pre_m);
        gb.pre_m = @intCast(done);
        // Lazily: LY and STAT only change at PPU events, and `tick_lazy`
        // flushes when the read's M-cycle reaches one.
        gb.tick_lazy(n);
    }

    /// Advance every subsystem by `m` CPU M-cycles now (tests, mid-
    /// instruction reads). Timer, serial and DMA run at CPU speed; the PPU
    /// and APU get dots, which is half as many per M-cycle in double speed
    /// (SPEC.md 19.1).
    pub fn tick(gb: *Gb, m: u8) void {
        gb.frame_dots += @as(u32, m) << gb.dot_shift;
        gb.pend_m += m;
        gb.flush();
    }

    /// The frame loop's tick (SPEC.md 8, event-driven catch-up): the
    /// M-cycles only accumulate in `pend_m` until the next subsystem event
    /// is due (`ev_m`, see `flush`), so a typical instruction costs two
    /// adds and a compare. Register reads and writes that can observe or
    /// change the subsystems call `sync` first (mmu.zig), and `flush`
    /// runs after the instruction whose cycles reach the event, exactly
    /// where the eager tick would have processed it, so the result is
    /// identical to ticking everything after every instruction.
    pub inline fn tick_lazy(gb: *Gb, m: u8) void {
        gb.frame_dots += @as(u32, m) << gb.dot_shift;
        gb.pend_m += m;
        if (gb.pend_m >= gb.ev_m) gb.flush();
    }

    /// Bring the timer, PPU and APU up to date if cycles are pending.
    pub inline fn sync(gb: *Gb) void {
        if (gb.pend_m != 0) gb.flush();
    }

    /// Give the pending M-cycles to every subsystem, then find the next
    /// event. `pend_m` is cleared first: a flush can re-enter through an
    /// HBlank DMA reading I/O, which then has nothing to catch up.
    pub fn flush(gb: *Gb) void {
        const m = gb.pend_m;
        gb.pend_m = 0;
        const dots = m << gb.dot_shift;
        timer.tick(gb, m);
        ppu.tick(gb, @intCast(dots));
        mmu.tick_dma(gb, m);
        apu.tick(gb, @intCast(dots));
        serial.tick(gb, m);
        gb.reschedule();
    }

    /// `ev_m`: M-cycles from now to the first moment a subsystem changes
    /// state on its own in a way the CPU could observe without reading
    /// its registers (those reads sync): a PPU mode or line change, an
    /// APU frame sequencer step, a TIMA overflow. Called after every
    /// flush and every I/O write.
    pub fn reschedule(gb: *Gb) void {
        const sh: u5 = gb.dot_shift;
        const dpm: u32 = @as(u32, 1) << sh;
        var e: u32 = max_ev_m;
        if (ppu.lcd_on(gb)) e = @min(e, ((gb.ppu.next_t -| gb.ppu.line_t) + dpm - 1) >> sh);
        if (gb.io[Reg.nr52] & 0x80 != 0) e = @min(e, ((apu.seq_period_dots -| gb.apu.seq_t) + dpm - 1) >> sh);
        if (gb.io[Reg.tac] & 0x04 != 0) e = @min(e, timer.m_to_overflow(gb));
        gb.ev_m = e;
    }

    /// Cap of `ev_m`: long enough to be rare, short enough that `pend_m`
    /// (plus one stall chunk) stays far below any tick's limits.
    pub const max_ev_m: u32 = 4096;

    pub inline fn line_wanted(gb: *const Gb, ly: u8) bool {
        return (gb.lines_wanted[ly >> 5] >> @as(u5, @truncate(ly))) & 1 != 0;
    }

    /// Render only the lines whose bit is set (see `lines_wanted`).
    pub fn set_lines_wanted(gb: *Gb, mask: [5]u32) void {
        gb.lines_wanted = mask;
    }

    pub inline fn request_irq(gb: *Gb, bit: u8) void {
        gb.io[Reg.if_] |= bit;
    }

    pub inline fn read8(gb: *Gb, addr: u16) u8 {
        return mmu.read8(gb, addr);
    }

    pub inline fn write8(gb: *Gb, addr: u16, v: u8) void {
        mmu.write8(gb, addr, v);
    }

    // ---- Keyframes (SPEC.md sections 10 and 19.3) ----

    /// Every snapshotted field except VRAM, WRAM and cart RAM, which the
    /// page store (core/kstore.zig) keeps as their own regions. `rom`, the
    /// cached bank pointers, `model`, `cart_ram` (the slice), `line_sink`
    /// and `pal_dirty` are not console state.
    pub const Small = struct {
        cpu: cpu.Cpu,
        dot_shift: u2,
        stall_m: u16,
        mbc: mmu.Mbc,
        banks: mmu.Banks,
        hdma: mmu.Hdma,
        oam: [0xA0]u8,
        hram: [0x7F]u8,
        io: [0x80]u8,
        ie: u8,
        ppu: ppu.Ppu,
        timer: timer.Timer,
        apu: apu.Apu,
        serial: serial.Serial,
        pad: u8,
        frame_count: u32,
    };

    /// Pack the small state into `out`. The bytes are zeroed first so that
    /// padding between fields is always 0 and two packs of equal state
    /// compare equal byte for byte (the page store relies on it for
    /// sharing, not for correctness).
    pub fn save_small(gb: *const Gb, out: *Small) void {
        @memset(std.mem.asBytes(out), 0);
        inline for (@typeInfo(Small).@"struct".field_names) |name| {
            @field(out, name) = @field(gb, name);
        }
    }

    pub fn load_small(gb: *Gb, k: *const Small) void {
        inline for (@typeInfo(Small).@"struct".field_names) |name| {
            @field(gb, name) = @field(k, name);
        }
        mmu.remap_rom(gb);
        gb.frame_dots = 0;
        gb.vblank_hit = false;
        gb.pal_dirty = true;
        gb.op_pc = gb.cpu.pc;
        gb.pre_m = 0;
        gb.pend_m = 0;
        gb.ev_m = 0;
        if (gb.snd) |snd| snd.reset();
        gb.audio_len = 0;
    }

    /// The console state as byte regions, in a fixed order: the packed
    /// `small` (caller-owned, filled by `save_small` before a snapshot and
    /// applied with `load_small` after a restore), VRAM, WRAM, cart RAM.
    pub fn state_regions(gb: *Gb, small: *Small) [4][]u8 {
        return .{ std.mem.asBytes(small), &gb.vram, &gb.wram, gb.cart_ram };
    }

    /// A whole keyframe in one struct (host tests, the in-cart self check).
    /// Cart RAM is stored in full (32 KB); see `KeyframeWith`.
    pub const Keyframe = KeyframeWith(max_cart_ram);
    pub const max_cart_ram = 0x8000;

    /// A keyframe holding the first `ram_len` bytes of cart RAM
    /// (`KeyframeWith(mmu.cart_ram_len(rom))`). `restore` leaves bytes past
    /// `ram_len` untouched.
    ///
    /// Auto-layout struct: padding bytes are undefined, so compare two
    /// keyframes field by field (`std.meta.eql`), never as raw bytes.
    pub fn KeyframeWith(comptime ram_len: usize) type {
        if (ram_len > max_cart_ram) @compileError("cart RAM is at most 32 KB");
        return struct {
            pub const cart_ram_len = ram_len;

            small: Small,
            vram: [0x4000]u8,
            wram: [0x8000]u8,
            cart_ram: [ram_len]u8,
        };
    }

    /// Copy the console into `out`, a `*Keyframe` or `*KeyframeWith(n)`.
    /// `gb.cart_ram` must hold at least n bytes.
    pub fn snapshot(gb: *const Gb, out: anytype) void {
        const K = @typeInfo(@TypeOf(out)).pointer.child;
        gb.save_small(&out.small);
        out.vram = gb.vram;
        out.wram = gb.wram;
        const n = @min(K.cart_ram_len, gb.cart_ram.len);
        @memcpy(out.cart_ram[0..n], gb.cart_ram[0..n]);
        @memset(out.cart_ram[n..], 0);
    }

    /// Put a keyframe (`*const Keyframe` or `*const KeyframeWith(n)`) back.
    pub fn restore(gb: *Gb, k: anytype) void {
        const K = @typeInfo(@TypeOf(k)).pointer.child;
        gb.load_small(&k.small);
        gb.vram = k.vram;
        gb.wram = k.wram;
        const n = @min(K.cart_ram_len, gb.cart_ram.len);
        @memcpy(gb.cart_ram[0..n], k.cart_ram[0..n]);
    }
};
