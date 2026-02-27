//! Claude Code SDK Options
//!
//! Configuration types for query() and Session operations.
//! All fields are borrowed slices — caller must ensure they outlive the call.

const std = @import("std");

// ============================================================================
// Enums
// ============================================================================

/// Permission mode controlling which tools Claude may use without confirmation.
pub const PermissionMode = enum {
    /// CLI prompts for dangerous tools (interactive use).
    default,
    /// Auto-accept file edits without prompting.
    accept_edits,
    /// Require explicit approval before taking any action.
    plan,
    /// Allow all tools without confirmation. Use with caution.
    bypass_permissions,

    /// Convert to the CLI flag value expected by claude.
    pub fn toString(self: PermissionMode) []const u8 {
        return switch (self) {
            .default => "default",
            .accept_edits => "acceptEdits",
            .plan => "plan",
            .bypass_permissions => "bypassPermissions",
        };
    }
};

// ============================================================================
// MCP Server Config
// ============================================================================

/// Key-value pair used for env vars or HTTP headers.
pub const KV = struct {
    key: []const u8,
    value: []const u8,
};

/// MCP server running as a local subprocess (stdio transport).
pub const McpStdioServer = struct {
    /// Executable command.
    command: []const u8,
    /// Command-line arguments (optional).
    args: []const []const u8 = &.{},
    /// Extra environment variables for the subprocess (optional).
    env: []const KV = &.{},
};

/// MCP server via SSE (Server-Sent Events) endpoint.
pub const McpSseServer = struct {
    /// SSE endpoint URL.
    url: []const u8,
    /// HTTP headers to send with requests (optional).
    headers: []const KV = &.{},
};

/// MCP server via HTTP endpoint.
pub const McpHttpServer = struct {
    /// HTTP endpoint URL.
    url: []const u8,
    /// HTTP headers to send with requests (optional).
    headers: []const KV = &.{},
};

/// MCP server configuration variant.
pub const McpServer = union(enum) {
    stdio: McpStdioServer,
    sse: McpSseServer,
    http: McpHttpServer,
};

/// Named MCP server entry for inclusion in options.
pub const McpServerEntry = struct {
    /// Server name (key in mcpServers config).
    name: []const u8,
    /// Server transport configuration.
    config: McpServer,
};

// ============================================================================
// Query Options
// ============================================================================

/// Options for one-shot query() calls.
///
/// Configures how the claude subprocess is launched and what flags it receives.
/// All slice fields are borrowed — the caller owns the memory.
pub const QueryOptions = struct {
    /// Working directory for the subprocess. Required. Must be an absolute path.
    cwd: []const u8,

    /// Path to the claude binary. Searches PATH if null.
    cli_path: ?[]const u8 = null,

    /// Model identifier (e.g. "claude-opus-4-5"). Uses Claude default if null.
    model: ?[]const u8 = null,

    /// System prompt to override Claude's default system prompt.
    system_prompt: ?[]const u8 = null,

    /// Tool names to allow. Empty slice means all tools are allowed.
    allowed_tools: []const []const u8 = &.{},

    /// Tool names to explicitly disallow.
    disallowed_tools: []const []const u8 = &.{},

    /// Permission mode for tool execution. Defaults to bypass_permissions.
    permission_mode: PermissionMode = .bypass_permissions,

    /// Maximum number of agentic turns (optional).
    max_turns: ?u32 = null,

    /// Resume a previous session by session ID (optional).
    resume_session: ?[]const u8 = null,

    /// Continue the most recent conversation in the working directory.
    continue_conversation: bool = false,

    /// Enable verbose diagnostic output.
    verbose: bool = false,

    /// MCP servers to configure for this query.
    mcp_servers: []const McpServerEntry = &.{},

    /// Additional project directories to include.
    add_dirs: []const []const u8 = &.{},
};

// ============================================================================
// Session Options
// ============================================================================

/// Options for bidirectional Session operations.
///
/// Identical to QueryOptions but without prompt (sent via Session.send).
/// The input format is always stream-json for sessions.
pub const SessionOptions = struct {
    /// Working directory for the subprocess. Required. Must be an absolute path.
    cwd: []const u8,

    /// Path to the claude binary. Searches PATH if null.
    cli_path: ?[]const u8 = null,

    /// Model identifier. Uses Claude default if null.
    model: ?[]const u8 = null,

    /// System prompt override.
    system_prompt: ?[]const u8 = null,

    /// Tool names to allow. Empty slice means all tools allowed.
    allowed_tools: []const []const u8 = &.{},

    /// Tool names to explicitly disallow.
    disallowed_tools: []const []const u8 = &.{},

    /// Permission mode for tool execution. Defaults to bypass_permissions.
    permission_mode: PermissionMode = .bypass_permissions,

    /// Maximum number of agentic turns (optional).
    max_turns: ?u32 = null,

    /// Resume a previous session by session ID (optional).
    resume_session: ?[]const u8 = null,

    /// Continue the most recent conversation in the working directory.
    continue_conversation: bool = false,

    /// Pass --verbose to the claude subprocess.
    /// Must be true when stdin is not a TTY (i.e. always in subprocess/SDK mode).
    /// Defaults to true for sessions; set to false only if you have a specific reason.
    verbose: bool = true,

    /// MCP servers to configure for this session.
    mcp_servers: []const McpServerEntry = &.{},

    /// Additional project directories to include.
    add_dirs: []const []const u8 = &.{},

    /// When true (default), spawn with a minimal whitelist environment and
    /// CLAUDE_CONFIG_DIR pointing to `{cwd}/.claude/` for full isolation.
    /// When false, inherit the parent's complete environment and let CC use
    /// its default `~/.claude/` global config (MCPs, skills, memories, etc.).
    is_isolated: bool = true,

    /// When true, forward the subprocess stderr to the parent process stderr.
    /// Useful for diagnosing startup failures (auth errors, flag errors, etc.).
    /// Defaults to false (stderr is discarded).
    inherit_stderr: bool = false,
};
