const std = @import("std");

// geo-zrs 公开仓构建：库（geozrs）+ 转换工具（zrs-convert）+ 测试。
// 自包含（零生态私有依赖）——GitHub Action 只 checkout 本仓即可构建。
pub fn build(b: *std.Build) void {
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse .ReleaseSafe;
    const target = b.standardTargetOptions(.{});

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    _ = lib_mod;

    // 库测试
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_tests.step);

    // 内存形态探针（mmap vs 全量读入的运行时实证；开发工具非分发件）
    const probe_mod = b.createModule(.{
        .root_source_file = b.path("src/memprobe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const probe_exe = b.addExecutable(.{ .name = "zrs-memprobe", .root_module = probe_mod });
    const install_probe = b.addInstallArtifact(probe_exe, .{});
    const probe_step = b.step("memprobe", "Build memory probe");
    probe_step.dependOn(&install_probe.step);

    // 转换工具（dat 上游 → KZF1 容器 full/base + ads 轻量覆盖）
    const conv_mod = b.createModule(.{
        .root_source_file = b.path("src/convert.zig"),
        .target = target,
        .optimize = optimize,
    });
    const conv_exe = b.addExecutable(.{ .name = "zrs-convert", .root_module = conv_mod });
    const install_conv = b.addInstallArtifact(conv_exe, .{});
    const conv_step = b.step("zrs-convert", "Build dataset converter");
    conv_step.dependOn(&install_conv.step);
}
