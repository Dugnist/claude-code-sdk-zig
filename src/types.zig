//! Claude Code SDK Message Types
//!
//! Structured types representing events emitted by Claude Code's NDJSON stdout.
//! All string fields in message types are arena-allocated and owned by the
//! containing OwnedMessage (for Session.receive) or valid only for the duration
//! of the MessageCallback invocation (for query).

const std = @import("std");

// ============================================================================
// Content Blocks
// ============================================================================

/// Plain text content from the assistant.
pub const TextBlock = struct {
    text: []const u8,
};

/// Extended thinking / reasoning content.
pub const ThinkingBlock = struct {
    thinking: []const u8,
};

/// Tool invocation by the assistant.
pub const ToolUseBlock = struct {
    /// Unique call identifier (e.g. "toolu_01...").
    id: []const u8,
    /// Tool name (e.g. "Bash", "Read").
    name: []const u8,
    /// Tool input serialized as a JSON string.
    input_json: []const u8,
};

/// Content block variant produced by the assistant.
pub const ContentBlock = union(enum) {
    text: TextBlock,
    thinking: ThinkingBlock,
    tool_use: ToolUseBlock,
};

// ============================================================================
// Token Usage
// ============================================================================

/// Token usage for a single assistant message.
pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_creation_input_tokens: u64 = 0,
    cache_read_input_tokens: u64 = 0,
};

// ============================================================================
// Message Variants
// ============================================================================

/// Session initialization event emitted once at the start of each run.
pub const SystemMsg = struct {
    /// Session ID assigned by Claude Code (use for resume).
    session_id: []const u8,
    /// Active model.
    model: ?[]const u8,
    /// Working directory.
    cwd: ?[]const u8,
    /// Tool names available in this session.
    tools: []const []const u8,
};

/// Assistant response containing one or more content blocks.
pub const AssistantMsg = struct {
    /// Unique message identifier.
    id: ?[]const u8,
    /// Session this message belongs to.
    session_id: ?[]const u8,
    /// Content blocks (text, thinking, tool_use).
    content: []const ContentBlock,
    /// Stop reason ("end_turn", "tool_use", "max_tokens", etc).
    stop_reason: ?[]const u8,
    /// Token usage for this message.
    usage: Usage,
};

/// Echoed user message (sent by Claude Code when it processes input).
pub const UserMsg = struct {
    /// Session this message belongs to.
    session_id: ?[]const u8,
    /// Raw content as JSON string (tool results etc).
    content_json: []const u8,
};

/// Discriminator for result success vs error.
pub const ResultSubtype = enum {
    success,
    error_result,
};

/// Final result emitted when Claude Code completes a task.
pub const ResultMsg = struct {
    /// Whether this is a success or error result.
    subtype: ResultSubtype,
    /// Session ID.
    session_id: []const u8,
    /// Final text answer from Claude (if any).
    result: ?[]const u8,
    /// Accumulated API cost in USD.
    total_cost_usd: f64,
    /// Wall-clock duration in milliseconds.
    duration_ms: u64,
    /// Cumulative API round-trip duration in milliseconds.
    duration_api_ms: u64,
    /// Number of agentic turns taken.
    num_turns: u32,
    /// True if this result represents an error condition.
    is_error: bool,
};

// ============================================================================
// Top-Level Message Union
// ============================================================================

/// All event types emitted by Claude Code.
pub const Message = union(enum) {
    /// Session initialization (first event).
    system: SystemMsg,
    /// Assistant response with content blocks.
    assistant: AssistantMsg,
    /// Echoed user message.
    user: UserMsg,
    /// Final completion result.
    result: ResultMsg,
};

// ============================================================================
// Callback / Owned Types
// ============================================================================

/// Callback invoked by query() for each parsed message.
///
/// The message and all string data within it are valid only for the duration
/// of this call. Copy any strings you need to retain beyond the callback.
/// The provided allocator is an arena that resets between messages.
pub const MessageCallback = *const fn (
    allocator: std.mem.Allocator,
    msg: Message,
) anyerror!void;

/// Message with its own arena allocator, returned by Session.receive().
///
/// All string data in `msg` is backed by the internal arena.
/// Call deinit() when done to free all associated memory.
pub const OwnedMessage = struct {
    msg: Message,
    arena: std.heap.ArenaAllocator,

    /// Free all memory associated with this message.
    pub fn deinit(self: *OwnedMessage) void {
        self.arena.deinit();
    }
};
