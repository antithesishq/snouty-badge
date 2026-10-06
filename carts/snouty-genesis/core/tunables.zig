//! Performance knobs, all in one place (SPEC.md section 8, tried in this
//! order when the budget misses). Integer fixed point, no floats in core/.
//! Defaults only: M1 measures, M4 retunes from Adrian's badge numbers, and
//! a menu item may later override `z80_enabled` at run time.

/// Emulated frames per badge update; only the last one is rendered.
/// 2 = 60/30 (two Genesis frames, present at 30 Hz); 3 = 20 Hz presents
/// with the game at full speed; 1 = 60 Hz if the numbers ever allow it.
pub const render_every: u8 = 2;

/// Fixed-point unit of the two scales: `scale_one` = 1.0.
pub const scale_one: u16 = 256;

/// Share of the Z80's 59,659 cycles per frame (228 per line) it gets, over
/// `scale_one`. Sound drivers idle between V-ints, so most tolerate some
/// underclocking.
pub const z80_scale: u16 = scale_one;

/// Share of the 68000's 128,008 cycles per frame (488/489 per line) it
/// gets, over `scale_one`. Underclock before dropping emulated frames.
pub const cpu_scale: u16 = scale_one;

/// False: no Z80 core is linked and the arbiter stub answers for it
/// (SPEC.md section 9, "Z80 off"; core/z80bus.zig). Set per build variant
/// (`build_options.z80`, carts/snouty-genesis/build.zig): the XIP cart and
/// the simulator have the Z80, the RAM cart has the stub (PLAN.md M5).
pub const z80_enabled: bool = @import("build_options").z80;
// With the stub, `-Dgenesis_s1dac=true` adds a fake of Sonic 1's Z80
// sample driver to the RAM cart (core/s1dac.zig, `build_options.s1dac`):
// that game's drums and SEGA chant play, other games are untouched.

/// The RAM cart's FM synthesis rate (core/ym2612.zig `Fm`, core/sound.zig):
/// the six FM channels are evaluated every `fm_rate_div`-th 44.1 kHz
/// sample and the value held for the others: 1 = 44,100 Hz, 2 = 22,050,
/// 3 = 14,700. The PSG and the output stay at 44.1 kHz. Measured per rate
/// in PLAN.md "Sound on the new firmware (2026-10-04)".
pub const fm_rate_div: u32 = 3;

/// The RAM-window carts (the RAM cart with its sound, the party cart with
/// its lobby and lockstep): 8 KB of cartridge SRAM (`rom.sram_max`) and a
/// 768 KB drive cluster table (frontend/romsrc.zig), PLAN.md "Sound on the
/// new firmware" and docs/MULTIPLAYER.md.
pub const tight_ram: bool = @import("build_options").synth or @import("build_options").party;
