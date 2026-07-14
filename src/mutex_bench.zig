const std = @import("std");
const xsync = @import("xsync");
const IoBackend = @import("utils.zig").IoBackend;

// Contended counter: `num_workers` tasks each do `iterations` lock/inc/unlock
// rounds on one shared mutex. Compares std.Io.Mutex (default) with
// xsync.Mutex (--xsync).
const num_workers = 4;
const iterations = 100_000;

fn Bench(comptime Mutex: type) type {
    return struct {
        fn worker(io: std.Io, m: *Mutex, counter: *u64) std.Io.Cancelable!void {
            for (0..iterations) |_| {
                try m.lock(io);
                counter.* += 1;
                m.unlock(io);
            }
        }

        fn run(io: std.Io) !void {
            var m: Mutex = .init;
            var counter: u64 = 0;

            var group: std.Io.Group = .init;
            defer group.cancel(io);
            for (0..num_workers) |_| {
                try group.concurrent(io, worker, .{ io, &m, &counter });
            }
            try group.await(io);

            if (counter != num_workers * iterations) return error.BadCount;
        }
    };
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var backend: IoBackend = .none;
    try backend.init(gpa, init.args);
    defer backend.deinit();

    var use_xsync = false;
    var iter = init.args.iterate();
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--xsync")) use_xsync = true;
    }

    const io = backend.io();
    const start: std.Io.Clock.Timestamp = .now(io, .real);

    if (use_xsync) {
        try Bench(xsync.Mutex).run(io);
    } else {
        try Bench(std.Io.Mutex).run(io);
    }

    const duration = start.durationTo(.now(io, .real));
    const ns = duration.raw.toNanoseconds();
    const total: u64 = num_workers * iterations;
    const rate = if (ns > 0) total * 1_000_000_000 / @as(u64, @intCast(ns)) else 0;
    std.log.info("Duration: {f} ({s}, {d} locks, {d} locks/s)", .{ duration.raw, if (use_xsync) "xsync" else "std", total, rate });
}
