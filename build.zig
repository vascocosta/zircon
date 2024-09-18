const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = b.addModule("zircon", .{
        .root_source_file = b.path("src/zircon.zig"),
        .target = target,
        .optimize = optimize,
    });
}
