# claude-code-sdk-zig

Unofficial Zig SDK for [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview) — spawn and communicate with the `claude` CLI as a managed subprocess.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## About

This SDK lets you drive Claude Code programmatically from Zig. It handles subprocess spawning, stream-JSON I/O, and message parsing so you can focus on what Claude produces rather than how to wire it up.

Two modes are supported: a one-shot `query()` for scripts and automation, and a bidirectional `Session` for multi-turn conversations, MCP server backends, and agent orchestration.

## Requirements

- Zig `0.16.0-dev.2821+3edaef9e0` or newer (latest tested)
- The `claude` CLI installed and available in `PATH` (standalone binary or npm/bun global install)
- A valid Anthropic authentication — run `claude` once interactively to authenticate

## Installation

Add the dependency to your project:

```sh
zig fetch --save git+https://codeberg.org/duhnist/claude-code-sdk-zig.git
```

Wire it up in `build.zig`:

```zig
const cc_sdk = b.dependency("claude_code_sdk_zig", .{});
exe.root_module.addImport("cc-sdk-zig", cc_sdk.module("cc-sdk-zig"));
```

Import in your code:

```zig
const sdk = @import("cc-sdk-zig");
```

## Usage

### One-shot query

Spawn claude, send a prompt, stream every event through a callback, then exit. Good for scripts, batch jobs, and CI pipelines.

```zig
const std = @import("std");
const sdk = @import("cc-sdk-zig");

fn onMessage(_: std.mem.Allocator, msg: sdk.Message) anyerror!void {
    switch (msg) {
        .assistant => |a| for (a.content) |blk| {
            if (blk == .text) std.debug.print("{s}", .{blk.text.text});
        },
        .result => |r| std.debug.print("\n[{s}] cost=${d:.4}\n", .{
            @tagName(r.subtype), r.total_cost_usd,
        }),
        else => {},
    }
}

pub fn main(init: std.process.Init) !void {
    var cwd_buf: [4096]u8 = undefined;
    const cwd = std.mem.sliceTo(std.c.getcwd(&cwd_buf, cwd_buf.len).?, 0);

    try sdk.query(
        init.arena.allocator(),
        init.io,
        "What is 2 + 2?",
        .{ .cwd = cwd },
        &onMessage,
    );
}
```

### Bidirectional session

Keep the subprocess alive across multiple turns. Send a prompt with `send()`, read events with `receive()`, then send again — all within a single process lifetime.

```zig
pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var cwd_buf: [4096]u8 = undefined;
    const cwd = std.mem.sliceTo(std.c.getcwd(&cwd_buf, cwd_buf.len).?, 0);

    var sess = try sdk.Session.init(allocator, io, .{ .cwd = cwd });
    defer sess.deinit();

    try sess.send("Implement a Fibonacci function in Zig");

    while (try sess.receive()) |msg| {
        var owned = msg;
        defer owned.deinit();
        switch (owned.msg) {
            .assistant => |a| for (a.content) |blk| {
                if (blk == .text) std.debug.print("{s}", .{blk.text.text});
            },
            .result => break,
            else => {},
        }
    }

    // Continue the conversation
    try sess.send("Now add unit tests");
    // ... receive again ...

    try sess.close();
}
```

### Resuming a session

Capture the `session_id` from the `system` message and pass it to `initResume` in a later session:

```zig
// First session — capture the ID
var session_id: []const u8 = "";
while (try sess.receive()) |msg| {
    var owned = msg;
    defer owned.deinit();
    if (owned.msg == .system) {
        session_id = try allocator.dupe(u8, owned.msg.system.session_id);
    }
    // ...
}
try sess.close();

// Later — resume by ID
var resumed = try sdk.Session.initResume(allocator, io, session_id, opts);
defer resumed.deinit();
```

### Configuring MCP servers

```zig
const opts = sdk.SessionOptions{
    .cwd = cwd,
    .mcp_servers = &.{
        .{
            .name = "my-server",
            .config = .{ .stdio = .{
                .command = "/usr/local/bin/my-mcp-server",
                .args = &.{"--port", "3000"},
            }},
        },
    },
};
```

## Message Types

| Type | When emitted | Key fields |
|------|-------------|------------|
| `system` | Once at session start | `session_id`, `model`, `tools` |
| `assistant` | Each response chunk | `content` (text / thinking / tool_use blocks) |
| `user` | Echoed input | `content_json` |
| `result` | Turn complete | `subtype`, `total_cost_usd`, `duration_ms`, `num_turns` |

Content blocks within `assistant`:

| Block | Fields |
|-------|--------|
| `text` | `text: []const u8` |
| `thinking` | `thinking: []const u8` |
| `tool_use` | `id`, `name`, `input_json` |

## Options Reference

Both `QueryOptions` and `SessionOptions` share these fields:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `cwd` | `[]const u8` | required | Working directory — **must be an absolute path** |
| `cli_path` | `?[]const u8` | `null` | Path to `claude` binary; searches `PATH` if null |
| `model` | `?[]const u8` | `null` | Model ID (e.g. `"claude-opus-4-5"`) |
| `system_prompt` | `?[]const u8` | `null` | Override the default system prompt |
| `allowed_tools` | `[]const []const u8` | `&.{}` | Whitelist of tool names; empty = all allowed |
| `disallowed_tools` | `[]const []const u8` | `&.{}` | Blacklist of tool names |
| `permission_mode` | `PermissionMode` | `.bypass_permissions` | Tool confirmation mode |
| `max_turns` | `?u32` | `null` | Limit agentic turns |
| `resume_session` | `?[]const u8` | `null` | Resume a previous session by ID |
| `continue_conversation` | `bool` | `false` | Continue the most recent conversation |
| `mcp_servers` | `[]const McpServerEntry` | `&.{}` | MCP server configs (stdio / SSE / HTTP) |
| `add_dirs` | `[]const []const u8` | `&.{}` | Additional project directories |

`SessionOptions` adds:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `verbose` | `bool` | `true` | Pass `--verbose`; required for non-TTY subprocess mode |
| `is_isolated` | `bool` | `true` | Spawn with a minimal env and `CLAUDE_CONFIG_DIR = {cwd}/.claude/` |
| `inherit_stderr` | `bool` | `false` | Forward subprocess stderr to parent (useful for auth/startup errors) |

## Gotchas

**`cwd` must be absolute.** Passing `"."` or any relative path causes a spawn failure on macOS. Use `std.c.getcwd` to resolve the real path:
```zig
var buf: [4096]u8 = undefined;
const cwd = std.mem.sliceTo(std.c.getcwd(&buf, buf.len).?, 0);
```

**`is_isolated = true` (default) uses a clean subprocess environment.** Auth is bridged from `~/.claude/settings.json` and `.env` automatically, but your global MCP servers and skills are not inherited — the subprocess looks at `{cwd}/.claude/` instead. Set `is_isolated = false` to inherit your full environment including all global Claude Code config.

**Running inside an existing Claude Code session.** The SDK automatically strips `CLAUDECODE` and `CLAUDE_CODE_ENTRYPOINT` from the child's environment to prevent the nested-session guard from firing.

**Multiple `claude` binaries in PATH.** When both a native standalone binary and a bun-global JS script (`~/.bun/bin/claude`) are present, the SDK prefers the native binary regardless of PATH order. This avoids Bun compatibility issues with the JS launcher.

## Development

```sh
# Build all artifacts
zig build

# Run the session flow integration test (requires auth)
zig build flow-test

# Run library unit tests
zig build test
```

The flow test in `example/flow-test.zig` exercises the full session lifecycle: start, resume, multi-turn conversation, delays, and graceful close.

## License

claude-code-sdk-zig is licensed under the MIT license. See [`LICENSE`](LICENSE) for details.

[![Stand With Ukraine](https://raw.githubusercontent.com/vshymanskyy/StandWithUkraine/main/banner2-direct.svg)](https://vshymanskyy.github.io/StandWithUkraine/)
