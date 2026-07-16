const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const only = b.option([]const u8, "bench", "Build only the named benchmark");
    const backend = b.option([]const u8, "backend", "zio event loop backend (io_uring, epoll, poll, ...)");

    const zio_dep = if (backend) |be| b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
        .backend = be,
    }) else b.dependency("zio", .{
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
        "sleep",
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
        "sleep_native",
    };

    for (benchmarks) |name| {
        if (only) |o| if (!std.mem.eql(u8, name, o)) continue;
        addZigBenchmark(b, target, optimize, zio, name, backend);
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
    backend: ?[]const u8,
) void {
    // Tag the binary with the backend when one is pinned, so io_uring and epoll
    // builds of the same benchmark can coexist (e.g. tcp_server_native_epoll).
    const exe_name = if (backend) |be| b.fmt("{s}_{s}", .{ name, be }) else name;
    const exe = b.addExecutable(.{
        .name = exe_name,
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
