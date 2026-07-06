const std = @import("std");
const IoBackend = @import("utils.zig").IoBackend;

// Spawns a chain of `chain_length` tasks: each task spawns the next one into
// the shared group and returns immediately. Only ~1 task is ever in flight at
// a time, so this measures raw per-task spawn/schedule/teardown throughput of
// the io backend rather than concurrency. Using a group means we never have to
// await/reap individual tasks.
const chain_length: u64 = 10_000;

fn link(io: std.Io, group: *std.Io.Group, n: u64) void {
    if (n == 0) return;
    group.async(io, link, .{ io, group, n - 1 });
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

    group.async(io, link, .{ io, &group, chain_length });
    try group.await(io);

    const end_time = std.Io.Clock.Timestamp.now(io, .real);
    const duration = start_time.durationTo(end_time);
    std.log.info("Duration: {f}", .{duration.raw});
}
