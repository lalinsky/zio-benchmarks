const std = @import("std");
const zio = @import("zio");

// RwLock churn on zio's native RwLock.
// default: 8 readers x 20k, 1 writer x 2k (mixed, exercises blocking/wakeups)
// --pure: readers only (uncontended fast path)
// --zio-mt: multi-threaded runtime
const num_readers = 8;
const reader_iters = 20_000;
const writer_iters = 2_000;

var shared: u64 = 0;

fn reader(rw: *zio.RwLock, sink: *std.atomic.Value(u64)) !void {
    var local: u64 = 0;
    for (0..reader_iters) |_| {
        try rw.lockShared();
        local +%= shared;
        rw.unlockShared();
    }
    _ = sink.fetchAdd(local, .monotonic);
}

fn writer(rw: *zio.RwLock) !void {
    for (0..writer_iters) |_| {
        try rw.lock();
        shared += 1;
        rw.unlock();
        try zio.yield();
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var mt = false;
    var pure = false;
    var iter = init.args.iterate();
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--zio-mt")) mt = true;
        if (std.mem.eql(u8, arg, "--pure")) pure = true;
    }

    const rt = try zio.Runtime.init(gpa, if (mt) .{ .executors = .auto } else .{});
    defer rt.deinit();

    var rw: zio.RwLock = .init;
    var sink = std.atomic.Value(u64).init(0);

    const start = zio.Timestamp.now(.monotonic);

    var group: zio.Group = .init;
    defer group.cancel();
    for (0..num_readers) |_| try group.spawn(reader, .{ &rw, &sink });
    if (!pure) try group.spawn(writer, .{&rw});
    try group.wait();

    const ns: u64 = @intCast(start.durationTo(zio.Timestamp.now(.monotonic)).toNanoseconds());
    const total: u64 = num_readers * reader_iters;
    const mode = if (pure) "pure" else "mixed";
    std.log.info("Duration: {d:.3}ms ({s}, {d} read locks, {d} locks/s)", .{ @as(f64, @floatFromInt(ns)) / 1e6, mode, total, total * 1_000_000_000 / ns });
}
