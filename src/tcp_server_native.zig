const std = @import("std");
const zio = @import("zio");

// TCP benchmark subject (native zio API), driven by driver/tcp_driver.go.
// Accepts connections forever (the bench runner kills the process); one task
// per connection. Modes:
//
//   echo    write back whatever arrives (works with driver pipelining)
//   sink    read and discard until EOF
//   source  write zeros until the client closes
//   http    minimal HTTP/1.1 keep-alive: read a request, write a fixed
//           "HelloWorld" response. Drive this one with wrk, not the driver.
//
// usage: tcp_server_native [--zio | --zio-mt] [--mode=echo|sink|source|http] [--port=N]
const buf_size = 64 * 1024;

const http_response = "HTTP/1.1 200 Ok\r\nContent-Length: 10\r\nContent-Type: text/plain; charset=utf8\r\n\r\nHelloWorld";

const Mode = enum { echo, sink, source, http };

fn handler(gpa: std.mem.Allocator, stream: zio.net.Stream, mode: Mode) void {
    defer stream.close();
    const buf = gpa.alloc(u8, buf_size) catch return;
    defer gpa.free(buf);

    switch (mode) {
        .echo => {
            while (true) {
                const n = stream.read(buf, .none) catch return;
                if (n == 0) return;
                stream.writeAll(buf[0..n], .none) catch return;
            }
        },
        .sink => {
            while (true) {
                const n = stream.read(buf, .none) catch return;
                if (n == 0) return;
            }
        },
        .source => {
            @memset(buf, 0);
            while (true) {
                stream.writeAll(buf, .none) catch return;
            }
        },
        .http => {
            // Minimal HTTP/1.1 framing: accumulate bytes and emit one response
            // per "\r\n\r\n" request terminator, shifting consumed bytes out.
            // Handles partial reads and requests that coalesce into one read.
            var end: usize = 0;
            while (true) {
                while (std.mem.indexOf(u8, buf[0..end], "\r\n\r\n")) |i| {
                    const consumed = i + 4;
                    std.mem.copyForwards(u8, buf[0 .. end - consumed], buf[consumed..end]);
                    end -= consumed;
                    stream.writeAll(http_response, .none) catch return;
                }
                const n = stream.read(buf[end..], .none) catch return;
                if (n == 0) return;
                end += n;
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
    var mt = false;
    var have_backend = false;
    var iarg: usize = 1;
    while (iarg < args.len) : (iarg += 1) {
        const arg = args[iarg];
        if (std.mem.eql(u8, arg, "--zio")) {
            have_backend = true;
        } else if (std.mem.eql(u8, arg, "--zio-mt")) {
            have_backend = true;
            mt = true;
        } else if (std.mem.startsWith(u8, arg, "--mode=")) {
            mode = std.meta.stringToEnum(Mode, arg["--mode=".len..]) orelse {
                std.log.err("unknown mode '{s}'", .{arg});
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            port = try std.fmt.parseUnsigned(u16, arg["--port=".len..], 10);
        } else {
            std.log.err("usage: tcp_server_native [--zio | --zio-mt] [--mode=echo|sink|source|http] [--port=N]", .{});
            std.process.exit(2);
        }
    }
    if (!have_backend) {
        std.debug.print("usage: tcp_server_native [--zio | --zio-mt] [--mode=echo|sink|source|http] [--port=N]\n", .{});
        std.process.exit(2);
    }

    const rt = try zio.Runtime.init(gpa, if (mt) .{ .executors = .auto } else .{});
    defer rt.deinit();

    const addr = try zio.net.IpAddress.parseIp4("127.0.0.1", port);
    var srv = try addr.listen(.{ .reuse_address = true, .kernel_backlog = 4096 });
    defer srv.close();
    std.log.info("tcp_server_native listening on 127.0.0.1:{d} ({t})", .{ port, mode });

    var group: zio.Group = .init;
    defer group.cancel();
    while (true) {
        const stream = srv.accept(.{}) catch |err| {
            std.log.err("accept failed: {}", .{err});
            return;
        };
        stream.socket.setNoDelay(true) catch {};
        group.spawn(handler, .{ gpa, stream, mode }) catch {
            stream.close();
            return;
        };
    }
}
