const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zio_dep = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });
    const zio = zio_dep.module("zio");

    const exe = b.addExecutable(.{
        .name = "hostname_lookup",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hostname_lookup.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zio", .module = zio },
            },
        }),
    });
    b.installArtifact(exe);

    const short_sleep = b.addExecutable(.{
        .name = "short_sleep",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/short_sleep.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zio", .module = zio },
            },
        }),
    });
    b.installArtifact(short_sleep);

    const long_sleep = b.addExecutable(.{
        .name = "long_sleep",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/long_sleep.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zio", .module = zio },
            },
        }),
    });
    b.installArtifact(long_sleep);
}
