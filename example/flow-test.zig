//! Session flow integration test.
//!
//! Exercises the full Session lifecycle:
//!   1.  Start a new session — prompt "What is 2+2?"
//!   2.  Resume by session_id — ask for the result
//!   3.  Wait 5 seconds
//!   4.  Send a status-check message to the same session
//!   5.  Print the response to step 4
//!   6.  Send another message — print response
//!   7.  Wait 10 seconds
//!   8.  Send a final message — print response after the wait
//!   9.  Close the session

const std = @import("std");
const sdk = @import("cc-sdk-zig");

const print = std.debug.print;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    // Resolve the real absolute cwd — spawn requires an absolute path.
    var cwd_buf: [4096]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.GetCwdFailed;
    const cwd = std.mem.sliceTo(cwd_ptr, 0);

    const opts: sdk.SessionOptions = .{
        .cwd = cwd,
        .is_isolated = false,
        .inherit_stderr = true,
        // Required when stdin is not a TTY (subprocess mode with --input-format stream-json).
        .verbose = true,
    };

    // ─────────────────────────────────────────────────────────────────────────
    // Step 1 — Start a new session, send "What is 2+2?", capture session_id.
    // ─────────────────────────────────────────────────────────────────────────
    print("\n[1] Starting session — \"What is 2+2?\"\n", .{});

    var sess1 = try sdk.Session.init(allocator, io, opts);
    defer sess1.deinit();

    var session_id: []const u8 = "";

    try sess1.send("What is 2+2?");

    step1: while (try sess1.receive()) |msg| {
        var owned = msg;
        defer owned.deinit();
        switch (owned.msg) {
            .system => |s| {
                // Dupe into the arena so it survives owned.deinit().
                session_id = try allocator.dupe(u8, s.session_id);
                print("    session_id : {s}\n", .{session_id});
                if (s.model) |m| print("    model      : {s}\n", .{m});
            },
            .assistant => |a| printAssistant(a),
            .result => |r| {
                printResult(r);
                break :step1;
            },
            else => {},
        }
    }

    try sess1.close();
    print("    session closed\n", .{});

    if (session_id.len == 0) {
        print("\n[ERROR] No system message received — claude may have exited immediately.\n", .{});
        print("        Check that the claude binary is in PATH and auth is configured.\n", .{});
        return error.NoSessionId;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Step 2 — Resume by session_id, ask for the result.
    // ─────────────────────────────────────────────────────────────────────────
    print("\n[2] Resuming session {s} — checking result\n", .{session_id});

    var sess2 = try sdk.Session.initResume(allocator, io, session_id, opts);
    defer sess2.deinit();

    try sess2.send("What was the result of the calculation you just performed?");

    step2: while (try sess2.receive()) |msg| {
        var owned = msg;
        defer owned.deinit();
        switch (owned.msg) {
            .assistant => |a| printAssistant(a),
            .result => |r| {
                printResult(r);
                break :step2;
            },
            else => {},
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Step 3 — Wait 5 seconds.
    // ─────────────────────────────────────────────────────────────────────────
    print("\n[3] Waiting 5 seconds...\n", .{});
    try std.Io.sleep(io, std.Io.Duration.fromSeconds(5), .real);
    print("    done\n", .{});

    // ─────────────────────────────────────────────────────────────────────────
    // Step 4 — Send a status-check message (response read in step 5).
    // ─────────────────────────────────────────────────────────────────────────
    print("\n[4] Sending status check to session after 5s delay\n", .{});
    try sess2.send("In one sentence: what has this session discussed so far?");

    // ─────────────────────────────────────────────────────────────────────────
    // Step 5 — Print the response to step 4.
    // ─────────────────────────────────────────────────────────────────────────
    print("\n[5] Session response:\n", .{});

    step5: while (try sess2.receive()) |msg| {
        var owned = msg;
        defer owned.deinit();
        switch (owned.msg) {
            .assistant => |a| printAssistant(a),
            .result => |r| {
                printResult(r);
                break :step5;
            },
            else => {},
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Step 6 — Send another message, print response immediately.
    // ─────────────────────────────────────────────────────────────────────────
    print("\n[6] Sending — \"What is 10 * 10?\"\n", .{});

    try sess2.send("What is 10 * 10?");

    step6: while (try sess2.receive()) |msg| {
        var owned = msg;
        defer owned.deinit();
        switch (owned.msg) {
            .assistant => |a| printAssistant(a),
            .result => |r| {
                printResult(r);
                break :step6;
            },
            else => {},
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Step 7 — Wait 10 seconds.
    // ─────────────────────────────────────────────────────────────────────────
    print("\n[7] Waiting 10 seconds...\n", .{});
    try std.Io.sleep(io, std.Io.Duration.fromSeconds(10), .real);
    print("    done\n", .{});

    // ─────────────────────────────────────────────────────────────────────────
    // Step 8 — Send a final message and print the response after the wait.
    // ─────────────────────────────────────────────────────────────────────────
    print("\n[8] Sending final message after 10s wait\n", .{});

    try sess2.send("Summarize all calculations done in this session.");

    step8: while (try sess2.receive()) |msg| {
        var owned = msg;
        defer owned.deinit();
        switch (owned.msg) {
            .assistant => |a| printAssistant(a),
            .result => |r| {
                printResult(r);
                break :step8;
            },
            else => {},
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Step 9 — Close the session gracefully.
    // ─────────────────────────────────────────────────────────────────────────
    print("\n[9] Closing session...\n", .{});
    try sess2.close();
    print("    session closed\n", .{});

    print("\n═══ flow test complete ═══\n\n", .{});
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

fn printAssistant(msg: sdk.AssistantMsg) void {
    for (msg.content) |block| {
        switch (block) {
            .text => |t| print("    {s}", .{t.text}),
            .thinking => |t| print("    <thinking> {s} </thinking>\n", .{t.thinking}),
            .tool_use => |t| print("    [tool: {s}]\n", .{t.name}),
        }
    }
    print("\n", .{});
}

fn printResult(msg: sdk.ResultMsg) void {
    print("    [{s}] turns={d}  cost=${d:.4}  duration={d}ms\n", .{
        @tagName(msg.subtype),
        msg.num_turns,
        msg.total_cost_usd,
        msg.duration_ms,
    });
}
