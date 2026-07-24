const std = @import("std");

const App = @This();

io: std.Io,

pub fn only(app: App, args: []const []const u8, _:void) !void {
    var stdout_buffer: [1024]u8 = @splat(0);
    var stdout: std.Io.File.Writer = .init(.stdout(), app.io, &stdout_buffer);

    for (args, 1..) |arg, i| {
        try stdout.interface.print("{d}: {s}\n", .{ i, arg });
    }

    try stdout.interface.flush();
}
