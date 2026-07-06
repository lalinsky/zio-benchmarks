const std = @import("std");
const IoBackend = @import("utils.zig").IoBackend;

// Balanced binary spawn tree: every internal node spawns 2 children into its
// own local group and awaits them, down to `depth` levels. Unlike task_chain's
// fire-and-forget relay, parents block in group.await() while children run, so
// this exercises the backend's fan-out/join (spawn + suspend + wake) path.
//
// A tree of `depth` levels has 2^depth leaf tasks and 2^(depth+1)-1 total
// nodes, i.e. 2*(2^depth - 1) spawns. depth=13 keeps that bounded at
// 8192 leaves / 16383 nodes, comparable in scale to the other benchmarks.
const depth: u32 = 13;

fn node(io: std.Io, level: u32) void {
    if (level == 0) return;
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    // concurrent() (unlike async()) forces a real concurrent task instead of
    // letting the backend degenerate to an inline synchronous call. For
    // std.Io.Threaded that means one OS thread per node blocked in await.
    group.concurrent(io, node, .{ io, level - 1 }) catch node(io, level - 1);
    group.concurrent(io, node, .{ io, level - 1 }) catch node(io, level - 1);
    group.await(io) catch {};
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var backend: IoBackend = .none;
    try backend.init(gpa, init.args);
    defer backend.deinit();

    const io = backend.io();

    const start_time: std.Io.Clock.Timestamp = .now(io, .real);

    node(io, depth);

    const end_time = std.Io.Clock.Timestamp.now(io, .real);
    const duration = start_time.durationTo(end_time);
    const total_nodes = (@as(u64, 1) << (depth + 1)) - 1;
    std.log.info("Duration: {f} ({d} nodes)", .{ duration.raw, total_nodes });
}
