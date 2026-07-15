const std = @import("std");
const IoBackend = @import("utils.zig").IoBackend;

// Golden TCP benchmark: `--conns` concurrent loopback connections, each doing
// `--msgs` request/response round-trips of `--size` bytes against a
// per-connection echo handler. Two golden presets:
//
//   defaults (1000 conns x 100 msgs x 64B)   many-connection throughput
//   --conns=1 --msgs=100000 --size=4096      single-connection latency chain
//                                            (the old tcp_ping_pong)
//
// Counterparts: go/tcp_echo, rust tcp_echo (tokio), cpp/tcp_echo_photon.
const port: u16 = 18766;
const max_msg_size = 4096;

const Config = struct {
    conns: u64 = 1000,
    msgs: u64 = 100,
    size: u64 = 64,
};

fn echoHandler(io: std.Io, stream: std.Io.net.Stream, size: u64) void {
    defer stream.close(io);
    var read_buf: [max_msg_size]u8 = undefined;
    var write_buf: [max_msg_size]u8 = undefined;
    var msg: [max_msg_size]u8 = undefined;
    var r = stream.reader(io, read_buf[0..size]);
    var w = stream.writer(io, write_buf[0..size]);
    while (true) {
        r.interface.readSliceAll(msg[0..size]) catch return;
        w.interface.writeAll(msg[0..size]) catch return;
        w.interface.flush() catch return;
    }
}

fn serverTask(io: std.Io, cfg: Config, ready: *std.Io.Event) void {
    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    var srv = addr.listen(io, .{ .reuse_address = true, .kernel_backlog = @intCast(@min(cfg.conns, 4096)) }) catch |err| {
        std.log.err("server: listen failed: {}", .{err});
        ready.set(io);
        return;
    };
    defer srv.deinit(io);

    ready.set(io);

    // One echo handler per accepted connection; wait for all before returning.
    var handlers: std.Io.Group = .init;
    defer handlers.cancel(io);

    var i: u64 = 0;
    while (i < cfg.conns) : (i += 1) {
        const stream = srv.accept(io) catch |err| {
            std.log.err("server: accept failed: {}", .{err});
            break;
        };
        handlers.concurrent(io, echoHandler, .{ io, stream, cfg.size }) catch {
            stream.close(io);
            break;
        };
    }
    handlers.await(io) catch {};
}

fn clientTask(io: std.Io, cfg: Config, ready: *std.Io.Event) void {
    ready.wait(io) catch return;

    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    var stream = addr.connect(io, .{ .mode = .stream }) catch |err| {
        std.log.err("client: connect failed: {}", .{err});
        return;
    };
    defer stream.close(io);

    var read_buf: [max_msg_size]u8 = undefined;
    var write_buf: [max_msg_size]u8 = undefined;
    var msg: [max_msg_size]u8 = @splat(0);
    var r = stream.reader(io, read_buf[0..cfg.size]);
    var w = stream.writer(io, write_buf[0..cfg.size]);

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
    var iarg: usize = 1;
    while (iarg < args.len) : (iarg += 1) {
        const arg = args[iarg];
        if (std.mem.eql(u8, arg, "--zio") or std.mem.eql(u8, arg, "--zio-mt") or std.mem.eql(u8, arg, "--threaded")) {
            continue; // io backend selection, handled by IoBackend below
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
            std.log.err("usage: tcp_echo [--zio | --zio-mt | --threaded] [--conns=N] [--msgs=N] [--size=N]", .{});
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
    if (cfg.conns == 0 or cfg.msgs == 0 or cfg.size == 0 or cfg.size > max_msg_size) {
        std.log.err("--conns/--msgs must be at least 1, --size in [1, {d}]", .{max_msg_size});
        std.process.exit(2);
    }

    var backend: IoBackend = .none;
    try backend.init(gpa, init.args);
    defer backend.deinit();

    const io = backend.io();

    const start_time: std.Io.Clock.Timestamp = .now(io, .real);

    var ready: std.Io.Event = .unset;

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    try group.concurrent(io, serverTask, .{ io, cfg, &ready });
    var i: u64 = 0;
    while (i < cfg.conns) : (i += 1) {
        try group.concurrent(io, clientTask, .{ io, cfg, &ready });
    }
    try group.await(io);

    const end_time = std.Io.Clock.Timestamp.now(io, .real);
    const duration = start_time.durationTo(end_time);
    const total_msgs = cfg.conns * cfg.msgs;
    const ns = duration.raw.toNanoseconds();
    const rate = if (ns > 0) total_msgs * 1_000_000_000 / @as(u64, @intCast(ns)) else 0;
    std.log.info("Duration: {f} ({d} msgs over {d} conns, size {d}, {d} msgs/s)", .{ duration.raw, total_msgs, cfg.conns, cfg.size, rate });
}
