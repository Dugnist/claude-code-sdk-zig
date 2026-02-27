//! Claude Code SDK — one-shot query()
//!
//! Spawns a claude subprocess with -p, streams NDJSON events from stdout,
//! calls the callback for each parsed message, then waits for process exit.
//!
//! ## Usage
//!
//! ```zig
//! const sdk = @import("sdk/mod.zig");
//!
//! fn onMessage(alloc: std.mem.Allocator, msg: sdk.Message) anyerror!void {
//!     switch (msg) {
//!         .assistant => |a| {
//!             for (a.content) |block| {
//!                 if (block == .text) std.debug.print("{s}", .{block.text.text});
//!             }
//!         },
//!         .result => |r| std.debug.print("done ({s})\n", .{@tagName(r.subtype)}),
//!         else => {},
//!     }
//! }
//!
//! try sdk.query(allocator, io, "What is 2+2?", .{ .cwd = "/tmp" }, &onMessage);
//! ```

const std = @import("std");
const options = @import("options.zig");
const types = @import("types.zig");
const argv_mod = @import("argv.zig");
const parser = @import("parser.zig");
const ReadBuffer = @import("buffer.zig").ReadBuffer;

// ============================================================================
// Public API
// ============================================================================

/// Run a one-shot query against Claude Code.
///
/// Spawns the claude subprocess with `--output-format stream-json` and `-p prompt`,
/// streams NDJSON events from stdout, and invokes `callback` for each parsed message.
/// Returns after the subprocess exits.
///
/// The `callback` receives a `Message` and an arena allocator. All string data in
/// the message is valid only for the duration of the callback call. Copy any strings
/// you need to retain.
///
/// ## Parameters
///   - allocator: General-purpose allocator for process and buffer management
///   - io: Zig IO runtime for fiber-suspending reads
///   - prompt: The user prompt to send
///   - opts: Query configuration (cwd is required; all others optional)
///   - callback: Invoked for each message received from Claude Code
///
/// ## Errors
///   - error.BinaryNotFound if the claude binary cannot be located
///   - error.SpawnFailed if the subprocess cannot be started
///   - error.ReadError on stdout read failure
///   - Any error propagated from callback
pub fn query(
    allocator: std.mem.Allocator,
    io: std.Io,
    prompt: []const u8,
    opts: options.QueryOptions,
    callback: types.MessageCallback,
) !void {
    // Discover binary
    const binary = try argv_mod.findBinary(allocator, io, opts.cli_path);
    defer allocator.free(binary);

    // Build argv
    const argv_result = try argv_mod.buildQueryArgv(allocator, io, binary, prompt, opts);
    defer argv_mod.freeArgv(allocator, io, argv_result);

    // Build environment: inherit full parent env, strip CC-internal vars that
    // would trigger the nested-session guard and crash the child process.
    const cc_internal_keys = [_][]const u8{
        "CLAUDECODE",
        "CLAUDE_CODE_ENTRYPOINT",
    };
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    var i: usize = 0;
    while (std.c.environ[i]) |env_z| : (i += 1) {
        const kv = std.mem.sliceTo(env_z, 0);
        if (std.mem.indexOfScalar(u8, kv, '=')) |eq| {
            const key = kv[0..eq];
            var skip = false;
            for (cc_internal_keys) |excl| {
                if (std.mem.eql(u8, key, excl)) { skip = true; break; }
            }
            if (skip) continue;
            env_map.put(key, kv[eq + 1 ..]) catch {};
        }
    }

    // Spawn subprocess
    var child = std.process.spawn(io, .{
        .argv = argv_result.argv,
        .cwd = .{ .path = opts.cwd },
        .environ_map = &env_map,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return error.SpawnFailed;

    // Close stdin immediately — one-shot mode sends no further input
    if (child.stdin) |stdin| {
        stdin.close(io);
        child.stdin = null;
    }

    // Stream stdout events
    const stream_err = streamEvents(allocator, io, child.stdout.?, callback);

    // Always wait for the child regardless of streaming errors
    _ = child.wait(io) catch {};

    // Propagate streaming errors after child cleanup
    try stream_err;
}

// ============================================================================
// Internal: Streaming Loop
// ============================================================================

/// Read NDJSON lines from file, parse, and call callback for each message.
fn streamEvents(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    callback: types.MessageCallback,
) !void {
    var line_buf = ReadBuffer.init(allocator);
    defer line_buf.deinit();

    var chunk: [8192]u8 = undefined;
    // Arena reused per message — reset after each callback
    var msg_arena = std.heap.ArenaAllocator.init(allocator);
    defer msg_arena.deinit();

    while (true) {
        // Drain complete lines first
        while (line_buf.drain()) |line| {
            defer _ = msg_arena.reset(.retain_capacity);

            const msg = parser.parseMessage(msg_arena.allocator(), line) catch |err| {
                if (err == error.InvalidJson) {
                    std.log.warn("cc-sdk query: invalid JSON line, skipping", .{});
                    continue;
                }
                return err;
            };
            if (msg) |m| {
                try callback(msg_arena.allocator(), m);
            }
        }

        // Read more data
        var bufs = [_][]u8{&chunk};
        const n = stdout.readStreaming(io, &bufs) catch |err| {
            if (err == error.EndOfStream) break;
            return error.ReadError;
        };
        if (n == 0) break;

        try line_buf.append(chunk[0..n]);
    }

    // Flush any remaining complete lines after EOF
    while (line_buf.drain()) |line| {
        defer _ = msg_arena.reset(.retain_capacity);
        const msg = parser.parseMessage(msg_arena.allocator(), line) catch continue;
        if (msg) |m| {
            try callback(msg_arena.allocator(), m);
        }
    }
}
