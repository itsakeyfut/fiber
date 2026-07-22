const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fiber_mod = b.addModule("fiber", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Examples: `zig build examples` builds and runs each program in examples/.
    const example_step = b.step("examples", "Build and run the examples");
    const examples = [_][]const u8{ "basic", "scheduler" };
    for (examples) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "fiber", .module = fiber_mod },
                },
            }),
        });
        b.installArtifact(exe);

        const run_example = b.addRunArtifact(exe);
        run_example.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_example.addArgs(args);
        example_step.dependOn(&run_example.step);
    }

    // Tests: `zig build test`.
    const tests = b.addTest(.{ .root_module = fiber_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
