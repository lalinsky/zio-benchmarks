const std = @import("std");
const IoBackend = @import("utils.zig").IoBackend;

// --pairs=N runs N independent ping-pong pairs concurrently, splitting a fixed
// total of `total` messages evenly (each pair bounces total/N). pairs=1 is the
// classic single wake-latency chain; higher counts exercise scheduling many
// concurrent chains at the same total work.
const total: u64 = 100_000;

const Context = struct {
    a_to_b: std.Io.Queue(u64),
    b_to_a: std.Io.Queue(u64),
    limit: u64,
};

fn taskA(io: std.Io, ctx: *Context) error{Canceled}!void {
    ctx.a_to_b.putOne(io, 0) catch |err| switch (err) {
        error.Closed => return,
        error.Canceled => return error.Canceled,
    };
    while (true) {
        const val = ctx.b_to_a.getOne(io) catch return;
        const next = val + 1;
        if (next >= ctx.limit) {
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
        if (next >= ctx.limit) {
            ctx.b_to_a.close(io);
            return;
        }
        ctx.b_to_a.putOne(io, next) catch |err| switch (err) {
            error.Closed => return,
            error.Canceled => return error.Canceled,
        };
    }
}

// One pair: owns its two channels and runs the two ping-pong tasks to completion.
fn pair(io: std.Io, limit: u64) error{Canceled}!void {
    var buf_a: [1]u64 = undefined;
    var buf_b: [1]u64 = undefined;
    var ctx: Context = .{ .a_to_b = .init(&buf_a), .b_to_a = .init(&buf_b), .limit = limit };

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    group.async(io, taskA, .{ io, &ctx });
    group.async(io, taskB, .{ io, &ctx });
    try group.await(io);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const args = try init.args.toSlice(arena_state.allocator());

    var pairs: u64 = 1;
    var iarg: usize = 1;
    while (iarg < args.len) : (iarg += 1) {
        const arg = args[iarg];
        if (std.mem.eql(u8, arg, "--zio") or std.mem.eql(u8, arg, "--zio-mt") or std.mem.eql(u8, arg, "--threaded")) {
            continue; // io backend selection, handled by IoBackend
        }
        const split_pos = std.mem.findScalar(u8, arg, '=') orelse arg.len;
        if (!std.mem.eql(u8, arg[0..split_pos], "--pairs")) {
            std.log.err("unknown argument '{s}'", .{arg});
            std.log.err("usage: queue_ping_pong [--zio | --zio-mt | --threaded] [--pairs=N]", .{});
            std.process.exit(1);
        }
        const value = if (split_pos < arg.len) arg[split_pos + 1 ..] else blk: {
            iarg += 1;
            if (iarg >= args.len) {
                std.log.err("expected a value after --pairs", .{});
                std.process.exit(2);
            }
            break :blk args[iarg];
        };
        pairs = try std.fmt.parseUnsigned(u64, value, 10);
    }
    if (pairs == 0) pairs = 1;
    const per_pair = @max(total / pairs, 1);

    var backend: IoBackend = .none;
    try backend.init(gpa, init.args);
    defer backend.deinit();

    const io = backend.io();

    const start_time: std.Io.Clock.Timestamp = .now(io, .real);

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..pairs) |_| {
        try group.concurrent(io, pair, .{ io, per_pair });
    }
    try group.await(io);

    const end_time = std.Io.Clock.Timestamp.now(io, .real);
    const duration = start_time.durationTo(end_time);
    std.log.info("Duration: {f} ({d} pairs, {d} msgs each)", .{ duration.raw, pairs, per_pair });
}
