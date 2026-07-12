const std = @import("std");
const zio = @import("zio");

// Standalone multithreaded zio TCP echo server for cross-runtime comparison
// against tardy. Accepts connections and echoes bytes back, one task per
// connection, no logging. Listens on 0.0.0.0:<port> (default 9863).
const default_port: u16 = 9863;
const frame_size = 64; // fixed-size frames (matches the load generator); avoids
// the readSliceShort/readSliceAll fill-until-full deadlock with a request/response client.

fn handleClient(io: std.Io, stream: std.Io.net.Stream) void {
    defer stream.close(io);
    var read_buf: [frame_size]u8 = undefined;
    var write_buf: [frame_size]u8 = undefined;
    var r = stream.reader(io, &read_buf);
    var w = stream.writer(io, &write_buf);
    var msg: [frame_size]u8 = undefined;
    while (true) {
        r.interface.readSliceAll(&msg) catch return; // reads exactly frame_size; EndOfStream on close
        w.interface.writeAll(&msg) catch return;
        w.interface.flush() catch return;
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var port: u16 = default_port;
    var threads: u8 = 0; // 0 = auto (all cores)
    var it = init.args.iterate();
    _ = it.next(); // argv0
    if (it.next()) |arg| port = std.fmt.parseUnsigned(u16, arg, 10) catch default_port;
    if (it.next()) |arg| threads = std.fmt.parseUnsigned(u8, arg, 10) catch 0;

    const rt = if (threads == 0)
        try zio.Runtime.init(gpa, .{ .executors = .auto })
    else
        try zio.Runtime.init(gpa, .{ .executors = .exact(threads) });
    std.log.info("zio executors={d} (0=auto)", .{threads});
    defer rt.deinit();
    const io = rt.io();

    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    var server = try addr.listen(io, .{ .reuse_address = true, .kernel_backlog = 1024 });
    defer server.deinit(io);

    std.log.info("zio echo server listening on 127.0.0.1:{d}", .{port});

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    while (true) {
        const stream = server.accept(io) catch break;
        group.concurrent(io, handleClient, .{ io, stream }) catch {
            stream.close(io);
            break;
        };
    }
    try group.await(io);
}
