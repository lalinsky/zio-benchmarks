const std = @import("std");
const IoBackend = @import("utils.zig").IoBackend;

fn sleepTask(io: std.Io) !void {
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var backend: IoBackend = .none;
    try backend.init(gpa, init.args);
    defer backend.deinit();

    const io = backend.io();

    const start_time: std.Io.Clock.Timestamp = .now(io, .real);

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    for (0..10000) |_| {
        try group.concurrent(io, sleepTask, .{io});
    }
    try group.await(io);

    const end_time = std.Io.Clock.Timestamp.now(io, .real);
    const duration = start_time.durationTo(end_time);
    std.log.info("Duration: {f}", .{duration.raw});
}
