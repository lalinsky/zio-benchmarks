const std = @import("std");
const zio = @import("zio");

// Native-API counterpart of sleep.zig: spawn --tasks concurrent tasks
// that each sleep --sleep-ms on zio's native runtime, wait for all of them.
// Presets:
//
//   defaults (10000 tasks x 1ms)   spawn storm + timer pressure
//   --sleep-ms=0                   pure no-op spawn benchmark (no timers)
//   --sleep-ms=1000                many long sleeps (timer capacity)
//
// Each task bumps a shared atomic counter as its last act, and main verifies
// the count equals --tasks — proof that every task actually ran to completion
// (a plain std.debug.assert would be compiled out in ReleaseFast).
fn sleepTask(counter: *std.atomic.Value(u64), sleep_ms: u64) !void {
    if (sleep_ms > 0) {
        try zio.sleep(zio.Duration.fromMilliseconds(sleep_ms));
    }
    _ = counter.fetchAdd(1, .monotonic);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const args = try init.args.toSlice(arena_state.allocator());

    var num_tasks: u64 = 10_000;
    var sleep_ms: u64 = 1;
    var mt = false;
    var have_backend = false;

    var iarg: usize = 1;
    while (iarg < args.len) : (iarg += 1) {
        const arg = args[iarg];
        if (std.mem.eql(u8, arg, "--zio")) {
            std.log.info("Using zio (single-threaded)", .{});
            have_backend = true;
            continue;
        } else if (std.mem.eql(u8, arg, "--zio-mt")) {
            std.log.info("Using zio (multi-threaded)", .{});
            have_backend = true;
            mt = true;
            continue;
        }
        const split_pos = std.mem.findScalar(u8, arg, '=') orelse arg.len;
        const key = arg[0..split_pos];
        const target: *u64 = if (std.mem.eql(u8, key, "--tasks"))
            &num_tasks
        else if (std.mem.eql(u8, key, "--sleep-ms"))
            &sleep_ms
        else {
            std.log.err("unknown argument '{s}'", .{arg});
            std.log.err("usage: sleep_native [--zio | --zio-mt] [--tasks=N] [--sleep-ms=N]", .{});
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

    if (!have_backend) {
        std.debug.print("usage: sleep_native [--zio | --zio-mt] [--tasks=N] [--sleep-ms=N]\n", .{});
        std.process.exit(1);
    }

    const rt = try zio.Runtime.init(gpa, if (mt) .{ .executors = .auto } else .{});
    defer rt.deinit();

    var counter: std.atomic.Value(u64) = .init(0);

    const start_time = zio.Timestamp.now(.monotonic);

    var group: zio.Group = .init;
    defer group.cancel();

    for (0..num_tasks) |_| {
        try group.spawn(sleepTask, .{ &counter, sleep_ms });
    }
    try group.wait();

    const duration = start_time.untilNow(.monotonic);

    // Proof that every task ran (survives ReleaseFast, unlike an assert).
    const ran = counter.load(.monotonic);
    if (ran != num_tasks) {
        std.log.err("only {d}/{d} tasks completed", .{ ran, num_tasks });
        std.process.exit(3);
    }

    std.log.info("Duration: {f} ({d} tasks, sleep {d}ms)", .{ duration, num_tasks, sleep_ms });
}
