const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zircon_mod = b.addModule("zircon", .{
        .root_source_file = b.path("src/zircon.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tls = b.dependency("tls", .{
        .target = target,
        .optimize = optimize,
    });

    zircon_mod.addImport("tls", tls.module("tls"));
}
