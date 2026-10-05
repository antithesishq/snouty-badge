//! Snouty Genesis core: the whole Sega Genesis (Mega Drive, NTSC model 1)
//! in one struct, badge-agnostic. No cart-api, no floats, no allocator, no
//! clock, no randomness: the only input is the pad words given to
//! `step_frame_pads` (docs/MULTIPLAYER.md). SPEC.md sections 3, 7, 10; PLAN.md "Frozen for M1:
//! core/md.zig" is the interface contract.
//!
//! `step_frame` is the frame loop of the PLAN.md timing contract: 262
//! lines; per line the badge row is rendered at the line's start (when
//! asked and when the line is in the line table), the 68000 runs until it
//! has consumed the line's 488 or 489 cycles (scaled by
//! `tunables.cpu_scale`; the overrun, DMA stalls included, is carried into
//! the next line), then the Z80 runs its 228 cycles (scaled by
//! `tunables.z80_scale`, remainder carried) unless BUSREQ or RESET holds it,
//! then `vdp.end_line()`. The Z80's INT is asserted for line 224 (V-int).
//! `tone()` is computed once at the end of each frame and cached.
//!
//! Byte order per array: `work_ram`, `z80_ram`, `sram` and `vdp.vram` hold
//! bytes at their bus addresses (the 68000's big-endian word order); CRAM
//! and VSRAM are native u16 words.

const std = @import("std");
pub const m68k = @import("m68k.zig");
pub const bus = @import("bus.zig");
pub const z80bus = @import("z80bus.zig");
pub const vdp = @import("vdp.zig");
pub const ym2612 = @import("ym2612.zig");
pub const psg = @import("psg.zig");
pub const rom = @import("rom.zig");
pub const tunables = @import("tunables.zig");
pub const undo = @import("undo.zig");
pub const sound = @import("sound.zig");
pub const ports = @import("ports.zig");

pub const RomSource = rom.RomSource;
pub const LineSink = vdp.LineSink;
pub const Cpu = m68k.M68k(bus.Bus);
pub const Z80 = z80bus.Cpu;

/// Bytes of Z80 RAM the console holds: 8 KB, or none with the Z80 stub
/// (the 68000 reads the stub's RAM as 0, core/z80bus.zig).
pub const z80_ram_size: usize = if (tunables.z80_enabled) 0x2000 else 0;

/// Pad words per frame (`step_frame_pads`, core/ports.zig): pad 1 first.
pub const max_pads = ports.max_pads;
pub const Pads = ports.Pads;

pub const out_w = vdp.out_w;
pub const out_h = vdp.out_h;

/// Pad word fed to `step_frame`: bit set = pressed (SPEC.md section 5).
/// Bits 0-7 are the three-button pad (the frontend maps the badge's
/// buttons onto them; one byte per player on the wire, docs/MULTIPLAYER.md),
/// bits 8-11 a 6-button pad's extra buttons, which only a Team Player
/// reports (`ports.Config.six`).
pub const Pad = struct {
    pub const up: u16 = 1 << 0;
    pub const down: u16 = 1 << 1;
    pub const left: u16 = 1 << 2;
    pub const right: u16 = 1 << 3;
    pub const a: u16 = 1 << 4;
    pub const b: u16 = 1 << 5;
    pub const c: u16 = 1 << 6;
    pub const start: u16 = 1 << 7;
    pub const x: u16 = 1 << 8;
    pub const y: u16 = 1 << 9;
    pub const z: u16 = 1 << 10;
    pub const mode: u16 = 1 << 11;
};

pub const PollHook = ports.PollHook;
pub const poll_lines = ports.poll_lines;

/// The one voice the badge plays (SPEC.md section 9): frequency in Hz and
/// loudness, 0 quietest audible .. 15 loudest (a PSG channel's is
/// 15 - attenuation; the FM scale is Track D's call, documented in
/// ym2612.zig).
pub const Tone = struct { hz: u16, level: u4 };

/// Z80 bus arbiter (SPEC.md section 9).
pub const Arbiter = struct {
    /// A11100: the 68000 asked for the Z80's bus (the Z80 stops).
    busreq: bool = false,
    /// A11200: the Z80 and the YM2612 are held in reset. Asserted at power
    /// on until the 68000 releases it.
    z80_reset: bool = true,
};

/// Version register and the two pad ports (A10000-A1001F).
pub const Io = struct {
    /// A10003/5/7: data registers of ports 1, 2 and EXT (TH is bit 6).
    data: [3]u8 = @splat(0x7F),
    /// A10009/B/D: control registers (bit set = pin is an output).
    ctrl: [3]u8 = @splat(0),
};

pub const Md = struct {
    // ---- 68000 side ----
    // Field order and the `align(4)`s are for the badge: Zig lays fields
    // out by alignment, and in declaration order within one alignment, so
    // the small hot fields come first and sit within 4 KB of the struct's
    // start, where a Thumb load reaches them with an immediate offset (the
    // 64 KB arrays after them would push them past it: two extra
    // instructions per access). `hot_fields_near` checks it.
    cpu: Cpu = .{},
    /// The SRAM range the bus decodes now: the declared one while visible,
    /// else empty. A ROM that ends at or below the SRAM's start sees it
    /// from reset; a larger one only after A130F1 bit 0 is set (the SRAM
    /// control register of 2-4 MB SRAM cartridges).
    sram_active: rom.SramMap = .{},
    /// 68000 cycles owed to DMA (the VDP's charge, SPEC.md section 4),
    /// taken out of the 68000's budget by the frame loop.
    dma_stall: u32 = 0,
    io: Io align(4) = .{},
    /// Multiplayer (core/ports.zig, docs/MULTIPLAYER.md): this frame's pads
    /// and the Team Player / J-Cart protocol state (console state). Two
    /// fields here, where `pad` was: placed after the big arrays or split
    /// into more fields, this Zig's auto layout stopped following the
    /// declaration order and moved hot fields past 4 KB.
    ports: ports.State align(4) = .{},
    /// What is plugged in, lockstep mode and the poll hook: configuration,
    /// kept by `reset` (`ports.Setup`).
    setup: ports.Setup align(4) = .{},

    // ---- Z80 side ----
    z80: Z80 align(4) = .{},
    /// 6000: the bank register, 9 bits shifted in one per write (address
    /// bits 15-23 of the 32 KB window at Z80 8000-FFFF).
    z80_bank: u16 align(4) = 0,
    arbiter: Arbiter align(4) = .{},
    /// Z80 INT, asserted for one line from V-int.
    z80_int: bool align(4) = false,
    psg: psg.Psg align(4) = .{},
    ym: ym2612.Ym2612 = .{},

    // ---- Frame bookkeeping ----
    /// Frames stepped since reset (wraps).
    frame_count: u32 = 0,
    /// 68000 cycles the last line overran its share by (carried into the
    /// next line, PLAN.md frame loop).
    m68k_carry: u32 = 0,
    /// Z80 cycles carried over, in `tunables.scale_one` units.
    z80_carry: u32 = 0,

    // ---- Not console state: excluded from keyframes, kept by `reset` ----
    rom: RomSource = .{},
    /// Where rendered rows go; set once by the frontend.
    line_sink: ?LineSink = null,
    /// The 68000 share of the line being run (`run_m68k`), 0 outside it,
    /// and whether a DMA stall was charged in it: what `skip_wait_loop`
    /// needs besides `vdp.line_cycles` (not console state).
    m68k_share: u32 align(4) = 0,
    m68k_stalled: bool align(4) = false,
    /// An address `skip_wait_loop` found is not a wait loop head (not
    /// console state: it only saves looking again).
    not_wait_loop: u32 align(4) = 0xFFFF_FFFF,
    /// The SRAM range the header declares (derived from `rom` by `reset`),
    /// or the J-Cart register (`setup.cfg`).
    sram_map: rom.SramMap = .{},
    /// The streamed sound's renderer (core/sound.zig; the RAM cart only,
    /// a zero-size field elsewhere), set by the frontend; not console state.
    snd: if (sound.enabled) ?*sound.Sound else void align(4) = if (sound.enabled) null else {},
    /// `tone()`'s answer, recomputed at the end of every frame and on
    /// `reset`/`restore` (derived from `ym` and `psg`).
    tone_cache: ?Tone align(4) = null,

    // ---- The big arrays, last ----
    vdp: vdp.Vdp = .{},
    /// FF0000-FFFFFF, mirrored from E00000.
    work_ram: [0x10000]u8 = @splat(0),
    /// Cartridge SRAM (SPEC.md section 11, up to 16 KB, in RAM, not saved):
    /// byte `addr - sram_map.lo` of the header-declared range. Console
    /// state (in keyframes). Unused when the header declares none.
    sram: [rom.sram_max]u8 = @splat(0),
    /// A00000-A01FFF / Z80 0000-1FFF. Empty without the Z80
    /// (`z80_ram_size`).
    z80_ram: [z80_ram_size]u8 = @splat(0),

    /// Build the console around `src` in place, reset to power-on. The
    /// console is ~153 KB: always a static, never a stack temporary (32 KB
    /// stack on the badge, 14.7 KB in wasm).
    pub fn init_in_place(md: *Md, src: RomSource) void {
        md.rom = src;
        md.line_sink = null;
        md.setup = .{ .cfg = ports.detect(&src) };
        if (sound.enabled) md.snd = null;
        md.reset();
    }

    /// Power-on state: memory zeroed, the 68000 at the reset vector (SSP
    /// from 000000, PC from 000004), the VDP, YM2612 and PSG reset, the Z80
    /// held in reset with the bus not requested (the 68000 must request the
    /// bus to load Z80 RAM and release the reset to start it, as on
    /// hardware). Field by field so no console-sized temporary is built.
    /// Keeps `rom` and `line_sink`.
    pub fn reset(md: *Md) void {
        @memset(&md.work_ram, 0);
        md.vdp.reset();
        md.io = .{};
        md.ports = .{};
        @memset(&md.sram, 0);
        const h = rom.parse_header(&md.rom);
        md.sram_map = if (md.rom.size >= rom.header_end) rom.sram_map(&h) else .{};
        md.sram_active = if (md.sram_map.present() and md.rom.size <= md.sram_map.lo) md.sram_map else .{};
        if (md.setup.cfg.kind == .jcart) {
            // The J-Cart register takes the SRAM window (ports.zig).
            md.sram_map = ports.jcart_map();
            md.sram_active = md.sram_map;
            ports.jcart_refresh(md);
        }
        md.dma_stall = 0;
        md.not_wait_loop = 0xFFFF_FFFF;
        md.m68k_share = 0;
        md.m68k_stalled = false;
        z80bus.reset_genesis(&md.z80);
        @memset(&md.z80_ram, 0);
        md.z80_bank = 0;
        md.arbiter = .{};
        md.z80_int = false;
        md.ym.reset();
        md.psg.reset();
        md.frame_count = 0;
        md.m68k_carry = 0;
        md.z80_carry = 0;
        var b = md.bus_for();
        md.cpu.reset(&b);
        md.tone_cache = md.pick_tone();
        if (sound.active(md)) |s| s.resync(md);
    }

    /// One Genesis frame (262 lines) with pad 1 = `pad` and every other pad
    /// released (`step_frame_pads`).
    pub fn step_frame(md: *Md, pad: u16, render: bool) void {
        var p: Pads = @splat(0);
        p[0] = pad;
        md.step_frame_pads(&p, render);
    }

    /// One Genesis frame (262 lines). `pads` are held for the whole frame
    /// (which ones a game can read depends on `setup.cfg`); `render` false
    /// skips all line rendering (the first frame of a 60/30 pair). The
    /// console state after it is a function of the state before and of
    /// `pads` only (docs/MULTIPLAYER.md; with `setup.lockstep` set, whatever the
    /// frontend renders).
    pub noinline fn step_frame_pads(md: *Md, pads: *const Pads, render: bool) void {
        md.ports.pads = pads.*;
        if (md.setup.cfg.kind == .jcart) ports.jcart_refresh(md);
        const sink: ?LineSink = if (render) md.line_sink else null;
        var b = md.bus_for();
        var zb = md.z80bus_for();
        const scaled_frame: u32 = vdp.m68k_cycles_per_frame * tunables.cpu_scale / tunables.scale_one;
        // Not held across the line loop (a register the 68000 needs).
        if (sound.active(md)) |s| s.begin_frame();
        var line: u32 = 0;
        while (line < vdp.lines_per_frame) : (line += 1) {
            if (sink) |s| if (md.vdp.row_for_line(@intCast(line))) |row| md.render_row(row, s);
            if (line % poll_lines == 0) if (md.setup.poll_hook) |h| h.func(h.ctx);
            if (line == vdp.vint_line) md.z80_int = true;
            md.run_m68k(&b, line_share(line, scaled_frame));
            md.run_z80(&zb);
            md.z80_int = false;
            // The YM2612 timers count real 68000 cycles (its clock), unscaled.
            md.ym.tick(line_share(line, vdp.m68k_cycles_per_frame));
            md.vdp.end_line();
        }
        md.frame_count +%= 1;
        md.tone_cache = md.pick_tone();
        if (sound.active(md)) |s| s.end_frame(md);
    }

    /// Render the current line as badge row `row`. In lockstep the sticky
    /// sprite bits the renderer sets are dropped, so rendering leaves the
    /// console state alone.
    inline fn render_row(md: *Md, row: u8, s: LineSink) void {
        // One call site: the RAM cart inlines `render_line` here.
        const st = md.vdp.status;
        md.vdp.render_line(row, s);
        if (md.setup.lockstep) md.vdp.status = st;
    }

    /// 68000 cycles of line `line` when the frame has `total`: the frame's
    /// cycles spread evenly with no running sum (488 or 489 at full speed).
    inline fn line_share(line: u32, total: u32) u32 {
        return (line + 1) * total / vdp.lines_per_frame - line * total / vdp.lines_per_frame;
    }

    /// Run the 68000 until it has consumed `share` cycles of this line,
    /// counting DMA stalls, and carry the overrun into the next line. A
    /// STOPped 68000 with no interrupt above its mask sleeps the rest of
    /// the line (interrupts change only between lines or by the 68000's
    /// own writes). `vdp.line_cycles` follows the position in the line for
    /// the HV counter.
    fn run_m68k(md: *Md, b: *bus.Bus, share: u32) void {
        var used: u32 = md.m68k_carry;
        md.m68k_share = share;
        md.m68k_stalled = false;
        defer md.m68k_share = 0;
        while (used < share) {
            if (md.dma_stall != 0) {
                used += md.dma_stall;
                md.dma_stall = 0;
                md.m68k_stalled = true;
                continue;
            }
            if (md.cpu.stopped and md.vdp.irq <= md.cpu.mask()) {
                used = share;
                break;
            }
            used += @call(.always_inline, Cpu.step, .{ &md.cpu, b });
            md.vdp.line_cycles = @truncate(@min(used, 0xFFFF));
        }
        md.m68k_carry = used - share;
    }

    /// The bus's `wait_loop` hook (`M68k.note_loop`): the 68000 just took
    /// a short branch back to `cpu.pc`, which may be the head of a wait
    /// loop. A game waiting for V-int spins on a work RAM flag the
    /// interrupt handler sets (`tst.b flag; beq.s *-6`: 55% of
    /// Miniplanets' instructions in play, 97% of the test ROM's) or on
    /// `bra.s *`. Nothing can change the flag or raise an interrupt before
    /// the line ends (the Z80 runs after the 68000's share, interrupts
    /// change at `end_line`), so whole iterations are skipped by adding
    /// their cycles to this branch's: every register, flag and cycle count
    /// ends exactly as stepping them would leave it. It stops at least one
    /// iteration short of the share, so the instruction that crosses into
    /// the next line is a real one. Recognised, with the PC at the head:
    /// TST.b/w/l or BTST #n on an abs.w or abs.l work RAM address, or
    /// MOVE.b/w/l from one to Dn, followed by BEQ.s/BNE.s to the head;
    /// BRA.s or Bcc.s to itself (its flags cannot change).
    /// tests/md_wait_loop.zig checks each form against plain stepping.
    ///
    /// The position in the line is `vdp.line_cycles` (the cycles before
    /// this instruction) plus `cpu.cyc`; not known exactly before the
    /// line's first step or after a DMA stall, so those do not skip.
    pub noinline fn skip_wait_loop(md: *Md, cpu: *Cpu) void {
        const pc: u24 = @truncate(cpu.pc);
        if (pc == md.not_wait_loop) return;
        const line_pos: u32 = md.vdp.line_cycles;
        if (md.m68k_stalled or line_pos == 0 or line_pos == 0xFFFF) return;
        const used = line_pos + cpu.cyc;
        const share = md.m68k_share;
        if (md.dma_stall != 0 or md.vdp.irq > cpu.mask()) return;
        // Code in ROM or work RAM only (no read side effects).
        if (pc >= 0x400000 and pc < 0xE00000) return;
        var b = md.bus_for();
        const op = b.read16(pc);
        // The taken Bcc.s / BRA.s, then the head's cycles below.
        var iter: u32 = 10;
        var len: u32 = 0;
        var addr: u32 = 0;
        // 0: TST, 1: BTST #n, 2: MOVE to Dn, 3: a branch to itself.
        var kind: u2 = 0;
        var sz: u2 = 0;
        var bit: u3 = 0;
        if (op & 0xF000 == 0x6000 and op & 0xFF == 0xFE and op & 0x0F00 != 0x0100) {
            kind = 3;
        } else if (op & 0xFF3E == 0x4A38 and op & 0xC0 != 0xC0) {
            // TST.<sz> abs.w / abs.l
            sz = @truncate(op >> 6);
            len = if (op & 1 != 0) 6 else 4;
            addr = abs_operand(&b, pc +% 2, op & 1 != 0);
            // Its words at 4 cycles each, the operand read (8 for a long).
            iter += len / 2 * 4 + 4 + (if (sz == 2) @as(u32, 4) else 0);
        } else if (op & 0xC1FE == 0x0038 and op & 0x3000 != 0) {
            // MOVE.<sz> abs.w / abs.l, Dn (sets Dn and the flags as TST).
            kind = 2;
            sz = switch (op >> 12) {
                1 => 0,
                3 => 1,
                else => 2,
            };
            len = if (op & 1 != 0) 6 else 4;
            addr = abs_operand(&b, pc +% 2, op & 1 != 0);
            iter += len / 2 * 4 + 4 + (if (sz == 2) @as(u32, 4) else 0);
        } else if (op & 0xFFFE == 0x0838) {
            // BTST #n, abs.w / abs.l (a byte in memory: bit n mod 8)
            kind = 1;
            bit = @truncate(b.read16(pc +% 2));
            len = if (op & 1 != 0) 8 else 6;
            addr = abs_operand(&b, pc +% 4, op & 1 != 0);
            iter += len / 2 * 4 + 4;
        } else return md.no_wait_loop(pc);

        if (kind != 3) {
            // Followed by BEQ.s / BNE.s back to the head.
            const br = b.read16(@truncate(pc +% len));
            const cc = br >> 8;
            if (cc != 0x67 and cc != 0x66) return md.no_wait_loop(pc);
            if (br & 0xFF != (0x100 - (len + 2)) & 0xFF) return md.no_wait_loop(pc);
            const a: u24 = @truncate(addr);
            if (a < 0xE00000) return md.no_wait_loop(pc);
            // As the bus reads it (a word at `addr & ~1`).
            var v: u32 = undefined;
            if (kind == 1 or sz == 0) {
                v = md.work_ram[@as(u16, @truncate(a))];
            } else {
                const i: u16 = @truncate(a & 0xFFFE);
                v = @as(u32, md.work_ram[i]) << 8 | md.work_ram[i + 1];
                if (sz == 2) v = v << 16 | @as(u32, md.work_ram[i +% 2]) << 8 | md.work_ram[i +% 3];
            }
            const zero = if (kind == 1) v >> bit & 1 == 0 else v == 0;
            // The branch must be taken again (else the loop is exiting).
            if (zero != (cc == 0x67)) return;
            if (used + iter >= share) return;
            // The flags and register the loop's head leaves (the same
            // every iteration).
            if (kind == 1) {
                cpu.f_z = @intFromBool(!zero);
            } else {
                const sh: u5 = switch (sz) {
                    0 => 24,
                    1 => 16,
                    else => 0,
                };
                cpu.f_n = v << sh;
                cpu.f_z = v << sh;
                cpu.f_v = 0;
                cpu.f_c = false;
                if (kind == 2) {
                    const m: u32 = @as(u32, 0xFFFF_FFFF) >> sh;
                    const r: u3 = @truncate(op >> 9);
                    cpu.d[r] = (cpu.d[r] & ~m) | v;
                }
            }
        } else if (used + iter >= share) return;
        cpu.cyc += (share - 1 - used) / iter * iter;
    }

    /// `pc` is not a wait loop head: remember it. (Code in RAM may change
    /// into one; it is then only not skipped, which is always exact.)
    fn no_wait_loop(md: *Md, pc: u24) void {
        md.not_wait_loop = pc;
    }

    /// The Z80's slice of this line, in `scale_one` units so a scaled
    /// clock carries its fraction. Held by BUSREQ or RESET (or switched
    /// off) it does not run and its carry waits.
    fn run_z80(md: *Md, zb: *z80bus.Z80Bus) void {
        if (!tunables.z80_enabled) return;
        if (md.arbiter.busreq or md.arbiter.z80_reset) return;
        const share: u32 = vdp.z80_cycles_per_line * tunables.z80_scale;
        var used: u32 = md.z80_carry;
        while (used < share) {
            // Cycles left in this slice, so a halted Z80 sleeps to its end.
            zb.left = (share - used + tunables.scale_one - 1) / tunables.scale_one;
            // Inlined (as Snouty Gear does): a call per instruction pushed
            // nine registers and reloaded the Z80's state every time, 2.6
            // ms of a Miniplanets update; +11 KB of flash.
            used += @call(.always_inline, Z80.step, .{ &md.z80, zb }) * tunables.scale_one;
        }
        zb.left = 0;
        md.z80_carry = used - share;
    }

    /// The note the badge should play now (SPEC.md section 9), as computed
    /// at the end of the last frame.
    pub fn tone(md: *const Md) ?Tone {
        return md.tone_cache;
    }

    /// SPEC.md section 9: the FM pick against the PSG pick, the louder
    /// wins, FM on a tie (`ym2612.pick_tone`).
    fn pick_tone(md: *const Md) ?Tone {
        // Without the Z80 there is no sound driver and the cart is silent
        // (PLAN.md M5): no tone, and no code for the pick.
        if (!tunables.z80_enabled) return null;
        return ym2612.pick_tone(&md.ym, &md.psg);
    }

    pub fn bus_for(md: *Md) bus.Bus {
        return .{ .md = md };
    }

    pub fn z80bus_for(md: *Md) z80bus.Z80Bus {
        return .{ .md = md };
    }

    // ---- Keyframes (SPEC.md section 10) ----

    /// The console minus `rom`, `line_sink` (not console state),
    /// `sram_map` and `tone_cache` (derived). M3 replaces the full copy
    /// with delta keyframes; the shape (`snapshot`/`restore`) stays. Auto
    /// layout: compare field by field (`std.meta.eql`), never as raw bytes.
    pub const Keyframe = struct {
        cpu: Cpu,
        work_ram: [0x10000]u8,
        vdp: vdp.Vdp,
        io: Io,
        ports: ports.State,
        sram: [rom.sram_max]u8,
        sram_active: rom.SramMap,
        dma_stall: u32,
        z80: Z80,
        z80_ram: [z80_ram_size]u8,
        z80_bank: u16,
        arbiter: Arbiter,
        z80_int: bool,
        ym: ym2612.Ym2612,
        psg: psg.Psg,
        frame_count: u32,
        m68k_carry: u32,
        z80_carry: u32,
    };

    // ---- The scrubber's small state (M3, core/undo.zig) ----

    /// Every console field outside the four byte regions (work RAM, VRAM,
    /// Z80 RAM, cartridge SRAM): the head of every undo record. Excluded
    /// like `Keyframe` (`rom`, `line_sink`, `sram_map`, `tone_cache`), plus
    /// the per-line scratch `m68k_share`/`m68k_stalled` (zero between
    /// frames) and the `not_wait_loop` hint; inside the VDP `vram` and
    /// `line_mode` / `h_mode` (`vdp.Vdp.Small`). Compare field by field, never as
    /// bytes (padding is zeroed by `save_small` only so equal states have
    /// equal bytes).
    pub const Small = struct {
        cpu: Cpu,
        vdp: vdp.Vdp.Small,
        io: Io,
        ports: ports.State,
        sram_active: rom.SramMap,
        dma_stall: u32,
        z80: Z80,
        z80_bank: u16,
        arbiter: Arbiter,
        z80_int: bool,
        ym: ym2612.Ym2612,
        psg: psg.Psg,
        frame_count: u32,
        m68k_carry: u32,
        z80_carry: u32,
    };

    pub fn save_small(md: *const Md, out: *Small) void {
        @memset(std.mem.asBytes(out), 0);
        inline for (@typeInfo(Small).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "vdp")) md.vdp.save_small(&out.vdp) else @field(out, name) = @field(md, name);
        }
    }

    /// Apply a `Small`; the byte regions are the caller's. Keeps `rom`,
    /// `line_sink`, `vdp.line_mode`, `vdp.h_mode` and `not_wait_loop`; recomputes
    /// `tone_cache`.
    pub fn load_small(md: *Md, k: *const Small) void {
        inline for (@typeInfo(Small).@"struct".field_names) |name| {
            if (comptime std.mem.eql(u8, name, "vdp")) md.vdp.load_small(&k.vdp) else @field(md, name) = @field(k, name);
        }
        md.tone_cache = md.pick_tone();
    }

    /// Draw the 128 badge rows of the current state through `line_sink`
    /// without stepping (the scrubber's parked picture): every line with a
    /// row renders with the registers as they are now. The state is left
    /// exactly as it was: `vdp.line`, the sticky status bits and the
    /// sprite table cache (which rendering may rebuild) are restored.
    pub fn render_still(md: *Md) void {
        const sink = md.line_sink orelse return;
        const v = &md.vdp;
        const line = v.line;
        const status = v.status;
        const spr_cache = v.spr_cache;
        const spr_band = v.spr_band;
        const spr_count = v.spr_count;
        const spr_dirty = v.spr_dirty;
        var l: u16 = 0;
        while (l < vdp.active_lines) : (l += 1) {
            if (v.row_for_line(l)) |row| {
                v.line = l;
                v.render_line(row, sink);
            }
        }
        v.line = line;
        v.status = status;
        v.spr_cache = spr_cache;
        v.spr_band = spr_band;
        v.spr_count = spr_count;
        v.spr_dirty = spr_dirty;
    }

    pub fn snapshot(md: *const Md, out: *Keyframe) void {
        out.cpu = md.cpu;
        out.work_ram = md.work_ram;
        out.vdp = md.vdp;
        out.io = md.io;
        out.ports = md.ports;
        out.sram = md.sram;
        out.sram_active = md.sram_active;
        out.dma_stall = md.dma_stall;
        out.z80 = md.z80;
        out.z80_ram = md.z80_ram;
        out.z80_bank = md.z80_bank;
        out.arbiter = md.arbiter;
        out.z80_int = md.z80_int;
        out.ym = md.ym;
        out.psg = md.psg;
        out.frame_count = md.frame_count;
        out.m68k_carry = md.m68k_carry;
        out.z80_carry = md.z80_carry;
    }

    pub fn restore(md: *Md, k: *const Keyframe) void {
        md.cpu = k.cpu;
        md.work_ram = k.work_ram;
        md.vdp = k.vdp;
        md.io = k.io;
        md.ports = k.ports;
        md.sram = k.sram;
        md.sram_active = k.sram_active;
        md.dma_stall = k.dma_stall;
        md.z80 = k.z80;
        md.z80_ram = k.z80_ram;
        md.z80_bank = k.z80_bank;
        md.arbiter = k.arbiter;
        md.z80_int = k.z80_int;
        md.ym = k.ym;
        md.psg = k.psg;
        md.frame_count = k.frame_count;
        md.m68k_carry = k.m68k_carry;
        md.z80_carry = k.z80_carry;
        md.tone_cache = md.pick_tone();
    }
};

inline fn sext16(v: u16) u32 {
    return @bitCast(@as(i32, @as(i16, @bitCast(v))));
}

/// The address word(s) at `at`: abs.l, or abs.w sign-extended.
inline fn abs_operand(b: *bus.Bus, at: u24, long: bool) u32 {
    if (long) return @as(u32, b.read16(at)) << 16 | b.read16(at +% 2);
    return sext16(b.read16(at));
}

/// The fields the hot loops touch sit within reach of an immediate offset
/// (see the note at the top of `Md`'s fields).
const hot_fields_near = blk: {
    const near = 4096;
    for ([_]u32{
        @offsetOf(Md, "z80"),                              @offsetOf(Md, "z80_int"),                                  @offsetOf(Md, "arbiter"),
        @offsetOf(Md, "z80_bank"),                         @offsetOf(Md, "dma_stall"),                                @offsetOf(Md, "sram_active"),
        @offsetOf(Md, "rom"),                              @offsetOf(Md, "m68k_carry"),                               @offsetOf(Md, "z80_carry"),
        @offsetOf(Md, "vdp") + @offsetOf(vdp.Vdp, "regs"), @offsetOf(Md, "vdp") + @offsetOf(vdp.Vdp, "hint_pending"),
    }) |o| if (o >= near) @compileError("Md: a hot field lies past 4 KB; see the note on Md's fields");
    break :blk true;
};
comptime {
    _ = hot_fields_near;
}

// `Md.Small` is `Keyframe` minus work RAM, Z80 RAM and SRAM (VRAM is in
// its `vdp`), and
// `vdp.Vdp.Small` is `Vdp` minus `vram`, `line_mode` and `h_mode`: a field added to
// the console must be added to both (or excluded here on purpose).
comptime {
    const kf = @typeInfo(Md.Keyframe).@"struct".field_names;
    const sm = @typeInfo(Md.Small).@"struct".field_names;
    if (kf.len != sm.len + 3) @compileError("Md.Small out of step with Md.Keyframe");
    for (sm) |name| if (!@hasField(Md.Keyframe, name)) @compileError("Md.Small field not in Keyframe: " ++ name);
    const vf = @typeInfo(vdp.Vdp).@"struct".field_names;
    const vs = @typeInfo(vdp.Vdp.Small).@"struct".field_names;
    if (vf.len != vs.len + 3) @compileError("Vdp.Small out of step with Vdp");
    for (vs) |name| if (@FieldType(vdp.Vdp.Small, name) != @FieldType(vdp.Vdp, name)) @compileError("Vdp.Small field type differs: " ++ name);
}
