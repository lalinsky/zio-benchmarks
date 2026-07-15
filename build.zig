const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zio_dep = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });
    const zio = zio_dep.module("zio");

    const xsync_dep = b.dependency("xsync", .{
        .target = target,
        .optimize = optimize,
    });
    const xsync = xsync_dep.module("xsync");

    const benchmarks = [_][]const u8{
        "hostname_lookup",
        "short_sleep",
        "long_sleep",
        "queue_ping_pong",
        "tcp_ping_pong",
        "tcp_echo",
        "queue_fan_in",
        "worker_pool",
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
        "zio_echo_server",
        "condition_bench_native",
        "rwlock_bench_native",
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

    // Variants that swap std.Io.Queue for xsync.Queue (same generic queue,
    // built on xsync's cross-Io Mutex/Condition instead of std's).
    const xsync_benchmarks = [_][]const u8{
        "queue_ping_pong_xsync",
        "mutex_bench",
        "condition_bench",
        "mutex_bench_native",
        "queue_fan_in_xsync",
        "worker_pool_xsync",
    };
    for (xsync_benchmarks) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zio", .module = zio },
                    .{ .name = "xsync", .module = xsync },
                },
            }),
        });
        b.installArtifact(exe);
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
