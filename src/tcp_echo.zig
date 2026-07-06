const std = @import("std");
const IoBackend = @import("utils.zig").IoBackend;

// Many-connection echo throughput. Opens `num_conns` concurrent loopback TCP
// connections; each client does `msgs_per_conn` request/response round-trips
// against a per-connection echo handler on the server side. Unlike
// tcp_ping_pong (a single connection, 2 tasks), this stresses the event loop
// with thousands of simultaneously-active sockets and tasks, i.e. the workload
// an async runtime actually exists for.
const num_conns: u64 = 1000;
const msgs_per_conn: u64 = 100;
const msg_size = 64;
const port: u16 = 18766;

fn echoHandler(io: std.Io, stream: std.Io.net.Stream) void {
    defer stream.close(io);
    var read_buf: [msg_size]u8 = undefined;
    var write_buf: [msg_size]u8 = undefined;
    var msg: [msg_size]u8 = undefined;
    var r = stream.reader(io, &read_buf);
    var w = stream.writer(io, &write_buf);
    while (true) {
        r.interface.readSliceAll(&msg) catch return;
        w.interface.writeAll(&msg) catch return;
        w.interface.flush() catch return;
    }
}

fn serverTask(io: std.Io, ready: *std.Io.Event) void {
    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    var srv = addr.listen(io, .{ .reuse_address = true, .kernel_backlog = num_conns }) catch |err| {
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
    while (i < num_conns) : (i += 1) {
        const stream = srv.accept(io) catch |err| {
            std.log.err("server: accept failed: {}", .{err});
            break;
        };
        handlers.concurrent(io, echoHandler, .{ io, stream }) catch {
            stream.close(io);
            break;
        };
    }
    handlers.await(io) catch {};
}

fn clientTask(io: std.Io, ready: *std.Io.Event) void {
    ready.wait(io) catch return;

    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    var stream = addr.connect(io, .{ .mode = .stream }) catch |err| {
        std.log.err("client: connect failed: {}", .{err});
        return;
    };
    defer stream.close(io);

    var read_buf: [msg_size]u8 = undefined;
    var write_buf: [msg_size]u8 = undefined;
    var msg: [msg_size]u8 = @splat(0);
    var r = stream.reader(io, &read_buf);
    var w = stream.writer(io, &write_buf);

    var i: u64 = 0;
    while (i < msgs_per_conn) : (i += 1) {
        w.interface.writeAll(&msg) catch return;
        w.interface.flush() catch return;
        r.interface.readSliceAll(&msg) catch return;
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var backend: IoBackend = .none;
    try backend.init(gpa, init.args);
    defer backend.deinit();

    const io = backend.io();

    const start_time: std.Io.Clock.Timestamp = .now(io, .real);

    var ready: std.Io.Event = .unset;

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    try group.concurrent(io, serverTask, .{ io, &ready });
    var i: u64 = 0;
    while (i < num_conns) : (i += 1) {
        try group.concurrent(io, clientTask, .{ io, &ready });
    }
    try group.await(io);

    const end_time = std.Io.Clock.Timestamp.now(io, .real);
    const duration = start_time.durationTo(end_time);
    const total_msgs = num_conns * msgs_per_conn;
    const ns = duration.raw.toNanoseconds();
    const rate = if (ns > 0) total_msgs * 1_000_000_000 / @as(u64, @intCast(ns)) else 0;
    std.log.info("Duration: {f} ({d} msgs over {d} conns, {d} msgs/s)", .{ duration.raw, total_msgs, num_conns, rate });
}
