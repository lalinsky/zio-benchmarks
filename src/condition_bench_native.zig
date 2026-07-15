const std = @import("std");
const zio = @import("zio");

// Condvar ping-pong on zio's native Mutex/Condition: two workers alternate
// turns, 100k rounds each direction.
// --zio (default): tasks on a single-threaded runtime
// --zio-mt: tasks on a multi-threaded runtime
// --threads: plain OS threads, no runtime (foreign-waiter path)
const rounds = 100_000;

const Shared = struct {
    mutex: zio.Mutex = .init,
    cond: zio.Condition = .init,
    turn: u32 = 0,
};

fn taskPlayer(s: *Shared, me: u32) !void {
    for (0..rounds) |_| {
        try s.mutex.lock();
        while (s.turn != me) try s.cond.wait(&s.mutex);
        s.turn = 1 - me;
        s.mutex.unlock();
        s.cond.signal();
    }
}

fn threadPlayer(s: *Shared, me: u32) void {
    for (0..rounds) |_| {
        s.mutex.lockUncancelable();
        while (s.turn != me) s.cond.waitUncancelable(&s.mutex);
        s.turn = 1 - me;
        s.mutex.unlock();
        s.cond.signal();
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var mt = false;
    var threads = false;
    var iter = init.args.iterate();
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--zio-mt")) mt = true;
        if (std.mem.eql(u8, arg, "--threads")) threads = true;
    }

    var s: Shared = .{};
    const start = zio.Timestamp.now(.monotonic);

    if (threads) {
        var a = try std.Thread.spawn(.{}, threadPlayer, .{ &s, 0 });
        var b = try std.Thread.spawn(.{}, threadPlayer, .{ &s, 1 });
        a.join();
        b.join();
    } else {
        const rt = try zio.Runtime.init(gpa, if (mt) .{ .executors = .auto } else .{});
        defer rt.deinit();

        var group: zio.Group = .init;
        defer group.cancel();
        try group.spawn(taskPlayer, .{ &s, 0 });
        try group.spawn(taskPlayer, .{ &s, 1 });
        try group.wait();
    }

    const ns: u64 = @intCast(start.durationTo(zio.Timestamp.now(.monotonic)).toNanoseconds());
    const mode = if (threads) "threads" else if (mt) "zio-mt" else "zio";
    std.log.info("Duration: {d:.3}ms ({s}, {d} signals, {d} signals/s)", .{ @as(f64, @floatFromInt(ns)) / 1e6, mode, rounds * 2, @as(u64, rounds * 2) * 1_000_000_000 / ns });
}
