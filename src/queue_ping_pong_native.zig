const std = @import("std");
const zio = @import("zio");

// Native-API counterpart of queue_ping_pong.zig: ping-pong over zio's native
// Channel(u64) instead of the generic, type-erased std.Io.Queue. --pairs=N runs
// N independent pairs concurrently, splitting a fixed total of `total` messages
// evenly (each pair bounces total/N). Only the zio runtime is supported, so this
// takes --zio / --zio-mt and is compared against the std.Io queue_ping_pong.

const total: u64 = 100_000;

const Context = struct {
    a_to_b: zio.Channel(u64),
    b_to_a: zio.Channel(u64),
    limit: u64,
};

fn taskA(ctx: *Context) zio.Cancelable!void {
    ctx.a_to_b.send(0) catch |err| switch (err) {
        error.ChannelClosed => return,
        error.Canceled => return error.Canceled,
    };
    while (true) {
        const val = ctx.b_to_a.receive() catch |err| switch (err) {
            error.ChannelClosed => return,
            error.Canceled => return error.Canceled,
        };
        const next = val + 1;
        if (next >= ctx.limit) {
            ctx.a_to_b.close(.graceful);
            return;
        }
        ctx.a_to_b.send(next) catch |err| switch (err) {
            error.ChannelClosed => return,
            error.Canceled => return error.Canceled,
        };
    }
}

fn taskB(ctx: *Context) zio.Cancelable!void {
    while (true) {
        const val = ctx.a_to_b.receive() catch |err| switch (err) {
            error.ChannelClosed => return,
            error.Canceled => return error.Canceled,
        };
        const next = val + 1;
        if (next >= ctx.limit) {
            ctx.b_to_a.close(.graceful);
            return;
        }
        ctx.b_to_a.send(next) catch |err| switch (err) {
            error.ChannelClosed => return,
            error.Canceled => return error.Canceled,
        };
    }
}

// One pair: owns its two channels and runs the two ping-pong tasks to completion.
fn pair(limit: u64) !void {
    // Capacity-1 buffers to match queue_ping_pong.zig's [1]u64 queues.
    var buf_a: [1]u64 = undefined;
    var buf_b: [1]u64 = undefined;
    var ctx: Context = .{
        .a_to_b = zio.Channel(u64).init(&buf_a),
        .b_to_a = zio.Channel(u64).init(&buf_b),
        .limit = limit,
    };

    var group: zio.Group = .init;
    defer group.cancel();
    try group.spawn(taskA, .{&ctx});
    try group.spawn(taskB, .{&ctx});
    try group.wait();
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var mt = false;
    var have_backend = false;
    var pairs: u64 = 1;
    var iter = init.args.iterate();
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--zio")) {
            std.log.info("Using zio (single-threaded)", .{});
            have_backend = true;
        } else if (std.mem.eql(u8, arg, "--zio-mt")) {
            std.log.info("Using zio (multi-threaded)", .{});
            have_backend = true;
            mt = true;
        } else if (std.mem.startsWith(u8, arg, "--pairs=")) {
            pairs = try std.fmt.parseUnsigned(u64, arg["--pairs=".len..], 10);
        }
    }
    if (!have_backend) {
        std.debug.print("Usage: queue_ping_pong_native [--zio | --zio-mt] [--pairs=N]\n", .{});
        std.process.exit(1);
    }
    if (pairs == 0) pairs = 1;
    const per_pair = @max(total / pairs, 1);

    const rt = try zio.Runtime.init(gpa, if (mt) .{ .executors = .auto } else .{});
    defer rt.deinit();

    const start_time = zio.Timestamp.now(.monotonic);

    var group: zio.Group = .init;
    defer group.cancel();
    for (0..pairs) |_| {
        try group.spawn(pair, .{per_pair});
    }
    try group.wait();

    const duration = start_time.untilNow(.monotonic);
    std.log.info("Duration: {f} ({d} pairs, {d} msgs each)", .{ duration, pairs, per_pair });
}
