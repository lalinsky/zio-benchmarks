const std = @import("std");
const IoBackend = @import("utils.zig").IoBackend;

// Single-producer -> N-consumer fan-out with CPU work per item, over a
// single-slot channel. The channel is the serialization point: every consumer
// blocks on getOne and is therefore woken *by the producer*, so zio's
// waker-runs-wakee migration drags all consumers onto the producer's executor
// and pins them there. With everyone on one executor the consumers run their
// CPU work serially -> --zio-mt collapses to ~1x, no better than --zio, while
// --threaded / Go spread the consumers across cores. Work stealing is what
// rebalances the piled-up consumer tasks onto idle executors.
//
// The single-slot buffer is load-bearing: a larger buffer lets the producer
// run ahead so consumers may never block, dodging the migration. Checksum must
// match across backends.
const num_consumers: usize = 8;
const num_items: u64 = 512;
const per_item_iters: u64 = 2_000_000;
const buffer_size = 1;

fn work(seed: u64, iters: u64) u64 {
    var x: u64 = seed;
    var acc: u64 = 0;
    var i: u64 = 0;
    while (i < iters) : (i += 1) {
        x = x *% 6364136223846793005 +% 1442695040888963407;
        acc ^= x >> 29;
    }
    return acc;
}

fn producer(io: std.Io, q: *std.Io.Queue(u64)) void {
    var i: u64 = 0;
    while (i < num_items) : (i += 1) {
        q.putOne(io, i + 1) catch return;
    }
    q.close(io);
}

fn consumer(io: std.Io, q: *std.Io.Queue(u64), result: *u64) void {
    var acc: u64 = 0;
    while (true) {
        const item = q.getOne(io) catch break; // error.Closed when drained
        acc ^= work(item, per_item_iters);
    }
    result.* = acc;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var backend: IoBackend = .none;
    try backend.init(gpa, init.args);
    defer backend.deinit();

    const io = backend.io();

    var results: [num_consumers]u64 = @splat(0);
    var buf: [buffer_size]u64 = undefined;
    var q: std.Io.Queue(u64) = .init(&buf);

    const start_time: std.Io.Clock.Timestamp = .now(io, .real);

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    for (0..num_consumers) |idx| {
        try group.concurrent(io, consumer, .{ io, &q, &results[idx] });
    }
    try group.concurrent(io, producer, .{ io, &q });
    try group.await(io);

    var checksum: u64 = 0;
    for (results) |r| checksum ^= r;

    const end_time = std.Io.Clock.Timestamp.now(io, .real);
    const duration = start_time.durationTo(end_time);
    std.log.info("Duration: {f} ({d} items x {d} iters, {d} consumers, checksum={x})", .{ duration.raw, num_items, per_item_iters, num_consumers, checksum });
}
