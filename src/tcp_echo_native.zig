const std = @import("std");
const zio = @import("zio");

// Native-API counterpart of tcp_echo.zig: same golden TCP echo benchmark, but
// using zio.net directly instead of std.Io. Only the zio runtime is supported,
// so this binary takes --zio / --zio-mt plus the same --conns/--msgs/--size.
const port: u16 = 18767;
const max_msg_size = 4096;

const Config = struct {
    conns: u64 = 1000,
    msgs: u64 = 100,
    size: u64 = 64,
};

fn echoHandler(stream: zio.net.Stream, size: u64) void {
    defer stream.close();
    var read_buf: [max_msg_size]u8 = undefined;
    var write_buf: [max_msg_size]u8 = undefined;
    var msg: [max_msg_size]u8 = undefined;
    var r = stream.reader(read_buf[0..size]);
    var w = stream.writer(write_buf[0..size]);
    while (true) {
        r.interface.readSliceAll(msg[0..size]) catch return;
        w.interface.writeAll(msg[0..size]) catch return;
        w.interface.flush() catch return;
    }
}

fn serverTask(cfg: Config, ready: *zio.ResetEvent) void {
    const addr = zio.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
    var srv = addr.listen(.{ .reuse_address = true, .kernel_backlog = @intCast(@min(cfg.conns, 4096)) }) catch |err| {
        std.log.err("server: listen failed: {}", .{err});
        ready.set();
        return;
    };
    defer srv.close();

    ready.set();

    var handlers: zio.Group = .init;
    defer handlers.cancel();

    var i: u64 = 0;
    while (i < cfg.conns) : (i += 1) {
        const stream = srv.accept(.{}) catch |err| {
            std.log.err("server: accept failed: {}", .{err});
            break;
        };
        stream.socket.setNoDelay(true) catch {};
        handlers.spawn(echoHandler, .{ stream, cfg.size }) catch {
            stream.close();
            break;
        };
    }
    handlers.wait() catch {};
}

fn clientTask(cfg: Config, ready: *zio.ResetEvent) void {
    ready.wait() catch return;

    const addr = zio.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
    const stream = addr.connect(.{}) catch |err| {
        std.log.err("client: connect failed: {}", .{err});
        return;
    };
    defer stream.close();
    stream.socket.setNoDelay(true) catch {};

    var read_buf: [max_msg_size]u8 = undefined;
    var write_buf: [max_msg_size]u8 = undefined;
    var msg: [max_msg_size]u8 = @splat(0);
    var r = stream.reader(read_buf[0..cfg.size]);
    var w = stream.writer(write_buf[0..cfg.size]);

    var i: u64 = 0;
    while (i < cfg.msgs) : (i += 1) {
        w.interface.writeAll(msg[0..cfg.size]) catch return;
        w.interface.flush() catch return;
        r.interface.readSliceAll(msg[0..cfg.size]) catch return;
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const args = try init.args.toSlice(arena_state.allocator());

    var cfg: Config = .{};
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
        const target: *u64 = if (std.mem.eql(u8, key, "--conns"))
            &cfg.conns
        else if (std.mem.eql(u8, key, "--msgs"))
            &cfg.msgs
        else if (std.mem.eql(u8, key, "--size"))
            &cfg.size
        else {
            std.log.err("unknown argument '{s}'", .{arg});
            std.log.err("usage: tcp_echo_native [--zio | --zio-mt] [--conns=N] [--msgs=N] [--size=N]", .{});
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
        std.debug.print("Usage: tcp_echo_native [--zio | --zio-mt] [--conns=N] [--msgs=N] [--size=N]\n", .{});
        std.process.exit(1);
    }
    if (cfg.conns == 0 or cfg.msgs == 0 or cfg.size == 0 or cfg.size > max_msg_size) {
        std.log.err("--conns/--msgs must be at least 1, --size in [1, {d}]", .{max_msg_size});
        std.process.exit(2);
    }

    const rt = try zio.Runtime.init(gpa, if (mt) .{ .executors = .auto } else .{});
    defer rt.deinit();

    const start_time = zio.Timestamp.now(.monotonic);

    var ready: zio.ResetEvent = .{};

    var group: zio.Group = .init;
    defer group.cancel();

    try group.spawn(serverTask, .{ cfg, &ready });
    var i: u64 = 0;
    while (i < cfg.conns) : (i += 1) {
        try group.spawn(clientTask, .{ cfg, &ready });
    }
    try group.wait();

    const duration = start_time.untilNow(.monotonic);
    const total_msgs = cfg.conns * cfg.msgs;
    const ns = duration.toNanoseconds();
    const rate = if (ns > 0) total_msgs * 1_000_000_000 / ns else 0;
    std.log.info("Duration: {f} ({d} msgs over {d} conns, size {d}, {d} msgs/s)", .{ duration, total_msgs, cfg.conns, cfg.size, rate });
}
