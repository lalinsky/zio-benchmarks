const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zio_dep = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });
    const zio = zio_dep.module("zio");

    const benchmarks = [_][]const u8{
        "hostname_lookup",
        "short_sleep",
        "long_sleep",
        "queue_ping_pong",
        "tcp_ping_pong",
        "tcp_echo",
        "queue_fan_in",
        "cpu_parallel",
    };

    // Zig-only benchmarks that use zio's native API and have no Go / std.Io
    // counterpart. They only build a zig executable (no matching _go binary).
    const zig_only_benchmarks = [_][]const u8{
        "queue_ping_pong_native",
        "queue_ping_pong_futex",
        "task_chain",
        "spawn_tree",
        "fanout_cpu",
    };

    for (benchmarks) |name| {
        addZigBenchmark(b, target, optimize, zio, name);

        const go_cmd = b.addSystemCommand(&.{ "go", "build", "-o" });
        go_cmd.setCwd(b.path("go"));
        const go_out = go_cmd.addOutputFileArg(b.fmt("{s}_go", .{name}));
        go_cmd.addArg(b.fmt("./{s}", .{name}));
        b.getInstallStep().dependOn(&b.addInstallFile(go_out, b.fmt("bin/{s}_go", .{name})).step);
    }

    for (zig_only_benchmarks) |name| {
        addZigBenchmark(b, target, optimize, zio, name);
    }
}

fn addZigBenchmark(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zio: *std.Build.Module,
    name: []const u8,
) void {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zio", .module = zio },
            },
        }),
    });
    b.installArtifact(exe);
}
