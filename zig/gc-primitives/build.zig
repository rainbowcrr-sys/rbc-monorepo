const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "gc_primitives",
        .root_module = lib_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // Expose the module so downstream packages can use
    // b.dependency("gc_primitives", ...).module("gc_primitives").
    _ = b.addModule("gc_primitives", .{
        .root_source_file = b.path("src/root.zig"),
    });

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run contract tests");
    test_step.dependOn(&run_tests.step);
}
