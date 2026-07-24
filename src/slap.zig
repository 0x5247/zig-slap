const std = @import("std");
const builtin = @import("builtin");

const App = if (builtin.is_test) TestApp else @import("App.zig");

fn UnwrapOptional(comptime N: type) type {
    return switch (@typeInfo(N)) {
        .optional => |info| info.child,
        else => N,
    };
}

fn UnwrapPointer(comptime P: type) type {
    return switch (@typeInfo(P)) {
        .pointer => |info| info.child,
        else => P,
    };
}

fn setValue(comptime T: type, app: App, args_start: usize, args: []const []const u8) !struct { T, usize } {
    const U = UnwrapOptional(T);

    switch (U) {
        bool => return .{ true, args_start },
        []const u8 => {
            if (try std.math.sub(usize, args.len, args_start) < 1) return error.Invalid;
            return .{ args[args_start], args_start + 1 };
        },
        else => {},
    }

    const V = UnwrapPointer(U);

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
                ret[i], args_cur = try setValue(info.child, app, args_cur, args);
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

fn isOptTypeValid(comptime T: type) void {
    comptime {
        var letters: [26]bool = @splat(false);

        for (@typeInfo(T).@"struct".fields) |f| {
            for (f.name) |c| switch (c) {
                'a'...'z', '0'...'9', '_' => {},
                else => @compileError("field f.name '" ++ f.name ++ "' must be snake case"),
            };

            if (f.name.len < 2) {
                @compileError("field f.name '" ++ f.name ++ "' is too small");
            }

            if (!std.ascii.isAlphabetic(f.name[0])) {
                @compileError("feild f.name must start with an alphabet");
            }

            if (f.name[f.name.len - 1] == '_') {
                @compileError("feild f.name must not end with start with '_'");
            }

            if (f.type == bool and f.default_value_ptr == null) {
                @compileError("boolean fields must have default value");
            }

            if (letters[f.name[0] - 'a']) {
                @compileError("all fields must start with different letter");
            } else {
                letters[f.name[0] - 'a'] = true;
            }
        }
    }
}

fn fillOpts(comptime T: type, app: App, args_start: usize, args: []const []const u8) !struct { T, usize } {
    isOptTypeValid(T);

    const fields = @typeInfo(T).@"struct".fields;

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
                        try setValue(@FieldType(T, f.name), app, args_cur, args);

                    is_field_set[idx] = true;

                    break;
                }
            } else return error.Invalid;
        } else if (args[args_cur][0] == '-') {
            const flag = args[args_cur];
            args_cur += 1;

            for (flag[1..]) |c| {
                inline for (fields, 0..) |f, idx| {
                    if (f.name[0] == c) {
                        if (is_field_set[idx]) return error.Conflict;

                        @field(opts, f.name), args_cur =
                            try setValue(@FieldType(T, f.name), app, args_cur, args);

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

pub fn callFnFromArgs(func: anytype, app: App, args_start: usize, args: []const []const u8) !void {
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

    var args_cur: usize = args_start;

    if (@FieldType(ParamType, last) != void) {
        @field(params, last), args_cur =
            try fillOpts(@FieldType(ParamType, last), app, args_start, args);
    }

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
                    try setValue(@FieldType(ParamType, name), app, args_cur, args);
            },
        };

    return @call(.auto, func, params);
}

pub fn dispatch(app: App, args_start: usize, args: []const []const u8) !void {
    if (args.len -| args_start < 1) return error.Invalid;

    inline for (comptime std.meta.declarations(App)) |d| {
        if (std.meta.hasFn(App, d.name) and std.mem.eql(u8, d.name, args[args_start]))
            return callFnFromArgs(@field(App, d.name), app, args_start + 1, args);
    } else {
        // TODO print usage info
        return error.UnknownCommand;
    }
}

const TestApp = struct {
    gpa: std.mem.Allocator,
    n: ?*usize = null,

    const E = enum {
        abc,
        def,
        ghi,
    };

    fn init() TestApp {
        return .{
            .gpa = std.testing.allocator,
        };
    }

    pub fn foo(app: TestApp, e: E, name: []const u8, opts: struct {
        foo: f32,
        bar: bool = true,
        daz: ?u64 = null,
    }) void {
        if (e != std.meta.stringToEnum(E, name) orelse e and
            opts.foo == 67 and
            !opts.bar and
            opts.daz == null)
        {
            if (app.n) |n| {
                n.* = 32;
            }
        }
    }

    pub fn bar(_: void, _: void) void {}

    pub fn baz(_: void, v: usize, tail: []const []const u8, opts: struct {
        claw: u8,
    }) !void {
        if (v != 2) return error.Baz;
        if (opts.claw != 0) return error.Baz;
        if (tail.len != v - opts.claw) return error.Baz;

        if (!std.mem.eql(u8, tail[0], "boo") or !std.mem.eql(u8, tail[1], "bee"))
            return error.Baz;
    }
};

const Vec = struct {
    x: f32,
    y: f32,

    pub fn init(x: f32, y: f32) Vec {
        return .{ .x = x, .y = y };
    }

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

        var i: usize = 0;
        outer: while (i < str.len) {
            defer i += 1;

            for (std.ascii.whitespace) |c| {
                if (c == str[i]) continue :outer;
            }

            switch (state) {
                .start => if (str[i] != '(') {
                    if (args.len < 2) return error.Invalid;

                    dst.x = try std.fmt.parseFloat(f32, args[0]);
                    dst.y = try std.fmt.parseFloat(f32, args[1]);

                    return .{ dst, 2 };
                } else {
                    state = .first;
                },
                .first => {
                    const end = std.mem.findScalarPos(u8, str, i, ',') orelse return error.Invalid;

                    dst.x = try std.fmt.parseFloat(f32, std.mem.trim(u8, str[i..end], &std.ascii.whitespace));

                    i = end;
                    state = .second;
                },
                .second => {
                    const end = std.mem.findScalarPos(u8, str, i, ')') orelse return error.Invalid;

                    dst.y = try std.fmt.parseFloat(f32, std.mem.trim(u8, str[i..end], &std.ascii.whitespace));

                    i = end;
                    state = .end;
                },
                .end => return error.Invalid,
            }
        }

        return if (state != .end) error.Invalid else .{ dst, 1 };
    }
};

const Block = struct {
    vs: ?[]Vec = null,

    pub fn parseFromArgs(app: TestApp, args: []const []const u8) !struct { *Block, usize } {
        if (args.len < 1) return error.Invalid;

        const count = try std.fmt.parseUnsigned(usize, args[0], 0);

        const vs = try app.gpa.alloc(Vec, count);
        errdefer app.gpa.free(vs);

        var args_cur: usize = 1;
        for (vs) |*v| {
            v.*, const args_inc = try Vec.parseFromArgs(args[args_cur..]);
            args_cur += args_inc;
        }

        const ret = try app.gpa.create(Block);
        ret.vs = vs;

        return .{ ret, args_cur };
    }
};

const skip_test_set_value = false;
const skip_test_fill_opts = false;

test "set value: Vec" {
    if (skip_test_set_value) return error.SkipZigTest;

    const n = 3;

    const expected_output: [n]Vec = .{ .init(1.3, 3.9), .init(45.7, 0.001), .init(6.7, 4.2) };
    //const args: [n][]const u8 = .{ "(1.3,3.9)", "(45.7,0.001)", "(6.7,4.2)" };
    const args: [(n * 2) - 1][]const u8 = .{ "1.3", "3.9", "(45.7,0.001)", "6.7", "4.2" };

    var dsts: [n]Vec = @splat(undefined);

    var args_cur: usize = 0;
    var dsts_idx: usize = 0;
    while (args_cur < args.len and dsts_idx < dsts.len) : (dsts_idx += 1) {
        dsts[dsts_idx], args_cur = try setValue(Vec, .init(), args_cur, &args);
    }

    for (&expected_output, &dsts) |out, dst| {
        try std.testing.expectEqual(out.x, dst.x);
        try std.testing.expectEqual(out.y, dst.y);
    }

    try std.testing.expectEqual(args_cur, args.len);
}

test "set value: bool" {
    if (skip_test_set_value) return error.SkipZigTest;

    var dsts: [6]bool = @splat(false);

    var args_cur: usize = 0;
    var dsts_idx: usize = 0;
    while (args_cur == 0 and dsts_idx < dsts.len) : (dsts_idx += 1) {
        dsts[dsts_idx], args_cur = try setValue(bool, .init(), args_cur, &.{});
    }

    for (&dsts) |dst| {
        try std.testing.expect(dst);
    }
}

test "set value: array(i32)" {
    if (skip_test_set_value) return error.SkipZigTest;

    const n = 6;

    const expected_output: [n]i32 = .{ -13, -39, 457, -1, 67, 42 };
    const args: [n][]const u8 = .{ "-13", "-39", "457", "-1", "67", "42" };

    const dsts, const args_cur = try setValue([n]i32, .init(), 0, &args);

    for (&expected_output, &dsts) |out, dst| {
        try std.testing.expectEqual(out, dst);
    }

    try std.testing.expectEqual(args_cur, args.len);
}

test "set value: array(enum)" {
    if (skip_test_set_value) return error.SkipZigTest;

    const n = 6;
    const E = enum {
        abc,
        def,
        ghi,
        jkl,
    };

    const expected_output: [n]E = .{ .jkl, .def, .abc, .abc, .ghi, .abc };
    const args: [n][]const u8 = .{ "jkl", "def", "abc", "abc", "ghi", "abc" };

    const dsts, const args_cur = try setValue([n]E, .init(), 0, &args);

    for (&expected_output, &dsts) |out, dst| {
        try std.testing.expectEqual(out, dst);
    }

    try std.testing.expectEqual(args_cur, args.len);
}

test "set value: string" {
    if (skip_test_set_value) return error.SkipZigTest;

    const val, const args_cur = try setValue([]const u8, .init(), 0, &.{"foo"});

    try std.testing.expectEqualStrings(val, "foo");
    try std.testing.expectEqual(args_cur, 1);
}

test "set value: pointer" {
    if (skip_test_set_value) return error.SkipZigTest;

    const args: []const []const u8 = &.{ "2", "33.3", "78.9", "(88,90)" };

    const val, const args_cur = try setValue(*Block, .init(), 0, args);
    defer {
        const gpa = std.testing.allocator;
        if (val.vs) |vs| gpa.free(vs);
        gpa.destroy(val);
    }

    try std.testing.expectEqual(args_cur, args.len);

    const vs = val.vs orelse return error.Null;

    try std.testing.expectEqual(vs.len, 2);
    try std.testing.expectEqualDeep(vs, @as([]const Vec, &.{ .{ .x = 33.3, .y = 78.9 }, .{ .x = 88, .y = 90 } }));
}

test "fill opts" {
    if (skip_test_fill_opts) return error.SkipZigTest;

    const Opts = struct {
        name: []const u8 = "blep",
        zap: usize,
        vec: Vec,
        boo_bee: enum {
            foo,
            bar,
            baz,
        },
        goop: [4]u8,
    };

    const cases: []const struct { []const []const u8, Opts } = &.{
        .{
            &.{
                "--name",
                "blip",
                "--boo-bee",
                "foo",
                "--vec",
                "(3.2,66)",
                "--zap",
                "44",
                "--goop",
                "0x7f",
                "0",
                "0",
                "1",
            },
            .{
                .name = "blip",
                .zap = 44,
                .vec = .{ .x = 3.2, .y = 66 },
                .boo_bee = .foo,
                .goop = .{ 127, 0, 0, 1 },
            },
        },
        .{
            &.{
                "--boo-bee",
                "baz",
                "--vec",
                "(3.0,7)",
                "--zap",
                "77",
                "--goop",
                "255",
                "0o77",
                "0",
                "100",
            },
            .{
                .zap = 77,
                .vec = .{ .x = 3.0, .y = 7 },
                .boo_bee = .baz,
                .goop = .{ 0xff, 0o77, 0, 100 },
            },
        },
    };

    for (cases) |case| {
        try std.testing.expectEqualDeep(.{ case.@"1", case.@"0".len }, try fillOpts(Opts, .init(), 0, case.@"0"));
    }
}

test "fiil opts short" {
    if (skip_test_fill_opts) return error.SkipZigTest;

    const Opts = struct {
        zap: usize,
        boo_bee: enum {
            foo,
            bar,
            baz,
        },
        goop: [4]u8,
        vec: Vec,
    };

    const args: []const []const u8 = &.{ "-bgz", "bar", "67", "68", "69", "42", "420", "--vec", "(56, 6.7)" };
    const target: Opts = .{
        .zap = 420,
        .boo_bee = .bar,
        .goop = .{ 67, 68, 69, 42 },
        .vec = .{ .x = 56, .y = 6.7 },
    };

    try std.testing.expectEqualDeep(.{ target, args.len }, try fillOpts(Opts, .init(), 0, args));
}

test "fill opts 2" {
    if (skip_test_fill_opts) return error.SkipZigTest;

    const Opts = struct {
        name: []const u8 = "blep",
        zap: usize,
        vec: Vec,
        boo_bee: enum {
            foo,
            bar,
            baz,
        },
        goop: [4]u8,
    };

    const cases: []const struct { []const []const u8, Opts } = &.{
        .{
            &.{
                "--name",
                "blip",
                "--boo-bee",
                "foo",
                "--vec",
                "(3.2,66)",
                "--zap",
                "44",
                "--goop",
                "0x7f",
                "0",
                "0",
                "1",
            },
            .{
                .name = "blip",
                .zap = 44,
                .vec = .{ .x = 3.2, .y = 66 },
                .boo_bee = .foo,
                .goop = .{ 127, 0, 0, 1 },
            },
        },
        .{
            &.{
                "--boo-bee",
                "baz",
                "--vec",
                "(3.0,7)",
                "--zap",
                "77",
                "--goop",
                "255",
                "0o77",
                "0",
                "100",
            },
            .{
                .zap = 77,
                .vec = .{ .x = 3.0, .y = 7 },
                .boo_bee = .baz,
                .goop = .{ 0xff, 0o77, 0, 100 },
            },
        },
    };

    for (cases) |case| {
        try std.testing.expectEqualDeep(.{ case.@"1", case.@"0".len }, try fillOpts(Opts, .init(), 0, case.@"0"));
    }
}

test "fill opts tail" {
    if (skip_test_fill_opts) return error.SkipZigTest;

    const Opts = struct {
        we_can_be: i16,
        so_hot: u8,
        hot_together: u32,

        larp: i64 = 556,
    };

    const args: []const []const u8 = &.{ "-wsh", "56", "255", "78", "--", "--larp", "557" };
    const target: Opts = .{
        .we_can_be = 56,
        .so_hot = 255,
        .hot_together = 78,
        .larp = 556,
    };

    try std.testing.expectEqualDeep(.{ target, args.len - 2 }, try fillOpts(Opts, .init(), 0, args));

    const tail = args[args.len - 2 ..];

    try std.testing.expectEqualStrings(tail[0], "--larp");
    try std.testing.expectEqualStrings(tail[1], "557");
}

test "fill opts tail 2" {
    if (skip_test_fill_opts) return error.SkipZigTest;

    const Opts = struct {
        we_can_be: i16,
        so_hot: ?u8,
        hot_together: u32,

        larp: i64 = 556,
    };

    const args: []const []const u8 = &.{ "-wsh", "56", "255", "78", "larp", "557" };
    const target: Opts = .{
        .we_can_be = 56,
        .so_hot = 255,
        .hot_together = 78,
        .larp = 556,
    };

    try std.testing.expectEqualDeep(.{ target, args.len - 2 }, try fillOpts(Opts, .init(), 0, args));

    const tail = args[args.len - 2 ..];

    try std.testing.expectEqualStrings(tail[0], "larp");
    try std.testing.expectEqualStrings(tail[1], "557");
}

test "fill opts bool" {
    if (skip_test_fill_opts) return error.SkipZigTest;

    const Opts = struct {
        somebody: bool = false,
        found_us: bool = true,
        dancing: bool = false,
    };

    const opt1, _ = try fillOpts(Opts, .init(), 0, &.{});

    const opt2, _ = try fillOpts(Opts, .init(), 0, &.{"-f"});

    const opt3, _ = try fillOpts(Opts, .init(), 0, &.{"-fsd"});

    try std.testing.expectEqualDeep(opt1, @as(Opts, .{}));
    try std.testing.expectEqualDeep(opt2, @as(Opts, .{ .found_us = false }));
    try std.testing.expectEqualDeep(opt3, @as(Opts, .{ .somebody = true, .found_us = false, .dancing = true }));
}

test "dispatch 0" {
    std.testing.log_level = .debug;

    var number: usize = 0;

    const app: App = .{ .gpa = std.testing.allocator, .n = &number };
    try dispatch(app, 0, &.{ "foo", "-f", "67", "--bar", "--", "def", "ghi" });

    try std.testing.expectEqual(number, 32);
}

test "dispatch 1" {
    try dispatch(.init(), 0, &.{"bar"});
}

test "dispatch 2" {
    try dispatch(.init(), 0, &.{"baz", "--claw", "0", "2", "boo", "bee"});
}
