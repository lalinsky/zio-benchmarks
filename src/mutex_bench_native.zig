const std = @import("std");
const zio = @import("zio");

// Contended counter on zio's native Mutex: 4 workers x 100k lock/inc/unlock.
// --zio (default): tasks on a single-threaded runtime
// --zio-mt: tasks on a multi-threaded runtime
// --threads: plain OS threads, no runtime (foreign-waiter path)
const num_workers = 4;
const iterations = 100_000;

fn taskWorker(m: *zio.Mutex, counter: *u64) !void {
    for (0..iterations) |_| {
        try m.lock();
        counter.* += 1;
        m.unlock();
    }
}

fn threadWorker(m: *zio.Mutex, counter: *u64) void {
    for (0..iterations) |_| {
        m.lockUncancelable();
        counter.* += 1;
        m.unlock();
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var mt = false;
    var threads = false;
    var exact: ?u8 = null;
    var iter = init.args.iterate();
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--zio-mt")) mt = true;
        if (std.mem.eql(u8, arg, "--threads")) threads = true;
        if (std.mem.startsWith(u8, arg, "--exact=")) {
            exact = std.fmt.parseInt(u8, arg["--exact=".len..], 10) catch null;
            mt = true;
        }
    }

    var m: zio.Mutex = .init;
    var counter: u64 = 0;

    const start = zio.Timestamp.now(.monotonic);

    if (threads) {
        var handles: [num_workers]std.Thread = undefined;
        for (&handles) |*h| h.* = try std.Thread.spawn(.{}, threadWorker, .{ &m, &counter });
        for (handles) |h| h.join();
    } else {
        const opts: zio.RuntimeOptions = if (exact) |n| .{ .executors = .exact(n) } else if (mt) .{ .executors = .auto } else .{};
        const rt = try zio.Runtime.init(gpa, opts);
        defer rt.deinit();

        var group: zio.Group = .init;
        defer group.cancel();
        for (0..num_workers) |_| try group.spawn(taskWorker, .{ &m, &counter });
        try group.wait();
    }

    const ns: u64 = @intCast(start.durationTo(zio.Timestamp.now(.monotonic)).toNanoseconds());
    if (counter != num_workers * iterations) return error.BadCount;
    const mode = if (threads) "threads" else if (mt) "zio-mt" else "zio";
    std.log.info("Duration: {d:.3}ms ({s}, {d} locks, {d} locks/s)", .{ @as(f64, @floatFromInt(ns)) / 1e6, mode, counter, counter * 1_000_000_000 / ns });
}
