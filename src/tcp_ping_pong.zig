const std = @import("std");
const IoBackend = @import("utils.zig").IoBackend;

const limit: u64 = 100_000;
const port: u16 = 18765;
const msg_size = 4096;

fn server(io: std.Io, ready: *std.Io.Event) !void {
    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    var srv = addr.listen(io, .{ .reuse_address = true }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => |e| {
            std.log.err("server: listen failed: {}", .{e});
            ready.set(io);
            return;
        },
    };
    defer srv.deinit(io);

    ready.set(io);

    var stream = srv.accept(io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => |e| {
            std.log.err("server: accept failed: {}", .{e});
            return;
        },
    };
    defer {
        stream.shutdown(io, .both) catch {};
        stream.close(io);
    }

    var read_buf: [msg_size]u8 = undefined;
    var write_buf: [msg_size]u8 = undefined;
    var msg: [msg_size]u8 = @splat(0);
    var r = stream.reader(io, &read_buf);
    var w = stream.writer(io, &write_buf);

    std.mem.writeInt(u64, msg[0..8], 0, .big);
    w.interface.writeAll(&msg) catch return;
    w.interface.flush() catch return;

    while (true) {
        r.interface.readSliceAll(&msg) catch return;
        const val = std.mem.readInt(u64, msg[0..8], .big);
        const next = val + 1;
        if (next >= limit) return;
        std.mem.writeInt(u64, msg[0..8], next, .big);
        w.interface.writeAll(&msg) catch return;
        w.interface.flush() catch return;
    }
}

fn client(io: std.Io, ready: *std.Io.Event) !void {
    try ready.wait(io);

    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    var stream = addr.connect(io, .{ .mode = .stream }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => |e| {
            std.log.err("client: connect failed: {}", .{e});
            return;
        },
    };
    defer {
        stream.shutdown(io, .both) catch {};
        stream.close(io);
    }

    var read_buf: [msg_size]u8 = undefined;
    var write_buf: [msg_size]u8 = undefined;
    var msg: [msg_size]u8 = undefined;
    var r = stream.reader(io, &read_buf);
    var w = stream.writer(io, &write_buf);

    while (true) {
        r.interface.readSliceAll(&msg) catch return;
        const val = std.mem.readInt(u64, msg[0..8], .big);
        const next = val + 1;
        if (next >= limit) return;
        std.mem.writeInt(u64, msg[0..8], next, .big);
        w.interface.writeAll(&msg) catch return;
        w.interface.flush() catch return;
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

    try group.concurrent(io, server, .{ io, &ready });
    try group.concurrent(io, client, .{ io, &ready });
    try group.await(io);

    const end_time = std.Io.Clock.Timestamp.now(io, .real);
    const duration = start_time.durationTo(end_time);
    std.log.info("Duration: {f}", .{duration.raw});
}
