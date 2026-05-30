const std = @import("std");
const zio = @import("zio");

pub const IoBackend = union(enum) {
    std_threaded: std.Io.Threaded,
    // std_evented: std.Io.Evented, // broken in 0.16.0: error set mismatch in Uring.zig
    zio: *zio.Runtime,
    none: void,

    pub fn init(self: *IoBackend, gpa: std.mem.Allocator, args: std.process.Args) !void {
        var iter = args.iterate();
        while (iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--zio")) {
                std.log.info("Using zio (single-threaded)", .{});
                self.* = .{ .zio = try zio.Runtime.init(gpa, .{}) };
            } else if (std.mem.eql(u8, arg, "--zio-mt")) {
                std.log.info("Using zio (multi-threaded)", .{});
                self.* = .{ .zio = try zio.Runtime.init(gpa, .{ .executors = .auto }) };
            } else if (std.mem.eql(u8, arg, "--threaded")) {
                std.log.info("Using std.Io.Threaded", .{});
                self.* = .{ .std_threaded = std.Io.Threaded.init(gpa, .{}) };
            // } else if (std.mem.eql(u8, arg, "--evented")) {
            //     std.log.info("Using std.Io.Evented", .{});
            //     self.* = .{ .std_evented = undefined };
            //     try self.std_evented.init(gpa, .{});
            }
        }
    }

    pub fn deinit(self: *IoBackend) void {
        switch (self.*) {
            .std_threaded => |*t| t.deinit(),
            // .std_evented => |*e| e.deinit(),
            .zio => |rt| rt.deinit(),
            else => {},
        }
    }

    pub fn io(self: *IoBackend) std.Io {
        switch (self.*) {
            .std_threaded => |*t| return t.io(),
            // .std_evented => |*e| return e.io(),
            .zio => |rt| return rt.io(),
            .none => {
                std.debug.print("Usage: <benchmark> [--zio | --zio-mt | --threaded]\n", .{});
                std.process.exit(1);
            },
        }
    }
};
