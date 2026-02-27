const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public library module — consumers import as @import("cc-sdk-zig")
    const mod = b.addModule("cc-sdk-zig", .{
        .root_source_file = b.path("src/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Example executable for local development
    const exe = b.addExecutable(.{
        .name = "cc-sdk-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cc-sdk-zig", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the example").dependOn(&run_cmd.step);

    // One-shot query integration test
    const query_exe = b.addExecutable(.{
        .name = "query-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/query-test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cc-sdk-zig", .module = mod },
            },
        }),
    });
    b.installArtifact(query_exe);

    const query_cmd = b.addRunArtifact(query_exe);
    query_cmd.step.dependOn(b.getInstallStep());
    b.step("query-test", "Run the one-shot query integration test").dependOn(&query_cmd.step);

    // Session flow integration test
    const flow_exe = b.addExecutable(.{
        .name = "flow-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/flow-test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cc-sdk-zig", .module = mod },
            },
        }),
    });
    b.installArtifact(flow_exe);

    const flow_cmd = b.addRunArtifact(flow_exe);
    flow_cmd.step.dependOn(b.getInstallStep());
    b.step("flow-test", "Run the session flow integration test").dependOn(&flow_cmd.step);

    // Library tests
    const lib_tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run library tests").dependOn(&b.addRunArtifact(lib_tests).step);
}
