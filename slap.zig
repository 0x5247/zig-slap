const std = @import("std");

fn setValue(
    comptime App: type,
    comptime T: type,
    app: App,
    args_start: usize,
    args: []const []const u8,
) !struct { T, usize } {
    const U = switch (@typeInfo(T)) {
        .optional => |info| info.child,
        else => T,
    };

    switch (U) {
        bool => return .{ true, args_start },
        []const u8 => {
            if (try std.math.sub(usize, args.len, args_start) < 1) return error.Invalid;
            return .{ args[args_start], args_start + 1 };
        },
        else => {},
    }

    const V = switch (@typeInfo(U)) {
        .pointer => |info| info.child,
        else => U,
    };

    if (std.meta.hasFn(V, "parseFromArgs")) {
        const FnType = @TypeOf(V.parseFromArgs);
        const ReturnType = @typeInfo(FnType).@"fn".return_type.?;

        const fn_args = switch (std.meta.ArgsTuple(FnType)) {
            struct { App, []const []const u8 } => .{ app, args[args_start..] },
            struct { []const []const u8 } => .{args[args_start..]},
            else => @compileError("wrong function signature for parseFromArgs method"),
        };

        const val, const args_inc = switch (@typeInfo(ReturnType)) {
            .error_union => try @call(.auto, V.parseFromArgs, fn_args),
            else => @call(.auto, V.parseFromArgs, fn_args),
        };

        return .{ val, try std.math.add(usize, args_start, args_inc) };
    }

    const type_type: enum {
        signed_int,
        unsigned_int,
        float,
        @"enum",
    } = switch (@typeInfo(U)) {
        .int => |info| switch (info.signedness) {
            .signed => .signed_int,
            .unsigned => .unsigned_int,
        },
        .float => .float,
        .@"enum" => .@"enum",
        inline .array, .vector => |info| {
            if (info.child == bool) @compileError("invalid field type");

            var ret: U = undefined;

            var args_cur = args_start;
            for (0..info.len) |i| {
                ret[i], args_cur = try setValue(App, info.child, app, args_cur, args);
            }

            return .{ ret, args_cur };
        },
        else => @compileError("invalid field type"),
    };

    if (args.len - args_start < 1) return error.Invalid;

    return .{ switch (type_type) {
        .signed_int => try std.fmt.parseInt(U, args[args_start], 0),
        .unsigned_int => try std.fmt.parseUnsigned(U, args[args_start], 0),
        .float => try std.fmt.parseFloat(U, args[args_start]),
        .@"enum" => std.meta.stringToEnum(U, args[args_start]) orelse return error.Invalid,
    }, args_start + 1 };
}

pub const Config = struct {
    enable_flag_alias: bool = true,
};

fn setFlags(
    comptime App: type,
    comptime T: type,
    app: App,
    args_start: usize,
    args: []const []const u8,
    comptime config: Config,
) !struct { T, usize } {
    const fields = @typeInfo(T).@"struct".fields;

    comptime {
        for (fields) |f| {
            for (f.name) |c| switch (c) {
                'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
                else => @compileError("field name contains invalid characters"),
            };

            if (f.name.len < 2) {
                @compileError("field name '" ++ f.name ++ "' is too small");
            }

            if (!std.ascii.isAlphabetic(f.name[0])) {
                @compileError("feild name must start with an alphabet");
            }

            if (f.name[f.name.len - 1] == '_') {
                @compileError("feild name must not end with start with '_'");
            }

            if (f.type == bool and f.default_value_ptr == null) {
                @compileError("boolean fields must have default value");
            }
        }

        if (config.enable_flag_alias) {
            var letters: struct {
                tbl: [26 * 26]bool = @splat(false),

                fn check(self: *@This(), c: u8) void {
                    const idx = switch (c) {
                        'a'...'z' => c - 'a',
                        'A'...'Z' => 26 + c - 'A',
                        else => unreachable,
                    };

                    if (self.tbl[idx]) @compileError("all fields must start with different letter");
                    self.tbl[idx] = true;
                }
            } = .{};

            for (fields) |f| letters.check(f.name[0]);
        }
    }

    var is_field_set: [fields.len]bool = @splat(false);

    var opts: T = undefined;

    var args_cur = args_start;
    while (args_cur < args.len) {
        if (std.mem.startsWith(u8, args[args_cur], "--")) {
            const flag = args[args_cur][2..];
            args_cur += 1;

            if (flag.len == 0) break;

            inline for (fields, 0..) |f, idx| {
                if (std.mem.eql(u8, comptime blk: {
                    var buf: [f.name.len]u8 = undefined;
                    for (f.name, 0..) |c, i| {
                        buf[i] = if (c == '_') '-' else c;
                    }

                    const bu2 = buf;
                    break :blk &bu2;
                }, flag)) {
                    if (is_field_set[idx]) return error.Conflict;

                    @field(opts, f.name), args_cur =
                        try setValue(App, @FieldType(T, f.name), app, args_cur, args);

                    is_field_set[idx] = true;

                    break;
                }
            } else return error.Invalid;
        } else if (config.enable_flag_alias and args[args_cur][0] == '-') {
            const flag = args[args_cur];
            args_cur += 1;

            for (flag[1..]) |c| {
                inline for (fields, 0..) |f, idx| {
                    if (f.name[0] == c) {
                        if (is_field_set[idx]) return error.Conflict;

                        @field(opts, f.name), args_cur =
                            try setValue(App, @FieldType(T, f.name), app, args_cur, args);

                        is_field_set[idx] = true;

                        break;
                    }
                } else return error.Invalid;
            }
        } else {
            break;
        }
    }

    inline for (&is_field_set, fields) |s, f| if (!s) {
        @field(opts, f.name) = f.defaultValue() orelse return error.Invalid;
    } else if (f.type == bool) {
        @field(opts, f.name) = !f.defaultValue().?;
    };

    return .{ opts, args_cur };
}

pub fn invokeFromArgs(
    comptime App: type,
    func: anytype,
    app: App,
    args_start: usize,
    args: []const []const u8,
    comptime config: Config,
) !void {
    const ParamType = std.meta.ArgsTuple(@TypeOf(func));
    const field_names = comptime std.meta.fieldNames(ParamType);

    if (field_names.len < 2) {
        @compileError("function type invalid");
    }

    var params: ParamType = undefined;

    const first = field_names[0];
    const last = field_names[field_names.len - 1];

    if (@FieldType(ParamType, first) != void) {
        @field(params, first) = app;
    }

    var args_cur = args_start;

    @field(params, last), args_cur =
        try setFlags(App, @FieldType(ParamType, last), app, args_start, args, config);

    inline for (field_names[1 .. field_names.len - 1], 1..) |name, i|
        switch (@FieldType(ParamType, name)) {
            bool => @compileError("invalid param type"),
            []const []const u8 => {
                if (i != field_names.len - 2) @compileError("invalid param type");
                @field(params, name) = args[args_cur..];
                break;
            },
            else => {
                @field(params, name), args_cur =
                    try setValue(App, @FieldType(ParamType, name), app, args_cur, args);
            },
        };

    return @call(.auto, func, params);
}

pub fn dispatch(
    comptime App: type,
    app: App,
    args_start: usize,
    args: []const []const u8,
    comptime config: Config,
) !void {
    if (args.len -| args_start < 1) return error.Invalid;

    inline for (comptime std.meta.declarations(App)) |d| {
        if (std.meta.hasFn(App, d.name) and std.mem.eql(u8, d.name, args[args_start]))
            return invokeFromArgs(App, @field(App, d.name), app, args_start + 1, args, config);
    } else {
        // TODO print usage info
        return error.UnknownCommand;
    }
}

const TestApp = struct {
    gpa: std.mem.Allocator,
    n: ?*usize = null,

    fn init() TestApp {
        return .{
            .gpa = std.testing.allocator,
        };
    }

    pub fn cmd0(_: void, _: struct {}) void {}

    pub fn cmd1(_: void, args: []const []const u8, _: struct {}) !void {
        try std.testing.expectEqual(4, args.len);
        try std.testing.expectEqualStrings("foo", args[0]);
        try std.testing.expectEqualStrings("bar", args[1]);
        try std.testing.expectEqualStrings("baz", args[2]);
        try std.testing.expectEqualStrings("bat", args[3]);
    }

    pub fn cmd2(app: TestApp, flags: struct {
        een: E,
        name: []const u8,
        foo: f32,
        bar: bool = true,
        daz: ?u64 = null,
    }) void {
        if (flags.een != std.meta.stringToEnum(E, flags.name) orelse flags.een and
            flags.foo == 67 and
            !flags.bar and
            flags.daz == null)
        {
            app.n.?.* = 32;
        }
    }

    pub fn cmd3(_: void, n: usize, tail: []const []const u8, flags: struct {
        magic_claw: u8,
    }) !void {
        try std.testing.expectEqual(n + flags.magic_claw, tail.len);

        for (tail) |arg| {
            try std.testing.expectEqualStrings("aaa", arg);
        }
    }

    pub fn cmd4(_: void, tail: []const []const u8, flags: struct {
        qwerty: ?u32 = null,
        wertyq: ?u32 = null,
        ertyqw: ?u32 = null,
        rtyqwe: ?u32 = null,
    }) !void {
        try std.testing.expectEqual(null, flags.qwerty);
        try std.testing.expectEqual(null, flags.wertyq);
        try std.testing.expectEqual(10, flags.ertyqw);
        try std.testing.expectEqual(20, flags.rtyqwe);

        try std.testing.expectEqual(3, tail.len);
        try std.testing.expectEqualStrings("--qwe", tail[0]);
        try std.testing.expectEqualStrings("rty", tail[1]);
        try std.testing.expectEqualStrings("--uio", tail[2]);
    }
};

const Vec = union(enum) {
    float: struct {
        x: f32,
        y: f32,
    },
    int: struct {
        x: i32,
        y: i32,
    },

    pub fn parseFromArgs(args: []const []const u8) !struct { Vec, usize } {
        if (args.len < 1) return error.Invalid;

        const str = args[0];

        var dst: Vec = undefined;

        var state: enum {
            start,
            first,
            second,
            end,
        } = .start;

        var idx: usize = 0;
        outer: while (idx < str.len) {
            defer idx += 1;

            for (std.ascii.whitespace) |c| {
                if (c == str[idx]) continue :outer;
            }

            switch (state) {
                .start => {
                    dst = switch (str[idx]) {
                        '(' => .{ .float = undefined },
                        '[' => .{ .int = undefined },
                        else => return error.Invalid,
                    };

                    state = .first;
                },
                .first => {
                    const end = std.mem.findScalarPos(u8, str, idx, ',') orelse return error.Invalid;

                    const arg = std.mem.trim(u8, str[idx..end], &std.ascii.whitespace);

                    switch (dst) {
                        .float => |*f| f.x = try std.fmt.parseFloat(f32, arg),
                        .int => |*i| i.x = try std.fmt.parseInt(i32, arg, 10),
                    }

                    idx = end;
                    state = .second;
                },
                .second => {
                    const end = std.mem.findScalarPos(u8, str, idx, switch (dst) {
                        .float => ')',
                        .int => ']',
                    }) orelse return error.Invalid;

                    const arg = std.mem.trim(u8, str[idx..end], &std.ascii.whitespace);

                    switch (dst) {
                        .float => |*f| f.y = try std.fmt.parseFloat(f32, arg),
                        .int => |*i| i.y = try std.fmt.parseInt(i32, arg, 10),
                    }

                    idx = end;
                    state = .end;
                },
                .end => return error.Invalid,
            }
        }

        return if (state != .end) error.Invalid else .{ dst, 1 };
    }
};

const FileLocation = struct {
    path: []const u8,
    line: u32,
    col: u32,

    pub fn parseFromArgs(app: TestApp, args: []const []const u8) !struct { []FileLocation, usize } {
        var list: std.ArrayList(FileLocation) = .empty;
        defer list.deinit(app.gpa);

        var args_cur: usize = 0;
        for (args) |arg| {
            if (arg.len == 0 or (arg[0] == '-' and std.mem.countScalar(u8, arg, ':') == 0)) break;

            var loc: FileLocation = .{
                .path = &.{},
                .line = 0,
                .col = 0,
            };

            var cur = std.mem.findScalar(u8, arg, ':') orelse return error.Invalid;
            loc.path = arg[0..cur];

            if (cur < arg.len) {
                const c = std.mem.findScalarPos(u8, arg, cur + 1, ':') orelse return error.Invalid;

                loc.line = try std.fmt.parseUnsigned(u32, arg[cur + 1 .. c], 10);
                cur = c;
            }

            loc.col = try std.fmt.parseUnsigned(u32, arg[cur + 1 ..], 10);

            if (loc.line == 0 or loc.col == 0) {
                return error.Invalid;
            }

            try list.append(app.gpa, loc);

            args_cur += 1;
        }

        return .{ try list.toOwnedSlice(app.gpa), args_cur };
    }
};

const E = enum {
    abc,
    def,
    ghi,
};

test "set value" {
    var args_cur: usize = 0;

    const args: []const []const u8 = &.{
        "0xffff",          "-54",        "7781",          "900",
        "(45.7, 67)",      "[89, 40]",   "[0,9]",         "abc",
        "def",             "ghi",        "foobar",        "doover",
        "slap.zig:414:11", "foo.c:77:9", "bar.txt:99:99", "baz.go:56:8",
    };

    const val0, args_cur = try setValue(void, u16, {}, args_cur, args);
    try std.testing.expectEqual(65535, val0);

    const val1, args_cur = try setValue(void, [3]i32, {}, args_cur, args);
    try std.testing.expectEqualDeep(@as([3]i32, .{ -54, 7781, 900 }), val1);

    const val2, args_cur = try setValue(void, [3]Vec, {}, args_cur, args);
    try std.testing.expectEqualDeep(@as([3]Vec, .{
        .{ .float = .{ .x = 45.7, .y = 67 } },
        .{ .int = .{ .x = 89, .y = 40 } },
        .{ .int = .{ .x = 0, .y = 9 } },
    }), val2);

    const val3, args_cur = try setValue(void, ?[3]E, {}, args_cur, args);
    try std.testing.expectEqualDeep(@as([3]E, .{ .abc, .def, .ghi }), val3 orelse error.Null);

    const val4, args_cur = try setValue(void, []const u8, {}, args_cur, args);
    try std.testing.expectEqualStrings("foobar", val4);

    const val5, args_cur = try setValue(void, []const u8, {}, args_cur, args);
    try std.testing.expectEqualStrings("doover", val5);

    const app: TestApp = .{ .gpa = std.testing.allocator };

    const val6, args_cur = try setValue(TestApp, ?[]FileLocation, app, args_cur, args);
    if (val6) |v| {
        defer app.gpa.free(v);

        try std.testing.expectEqualDeep(@as([]const FileLocation, &.{
            .{ .path = "slap.zig", .line = 414, .col = 11 },
            .{ .path = "foo.c", .line = 77, .col = 9 },
            .{ .path = "bar.txt", .line = 99, .col = 99 },
            .{ .path = "baz.go", .line = 56, .col = 8 },
        }), v);
    } else return error.Null;

    try std.testing.expectEqual(args.len, args_cur);

    var val7: [255]bool = undefined;
    for (&val7) |*v| {
        v.*, args_cur = try setValue(void, bool, {}, args_cur, args);
    }

    try std.testing.expectEqualDeep(@as([255]bool, @splat(true)), val7);

    try std.testing.expectEqual(args.len, args_cur);
}

test "set flags" {
    const app: TestApp = .{ .gpa = std.testing.allocator };

    const Flags = struct {
        Files: []FileLocation,
        strings: [3][]const u8,
        number: isize,
        lAbel: enum {
            bar,
            car,
            far,
        },
        option: bool = false,
    };

    const Flags2 = struct {
        flare: u32,
        fair: u128,
        fare: u128,
    };

    const args: []const []const u8 = &.{
        "-F",           "--shh.js:55:1",
        "main.go:54:9", "index.html:89:7",
        "--strings",    "foo",
        "bar",          "baz",
        "--number",     "-777",
        "--lAbel",      "far",
        "--option",     "--",
        "--flare",      "33",
        "--fair",       "32",
        "--fare",       "45",
    };

    const flags, var args_cur = try setFlags(TestApp, Flags, app, 0, args, .{});
    defer app.gpa.free(flags.Files);

    try std.testing.expectEqualDeep(@as([]const FileLocation, &.{
        .{ .path = "--shh.js", .line = 55, .col = 1 },
        .{ .path = "main.go", .line = 54, .col = 9 },
        .{ .path = "index.html", .line = 89, .col = 7 },
    }), flags.Files);

    try std.testing.expectEqualDeep(@as([3][]const u8, .{ "foo", "bar", "baz" }), flags.strings);

    try std.testing.expectEqual(-777, flags.number);

    try std.testing.expectEqual(.far, flags.lAbel);

    try std.testing.expect(flags.option);

    const flags2, args_cur = try setFlags(void, Flags2, {}, args_cur, args, .{ .enable_flag_alias = false });

    try std.testing.expectEqualDeep(@as(Flags2, .{
        .flare = 33,
        .fair = 32,
        .fare = 45,
    }), flags2);

    try std.testing.expectEqual(args.len, args_cur);
}

test "dispatch" {
    var number: usize = 0;
    const app: TestApp = .{ .gpa = std.testing.allocator, .n = &number };

    try dispatch(TestApp, app, 0, &.{"cmd0"}, .{});

    try dispatch(TestApp, app, 0, &.{ "cmd1", "foo", "bar", "baz", "bat" }, .{});

    try dispatch(TestApp, app, 0, &.{ "cmd2", "-en", "abc", "def", "--foo", "67", "--bar" }, .{});
    try std.testing.expectEqual(number, 32);

    try dispatch(TestApp, app, 0, &.{
        "cmd3", "--magic-claw", "3",   "5",
        "aaa",  "aaa",          "aaa", "aaa",
        "aaa",  "aaa",          "aaa", "aaa",
    }, .{});

    try dispatch(TestApp, app, 0, &.{ "cmd4", "-er", "10", "20", "--", "--qwe", "rty", "--uio" }, .{});
}
