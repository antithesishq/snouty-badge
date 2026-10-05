//! lib/save.zig through its host backend (the fake OS store).
const std = @import("std");
const save = @import("../save.zig");
const fake = save.fake;

test "save: host backend is the fake" {
    try std.testing.expectEqual(save.Backend.fake, save.backend);
}

test "save: abi word and struct layout" {
    try std.testing.expectEqual(@as(u32, 0x2C00D454), save.abi.word(0x20035150));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(save.abi.Request));
    try std.testing.expectEqual(@as(usize, 0x34), @offsetOf(save.abi.Request, "buf"));
    try std.testing.expectEqual(@as(usize, 0x3C), @offsetOf(save.abi.Request, "result"));
}

test "save: round trip, short and long reads" {
    fake.reset();
    try std.testing.expect(save.supported());
    try save.write("test/slot", "hello world");
    var big: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 11), try save.read("test/slot", &big));
    try std.testing.expectEqualStrings("hello world", big[0..11]);
    var small: [5]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 11), try save.read("test/slot", &small));
    try std.testing.expectEqualStrings("hello", &small);
    try std.testing.expectEqual(@as(usize, 11), try save.read("test/slot", &.{}));
    try std.testing.expectError(error.NotFound, save.read("test/other", &big));
}

test "save: overwrite, delete" {
    fake.reset();
    try save.write("a", "one");
    try save.write("a", "two!");
    var b: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try save.read("a", &b));
    try std.testing.expectEqualStrings("two!", b[0..4]);
    try save.delete("a");
    try std.testing.expectError(error.NotFound, save.read("a", &b));
    try std.testing.expectError(error.NotFound, save.delete("a"));
    try std.testing.expectEqual(@as(u32, 3), fake.commits());
    // two 1-block writes (2 x 110 ms) and a delete (55 ms)
    try std.testing.expectEqual(@as(u64, 275), fake.flashMs());
}

test "save: unchanged write is free and takes no token" {
    fake.reset();
    try save.write("k", "same");
    for (0..50) |_| try save.write("k", "same");
    try std.testing.expectEqual(@as(u32, 1), fake.commits());
    try std.testing.expectEqual(@as(u32, 7), (try save.stat()).writes_left_now);
}

test "save: argument checks" {
    fake.reset();
    try std.testing.expectError(error.BadRequest, save.write("", "x"));
    try std.testing.expectError(error.BadRequest, save.write("123456789012345678901234567890123", "x"));
    try std.testing.expectError(error.BadRequest, save.write("tab\there", "x"));
    try std.testing.expectError(error.BadRequest, save.write("k", ""));
    var huge: [save.max_blob + 1]u8 = undefined;
    try std.testing.expectError(error.TooBig, save.write("k", &huge));
    try save.write("12345678901234567890123456789012", huge[0..save.max_blob]);
    try std.testing.expectEqual(@as(u32, 1), fake.commits());
}

test "save: unsupported (stock firmware)" {
    fake.reset();
    fake.setSupported(false);
    try std.testing.expect(!save.supported());
    var b: [4]u8 = undefined;
    try std.testing.expectError(error.Unsupported, save.read("k", &b));
    try std.testing.expectError(error.Unsupported, save.write("k", "v"));
    try std.testing.expectError(error.Unsupported, save.delete("k"));
    try std.testing.expectError(error.Unsupported, save.stat());
    try std.testing.expectError(error.Unsupported, save.watchExit());
    try std.testing.expect(!save.exitRequested());
    save.exitReady();
}

test "save: rate limit refills one token per 10 s" {
    fake.reset();
    var buf: [1]u8 = undefined;
    for (0..8) |i| {
        buf[0] = @intCast(i);
        try save.write("r", &buf);
    }
    buf[0] = 99;
    try std.testing.expectError(error.RateLimited, save.write("r", &buf));
    try std.testing.expectError(error.RateLimited, save.delete("r"));
    fake.advanceMs(9_999);
    try std.testing.expectError(error.RateLimited, save.write("r", &buf));
    fake.advanceMs(1);
    try save.write("r", &buf);
    try std.testing.expectError(error.RateLimited, save.write("r", "zz"));
    fake.advanceMs(1_000_000);
    try std.testing.expectEqual(@as(u32, 8), (try save.stat()).writes_left_now);
    fake.setRateLimit(false);
    for (0..20) |i| {
        buf[0] = @intCast(i);
        try save.write("r", &buf);
    }
}

test "save: space accounting is copy-on-write" {
    fake.reset();
    fake.setRateLimit(false);
    var blob: [save.max_blob]u8 = @splat(0xA5);
    const s0 = try save.stat();
    try std.testing.expectEqual(@as(u32, 62 * 4096), s0.free_bytes);
    try std.testing.expectEqual(@as(u32, 64 * 4096), s0.region_bytes);
    try std.testing.expectEqual(@as(u32, 1), s0.version);
    // 3 x 16 blocks = 48 of 62; 14 left.
    try save.write("b0", &blob);
    try save.write("b1", &blob);
    try save.write("b2", &blob);
    try std.testing.expectEqual(@as(u32, 14 * 4096), (try save.stat()).free_bytes);
    // Rewriting a 16-block blob needs 16 free blocks while the old copy exists.
    blob[0] = 1;
    try std.testing.expectError(error.NoSpace, save.write("b0", &blob));
    // 14 blocks fit, and the old 16 come back afterwards.
    try save.write("b0", blob[0 .. 14 * 4096]);
    try std.testing.expectEqual(@as(u32, 16 * 4096), (try save.stat()).free_bytes);
    var out: [save.max_blob]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 14 * 4096), try save.read("b0", &out));
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    try std.testing.expectEqual(@as(u8, 0xA5), out[14 * 4096 - 1]);
    try std.testing.expectEqual(@as(usize, save.max_blob), try save.read("b1", &out));
    try std.testing.expect(std.mem.allEqual(u8, &out, 0xA5));
}

test "save: 62 one-block keys fill the store (the 63-key limit is unreachable)" {
    fake.reset();
    fake.setRateLimit(false);
    var key: [8]u8 = undefined;
    for (0..63) |i| {
        const k = std.fmt.bufPrint(&key, "k/{d}", .{i}) catch unreachable;
        save.write(k, "x") catch |e| {
            // 62 data blocks: the 63rd one-block key has no block left.
            try std.testing.expectEqual(@as(usize, 62), i);
            try std.testing.expectEqual(error.NoSpace, e);
            break;
        };
    }
    try std.testing.expectEqual(@as(u32, 62), (try save.stat()).entries);
    try std.testing.expectEqual(@as(u32, 0), (try save.stat()).free_bytes);
    try std.testing.expectError(error.NoSpace, save.write("k/new", "y"));
}

test "save: list" {
    fake.reset();
    try save.write("boy/TETRIS/1234", "abc");
    try save.write("paperclips/game", "defg");
    var rows: [1]save.ListEntry = undefined;
    try std.testing.expectEqual(@as(usize, 2), try save.list(&rows));
    try std.testing.expectEqualStrings("boy/TETRIS/1234", rows[0].name());
    try std.testing.expectEqual(@as(u32, 3), rows[0].size);
    var all: [4]save.ListEntry = undefined;
    try std.testing.expectEqual(@as(usize, 2), try save.list(&all));
    try std.testing.expectEqualStrings("paperclips/game", all[1].name());
}

test "save: exit hook" {
    fake.reset();
    try std.testing.expect(!save.exitRequested());
    fake.setExitRequested(); // not watched: nothing
    try std.testing.expect(!save.exitRequested());
    try save.watchExit();
    try std.testing.expect(fake.exitWatched());
    try std.testing.expect(!save.exitRequested());
    fake.setExitRequested();
    try std.testing.expect(save.exitRequested());
    try std.testing.expectEqual(@as(u32, 1), fake.exitWord());
    save.exitReady();
    try std.testing.expectEqual(@as(u32, 2), fake.exitWord());
    try std.testing.expect(save.exitRequested());
}

test "save: reboot keeps blobs, injected failures" {
    fake.reset();
    try save.write("p", "persist");
    try save.watchExit();
    fake.reboot();
    try std.testing.expect(!fake.exitWatched());
    var b: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 7), try save.read("p", &b));
    fake.failNext(error.IoError);
    try std.testing.expectError(error.IoError, save.read("p", &b));
    try std.testing.expectEqual(@as(usize, 7), try save.read("p", &b));
    var peek: [3]u8 = undefined;
    try std.testing.expectEqualStrings("per", fake.peek("p", &peek).?);
    try std.testing.expect(fake.peek("q", &peek) == null);
}
