const std = @import("std");
const xsync = @import("xsync");
const IoBackend = @import("utils.zig").IoBackend;

// Condvar ping-pong: two tasks alternate turns through one mutex/condition
// pair. Compares std.Io (default) with xsync (--xsync).
const rounds = 100_000;

fn Bench(comptime Mutex: type, comptime Condition: type) type {
    return struct {
        const Shared = struct {
            mutex: Mutex = .init,
            cond: Condition = .init,
            turn: u32 = 0,
        };

        fn player(io: std.Io, s: *Shared, me: u32) std.Io.Cancelable!void {
            for (0..rounds) |_| {
                try s.mutex.lock(io);
                while (s.turn != me) try s.cond.wait(io, &s.mutex);
                s.turn = 1 - me;
                s.mutex.unlock(io);
                s.cond.signal(io);
            }
        }

        fn run(io: std.Io) !void {
            var s: Shared = .{};

            var group: std.Io.Group = .init;
            defer group.cancel(io);
            try group.concurrent(io, player, .{ io, &s, 0 });
            try group.concurrent(io, player, .{ io, &s, 1 });
            try group.await(io);
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
        try Bench(xsync.Mutex, xsync.Condition).run(io);
    } else {
        try Bench(std.Io.Mutex, std.Io.Condition).run(io);
    }

    const duration = start.durationTo(.now(io, .real));
    const ns = duration.raw.toNanoseconds();
    const rate = if (ns > 0) rounds * 2 * 1_000_000_000 / @as(u64, @intCast(ns)) else 0;
    std.log.info("Duration: {f} ({s}, {d} signals, {d} signals/s)", .{ duration.raw, if (use_xsync) "xsync" else "std", rounds * 2, rate });
}
