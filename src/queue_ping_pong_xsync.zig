const std = @import("std");
const xsync = @import("xsync");
const IoBackend = @import("utils.zig").IoBackend;

const limit: u64 = 100_000;

const Context = struct {
    a_to_b: xsync.Queue(u64),
    b_to_a: xsync.Queue(u64),
};

fn taskA(io: std.Io, ctx: *Context) error{Canceled}!void {
    ctx.a_to_b.putOne(io, 0) catch |err| switch (err) {
        error.Closed => return,
        error.Canceled => return error.Canceled,
    };
    while (true) {
        const val = ctx.b_to_a.getOne(io) catch return;
        const next = val + 1;
        if (next >= limit) {
            ctx.a_to_b.close(io);
            return;
        }
        ctx.a_to_b.putOne(io, next) catch |err| switch (err) {
            error.Closed => return,
            error.Canceled => return error.Canceled,
        };
    }
}

fn taskB(io: std.Io, ctx: *Context) error{Canceled}!void {
    while (true) {
        const val = ctx.a_to_b.getOne(io) catch return;
        const next = val + 1;
        if (next >= limit) {
            ctx.b_to_a.close(io);
            return;
        }
        ctx.b_to_a.putOne(io, next) catch |err| switch (err) {
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

    var buf_a: [1]u64 = undefined;
    var buf_b: [1]u64 = undefined;
    var ctx: Context = .{
        .a_to_b = .init(&buf_a),
        .b_to_a = .init(&buf_b),
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
