const std = @import("std");
const zio = @import("zio");
const IoBackend = @import("utils.zig").IoBackend;

fn lookupHost(io: std.Io, sem: *std.Io.Semaphore, hostname: []const u8) !void {
    defer sem.post(io);
    var hn = std.Io.net.HostName.init(hostname) catch |err| {
        std.log.err("Failed: {}", .{err});
        return;
    };
    var results: [32]std.Io.net.HostName.LookupResult = undefined;
    var results_q: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&results);
    hn.lookup(io, &results_q, .{ .port = 80 }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => |e| {
            std.log.err("Failed: {}", .{e});
            return;
        },
    };
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var backend: IoBackend = .none;
    try backend.init(gpa, init.args);
    defer backend.deinit();

    const io = backend.io();

    const start_time: std.Io.Clock.Timestamp = .now(io, .real);

    var sem: std.Io.Semaphore = .{ .permits = 1000 };

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    for (0..10000) |_| {
        try sem.wait(io);
        group.async(io, lookupHost, .{ io, &sem, "example.com" });
    }
    try group.await(io);

    const end_time = std.Io.Clock.Timestamp.now(io, .real);
    const duration = start_time.durationTo(end_time);
    std.log.info("Duration: {f}", .{duration.raw});
}
