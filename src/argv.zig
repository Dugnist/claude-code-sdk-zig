//! Internal: argv builder for Claude Code SDK
//!
//! Constructs subprocess argv arrays from SDK options, handling binary
//! discovery, flag generation, and optional MCP config file creation.
//! Not part of the public SDK API.

const std = @import("std");
const options = @import("options.zig");

// ============================================================================
// Result Type
// ============================================================================

/// Result of argv construction.
///
/// tmp_mcp_path (if non-null) is a temp file created for --mcp-config.
/// The caller must delete it after the subprocess exits and free the string.
pub const ArgvResult = struct {
    /// Null-terminated argument vector owned by caller. Free with freeArgv().
    argv: [][]const u8,
    /// Temp MCP config file path (optional). Free with allocator.free() after deleting.
    tmp_mcp_path: ?[]const u8,
};

// ============================================================================
// Binary Discovery
// ============================================================================

/// Find the claude binary: check cli_path first, then search PATH.
///
/// When multiple `claude` entries exist in PATH, a native binary (Mach-O/ELF)
/// is preferred over a JS-script symlink (e.g. `bun add --global` stubs that
/// point to a `cli.js`). This matters when both the standalone installer binary
/// and an older bun-global install are present — the native binary is stable,
/// while executing the `.js` shebang script depends on which `node` is first in
/// PATH and may crash under Bun's Node.js compatibility layer.
///
/// Falls back to the first JS script found if no native binary is available.
///
/// Returns owned string — caller must free.
pub fn findBinary(allocator: std.mem.Allocator, io: std.Io, cli_path: ?[]const u8) ![]const u8 {
    if (cli_path) |p| {
        return allocator.dupe(u8, p);
    }

    const path_env_z = std.c.getenv("PATH") orelse {
        std.log.err("PATH environment variable not set", .{});
        return error.BinaryNotFound;
    };
    const path_env = std.mem.sliceTo(path_env_z, 0);

    // Keep the first JS-script symlink as a fallback in case no native binary
    // is ever found. Freed on success or propagated as the final result.
    var js_fallback: ?[]const u8 = null;
    errdefer if (js_fallback) |p| allocator.free(p);

    var it = std.mem.tokenizeScalar(u8, path_env, std.fs.path.delimiter);
    while (it.next()) |dir| {
        const full = try std.fs.path.join(allocator, &.{ dir, "claude" });
        if (std.Io.Dir.accessAbsolute(io, full, .{ .execute = true })) {
            if (symlinkTargetIsJs(full)) {
                // JS-script stub — save as fallback, keep searching for native.
                if (js_fallback == null) {
                    js_fallback = full;
                } else {
                    allocator.free(full);
                }
            } else {
                // Native binary — prefer this.
                if (js_fallback) |p| allocator.free(p);
                return full;
            }
        } else |_| {
            allocator.free(full);
        }
    }

    // No native binary found — use the JS-script fallback if one exists.
    if (js_fallback) |p| {
        return p;
    }

    std.log.err("claude binary not found in PATH", .{});
    return error.BinaryNotFound;
}

/// Return true when `path` is a symlink whose direct target ends with ".js".
///
/// Used to detect bun-global install stubs like
///   ~/.bun/bin/claude -> ../install/global/node_modules/.../cli.js
fn symlinkTargetIsJs(path: []const u8) bool {
    if (path.len >= 4096) return false;
    var pathz: [4097]u8 = undefined;
    @memcpy(pathz[0..path.len], path);
    pathz[path.len] = 0;

    var link_buf: [4096]u8 = undefined;
    const n = std.c.readlink(@ptrCast(&pathz), &link_buf, link_buf.len);
    if (n <= 0) return false; // not a symlink or readlink error

    return std.mem.endsWith(u8, link_buf[0..@intCast(n)], ".js");
}

// ============================================================================
// Argv Builders
// ============================================================================

/// Build argv for a one-shot query (adds -p <prompt> at the end).
///
/// Returned ArgvResult.argv is owned by the caller; use freeArgv() to release.
pub fn buildQueryArgv(
    allocator: std.mem.Allocator,
    io: std.Io,
    binary: []const u8,
    prompt: []const u8,
    opts: options.QueryOptions,
) !ArgvResult {
    var argv = std.ArrayList([]const u8){};
    errdefer freeList(allocator, &argv);

    try appendCommonArgs(allocator, &argv, binary, false, opts.model, opts.system_prompt, opts.allowed_tools, opts.disallowed_tools, opts.permission_mode, opts.max_turns, opts.resume_session, opts.continue_conversation, opts.verbose, opts.add_dirs);

    // MCP config
    const tmp_mcp_path = try appendMcpArgs(allocator, io, &argv, opts.mcp_servers);

    // Prompt (positional, must come last)
    try argv.append(allocator, try allocator.dupe(u8, "-p"));
    try argv.append(allocator, try allocator.dupe(u8, prompt));

    return ArgvResult{
        .argv = try argv.toOwnedSlice(allocator),
        .tmp_mcp_path = tmp_mcp_path,
    };
}

/// Build argv for a bidirectional session (adds --input-format stream-json).
///
/// No prompt flag — input is sent via stdin JSON messages.
pub fn buildSessionArgv(
    allocator: std.mem.Allocator,
    io: std.Io,
    binary: []const u8,
    opts: options.SessionOptions,
) !ArgvResult {
    var argv = std.ArrayList([]const u8){};
    errdefer freeList(allocator, &argv);

    try appendCommonArgs(allocator, &argv, binary, true, opts.model, opts.system_prompt, opts.allowed_tools, opts.disallowed_tools, opts.permission_mode, opts.max_turns, opts.resume_session, opts.continue_conversation, opts.verbose, opts.add_dirs);

    const tmp_mcp_path = try appendMcpArgs(allocator, io, &argv, opts.mcp_servers);

    return ArgvResult{
        .argv = try argv.toOwnedSlice(allocator),
        .tmp_mcp_path = tmp_mcp_path,
    };
}

/// Free all strings in an argv slice plus the slice itself.
pub fn freeArgv(allocator: std.mem.Allocator, io: std.Io, result: ArgvResult) void {
    for (result.argv) |arg| allocator.free(arg);
    allocator.free(result.argv);
    if (result.tmp_mcp_path) |p| {
        std.Io.Dir.deleteFileAbsolute(io, p) catch {};
        allocator.free(p);
    }
}

// ============================================================================
// Internal Helpers
// ============================================================================

/// Append the flags common to both query and session modes.
fn appendCommonArgs(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    binary: []const u8,
    session_mode: bool,
    model: ?[]const u8,
    system_prompt: ?[]const u8,
    allowed_tools: []const []const u8,
    disallowed_tools: []const []const u8,
    permission_mode: options.PermissionMode,
    max_turns: ?u32,
    resume_id: ?[]const u8,
    cont: bool,
    verbose: bool,
    add_dirs: []const []const u8,
) !void {
    try argv.append(allocator, try allocator.dupe(u8, binary));

    try argv.append(allocator, try allocator.dupe(u8, "--output-format"));
    try argv.append(allocator, try allocator.dupe(u8, "stream-json"));

    if (session_mode) {
        try argv.append(allocator, try allocator.dupe(u8, "--input-format"));
        try argv.append(allocator, try allocator.dupe(u8, "stream-json"));
    }

    if (model) |m| {
        try argv.append(allocator, try allocator.dupe(u8, "--model"));
        try argv.append(allocator, try allocator.dupe(u8, m));
    }

    if (system_prompt) |sp| {
        try argv.append(allocator, try allocator.dupe(u8, "--system-prompt"));
        try argv.append(allocator, try allocator.dupe(u8, sp));
    }

    for (allowed_tools) |tool| {
        try argv.append(allocator, try allocator.dupe(u8, "--allowedTools"));
        try argv.append(allocator, try allocator.dupe(u8, tool));
    }

    for (disallowed_tools) |tool| {
        try argv.append(allocator, try allocator.dupe(u8, "--disallowedTools"));
        try argv.append(allocator, try allocator.dupe(u8, tool));
    }

    switch (permission_mode) {
        .bypass_permissions => {
            try argv.append(allocator, try allocator.dupe(u8, "--dangerously-skip-permissions"));
        },
        else => {
            try argv.append(allocator, try allocator.dupe(u8, "--permission-mode"));
            try argv.append(allocator, try allocator.dupe(u8, permission_mode.toString()));
        },
    }

    if (max_turns) |mt| {
        try argv.append(allocator, try allocator.dupe(u8, "--max-turns"));
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{mt}));
    }

    if (resume_id) |sid| {
        try argv.append(allocator, try allocator.dupe(u8, "--resume"));
        try argv.append(allocator, try allocator.dupe(u8, sid));
    } else if (cont) {
        try argv.append(allocator, try allocator.dupe(u8, "--continue"));
    }

    if (verbose) {
        try argv.append(allocator, try allocator.dupe(u8, "--verbose"));
    }

    for (add_dirs) |dir| {
        try argv.append(allocator, try allocator.dupe(u8, "--add-dir"));
        try argv.append(allocator, try allocator.dupe(u8, dir));
    }
}

/// Write MCP config file and append --mcp-config flag, or return null.
fn appendMcpArgs(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: *std.ArrayList([]const u8),
    servers: []const options.McpServerEntry,
) !?[]const u8 {
    if (servers.len == 0) return null;

    const tmp_path = try writeMcpConfig(allocator, io, servers);
    errdefer {
        std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};
        allocator.free(tmp_path);
    }

    try argv.append(allocator, try allocator.dupe(u8, "--mcp-config"));
    try argv.append(allocator, try allocator.dupe(u8, tmp_path));

    return tmp_path;
}

/// Write MCP server config to a temp JSON file and return its path.
///
/// The caller is responsible for deleting the file and freeing the path string.
fn writeMcpConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    servers: []const options.McpServerEntry,
) ![]const u8 {
    var rand_bytes: [8]u8 = undefined;
    const rng_src = std.Random.IoSource{ .io = io };
    rng_src.interface().bytes(&rand_bytes);
    const rand_hex = std.fmt.bytesToHex(&rand_bytes, .lower);

    const tmp_path = try std.fmt.allocPrint(
        allocator,
        "/tmp/cc-sdk-mcp-{s}.json",
        .{&rand_hex},
    );
    errdefer allocator.free(tmp_path);

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"mcpServers\":{");
    for (servers, 0..) |entry, i| {
        if (i > 0) try w.writeByte(',');
        try writeJsonStr(w, entry.name);
        try w.writeByte(':');
        switch (entry.config) {
            .stdio => |s| {
                try w.writeAll("{\"command\":");
                try writeJsonStr(w, s.command);
                try w.writeAll(",\"args\":[");
                for (s.args, 0..) |arg, j| {
                    if (j > 0) try w.writeByte(',');
                    try writeJsonStr(w, arg);
                }
                try w.writeAll("],\"env\":{");
                for (s.env, 0..) |kv, j| {
                    if (j > 0) try w.writeByte(',');
                    try writeJsonStr(w, kv.key);
                    try w.writeByte(':');
                    try writeJsonStr(w, kv.value);
                }
                try w.writeAll("}}");
            },
            .sse => |s| {
                try w.writeAll("{\"type\":\"sse\",\"url\":");
                try writeJsonStr(w, s.url);
                if (s.headers.len > 0) {
                    try w.writeAll(",\"headers\":{");
                    for (s.headers, 0..) |h, j| {
                        if (j > 0) try w.writeByte(',');
                        try writeJsonStr(w, h.key);
                        try w.writeByte(':');
                        try writeJsonStr(w, h.value);
                    }
                    try w.writeByte('}');
                }
                try w.writeByte('}');
            },
            .http => |s| {
                try w.writeAll("{\"type\":\"http\",\"url\":");
                try writeJsonStr(w, s.url);
                if (s.headers.len > 0) {
                    try w.writeAll(",\"headers\":{");
                    for (s.headers, 0..) |h, j| {
                        if (j > 0) try w.writeByte(',');
                        try writeJsonStr(w, h.key);
                        try w.writeByte(':');
                        try writeJsonStr(w, h.value);
                    }
                    try w.writeByte('}');
                }
                try w.writeByte('}');
            },
        }
    }
    try w.writeAll("}}");

    const file = try std.Io.Dir.createFileAbsolute(io, tmp_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, aw.writer.buffer[0..aw.writer.end]);

    return tmp_path;
}

/// Write a JSON-encoded string (with surrounding quotes) to writer.
fn writeJsonStr(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x08, 0x0b...0x0c, 0x0e...0x1f => |ctrl| try w.print("\\u{x:04}", .{ctrl}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

/// Errdefer helper: free all strings in an ArrayList and the list itself.
fn freeList(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
}
