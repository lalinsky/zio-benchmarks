const std = @import("std");
const IoBackend = @import("utils.zig").IoBackend;
const FutexChannel = @import("futex_channel.zig").FutexChannel;

// Same 100k two-task ping-pong as queue_ping_pong.zig, but over a channel built
// directly on the std.Io futex vtable (see futex_channel.zig) instead of the
// generic std.Io.Queue (which stacks a Condition on the futex). Still goes
// through the std.Io interface, so it runs on every backend (--zio, --zio-mt,
// --threaded) and is directly comparable to queue_ping_pong.

const limit: u64 = 100_000;

const Context = struct {
    a_to_b: FutexChannel(u64),
    b_to_a: FutexChannel(u64),
};

fn taskA(io: std.Io, ctx: *Context) error{Canceled}!void {
    ctx.a_to_b.send(io, 0) catch |err| switch (err) {
        error.Closed => return,
        error.Canceled => return error.Canceled,
    };
    while (true) {
        const val = ctx.b_to_a.receive(io) catch |err| switch (err) {
            error.Closed => return,
            error.Canceled => return error.Canceled,
        };
        const next = val + 1;
        if (next >= limit) {
            ctx.a_to_b.close(io);
            return;
        }
        ctx.a_to_b.send(io, next) catch |err| switch (err) {
            error.Closed => return,
            error.Canceled => return error.Canceled,
        };
    }
}

fn taskB(io: std.Io, ctx: *Context) error{Canceled}!void {
    while (true) {
        const val = ctx.a_to_b.receive(io) catch |err| switch (err) {
            error.Closed => return,
            error.Canceled => return error.Canceled,
        };
        const next = val + 1;
        if (next >= limit) {
            ctx.b_to_a.close(io);
            return;
        }
        ctx.b_to_a.send(io, next) catch |err| switch (err) {
            error.Closed => return,
            error.Canceled => return error.Canceled,
        };
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var backend: IoBackend = .none;
    try backend.init(gpa, init.args);
    defer backend.deinit();

    const io = backend.io();

    const start_time: std.Io.Clock.Timestamp = .now(io, .real);

    // Capacity-1 buffers to match queue_ping_pong.zig's [1]u64 queues.
    var buf_a: [1]u64 = undefined;
    var buf_b: [1]u64 = undefined;
    var ctx: Context = .{
        .a_to_b = FutexChannel(u64).init(&buf_a),
        .b_to_a = FutexChannel(u64).init(&buf_b),
    };

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    group.async(io, taskA, .{ io, &ctx });
    group.async(io, taskB, .{ io, &ctx });
    try group.await(io);

    const end_time = std.Io.Clock.Timestamp.now(io, .real);
    const duration = start_time.durationTo(end_time);
    std.log.info("Duration: {f}", .{duration.raw});
}
