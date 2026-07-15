const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const only = b.option([]const u8, "bench", "Build only the named benchmark");

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

    // Go counterparts build separately with ./build_go.sh.
    const benchmarks = [_][]const u8{
        "sleep_bench",
        "queue_ping_pong",
        "tcp_server",
        "worker_pool",
        "cpu_parallel",
        "queue_ping_pong_native",
        "queue_ping_pong_futex",
        "task_chain",
        "spawn_tree",
        "fanout_cpu",
        "tcp_server_native",
        "condition_bench_native",
        "rwlock_bench_native",
        "worker_pool_native",
        "yield_bench",
        "spawn_bench",
    };

    for (benchmarks) |name| {
        if (only) |o| if (!std.mem.eql(u8, name, o)) continue;
        addZigBenchmark(b, target, optimize, zio, name);
    }

    // Variants that swap std.Io.Queue for xsync.Queue (same generic queue,
    // built on xsync's cross-Io Mutex/Condition instead of std's).
    const xsync_benchmarks = [_][]const u8{
        "queue_ping_pong_xsync",
        "mutex_bench",
        "condition_bench",
        "mutex_bench_native",
        "worker_pool_xsync",
    };
    for (xsync_benchmarks) |name| {
        if (only) |o| if (!std.mem.eql(u8, name, o)) continue;
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
