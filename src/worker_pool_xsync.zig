const std = @import("std");
const xsync = @import("xsync");
const IoBackend = @import("utils.zig").IoBackend;

// Generic worker-pool benchmark: `--num-producers` tasks push `--num-items`
// values (split evenly) into one shared queue, `--num-consumers` workers race
// to drain it, each doing `--work` iterations of a data-dependent hash
// recurrence per item. Covers the whole fan spectrum with one binary:
//
//   defaults                            fan-out worker pool (1 -> 1000)
//   --num-producers=1000 --num-consumers=1   queue_fan_in shape
//   --num-consumers=8 --work=2000000         fanout_cpu shape
//
// With the default tiny per-item work (~50ns) the queue is the serialization
// point, so this measures queue + scheduler overhead: wakeup distribution,
// wake/steal churn, and task migration ping-pong. Cranking --work up shifts it
// toward a real parallel workload. The xor checksum is order-independent and
// must match across backends.
const buffer_size = 256;

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

fn producer(io: std.Io, q: *xsync.Queue(u64), start: u64, end: u64, remaining: *std.atomic.Value(u64)) void {
    var i: u64 = start;
    while (i < end) : (i += 1) {
        q.putOne(io, i + 1) catch return;
    }
    // Last producer out closes the queue so the consumers drain and exit.
    if (remaining.fetchSub(1, .acq_rel) == 1) q.close(io);
}

fn consumer(io: std.Io, q: *xsync.Queue(u64), work_iters: u64, result: *u64) void {
    var acc: u64 = 0;
    while (true) {
        const item = q.getOne(io) catch break; // error.Closed when drained
        acc ^= work(item, work_iters);
    }
    result.* = acc;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const args = try init.args.toSlice(arena_state.allocator());

    var num_items: u64 = 100_000;
    var num_producers: u64 = 1;
    var num_consumers: u64 = 1000;
    var work_iters: u64 = 64;

    var iarg: usize = 1;
    while (iarg < args.len) : (iarg += 1) {
        const arg = args[iarg];
        if (std.mem.eql(u8, arg, "--zio") or std.mem.eql(u8, arg, "--zio-mt") or std.mem.eql(u8, arg, "--threaded")) {
            continue; // io backend selection, handled by IoBackend below
        }
        const split_pos = std.mem.findScalar(u8, arg, '=') orelse arg.len;
        const key = arg[0..split_pos];
        const target: *u64 = if (std.mem.eql(u8, key, "--num-items"))
            &num_items
        else if (std.mem.eql(u8, key, "--num-producers"))
            &num_producers
        else if (std.mem.eql(u8, key, "--num-consumers"))
            &num_consumers
        else if (std.mem.eql(u8, key, "--work"))
            &work_iters
        else {
            std.log.err("unknown argument '{s}'", .{arg});
            std.log.err("usage: worker_pool [--zio | --zio-mt | --threaded] [--num-items=N] [--num-producers=N] [--num-consumers=N] [--work=N]", .{});
            std.process.exit(1);
        };
        const value = if (split_pos < arg.len) arg[split_pos + 1 ..] else blk: {
            iarg += 1;
            if (iarg >= args.len) {
                std.log.err("expected a value after {s}", .{key});
                std.process.exit(2);
            }
            break :blk args[iarg];
        };
        target.* = try std.fmt.parseUnsigned(u64, value, 10);
    }
    if (num_producers == 0 or num_consumers == 0) {
        std.log.err("--num-producers and --num-consumers must be at least 1", .{});
        std.process.exit(2);
    }

    var backend: IoBackend = .none;
    try backend.init(gpa, init.args);
    defer backend.deinit();

    const io = backend.io();

    const results = try gpa.alloc(u64, num_consumers);
    defer gpa.free(results);
    @memset(results, 0);

    var buf: [buffer_size]u64 = undefined;
    var q: xsync.Queue(u64) = .init(&buf);
    var producers_remaining: std.atomic.Value(u64) = .init(num_producers);

    const start_time: std.Io.Clock.Timestamp = .now(io, .real);

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    for (results) |*result| {
        try group.concurrent(io, consumer, .{ io, &q, work_iters, result });
    }
    for (0..num_producers) |p| {
        // Even split; integer boundaries distribute any remainder.
        const start = @as(u64, p) * num_items / num_producers;
        const end = (@as(u64, p) + 1) * num_items / num_producers;
        try group.concurrent(io, producer, .{ io, &q, start, end, &producers_remaining });
    }
    try group.await(io);

    var checksum: u64 = 0;
    for (results) |r| checksum ^= r;

    const end_time = std.Io.Clock.Timestamp.now(io, .real);
    const duration = start_time.durationTo(end_time);
    const ns = duration.raw.toNanoseconds();
    const rate = if (ns > 0) num_items * 1_000_000_000 / @as(u64, @intCast(ns)) else 0;
    std.log.info("Duration: {f} ({d} items, {d} producers, {d} consumers, work={d}, {d} msgs/s, checksum={x})", .{ duration.raw, num_items, num_producers, num_consumers, work_iters, rate, checksum });
}
