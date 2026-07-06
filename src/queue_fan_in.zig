const std = @import("std");
const IoBackend = @import("utils.zig").IoBackend;

// Channel contention: `num_producers` tasks all push into a single shared
// queue that one consumer drains. Unlike queue_ping_pong (strictly 1:1,
// uncontended), this pits many producers against the same queue, so it
// measures the queue's internal synchronization under contention — real lock
// contention across executors on --zio-mt / --threaded, and a deep wakeup fan
// on --zio.
const num_producers: u64 = 1000;
const per_producer: u64 = 100;
const total: u64 = num_producers * per_producer;
const buffer_size = 256;

fn producer(io: std.Io, q: *std.Io.Queue(u64)) void {
    var i: u64 = 0;
    while (i < per_producer) : (i += 1) {
        q.putOne(io, 1) catch return;
    }
}

fn consumer(io: std.Io, q: *std.Io.Queue(u64)) void {
    var count: u64 = 0;
    while (count < total) : (count += 1) {
        _ = q.getOne(io) catch return;
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var backend: IoBackend = .none;
    try backend.init(gpa, init.args);
    defer backend.deinit();

    const io = backend.io();

    const start_time: std.Io.Clock.Timestamp = .now(io, .real);

    var buf: [buffer_size]u64 = undefined;
    var q: std.Io.Queue(u64) = .init(&buf);

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    group.async(io, consumer, .{ io, &q });
    var i: u64 = 0;
    while (i < num_producers) : (i += 1) {
        try group.concurrent(io, producer, .{ io, &q });
    }
    try group.await(io);

    const end_time = std.Io.Clock.Timestamp.now(io, .real);
    const duration = start_time.durationTo(end_time);
    const ns = duration.raw.toNanoseconds();
    const rate = if (ns > 0) total * 1_000_000_000 / @as(u64, @intCast(ns)) else 0;
    std.log.info("Duration: {f} ({d} msgs, {d} producers, {d} msgs/s)", .{ duration.raw, total, num_producers, rate });
}
