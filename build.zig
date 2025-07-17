const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add debug option to preserve symbols
    const debug_symbols = b.option(bool, "debug-symbols", "Include debug symbols") orelse false;

    const exe = b.addExecutable(.{
        .name = "cbzt",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Configure debug symbols
    if (debug_symbols or optimize == .Debug) {
        exe.root_module.strip = false;
    }

    const raylib_dep = b.dependency("raylib", .{
        .target = target,
        .optimize = if (debug_symbols) .Debug else optimize,
    });
    const raylib = raylib_dep.artifact("raylib");

    exe.linkLibrary(raylib);
    exe.linkLibC();

    // macOS frameworks
    exe.linkFramework("CoreFoundation");
    exe.linkFramework("CoreGraphics");
    exe.linkFramework("CoreServices");
    exe.linkFramework("Foundation");
    exe.linkFramework("IOKit");
    exe.linkFramework("AppKit");
    exe.linkFramework("OpenGL");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Add debug build step
    const debug_step = b.step("debug", "Build with debug symbols for profiling");
    debug_step.dependOn(b.getInstallStep());

    const exe_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
