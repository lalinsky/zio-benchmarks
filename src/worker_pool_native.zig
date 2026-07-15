const std = @import("std");
const zio = @import("zio");

// Native-API counterpart of worker_pool.zig: same producers/queue/consumers
// benchmark, but over zio's native Channel(u64) instead of std.Io.Queue. Only
// the zio runtime is supported (--zio / --zio-mt). Golden presets:
//
//   defaults                                  fan-out worker pool (1 -> 1000)
//   --num-producers=1000 --num-consumers=1 --work=0   fan-in (old queue_fan_in)
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

fn producer(ch: *zio.Channel(u64), start: u64, end: u64, remaining: *std.atomic.Value(u64)) void {
    var i: u64 = start;
    while (i < end) : (i += 1) {
        ch.send(i + 1) catch return;
    }
    // Last producer out closes the channel so the consumers drain and exit.
    if (remaining.fetchSub(1, .acq_rel) == 1) ch.close(.graceful);
}

fn consumer(ch: *zio.Channel(u64), work_iters: u64, result: *u64) void {
    var acc: u64 = 0;
    while (true) {
        const item = ch.receive() catch break; // error.ChannelClosed when drained
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
    var mt = false;
    var have_backend = false;

    var iarg: usize = 1;
    while (iarg < args.len) : (iarg += 1) {
        const arg = args[iarg];
        if (std.mem.eql(u8, arg, "--zio")) {
            std.log.info("Using zio (single-threaded)", .{});
            have_backend = true;
            continue;
        } else if (std.mem.eql(u8, arg, "--zio-mt")) {
            std.log.info("Using zio (multi-threaded)", .{});
            have_backend = true;
            mt = true;
            continue;
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
            std.log.err("usage: worker_pool_native [--zio | --zio-mt] [--num-items=N] [--num-producers=N] [--num-consumers=N] [--work=N]", .{});
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
    if (!have_backend) {
        std.debug.print("Usage: worker_pool_native [--zio | --zio-mt] [--num-items=N] [--num-producers=N] [--num-consumers=N] [--work=N]\n", .{});
        std.process.exit(1);
    }
    if (num_producers == 0 or num_consumers == 0) {
        std.log.err("--num-producers and --num-consumers must be at least 1", .{});
        std.process.exit(2);
    }

    const rt = try zio.Runtime.init(gpa, if (mt) .{ .executors = .auto } else .{});
    defer rt.deinit();

    const results = try gpa.alloc(u64, num_consumers);
    defer gpa.free(results);
    @memset(results, 0);

    var buf: [buffer_size]u64 = undefined;
    var ch = zio.Channel(u64).init(&buf);
    var producers_remaining: std.atomic.Value(u64) = .init(num_producers);

    const start_time = zio.Timestamp.now(.monotonic);

    var group: zio.Group = .init;
    defer group.cancel();

    for (results) |*result| {
        try group.spawn(consumer, .{ &ch, work_iters, result });
    }
    for (0..num_producers) |p| {
        // Even split; integer boundaries distribute any remainder.
        const start = @as(u64, p) * num_items / num_producers;
        const end = (@as(u64, p) + 1) * num_items / num_producers;
        try group.spawn(producer, .{ &ch, start, end, &producers_remaining });
    }
    try group.wait();

    var checksum: u64 = 0;
    for (results) |r| checksum ^= r;

    const duration = start_time.untilNow(.monotonic);
    const ns = duration.toNanoseconds();
    const rate = if (ns > 0) num_items * 1_000_000_000 / ns else 0;
    std.log.info("Duration: {f} ({d} items, {d} producers, {d} consumers, work={d}, {d} msgs/s, checksum={x})", .{ duration, num_items, num_producers, num_consumers, work_iters, rate, checksum });
}
