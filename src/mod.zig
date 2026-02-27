//! Claude Code Agent SDK for Zig
//!
//! A minimal, self-contained SDK for spawning and communicating with Claude Code
//! (the claude CLI) as a subprocess. Suitable for embedding in MCP servers,
//! automation pipelines, and multi-agent orchestration systems.
//!
//! ## Two Modes
//!
//! ### 1. One-shot: query()
//!
//! Spawn claude, send a single prompt, stream all events via callback, wait for exit.
//! Ideal for automation scripts, batch processing, and CI/CD pipelines.
//!
//! ```zig
//! const sdk = @import("sdk/mod.zig");
//!
//! fn handleMessage(alloc: std.mem.Allocator, msg: sdk.Message) anyerror!void {
//!     if (msg == .result) {
//!         std.debug.print("result: {s}\n", .{msg.result.result orelse "none"});
//!     }
//! }
//!
//! try sdk.query(allocator, io, "What is 2 + 2?",
//!     .{ .cwd = "/tmp" }, &handleMessage);
//! ```
//!
//! ### 2. Bidirectional: Session
//!
//! Long-running subprocess with open stdin/stdout for multi-turn conversations.
//! Ideal for interactive chat, MCP server backends, and inter-agent communication.
//!
//! ```zig
//! var sess = try sdk.Session.init(allocator, io, .{ .cwd = "/my/project" });
//! defer sess.deinit();
//!
//! try sess.send("Analyze the code in this repo");
//!
//! while (try sess.receive()) |*owned| {
//!     defer owned.deinit();
//!     switch (owned.msg) {
//!         .assistant => |a| for (a.content) |blk| {
//!             if (blk == .text) std.debug.print("{s}", .{blk.text.text});
//!         },
//!         .result => break,
//!         else => {},
//!     }
//! }
//!
//! try sess.close();
//! ```

// ============================================================================
// Submodules (for advanced / internal access)
// ============================================================================

pub const options_mod = @import("options.zig");
pub const types_mod = @import("types.zig");

// ============================================================================
// Options
// ============================================================================

pub const PermissionMode = options_mod.PermissionMode;
pub const KV = options_mod.KV;
pub const McpStdioServer = options_mod.McpStdioServer;
pub const McpSseServer = options_mod.McpSseServer;
pub const McpHttpServer = options_mod.McpHttpServer;
pub const McpServer = options_mod.McpServer;
pub const McpServerEntry = options_mod.McpServerEntry;
pub const QueryOptions = options_mod.QueryOptions;
pub const SessionOptions = options_mod.SessionOptions;

// ============================================================================
// Message Types
// ============================================================================

pub const TextBlock = types_mod.TextBlock;
pub const ThinkingBlock = types_mod.ThinkingBlock;
pub const ToolUseBlock = types_mod.ToolUseBlock;
pub const ContentBlock = types_mod.ContentBlock;
pub const Usage = types_mod.Usage;
pub const SystemMsg = types_mod.SystemMsg;
pub const AssistantMsg = types_mod.AssistantMsg;
pub const UserMsg = types_mod.UserMsg;
pub const ResultMsg = types_mod.ResultMsg;
pub const ResultSubtype = types_mod.ResultSubtype;
pub const Message = types_mod.Message;
pub const MessageCallback = types_mod.MessageCallback;
pub const OwnedMessage = types_mod.OwnedMessage;

// ============================================================================
// API
// ============================================================================

/// One-shot query: spawn, send prompt, stream events, exit.
pub const query = @import("query.zig").query;

/// Bidirectional session: spawn once, send/receive multiple turns.
pub const Session = @import("session.zig").Session;
