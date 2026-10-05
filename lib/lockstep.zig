//! Two-badge deterministic lockstep over lib/link.zig (docs/LOCKSTEP.md).
//! Extracted from Snouty GC's M4 net code (carts/snouty-gc/cart/src/net.zig
//! at 90683be4) and made game-agnostic, for Snouty GC, Snouty Cycles and
//! Snouty Zero.
//!
//! Both badges run the same deterministic World (`G.simulate` is pure in
//! `(World, inputs)`). They agree on a setup in a small lobby (the host is
//! the badge whose link HELLO nonce is higher; it sends SETUP and GO, both
//! send PICK), then exchange only their human's input byte, one per tick,
//! `G.input_delay` ticks ahead. `step` advances the World by one tick only
//! when it holds both humans' bytes for that tick, and nothing but those
//! bytes and the agreed setup (rules, picks, seed) reaches `simulate`.
//!
//! The input packet is 5 payload bytes, 8 on the wire, always: the PIO
//! receive FIFO holds 8 bytes, so one whole packet survives a badge that
//! polls only once a frame. It carries the newest of three consecutive
//! ticks (low 6 bits), the three input bytes and one 7-bit check piece; a
//! packet lost to the FIFO or the CRC is covered by the repeats, and a
//! badge that sees its partner stalled resends the ticks the partner needs
//! (the partner's newest tick bounds what it holds), so no retransmit
//! protocol is needed. The check pieces are 7-bit slices of the game's
//! 32-bit World hash, taken every `check_every` ticks: a mismatch is
//! `desync`.
//!
//! With one rules byte and picks of at most 3 bits (GC, Zero) every message
//! is byte-identical to GC's M4 net.zig, so a converted GC links with an M4
//! GC. More rules bytes (Cycles) or wider picks switch, at comptime, to a
//! paged SETUP and a GO that carries a digest of the rules instead of the
//! rules themselves (docs/LOCKSTEP.md section 4).
//!
//! Generic over the link (`Lockstep(link.Badge, G)` on the badge, a link
//! over lib/link_virtual.zig in the host tests); the link is owned by value.
//! No cart API, no clock (callers pass `now`), no floats, and no import of
//! link.zig (a cart's `link` module and this one stay separate files).
const std = @import("std");

// ---- app ids -----------------------------------------------------------------

/// The HELLO `app` byte of each cart that uses the link (`link.Badge.init(.{},
/// app_id, seed)`). The lockstep tells a partner from `wrong_cart` by
/// `link.partner_app == link.app`: the app id is whatever the cart gave its
/// link, nothing more to configure here.
pub const apps = struct {
    pub const link_test: u8 = 'L';
    pub const boy: u8 = 'B';
    pub const gc: u8 = 'G';
    pub const cycles: u8 = 'C';
    pub const zero: u8 = 'Z';
    pub const snoutenstein: u8 = 'S';
};

/// The cart behind a HELLO app byte, for "WRONG CART: <name>".
pub fn app_name(id: u8) []const u8 {
    return switch (id) {
        apps.link_test => "SNOUTY LINK",
        apps.boy => "SNOUTY BOY",
        apps.gc => "SNOUTY GC",
        apps.cycles => "SNOUTY CYCLES",
        apps.zero => "SNOUTY ZERO",
        apps.snoutenstein => "SNOUTENSTEIN",
        else => "ANOTHER CART",
    };
}

// ---- shared types and wire helpers --------------------------------------------

/// Timing in microseconds, adjustable in one place (GC's `net.timing`).
pub const timing = struct {
    /// Racing: an input packet goes out when a new local input is
    /// submitted (once a frame) but never sooner than this after the last
    /// packet, and at least this often while nothing new is submitted (a
    /// stall: the partner may need a lost tick). One packet a frame keeps
    /// the partner's 8-byte receive FIFO from overflowing.
    pub const min_gap: u64 = 12_000;
    pub const resend: u64 = 20_000;
    /// Lobby: one control message this often (the host alternates SETUP
    /// and PICK); after a change or a state switch the next goes after
    /// `ctrl_gap` instead.
    pub const lobby_every: u64 = 50_000;
    pub const ctrl_gap: u64 = 20_000;
    /// Host: GO again this often until the guest's first input arrives.
    pub const go_every: u64 = 100_000;
    /// `state()` says `.waiting` once `step` has had no inputs this long
    /// (30 frames).
    pub const waiting_after: u64 = 500_000;
    /// The partner's newest tick has not moved for this long: it is
    /// stalled on a tick of ours it lacks (a running badge's newest moves
    /// every frame), so every other packet carries the oldest tick it may
    /// need instead of the newest three.
    pub const peer_stalled: u64 = 25_000;
};

pub const State = enum(u8) {
    /// No link hardware (the wasm simulator): "NO LINK IN SIMULATOR".
    offline,
    /// The link is searching or handshaking (cable out, partner off).
    searching,
    /// Connected to a badge running another cart (`link.partner_app`).
    wrong_cart,
    /// Connected to this cart in another protocol version (`G.version`,
    /// the high nibble of `link.partner_version`). Nothing is sent: an
    /// older badge that ignores the version waits in its lobby.
    wrong_version,
    /// Connected, in the lobby: rules (host), picks, GO.
    lobby,
    /// A race is running; `step` advances it.
    racing,
    /// Racing, but `step` has had no partner input for `waiting_after`.
    waiting,
    /// The partner went away (or left the race): `step` goes on solo, the
    /// game's AI driving the partner's slot (`G.hand_over`). Until `leave`.
    peer_left,
    /// The World hashes differ: `step` stops. Until `leave`.
    desync,
};

/// Why the partner left the race (`peer_left`).
pub const Left = enum(u8) { none, unplugged, restarted, quit };

pub const Role = enum(u8) { none, host, guest };

pub const Stats = struct {
    /// Input packets sent and received (repeats included).
    inputs_sent: u32 = 0,
    inputs_recv: u32 = 0,
    /// Input packets that brought no new tick (everything already held).
    inputs_stale: u32 = 0,
    /// Sends of an older window for a stalled partner.
    old_windows: u32 = 0,
    control_sent: u32 = 0,
    control_recv: u32 = 0,
    /// Check pieces compared (equal) and GOs re-sent.
    checks_ok: u32 = 0,
    go_resends: u32 = 0,
    /// `step` calls that found no inputs; pumps.
    stalls: u32 = 0,
    pumps: u32 = 0,
};

/// Control messages: DATA packets with this kind byte first, never 5 bytes
/// long (a 5-byte packet is an input packet). GC's kinds; the paged SETUP
/// and the digest GO (more rules bytes, or wide picks) have kind ranges of
/// their own, see `Lockstep`.
pub const Msg = enum(u8) {
    /// host: kind, race id, rules (one rules byte only)
    setup = 0xA1,
    /// both: kind, race id, pick (value bits 0-6, ready bit 7)
    pick = 0xA2,
    /// host: kind, new race id, rules, picks (host bits 0-2, guest 4-6);
    /// one rules byte and 3-bit picks only
    go = 0xA3,
    /// both: kind, race id (this badge left that race)
    quit = 0xA4,
    /// both: kind, race id (this badge found a desync in that race; the
    /// partner may not get the check piece that shows it, as this badge
    /// stops sending inputs)
    desync = 0xA5,
    _,
};
pub const input_len = 5;

/// lib/link.zig's DATA kind byte and CRC (the tests check they match): the
/// input packet picks its salt bits so its CRC never needs escaping.
pub const data_kind: u8 = 0x10;
pub fn crc8(bytes: []const u8) u8 {
    var c: u8 = 0;
    for (bytes) |byte| {
        c ^= byte;
        for (0..8) |_| c = if (c & 0x80 != 0) (c << 1) ^ 0x07 else c << 1;
    }
    return c;
}

/// SLIP's END and ESC: either byte costs an extra wire byte.
pub fn slip_special(b: u8) bool {
    return b == 0xC0 or b == 0xDB;
}

/// The input packet for the three ticks n-2, n-1, n: `ins` = inputs for
/// n, n-1, n-2; `check` a 7-bit piece. Byte 0 is n mod 64 plus two salt
/// bits, chosen so the link's CRC is not a SLIP special byte (the three
/// salts 0, 0x40, 0x80 give three different CRCs and only two are
/// special); no other byte can be special (inputs never have both bits 6
/// and 7, `sanitize`; check < 0x80), so the packet is always 5 + 3 = 8
/// wire bytes.
pub fn encode_input(n: u32, ins: [3]u8, check: u8) [input_len]u8 {
    var p = [input_len]u8{ @as(u8, @truncate(n)) & 0x3F, ins[0], ins[1], ins[2], check & 0x7F };
    for ([_]u8{ 0x00, 0x40, 0x80 }) |salt| {
        p[0] = (p[0] & 0x3F) | salt;
        var buf: [1 + input_len]u8 = undefined;
        buf[0] = data_kind;
        @memcpy(buf[1..], &p);
        if (!slip_special(crc8(&buf))) break;
    }
    return p;
}

/// Input bytes never have bits 6 and 7 both set: that is Start+Select in
/// the usual layout (bit 6 Start, bit 7 Select), the OS chord the cart
/// never sees, and it keeps 0xC0 and 0xDB out of input bytes. `submit`
/// clears both when both are set.
pub fn sanitize(byte: u8) u8 {
    return if (byte & 0xC0 == 0xC0) byte & 0x3F else byte;
}

/// A 32-bit hash of every field of `v` by reflection (structs, packed
/// structs, arrays, enums, bools, ints up to 32 bits): padding is never
/// read, so equal values hash equal on both badges. GC's `world_hash`,
/// made generic; a game with a big World (Cycles: 38 KB) writes its own
/// `G.hash` instead. Its cost is one mix per field.
pub fn hash_fields(comptime T: type, v: *const T) u32 {
    var h: u32 = 0x811C_9DC5;
    mix(T, v, &h);
    h ^= h >> 16;
    h *%= 0x85EB_CA6B;
    h ^= h >> 13;
    h *%= 0xC2B2_AE35;
    h ^= h >> 16;
    return h;
}

fn feed(h: *u32, x: u32) void {
    h.* = std.math.rotl(u32, h.* ^ x, 5) *% 0x9E37_79B1;
}

fn mix(comptime T: type, v: *const T, h: *u32) void {
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            if (s.layout == .@"packed") {
                const I = @Int(.unsigned, @bitSizeOf(T));
                return mix(I, &@as(I, @bitCast(v.*)), h);
            }
            inline for (s.field_names, s.field_types) |name, F| mix(F, &@field(v.*, name), h);
        },
        .array => |a| for (v) |*x| mix(a.child, x, h),
        .@"enum" => feed(h, @backingInt(v.*)),
        .bool => feed(h, @intFromBool(v.*)),
        .int => {
            const bits = @bitSizeOf(T);
            if (bits > 32) @compileError("hash_fields: field wider than 32 bits");
            const U = @Int(.unsigned, bits);
            feed(h, @as(U, @bitCast(v.*)));
        },
        else => @compileError("hash_fields: unsupported field type " ++ @typeName(T)),
    }
}

/// The 7-bit piece i (0..3) of a hash.
fn piece(h: u32, i: u32) u8 {
    return @truncate((h >> @intCast(7 * i)) & 0x7F);
}

const Phase = enum(u8) { offline, searching, wrong_cart, wrong_version, lobby, racing, peer_left, desync };

const Check = struct { epoch: u32 = 0, hash: u32 = 0 };

// ---- the lockstep ----------------------------------------------------------------

/// `L`: the link type (`link.Badge`, or `link.Link(Port)` in host tests).
/// `G`: the game, a namespace with
///   World: type
///   fn simulate(w: *World, in: [2]u8) void      slot 0 host, 1 guest
///   fn hash(w: *const World) u32                every check_every ticks
///   fn hand_over(w: *World, slot: u1) void      the partner left: AI
///   rules_len: comptime_int (1..8)              host's rules bytes
///   input_delay: u32 (2..6)                     ticks
/// and optionally
///   check_every: u32 = 32                       ticks between hashes
///   pause_bit: ?u8 = null                       press edge toggles paused
///   fn picks_ok(host: u8, guest: u8) bool       = true (GO allowed)
///   fn can_pause(w: *const World) bool          = true (false: unpause)
///   pick_bits: u8 = 3                           pick values < 1 << pick_bits
///   version: u4 = 0                             another one: wrong_version
pub fn Lockstep(comptime L: type, comptime G: type) type {
    return struct {
        const Self = @This();

        pub const World = G.World;
        pub const rules_len: comptime_int = G.rules_len;
        /// Input delay in ticks: the byte submitted on frame f drives tick
        /// f + input_delay.
        pub const input_delay: u32 = G.input_delay;
        /// A World hash is taken every this many ticks.
        pub const check_every: u32 = if (@hasDecl(G, "check_every")) G.check_every else 32;
        /// A press edge of this bit in either human's byte toggles `paused`.
        pub const pause_bit: ?u8 = if (@hasDecl(G, "pause_bit")) G.pause_bit else null;
        /// The game's protocol version, in the high nibble of the link's
        /// HELLO version byte: a partner with another one is
        /// `wrong_version`. Bump it whenever the game's wire meaning changes
        /// (rules layout, input bits, World rules); 0 sends GC M4's HELLO.
        pub const version: u4 = if (@hasDecl(G, "version")) G.version else 0;
        /// Pick values are below 1 << pick_bits (bit 7 of a PICK is ready).
        pub const pick_bits: u8 = if (@hasDecl(G, "pick_bits")) G.pick_bits else 3;
        /// Packets whose newest tick n has n - check_lag in epoch e carry
        /// pieces of epoch e's hash; the lag makes sure both badges have
        /// taken it (a badge's newest tick is at most its partner's tick +
        /// 2 * delay + 1).
        pub const check_lag: u32 = 2 * input_delay + 4;
        /// Local inputs submitted past the next tick to step: delay + 1 (the
        /// byte of this frame is for tick T + delay, after this frame's step).
        const lead_max: u32 = input_delay + 1;
        /// Input rings (local and remote). The local ring holds what the
        /// partner may still need, the remote one what we have not stepped
        /// yet: each at most 2 * delay + 2 ticks (8 at delay 3, 14 at the
        /// largest delay 6), so 16 holds them.
        const ring_len = 16;
        const check_slots = 4;
        /// Delay 3 and up (and every form but GC's) keep remote ticks that
        /// arrive past a hole, until it fills. A badge
        /// may run delay + 1 ticks ahead of its partner, so with delay 3 the
        /// partner's newest window (its newest three ticks) starts past what
        /// a badge that lost a packet needs: GC's contiguous-only receive
        /// then leans on the 3-tick old window, one every other packet,
        /// and stalls about 40% of frames. In GC's form at delay 2 the
        /// window covers it and the receive stays GC M4's, step for step.
        const reorder = input_delay > 2 or !gc_wire;
        const pick_mask: u8 = (@as(u8, 1) << @intCast(pick_bits)) - 1;

        /// One rules byte and narrow picks: GC's SETUP and GO, which carries
        /// the rules. Otherwise SETUP is paged and GO carries a digest.
        pub const gc_wire = rules_len == 1 and pick_bits <= 3;
        const paged = rules_len > 1;
        /// SETUP pages of 2 rules bytes (paged only).
        pub const pages = (rules_len + 1) / 2;
        const all_pages: u8 = (@as(u8, 1) << pages) - 1;

        /// Paged SETUP: kind 0x80 | page << 2 | flip1 << 1 | flip0, race id,
        /// two rules bytes, each XORed with 0x80 when its flip bit is set
        /// (whichever keeps it off 0xC0 / 0xDB): only the CRC may need a
        /// SLIP escape, so the 4-byte message is at most 8 wire bytes.
        pub const setup_paged: u8 = 0x80;
        /// Digest GO, 3-bit picks: kind 0x90 | flip, new race id, CRC8 of
        /// the rules (XORed with 0x80 if flip), picks (host bits 0-2, guest
        /// 4-6). Wide picks: digest & 0x7F, new race id, host pick, guest
        /// pick (the only 4-byte message whose first byte is below 0x80).
        pub const go_digest: u8 = 0x90;

        comptime {
            if (rules_len < 1 or rules_len > 8) @compileError("lockstep: rules_len must be 1 to 8");
            if (input_delay < 2 or input_delay > 6) @compileError("lockstep: input_delay must be 2 to 6");
            if (check_every < 4) @compileError("lockstep: check_every must be at least 4");
            if (pick_bits < 1 or pick_bits > 7) @compileError("lockstep: pick_bits must be 1 to 7");
        }

        pub const Rules = [rules_len]u8;

        /// The agreed race (GO): id, rules, the two humans' picks in slot
        /// order (0 = host, 1 = guest) and the seed both derive from the
        /// link nonces.
        pub const Race = struct {
            id: u8 = 0,
            rules: Rules = @splat(0),
            picks: [2]u8 = .{ 0, 0 },
            seed: u32 = 1,
        };

        link: L,
        phase: Phase,
        role: Role = .none,
        /// Why the partner left (`peer_left`).
        left: Left = .none,
        /// The link session this lobby / race belongs to.
        session: u32 = 0,
        /// `now` of the last pump (us).
        now: u64 = 0,

        // ---- lobby ----
        /// Host: the rules it offers. Guest: what it heard (`heard_pages`).
        offer: Rules = @splat(0),
        heard: Rules = @splat(0),
        /// Guest: SETUP pages heard this session (bit per page).
        heard_pages: u8 = 0,
        /// Host: the SETUP page it sends next (paged only).
        page_next: u8 = 0,
        /// This badge's pick (value) and ready flag; the partner's last PICK
        /// byte this lobby (value bits 0-6, ready bit 7; null until heard,
        /// and again after each race).
        pick: u8 = pick_mask,
        ready: bool = false,
        peer_pick_byte: ?u8 = null,
        /// The last race this badge joined this session (0: none yet).
        /// Every control message carries it.
        race_id: u8 = 0,
        /// The agreed race (valid from `take_started`).
        race: Race = .{},
        started: bool = false,
        /// The next lobby message: SETUP or PICK (host alternates); QUIT
        /// first after leaving a race.
        turn: u1 = 0,
        quit_next: bool = false,
        /// Wait after `last_tx` before the next control message.
        ctrl_wait: u64 = timing.ctrl_gap,
        /// Last packet this layer sent (any kind).
        last_tx: u64 = 0,

        // ---- lockstep ----
        /// The next tick `step` runs (lockstep ticks, paused ones included).
        tick: u32 = 0,
        /// Inputs held: local for ticks < local_hi, remote for < remote_hi.
        local_hi: u32 = input_delay,
        remote_hi: u32 = input_delay,
        /// Lower bound of the partner's remote_hi (what it holds of ours):
        /// the newest tick it sent minus the delay. Exact while it is
        /// stalled (`timing.peer_stalled` since `peer_top_at`).
        peer_need: u32 = input_delay,
        peer_top: u32 = 0,
        peer_top_at: u64 = 0,
        local: [ring_len]u8 = @splat(0),
        remote: [ring_len]u8 = @splat(0),
        /// Delay 3 and up: remote ticks past a hole, held until it fills
        /// (bit t % ring_len, for ticks remote_hi < t < tick + ring_len).
        remote_ahead: if (reorder) u16 else void = if (reorder) 0 else {},
        /// Both input bytes of the last stepped tick (pause edges).
        prev: [2]u8 = .{ 0, 0 },
        /// Paused by a `pause_bit` press of either human (agreed: it comes
        /// from the input bytes of a tick). `step` keeps running ticks,
        /// without simulating them, so the lockstep and the checks go on.
        paused: bool = false,
        /// Host: the guest's first input arrived (until then GO repeats).
        peer_started: bool = false,
        /// peer_left: `G.hand_over` ran for the partner's slot.
        handed_over: bool = false,
        /// A new local input not yet sent; the window the next packet to a
        /// stalled partner carries (oldest or newest, alternating).
        dirty: bool = false,
        alt: bool = false,
        /// `step` found no inputs since this time (null: it found some).
        stall_since: ?u64 = null,
        checks: [check_slots]Check = @splat(.{}),
        /// Lockstep tick at which `desync` was found.
        desync_tick: u32 = 0,

        stats: Stats = .{},

        /// `l` = `link.Badge.init(.{}, app_id, cart.rand())`: the app id the
        /// cart gives its link is the one a partner must have.
        pub fn init(l: L) Self {
            const unavailable = l.state == .unavailable;
            var self: Self = .{ .link = l, .phase = if (unavailable) .offline else .searching };
            self.link.app_version = version;
            return self;
        }

        // ---- per frame -----------------------------------------------------

        /// Run the link and this layer: poll, follow the link state, read
        /// packets, send what is due. Callable from anywhere, as often as
        /// the cart likes (top of update, inside long draws, the loop to
        /// 14 ms while `busy`). With no partner it is one `link.poll` and
        /// a compare.
        pub fn pump(self: *Self, now: u64) void {
            self.now = now;
            self.stats.pumps +%= 1;
            if (self.phase == .offline) return;
            self.link.poll(now);
            if (self.phase == .searching and !self.link.connected()) return;
            self.follow_link(now);
            while (self.link.recv()) |p| self.handle(p.slice());
            self.send_due(now);
        }

        pub fn state(self: *const Self) State {
            return switch (self.phase) {
                .offline => .offline,
                .searching => .searching,
                .wrong_cart => .wrong_cart,
                .wrong_version => .wrong_version,
                .lobby => .lobby,
                .racing => if (self.stall_since) |s|
                    (if (self.now -% s >= timing.waiting_after) .waiting else .racing)
                else
                    .racing,
                .peer_left => .peer_left,
                .desync => .desync,
            };
        }

        /// A race runs (racing, waiting or peer_left): pump in a loop to
        /// 14 ms into the frame. Otherwise pumping once a frame is enough.
        pub fn busy(self: *const Self) bool {
            return self.phase == .racing or self.phase == .peer_left;
        }

        /// The input slot this badge drives: 0 for the host, 1 for the guest.
        pub fn local_slot(self: *const Self) u1 {
            return if (self.role == .guest) 1 else 0;
        }

        /// The partner's cart name (for `wrong_cart`).
        pub fn partner_name(self: *const Self) []const u8 {
            return app_name(self.link.partner_app);
        }

        // ---- lobby ---------------------------------------------------------

        /// Host: the rules to offer (ignored on the guest and outside the
        /// lobby).
        pub fn set_rules(self: *Self, r: Rules) void {
            if (self.role != .host or self.phase != .lobby) return;
            if (std.mem.eql(u8, &r, &self.offer)) return;
            if (paged) {
                // The changed page goes first.
                var i: u8 = 0;
                while (r[i] == self.offer[i]) i += 1;
                self.page_next = i / 2;
                self.turn = 0;
            }
            self.offer = r;
            self.ctrl_wait = timing.ctrl_gap;
        }

        /// The rules: during a race (and on its results until `leave`) the
        /// agreed ones; in the lobby the host's offer, or what the guest has
        /// heard (null until it has every page).
        pub fn rules(self: *const Self) ?Rules {
            switch (self.phase) {
                .racing, .peer_left, .desync => return self.race.rules,
                else => {},
            }
            if (self.role == .host) return self.offer;
            return if (self.heard_pages == all_pages) self.heard else null;
        }

        /// This badge's pick (bits 0 to pick_bits - 1; the game decides what
        /// a value means, "none" included) and ready flag.
        pub fn set_pick(self: *Self, pick: u8, ready: bool) void {
            const p = pick & pick_mask;
            if (p == self.pick and ready == self.ready) return;
            self.pick = p;
            self.ready = ready;
            self.ctrl_wait = timing.ctrl_gap;
        }

        /// The partner's pick (null until heard this lobby).
        pub fn peer_pick(self: *const Self) ?u8 {
            return if (self.peer_pick_byte) |b| b & pick_mask else null;
        }

        /// The partner is ready (on `peer_pick`).
        pub fn peer_ready(self: *const Self) bool {
            return if (self.peer_pick_byte) |b| b & 0x80 != 0 else false;
        }

        /// Host: both badges are ready and `G.picks_ok` agrees.
        pub fn can_go(self: *const Self) bool {
            if (self.phase != .lobby or self.role != .host or !self.ready) return false;
            const pp = self.peer_pick_byte orelse return false;
            return pp & 0x80 != 0 and picks_ok(self.pick, pp & pick_mask);
        }

        fn picks_ok(host: u8, guest: u8) bool {
            return if (@hasDecl(G, "picks_ok")) G.picks_ok(host, guest) else true;
        }

        /// Host: start the race (both badges run it from lockstep tick 0).
        /// False when `can_go` is not.
        pub fn go(self: *Self, now: u64) bool {
            if (!self.can_go()) return false;
            var id = self.race_id +% 1;
            if (id == 0) id = 1;
            // Digest GO: no SLIP escape in the id either (GC's GO keeps its
            // ids: byte-identical).
            if (!gc_wire and slip_special(id)) id += 1;
            self.race = .{ .id = id, .rules = self.offer, .picks = .{ self.pick, self.peer_pick_byte.? & pick_mask }, .seed = self.seed_of(id) };
            self.race_id = id;
            self.begin_race(now);
            return true;
        }

        /// True once per race start (both badges): reset the World from
        /// `rules()`, `picks()` and `seed()` before the first `step`.
        pub fn take_started(self: *Self) bool {
            const s = self.started;
            self.started = false;
            return s;
        }

        /// The agreed picks, host's then guest's (valid from `take_started`).
        pub fn picks(self: *const Self) [2]u8 {
            return self.race.picks;
        }

        /// The race seed, the same on both badges: from both link nonces and
        /// the race id (valid from `take_started`).
        pub fn seed(self: *const Self) u32 {
            return self.race.seed;
        }

        /// Leave the race (pause QUIT, results done, after peer_left or
        /// desync): back to the lobby, the partner hears QUIT. Also clears
        /// this badge's ready flag.
        pub fn leave(self: *Self, now: u64) void {
            switch (self.phase) {
                .racing, .peer_left, .desync => {},
                else => return,
            }
            _ = now;
            self.ready = false;
            self.peer_pick_byte = null;
            self.paused = false;
            self.stall_since = null;
            self.left = .none;
            self.started = false;
            if (self.link.connected() and self.link.session == self.session) {
                self.phase = .lobby;
                self.quit_next = true;
                self.ctrl_wait = timing.ctrl_gap;
            } else {
                self.phase = .searching;
            }
        }

        // ---- racing --------------------------------------------------------

        /// This frame's input byte (bits 6 and 7 never both, `sanitize`):
        /// call it once a frame while `busy`. It becomes the input for tick
        /// `local_hi`, at most delay + 1 ticks past the next tick to step
        /// (while `step` is stalled the frame's byte is dropped), and goes
        /// out at once. After the World is over the cart may keep calling
        /// it (with anything) until `leave`, so a partner that still lacks a
        /// tick of ours gets it: the last window is resent meanwhile.
        pub fn submit(self: *Self, now: u64, byte: u8) void {
            switch (self.phase) {
                .racing, .peer_left => {},
                else => return,
            }
            const b = sanitize(byte);
            if (self.local_hi < self.tick + lead_max) {
                self.local[self.local_hi % ring_len] = b;
                self.local_hi += 1;
                self.dirty = true;
            }
            self.send_due(now);
        }

        /// Run the next lockstep tick if both inputs are here: pause edges
        /// toggle `paused`, then (unless paused) `G.simulate(w, inputs)`.
        /// After `peer_left` the partner's slot goes to the AI first
        /// (`G.hand_over`, the only World write outside simulate; the
        /// partner is gone, so no agreement is needed) and the race goes on
        /// solo. At most one successful call a frame (the World runs at the
        /// frame rate; one input is submitted a frame): call it after
        /// `submit`, and while it returns false keep pumping and retry in
        /// the frame's waiting loop.
        pub fn step(self: *Self, w: *World) bool {
            const solo = self.phase == .peer_left;
            if (self.phase != .racing and !solo) return false;
            const t = self.tick;
            if (t >= self.local_hi or (!solo and t >= self.remote_hi)) {
                if (self.stall_since == null) self.stall_since = self.now;
                self.stats.stalls +%= 1;
                return false;
            }
            self.stall_since = null;
            const me = self.local_slot();
            var in: [2]u8 = undefined;
            in[me] = self.local[t % ring_len];
            in[me ^ 1] = if (solo) 0 else self.remote[t % ring_len];
            if (solo and !self.handed_over) {
                G.hand_over(w, me ^ 1);
                self.handed_over = true;
            }
            if (pause_bit) |pb| {
                const edge = ((in[0] & ~self.prev[0]) | (in[1] & ~self.prev[1])) & pb != 0;
                const pausable = if (@hasDecl(G, "can_pause")) G.can_pause(w) else true;
                if (!pausable) self.paused = false else if (edge) self.paused = !self.paused;
            }
            self.prev = in;
            if (!self.paused) G.simulate(w, in);
            self.tick = t + 1;
            if (self.tick % check_every == 0) {
                const e = self.tick / check_every;
                self.checks[e % check_slots] = .{ .epoch = e, .hash = G.hash(w) };
            }
            return true;
        }

        // ---- link state ----------------------------------------------------

        fn follow_link(self: *Self, now: u64) void {
            const up = self.link.connected();
            switch (self.phase) {
                .offline, .peer_left, .desync => {},
                .racing => {
                    if (!up) return self.peer_gone(.unplugged);
                    if (self.link.session != self.session) return self.peer_gone(.restarted);
                },
                .searching, .lobby, .wrong_cart, .wrong_version => {
                    if (!up) {
                        self.phase = .searching;
                        return;
                    }
                    if (self.phase == .searching or self.link.session != self.session) self.new_session(now);
                },
            }
        }

        fn new_session(self: *Self, now: u64) void {
            self.session = self.link.session;
            self.race_id = 0;
            self.peer_pick_byte = null;
            self.heard_pages = 0;
            self.page_next = 0;
            self.ready = false;
            self.quit_next = false;
            self.turn = 0;
            self.role = .none;
            if (self.link.partner_app != self.link.app) {
                self.phase = .wrong_cart;
                return;
            }
            if (self.link.partner_version >> 4 != version) {
                self.phase = .wrong_version;
                return;
            }
            const me = self.link.nonce;
            const them = self.link.partner_nonce;
            if (me == them) {
                // Who hosts is undecided (1 in 65536): lock again, new nonces.
                self.link.restart(now);
                self.phase = .searching;
                return;
            }
            self.role = if (me > them) .host else .guest;
            self.phase = .lobby;
            self.ctrl_wait = timing.ctrl_gap;
        }

        fn peer_gone(self: *Self, why: Left) void {
            self.phase = .peer_left;
            self.left = why;
            self.stall_since = null;
        }

        /// GC's seed_of: both nonces (higher first) and the race id.
        fn seed_of(self: *const Self, id: u8) u32 {
            const a = self.link.nonce;
            const b = self.link.partner_nonce;
            var x: u32 = (@as(u32, @max(a, b)) << 16 | @min(a, b)) ^ (@as(u32, id) *% 0x9E37_79B9);
            x ^= x >> 16;
            x *%= 0x85EB_CA6B;
            x ^= x >> 13;
            x *%= 0xC2B2_AE35;
            x ^= x >> 16;
            return if (x == 0) 1 else x;
        }

        fn begin_race(self: *Self, now: u64) void {
            self.phase = .racing;
            self.left = .none;
            self.tick = 0;
            self.local_hi = input_delay;
            self.remote_hi = input_delay;
            self.peer_need = input_delay;
            self.peer_top = 0;
            self.peer_top_at = now;
            self.local = @splat(0);
            self.remote = @splat(0);
            if (reorder) self.remote_ahead = 0;
            self.prev = .{ 0, 0 };
            self.paused = false;
            self.peer_started = self.role == .guest;
            self.handed_over = false;
            self.dirty = false;
            self.stall_since = null;
            self.checks = @splat(.{});
            self.peer_pick_byte = null;
            self.started = true;
            self.ctrl_wait = timing.ctrl_gap;
            // Digest GO: the host's first message is GO, then SETUP pages.
            if (!gc_wire) self.turn = 0;
        }

        // ---- receiving -----------------------------------------------------

        fn handle(self: *Self, p: []const u8) void {
            if (p.len == input_len) return self.on_input(p);
            if (p.len < 2) return;
            self.stats.control_recv +%= 1;
            const k = p[0];
            const id = p[1];
            if (paged and p.len >= 4 and k & 0xF0 == setup_paged) {
                return self.on_setup(id, (k >> 2) & 3, .{ p[2] ^ ((k & 1) << 7), p[3] ^ ((k & 2) << 6) });
            }
            if (!gc_wire and p.len == 4) {
                if (pick_bits <= 3 and k & 0xFE == go_digest) {
                    const d = p[2] ^ ((k & 1) << 7);
                    return self.on_go(id, d, p[3] & 7, (p[3] >> 4) & 7, null);
                }
                if (pick_bits > 3 and k < 0x80) return self.on_go(id, k, p[2], p[3], null);
            }
            switch (@as(Msg, @fromBackingInt(@intCast(k)))) {
                .setup => if (!paged and p.len >= 3) self.on_setup(id, 0, .{ p[2], 0 }),
                .pick => {
                    if (p.len < 3) return;
                    self.on_lobby_msg(id);
                    if (self.phase == .lobby) self.peer_pick_byte = p[2];
                },
                .go => if (gc_wire and p.len >= 4) self.on_go(id, 0, p[3] & 7, (p[3] >> 4) & 7, p[2]),
                .quit => self.on_lobby_msg(id),
                .desync => if (self.phase == .racing and id == self.race_id) self.found_desync(),
                _ => {},
            }
        }

        fn on_setup(self: *Self, id: u8, page: u8, two: [2]u8) void {
            // GC's GO carries the rules, so the host sends SETUP only from
            // the lobby and one with our race's id means it left. A digest
            // GO goes out between SETUPs (the guest may lack a page), so
            // there a SETUP says nothing about leaving (PICK and QUIT do).
            if (gc_wire) self.on_lobby_msg(id);
            if (self.phase != .lobby or self.role != .guest or page >= pages) return;
            const at = @as(usize, page) * 2;
            self.heard[at] = two[0];
            if (at + 1 < rules_len) self.heard[at + 1] = two[1];
            self.heard_pages |= @as(u8, 1) << @intCast(page);
        }

        /// The partner sends control messages only from the lobby, with the
        /// last race it joined: our race id means it left our race.
        fn on_lobby_msg(self: *Self, id: u8) void {
            if (self.phase == .racing and id == self.race_id) self.peer_gone(.quit);
        }

        /// GO with the host's and guest's picks: `rules_b` for GC's GO,
        /// else `digest` must match the rules heard in full (8 bits, or
        /// 7 with wide picks).
        fn on_go(self: *Self, id: u8, digest: u8, host_pick: u8, guest_pick: u8, rules_b: ?u8) void {
            if (self.role != .guest or self.phase != .lobby or id == self.race_id or id == 0) return;
            const hp = host_pick & pick_mask;
            const gp = guest_pick & pick_mask;
            if (!picks_ok(hp, gp)) return;
            var r: Rules = undefined;
            if (rules_b) |b| {
                r[0] = b;
            } else {
                if (self.heard_pages != all_pages) return;
                const mine = crc8(&self.heard);
                if ((if (pick_bits > 3) mine & 0x7F else mine) != digest) return;
                r = self.heard;
            }
            self.race_id = id;
            self.race = .{ .id = id, .rules = r, .picks = .{ hp, gp }, .seed = self.seed_of(id) };
            self.begin_race(self.now);
        }

        fn on_input(self: *Self, p: []const u8) void {
            if (self.phase != .racing) return;
            self.stats.inputs_recv +%= 1;
            // The newest tick from its low 6 bits: within 32 of remote_hi.
            const base = self.remote_hi;
            var d: i32 = @intCast((@as(u32, p[0] & 0x3F) -% base) & 0x3F);
            if (d >= 32) d -= 64;
            const n_signed = @as(i64, base) + d;
            if (n_signed < input_delay) return;
            const n: u32 = @intCast(n_signed);
            self.peer_started = true;
            // The partner's local_hi <= its tick + delay + 1, so it has
            // stepped (and holds our inputs) up to at least n - delay.
            if (n > self.peer_top) {
                self.peer_top = n;
                self.peer_top_at = self.now;
            }
            if (n - input_delay > self.peer_need) self.peer_need = n - input_delay;
            const before = self.remote_hi;
            var fresh = false;
            var k: u32 = 0;
            while (k < 3) : (k += 1) {
                const t = n - 2 + k;
                if (t == self.remote_hi and self.remote_hi - self.tick < ring_len) {
                    self.remote[t % ring_len] = p[3 - k];
                    self.remote_hi += 1;
                } else if (reorder and t > self.remote_hi and t < self.tick + ring_len) {
                    const bit = @as(u16, 1) << @intCast(t % ring_len);
                    if (self.remote_ahead & bit == 0) fresh = true;
                    self.remote[t % ring_len] = p[3 - k];
                    self.remote_ahead |= bit;
                }
                if (reorder) {
                    // The hole filled: take the run held past it.
                    while (true) {
                        const bit = @as(u16, 1) << @intCast(self.remote_hi % ring_len);
                        if (self.remote_ahead & bit == 0) break;
                        self.remote_ahead &= ~bit;
                        self.remote_hi += 1;
                    }
                }
            }
            if (self.remote_hi == before and !fresh) self.stats.inputs_stale +%= 1;
            self.verify(n, p[4]);
        }

        fn check_of(self: *const Self, e: u32) ?u32 {
            const c = self.checks[e % check_slots];
            return if (c.epoch == e) c.hash else null;
        }

        /// The check byte of a packet whose newest tick is n.
        fn check_byte(self: *const Self, n: u32) u8 {
            if (n < check_lag + check_every) return 0;
            const m = n - check_lag;
            const h = self.check_of(m / check_every) orelse return 0;
            return piece(h, m % 4);
        }

        fn verify(self: *Self, n: u32, c: u8) void {
            if (n < check_lag + check_every) return;
            const m = n - check_lag;
            const h = self.check_of(m / check_every) orelse return;
            if (piece(h, m % 4) == c & 0x7F) {
                self.stats.checks_ok +%= 1;
                return;
            }
            self.found_desync();
        }

        fn found_desync(self: *Self) void {
            self.phase = .desync;
            self.desync_tick = self.tick;
            self.stall_since = null;
            self.ctrl_wait = timing.ctrl_gap;
        }

        // ---- sending -------------------------------------------------------

        fn send_due(self: *Self, now: u64) void {
            const since = now -% self.last_tx;
            switch (self.phase) {
                .lobby => if (since >= self.ctrl_wait) self.send_lobby(now),
                .desync => if (since >= self.ctrl_wait) {
                    self.send_control(now, &.{ @backingInt(Msg.desync), self.race_id });
                    self.ctrl_wait = timing.lobby_every;
                },
                .racing => {
                    if (!self.peer_started) {
                        // Host: GO until the guest's first input shows it started.
                        if (since >= self.ctrl_wait) self.send_go(now);
                        return;
                    }
                    if ((self.dirty and since >= timing.min_gap) or since >= timing.resend) self.send_inputs(now);
                },
                else => {},
            }
        }

        fn send_control(self: *Self, now: u64, msg: []const u8) void {
            _ = self.link.send(now, msg);
            self.last_tx = now;
            self.stats.control_sent +%= 1;
        }

        fn send_go(self: *Self, now: u64) void {
            if (gc_wire) {
                if (self.ctrl_wait == timing.go_every) self.stats.go_resends +%= 1;
                self.send_control(now, &self.go_msg());
                self.ctrl_wait = timing.go_every;
                return;
            }
            // Digest GO: GO and SETUP pages alternate, so a guest that
            // missed the last change of the rules catches up and its next
            // GO matches.
            if (self.turn == 0) {
                if (self.ctrl_wait != timing.ctrl_gap) self.stats.go_resends +%= 1;
                self.send_control(now, &self.go_msg());
            } else self.send_setup(now);
            self.turn ^= 1;
            self.ctrl_wait = timing.go_every / 2;
        }

        /// The GO message of `race` (4 bytes, at most 8 on the wire except
        /// GC's, whose rules byte and race id may each need an escape).
        pub fn go_msg(self: *const Self) [4]u8 {
            const r = &self.race;
            const narrow = (r.picks[0] & 7) | ((r.picks[1] & 7) << 4);
            if (gc_wire) return .{ @backingInt(Msg.go), r.id, r.rules[0], narrow };
            const d = crc8(&r.rules);
            if (pick_bits > 3) return .{ d & 0x7F, r.id, r.picks[0], r.picks[1] };
            const flip: u8 = @intFromBool(slip_special(d));
            return .{ go_digest | flip, r.id, d ^ (flip << 7), narrow };
        }

        /// SETUP page `page` of `offer`: GC's 3-byte SETUP for one rules
        /// byte, else the paged 4-byte one.
        pub fn setup_msg(self: *const Self, page: u8) if (paged) [4]u8 else [3]u8 {
            if (!paged) return .{ @backingInt(Msg.setup), self.race_id, self.offer[0] };
            const at = @as(usize, page) * 2;
            const r0 = self.offer[at];
            const r1 = if (at + 1 < rules_len) self.offer[at + 1] else 0;
            const f0: u8 = @intFromBool(slip_special(r0));
            const f1: u8 = @intFromBool(slip_special(r1));
            return .{ setup_paged | (page << 2) | (f1 << 1) | f0, self.race_id, r0 ^ (f0 << 7), r1 ^ (f1 << 7) };
        }

        fn send_setup(self: *Self, now: u64) void {
            const page = self.page_next;
            self.page_next = if (page + 1 >= pages) 0 else page + 1;
            self.send_control(now, &self.setup_msg(page));
        }

        fn send_lobby(self: *Self, now: u64) void {
            if (self.quit_next) {
                self.quit_next = false;
                self.send_control(now, &.{ @backingInt(Msg.quit), self.race_id });
            } else if (self.role == .host and self.turn == 0) {
                self.send_setup(now);
            } else {
                self.send_control(now, &.{ @backingInt(Msg.pick), self.race_id, self.pick | (@as(u8, @intFromBool(self.ready)) << 7) });
            }
            if (self.role == .host) self.turn ^= 1;
            self.ctrl_wait = timing.lobby_every;
        }

        fn send_inputs(self: *Self, now: u64) void {
            if (self.local_hi < 3) return;
            const newest = self.local_hi - 3;
            var b = newest;
            // A stalled partner lacks a tick we sent (lost packets), at least
            // peer_need. Alternate a window from there with the newest: its
            // own newest tick may be lost too, so peer_need may be low (then
            // our newest ticks are what it lacks, and the newest window also
            // tells it what we lack).
            if (self.peer_need < newest and self.local_hi - self.peer_need < ring_len and
                now -% self.peer_top_at >= timing.peer_stalled)
            {
                self.alt = !self.alt;
                if (self.alt) {
                    b = self.peer_need;
                    self.stats.old_windows +%= 1;
                }
            }
            const n = b + 2;
            const p = encode_input(n, .{
                self.local[n % ring_len],
                self.local[(n - 1) % ring_len],
                self.local[(n - 2) % ring_len],
            }, self.check_byte(n));
            _ = self.link.send(now, &p);
            self.last_tx = now;
            self.dirty = false;
            self.stats.inputs_sent +%= 1;
        }
    };
}
