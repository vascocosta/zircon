const std = @import("std");
const builtin = @import("builtin");

pub inline fn debug(comptime fmt: []const u8, args: anytype) void {
    if (builtin.mode == .Debug) {
        std.debug.print(fmt, args);
    }
}
