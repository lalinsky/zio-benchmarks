const std = @import("std");
const zio = @import("zio");

// Pure context-switch benchmark: two tasks on a single-threaded runtime, each
// yielding 1M times. Nothing blocks, so this measures scheduler switch cost
// alone (photon counterpart: cpp/yield_bench_photon.cpp). With --solo a single
// task yields alone, exercising the empty-queue yield fast path.

const iterations: u64 = 1_000_000;

fn yielder() zio.Cancelable!void {
    for (0..iterations) |_| {
        try zio.yield();
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var solo = false;
    var iter = init.args.iterate();
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--solo")) solo = true;
    }
    const num_tasks: u64 = if (solo) 1 else 2;

    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();

    const start_time = zio.Timestamp.now(.monotonic);

    var group: zio.Group = .init;
    defer group.cancel();

    for (0..num_tasks) |_| {
        try group.spawn(yielder, .{});
    }
    try group.wait();

    const duration = start_time.untilNow(.monotonic);
    const ns = duration.toNanoseconds();
    const yields = num_tasks * iterations;
    std.log.info("Duration: {f} ({d} yields, {d:.1}ns/yield)", .{
        duration,
        yields,
        @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(yields)),
    });
}
