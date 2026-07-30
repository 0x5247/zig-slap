//! Zig 0.16.0 single file parallel downloader demo by nubskr
//! modified by me.
//!
//! original: https://gist.github.com/nubskr/c2b4a4ce3c16214c18718e24471520c6

const std = @import("std");

const slap = @import("slap.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    try slap.invokeFromArgs(std.mem.Allocator, run, init.gpa, 1, args, .{});
}

fn run(gpa: std.mem.Allocator, w_uri: Uri, flags: struct {
    output: ?[]const u8 = null,
    async_limit: usize = 10,
    concurrent_limit: usize = 20,
    interactive: bool = false,
}) !void {
    const uri = w_uri.uri;

    var threaded: std.Io.Threaded = .init(gpa, .{
        .async_limit = .limited(flags.async_limit),
        .concurrent_limit = .limited(flags.concurrent_limit),
    });
    defer threaded.deinit();

    const io = threaded.io();

    var client: std.http.Client = .{
        .allocator = gpa,
        .io = io,
    };
    defer client.deinit();

    const destination = flags.output orelse destinationName(uri);

    const bytes_written = try download(gpa, &client, uri, destination, .{
        .interactive = flags.interactive,
        .async_limit = flags.async_limit,
    });

    std.log.info("saved {s} ({d} bytes)", .{ destination, bytes_written });
}

const Uri = struct {
    uri: std.Uri,

    pub fn parseFromArgs(args: []const []const u8) !struct { Uri, usize } {
        if (args.len < 1) return error.MissingArgs;
        return .{ .{ .uri = try std.Uri.parse(args[0]) }, 1 };
    }
};

fn destinationName(uri: std.Uri) []const u8 {
    const basename = std.Io.Dir.path.basenamePosix(uri.path.percent_encoded);
    return if (basename.len == 0) "download" else basename;
}

fn remoteFileSize(client: *std.http.Client, uri: std.Uri) !u64 {
    var request = try client.request(.HEAD, uri, .{
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
    });
    defer request.deinit();
    try request.sendBodiless();

    var head_buffer: [8192]u8 = undefined;
    const response = try request.receiveHead(&head_buffer);

    if (response.head.status != .ok) return error.UnexpectedHttpStatus;
    return response.head.content_length orelse error.MissingContentLength;
}

fn download(
    gpa: std.mem.Allocator,
    client: *std.http.Client,
    uri: std.Uri,
    destination: []const u8,
    flags: struct {
        async_limit: usize,
        interactive: bool,
    },
) !u64 {
    const io = client.io;

    const cwd: std.Io.Dir = .cwd();

    var file = try cwd.createFile(io, destination, .{ .exclusive = flags.interactive });
    defer file.close(io);

    const total = try remoteFileSize(client, uri);
    if (total == 0) return 0;

    const chunk_count: usize = @intCast(@min(total, flags.async_limit));


    const futures = try gpa.alloc(std.Io.Future(DownloadChunkError!void), flags.async_limit);
    var started: usize = 0;
    defer {
        for (futures[0..started]) |*future| {
            _ = future.cancel(io) catch {};
        }

        gpa.free(futures);
    }

    const base_len = total / chunk_count;
    const remainder = total % chunk_count;
    var start: u64 = 0;

    for (futures[0..chunk_count], 0..) |*future, chunk_index| {
        const chunk_len = base_len + @intFromBool(chunk_index < remainder);
        future.* = try io.concurrent(downloadChunk, .{
            client,
            file,
            uri,
            start,
            start + chunk_len - 1,
        });
        started += 1;
        start += chunk_len;
    }

    for (futures[0..chunk_count]) |*future| {
        try future.await(io);
    }

    return total;
}

const DownloadChunkError =
    std.fmt.BufPrintError ||
    std.Io.Writer.Error ||
    std.Io.File.Writer.Error ||
    std.Io.File.Writer.SeekError ||
    std.http.Client.FetchError ||
    error{
        RangeRequestRejected,
        UnexpectedContentLength,
    };

fn downloadChunk(
    client: *std.http.Client,
    file: std.Io.File,
    uri: std.Uri,
    start: u64,
    end: u64,
) DownloadChunkError!void {
    const io = client.io;

    var range_buffer: [128]u8 = undefined;
    const range = try std.fmt.bufPrint(
        &range_buffer,
        "bytes={d}-{d}",
        .{ start, end },
    );

    var file_buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &file_buffer);
    try writer.seekTo(start);

    const response = try client.fetch(.{
        .location = .{ .uri = uri },
        .response_writer = &writer.interface,
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
        .extra_headers = &.{
            .{ .name = "Range", .value = range },
        },
    });

    if (response.status != .partial_content) return error.RangeRequestRejected;
    if (writer.logicalPos() != end + 1) return error.UnexpectedContentLength;

    try writer.flush();
}
