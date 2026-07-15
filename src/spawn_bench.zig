const std = @import("std");
const zio = @import("zio");

// Spawn cost benchmark: 100k no-op tasks on a single-threaded runtime, wait
// for all of them (photon counterpart: cpp/spawn_bench_photon.cpp).

const num_tasks: u64 = 100_000;

fn task() void {}

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();

    const start_time = zio.Timestamp.now(.monotonic);

    var group: zio.Group = .init;
    defer group.cancel();

    for (0..num_tasks) |_| {
        try group.spawn(task, .{});
    }
    try group.wait();

    const duration = start_time.untilNow(.monotonic);
    const ns = duration.toNanoseconds();
    std.log.info("Duration: {f} ({d} spawns, {d:.0}ns/spawn)", .{
        duration,
        num_tasks,
        @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(num_tasks)),
    });
}
