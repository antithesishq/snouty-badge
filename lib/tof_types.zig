//! What carts see of the TMF8820 time-of-flight sensor (docs/TOF.md).
//! Shared by lib/tof.zig (the driver), lib/tof_virtual.zig (the model)
//! and the carts; plain data, no hardware.

/// The 8820 measures a 3x3 grid of zones.
pub const zones = 9;
/// Histogram channels: 0 is the reference SPAD, 1..9 the zones.
pub const hist_channels = 10;
pub const hist_bins = 128;

/// One detected object in a zone. `confidence` 0 means nothing was
/// detected and `mm` is meaningless.
pub const Target = struct {
    mm: u16 = 0,
    confidence: u8 = 0,

    pub fn valid(t: Target) bool {
        return t.confidence != 0;
    }
};

/// A zone's closest object and, if the device saw one, the next.
pub const Zone = struct {
    near: Target = .{},
    far: Target = .{},
};

/// One measurement. `zones` is in the device's order (datasheet zones
/// 1..9 as indices 0..8, row-major as the datasheet draws them); carts
/// map it to the screen with `Orientation.index`.
pub const Frame = struct {
    /// The device's result number; increases by one per measurement
    /// (wraps at 256 on the device, widened here).
    seq: u32 = 0,
    /// `micros_since_boot` when the driver finished reading it.
    time_us: u64 = 0,
    zones: [zones]Zone = @splat(.{}),
    temperature_c: i8 = 0,
    ambient: u32 = 0,
    photons: u32 = 0,
    ref_photons: u32 = 0,
};

/// The raw photon histograms that came with frame `seq`, when histogram
/// dumps are on. Bin counts are the device's 24-bit values.
pub const Histograms = struct {
    seq: u32 = 0,
    bins: [hist_channels][hist_bins]u32 = @splat(@splat(0)),
};

/// How the breakout faces on the badge: the grid as the user should see
/// it on screen, from the device's zone order.
pub const Orientation = struct {
    flip_x: bool = false,
    flip_y: bool = false,
    /// Transpose (applied before the flips): a quarter turn with one flip.
    transpose: bool = false,

    /// The device zone index (0..8) to show at screen cell (col, row).
    pub fn index(o: Orientation, col: u2, row: u2) u4 {
        var c: u4 = col;
        var r: u4 = row;
        if (o.transpose) {
            const t = c;
            c = r;
            r = t;
        }
        if (o.flip_x) c = 2 - c;
        if (o.flip_y) r = 2 - r;
        return r * 3 + c;
    }
};
