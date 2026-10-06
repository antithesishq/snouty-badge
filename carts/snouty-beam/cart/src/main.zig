//! Snouty Beam: send carts badge to badge over the link cable (PLAN.md).
//!
//! The home screen lists the UF2s on the badge's drives (and the received
//! cart, if the slot holds one); A sends the highlighted cart to the
//! partner badge, which asks its owner and saves the cart: as a new `.uf2`
//! on its drive when its firmware has cart files (M3, fork/CART_FILES.md),
//! else into the external flash's received-cart slot (M1,
//! fork/CART_TRANSFER.md). The firmware's menu then lists it.
//!
//! - lib/beam_slot.zig: the slot format and the UF2 flattener.
//! - proto.zig: the transfer protocol (pure state machines); this file pumps
//!   them, `BadgeIo` gives them the link, the flash and the drives.
//! - lib/ext_flash.zig: the fork firmware's external flash (mailbox 0x2B).
//! - lib/cart_files.zig: the fork firmware's cart files (mailbox 0x2D).
//!
//! Receiving is compiled in only with -Dbeam_receive=true (it needs the
//! fork firmware); without it an offer is answered "cannot receive". Even
//! compiled in, it switches on only when the firmware sets os_flags bit 6
//! (cart_files: files), or bits 2 and 5 (ext_flash, cart_transfer: the
//! slot). What this badge can take goes to the partner in the link HELLO
//! (`proto.Caps`), and the sender picks a file or a slot image from it.
const std = @import("std");
const cart = @import("cart-api");
const link = @import("link");
const lockstep = @import("lockstep");
const romfs = @import("romfs");
const slot = @import("beam_slot");
const ext_flash = @import("ext_flash");
const cart_files = @import("cart_files");
const build_options = @import("build_options");
const proto = @import("proto.zig");
const source = @import("source.zig");

comptime {
    cart.export_start_code();
}

/// -Dbeam_receive: the receiving side is in this build.
const receive_built = build_options.receive;

/// HELLO app id (lib/lockstep.zig `apps.beam`).
const app_id = lockstep.apps.beam;

/// While connected, keep pumping the link until this far into the frame.
const pump_until_us = 14_000;
/// Hold B this long to cancel a transfer.
const cancel_hold_us = 600_000;
/// The DMA channel for the link's receive ring (docs/LINK.md).
const rx_dma_channel = 11;
/// Image bytes hashed per frame while preparing an offer (about 0.3 ms
/// per 4 KB on the badge).
const prepare_chunks_per_frame = 16;

const bg = cart.DisplayColor.rgb(0x0C1420);
const fg = cart.DisplayColor.rgb(0xE0E8F0);
const dim = cart.DisplayColor.rgb(0x5A6878);
const accent = cart.DisplayColor.rgb(0x40D0F0);
const good = cart.DisplayColor.rgb(0x60E080);
const warn = cart.DisplayColor.rgb(0xF0B040);
const bar_bg = cart.DisplayColor.rgb(0x1C2838);
const sel_bg = cart.DisplayColor.rgb(0x203448);

const Link = link.LinkQueue(link.rp2350.Port, 32);

/// A drive file as lib/beam_slot.zig's UF2 `File`: a UF2 block is exactly
/// one 512-byte cluster.
const DriveFile = struct {
    m: romfs.Mapped,
    pub fn size(f: *const DriveFile) u32 {
        return f.m.size;
    }
    pub fn block(f: *const DriveFile, i: u32) *const [512]u8 {
        return @ptrCast(f.m.chunk(i * 512, 512).?);
    }
};

const Src = source.Source(DriveFile);

const BadgeIo = struct {
    pub fn now(_: *BadgeIo) u64 {
        return cart.micros_since_boot();
    }
    pub fn send(_: *BadgeIo, bytes: []const u8) bool {
        return l.send(cart.micros_since_boot(), bytes);
    }
    pub fn erase(_: *BadgeIo, at: u32) bool {
        ext_flash.erase(at, front()) catch return false;
        return true;
    }
    pub fn program(_: *BadgeIo, at: u32, data: []const u8) bool {
        ext_flash.program(at, data, front()) catch return false;
        return true;
    }
    pub fn read(_: *BadgeIo, at: u32, dst: []u8) void {
        const a = ext_flash.area() orelse return @memset(dst, 0xFF);
        @memcpy(dst, a[at..][0..dst.len]);
    }
    pub fn area_size(_: *BadgeIo) u32 {
        return ext_flash.info().area_size;
    }
    pub fn can_receive(_: *BadgeIo) bool {
        return my_caps.slot;
    }
    pub fn takes_files(_: *BadgeIo) bool {
        return my_caps.file;
    }
    pub fn file_stat(_: *BadgeIo, volume: u1) cart_files.Error!cart_files.Stat {
        const st = try cart_files.stat(volume);
        usb_host = st.flags.usb_host;
        return st;
    }
    pub fn file_create(_: *BadgeIo, volume: u1, name: []const u8, size: u32) cart_files.Error!void {
        return cart_files.create(volume, name, size);
    }
    pub fn file_write(_: *BadgeIo, offset: u32, data: []const u8) cart_files.Error!void {
        return cart_files.write(offset, data);
    }
    pub fn file_commit(_: *BadgeIo) cart_files.Error!void {
        return cart_files.commit();
    }
    pub fn file_abort(_: *BadgeIo) void {
        cart_files.abort();
    }

    /// The buffer the OS shows now (lib/ext_flash.zig re-arms `present`
    /// with it).
    fn front() u1 {
        return 1 - cart.framebufferIndex();
    }
};

const Sender = proto.Sender(BadgeIo, Src);
const Receiver = proto.Receiver(BadgeIo);
const Offer = Sender.Offer;

// ---- state ------------------------------------------------------------------------

var l: Link = undefined;
var io: BadgeIo = .{};
var sender: Sender = .{};
var receiver: if (receive_built) Receiver else void = if (receive_built) .{} else {};
var session: u32 = 0;

/// What this badge can receive (advertised in the link HELLO), from the
/// firmware at start.
var my_caps: proto.Caps = .{};
/// A computer has the drives mounted (cart files refuse writes): from the
/// last cart-files reply, asked again every `usb_poll_us` on Home.
var usb_host = false;
var usb_polled_at: u64 = 0;
const usb_poll_us = 1_000_000;

const Mode = enum { home, preparing, sending, offer, receiving, confirm_clear };
var mode: Mode = .home;
/// Redraw the whole screen this frame (the screen changed).
var full_redraw = true;

/// One row of the list: a drive file or the received slot.
const Row = struct {
    kind: enum { file, slot } = .file,
    entry: romfs.Entry = .{},
    analysed: bool = false,
    image_len: u32 = 0,
    /// Why it cannot go as a slot image (null: it can).
    slot_refused: ?[]const u8 = null,
    /// Why it cannot go as a file (null: it can); XIP carts and carts too
    /// big for a slot can. A slot row never goes as a file.
    file_refused: ?[]const u8 = null,
};
const max_rows = 32;
var rows: [max_rows]Row = undefined;
var row_count: u8 = 0;
var selected: u8 = 0;
var scroll: u8 = 0;
/// Rows analysed so far (one per frame after a scan).
var analyse_next: u8 = 0;
/// The cluster table of the file being analysed or sent (5 KB).
var clusters: [romfs.max_clusters]u16 = undefined;
var drives_present: u8 = 0;

/// The received slot (header), when valid.
var slot_header: ?slot.Header = null;
/// Image capacity of the slot area (default when unknown).
var capacity: u32 = slot.capacity(slot.default_area_size);

// Preparing an offer: the file's CRC (file mode) and the image's (slot
// mode, or the file offer's slot fallback), a few chunks per frame.
var prep_plan: proto.Plan = undefined;
var prep_file: DriveFile = undefined;
var prep_file_crc: romfs.Mapped.Crc = undefined;
var prep_src: Src = undefined;
var prep_len: u32 = 0;
var prep_crc: slot.CrcState = .{};
var prep_header: [slot.header_size]u8 = undefined;
var prep_name: [64]u8 = undefined;
var prep_name_len: u8 = 0;
var prep_slot_crc: ?u32 = null;
var prep_offer: Offer = undefined;
var prep_fallback: Offer = undefined;
var scratch: [slot.sector_size]u8 = undefined;

var send_started: u64 = 0;
var b_down_since: ?u64 = null;
var toast_buf: [24]u8 = undefined;
var toast: []const u8 = "";
var toast_until: u64 = 0;
var xfer_seed: u32 = 0;
var last_xfer: u8 = 0;

/// badge-bench (`--poke beam_bench_no_pump=1`): skip the late pump loop,
/// so the bench measures the frame's own work instead of the 14 ms of
/// link polling that a cart with no cable spends by design.
export var beam_bench_no_pump: u32 = 0;

/// No buttons (cart.Controls has no field defaults).
const none: cart.Controls = @bitCast(@as(u16, 0));
var held = none;

// ---- start / update -------------------------------------------------------------------

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.copy_forward);
    link.rp2350.rx_dma = rx_dma_channel;
    xfer_seed = cart.rand() ^ @as(u32, @truncate(cart.micros_since_boot()));
    l = Link.init(.{}, app_id, xfer_seed | 1);
    if (receive_built) {
        my_caps = .{
            .slot = ext_flash.info().can_receive(),
            // A probe (at most 250 ms) only when os_flags bit 6 is set.
            .file = cart_files.supported(),
        };
        if (my_caps.file) usb_host = cart_files.last_flags().usb_host;
    }
    // Before the first poll: the HELLO carries it.
    l.app_version = my_caps.nibble();
    scan();
}

pub fn update() void {
    const frame_start = cart.micros_since_boot();
    const pad = read_controls();
    const pressed = presses(held, pad);
    held = pad;

    if (demo == 0) pump() else demo_step();
    switch (mode) {
        .home => home(frame_start, pressed),
        .preparing => prepare(frame_start, pad),
        .sending => sending(frame_start, pad, pressed),
        .offer => offer(pressed),
        .receiving => receiving(frame_start, pad, pressed),
        .confirm_clear => confirm_clear(pressed),
    }
    if (mode == .home and analyse_next < row_count) analyse(analyse_next);
    draw(frame_start);

    // The link's receive ring holds 256 bytes; keep it drained.
    if (l.state != .unavailable and beam_bench_no_pump == 0) {
        while (cart.micros_since_boot() -% frame_start < pump_until_us) pump();
    }
    if (cart.is_wasm) present_wasm();
}

fn set_mode(m: Mode) void {
    if (m == mode) return;
    const busy = m == .preparing or m == .sending or m == .receiving;
    const was_busy = mode == .preparing or mode == .sending or mode == .receiving;
    // A transfer draws only its progress, with no vsync wait, so the
    // link is read again within a millisecond.
    if (busy and !was_busy) cart.set_vsync_disabled();
    if (!busy and was_busy) cart.set_vsync_enabled(1000.0 / 60.0);
    mode = m;
    full_redraw = true;
}

/// Poll the link once and feed the protocol.
fn pump() void {
    l.poll(cart.micros_since_boot());
    while (l.recv()) |p| {
        const bytes = p.slice();
        if (bytes.len < 2) continue;
        if (proto.to_sender(bytes[0])) sender.handle(&io, bytes);
        if (proto.to_receiver(bytes[0])) {
            if (receive_built) {
                receiver.handle(&io, bytes);
            } else if (bytes[0] == proto.T.offer) {
                _ = l.send(cart.micros_since_boot(), &.{ proto.T.reject, bytes[1], @backingInt(proto.Reject.cannot_receive) });
            }
        }
    }
    if (!l.connected() or l.session != session) {
        session = l.session;
        sender.link_lost();
        if (receive_built) receiver.link_lost(&io);
    }
    if (receive_built) receiver.accepting = mode == .home and !sender.active();
    sender.tick(&io);
    if (receive_built) {
        receiver.tick(&io);
        if (receiver.state == .asking and mode == .home) set_mode(.offer);
    }
}

// ---- the list ---------------------------------------------------------------------------

/// List the UF2s on both drives and the received slot; analysis follows a
/// row per frame.
fn scan() void {
    row_count = 0;
    drives_present = 0;
    analyse_next = 0;
    if (!cart.is_wasm) {
        var d: u8 = 0;
        while (d < romfs.drive_count) : (d += 1) {
            const vol = romfs.Volume.open_drive(d) catch continue;
            drives_present += 1;
            var found: [max_rows]romfs.Entry = undefined;
            const n = vol.find(&.{"uf2"}, found[0 .. max_rows - 1 - row_count]);
            for (found[0..n]) |e| {
                rows[row_count] = .{ .entry = e };
                row_count += 1;
            }
        }
    }
    read_slot();
    if (slot_header) |h| {
        rows[row_count] = .{ .kind = .slot, .analysed = true, .image_len = h.image_len };
        row_count += 1;
    }
    if (selected >= row_count) selected = if (row_count > 0) row_count - 1 else 0;
    full_redraw = true;
}

fn read_slot() void {
    slot_header = null;
    const info = ext_flash.info();
    if (info.area_size > slot.image_offset) capacity = slot.capacity(info.area_size);
    const a = ext_flash.area() orelse return;
    if (a.len < slot.image_offset) return;
    slot_header = slot.parse(a[0..slot.header_size], @intCast(a.len)) catch null;
}

fn map_row(r: *const Row) !DriveFile {
    const vol = try romfs.Volume.open_drive(r.entry.drive);
    return .{ .m = try vol.map(r.entry, &clusters) };
}

fn analyse(i: u8) void {
    analyse_next = i + 1;
    const r = &rows[i];
    if (r.kind != .file or r.analysed) return;
    r.analysed = true;
    const f = map_row(r) catch |e| {
        r.slot_refused = if (e == error.TooManyClusters) "FILE TOO BIG" else "DRIVE ERROR";
        r.file_refused = r.slot_refused;
        return;
    };
    const u = slot.Uf2(DriveFile).open(f) catch |e| {
        r.slot_refused = refusal(e);
        // An XIP cart, or a RAM cart the slot format can't split: the
        // menu runs them, so they go as files.
        if (e != error.Xip and e != error.StraddlesIpc) r.file_refused = r.slot_refused;
        return;
    };
    r.image_len = u.info.image_len;
    if (u.info.image_len > capacity) r.slot_refused = "TOO BIG FOR A SLOT";
}

/// The partner's capabilities, when a Snouty Beam is connected.
fn partner_caps() ?proto.Caps {
    if (demo != 0) return .{ .slot = true, .file = true };
    if (!l.connected() or l.partner_app != app_id) return null;
    return proto.Caps.of_partner(l.partner_version);
}

/// The row as this partner would get it, or with no partner yet as a file
/// (M3): null when it can be sent, else why not.
fn row_refusal(r: *const Row) ?[]const u8 {
    if (!r.analysed) return null;
    const caps = partner_caps() orelse return if (r.kind == .slot) null else r.file_refused;
    if (caps.v2 and !caps.slot and !caps.file) return "PARTNER CAN'T RECEIVE";
    if (r.kind == .slot) return if (caps.takes_slot()) null else "PARTNER TAKES FILES";
    if (proto.plan(caps, r.file_refused == null, r.slot_refused == null) != null) return null;
    return if (caps.v2 and caps.file) r.file_refused else r.slot_refused;
}

/// Sent as a file to this partner (else as a slot image): the size shown.
fn row_as_file(r: *const Row) bool {
    if (r.kind == .slot) return false;
    const caps = partner_caps() orelse return true;
    const pl = proto.plan(caps, r.file_refused == null, r.slot_refused == null) orelse return caps.v2 and caps.file;
    return pl.kind == .file;
}

fn refusal(e: slot.Uf2Error) []const u8 {
    return switch (e) {
        error.Xip => "XIP CART: CAN'T BEAM",
        error.OutsideCartRam => "NOT A RAM CART",
        error.StraddlesIpc => "ODD LAYOUT: CAN'T",
        error.WrongFamily => "NOT FOR THIS CHIP",
        error.NoDescriptor, error.BadDescriptor => "NO CART DESCRIPTOR",
        error.NotUf2, error.BadBlock, error.Incomplete => "NOT A VALID UF2",
    };
}

// ---- screens: logic ------------------------------------------------------------------------

fn say_toast(now: u64, msg: []const u8) void {
    const n = @min(msg.len, toast_buf.len);
    @memcpy(toast_buf[0..n], msg[0..n]);
    toast = toast_buf[0..n];
    toast_until = now + 3_000_000;
}

fn home(now: u64, pressed: cart.Controls) void {
    if (receive_built) {
        // An offer refused before it was shown (too big, bad header, no
        // room, a computer on USB): say so.
        if (receiver.state == .finished) {
            switch (receiver.result) {
                .refused => |why| say_toast(now, switch (why) {
                    .usb => "REFUSED: UNPLUG USB",
                    .no_space => "REFUSED: DRIVES FULL",
                    .too_big => "REFUSED: TOO BIG",
                    .drive => "REFUSED: DRIVE ERROR",
                    else => "REFUSED AN OFFER",
                }),
                else => {},
            }
            receiver.reset();
        }
        // Ask now and then whether a computer has the drives.
        if (my_caps.file and now -% usb_polled_at >= usb_poll_us) {
            usb_polled_at = now;
            if (cart_files.refresh()) |f| usb_host = f.usb_host else |_| {}
        }
    }
    if (row_count > 0) {
        if (pressed.up and selected > 0) selected -= 1;
        if (pressed.down and selected + 1 < row_count) selected += 1;
    }
    if (pressed.select and row_count > 0 and rows[selected].kind == .slot and receive_built and io.can_receive()) {
        set_mode(.confirm_clear);
        return;
    }
    if (!pressed.a or row_count == 0) return;
    const r = &rows[selected];
    if (!r.analysed) return;
    if (row_refusal(r)) |why| return say_toast(now, why);
    if (!l.connected()) return say_toast(now, if (l.state == .unavailable) "NO LINK HERE" else "PLUG IN THE CABLE");
    if (l.partner_app != app_id) return say_toast(now, "PARTNER: RUN BEAM");
    begin_prepare(r) catch return say_toast(now, "DRIVE ERROR");
}

fn begin_prepare(r: *const Row) !void {
    const caps = partner_caps() orelse return error.NoPartner;
    prep_crc = .{};
    prep_len = 0;
    prep_slot_crc = null;
    switch (r.kind) {
        .file => {
            prep_plan = proto.plan(caps, r.file_refused == null, r.slot_refused == null) orelse return error.Refused;
            prep_file = try map_row(r);
            prep_file_crc = .init();
            if (prep_plan.kind == .slot or prep_plan.fallback) {
                const u = try slot.Uf2(DriveFile).open(prep_file);
                prep_src = .{ .uf2 = u };
                prep_len = u.info.image_len;
            }
            const n = @min(r.entry.name_len, prep_name.len);
            @memcpy(prep_name[0..n], r.entry.name[0..n]);
            prep_name_len = @intCast(n);
        },
        .slot => {
            prep_plan = .{ .kind = .slot, .fallback = false };
            const a = ext_flash.area() orelse return error.NoSlot;
            const h = slot_header orelse return error.NoSlot;
            prep_src = .{ .flat = a[slot.image_offset..][0..h.image_len] };
            prep_len = h.image_len;
            prep_header = a[0..slot.header_size].*;
            prep_slot_crc = h.image_crc32;
            const n = h.name_len;
            @memcpy(prep_name[0..n], h.name());
            prep_name_len = n;
        },
    }
    set_mode(.preparing);
}

/// Bytes the preparing step hashes: the file (file mode), then the image
/// (slot mode or the fallback).
fn prep_total() u32 {
    const file: u32 = if (prep_plan.kind == .file) prep_file.size() else 0;
    return file + prep_len;
}

fn prep_done() u32 {
    const file: u32 = if (prep_plan.kind == .file) prep_file_crc.at else 0;
    return file + prep_crc.at;
}

fn prepare(now: u64, pad: cart.Controls) void {
    if (pad.b and !pad.start) return set_mode(.home);
    var budget: u32 = prepare_chunks_per_frame * slot.sector_size;
    if (prep_plan.kind == .file and prep_file_crc.at < prep_file.size()) {
        const before = prep_file_crc.at;
        _ = prep_file_crc.step(&prep_file.m, budget);
        budget -|= prep_file_crc.at - before;
    }
    while (budget > 0 and prep_crc.at < prep_len) {
        const n = @min(slot.sector_size, prep_len - prep_crc.at);
        prep_src.read(prep_crc.at, scratch[0..n]);
        prep_crc.h.update(scratch[0..n]);
        prep_crc.at += n;
        budget -|= n;
    }
    if (prep_done() < prep_total()) return;
    if (!l.connected()) {
        say_toast(now, "CABLE OUT");
        return set_mode(.home);
    }
    const name = prep_name[0..prep_name_len];
    if (prep_len > 0) {
        const crc = prep_crc.final();
        switch (prep_src) {
            .uf2 => |*u| prep_header = u.header(crc, name).encode(),
            .flat => if (prep_slot_crc.? != crc) {
                say_toast(now, "SLOT IS DAMAGED");
                return set_mode(.home);
            },
            .file => unreachable,
        }
    }
    last_xfer +%= 1 + @as(u8, @truncate(xfer_seed % 200));
    if (last_xfer == 0) last_xfer = 1;
    if (prep_plan.kind == .file) {
        const h = proto.FileHeader.init(prep_file.size(), prep_file_crc.final(), name);
        prep_offer = .of_file(&h, .{ .file = prep_file });
        if (prep_plan.fallback) prep_fallback = .of_slot(&prep_header, prep_len, prep_src);
        sender.start(&io, &prep_offer, if (prep_plan.fallback) &prep_fallback else null, last_xfer);
    } else {
        prep_offer = .of_slot(&prep_header, prep_len, prep_src);
        sender.start(&io, &prep_offer, null, last_xfer);
    }
    send_started = 0;
    b_down_since = null;
    set_mode(.sending);
}

/// True once B has been held long enough (Start+Select belongs to the OS).
fn cancel_held(now: u64, pad: cart.Controls) bool {
    if (!pad.b or pad.start) {
        b_down_since = null;
        return false;
    }
    const since = b_down_since orelse now;
    b_down_since = since;
    return now -% since >= cancel_hold_us;
}

fn sending(now: u64, pad: cart.Controls, pressed: cart.Controls) void {
    if (sender.state == .sending and send_started == 0) send_started = now;
    if (sender.active()) {
        if (cancel_held(now, pad)) sender.cancel(&io);
        return;
    }
    // A slot fallback used the next transfer id.
    last_xfer = sender.xfer;
    if (pressed.a or pressed.b) {
        sender.reset();
        set_mode(.home);
    }
}

fn offer(pressed: cart.Controls) void {
    if (receive_built) offer_rx(pressed) else set_mode(.home);
}

fn offer_rx(pressed: cart.Controls) void {
    switch (receiver.state) {
        .asking => {
            if (pressed.a) {
                receiver.accept(&io);
                b_down_since = null;
                set_mode(.receiving);
            } else if (pressed.b) {
                receiver.decline(&io);
                receiver.reset();
                set_mode(.home);
            }
        },
        else => {
            // Timed out (declined), or the sender gave up.
            receiver.reset();
            set_mode(.home);
        },
    }
}

fn receiving(now: u64, pad: cart.Controls, pressed: cart.Controls) void {
    if (receive_built) receiving_rx(now, pad, pressed) else set_mode(.home);
}

fn receiving_rx(now: u64, pad: cart.Controls, pressed: cart.Controls) void {
    if (receiver.busy()) {
        if (cancel_held(now, pad)) receiver.cancel(&io);
        return;
    }
    if (pressed.a or pressed.b) {
        receiver.reset();
        set_mode(.home);
        scan();
    }
}

fn confirm_clear(pressed: cart.Controls) void {
    if (pressed.a) {
        _ = io.erase(0);
        set_mode(.home);
        scan();
    } else if (pressed.b) {
        set_mode(.home);
    }
}

/// Buttons down now that were up last frame, ignoring the OS's
/// Start+Select chord.
fn presses(before: cart.Controls, after: cart.Controls) cart.Controls {
    if (after.start and after.select) return none;
    return @bitCast(@as(u16, @bitCast(after)) & ~@as(u16, @bitCast(before)));
}

// ---- drawing ---------------------------------------------------------------------------------

const list_y = 34;
const row_h = 9;
const visible_rows = 7;

fn draw(now: u64) void {
    const full = full_redraw;
    full_redraw = false;
    switch (mode) {
        // The list screens are cheap: redraw them whole (vsync is on).
        .home => draw_home(now),
        .confirm_clear => draw_confirm(),
        .offer => if (receive_built) draw_offer(now),
        .preparing, .sending => draw_sending(full, now),
        .receiving => if (receive_built) draw_receiving(full),
    }
}

fn clear() void {
    cart.rect(.{ .x = 0, .y = 0, .width = 160, .height = 128, .fill_color = bg });
}

fn draw_home(now: u64) void {
    clear();
    say(2, "SNOUTY BEAM", accent);
    draw_link_state();
    if (row_count == 0) {
        say(52, if (cart.is_wasm) "NO DRIVES IN" else "NO CARTS ON", dim);
        say(62, if (cart.is_wasm) "THE SIMULATOR" else "THE DRIVE", dim);
    } else {
        if (selected < scroll) scroll = selected;
        if (selected >= scroll + visible_rows) scroll = selected + 1 - visible_rows;
        var i: u8 = scroll;
        while (i < row_count and i < scroll + visible_rows) : (i += 1) draw_row(i, list_y + @as(i32, i - scroll) * row_h);
        if (scroll > 0) cart.text(.{ .str = "^", .x = 152, .y = list_y - 8, .text_color = dim });
        if (scroll + visible_rows < row_count) cart.text(.{ .str = "v", .x = 152, .y = list_y + visible_rows * row_h, .text_color = dim });
    }
    // Detail of the highlighted row, or a toast.
    if (now < toast_until) {
        say(100, toast, warn);
    } else if (row_count > 0) {
        const r = &rows[selected];
        if (!r.analysed) {
            say(100, "READING...", dim);
        } else if (row_refusal(r)) |why| {
            say(100, why, warn);
        } else if (r.kind == .slot) {
            say(100, if (receive_built and io.can_receive()) "A: SEND  SEL: CLEAR" else "A: SEND", fg);
        } else {
            say(100, if (drives_present > 1 and r.entry.drive == 1) "A: SEND (DRIVE 2)" else "A: SEND", fg);
        }
    }
    draw_footer();
}

fn draw_link_state() void {
    if (demo != 0) return say(14, "CONNECTED", good);
    switch (l.state) {
        .unavailable => say(14, "NO LINK IN SIMULATOR", dim),
        .searching, .handshake => say(14, "PLUG IN THE CABLE", dim),
        .connected => if (l.partner_app != app_id) {
            say(14, "WRONG CART:", warn);
            say(23, lockstep.app_name(l.partner_app), warn);
        } else {
            say(14, "CONNECTED", good);
        },
    }
}

fn draw_row(i: u8, y: i32) void {
    const r = &rows[i];
    const sel = i == selected;
    if (sel) cart.rect(.{ .x = 0, .y = y - 1, .width = 160, .height = row_h, .fill_color = sel_bg });
    const color = if (row_refusal(r) != null) dim else if (r.kind == .slot) accent else fg;
    var name_buf: [14]u8 = undefined;
    const name = switch (r.kind) {
        .file => stem(r.entry.slice()),
        .slot => if (slot_header) |*h| h.name() else "?",
    };
    var n: usize = 0;
    if (r.kind == .slot) {
        name_buf[0] = '*';
        n = 1;
    }
    const take = @min(name.len, name_buf.len - n);
    @memcpy(name_buf[n..][0..take], name[0..take]);
    n += take;
    cart.text(.{ .str = name_buf[0..n], .x = 0, .y = y, .text_color = color });
    // The bytes this partner would get: the file, or the slot image.
    const bytes = if (row_as_file(r)) r.entry.size else r.image_len;
    if (r.analysed and bytes > 0) {
        var buf: [8]u8 = undefined;
        const s = fmt(&buf, "{d}K", .{(bytes + 1023) / 1024});
        cart.text(.{ .str = s, .x = @intCast(160 - s.len * 8), .y = y, .text_color = color });
    }
}

fn draw_footer() void {
    if (!receive_built) {
        say(110, "RECEIVING NEEDS THE", dim);
        say(119, "FORK FIRMWARE BUILD", dim);
    } else if (!my_caps.slot and !my_caps.file) {
        say(110, "CAN'T RECEIVE: NEEDS", dim);
        say(119, "THE FORK FIRMWARE", dim);
    } else if (my_caps.file and usb_host) {
        // Files are refused while a computer has the drives mounted
        // (fork/CART_FILES.md "Why this is safe").
        say(110, "UNPLUG FROM THE", warn);
        say(119, "COMPUTER TO RECEIVE", warn);
    } else {
        say(110, if (my_caps.file) "CAN RECEIVE FILES" else "CAN RECEIVE", good);
        var buf: [24]u8 = undefined;
        if (!my_caps.slot) {
            // Files only: nothing about a slot to say.
        } else if (slot_header) |*h| {
            say(119, fmt(&buf, "SLOT: {s}", .{clip(h.name(), 14)}), dim);
        } else {
            say(119, "SLOT: EMPTY", dim);
        }
    }
}

fn draw_confirm() void {
    clear();
    say(2, "SNOUTY BEAM", accent);
    say(40, "CLEAR THE SLOT?", fg);
    if (slot_header) |*h| say(52, clip(h.name(), 20), accent);
    say(72, "THE MENU WILL NO", dim);
    say(81, "LONGER LIST IT.", dim);
    say(104, "A: CLEAR  B: KEEP", fg);
}

fn draw_offer(now: u64) void {
    clear();
    say(2, "INCOMING CART", accent);
    const name = receiver.name();
    say(24, "RECEIVE", fg);
    say(34, clip(name, 20), accent);
    if (name.len > 20) say(43, clip(name[20..], 20), accent);
    var buf: [24]u8 = undefined;
    const kb = (receiver.total + 1023) / 1024;
    if (receiver.kind == .file) {
        // "RECEIVE <name>, <KB> KB TO SYCLBADGE?"
        say(54, fmt(&buf, "{d} KB TO", .{kb}), fg);
        say(63, fmt(&buf, "{s}?", .{cart_files.volume_names[receiver.volume]}), fg);
    } else {
        say(54, fmt(&buf, "{d} KB?", .{kb}), fg);
        if (slot_header) |*old| {
            say(70, "REPLACES", dim);
            say(79, clip(old.name(), 20), dim);
        }
    }
    const left = proto.timing.offer_timeout -| (now -% receiver.asked_at);
    say(96, fmt(&buf, "{d} S", .{left / 1_000_000}), dim);
    say(110, "A: ACCEPT", good);
    say(119, "B: DECLINE", fg);
}

fn bar(y: i32, permille: u32) void {
    const w: u32 = 144 * @as(u32, @min(permille, 1000)) / 1000;
    cart.rect(.{ .x = 8, .y = y, .width = 144, .height = 10, .fill_color = bar_bg });
    if (w > 0) cart.rect(.{ .x = 8, .y = y, .width = w, .height = 10, .fill_color = accent });
}

fn draw_sending(full: bool, now: u64) void {
    if (full) {
        clear();
        say(2, "SENDING", accent);
        say(20, clip(stem(prep_name[0..prep_name_len]), 20), fg);
    }
    // Only the parts below change from frame to frame.
    cart.rect(.{ .x = 0, .y = 40, .width = 160, .height = 88, .fill_color = bg });
    var buf: [24]u8 = undefined;
    if (mode == .preparing) {
        const total = prep_total();
        bar(44, if (total == 0) 0 else @intCast(@as(u64, prep_done()) * 1000 / total));
        say(60, "PREPARING", dim);
        return;
    }
    bar(44, sender.permille());
    say(60, fmt(&buf, "{d}K / {d}K", .{ sender.acked / 1024, (sender.total + 1023) / 1024 }), fg);
    switch (sender.state) {
        .offering, .waiting_answer => {
            say(76, "WAITING FOR THE", dim);
            say(85, "PARTNER TO ACCEPT", dim);
            say(119, "HOLD B: CANCEL", dim);
        },
        .sending, .finishing => {
            if (send_started != 0 and now > send_started) {
                // The preview's clock is not real time: show the model's rate.
                const kbs = if (demo != 0) 29 else @as(u64, sender.acked) * 1000 / (now - send_started);
                say(76, fmt(&buf, "{d} KB/S", .{kbs}), dim);
            }
            say(119, "HOLD B: CANCEL", dim);
        },
        .finished, .idle => {
            const r = send_result_text(sender.result, sender.kind());
            say(76, r[0], if (sender.result == .sent) good else warn);
            say(85, r[1], dim);
            say(119, "A: OK", fg);
        },
    }
}

fn send_result_text(r: proto.SendResult, kind: proto.Kind) [2][]const u8 {
    return switch (r) {
        .sent => .{ "SENT", if (kind == .file) "AS A FILE" else "TO THEIR SLOT" },
        .rejected => |why| switch (why) {
            .declined => .{ "DECLINED", "" },
            .too_big => .{ "TOO BIG FOR", "THEIR SLOT" },
            .cannot_receive => .{ "PARTNER CAN'T", "RECEIVE (FIRMWARE)" },
            .busy => .{ "PARTNER IS BUSY", "TRY AGAIN" },
            .usb => .{ "PARTNER: UNPLUG", "FROM THE COMPUTER" },
            .no_space => .{ "NO ROOM ON THE", "PARTNER'S DRIVES" },
            .drive => .{ "PARTNER'S DRIVE", "REFUSED THE FILE" },
            else => .{ "REFUSED", "" },
        },
        .no_answer => .{ "NO ANSWER", "" },
        .partner_aborted => |why| switch (why) {
            .flash => .{ "PARTNER'S FLASH", "WRITE FAILED" },
            .usb => .{ "PARTNER PLUGGED", "INTO A COMPUTER" },
            .drive => .{ "PARTNER'S DRIVE", "WRITE FAILED" },
            else => .{ "PARTNER", "CANCELLED" },
        },
        .failed => |st| switch (st) {
            .usb => .{ "PARTNER PLUGGED", "INTO A COMPUTER" },
            .drive => .{ "PARTNER'S DRIVE", "WRITE FAILED" },
            else => .{ "PARTNER'S CHECK", "FAILED" },
        },
        .cancelled => .{ "CANCELLED", "" },
        .link_lost => .{ "CABLE OUT OR", "PARTNER LEFT" },
        .none => .{ "", "" },
    };
}

fn draw_receiving(full: bool) void {
    const file = receiver.kind == .file;
    if (full) {
        clear();
        say(2, "RECEIVING", accent);
        say(20, clip(receiver.name(), 20), fg);
    }
    cart.rect(.{ .x = 0, .y = 40, .width = 160, .height = 88, .fill_color = bg });
    var buf: [24]u8 = undefined;
    bar(44, receiver.permille());
    say(60, fmt(&buf, "{d}K / {d}K", .{ receiver.written / 1024, (receiver.total + 1023) / 1024 }), fg);
    switch (receiver.state) {
        .verifying => say(76, if (file) "SAVING" else "CHECKING", dim),
        .finished, .idle => {
            switch (receiver.result) {
                .received => if (file) {
                    // The drive and the final name (numbered if taken).
                    say(68, "RECEIVED ON", good);
                    say(77, cart_files.volume_names[receiver.volume], good);
                    say(87, clip(receiver.name(), 20), accent);
                    say(100, "OPEN THE MENU", fg);
                    say(109, "TO RUN IT.", fg);
                } else {
                    say(76, "RECEIVED", good);
                    say(88, "OPEN THE MENU", fg);
                    say(97, "TO RUN IT.", fg);
                },
                .sender_aborted => say(76, "SENDER CANCELLED", warn),
                .cancelled => say(76, "CANCELLED", warn),
                .link_lost => {
                    say(76, "CABLE OUT OR", warn);
                    say(85, "PARTNER LEFT", warn);
                },
                .failed => |st| switch (st) {
                    .usb => {
                        say(76, "UNPLUG FROM THE", warn);
                        say(85, "COMPUTER, TRY AGAIN", warn);
                    },
                    .drive => say(76, "DRIVE WRITE FAILED", warn),
                    .crc => say(76, "CHECK FAILED", warn),
                    else => say(76, "FLASH WRITE FAILED", warn),
                },
                .refused => |why| say(76, if (why == .no_space) "NO ROOM ON THE DRIVE" else if (why == .usb) "UNPLUG FROM USB" else "COULDN'T SAVE IT", warn),
                .declined, .none => {},
            }
            if (receiver.result != .received) say(97, if (file) "NOTHING WAS SAVED" else "SLOT IS EMPTY NOW", dim);
            say(119, "A: OK", fg);
        },
        else => say(119, "HOLD B: CANCEL", dim),
    }
}

/// A file name without its extension.
fn stem(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return if (dot == 0) name else name[0..dot];
}

fn clip(s: []const u8, n: usize) []const u8 {
    return s[0..@min(s.len, n)];
}

/// Text centred on the screen (8x8 font).
fn say(y: i32, str: []const u8, color: cart.DisplayColor) void {
    const s = clip(str, 20);
    const x = (160 - s.len * 8) / 2;
    cart.text(.{ .str = s, .x = @intCast(x), .y = y, .text_color = color });
}

fn fmt(buf: []u8, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, f, args) catch "?";
}

// ---- preview scenes (simulator only) ---------------------------------------------

/// The simulator has no drives and no link, so the preview GIF
/// (docs/preview.gif, `--call-at "T beam_demo:N"`) stages two scenes with
/// made-up rows: 1 the home list, 2 a send in progress. Badge builds never
/// export or call this.
var demo: u32 = 0;

comptime {
    if (cart.is_wasm) @export(&beam_demo, .{ .name = "beam_demo" });
}

fn beam_demo(scene: u32) callconv(.c) u32 {
    demo = scene;
    const Sample = struct { name: []const u8, kb: u32, refused: ?[]const u8 = null };
    const samples = [_]Sample{
        .{ .name = "snouty-pong.uf2", .kb = 24 },
        .{ .name = "snouty-boy.uf2", .kb = 125 },
        .{ .name = "raspberry-trail.uf2", .kb = 109 },
        .{ .name = "paperclips.uf2", .kb = 173 },
        .{ .name = "demosnout.uf2", .kb = 259 },
        .{ .name = "snouty-zero-xip.uf2", .kb = 438 },
        .{ .name = "notes.uf2", .kb = 3, .refused = "NOT A VALID UF2" },
    };
    row_count = 0;
    for (samples) |smp| {
        var e: romfs.Entry = .{ .name_len = @intCast(smp.name.len) };
        @memcpy(e.name[0..smp.name.len], smp.name);
        e.size = smp.kb * 2048;
        rows[row_count] = .{ .entry = e, .analysed = true, .image_len = smp.kb * 1024, .slot_refused = smp.refused, .file_refused = smp.refused };
        row_count += 1;
    }
    analyse_next = row_count;
    if (scene == 2) {
        const name = "snouty-boy.uf2";
        @memcpy(prep_name[0..name.len], name);
        prep_name_len = name.len;
        sender = .{ .state = .sending, .total = 250 * 1024 };
        set_mode(.sending);
        send_started = cart.micros_since_boot() -| 1;
    } else {
        set_mode(.home);
    }
    return scene;
}

/// Scene 2: the bar moves at the modelled 29 KB/s, about 1 KB a frame.
fn demo_step() void {
    if (demo != 2 or mode != .sending) return;
    if (sender.state != .sending) return;
    sender.acked = @min(sender.total, sender.acked + 1024 * 29 / 60 * 4);
    if (sender.acked >= sender.total) {
        sender.state = .finished;
        sender.result = .sent;
    }
}

// ---- simulator shims (CLAUDE.md "Simulator and headless preview") ---------------

/// The web simulator writes its buttons to address 0x04; the badge's OS
/// keeps `cart.controls`.
fn read_controls() cart.Controls {
    if (cart.is_wasm) return @bitCast(@as(*const volatile u16, @ptrFromInt(0x04)).*);
    return cart.controls.*;
}

/// The web simulator reads a legacy framebuffer at 0x20 with red and blue
/// swapped. Badge builds compile none of this.
fn present_wasm() void {
    const sim_framebuffer: *cart.Framebuffer = @ptrFromInt(0x20);
    for (cart.framebuffer, sim_framebuffer) |*src_column, *dst_column| {
        for (src_column, dst_column) |src, *dst| {
            const c = src.to_color();
            dst.* = .from_color(.{ .r = c.b, .g = c.g, .b = c.r });
        }
    }
}
