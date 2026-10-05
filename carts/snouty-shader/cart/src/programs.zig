//! The gallery (SPEC.md section 2): each program renders the 80x64 surface
//! from the uniforms and a cosine palette. `init` builds a program's
//! tables once at start(); `enter` resets its state when it is selected.
const palette = @import("palette.zig");
const surface = @import("surface.zig");
const U = @import("uniforms.zig").U;

pub const Program = struct {
    name: []const u8,
    param_name: []const u8,
    default_palette: u8,
    init: *const fn () void,
    enter: *const fn () void,
    render: *const fn (u: *const U, pal: *const palette.Cosine, out: *surface.Surface) void,
};

fn entry(comptime m: type) Program {
    return .{
        .name = m.name,
        .param_name = m.param_name,
        .default_palette = m.default_palette,
        .init = &m.init,
        .enter = &m.enter,
        .render = &m.render,
    };
}

pub const list = [_]Program{
    entry(@import("programs/ink.zig")),
    entry(@import("programs/ripple.zig")),
    entry(@import("programs/lava.zig")),
    entry(@import("programs/echo.zig")),
    entry(@import("programs/cells.zig")),
    entry(@import("programs/kaleido.zig")),
};

pub const count = list.len;

pub fn init_all() void {
    for (&list) |*p| p.init();
}
