const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zson", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Main executable
    const exe = b.addExecutable(.{
        .name = "zson",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zson", .module = mod },
            },
        }),
    });
    exe.linkLibC();
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run zson").dependOn(&run_cmd.step);

    // Examples
    inline for (.{
        .{ "example-query", "examples/query.zig", "Run query example" },
        .{ "example-parallel", "examples/parallel.zig", "Run parallel example" },
    }) |ex| {
        const ex_exe = b.addExecutable(.{
            .name = ex[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex[1]),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zson", .module = mod },
                },
            }),
        });
        ex_exe.linkLibC();
        const run_ex = b.addRunArtifact(ex_exe);
        b.step(ex[0], ex[2]).dependOn(&run_ex.step);
    }

    // Tests
    const mod_tests = b.addTest(.{ .root_module = mod });
    mod_tests.linkLibC();
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
