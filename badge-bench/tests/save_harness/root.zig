//! badge-bench tests/test_saves.py: lib/save.zig's badge backend (the real
//! raw-mailbox client) behind C-ABI exports, run under unicorn against the
//! bench's save service. Error results are `code(e)` (0 = ok).
const save = @import("save");

comptime {
    if (save.backend != .badge) @compileError("build for thumb-freestanding (the badge backend)");
}

fn code(e: save.Error) u32 {
    return switch (e) {
        error.Unsupported => 1,
        error.NotFound => 2,
        error.NoSpace => 3,
        error.BadRequest => 4,
        error.BadBuffer => 5,
        error.RateLimited => 6,
        error.TooBig => 7,
        error.IoError => 8,
        error.Busy => 9,
    };
}

export fn h_supported() u32 {
    return @intFromBool(save.supported());
}

export fn h_read(key: [*]const u8, key_len: u32, dst: [*]u8, len: u32, size: *u32) u32 {
    size.* = @intCast(save.read(key[0..key_len], dst[0..len]) catch |e| return code(e));
    return 0;
}

export fn h_write(key: [*]const u8, key_len: u32, src: [*]const u8, len: u32) u32 {
    save.write(key[0..key_len], src[0..len]) catch |e| return code(e);
    return 0;
}

export fn h_delete(key: [*]const u8, key_len: u32) u32 {
    save.delete(key[0..key_len]) catch |e| return code(e);
    return 0;
}

export fn h_stat(out: *save.Stat) u32 {
    out.* = save.stat() catch |e| return code(e);
    return 0;
}

export fn h_list(out: [*]save.ListEntry, n: u32, count: *u32) u32 {
    count.* = @intCast(save.list(out[0..n]) catch |e| return code(e));
    return 0;
}

export fn h_watch_exit() u32 {
    save.watchExit() catch |e| return code(e);
    return 0;
}

export fn h_exit_requested() u32 {
    return @intFromBool(save.exitRequested());
}

export fn h_exit_ready() void {
    save.exitReady();
}
