const std = @import("std");
const zio = @import("zio");

pub const IoBackend = union(enum) {
    std_threaded: std.Io.Threaded,
    std_evented: std.Io.Evented,
    zio: *zio.Runtime,
    none: void,

    pub fn init(self: *IoBackend, gpa: std.mem.Allocator, args: std.process.Args) !void {
        var iter = args.iterate();
        while (iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--io")) {
                const name = iter.next() orelse return error.MissingArgument;
                if (std.mem.eql(u8, name, "zio")) {
                    std.log.info("Using zio", .{});
                    self.* = .{ .zio = try zio.Runtime.init(gpa, .{}) };
                } else if (std.mem.eql(u8, name, "threaded")) {
                    std.log.info("Using std.Io.Threaded", .{});
                    self.* = .{ .std_threaded = std.Io.Threaded.init(gpa, .{}) };
                } else {
                    return error.UnknownIoBackend;
                }
            }
        }
    }

    pub fn deinit(self: *IoBackend) void {
        switch (self.*) {
            .std_threaded => |*t| t.deinit(),
            .zio => |rt| rt.deinit(),
            else => {},
        }
    }

    pub fn io(self: *IoBackend) std.Io {
        switch (self.*) {
            .std_threaded => |*t| return t.io(),
            .zio => |rt| return rt.io(),
            else => @panic("TODO"),
        }
    }
};
