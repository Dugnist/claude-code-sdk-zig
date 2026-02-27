//! Claude Code SDK — bidirectional Session
//!
//! Manages a long-running claude subprocess with --input-format stream-json,
//! enabling bidirectional communication: send prompts at any time and receive
//! streaming events in return.
//!
//! ## Lifecycle
//!
//! ```zig
//! const sdk = @import("sdk/mod.zig");
//!
//! // Create a new session
//! var sess = try sdk.Session.init(allocator, io, .{ .cwd = "/my/project" });
//! defer sess.deinit();
//!
//! // Send initial prompt and read responses
//! try sess.send("Implement a Fibonacci function in Zig");
//! while (try sess.receive()) |*owned| {
//!     defer owned.deinit();
//!     switch (owned.msg) {
//!         .assistant => |a| { /* handle response */ },
//!         .result    => break,
//!         else       => {},
//!     }
//! }
//!
//! // Send follow-up
//! try sess.send("Now add unit tests");
//! // ... read more responses ...
//!
//! // Clean shutdown
//! try sess.close();
//! ```
//!
//! ## Resume an existing session
//!
//! ```zig
//! var sess = try sdk.Session.initResume(allocator, io, "session-id-here",
//!                                       .{ .cwd = "/my/project" });
//! ```

const std = @import("std");
const options = @import("options.zig");
const types = @import("types.zig");
const argv_mod = @import("argv.zig");
const parser = @import("parser.zig");
const ReadBuffer = @import("buffer.zig").ReadBuffer;

// ============================================================================
// Session
// ============================================================================

/// Bidirectional Claude Code session.
///
/// Holds a running claude subprocess with its stdin/stdout pipes open.
/// Messages are sent by writing JSON to stdin; responses are read from stdout.
pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    line_buf: ReadBuffer,
    chunk: [8192]u8,

    // ========================================================================
    // Construction
    // ========================================================================

    /// Start a new Claude Code session.
    ///
    /// Spawns the subprocess with `--input-format stream-json`.
    /// Call send() to submit prompts and receive() to read responses.
    ///
    /// ## Parameters
    ///   - allocator: Allocator for process and buffer management (must outlive session)
    ///   - io: Zig IO runtime for fiber-suspending reads
    ///   - opts: Session configuration (cwd is required)
    ///
    /// ## Errors
    ///   - error.BinaryNotFound if claude binary cannot be found
    ///   - error.SpawnFailed if the subprocess cannot be started
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        opts: options.SessionOptions,
    ) !Session {
        return spawnSession(allocator, io, opts);
    }

    /// Resume a previous Claude Code session by session ID.
    ///
    /// Equivalent to Session.init() with opts.resume_session set to session_id.
    /// Use the session_id from a previous SystemMsg.session_id.
    ///
    /// ## Parameters
    ///   - allocator: Allocator for process and buffer management
    ///   - io: Zig IO runtime
    ///   - session_id: Session ID to resume (from a prior SystemMsg)
    ///   - opts: Session configuration (cwd is required)
    pub fn initResume(
        allocator: std.mem.Allocator,
        io: std.Io,
        session_id: []const u8,
        opts: options.SessionOptions,
    ) !Session {
        var patched = opts;
        patched.resume_session = session_id;
        return spawnSession(allocator, io, patched);
    }

    // ========================================================================
    // Sending Input
    // ========================================================================

    /// Send a user prompt to the running session.
    ///
    /// Writes a `{"type":"user","message":{"role":"user","content":"..."}}` JSON line
    /// to the subprocess stdin. The session must be open (not yet closed).
    ///
    /// ## Errors
    ///   - error.SessionClosed if stdin is no longer available
    ///   - error.WriteError on I/O failure
    pub fn send(self: *Session, prompt: []const u8) !void {
        const stdin = self.child.stdin orelse return error.SessionClosed;

        var aw = std.Io.Writer.Allocating.init(self.allocator);
        defer aw.deinit();
        const w = &aw.writer;

        try w.writeAll("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":");
        try writeJsonStr(w, prompt);
        try w.writeAll("},\"parent_tool_use_id\":null}\n");

        stdin.writeStreamingAll(self.io, aw.writer.buffer[0..aw.writer.end]) catch return error.WriteError;
    }

    /// Send an interrupt signal to the running session.
    ///
    /// Writes `{"type":"interrupt"}` to stdin, signalling Claude Code to
    /// stop the current turn and return control.
    ///
    /// ## Errors
    ///   - error.SessionClosed if stdin is no longer available
    ///   - error.WriteError on I/O failure
    pub fn interrupt(self: *Session) !void {
        const stdin = self.child.stdin orelse return error.SessionClosed;
        stdin.writeStreamingAll(self.io, "{\"type\":\"interrupt\"}\n") catch return error.WriteError;
    }

    // ========================================================================
    // Receiving Output
    // ========================================================================

    /// Read the next message from the session.
    ///
    /// Suspends the current fiber until a complete NDJSON line is available or
    /// stdout is closed (EOF). Returns null when the stream ends.
    ///
    /// The returned OwnedMessage owns all string data; call `.deinit()` when done.
    ///
    /// ## Errors
    ///   - error.ReadError on stdout I/O failure
    ///   - error.MissingField if a required JSON field is absent
    pub fn receive(self: *Session) !?types.OwnedMessage {
        while (true) {
            // Try to drain a complete line first
            if (self.line_buf.drain()) |line| {
                if (try parseLine(self.allocator, line)) |owned| return owned;
                continue; // Unknown/empty line — keep reading
            }

            // Need more data — async read from stdout
            const stdout = self.child.stdout orelse return null;
            var bufs = [_][]u8{&self.chunk};
            const n = stdout.readStreaming(self.io, &bufs) catch |err| {
                if (err == error.EndOfStream) return null;
                return error.ReadError;
            };
            if (n == 0) return null;

            try self.line_buf.append(self.chunk[0..n]);
        }
    }

    // ========================================================================
    // Lifecycle
    // ========================================================================

    /// Close stdin and wait for the subprocess to exit.
    ///
    /// Signals Claude Code that no more input will arrive, waits for it to
    /// finish its current work, and reaps the process. After this call the
    /// session should be deinitialized.
    ///
    /// ## Errors
    ///   - error.WaitFailed if waiting on the child process fails
    pub fn close(self: *Session) !void {
        // Close stdin pipe so CC knows input is done
        if (self.child.stdin) |stdin| {
            stdin.close(self.io);
            self.child.stdin = null;
        }

        // Drain remaining stdout events (prevent pipe buffer deadlock)
        var drain_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer drain_arena.deinit();

        drainStdout(self, drain_arena.allocator()) catch {};

        // Wait for child exit
        _ = self.child.wait(self.io) catch return error.WaitFailed;
    }

    /// Free all resources held by the session without waiting for clean exit.
    ///
    /// Force-kills the subprocess if still running. For graceful shutdown,
    /// call close() before deinit().
    pub fn deinit(self: *Session) void {
        // Close stdin if still open
        if (self.child.stdin) |stdin| {
            stdin.close(self.io);
            self.child.stdin = null;
        }

        // kill() is idempotent — it reaps the process and sets child.id = null.
        // Do NOT call wait() after kill(); that would assert child.id != null and panic.
        self.child.kill(self.io);

        self.line_buf.deinit();
    }

    // ========================================================================
    // Internal Helpers
    // ========================================================================

    /// Consume remaining stdout without processing (for close() drain).
    fn drainStdout(self: *Session, arena: std.mem.Allocator) !void {
        const stdout = self.child.stdout orelse return;
        while (true) {
            // Drain buffered lines
            while (self.line_buf.drain()) |_| {}

            var bufs = [_][]u8{&self.chunk};
            const n = stdout.readStreaming(self.io, &bufs) catch |err| {
                if (err == error.EndOfStream) return;
                return;
            };
            if (n == 0) return;
            try self.line_buf.append(self.chunk[0..n]);
            _ = arena;
        }
    }
};

// ============================================================================
// Internal: Process Spawning
// ============================================================================

/// Parse a .env file and inject any auth_keys that are missing from env_map.
///
/// Only keys listed in auth_keys are extracted — all other vars in the file
/// are silently ignored to prevent accidental exposure of unrelated secrets.
///
/// Supported formats:  KEY=value  KEY="value"  KEY='value'  # comment
fn loadDotEnvFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    auth_keys: []const [*:0]const u8,
    path: []const u8,
) void {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return;
    defer file.close(io);

    const size = file.length(io) catch return;
    if (size > 64 * 1024) return; // guard against unreasonably large files
    const content = allocator.alloc(u8, size) catch return;
    defer allocator.free(content);
    _ = file.readPositionalAll(io, content, 0) catch return;

    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trimEnd(u8, line[0..eq], " \t");
        if (key.len == 0) continue;

        // Only inject recognized auth keys
        var is_auth_key = false;
        for (auth_keys) |ak| {
            if (std.mem.eql(u8, key, std.mem.sliceTo(ak, 0))) {
                is_auth_key = true;
                break;
            }
        }
        if (!is_auth_key) continue;

        // Skip if already set from process env
        if (env_map.get(key) != null) continue;

        // Strip surrounding quotes from value
        var val = std.mem.trimStart(u8, line[eq + 1 ..], " \t");
        if (val.len >= 2 and
            ((val[0] == '"' and val[val.len - 1] == '"') or
            (val[0] == '\'' and val[val.len - 1] == '\'')))
        {
            val = val[1 .. val.len - 1];
        }
        env_map.put(key, val) catch {};
    }
}

/// Inject auth_keys missing from env_map, checking three sources in order:
///
///   1. `.env` in process cwd     — developer-standard local override
///   2. `~/.claude/settings.json` — CC's own auth storage (`claude config set`)
///
/// Each source skips keys already present (earlier sources win).
/// Non-fatal — all errors are silently ignored.
fn bridgeSettingsEnvs(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    auth_keys: []const [*:0]const u8,
) void {
    // 1. .env file in the process working directory
    var cwd_buf: [4096]u8 = undefined;
    if (std.c.getcwd(&cwd_buf, cwd_buf.len)) |cwd_ptr| {
        const cwd = std.mem.sliceTo(cwd_ptr, 0);
        const dotenv_path = std.fmt.allocPrint(allocator, "{s}/.env", .{cwd}) catch null;
        if (dotenv_path) |path| {
            defer allocator.free(path);
            loadDotEnvFile(allocator, io, env_map, auth_keys, path);
        }
    }

    // 2. ~/.claude/settings.json — CC stores auth tokens under "envs"
    const home_z = std.c.getenv("HOME") orelse return;
    const home = std.mem.sliceTo(home_z, 0);

    const path = std.fmt.allocPrint(allocator, "{s}/.claude/settings.json", .{home}) catch return;
    defer allocator.free(path);

    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return;
    defer file.close(io);

    const size = file.length(io) catch return;
    if (size > 512 * 1024) return; // guard against unreasonably large files
    const content = allocator.alloc(u8, size) catch return;
    defer allocator.free(content);
    _ = file.readPositionalAll(io, content, 0) catch return;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return;
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    const envs_val = root_obj.get("envs") orelse return;
    const envs = switch (envs_val) {
        .object => |o| o,
        else => return,
    };

    for (auth_keys) |key_z| {
        const key = std.mem.sliceTo(key_z, 0);
        if (env_map.get(key) != null) continue; // already set from process env or .env
        const val = switch (envs.get(key) orelse continue) {
            .string => |s| s,
            else => continue,
        };
        env_map.put(key, val) catch {};
    }
}

fn spawnSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: options.SessionOptions,
) !Session {
    const binary = try argv_mod.findBinary(allocator, io, opts.cli_path);
    defer allocator.free(binary);

    const argv_result = try argv_mod.buildSessionArgv(allocator, io, binary, opts);
    defer argv_mod.freeArgv(allocator, io, argv_result);

    // Anthropic / CC auth and config keys — used in both isolation modes.
    const auth_keys = [_][*:0]const u8{
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "API_TIMEOUT_MS",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
    };

    // The env_map lifetime only needs to cover the spawn call — fork() copies it.
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    if (opts.is_isolated) {
        // ── Isolated mode (default) ──────────────────────────────────────────
        // Forward only system essentials + auth keys.  Everything else (MCPs,
        // skills, memories) comes from the project's own .claude/ directory.
        const sys_keys = [_][*:0]const u8{
            "PATH", "HOME", "USER", "LOGNAME", "SHELL",
            "TMPDIR", "TEMP", "TMP",
            "LANG", "LC_ALL", "LC_CTYPE",
            "TERM", "COLORTERM",
        };

        inline for (sys_keys ++ auth_keys) |key_z| {
            if (std.c.getenv(key_z)) |val_z| {
                const key = std.mem.sliceTo(key_z, 0);
                const val = std.mem.sliceTo(val_z, 0);
                env_map.put(key, val) catch {};
            }
        }

        // Auth bridge: check .env file then ~/.claude/settings.json for any
        // auth_keys that were not found in the process environment above.
        bridgeSettingsEnvs(allocator, io, &env_map, &auth_keys);

        // Redirect CC's config to the project's own .claude/ directory.
        // Isolates MCPs, skills, settings, and memories from ~/.claude/.
        const config_dir = try std.fmt.allocPrint(allocator, "{s}/.claude", .{opts.cwd});
        defer allocator.free(config_dir);
        try env_map.put("CLAUDE_CONFIG_DIR", config_dir);
    } else {
        // ── Non-isolated mode ────────────────────────────────────────────────
        // Inherit the parent's complete environment.  CC uses ~/.claude/ as
        // normal — full MCPs, skills, and memories are available.
        //
        // CC-internal vars are excluded: they are set by CC itself based on
        // its invocation mode.  Forwarding them from an outer CC session would
        // trigger the "nested session" guard and crash the child process.
        const cc_internal_keys = [_][]const u8{
            "CLAUDECODE",
            "CLAUDE_CODE_ENTRYPOINT",
        };
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
    }

    const child = std.process.spawn(io, .{
        .argv = argv_result.argv,
        .cwd = .{ .path = opts.cwd },
        .environ_map = &env_map,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = if (opts.inherit_stderr) .inherit else .ignore,
    }) catch return error.SpawnFailed;

    return Session{
        .allocator = allocator,
        .io = io,
        .child = child,
        .line_buf = ReadBuffer.init(allocator),
        .chunk = undefined,
    };
}

// ============================================================================
// Internal: Per-Line Parsing
// ============================================================================

fn parseLine(allocator: std.mem.Allocator, line: []const u8) !?types.OwnedMessage {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const msg = parser.parseMessage(arena.allocator(), line) catch |err| {
        arena.deinit();
        if (err == error.InvalidJson) {
            std.log.warn("cc-sdk session: invalid JSON line, skipping", .{});
            return null;
        }
        return err;
    };

    if (msg) |m| {
        return types.OwnedMessage{
            .msg = m,
            .arena = arena,
        };
    }

    arena.deinit();
    return null;
}

// ============================================================================
// Internal: JSON String Encoding
// ============================================================================

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
