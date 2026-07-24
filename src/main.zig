const std = @import("std");

const App = @import("App.zig");
const slap = @import("slap.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    const app: App = .{ .io = init.io };

    try slap.dispatch(app, 1, args);
}
