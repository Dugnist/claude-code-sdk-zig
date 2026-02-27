const std = @import("std");
const sdk = @import("cc-sdk-zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) {
        std.debug.print("Usage: cc-sdk-example <prompt>\n", .{});
        return;
    }

    const prompt = args[1];

    try sdk.query(allocator, io, prompt, .{ .cwd = "." }, &onMessage);
}

fn onMessage(_: std.mem.Allocator, msg: sdk.Message) anyerror!void {
    switch (msg) {
        .assistant => |a| for (a.content) |blk| {
            if (blk == .text) std.debug.print("{s}", .{blk.text.text});
        },
        .result => |r| std.debug.print("\n[{s}] cost=${d:.4}\n", .{
            @tagName(r.subtype),
            r.total_cost_usd,
        }),
        else => {},
    }
}
