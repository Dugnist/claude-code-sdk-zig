//! ReadBuffer - Line buffer for streaming NDJSON reads.
//!
//! Accumulates partial reads into complete lines, handles chunked I/O,
//! skips empty lines, and manages partial data at EOF.
//!
//! ## Usage
//!
//! ```zig
//! var buffer = ReadBuffer.init(allocator);
//! defer buffer.deinit();
//!
//! // Append chunk from stream
//! try buffer.append(chunk);
//!
//! // Drain complete lines
//! while (buffer.drain()) |line| {
//!     // Process line
//! }
//! ```

const std = @import("std");

// ============================================================================
// ReadBuffer Struct
// ============================================================================

/// Line buffer for accumulating partial reads into complete lines.
///
/// Handles chunked reads from stdout, accumulates partial data,
/// and drains complete NDJSON lines. Skips empty lines and
/// handles partial lines at EOF.
pub const ReadBuffer = struct {
    /// Byte buffer for accumulated data
    buffer: []u8,

    /// Current length of data in buffer
    len: usize,

    /// Capacity of buffer
    capacity: usize,

    /// Arena allocator for JSON parsing
    arena: std.heap.ArenaAllocator,

    /// Allocator reference
    allocator: std.mem.Allocator,

    /// Initialize ReadBuffer with allocator.
    ///
    /// ## Parameters
    ///   - allocator: Memory allocator for buffer and arena
    ///
    /// ## Returns
    ///   - Initialized ReadBuffer
    pub fn init(allocator: std.mem.Allocator) ReadBuffer {
        // Start with 8KB capacity
        const capacity = 8192;
        const buffer = allocator.alloc(u8, capacity) catch unreachable;

        return .{
            .buffer = buffer,
            .len = 0,
            .capacity = capacity,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .allocator = allocator,
        };
    }

    /// Cleanup buffer and arena resources.
    ///
    /// ## Parameters
    ///   - self: Buffer to deinitialize
    pub fn deinit(self: *ReadBuffer) void {
        self.allocator.free(self.buffer);
        self.arena.deinit();
    }

    /// Append chunk to buffer.
    ///
    /// ## Parameters
    ///   - self: Buffer to append to
    ///   - data: Chunk to append
    ///
    /// ## Returns
    ///   - error.OutOfMemory if allocation fails
    pub fn append(self: *ReadBuffer, data: []const u8) !void {
        // Check if we need to expand
        const needed = self.len + data.len;
        if (needed > self.capacity) {
            // Expand buffer (double capacity until enough)
            var new_capacity = self.capacity * 2;
            while (new_capacity < needed) {
                new_capacity *= 2;
            }

            const new_buffer = try self.allocator.realloc(self.buffer, new_capacity);
            self.buffer = new_buffer;
            self.capacity = new_capacity;
        }

        // Append data
        @memcpy(self.buffer[self.len..][0..data.len], data);
        self.len += data.len;
    }

    /// Extract complete line or return null.
    ///
    /// Searches for '\n' in buffer, extracts line up to newline,
    /// removes from buffer, and returns line. Handles '\r\n' by
    /// stripping CR. Skips empty lines.
    ///
    /// ## Parameters
    ///   - self: Buffer to drain from
    ///
    /// ## Returns
    ///   - Complete line (borrowed from buffer, valid until next append/deinit)
    ///   - null if no complete line available
    pub fn drain(self: *ReadBuffer) ?[]const u8 {
        // Loop to skip all consecutive empty lines
        while (true) {
            // Search for newline
            const newline_idx = std.mem.indexOfScalar(u8, self.buffer[0..self.len], '\n') orelse {
                return null;
            };

            // Extract line (excluding newline)
            var line_end = newline_idx;

            // Check for '\r\n' (Windows line endings)
            const has_cr = (newline_idx > 0 and self.buffer[newline_idx - 1] == '\r');
            if (has_cr) {
                line_end = newline_idx - 1;
            }

            // Get the line (without \r or \n)
            var line = self.buffer[0..line_end];

            // Skip empty lines (including "\r\n")
            if (line.len == 0) {
                // Remove the line ending from buffer
                const remove_count = if (has_cr) newline_idx + 1 else newline_idx;
                const bytes_to_keep = self.len - remove_count - 1;
                for (0..bytes_to_keep) |i| {
                    self.buffer[i] = self.buffer[remove_count + 1 + i];
                }
                self.len = bytes_to_keep;
                // Continue to next line (skip this empty line)
                continue;
            }

            // Found a non-empty line - back it up and return it
            const remove_count = newline_idx + 1;
            const bytes_to_keep = self.len - remove_count;

            // Backup the line at the END of the buffer.
            // Ensure capacity for the backup (self.len + line.len may exceed capacity
            // when the buffer is full or nearly full).
            const line_backup_start = self.len;
            const needed = line_backup_start + line.len;
            if (needed > self.capacity) {
                var new_capacity = self.capacity * 2;
                while (new_capacity < needed) {
                    new_capacity *= 2;
                }
                const new_buffer = self.allocator.realloc(self.buffer, new_capacity) catch return null;
                self.buffer = new_buffer;
                self.capacity = new_capacity;
                // Re-derive line slice — realloc may have moved the buffer
                line = self.buffer[0..line_end];
            }

            for (0..line.len) |i| {
                self.buffer[line_backup_start + i] = line[i];
            }

            // Now shift the remaining data
            for (0..bytes_to_keep) |i| {
                self.buffer[i] = self.buffer[remove_count + i];
            }
            self.len = bytes_to_keep;

            // Return the backup copy of the line
            return self.buffer[line_backup_start..][0..line.len];
        }
    }

    /// Check if buffer has incomplete line.
    ///
    /// ## Parameters
    ///   - self: Buffer to check
    ///
    /// ## Returns
    ///   - true if buffer has data without newline
    pub fn hasPartial(self: *const ReadBuffer) bool {
        return self.len > 0;
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "ReadBuffer accumulates chunks and drains complete lines" {
    var buffer = ReadBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    // Append partial line (no newline)
    try buffer.append("partial");
    try std.testing.expect(buffer.hasPartial());
    try std.testing.expect(buffer.drain() == null); // No complete line yet

    // Append rest of line
    try buffer.append(" line\n");
    try std.testing.expect(buffer.drain() != null); // Complete line available
    try std.testing.expect(!buffer.hasPartial()); // Buffer empty after drain
}

test "ReadBuffer handles multiple lines" {
    var buffer = ReadBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    try buffer.append("line1\nline2\nline3\n");

    const line1 = buffer.drain();
    try std.testing.expect(line1 != null);
    try std.testing.expectEqualStrings("line1", line1.?);

    const line2 = buffer.drain();
    try std.testing.expect(line2 != null);
    try std.testing.expectEqualStrings("line2", line2.?);

    const line3 = buffer.drain();
    try std.testing.expect(line3 != null);
    try std.testing.expectEqualStrings("line3", line3.?);

    try std.testing.expect(buffer.drain() == null); // No more lines
}

test "ReadBuffer handles CRLF line endings" {
    var buffer = ReadBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    try buffer.append("line\r\n");

    const line = buffer.drain();
    try std.testing.expect(line != null);
    try std.testing.expectEqualStrings("line", line.?);
}

test "ReadBuffer skips empty lines" {
    var buffer = ReadBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    try buffer.append("line1\n\n\nline2\n");

    const line1 = buffer.drain();
    try std.testing.expect(line1 != null);
    try std.testing.expectEqualStrings("line1", line1.?);

    // Empty lines are skipped
    const line2 = buffer.drain();
    try std.testing.expect(line2 != null);
    try std.testing.expectEqualStrings("line2", line2.?);
}

test "ReadBuffer drain does not panic when buffer is at capacity" {
    var buffer = ReadBuffer.init(std.testing.allocator);
    defer buffer.deinit();

    // Fill buffer exactly to initial capacity (8192) with a single line + \n.
    // This triggers the backup-at-end path where line_backup_start == self.len == capacity.
    const line_len = 8191; // + 1 for \n = 8192 = initial capacity
    const big_line = "A" ** line_len;
    try buffer.append(big_line ++ "\n");
    try std.testing.expectEqual(@as(usize, 8192), buffer.len);

    const result = buffer.drain();
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, line_len), result.?.len);
    try std.testing.expectEqualStrings(big_line, result.?);
}
