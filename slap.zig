const std = @import("std");

fn compileLog(arg: anytype) void {
    if (false) @compileLog(arg);
}

pub fn FlagsConfig(comptime T: type) type {
    return struct {
        /// add short flags for defaults
        /// enabling this will limit the
        /// possible field names and count
        /// if no custom flags are given
        add_short_flags: bool = false,

        /// comma seperated custom flags
        /// for a field empty means
        /// auto generate from field name
        flags: StringFieldStruct(T) = .{},

        /// short description about the field
        /// will be used for making usage info
        infos: StringFieldStruct(T) = .{},
    };
}

/// dispatch the right command (function) through cli arguments
/// commands are functions declarated to the App type
pub fn dispatch(
    comptime App: type,
    app: App,
    args_start: usize,
    args: []const []const u8,
) !void {
    if (args.len -| args_start < 1) return error.Invalid;

    inline for (comptime std.meta.declarations(App)) |d| {
        if (std.meta.hasFn(App, d.name) and std.mem.eql(u8, d.name, args[args_start]))
            return invoke(App, app, @field(App, d.name), args_start + 1, args);
    } else {
        // TODO print usage info
        return error.UnknownCommand;
    }
}

/// invoke the given function taking
/// parameters from cli arguments
pub fn invoke(
    comptime App: type,
    app: App,
    func: anytype,
    args_start: usize,
    args: []const []const u8,
) !void {
    const Param = std.meta.ArgsTuple(@TypeOf(func));

    var params: Param = undefined;

    if (@FieldType(Param, "0") != void) params.@"0" = app;

    var args_cur = args_start;

    if (@FieldType(Param, "1") != void) params.@"1", args_cur =
        try setFields(App, @FieldType(Param, "1"), app, args_start, args);

    inline for (comptime std.meta.fieldNames(Param)[2..]) |name| @field(params, name), args_cur =
        try setValue(App, @FieldType(Param, name), app, args_cur, args);

    return @call(.auto, func, params);
}

/// Set the value for each field
/// flags are loaded at compile time
/// long flags must be prefixed with '--'
/// and short flags must be prefixed with '-'
///
/// Short flags can be chained
/// For example:-
///     -a 100 -b 155
///   is equvilent to
///     -ab 100 155
///
/// Booleans must have default values
fn setFields(
    comptime App: type,
    comptime T: type,
    app: App,
    args_start: usize,
    args: []const []const u8,
) !struct { T, usize } {
    const long_flags, const short_flags = comptime fieldFlags(T);

    var is_field_set: @Struct(
        .auto,
        null,
        std.meta.fieldNames(T),
        &@splat(bool),
        &@splat(.{ .default_value_ptr = @ptrCast(&@as(bool, false)) }),
    ) = .{};

    var ret: T = undefined;

    var args_cur = args_start;
    while (args_cur < args.len) {
        if (std.mem.startsWith(u8, args[args_cur], "--")) {
            const arg = args[args_cur][2..];
            args_cur += 1;

            if (arg.len == 0) break;

            inline for (&long_flags) |long_flag| {
                const flag, const field = long_flag;

                if (std.mem.eql(u8, arg, flag)) {
                    if (@field(is_field_set, field)) return error.Conflict;

                    if (@FieldType(T, field) != bool) {
                        @field(ret, field), args_cur =
                            try setValue(App, @FieldType(T, field), app, args_cur, args);
                    }

                    @field(is_field_set, field) = true;

                    break;
                }
            } else {
                return error.InvalidFlag;
            }
        } else if (args.len > 1 and args[args_cur][0] == '-') {
            const arg = args[args_cur][1..];
            args_cur += 1;

            for (arg) |c| {
                inline for (&short_flags) |short_flag| {
                    const flag, const field = short_flag;

                    if (c == flag) {
                        if (@field(is_field_set, field)) return error.Conflict;

                        if (@FieldType(T, field) != bool) {
                            @field(ret, field), args_cur =
                                try setValue(App, @FieldType(T, field), app, args_cur, args);
                        }

                        @field(is_field_set, field) = true;

                        break;
                    }
                } else {
                    return error.InvalidFlag;
                }
            }
        } else {
            break;
        }
    }

    inline for (comptime std.meta.fieldNames(T), @typeInfo(T).@"struct".fields) |field, field_info| {
        if (!@field(is_field_set, field)) {
            @field(ret, field) = field_info.defaultValue() orelse return error.MissingFlag;
        } else if (field_info.type == bool) {
            @field(ret, field) =
                !(field_info.defaultValue() orelse @compileError("boolean fields must have default value"));
        }
    }

    return .{ ret, args_cur };
}

/// Set a value through cli argumnts
/// can handle premitive types like
/// ints, floats, enums, and strings
/// and any type that has `parseFromArgs`
/// method. Optional types are handled
/// and if the type is array, this
/// function is called for each element
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
        []const u8 => {
            if (try std.math.sub(usize, args.len, args_start) < 1) return error.Invalid;
            return .{ args[args_start], args_start + 1 };
        },
        []const []const u8 => return .{ args[args_start..], args.len },
        else => {},
    }

    const V = switch (@typeInfo(U)) {
        inline .pointer, .vector => |info| info.child,
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
        .array => |info| {
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

/// Loads the cli flags for each field
/// flags are taken from T.flags_config.flags
/// single character flags will be short flags
///
/// If T.flags_config is not declared or
/// if the flag set for that field is empty,
/// the flag will be the field name but the
/// underscores are replaced with hyphens
/// and a short flag will also be added if
/// T.add_short_flags is set to true
fn fieldFlags(comptime T: type) struct {
    [fieldFlagsCount(T)[0]][2][]const u8,
    [fieldFlagsCount(T)[1]]struct { u8, []const u8 },
} {
    const long_count, const short_count = fieldFlagsCount(T);

    var long: [long_count][2][]const u8 = @splat(.{ &.{}, &.{} });
    var short: [short_count]struct { u8, []const u8 } = @splat(.{ 0, &.{} });

    var long_idx = 0;
    var short_idx = 0;

    const flags_config: FlagsConfig(T) = if (@hasDecl(T, "flags_config")) T.flags_config else .{};

    for (std.meta.fieldNames(T)) |key| {
        const flag_set = @field(flags_config.flags, key);

        if (flag_set.len != 0) {
            var idx = 0;
            while (idx < flag_set.len) {
                const len = std.mem.findScalarPos(u8, flag_set, idx, ',') orelse flag_set.len;
                defer idx = len + 1;

                if (len - idx != 1) {
                    long[long_idx][0] = flag_set[idx..len];
                    long[long_idx][1] = key;
                    long_idx += 1;
                } else {
                    short[short_idx].@"0" = flag_set[idx];
                    short[short_idx].@"1" = key;
                    short_idx += 1;
                }
            }
        } else {
            var long_flag: [key.len]u8 = @splat(0);
            for (key, 0..) |c, i| long_flag[i] = switch (c) {
                'a'...'z', '0'...'9', 'A'...'Z' => c,
                '_' => '-',
                else => @compileError("field name contains invalid characters"),
            };

            const long_flag_const = long_flag;
            long[long_idx][0] = &long_flag_const;

            long[long_idx][1] = key;
            long_idx += 1;

            if (flags_config.add_short_flags) {
                short[short_idx].@"0" = key[0];
                short[short_idx].@"1" = key;
                short_idx += 1;
            }
        }
    }

    std.debug.assert(long_idx == long_count);
    std.debug.assert(short_idx == short_count);

    // ensure there are no repeating flags
    var flags: [long_count + short_count][]const u8 = undefined;

    for (long, 0..) |l, idx| flags[idx] = l[0];
    for (short, long_count..) |s, idx| flags[idx] = &.{s.@"0"};

    // this will fail if there are duplicte flags
    // i don't feel like doing this the normal way
    _ = @typeInfo(@Struct(.auto, null, &flags, &@splat(void), &@splat(.{}))).@"struct";

    return .{ long, short };
}

/// calculates the count of
/// the flags ahead of time
fn fieldFlagsCount(comptime T: type) [2]comptime_int {
    const flags_config: FlagsConfig(T) = if (@hasDecl(T, "flags_config")) T.flags_config else .{};

    var long_count = 0;
    var short_count = 0;

    for (std.meta.fieldNames(T)) |key| {
        const flag_set = @field(flags_config.flags, key);

        if (flag_set.len != 0) {
            validateFlagSet(flag_set);

            var idx = 0;
            while (idx < flag_set.len) {
                const len = std.mem.findScalarPos(u8, flag_set, idx, ',') orelse flag_set.len;
                defer idx = len + 1;

                (if (len - idx != 1) long_count else short_count) += 1;
            }
        } else {
            validateFieldName(key);

            long_count += 1;
            if (flags_config.add_short_flags) short_count += 1;
        }
    }

    return .{ long_count, short_count };
}

/// function that turns this
/// struct {
///     field1: f32,
///     field2: isize = 67,
///     other_field: SomeType,
/// }
/// into this
/// struct {
///     field1: []const u8 = &.{},
///     field2: []const u8 = &.{},
///     other_field: []const u8 = &.{},
/// }
fn StringFieldStruct(comptime T: type) type {
    _ = @typeInfo(T).@"struct";

    return @Struct(
        .auto,
        null,
        std.meta.fieldNames(T),
        &@splat([]const u8),
        &@splat(.{ .default_value_ptr = @ptrCast(&@as([]const u8, &.{})) }),
    );
}

/// ensures the flag set only contains
/// valid characters and no empty flags
fn validateFlagSet(flag_set: []const u8) void {
    if (flag_set.len == 0) @compileError("empty flag set");

    for (flag_set) |c| switch (c) {
        'a'...'z', '0'...'9', 'A'...'Z', '-', ',' => {},
        else => @compileError("flag set contains invalid character"),
    };

    var idx = 0;
    while (idx < flag_set.len) {
        const len = std.mem.findScalarPos(u8, flag_set, idx, ',') orelse flag_set.len;
        defer idx = len + 1;

        if (idx == len) {
            @compileError("flag set contains empty flag");
        }

        if (!std.ascii.isAlphabetic(flag_set[idx])) {
            @compileError("flag must start with an alphabet");
        }

        if (!std.ascii.isAlphanumeric(flag_set[len - 1])) {
            @compileError("flag must end with an alphabet or a number");
        }

        // allowing only one long flag and a short flag
        // is probably a good idea
    }
}

/// ensures the field name is
/// suitable to turn into a flag
fn validateFieldName(field_name: []const u8) void {
    if (field_name.len < 2) @compileError("field name too short");

    for (field_name) |c| switch (c) {
        'a'...'z', '0'...'9', 'A'...'Z', '_' => {},
        else => @compileError("field name contains invalid character"),
    };

    if (!std.ascii.isAlphabetic(field_name[0])) {
        @compileError("flag must start with an alphabet");
    }

    if (!std.ascii.isAlphanumeric(field_name[field_name.len - 1])) {
        @compileError("flag must end with an alphabet or a number");
    }
}

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

    const val3, args_cur = try setValue(void, ?[3]TestEnum, {}, args_cur, args);
    try std.testing.expectEqualDeep(@as([3]TestEnum, .{ .abc, .def, .ghi }), val3 orelse error.Null);

    const val4, args_cur = try setValue(void, ?[]const u8, {}, args_cur, args);
    try std.testing.expectEqualStrings("foobar", val4 orelse return error.Null);

    const val5, args_cur = try setValue(void, []const u8, {}, args_cur, args);
    try std.testing.expectEqualStrings("doover", val5);

    const app: TestApp = .init();

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
}

test "set fields" {
    const app: TestApp = .init();

    const args: []const []const u8 = &.{
        "-F",           "--shh.js:55:1",
        "main.go:54:9", "index.html:89:7",
        "-g",           "foo",
        "bar",          "baz",
        "--number",     "-777",
        "--lAbel",      "far",
        "--floption",   "--",
        "--flare",      "33",
        "--fair",       "32",
        "--fare",       "45",
    };

    const Flags = struct {
        Files: []FileLocation,
        strings: [3][]const u8,
        number: isize,
        lAbel: enum {
            bar,
            car,
            far,
        },
        floption: bool = false,

        pub const flags_config: FlagsConfig(@This()) = .{
            .add_short_flags = true,
            .flags = .{
                .strings = "g",
            },
        };
    };

    const Flags2 = struct {
        flare: u32,
        fair: u128,
        fare: u128,
    };

    const flags, var args_cur = try setFields(TestApp, Flags, app, 0, args);
    defer app.gpa.free(flags.Files);

    try std.testing.expectEqualDeep(@as([]const FileLocation, &.{
        .{ .path = "--shh.js", .line = 55, .col = 1 },
        .{ .path = "main.go", .line = 54, .col = 9 },
        .{ .path = "index.html", .line = 89, .col = 7 },
    }), flags.Files);

    try std.testing.expectEqualDeep(@as([3][]const u8, .{ "foo", "bar", "baz" }), flags.strings);

    try std.testing.expectEqual(-777, flags.number);

    try std.testing.expectEqual(.far, flags.lAbel);

    try std.testing.expect(flags.floption);

    const flags2, args_cur = try setFields(void, Flags2, {}, args_cur, args);

    try std.testing.expectEqualDeep(@as(Flags2, .{
        .flare = 33,
        .fair = 32,
        .fare = 45,
    }), flags2);

    try std.testing.expectEqual(args.len, args_cur);
}

const TestApp = struct {
    gpa: std.mem.Allocator,
    n: ?*usize = null,

    fn init() TestApp {
        return .{
            .gpa = std.testing.allocator,
        };
    }

    pub fn cmd1(_: void, _:void) void {}

    // coming up with examples/tests is the hardest part of this project. aaaaaaaaahhh
};

const TestEnum = enum {
    abc,
    def,
    ghi,
    jkl,
    mno,
    pqr,
    stu,
    vwx,
    yz,
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
            if (arg.len == 0 or (arg[0] == '-' and std.mem.findScalar(u8, arg, ':') == null)) break;

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
