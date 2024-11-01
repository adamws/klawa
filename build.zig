const std = @import("std");
const fs = std.fs;

const CFlags = &.{};

pub fn build(b: *std.Build) void {
    const tracy = b.option([]const u8, "tracy", "Enable Tracy integration. Supply path to Tracy source");
    const tracy_callstack = b.option(bool, "tracy-callstack", "Include callstack information with Tracy data. Does nothing if -Dtracy is not provided") orelse false;
    const tracy_allocation = b.option(bool, "tracy-allocation", "Include allocation information with Tracy data. Does nothing if -Dtracy is not provided") orelse false;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "klawa",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_options = b.addOptions();
    exe.root_module.addOptions("build_options", exe_options);

    exe_options.addOption(bool, "enable_tracy", tracy != null);
    exe_options.addOption(bool, "enable_tracy_callstack", tracy_callstack);
    exe_options.addOption(bool, "enable_tracy_allocation", tracy_allocation);
    if (tracy) |tracy_path| {
        const client_cpp = b.pathJoin(
            &[_][]const u8{ tracy_path, "public", "TracyClient.cpp" },
        );

        // On mingw, we need to opt into windows 7+ to get some features required by tracy.
        const tracy_c_flags: []const []const u8 = if (target.result.os.tag == .windows and target.result.abi == .gnu)
            &[_][]const u8{ "-DTRACY_ENABLE=1", "-fno-sanitize=undefined", "-D_WIN32_WINNT=0x601" }
        else
            &[_][]const u8{ "-DTRACY_ENABLE=1", "-fno-sanitize=undefined" };

        exe.addIncludePath(.{ .cwd_relative = tracy_path });
        exe.addCSourceFile(.{ .file = .{ .cwd_relative = client_cpp }, .flags = tracy_c_flags });
        exe.root_module.linkSystemLibrary("c++", .{ .use_pkg_config = .no });

        if (target.result.os.tag == .windows) {
            exe.linkSystemLibrary("dbghelp");
            exe.linkSystemLibrary("ws2_32");
        }
    }

    exe.linkLibC();

    const system_libs = [_][]const u8{ "X11", "Xi" };
    for (system_libs) |lib| {
        exe.linkSystemLibrary(lib);
    }

    const clap = b.dependency("clap", .{});
    exe.root_module.addImport("clap", clap.module("clap"));

    const known_folders = b.dependency("known-folders", .{});
    exe.root_module.addImport("known-folders", known_folders.module("known-folders"));

    const raylib_dep = b.dependency("raylib-zig", .{
        .target = target,
        .optimize = optimize,
    });

    const raylib = raylib_dep.module("raylib");
    const raygui = raylib_dep.module("raygui");
    const raylib_artifact = raylib_dep.artifact("raylib");

    exe.linkLibrary(raylib_artifact);
    exe.root_module.addImport("raylib", raylib);
    exe.root_module.addImport("raygui", raygui);

    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step: `zig build run`
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_unit_tests.linkLibC();

    for (system_libs) |lib| {
        exe_unit_tests.linkSystemLibrary(lib);
    }

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // This creates a test step: `zig build test`
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
