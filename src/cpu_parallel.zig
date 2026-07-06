const std = @import("std");
const IoBackend = @import("utils.zig").IoBackend;

// CPU-bound parallel reduction. A large data-dependent hash recurrence (which
// the compiler cannot vectorize or hoist) is split into `num_chunks` chunks,
// one task per chunk, and the partial results are xor-combined into a checksum.
// There is no I/O and the tasks never yield, so this measures raw parallel
// compute throughput and the scheduler's ability to spread CPU work across
// cores — the case where zio's cooperative model has the least edge over plain
// threads. --zio (single-threaded) is the ~1x baseline; the checksum must match
// across all backends.
const total_iters: u64 = 4_000_000_000;
const num_chunks: usize = 64;
const per_chunk: u64 = total_iters / num_chunks;

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

fn worker(results: *[num_chunks]u64, idx: usize) void {
    results[idx] = work(@intCast(idx + 1), per_chunk);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var backend: IoBackend = .none;
    try backend.init(gpa, init.args);
    defer backend.deinit();

    const io = backend.io();

    var results: [num_chunks]u64 = undefined;

    const start_time: std.Io.Clock.Timestamp = .now(io, .real);

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    for (0..num_chunks) |idx| {
        try group.concurrent(io, worker, .{ &results, idx });
    }
    try group.await(io);

    var checksum: u64 = 0;
    for (results) |r| checksum ^= r;

    const end_time = std.Io.Clock.Timestamp.now(io, .real);
    const duration = start_time.durationTo(end_time);
    std.log.info("Duration: {f} ({d} iters, {d} chunks, checksum={x})", .{ duration.raw, total_iters, num_chunks, checksum });
}
