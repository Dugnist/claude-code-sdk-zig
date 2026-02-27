//! One-shot query() integration test.
//!
//! Exercises the query() API across three scenarios:
//!   1.  Plain text response — "What is 2+2?"
//!   2.  Tool use — "List the files in the current directory"
//!   3.  Custom system prompt — restricts the response style

const std = @import("std");
const sdk = @import("cc-sdk-zig");

const print = std.debug.print;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    // Resolve absolute cwd — query() requires an absolute path.
    var cwd_buf: [4096]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.GetCwdFailed;
    const cwd = std.mem.sliceTo(cwd_ptr, 0);

    const base_opts: sdk.QueryOptions = .{
        .cwd = cwd,
        .verbose = true,
    };

    // ─────────────────────────────────────────────────────────────────────────
    // Step 1 — Plain text response.
    // ─────────────────────────────────────────────────────────────────────────
    print("\n[1] Query — \"What is 2+2?\"\n", .{});

    try sdk.query(allocator, io, "What is 2+2?", base_opts, &onMessage);

    // ─────────────────────────────────────────────────────────────────────────
    // Step 2 — Tool use (Bash).
    // ─────────────────────────────────────────────────────────────────────────
    print("\n[2] Query — \"List the files in the current directory\"\n", .{});

    try sdk.query(
        allocator,
        io,
        "List the files in the current directory using the Bash tool and show me the output.",
        base_opts,
        &onMessage,
    );

    // ─────────────────────────────────────────────────────────────────────────
    // Step 3 — Custom system prompt.
    // ─────────────────────────────────────────────────────────────────────────
    print("\n[3] Query — custom system prompt (respond only in JSON)\n", .{});

    try sdk.query(
        allocator,
        io,
        "What is the sum of 3 and 7? Provide the answer as a JSON object.",
        .{
            .cwd = cwd,
            .verbose = true,
            .system_prompt = "You are a JSON-only assistant. Respond exclusively with valid JSON, no prose.",
        },
        &onMessage,
    );

    print("\n═══ query test complete ═══\n\n", .{});
}

// ─────────────────────────────────────────────────────────────────────────────
// Callback — invoked for every event emitted by the subprocess.
// ─────────────────────────────────────────────────────────────────────────────

fn onMessage(_: std.mem.Allocator, msg: sdk.Message) anyerror!void {
    switch (msg) {
        .system => |s| {
            print("    session_id : {s}\n", .{s.session_id});
            if (s.model) |m| print("    model      : {s}\n", .{m});
            print("    tools      : {d} available\n", .{s.tools.len});
        },
        .assistant => |a| printAssistant(a),
        .result => |r| printResult(r),
        .user => {},
    }
}

fn printAssistant(msg: sdk.AssistantMsg) void {
    for (msg.content) |block| {
        switch (block) {
            .text => |t| print("    {s}\n", .{t.text}),
            .thinking => |t| print("    <thinking> {s} </thinking>\n", .{t.thinking}),
            .tool_use => |t| print("    [tool: {s}]\n", .{t.name}),
        }
    }
}

fn printResult(msg: sdk.ResultMsg) void {
    print("    [{s}] turns={d}  cost=${d:.4}  duration={d}ms\n", .{
        @tagName(msg.subtype),
        msg.num_turns,
        msg.total_cost_usd,
        msg.duration_ms,
    });
}
