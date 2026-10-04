//! The roster (SPEC 4.1, 4.2): names, cars, chassis and placeholder
//! liveries in SPEC order. M0 keeps only what driving needs; M1 adds the
//! loadouts, bios, taunts and the crew characters (SPEC 4.3). No cart API.
const tuning = @import("tuning.zig");

pub const snouty: u8 = 0;
pub const legacy: u8 = 1;
pub const kiddie: u8 = 2;
pub const sysadmin: u8 = 3;
pub const rootkit: u8 = 4;
pub const botnet: u8 = 5;
pub const count = 6;

pub const ChassisKind = enum(u8) { thin_client, workstation, mainframe };

pub const Racer = struct {
    name: []const u8,
    car: []const u8,
    chassis: ChassisKind,
    /// Placeholder livery base colour (0xRRGGBB): Zero's machine sprite is
    /// re-paletted with it, and it is the minimap dot. The art track's own
    /// car sheets replace the sprite in M1.
    livery: u32,
};

pub const roster = [count]Racer{
    .{ .name = "SNOUTY", .car = "ANTEATER", .chassis = .workstation, .livery = 0x9A50E8 },
    .{ .name = "LEGACY", .car = "BIG IRON", .chassis = .mainframe, .livery = 0xD86A30 },
    .{ .name = "KIDDIE", .car = "CTRL-V", .chassis = .thin_client, .livery = 0xF04890 },
    .{ .name = "SYSADMIN", .car = "UPTIME", .chassis = .workstation, .livery = 0x40D070 },
    .{ .name = "ROOTKIT", .car = "PERSIST", .chassis = .thin_client, .livery = 0x4A5868 },
    .{ .name = "BOTNET", .car = "ZOMBIE", .chassis = .mainframe, .livery = 0xF0C030 },
};

pub fn chassis(kind: ChassisKind) tuning.Chassis {
    return switch (kind) {
        .thin_client => tuning.thin_client,
        .workstation => tuning.workstation,
        .mainframe => tuning.mainframe,
    };
}

pub fn chassis_of(racer: u8) tuning.Chassis {
    return chassis(roster[racer % count].chassis);
}
