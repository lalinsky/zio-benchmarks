const std = @import("std");
const IoBackend = @import("utils.zig").IoBackend;

// TCP benchmark subject (std.Io API), driven by driver/tcp_driver.go. Accepts
// connections forever (the bench runner kills the process); one task per
// connection. Modes:
//
//   echo    write back whatever arrives (works with driver pipelining)
//   sink    read and discard until EOF
//   source  write zeros until the client closes
//   http    minimal HTTP/1.1 keep-alive: read a request, write a fixed
//           "HelloWorld" response. Drive this one with wrk, not the driver.
//
// usage: tcp_server [--zio | --zio-mt | --threaded] [--mode=echo|sink|source|http] [--port=N]
const buf_size = 64 * 1024;

const http_response = "HTTP/1.1 200 Ok\r\nContent-Length: 10\r\nContent-Type: text/plain; charset=utf8\r\n\r\nHelloWorld";

const Mode = enum { echo, sink, source, http };

fn handler(io: std.Io, gpa: std.mem.Allocator, stream: std.Io.net.Stream, mode: Mode) void {
    defer stream.close(io);
    const buf = gpa.alloc(u8, buf_size) catch return;
    defer gpa.free(buf);

    switch (mode) {
        .echo => {
            // Echo whatever is available: fillMore does exactly one underlying
            // read (readSliceShort would block until the whole buffer fills).
            var r = stream.reader(io, buf);
            var w = stream.writer(io, &.{});
            while (true) {
                r.interface.fillMore() catch return;
                const data = r.interface.buffered();
                if (data.len == 0) continue;
                w.interface.writeAll(data) catch return;
                w.interface.flush() catch return;
                r.interface.tossBuffered();
            }
        },
        .sink => {
            var r = stream.reader(io, &.{});
            while (true) {
                const n = r.interface.readSliceShort(buf) catch return;
                if (n == 0) return;
            }
        },
        .source => {
            @memset(buf, 0);
            var w = stream.writer(io, &.{});
            while (true) {
                w.interface.writeAll(buf) catch return;
                w.interface.flush() catch return;
            }
        },
        .http => {
            // Minimal HTTP/1.1 framing: accumulate bytes in the reader's buffer,
            // emit one response per "\r\n\r\n" request terminator. fillMore does
            // exactly one read (readSliceShort would block until buf fills).
            var r = stream.reader(io, buf);
            var w = stream.writer(io, &.{});
            while (true) {
                while (std.mem.indexOf(u8, r.interface.buffered(), "\r\n\r\n")) |i| {
                    r.interface.toss(i + 4);
                    w.interface.writeAll(http_response) catch return;
                }
                w.interface.flush() catch return;
                r.interface.fillMore() catch return;
            }
        },
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const args = try init.args.toSlice(arena_state.allocator());

    var mode: Mode = .echo;
    var port: u16 = 18800;
    var iarg: usize = 1;
    while (iarg < args.len) : (iarg += 1) {
        const arg = args[iarg];
        if (std.mem.eql(u8, arg, "--zio") or std.mem.eql(u8, arg, "--zio-mt") or std.mem.eql(u8, arg, "--threaded")) {
            continue; // io backend selection, handled by IoBackend below
        } else if (std.mem.startsWith(u8, arg, "--mode=")) {
            mode = std.meta.stringToEnum(Mode, arg["--mode=".len..]) orelse {
                std.log.err("unknown mode '{s}'", .{arg});
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            port = try std.fmt.parseUnsigned(u16, arg["--port=".len..], 10);
        } else {
            std.log.err("usage: tcp_server [--zio | --zio-mt | --threaded] [--mode=echo|sink|source|http] [--port=N]", .{});
            std.process.exit(2);
        }
    }

    var backend: IoBackend = .none;
    try backend.init(gpa, init.args);
    defer backend.deinit();

    const io = backend.io();

    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    var srv = try addr.listen(io, .{ .reuse_address = true, .kernel_backlog = 4096 });
    defer srv.deinit(io);
    std.log.info("tcp_server listening on 127.0.0.1:{d} ({t})", .{ port, mode });

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = srv.accept(io) catch |err| {
            std.log.err("accept failed: {}", .{err});
            return;
        };
        // TCP_NODELAY: the std.Io interface doesn't expose it, so set it on the
        // raw fd (matters for the http request/response mode; harmless for the
        // driver modes).
        std.posix.setsockopt(stream.socket.handle, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
        group.concurrent(io, handler, .{ io, gpa, stream, mode }) catch {
            stream.close(io);
            return;
        };
    }
}
