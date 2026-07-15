const std = @import("std");
const IoBackend = @import("utils.zig").IoBackend;

// Golden sleep/spawn benchmark: spawn --tasks concurrent tasks that each sleep
// --sleep-ms, wait for all of them. Presets:
//
//   defaults (10000 tasks x 1ms)   spawn storm + timer pressure
//   --sleep-ms=0                   pure no-op spawn benchmark (no timers)
//   --sleep-ms=1000                many long sleeps (timer capacity)
fn sleepTask(io: std.Io, sleep_ms: u64) !void {
    if (sleep_ms > 0) {
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(sleep_ms)), .awake);
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const args = try init.args.toSlice(arena_state.allocator());

    var num_tasks: u64 = 10_000;
    var sleep_ms: u64 = 1;

    var iarg: usize = 1;
    while (iarg < args.len) : (iarg += 1) {
        const arg = args[iarg];
        if (std.mem.eql(u8, arg, "--zio") or std.mem.eql(u8, arg, "--zio-mt") or std.mem.eql(u8, arg, "--threaded")) {
            continue; // io backend selection, handled by IoBackend below
        }
        const split_pos = std.mem.findScalar(u8, arg, '=') orelse arg.len;
        const key = arg[0..split_pos];
        const target: *u64 = if (std.mem.eql(u8, key, "--tasks"))
            &num_tasks
        else if (std.mem.eql(u8, key, "--sleep-ms"))
            &sleep_ms
        else {
            std.log.err("unknown argument '{s}'", .{arg});
            std.log.err("usage: sleep_bench [--zio | --zio-mt | --threaded] [--tasks=N] [--sleep-ms=N]", .{});
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

    var backend: IoBackend = .none;
    try backend.init(gpa, init.args);
    defer backend.deinit();

    const io = backend.io();

    const start_time: std.Io.Clock.Timestamp = .now(io, .real);

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    for (0..num_tasks) |_| {
        try group.concurrent(io, sleepTask, .{ io, sleep_ms });
    }
    try group.await(io);

    const end_time = std.Io.Clock.Timestamp.now(io, .real);
    const duration = start_time.durationTo(end_time);
    std.log.info("Duration: {f} ({d} tasks, sleep {d}ms)", .{ duration.raw, num_tasks, sleep_ms });
}
