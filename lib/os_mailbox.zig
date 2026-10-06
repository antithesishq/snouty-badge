//! Raw cart -> OS mailbox plumbing on the cart core, shared by the fork
//! firmware's request mailboxes that the pinned SDK predates:
//! lib/ext_flash.zig (0x2B, answered on the SIO FIFO) and
//! lib/cart_files.zig (0x2D, answered in a request struct). lib/save.zig on
//! branch saves/m1 is the same pattern written out for cart saves.
//!
//! A request: a struct in cart RAM (4-aligned), then the FIFO word
//! `type << 24 | (addr - 0x20000000) / 4` (`word`), sent the way the
//! pinned runtime sends its own words (platform_cart_ram.zig: wait for
//! FIFO_ST.RDY, write FIFO_WR, `sev`).
//!
//! **The FIFO hazard.** The pinned runtime's `present` waits for
//! FRAMEBUFFER_DONE (0x25000002) on the same core-0 -> core-1 FIFO. Two
//! ways to wait for the OS's answer, and what each must do about it:
//!
//! - **Answered on the FIFO** (`wait_fifo`, ext_flash's 0x2B): reading the
//!   FIFO may consume a FRAMEBUFFER_DONE meant for `present`, which would
//!   then wait for a DONE that never comes (its 0.5 s timeout leaves it
//!   waiting forever). So when `wait_fifo` swallows one it sends an empty
//!   frame (FRAMEBUFFER_READY_V2, no dirty rect) for the front buffer, which
//!   the OS answers with a fresh FRAMEBUFFER_DONE for `present` to find.
//!   The caller passes the front buffer index (`1 - cart.framebufferIndex()`).
//! - **Answered in the request struct** (`wait_struct`, cart files, cart
//!   saves): the wait never reads the FIFO, so a FRAMEBUFFER_DONE that
//!   arrives meanwhile stays queued for `present` and nothing needs
//!   re-arming. Keep it that way: a struct-answered wait must not drain
//!   the FIFO.
//!
//! **The no-flash rule.** While the OS erases or programs it may switch XIP
//! off, so a request that writes flash parks this core with interrupts
//! masked (`irq_disable`), spinning on SIO and TIMER0 registers and the
//! request in RAM only. A RAM cart's code is all in RAM; an XIP cart must
//! not make such requests.
//!
//! Only the `badge` namespace touches hardware; it compiles on every target
//! but is only called on the cart core. Imported as the named module
//! `os_mailbox` (one module per file: both users share it).
const std = @import("std");
const builtin = @import("builtin");

/// The Cortex-M33 cart core; false for wasm and hosts.
pub const is_badge = builtin.os.tag == .freestanding and (builtin.cpu.arch.isThumb() or builtin.cpu.arch.isArm());

/// The FIFO word that hands the OS a request at `addr` (cart RAM).
pub fn word(msg_type: u32, addr: usize) u32 {
    return (msg_type << 24) | @as(u32, @intCast((addr - 0x2000_0000) / 4));
}

pub const badge = struct {
    const sio_fifo_st: *volatile u32 = @ptrFromInt(0xD0000050);
    const sio_fifo_wr: *volatile u32 = @ptrFromInt(0xD0000054);
    const sio_fifo_rd: *volatile u32 = @ptrFromInt(0xD0000058);
    const fifo_rdy: u32 = 1 << 1;
    const fifo_vld: u32 = 1 << 0;
    /// The pinned runtime's FRAMEBUFFER_DONE and FRAMEBUFFER_READY_V2 tag.
    pub const framebuffer_done: u32 = 0x25000002;
    const framebuffer_ready_v2: u32 = 0x28;

    /// TIMER0 TIMELR: the low 32 bits of microseconds since boot.
    pub inline fn micros() u32 {
        const timelr: *const volatile u32 = @ptrFromInt(0x400b000c);
        return timelr.*;
    }

    pub inline fn dmb() void {
        asm volatile ("dmb" ::: .{ .memory = true });
    }

    /// Mask interrupts (PRIMASK); returns the old PRIMASK for `irq_restore`.
    pub inline fn irq_disable() u32 {
        return asm volatile (
            \\mrs %[p], primask
            \\cpsid i
            : [p] "=r" (-> u32),
            :
            : .{ .memory = true });
    }

    pub inline fn irq_restore(p: u32) void {
        asm volatile ("msr primask, %[p]"
            :
            : [p] "r" (p),
            : .{ .memory = true });
    }

    /// Write one word to the OS (waits for FIFO room); false on timeout.
    pub fn put(w: u32, timeout_us: u32) bool {
        const t0 = micros();
        while (sio_fifo_st.* & fifo_rdy == 0) {
            if (micros() -% t0 > timeout_us) return false;
        }
        sio_fifo_wr.* = w;
        asm volatile ("sev");
        return true;
    }

    /// FIFO-answered requests: wait for a word whose top byte is
    /// `msg_type` and return it (null on timeout). A FRAMEBUFFER_DONE read
    /// meanwhile is answered with an empty frame for `front` before
    /// returning (see the top of this file); other words are dropped, as
    /// the pinned runtime's own drain does.
    pub fn wait_fifo(msg_type: u32, timeout_us: u32, front: u1) ?u32 {
        var swallowed = false;
        defer if (swallowed) rearm_present(front, timeout_us);
        const t0 = micros();
        while (true) {
            if (sio_fifo_st.* & fifo_vld != 0) {
                const msg = sio_fifo_rd.*;
                if (msg >> 24 == msg_type) return msg;
                if (msg == framebuffer_done) swallowed = true;
                continue;
            }
            if (micros() -% t0 > timeout_us) return null;
        }
    }

    /// An empty frame for the front buffer: the OS answers it with the
    /// FRAMEBUFFER_DONE that `present` is waiting for.
    pub fn rearm_present(front: u1, timeout_us: u32) void {
        _ = put((framebuffer_ready_v2 << 24) | front, timeout_us);
    }

    pub const Wait = enum { done, never_picked_up };

    /// Struct-answered requests: spin until `state.*` reads `done` (the
    /// OS's pending -> busy -> done). Gives up only while it still reads
    /// `pending` after `pending_timeout_us` (stock firmware ignores the
    /// message; a lost word); once the OS has moved it on, the wait has no
    /// limit, because the OS always finishes. Never reads the FIFO.
    pub fn wait_struct(state: *volatile u32, pending: u32, done: u32, pending_timeout_us: u32) Wait {
        var last = pending;
        var t0 = micros();
        while (true) {
            dmb();
            const s = state.*;
            if (s == done) {
                dmb();
                return .done;
            }
            if (s != last) {
                last = s;
                t0 = micros();
            } else if (s == pending and micros() -% t0 >= pending_timeout_us) {
                return .never_picked_up;
            }
        }
    }
};
