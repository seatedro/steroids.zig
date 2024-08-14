const std = @import("std");
const rlz = @import("raylib-zig");
const fs = std.fs;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "steroids.zig",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_check = b.addExecutable(.{
        .name = "steroids.zig",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const raylib_dep = b.dependency("raylib-zig", .{
        .target = target,
        .optimize = optimize,
    });

    const raylib = raylib_dep.module("raylib");
    const raylib_artifact = raylib_dep.artifact("raylib");

    if (target.query.os_tag == .emscripten) {
        const exe_lib = rlz.emcc.compileForEmscripten(b, "steroids.zig", "src/main.zig", target, optimize);

        exe_lib.linkLibrary(raylib_artifact);
        exe_lib.root_module.addImport("raylib", raylib);

        const include_path = try fs.path.join(b.allocator, &.{ b.sysroot.?, "cache", "sysroot", "include" });
        defer b.allocator.free(include_path);
        exe_lib.addIncludePath(.{ .path = include_path });
        exe_lib.linkLibC();

        // linking raylib to the exe_lib output file.
        const link_step = try rlz.emcc.linkWithEmscripten(b, &[_]*std.Build.Step.Compile{ exe_lib, raylib_artifact });

        // Add the -sUSE_OFFSET_CONVERTER flag
        link_step.addArg("-sUSE_OFFSET_CONVERTER");

        // Use the custom HTML template
        link_step.addArg("--shell-file");
        link_step.addArg("shell.html");

        // Embed the resources directory
        link_step.addArg("--preload-file");
        link_step.addArg("assets");

        link_step.addArg("-sALLOW_MEMORY_GROWTH");
        link_step.addArg("-sWASM_MEM_MAX=16MB");
        link_step.addArg("-sTOTAL_MEMORY=16MB");
        link_step.addArg("-sERROR_ON_UNDEFINED_SYMBOLS=0");
        link_step.addArg("-sEXPORTED_RUNTIME_METHODS=ccall,cwrap");

        b.getInstallStep().dependOn(&link_step.step);
        const run_step = try rlz.emcc.emscriptenRunStep(b);
        run_step.step.dependOn(&link_step.step);
        const run_option = b.step("run", "Run the steroids.zig");
        run_option.dependOn(&run_step.step);
        return;
    }

    exe.linkLibrary(raylib_artifact);
    exe.root_module.addImport("raylib", raylib);

    exe_check.linkLibrary(raylib_artifact);
    exe_check.root_module.addImport("raylib", raylib);

    b.installArtifact(exe);

    const check_step = b.step("check", "Check if the code compiles");
    check_step.dependOn(&exe_check.step);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
