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

    const windows_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .abi = .gnu,
    });
    const windows_mod = b.addModule("zson-windows", .{
        .root_source_file = b.path("src/root.zig"),
        .target = windows_target,
    });
    const windows_exe = b.addExecutable(.{
        .name = "zson",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = windows_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zson", .module = windows_mod },
            },
        }),
    });
    windows_exe.linkLibC();
    b.step("windows", "Build zson for Windows x86_64").dependOn(&windows_exe.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run zson").dependOn(&run_cmd.step);

    // Examples
    inline for (.{
        .{ "example-query", "examples/query.zig", "Run query example" },
        .{ "example-parallel", "examples/parallel.zig", "Run parallel example" },
        .{ "example-lib", "examples/lib.zig", "Run Zig library API example" },
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

    const bench_json_exe = b.addExecutable(.{
        .name = "bench-json",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/json_libs.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zson", .module = mod },
            },
        }),
    });
    bench_json_exe.linkLibC();
    const run_bench_json = b.addRunArtifact(bench_json_exe);
    b.step("bench-json", "Compare zson with Zig std.json").dependOn(&run_bench_json.step);

    // Tests
    const mod_tests = b.addTest(.{ .root_module = mod });
    mod_tests.linkLibC();
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
